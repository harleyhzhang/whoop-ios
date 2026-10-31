import Foundation
import SQLite3

/// Read-only scoring of the newest sleep before automatic publication.
extension WhoopStore {
    private enum PublishedSleep {
        case none
        /// Empty for an archived row, which is always a different sleep.
        case sleep(id: String)

        var sleepID: String? {
            if case .sleep(let id) = self { return id }
            return nil
        }
    }

    func provisionalDay(
        for candidate: SleepCandidate?,
        isSleeping: Bool,
        now: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) throws -> WhoopProvisionalDay? {
        guard let database, let candidate else { return nil }
        let summary = WhoopProvisionalSleepCandidate(
            firstAsleep: candidate.firstSleep.timestamp,
            lastAsleep: candidate.lastSleep.timestamp,
            meetsEvidenceGates: candidate.meetsEvidenceGates
        )
        let dateKey = WhoopProvisionalSleepPolicy.projectedDateKey(
            firstAsleep: summary.firstAsleep, lastAsleep: summary.lastAsleep, timeZone: timeZone)
        guard
            let published = publishedSleepID(dateKey: dateKey, database: database),
            WhoopProvisionalSleepPolicy.shouldShow(
                summary, isSleeping: isSleeping, now: now.timeIntervalSince1970,
                publishedSleepID: published.sleepID, timeZone: timeZone)
        else { return nil }
        let derived = try derivedRecord(for: candidate, now: now, dateKey: dateKey)
        let health =
            WhoopProvisionalSleepPolicy.showsScores(sleepSeconds: candidate.sleepSeconds)
            ? derived : derived.withholdingModelScores()
        let steps = provisionalSteps(
            dateKey: dateKey, from: candidate.lastSleep.timestamp, through: now, database: database)
        return WhoopProvisionalDay(
            health: health,
            steps: steps,
            recovery: provisionalRecovery(for: health, steps: steps, database: database)
        )
    }

    /// Nil is a failed read, which shows nothing rather than guessing.
    private func publishedSleepID(dateKey: String, database: OpaquePointer) -> PublishedSleep? {
        guard
            let rows = try? SQLiteRead.rows(
                database,
                sql: "SELECT COALESCE(sleep_id, '') FROM daily_health_metric WHERE date_key = ?",
                bindings: [.text(dateKey)], map: { textColumn($0, 0) ?? "" })
        else { return nil }
        if let id = rows.first { return .sleep(id: id) }
        return PublishedSleep.none
    }

    /// Publication re-buckets samples from the wake onward into the new day and
    /// keeps everything before it on the preceding day. Its wake bound passes
    /// through a whole-second ISO-8601 string, so count from the same floor.
    func provisionalSteps(
        dateKey: String, from lastAsleep: TimeInterval, through now: Date, database: OpaquePointer
    ) -> DailyStepRecord? {
        let sql = """
            SELECT sample_at, step_motion_counter
            FROM whoop_historical_sample
            WHERE peripheral_id = (\(WhoopStrainInputIndex.latestPeripheralQuery))
              AND sample_at >= ? AND sample_at <= ?
              AND step_motion_counter IS NOT NULL
            ORDER BY sample_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, lastAsleep.rounded(.down))
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        var samples: [WhoopStepCounterSample] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            samples.append(
                WhoopStepCounterSample(
                    timestamp: sqlite3_column_double(statement, 0),
                    counter: UInt16(truncatingIfNeeded: sqlite3_column_int(statement, 1))))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { return nil }
        let summary = WhoopStepDaySummary.summarize(samples)
        return DailyStepRecord(
            dateKey: dateKey,
            stepCount: summary.stepCount,
            sampleCount: summary.sampleCount,
            spanSeconds: summary.spanSeconds,
            coverageFraction: summary.coverageFraction,
            gapSeconds: summary.gapSeconds,
            counterWrapCount: summary.counterWrapCount,
            rejectedDeltaCount: summary.rejectedDeltaCount,
            firstSampleAt: summary.firstSampleAt.map { Date(timeIntervalSince1970: $0) },
            lastSampleAt: summary.lastSampleAt.map { Date(timeIntervalSince1970: $0) },
            source: "whoop5_v18_step_counter",
            algorithmVersion: WhoopStepDaySummary.algorithmVersion
        )
    }

    /// The stored backfill scores each night against the eligible nights before
    /// it; reproduce that history so the final value matches publication.
    func provisionalRecovery(
        for record: DailyHealthRecord, steps: DailyStepRecord?, database: OpaquePointer
    ) -> DailyRecoveryRecord? {
        guard let model = Self.bundledRecoveryScoreModel,
            let inputs = recoveryInputs(database: database)
        else { return nil }
        var history = WhoopRollingRecoveryHistory()
        for earlier in inputs.records where earlier.dateKey < record.dateKey {
            history.append(earlier)
        }
        var stepsByDate = inputs.stepsByDate
        stepsByDate[record.dateKey] = steps.map { Double($0.stepCount) }
        guard
            let features = RecoveryScoreFeatureBuilder.features(
                current: record, history: history.records, stepsByDate: stepsByDate),
            let prediction = model.prediction(features)
        else { return nil }
        return DailyRecoveryRecord(dateKey: record.dateKey, score: prediction.score, source: model.version)
    }
}
