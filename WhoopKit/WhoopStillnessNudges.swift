import Foundation

extension WhoopStillnessSample {
    static func decode(_ envelope: WhoopPacketEnvelope) -> Self? {
        guard envelope.acceptsControlEvents, envelope.integrityIsValid,
            let historical = envelope.historical, envelope.packet.count == 124
        else { return nil }
        let bytes = [UInt8](envelope.packet)
        let bits =
            UInt32(bytes[41]) | UInt32(bytes[42]) << 8
            | UInt32(bytes[43]) << 16 | UInt32(bytes[44]) << 24
        return Self(
            timestamp: historical.sampleAt.timeIntervalSince1970,
            receivedAt: envelope.deliveredAt.timeIntervalSince1970,
            acceleration: Double(Float(bitPattern: bits)), sleepState: historical.sleepState.rawValue)
    }
}

/// Event-driven: no background iPhone timer and no new sensor mode. A finite
/// waveform runs on the strap only after durable, coherent history arrives.
@MainActor
final class WhoopStillnessNudges {
    private var policy: WhoopStillnessPolicy
    private let send: (WhoopCommand) -> UInt8?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let localHour: (Date) -> Int
    private var pending: (sequence: UInt8, at: Date)?
    private let lastNudgeKey = "WhoopCollector.lastStillnessNudgeAt"

    init(
        send: @escaping (WhoopCommand) -> UInt8?, defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { .now },
        localHour: @escaping (Date) -> Int = { Calendar.autoupdatingCurrent.component(.hour, from: $0) }
    ) {
        self.send = send
        self.defaults = defaults
        self.clock = clock
        self.localHour = localHour
        policy = WhoopStillnessPolicy(startedAt: clock().timeIntervalSince1970)
        WhoopRuntimeDiagnostics.shared.recordEvent("stillness nudges initialized")
    }

    func resetConnection() {
        policy = WhoopStillnessPolicy(startedAt: clock().timeIntervalSince1970)
        pending = nil
    }

    func persisted(_ summary: WhoopTransportBatchSummary) {
        for sample in summary.stillnessSamples { policy.observe(sample) }
        guard let pending else { return }
        for envelope in summary.clockEnvelopes {
            let bytes = [UInt8](envelope.packet)
            guard bytes.count >= 20, bytes[8] == 36, bytes[10] == 19,
                bytes[11] == pending.sequence, bytes[13] == 1
            else { continue }
            if bytes[12] == 2 { continue }
            self.pending = nil
            let succeeded = bytes[12] == 1 && bytes[14] == 5
            WhoopRuntimeDiagnostics.shared.recordEvent(
                succeeded ? "stillness haptic completed" : "stillness haptic rejected")
        }
    }

    func historyCompleted(connected: Bool, worn: Bool, sleeping: Bool) {
        let now = clock()
        guard defaults.object(forKey: "WhoopCollector.stillnessNudgesEnabled") as? Bool != false,
            pending.map({ now.timeIntervalSince($0.at) >= 60 }) ?? true,
            (defaults.object(forKey: lastNudgeKey) as? Date).map({ now.timeIntervalSince($0) >= 3600 }) ?? true,
            policy.takeNudge(
                .init(
                    now: now.timeIntervalSince1970, localHour: localHour(now),
                    connected: connected, worn: worn, sleeping: sleeping))
        else { return }
        guard let sequence = send(.stillnessNudge) else { return }
        pending = (sequence, now)
        defaults.set(now, forKey: lastNudgeKey)
        WhoopRuntimeDiagnostics.shared.recordEvent("stillness triple nudge requested", at: now)
    }
}
