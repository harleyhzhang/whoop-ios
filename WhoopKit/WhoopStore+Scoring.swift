import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Local sleep and recovery score backfills and analysis.
extension WhoopStore {
    /// Replays retained raw sleep-state evidence once for each score model
    /// version. Without this, an app update would fix future nights but leave
    /// the handful of locally scored pre-update nights on the old duration-only
    /// formula forever merely because they fell outside the 48-hour live window.
    func backfillLocalSleepScoresIfNeeded() {
        guard let database,
            metadataValue(database: database, key: "local-sleep-score-backfill") != Self.localSource
        else { return }
        let sql = """
            SELECT sample_at, heart_rate, sleep_state
            FROM whoop_historical_sample
            WHERE peripheral_id = (
                SELECT peripheral_id FROM whoop_historical_sample
                ORDER BY sample_at DESC LIMIT 1
            )
            ORDER BY sample_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        var rows: [HistoricalRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                HistoricalRow(
                    timestamp: sqlite3_column_double(statement, 0),
                    heartRate: Int(sqlite3_column_int(statement, 1)),
                    sleepState: SleepState(rawValue: Int(sqlite3_column_int(statement, 2)))
                ))
        }
        sqlite3_finalize(statement)
        guard let latest = rows.last, execute("BEGIN IMMEDIATE") else { return }
        let ranges = WhoopBackfillPlanner.indexedSleepRanges(
            in: rows,
            timestamp: { $0.timestamp },
            isAsleep: { $0.sleepState == .asleep }
        )
        for range in ranges {
            let session = Array(rows[range.sessionRange])
            let group = range.asleepIndices.map { rows[$0] }
            guard let first = group.first, let last = group.last else { continue }
            let cadence = Self.cadenceSeconds(of: session)
            let candidate = SleepCandidate(
                sessionRows: session,
                asleepRows: group,
                firstSleep: first,
                lastSleep: last,
                latest: latest,
                latestSampleIsCurrent: false,
                cadenceSeconds: cadence,
                sleepSeconds: Self.elapsedSeconds(across: group, cadence: cadence),
                sessionCoverage: Self.observedFraction(of: session, cadence: cadence),
                wakeSeconds: 0
            )
            guard candidate.meetsEvidenceGates,
                shouldDerive(candidate: candidate, database: database)
            else { continue }
            guard
                updateLocalSleepScore(
                    derivedRecord(for: candidate, now: .now), database: database
                )
            else {
                execute("ROLLBACK")
                return
            }
        }
        guard
            setMetadataValue(
                database: database, key: "local-sleep-score-backfill", value: Self.localSource
            ), execute("COMMIT")
        else {
            execute("ROLLBACK")
            return
        }
    }

    func rebuildRecoveryMetricsIfNeeded(force: Bool = false) {
        guard let database, let model = Self.bundledRecoveryScoreModel else { return }
        if !force,
            metadataValue(database: database, key: "local-recovery-score-backfill") == model.version
        {
            return
        }
        let healthSQL = """
            SELECT date_key, sleep_score, sleep_duration_minutes,
                   hrv_rmssd_milliseconds, resting_heart_rate_bpm,
                   sleep_id, cycle_id, source, source_archive, source_updated_at,
                   sleep_start_at, sleep_end_at, sleep_start_minute, sleep_end_minute,
                   sleep_need_minutes, sleep_consistency_percentage,
                   sleep_efficiency_percentage, sleep_sufficiency_percentage
            FROM daily_health_metric
            WHERE sleep_score IS NOT NULL AND sleep_duration_minutes IS NOT NULL
              AND hrv_rmssd_milliseconds IS NOT NULL
              AND resting_heart_rate_bpm IS NOT NULL
              AND sleep_start_minute IS NOT NULL AND sleep_end_minute IS NOT NULL
              AND sleep_efficiency_percentage IS NOT NULL
            ORDER BY date_key ASC
            """
        var healthStatementPointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, healthSQL, -1, &healthStatementPointer, nil) == SQLITE_OK,
            let healthStatement = healthStatementPointer
        else { return }
        var records: [DailyHealthRecord] = []
        var result = sqlite3_step(healthStatement)
        while result == SQLITE_ROW {
            guard let dateKey = textColumn(healthStatement, 0),
                let source = textColumn(healthStatement, 7),
                let sourceUpdatedAt = textColumn(healthStatement, 9)
            else {
                result = sqlite3_step(healthStatement)
                continue
            }
            records.append(
                DailyHealthRecord(
                    dateKey: dateKey,
                    sleepScore: doubleColumn(healthStatement, 1),
                    sleepDurationMinutes: doubleColumn(healthStatement, 2),
                    hrvRMSSDMilliseconds: doubleColumn(healthStatement, 3),
                    restingHeartRateBPM: doubleColumn(healthStatement, 4),
                    sleepID: textColumn(healthStatement, 5),
                    cycleID: int64Column(healthStatement, 6),
                    source: source,
                    sourceArchive: textColumn(healthStatement, 8),
                    sourceUpdatedAt: sourceUpdatedAt,
                    sleepStartAt: textColumn(healthStatement, 10),
                    sleepEndAt: textColumn(healthStatement, 11),
                    sleepStartMinute: doubleColumn(healthStatement, 12),
                    sleepEndMinute: doubleColumn(healthStatement, 13),
                    sleepNeedMinutes: doubleColumn(healthStatement, 14),
                    sleepConsistencyPercentage: doubleColumn(healthStatement, 15),
                    sleepEfficiencyPercentage: doubleColumn(healthStatement, 16),
                    sleepSufficiencyPercentage: doubleColumn(healthStatement, 17)
                ))
            result = sqlite3_step(healthStatement)
        }
        sqlite3_finalize(healthStatement)
        guard result == SQLITE_DONE else { return }

        let stepsSQL = """
            SELECT date_key, step_count FROM (
                SELECT date_key, official_steps AS step_count
                FROM whoop_official_daily_metric WHERE official_steps IS NOT NULL
                UNION ALL
                SELECT l.date_key, l.step_count FROM whoop_daily_step_metric l
                WHERE NOT EXISTS (
                    SELECT 1 FROM whoop_official_daily_metric o
                    WHERE o.date_key = l.date_key AND o.official_steps IS NOT NULL
                )
            )
            """
        var stepsStatementPointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, stepsSQL, -1, &stepsStatementPointer, nil) == SQLITE_OK,
            let stepsStatement = stepsStatementPointer
        else { return }
        var stepsByDate: [String: Double] = [:]
        result = sqlite3_step(stepsStatement)
        while result == SQLITE_ROW {
            if let dateKey = textColumn(stepsStatement, 0) {
                stepsByDate[dateKey] = Double(sqlite3_column_int64(stepsStatement, 1))
            }
            result = sqlite3_step(stepsStatement)
        }
        sqlite3_finalize(stepsStatement)
        guard result == SQLITE_DONE, execute("BEGIN IMMEDIATE") else { return }

        let upsertSQL = """
            INSERT INTO whoop_daily_recovery_metric
            (date_key, score, confidence, hrv_component, rhr_component,
             sleep_component, steps_component, hrv_baseline, rhr_baseline,
             sleep_baseline, steps_baseline, input_json, model_version, derived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                score = excluded.score, confidence = excluded.confidence,
                hrv_component = excluded.hrv_component,
                rhr_component = excluded.rhr_component,
                sleep_component = excluded.sleep_component,
                steps_component = excluded.steps_component,
                hrv_baseline = excluded.hrv_baseline,
                rhr_baseline = excluded.rhr_baseline,
                sleep_baseline = excluded.sleep_baseline,
                steps_baseline = excluded.steps_baseline,
                input_json = excluded.input_json,
                model_version = excluded.model_version,
                derived_at = excluded.derived_at
            """
        var upsertStatementPointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, upsertSQL, -1, &upsertStatementPointer, nil) == SQLITE_OK,
            let upsertStatement = upsertStatementPointer
        else {
            execute("ROLLBACK")
            return
        }
        let encoder = JSONEncoder()
        var rollingHistory = WhoopRollingRecoveryHistory()
        for record in records {
            let features = RecoveryScoreFeatureBuilder.features(
                current: record,
                history: rollingHistory.records,
                stepsByDate: stepsByDate
            )
            rollingHistory.append(record)
            guard
                let features, let prediction = model.prediction(features),
                let inputs = try? encoder.encode(features.map { $0.isFinite ? Optional($0) : nil }),
                let inputJSON = String(data: inputs, encoding: .utf8)
            else { continue }
            bind(record.dateKey, to: 1, in: upsertStatement)
            sqlite3_bind_double(upsertStatement, 2, prediction.score)
            sqlite3_bind_double(upsertStatement, 3, prediction.confidence)
            sqlite3_bind_double(upsertStatement, 4, prediction.hrvComponent)
            sqlite3_bind_double(upsertStatement, 5, prediction.rhrComponent)
            sqlite3_bind_double(upsertStatement, 6, prediction.sleepComponent)
            sqlite3_bind_double(upsertStatement, 7, prediction.stepsComponent)
            bind(prediction.hrvBaseline, to: 8, in: upsertStatement)
            bind(prediction.rhrBaseline, to: 9, in: upsertStatement)
            bind(prediction.sleepBaseline, to: 10, in: upsertStatement)
            bind(prediction.stepsBaseline, to: 11, in: upsertStatement)
            bind(inputJSON, to: 12, in: upsertStatement)
            bind(model.version, to: 13, in: upsertStatement)
            sqlite3_bind_double(upsertStatement, 14, Date().timeIntervalSince1970)
            guard sqlite3_step(upsertStatement) == SQLITE_DONE else {
                sqlite3_finalize(upsertStatement)
                execute("ROLLBACK")
                return
            }
            sqlite3_reset(upsertStatement)
            sqlite3_clear_bindings(upsertStatement)
        }
        sqlite3_finalize(upsertStatement)
        guard
            setMetadataValue(
                database: database, key: "local-recovery-score-backfill", value: model.version
            ), execute("COMMIT")
        else {
            execute("ROLLBACK")
            return
        }
    }

    func analyze(now: Date) -> SleepAnalysis {
        let rows = recentHistoricalRows(now: now)
        guard let latest = rows.last else { return .noData }
        let latestDate = Date(timeIntervalSince1970: latest.timestamp)
        let sampleIsCurrent = abs(now.timeIntervalSince(latestDate)) <= 30 * 60
        let detectorReportsSleeping = WhoopAutomaticSleepPolicy.reportsSleeping(
            latestState: latest.sleepState,
            latestSampleIsCurrent: sampleIsCurrent
        )
        let asleepRows = rows.filter { $0.sleepState == .asleep }
        guard !asleepRows.isEmpty else { return .awake(latestDate, []) }

        let groups = Self.groupedAsleepRows(asleepRows)
        var candidates: [SleepCandidate] = []
        for session in groups {
            guard let firstSleep = session.first, let lastSleep = session.last else { continue }
            let sessionRows = rows.filter {
                $0.timestamp >= firstSleep.timestamp && $0.timestamp <= lastSleep.timestamp
            }
            let cadence = Self.cadenceSeconds(of: sessionRows)
            let wakeRows = rows.filter {
                $0.timestamp > lastSleep.timestamp && $0.sleepState != .asleep
            }
            candidates.append(
                SleepCandidate(
                    sessionRows: sessionRows,
                    asleepRows: session,
                    firstSleep: firstSleep,
                    lastSleep: lastSleep,
                    latest: latest,
                    latestSampleIsCurrent: sampleIsCurrent,
                    cadenceSeconds: cadence,
                    // State 3 ("up") may bridge two state-2 runs into one night,
                    // but it is not sleep. Group with the asleep rows and measure
                    // with the asleep rows; conflating those two operations added
                    // an hour-long up interval to a real night's duration.
                    sleepSeconds: Self.elapsedSeconds(across: session, cadence: cadence),
                    sessionCoverage: Self.observedFraction(of: sessionRows, cadence: cadence),
                    wakeSeconds: Self.elapsedSeconds(across: wakeRows, cadence: cadence)
                ))
        }
        if detectorReportsSleeping { return .sleeping(latestDate, candidates.last) }
        return .awake(latestDate, candidates)
    }

    /// Automatic path. Explicit awake finalizes immediately; current `up`
    /// finalizes provisionally. Both remain gated on a coherent completed
    /// offload and can grow if sleep resumes within ninety minutes,
    /// or within two hours after a completed main sleep on the same morning.
    func analyzeLatestSleep(
        now: Date = .now,
        allowAutomaticFinalization: Bool = false
    ) -> WhoopSleepSnapshot {
        switch analyze(now: now) {
        case .noData:
            return WhoopSleepSnapshot(
                isSleeping: false,
                sampleAt: nil,
                finalizedRecord: nil
            )

        case .sleeping(let sampleAt, _):
            return WhoopSleepSnapshot(
                isSleeping: true,
                sampleAt: sampleAt,
                finalizedRecord: nil
            )

        case .awake(let sampleAt, let candidates):
            guard let database else {
                return WhoopSleepSnapshot(
                    isSleeping: false,
                    sampleAt: sampleAt,
                    finalizedRecord: nil
                )
            }

            // Only a completed history offload may bank a night, and the four
            // primary metrics are written together. The persisted completion
            // marker also makes this safe immediately after an app relaunch;
            // a newer partial chunk invalidates it until the next COMPLETE.
            let coherentHistory =
                allowAutomaticFinalization
                && completedOffloadCoversLatestHistory(database: database)
            var publishable: [DailyHealthRecord] = []
            for candidate in candidates
            where coherentHistory
                && candidate.meetsEvidenceGates
                && candidate.meetsAutomaticWakeGate
            {
                guard shouldDerive(candidate: candidate, database: database) else { continue }
                let record = derivedRecord(for: candidate, now: now)
                guard record.hasCompletePrimarySleepMetrics else { continue }
                publishable.append(record)
            }
            var newest: DailyHealthRecord?
            if !publishable.isEmpty, execute("BEGIN IMMEDIATE") {
                let succeeded = publishable.allSatisfy {
                    upsertLocalDailyHealthRecord($0, database: database)
                }
                if succeeded, execute("COMMIT") {
                    newest = publishable.last
                } else {
                    execute("ROLLBACK")
                }
            }
            if newest != nil { rebuildRecoveryMetricsIfNeeded(force: true) }

            return WhoopSleepSnapshot(
                isSleeping: false,
                sampleAt: sampleAt,
                finalizedRecord: newest
            )
        }
    }

    func completedOffloadCoversLatestHistoryForTesting() -> Bool {
        queue.sync { [self] in
            guard let database else { return false }
            return completedOffloadCoversLatestHistory(database: database)
        }
    }
}
