import Foundation

/// Re-requesting the same offload forever cannot recover a wedged BLE command
/// channel. Escalate after two stalls, but never count replayed history as new
/// forward progress that earns another unlimited set of retries.
struct WhoopHistoricalRecovery {
    private var newestSampleAt: Date?
    private var consecutiveStalls = 0

    mutating func observeProgress(at sampleAt: Date) {
        guard newestSampleAt.map({ sampleAt > $0 }) ?? true else { return }
        newestSampleAt = sampleAt
        consecutiveStalls = 0
    }

    mutating func shouldReconnectAfterStall() -> Bool {
        consecutiveStalls = min(2, consecutiveStalls + 1)
        return consecutiveStalls >= 2
    }

    mutating func resetStalls() {
        consecutiveStalls = 0
    }
}
