import Foundation

enum WhoopAutomaticSleepPolicy {
    static let provisionalWakeDelay: TimeInterval = 10 * 60
    static let reopenWindow: TimeInterval = 90 * 60

    static func reportsSleeping(
        latestState: SleepState,
        secondsSinceLastAsleep: TimeInterval,
        latestSampleIsCurrent: Bool
    ) -> Bool {
        latestSampleIsCurrent
            && (latestState == .asleep
                || (latestState == .up && secondsSinceLastAsleep < provisionalWakeDelay))
    }

    static func canFinalize(
        latestState: SleepState,
        secondsSinceLastAsleep: TimeInterval,
        latestSampleIsCurrent: Bool
    ) -> Bool {
        switch latestState {
        case .awakePrimary, .awakeAlternate:
            return secondsSinceLastAsleep >= 0
        case .up:
            return latestSampleIsCurrent && secondsSinceLastAsleep >= provisionalWakeDelay
        case .asleep, .unknown:
            return false
        }
    }
}

struct WhoopSleepSnapshot: Sendable {
    let isSleeping: Bool
    let sampleAt: Date?
    let finalizedRecord: DailyHealthRecord?
}

/// A factual account of what the strap actually banked and how each gate judged
/// it, so a night that produced no record can be explained instead of only
/// showing dashes.
struct WhoopSleepDiagnostics: Codable, Sendable {
    let generatedAt: String
    let windowHours: Int
    let sampleCount: Int
    let firstSampleAt: String?
    let lastSampleAt: String?
    let secondsSinceLastSample: Int?
    let observedCadenceSeconds: Double?
    let largestGapSeconds: Int?
    let sleepStateHistogram: [String: Int]
    let rawType47PacketTotal: Int
    let historicalSampleTotal: Int
    let recentType47Outcomes: [String: Int]
    let sessions: [WhoopSleepSessionDiagnostics]
    let outcome: String
}

struct WhoopSleepSessionDiagnostics: Codable, Sendable {
    let startedAt: String
    let endedAt: String
    let spanMinutes: Double
    let durationMinutes: Double
    let sampleCount: Int
    let coverage: Double
    let sampleDensity: Double
    let bankedWakeMinutes: Double
    let minutesSinceLastAsleep: Double
    let passesDurationGate: Bool
    let passesCoverageGate: Bool
    let passesWakeCoverageGate: Bool
    let passesWakeElapsedGate: Bool
    let dateKey: String
    let storedSleepID: String?
    let storedSummary: String?
    let verdict: String
}

struct WhoopLatestHeartRateSample: Sendable {
    let heartRate: Int
    let receivedAt: Date
}

struct WhoopPacketPersistenceResult: Sendable {
    let success: Bool
    let deliverySequence: Int64?
}

struct WhoopPacketBatchPersistenceResult: Sendable {
    let success: Bool
    let deliverySequences: [Int64]

    var committedEnvelopeCount: Int { success ? deliverySequences.count : 0 }
}
