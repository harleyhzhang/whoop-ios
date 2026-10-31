import Foundation

/// Decodes retained calibration records without changing their evidence. New
/// recordings are retired; this policy can only turn a legacy producer OFF.
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
    // Legacy Codable evidence is still read/written by the journal. Retain
    // every field even when OFF-only recovery does not inspect its value.
    // swiftlint:disable unused_declaration
    struct ClockReference: Codable {
        let deviceAt: Date
        let sentAt: Date
        let receivedAt: Date
    }
    private(set) var clockReference: ClockReference?
    let id: UUID
    let peripheralID: UUID
    let label: Label
    let notes: String
    let sourceCommit: String
    let startedAt: Date
    let deadline: Date
    private(set) var phase: Phase
    private(set) var pending: Pending?
    private(set) var endedAt: Date?
    private(set) var reason: String
    private(set) var buffers: [WhoopMotionProtocol.Buffer]
    private(set) var commandResults: [String]
    private(set) var rawBytesReceived: Int
    private(set) var rawStopAccepted: Bool
    private(set) var imuStopAccepted: Bool
    private(set) var rawStartUnsupported: Bool
    private(set) var imuStartUnsupported: Bool
    private(set) var settlingAt: Date?
    private(set) var lastLiveBufferAt: Date?
    private(set) var lastBothSensorsAt: Date?

    // swiftlint:enable unused_declaration

    var needsCleanup: Bool { phase != .complete }
    var nextCommand: WhoopCommand? {
        guard pending == nil else { return nil }
        return switch phase {
        case .stoppingRaw: .stopRawMotion
        case .disablingIMU: .disableLiveIMU
        default: nil
        }
    }

    mutating func sent(_ command: WhoopCommand, sequence: UInt8, now: Date) {
        guard command == nextCommand else { return }
        pending = Pending(opcode: command.opcode, sequence: sequence, sentAt: now)
    }

    mutating func reply(_ reply: WhoopMotionProtocol.Reply, now: Date) {
        guard let pending, reply.command == pending.opcode, reply.origin == pending.sequence,
            reply.receivedAt >= pending.sentAt, reply.result != 2
        else { return }
        commandResults.append("\(reply.command):\(reply.origin):\(reply.result)")
        self.pending = nil
        finishCommand(accepted: reply.result == 1, now: now)
    }

    mutating func stop(reason: String, now: Date) {
        guard phase != .stoppingRaw, phase != .disablingIMU, phase != .settling else { return }
        self.reason = reason
        endedAt = endedAt ?? now
        pending = nil
        rawStopAccepted = false
        imuStopAccepted = false
        phase = .stoppingRaw
    }

    mutating func disconnected(now: Date) {
        guard needsCleanup else { return }
        reason = "Interrupted legacy recording; cleanup required"
        endedAt = endedAt ?? now
        pending = nil
        phase = .needsCleanup
    }

    mutating func reconnect(now: Date) {
        guard needsCleanup else { return }
        phase = .needsCleanup
        stop(reason: "Retired recording; stopping sensors", now: now)
    }

    mutating func observeProducerTraffic(now: Date) {
        lastLiveBufferAt = now
        if phase == .complete {
            stop(reason: "Realtime motion continued after stop", now: now)
        }
    }

    mutating func tick(now: Date) {
        if let pending, now.timeIntervalSince(pending.sentAt) >= 4 {
            commandResults.append("\(pending.opcode):\(pending.sequence):timeout")
            self.pending = nil
            finishCommand(accepted: false, now: now)
        }
        guard phase == .settling, let settlingAt else { return }
        let lastTraffic = max(settlingAt, lastLiveBufferAt ?? settlingAt)
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
        case .stoppingRaw:
            rawStopAccepted = accepted
            phase = .disablingIMU
        case .disablingIMU:
            imuStopAccepted = accepted
            settlingAt = now
            phase = .settling
        default: break
        }
    }
}
