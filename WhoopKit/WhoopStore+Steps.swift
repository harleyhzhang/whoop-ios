import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Wake-anchored step-day materialization.
extension WhoopStore {
    func allStoredStepDateKeys(database: OpaquePointer) -> Set<String>? {
        let sql = """
            SELECT DISTINCT step_date_key
            FROM whoop_historical_sample
            WHERE step_date_key IS NOT NULL AND step_motion_counter IS NOT NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var dateKeys: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let dateKey = textColumn(statement, 0) { dateKeys.insert(dateKey) }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? dateKeys : nil
    }

    func rebuildWakeAnchoredStepDaysIfNeeded() {
        guard let database,
            metadataValue(database: database, key: "wake-anchored-step-days") != "3"
        else { return }
        let boundaries = publishedWakeBoundaries(database: database)
        guard !boundaries.isEmpty, execute("BEGIN IMMEDIATE") else { return }
        guard execute("DELETE FROM whoop_daily_step_metric"),
            execute(WhoopStepDayMigration.civilFallbackSQL)
        else {
            execute("ROLLBACK")
            return
        }
        for interval in WhoopStepDayMigration.intervals(for: boundaries) {
            let assigned = assignStepSamples(
                to: interval.dateKey,
                from: interval.lowerBound,
                until: interval.upperBound,
                database: database
            )
            guard assigned else {
                execute("ROLLBACK")
                return
            }
        }
        guard let dateKeys = allStoredStepDateKeys(database: database),
            rebuildDailySteps(for: dateKeys, database: database),
            setMetadataValue(
                database: database,
                key: "wake-anchored-step-days",
                value: "3"
            ),
            execute("COMMIT")
        else {
            execute("ROLLBACK")
            return
        }
        pendingStepDateKeys.removeAll(keepingCapacity: true)
        rebuildRecoveryMetricsIfNeeded(force: true)
        if !dateKeys.isEmpty { publishStepUpdate() }
    }

    /// Re-buckets post-wake samples. Samples before the wake—including during
    /// the just-finished sleep—remain on the preceding day.
    func assignStepsToPublishedDay(
        _ record: DailyHealthRecord,
        replacingWakeAt previousWakeAt: Date?,
        database: OpaquePointer
    ) -> Bool {
        guard let wakeRaw = record.sleepEndAt,
            let wokeAt = Self.parseISO8601(wakeRaw)
        else { return true }
        // This helper normally runs inside the caller's transaction. Do not
        // retain a boundary that could disappear if a later write rolls back.
        defer { cachedPublishedWakeBoundaries = nil }
        let boundaries = publishedWakeBoundaries(database: database)
        let upperBound =
            boundaries
            .filter { $0.wokeAt > wokeAt }
            .map(\.wokeAt)
            .min()?
            .timeIntervalSince1970
        let lowerBound = wokeAt.timeIntervalSince1970
        guard
            let oldDateKeys = stepDateKeys(
                from: lowerBound,
                until: upperBound,
                database: database
            ),
            assignStepSamples(
                to: record.dateKey,
                from: lowerBound,
                until: upperBound,
                database: database
            )
        else { return false }

        var affectedDateKeys = oldDateKeys.union([record.dateKey])

        // A provisional wake can move later when state-2 sleep returns inside
        // the reopen window. Move the interval that used to be post-wake back
        // to the preceding physiological day in the same transaction.
        if let previousWakeAt, previousWakeAt < wokeAt {
            let previousDateKey =
                (boundaries
                .filter { $0.wokeAt < wokeAt }
                .max(by: { $0.wokeAt < $1.wokeAt })?
                .dateKey
                ?? DayKey(
                    date: previousWakeAt.addingTimeInterval(-1),
                    timeZone: .autoupdatingCurrent
                )).rawValue
            let correctionLowerBound = previousWakeAt.timeIntervalSince1970
            guard
                let correctionDateKeys = stepDateKeys(
                    from: correctionLowerBound,
                    until: lowerBound,
                    database: database
                ),
                assignStepSamples(
                    to: previousDateKey,
                    from: correctionLowerBound,
                    until: lowerBound,
                    database: database
                )
            else { return false }
            affectedDateKeys.formUnion(correctionDateKeys)
            affectedDateKeys.insert(previousDateKey)
        }
        if let repair = WhoopStepDayMigration.fallbackRepair(
            before: wokeAt,
            boundaries: boundaries
        ) {
            guard
                let fallbackDateKeys = stepDateKeys(
                    from: repair.lowerBound,
                    until: lowerBound,
                    database: database
                ),
                assignStepSamples(
                    to: repair.dateKey,
                    from: repair.lowerBound,
                    until: lowerBound,
                    database: database
                )
            else { return false }
            affectedDateKeys.formUnion(fallbackDateKeys)
            affectedDateKeys.insert(repair.dateKey)
        }
        for dateKey in affectedDateKeys {
            guard deleteLocalStepMetric(dateKey: dateKey, database: database) else {
                return false
            }
        }
        guard rebuildDailySteps(for: affectedDateKeys, database: database) else {
            return false
        }
        pendingStepDateKeys.subtract(affectedDateKeys)
        return true
    }

    func stepDateKeys(
        from lowerBound: TimeInterval,
        until upperBound: TimeInterval?,
        database: OpaquePointer
    ) -> Set<String>? {
        let sql = """
            SELECT DISTINCT step_date_key
            FROM whoop_historical_sample
            WHERE step_motion_counter IS NOT NULL AND sample_at >= ?
              AND (? IS NULL OR sample_at < ?)
              AND step_date_key IS NOT NULL
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            sqlite3_bind_double(statement, 1, lowerBound)
            bind(upperBound, to: 2, in: statement)
            bind(upperBound, to: 3, in: statement)
            var dateKeys: Set<String> = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let dateKey = textColumn(statement, 0) { dateKeys.insert(dateKey) }
                result = sqlite3_step(statement)
            }
            return result == SQLITE_DONE ? dateKeys : nil
        } ?? nil
    }

    func assignStepSamples(
        to dateKey: String,
        from lowerBound: TimeInterval,
        until upperBound: TimeInterval?,
        database: OpaquePointer
    ) -> Bool {
        let sql = """
            UPDATE whoop_historical_sample
            SET step_date_key = ?
            WHERE step_motion_counter IS NOT NULL AND sample_at >= ?
              AND (? IS NULL OR sample_at < ?)
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(dateKey, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, lowerBound)
            bind(upperBound, to: 3, in: statement)
            bind(upperBound, to: 4, in: statement)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    func deleteLocalStepMetric(dateKey: String, database: OpaquePointer) -> Bool {
        let sql = "DELETE FROM whoop_daily_step_metric WHERE date_key = ?"
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(dateKey, to: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    func rebuildDailySteps(for dateKeys: Set<String>, database: OpaquePointer) -> Bool {
        guard !dateKeys.isEmpty else { return true }
        let selectSQL = """
            SELECT peripheral_id, sample_at, step_motion_counter
            FROM whoop_historical_sample
            WHERE step_date_key = ? AND step_motion_counter IS NOT NULL
            ORDER BY peripheral_id, sample_at
            """
        let upsertSQL = """
            INSERT INTO whoop_daily_step_metric
            (date_key, peripheral_id, step_count, sample_count, span_seconds,
             coverage_fraction, gap_seconds, counter_wrap_count,
             rejected_delta_count, first_sample_at, last_sample_at,
             source, algorithm_version, derived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    'whoop5_v18_step_counter', ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                peripheral_id = excluded.peripheral_id,
                step_count = excluded.step_count,
                sample_count = excluded.sample_count,
                span_seconds = excluded.span_seconds,
                coverage_fraction = excluded.coverage_fraction,
                gap_seconds = excluded.gap_seconds,
                counter_wrap_count = excluded.counter_wrap_count,
                rejected_delta_count = excluded.rejected_delta_count,
                first_sample_at = excluded.first_sample_at,
                last_sample_at = excluded.last_sample_at,
                source = excluded.source,
                algorithm_version = excluded.algorithm_version,
                derived_at = excluded.derived_at
            """

        for dateKey in dateKeys.sorted() {
            let grouped: [String: [WhoopStepCounterSample]]? =
                withCachedStatement(
                    database: database, sql: selectSQL
                ) { select in
                    bind(dateKey, to: 1, in: select)
                    var byPeripheral: [String: [WhoopStepCounterSample]] = [:]
                    var result = sqlite3_step(select)
                    while result == SQLITE_ROW {
                        if let peripheralID = textColumn(select, 0) {
                            byPeripheral[peripheralID, default: []].append(
                                WhoopStepCounterSample(
                                    timestamp: sqlite3_column_double(select, 1),
                                    counter: UInt16(truncatingIfNeeded: sqlite3_column_int(select, 2))
                                )
                            )
                        }
                        result = sqlite3_step(select)
                    }
                    return result == SQLITE_DONE ? byPeripheral : nil
                } ?? nil
            guard let byPeripheral = grouped else { return false }
            let candidates = byPeripheral.map { peripheralID, samples in
                (peripheralID, WhoopStepDaySummary.summarize(samples))
            }
            guard
                let chosen = candidates.max(by: { lhs, rhs in
                    if lhs.1.sampleCount == rhs.1.sampleCount {
                        return (lhs.1.lastSampleAt ?? 0) < (rhs.1.lastSampleAt ?? 0)
                    }
                    return lhs.1.sampleCount < rhs.1.sampleCount
                })
            else { continue }
            let summary = chosen.1
            let upserted =
                withCachedStatement(database: database, sql: upsertSQL) { upsert in
                    bind(dateKey, to: 1, in: upsert)
                    bind(chosen.0, to: 2, in: upsert)
                    sqlite3_bind_int64(upsert, 3, Int64(summary.stepCount))
                    sqlite3_bind_int64(upsert, 4, Int64(summary.sampleCount))
                    sqlite3_bind_int64(upsert, 5, Int64(summary.spanSeconds))
                    sqlite3_bind_double(upsert, 6, summary.coverageFraction)
                    sqlite3_bind_int64(upsert, 7, Int64(summary.gapSeconds))
                    sqlite3_bind_int64(upsert, 8, Int64(summary.counterWrapCount))
                    sqlite3_bind_int64(upsert, 9, Int64(summary.rejectedDeltaCount))
                    bind(summary.firstSampleAt, to: 10, in: upsert)
                    bind(summary.lastSampleAt, to: 11, in: upsert)
                    sqlite3_bind_int(upsert, 12, Int32(WhoopStepDaySummary.algorithmVersion))
                    sqlite3_bind_double(upsert, 13, Date().timeIntervalSince1970)
                    return sqlite3_step(upsert) == SQLITE_DONE
                } ?? false
            guard upserted else { return false }
        }
        return true
    }

    /// Runs in the packet transaction so a history-complete acknowledgement
    /// cannot become durable before its UI-facing totals do.
    func materializePendingStepsIfNeeded(
        metadata: WhoopHistoricalMetadata?,
        database: OpaquePointer
    ) -> Set<String>? {
        guard metadata?.type == .historyComplete else { return [] }
        let changedDays = pendingStepDateKeys
        return rebuildDailySteps(for: changedDays, database: database) ? changedDays : nil
    }

    func finishCommittedStepMaterialization(_ changedDays: Set<String>) {
        guard !changedDays.isEmpty else { return }
        pendingStepDateKeys.subtract(changedDays)
        rebuildRecoveryMetricsIfNeeded(force: true)
        publishStepUpdate()
    }

    func publishStepUpdate() {
        DispatchQueue.main.async {
            WhoopHealthHistoryEvents.post(.projectionsChanged)
        }
    }

    func metadataValue(database: OpaquePointer, key: String) -> String? {
        let sql = "SELECT value FROM whoop_store_metadata WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, 0)
    }

    func setMetadataValue(database: OpaquePointer, key: String, value: String) -> Bool {
        StoreMetadataRepository().set(database: database, key: key, value: value)
    }
}
