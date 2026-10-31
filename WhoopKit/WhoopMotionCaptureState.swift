import Foundation

/// Pure finite capture policy. Device-side expiry is unproven: interrupted
/// cleanup stays journaled and is retried on the next matching connection.
struct WhoopMotionCaptureState: Codable {
    enum Label: String, CaseIterable, Codable {
        case lifting = "Lifting"
        case walking = "Walking"
        case rest = "Rest"
    }

    enum Phase: String, Codable {
        case startingRaw, enablingIMU, awaitingSamples, recording
        case stoppingRaw, disablingIMU, settling, needsCleanup, complete
    }

    struct Pending: Codable {
        let opcode: UInt8
        let sequence: UInt8
        let sentAt: Date
    }

    let id: UUID
    let peripheralID: UUID
    let label: Label
    let notes: String
    let sourceCommit: String
    let startedAt: Date
    let deadline: Date
    private(set) var phase: Phase = .startingRaw
    private(set) var pending: Pending?
    private(set) var endedAt: Date?
    private(set) var reason = ""
    private(set) var buffers: [WhoopMotionProtocol.Buffer] = []
    private(set) var commandResults: [String] = []
    private(set) var rawBytesReceived = 0
    private(set) var rawStopAccepted = false
    private(set) var imuStopAccepted = false
    private(set) var rawStartUnsupported = false
    private(set) var imuStartUnsupported = false
    private(set) var settlingAt: Date?
    private(set) var lastLiveBufferAt: Date?
    private(set) var lastBothSensorsAt: Date?

    init?(
        peripheralID: UUID, label: Label, notes: String, duration: TimeInterval,
        sourceCommit: String, now: Date
    ) {
        guard duration.isFinite, (30...600).contains(duration) else { return nil }
        id = UUID()
        self.peripheralID = peripheralID
        self.label = label
        self.notes = String(notes.prefix(300))
        self.sourceCommit = sourceCommit
        startedAt = now
        deadline = now.addingTimeInterval(duration)
    }

    var isCollecting: Bool {
        [.startingRaw, .enablingIMU, .awaitingSamples, .recording].contains(phase)
    }

    var needsCleanup: Bool { phase != .complete }
    var hasBothSensors: Bool {
        buffers.contains { $0.accelerometerCount > 0 && $0.gyroscopeCount > 0 }
    }

    var nextCommand: WhoopCommand? {
        guard pending == nil else { return nil }
        switch phase {
        case .startingRaw: return .rawMotion(start: true)
        case .enablingIMU: return .liveIMU(enabled: true)
        case .stoppingRaw: return .rawMotion(start: false)
        case .disablingIMU: return .liveIMU(enabled: false)
        default: return nil
        }
    }

    mutating func sent(_ command: WhoopCommand, sequence: UInt8, now: Date) {
        pending = Pending(opcode: command.opcode, sequence: sequence, sentAt: now)
    }

    mutating func reply(_ reply: WhoopMotionProtocol.Reply, now: Date) {
        guard let pending, reply.command == pending.opcode, reply.origin == pending.sequence,
            reply.receivedAt >= pending.sentAt
        else { return }
        guard reply.result != 2 else { return }  // Pending is not successful completion.
        commandResults.append("\(reply.command):\(reply.origin):\(reply.result)")
        self.pending = nil
        if reply.result == 3 {
            if phase == .startingRaw { rawStartUnsupported = true }
            if phase == .enablingIMU { imuStartUnsupported = true }
        }
        finishCommand(accepted: reply.result == 1, now: now)
    }

    mutating func stop(reason: String, now: Date) {
        guard phase != .complete, phase != .stoppingRaw, phase != .disablingIMU,
            phase != .settling
        else { return }
        self.reason = reason
        endedAt = endedAt ?? now
        pending = nil
        rawStopAccepted = false
        imuStopAccepted = false
        phase = .stoppingRaw
    }

    mutating func disconnected(now: Date) {
        guard needsCleanup else { return }
        reason = "Connection interrupted; cleanup required"
        endedAt = endedAt ?? now
        pending = nil
        phase = .needsCleanup
    }

