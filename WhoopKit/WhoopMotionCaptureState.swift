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
        case readingClock, startingRaw, enablingIMU, awaitingSamples, recording
        case stoppingRaw, disablingIMU, settling, needsCleanup, complete
    }

    struct Pending: Codable {
        let opcode: UInt8
        let sequence: UInt8
        let sentAt: Date
    }

    struct ClockReference: Codable {
        let deviceAt: Date
        let sentAt: Date
        let receivedAt: Date
        var offset: TimeInterval {
            (sentAt.timeIntervalSince1970 + receivedAt.timeIntervalSince1970) / 2 - deviceAt.timeIntervalSince1970
        }
        var uncertainty: TimeInterval { receivedAt.timeIntervalSince(sentAt) / 2 + 0.02 }
    }
    private(set) var clockReference: ClockReference?
    let id: UUID
    let peripheralID: UUID
    let label: Label
    let notes: String
    let sourceCommit: String
    let startedAt: Date
    let deadline: Date
    private(set) var phase: Phase = .readingClock
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
        [.readingClock, .startingRaw, .enablingIMU, .awaitingSamples, .recording].contains(phase)
    }

    var needsCleanup: Bool { phase != .complete }
    var hasBothSensors: Bool {
        buffers.contains { $0.accelerometerCount > 0 && $0.gyroscopeCount > 0 }
    }

    var nextCommand: WhoopCommand? {
        guard pending == nil else { return nil }
        switch phase {
        case .readingClock: return .readMotionClock
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
        guard reply.result != 2 else { return }
        if phase == .readingClock {
            commandResults.append("147:\(pending.sequence):\(reply.result)")
            self.pending = nil
            if reply.result == 1, let deviceAt = reply.deviceClock,
                reply.receivedAt.timeIntervalSince(pending.sentAt) <= 2,
                abs(reply.receivedAt.timeIntervalSince(deviceAt)) <= 86400
            {
                clockReference = ClockReference(
                    deviceAt: deviceAt, sentAt: pending.sentAt, receivedAt: reply.receivedAt)
                phase = .startingRaw
            } else {
                failClock(now: now)
            }
            return
        }  // Pending is not successful completion.
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
        if buffer.realtime != false { observeProducerTraffic(now: now) }
        guard let reference = clockReference else { return }
        let aligned = buffer.sensorAt.addingTimeInterval(reference.offset)
        let uncertainty = reference.uncertainty
        guard aligned.addingTimeInterval(-uncertainty) >= startedAt.addingTimeInterval(-1),
            aligned.addingTimeInterval(uncertainty) <= (endedAt ?? deadline),
            buffer.receivedAt >= aligned.addingTimeInterval(-uncertainty),
            buffer.receivedAt.timeIntervalSince(aligned) <= 600
        else { return }
        // Even an empty valid buffer is live producer traffic and prevents a
        // false quiet-stop confirmation; it never adds sample coverage.
        guard buffer.accelerometerCount > 0 || buffer.gyroscopeCount > 0 else { return }
        if buffer.accelerometerCount > 0, buffer.gyroscopeCount > 0 { lastBothSensorsAt = now }
        guard isCollecting || phase == .complete || phase == .settling, buffers.count < 1200,
            !buffers.contains(where: { $0.sensorAt == buffer.sensorAt })
        else { return }
        buffers.append(buffer)
        if phase == .awaitingSamples, hasBothSensors { phase = .recording }
        if buffers.count >= 1200 { stop(reason: "Capture buffer limit reached", now: now) }
    }

    mutating func observeProducerTraffic(now: Date) {
        lastLiveBufferAt = now
        if phase == .complete {
            phase = .needsCleanup
            stop(reason: "Realtime motion continued after stop", now: now)
        }
    }

    var acceptsHistoryRepair: Bool { clockReference != nil && endedAt != nil }

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
        } else if isCollecting, now.timeIntervalSince(startedAt) >= 30, !hasBothSensors {
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

    private mutating func failClock(now: Date) {
        if lastLiveBufferAt != nil {
            stop(reason: "Clock unavailable; stopping observed motion producer", now: now)
        } else {
            reason = "Clock reference unavailable; sensors were not started"
            endedAt = now
            phase = .complete
        }
    }

    private mutating func finishCommand(accepted: Bool, now: Date) {
        switch phase {
        case .readingClock:
            failClock(now: now)
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
