import Foundation

/// The night in progress, scored with the publication code but never stored,
/// notified, or replicated. Automatic publication still owns the banked day.
struct WhoopProvisionalDay: Codable, Equatable, Sendable {
    let health: DailyHealthRecord
    let steps: DailyStepRecord?
    let recovery: DailyRecoveryRecord?

    var dateKey: String { health.dateKey }
}

/// A night's identity and what is already published for its projected day.
struct WhoopProvisionalSleepCandidate: Equatable, Sendable {
    let firstAsleep: TimeInterval
    let lastAsleep: TimeInterval
    let meetsEvidenceGates: Bool

    var sleepID: String { "local-\(Int(firstAsleep))-\(Int(lastAsleep))" }
    var sessionPrefix: String { "local-\(Int(firstAsleep))-" }
}

enum WhoopProvisionalSleepPolicy {
    /// Sleep that begins six or more hours before midnight is an evening nap
    /// or a day sleep and keeps the current day; later onsets name tomorrow.
    static let onsetDayLead: TimeInterval = 6 * 60 * 60

    /// Duration, heart rate, and HRV are honest measurements from the first
    /// minutes. The Sleep model only saw nights past the publication minimum;
    /// replaying 37 real nights, its score swung 20+ points below three hours
    /// and Recovery inherits it, so both wait for the same evidence gate.
    static func showsScores(sleepSeconds: TimeInterval) -> Bool {
        sleepSeconds >= WhoopAutomaticSleepPolicy.primarySleepMinimum
    }

    /// A night is published under the local day of its last asleep sample.
    /// Before that sample is known, name the day it will most likely end on.
    static func projectedDateKey(
        firstAsleep: TimeInterval,
        lastAsleep: TimeInterval,
        timeZone: TimeZone
    ) -> String {
        let projectedEnd = max(lastAsleep, firstAsleep + onsetDayLead)
        return DayKey.string(from: Date(timeIntervalSince1970: projectedEnd), timeZone: timeZone)
    }

    /// Shows the night while it is running, while it could still continue,
    /// and while a night that passed the evidence gates awaits publication.
    /// A different sleep already published for the same day keeps priority,
    /// so a nap never replaces the morning's banked night.
    static func shouldShow(
        _ candidate: WhoopProvisionalSleepCandidate,
        isSleeping: Bool,
        now: TimeInterval,
        publishedSleepID: String?,
        timeZone: TimeZone
    ) -> Bool {
        if let publishedSleepID {
            if publishedSleepID == candidate.sleepID { return false }
            guard publishedSleepID.hasPrefix(candidate.sessionPrefix) else { return false }
        }
        if isSleeping || candidate.meetsEvidenceGates { return true }
        return WhoopAutomaticSleepPolicy.shouldMergeAsleepRuns(
            firstAsleepTimestamp: candidate.firstAsleep,
            lastAsleepTimestamp: candidate.lastAsleep,
            nextAsleepTimestamp: now,
            timeZone: timeZone
        )
    }
}

extension DashboardHistorySnapshot {
    /// Places the in-progress day into every history family so charts and
    /// the current-day summary agree. Missing provisional families stay empty.
    func overlaying(_ provisional: WhoopProvisionalDay?) -> DashboardHistorySnapshot {
        guard let provisional else { return self }
        let key = provisional.dateKey
        return DashboardHistorySnapshot(
            healthRecords: Self.replacing(healthRecords, key: key, with: provisional.health),
            stepRecords: Self.replacing(stepRecords, key: key, with: provisional.steps),
            recoveryRecords: Self.replacing(recoveryRecords, key: key, with: provisional.recovery),
            strainRecords: strainRecords,
            strainDerivations: strainDerivations
        )
    }

    private static func replacing<Record: Identifiable>(
        _ records: [Record], key: String, with record: Record?
    ) -> [Record] where Record.ID == String {
        var result = records.filter { $0.id != key }
        if let record { result.append(record) }
        return result.sorted { $0.id < $1.id }
    }
}

extension DailyHealthRecord {
    /// Keeps measured values and drops model outputs. Recovery has no input
    /// without a Sleep score, so it is withheld with it.
    func withholdingModelScores() -> DailyHealthRecord {
        DailyHealthRecord(
            dateKey: dateKey, sleepScore: nil, sleepDurationMinutes: sleepDurationMinutes,
            hrvRMSSDMilliseconds: hrvRMSSDMilliseconds, restingHeartRateBPM: restingHeartRateBPM,
            sleepID: sleepID, cycleID: cycleID, source: source, sourceArchive: sourceArchive,
            sourceUpdatedAt: sourceUpdatedAt, sleepStartAt: sleepStartAt, sleepEndAt: sleepEndAt,
            sleepStartMinute: sleepStartMinute, sleepEndMinute: sleepEndMinute,
            sleepEfficiencyPercentage: sleepEfficiencyPercentage)
    }
}
