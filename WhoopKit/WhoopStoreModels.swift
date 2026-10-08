import Foundation

enum WhoopAutomaticSleepPolicy {
    static let reopenWindow: TimeInterval = 90 * 60
    static let sameMorningReopenWindow: TimeInterval = 2 * 60 * 60
    static let primarySleepMinimum: TimeInterval = 3 * 60 * 60

    /// The ordinary 90-minute window handles interruptions anywhere in a
    /// sleep. A narrow two-hour exception handles a completed main sleep that
    /// resumes the same local morning, without broadly folding afternoon naps
    /// or clusters of short sleeps into the preceding night.
    static func shouldMergeAsleepRuns(
        firstAsleepTimestamp: TimeInterval,
        lastAsleepTimestamp: TimeInterval,
        nextAsleepTimestamp: TimeInterval,
        timeZone: TimeZone
    ) -> Bool {
        let interruption = nextAsleepTimestamp - lastAsleepTimestamp
        guard interruption >= 0 else { return false }
        if interruption <= reopenWindow { return true }
        guard interruption <= sameMorningReopenWindow,
            lastAsleepTimestamp - firstAsleepTimestamp >= primarySleepMinimum
        else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let lastAsleep = Date(timeIntervalSince1970: lastAsleepTimestamp)
        let nextAsleep = Date(timeIntervalSince1970: nextAsleepTimestamp)
        return calendar.isDate(lastAsleep, inSameDayAs: nextAsleep)
            && calendar.component(.hour, from: nextAsleep) < 12
    }

    static func reportsSleeping(
        latestState: SleepState,
        latestSampleIsCurrent: Bool
    ) -> Bool {
        latestSampleIsCurrent
            && latestState == .asleep
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
            return latestSampleIsCurrent && secondsSinceLastAsleep >= 0
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
    let rawType47PacketTotal: Int?
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
    let failure: WhoopStorageFailure?

    init(
        success: Bool,
        deliverySequence: Int64?,
        failure: WhoopStorageFailure? = nil
    ) {
        self.success = success
        self.deliverySequence = deliverySequence
        self.failure = failure
    }
}

struct WhoopPacketBatchPersistenceResult: Sendable {
    let success: Bool
    let deliverySequences: [Int64]
    let failure: WhoopStorageFailure?

    init(
        success: Bool,
        deliverySequences: [Int64],
        failure: WhoopStorageFailure? = nil
    ) {
        self.success = success
        self.deliverySequences = deliverySequences
        self.failure = failure
    }

    var committedEnvelopeCount: Int { success ? deliverySequences.count : 0 }
}