    mutating func reconnect(now: Date) {
        guard needsCleanup else { return }
        phase = .needsCleanup
        stop(reason: "Interrupted capture; stopping sensors", now: now)
    }

    mutating func observe(_ buffer: WhoopMotionProtocol.Buffer, now: Date) {
        // Only fresh, timestamped data from the labeled interval is credited.
        // Replayed history, duplicate buffers and clock skew never add coverage.
        guard abs(buffer.receivedAt.timeIntervalSince(buffer.sensorAt)) <= 2,
            buffer.sensorAt >= startedAt.addingTimeInterval(-1)
        else { return }
        // Even an empty valid buffer is live producer traffic and prevents a
        // false quiet-stop confirmation; it never adds sample coverage.
        lastLiveBufferAt = now
        guard buffer.accelerometerCount > 0 || buffer.gyroscopeCount > 0 else { return }
        if buffer.accelerometerCount > 0, buffer.gyroscopeCount > 0 { lastBothSensorsAt = now }
        guard isCollecting, buffer.sensorAt <= deadline,
            !buffers.contains(where: { $0.sensorAt == buffer.sensorAt })
        else { return }
        buffers.append(buffer)
        if phase == .awaitingSamples, hasBothSensors { phase = .recording }
        if buffers.count >= 1200 { stop(reason: "Capture buffer limit reached", now: now) }
    }

    mutating func observeRawBytes(_ count: Int, now: Date) {
        guard isCollecting else { return }
        rawBytesReceived += max(0, count)
        if rawBytesReceived >= 10 * 1024 * 1024 {
            stop(reason: "Capture storage budget reached", now: now)
        }
    }

    mutating func tick(now: Date) {
        if isCollecting, now >= deadline {
            stop(reason: "Time limit reached", now: now)
        } else if isCollecting, now.timeIntervalSince(startedAt) >= 15, !hasBothSensors {
            stop(reason: "No verified accel and gyro stream", now: now)
        } else if phase == .recording,
            now.timeIntervalSince(lastBothSensorsAt ?? startedAt) > 5
        {
            stop(reason: "Motion stream interrupted", now: now)
        }
        if let pending, now.timeIntervalSince(pending.sentAt) >= 4 {
            commandResults.append("\(pending.opcode):\(pending.sequence):timeout")
            self.pending = nil
            finishCommand(accepted: false, now: now)
        }
        guard phase == .settling, let settlingAt else { return }
        let lastTraffic = max(settlingAt, lastLiveBufferAt ?? settlingAt)
        // Explicit UNSUPPORTED proves this start operation did not enable a
        // producer. Failure/timeout/unknown never supply that proof. Always
        // attempt both stops first; avoid stranding ordinary history for an
        // unsupported optional capture facility.
        let noObservedProducer = lastLiveBufferAt == nil
        let stopped =
            (rawStopAccepted && imuStopAccepted)
            || (noObservedProducer && (rawStartUnsupported || (rawStopAccepted && imuStartUnsupported)))
        if stopped, now.timeIntervalSince(lastTraffic) >= 3 {
            phase = .complete
        } else if now.timeIntervalSince(settlingAt) >= 10 {
            phase = .needsCleanup
        }
    }

    private mutating func finishCommand(accepted: Bool, now: Date) {
        switch phase {
        case .startingRaw:
            if accepted {
                phase = .enablingIMU
            } else {
                stop(reason: "Raw capture request refused or timed out", now: now)
            }
        case .enablingIMU:
            if accepted {
                phase = hasBothSensors ? .recording : .awaitingSamples
            } else {
                stop(reason: "Live IMU request refused or timed out", now: now)
            }
        case .stoppingRaw:
            rawStopAccepted = accepted
            phase = .disablingIMU  // Always attempt both independent stop controls.
        case .disablingIMU:
            imuStopAccepted = accepted
            settlingAt = now
            phase = .settling
        default: break
        }
    }
}
