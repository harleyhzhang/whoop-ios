import Foundation
import SQLite3

/// Read-only dashboard queries. The caller supplies the queue-confined SQLite
/// connection and, when a coherent multi-table snapshot is required, owns the
/// surrounding transaction.
struct DashboardRepository {
    private let strainRepository = LocalStrainRepository()
    func loadSnapshot(database: OpaquePointer) throws -> DashboardHistorySnapshot {
        let health = try loadDailyHealthRecords(database: database)
        let strain = try strainRepository.load(
            database: database, health: health,
            model: WhoopStrainModel.load())
        return DashboardHistorySnapshot(
            healthRecords: health,
            stepRecords: try loadDailyStepRecords(database: database),
            recoveryRecords: try loadDailyRecoveryRecords(database: database),
            strainRecords: strain.records,
            strainDerivations: strain.derivations
        )
    }

    func loadDailyHealthRecords(database: OpaquePointer) throws -> [DailyHealthRecord] {
        let sql = """
            SELECT d.date_key, d.sleep_score,
                   COALESCE(o.official_recovery_score, r.score),
                   CASE WHEN o.official_recovery_score IS NOT NULL
                        THEN 'whoop_private_ios_api'
                        WHEN r.score IS NOT NULL THEN r.model_version END,
                   d.sleep_duration_minutes, d.hrv_rmssd_milliseconds,
                   d.resting_heart_rate_bpm, d.sleep_id, d.cycle_id,
                   d.source, d.source_archive, d.source_updated_at,
                   d.sleep_start_at, d.sleep_end_at, d.sleep_start_minute,
                   d.sleep_end_minute, d.sleep_need_minutes,
                   d.sleep_consistency_percentage,
                   d.sleep_efficiency_percentage, d.sleep_sufficiency_percentage
            FROM daily_health_metric d
            LEFT JOIN whoop_official_daily_metric o ON o.date_key = d.date_key
            LEFT JOIN whoop_daily_recovery_metric r ON r.date_key = d.date_key
            WHERE d.source NOT LIKE 'whoop5_local_%'
               OR (d.sleep_score IS NOT NULL
                   AND d.sleep_duration_minutes IS NOT NULL
                   AND d.hrv_rmssd_milliseconds IS NOT NULL
                   AND d.resting_heart_rate_bpm IS NOT NULL)
            ORDER BY d.date_key ASC
            """
        return try withStatement(database: database, sql: sql) { statement in
            var records: [DailyHealthRecord] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let record = dailyHealthRecord(from: statement) {
                    records.append(record)
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw QueryError.failed(errorMessage(database))
            }
            return records
        }
    }

    func loadDailyStepRecords(database: OpaquePointer) throws -> [DailyStepRecord] {
        let sql = """
            SELECT date_key, step_count, sample_count, span_seconds,
                   coverage_fraction, gap_seconds, counter_wrap_count,
                   rejected_delta_count, first_sample_at, last_sample_at,
                   source, algorithm_version
            FROM (
                SELECT o.date_key, o.official_steps AS step_count,
                       0 AS sample_count, 0 AS span_seconds,
                       1.0 AS coverage_fraction, 0 AS gap_seconds,
                       0 AS counter_wrap_count, 0 AS rejected_delta_count,
                       NULL AS first_sample_at, NULL AS last_sample_at,
                       'whoop_private_ios_api' AS source, 1 AS algorithm_version
                FROM whoop_official_daily_metric o
                WHERE o.official_steps IS NOT NULL
                UNION ALL
                SELECT l.date_key, l.step_count, l.sample_count, l.span_seconds,
                       l.coverage_fraction, l.gap_seconds, l.counter_wrap_count,
                       l.rejected_delta_count, l.first_sample_at, l.last_sample_at,
                       l.source, l.algorithm_version
                FROM whoop_daily_step_metric l
                WHERE NOT EXISTS (
                    SELECT 1 FROM whoop_official_daily_metric o
                    WHERE o.date_key = l.date_key AND o.official_steps IS NOT NULL
                )
            )
            ORDER BY date_key ASC
            """
        return try withStatement(database: database, sql: sql) { statement in
            var records: [DailyStepRecord] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let dateKey = textColumn(statement, 0),
                    let source = textColumn(statement, 10)
                {
                    records.append(
                        DailyStepRecord(
                            dateKey: dateKey,
                            stepCount: Int(sqlite3_column_int64(statement, 1)),
                            sampleCount: Int(sqlite3_column_int64(statement, 2)),
                            spanSeconds: Int(sqlite3_column_int64(statement, 3)),
                            coverageFraction: sqlite3_column_double(statement, 4),
                            gapSeconds: Int(sqlite3_column_int64(statement, 5)),
                            counterWrapCount: Int(sqlite3_column_int64(statement, 6)),
                            rejectedDeltaCount: Int(sqlite3_column_int64(statement, 7)),
                            firstSampleAt: doubleColumn(statement, 8).map {
                                Date(timeIntervalSince1970: $0)
                            },
                            lastSampleAt: doubleColumn(statement, 9).map {
                                Date(timeIntervalSince1970: $0)
                            },
                            source: source,
                            algorithmVersion: Int(sqlite3_column_int(statement, 11))
                        ))
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw QueryError.failed(errorMessage(database))
            }
            return records
        }
    }

    func loadDailyRecoveryRecords(database: OpaquePointer) throws -> [DailyRecoveryRecord] {
        let sql = """
            SELECT date_key, score, source FROM (
                SELECT date_key, official_recovery_score AS score,
                       'whoop_private_ios_api' AS source
                FROM whoop_official_daily_metric
                WHERE official_recovery_score IS NOT NULL
                UNION ALL
                SELECT r.date_key, r.score, r.model_version
                FROM whoop_daily_recovery_metric r
                WHERE NOT EXISTS (
                    SELECT 1 FROM whoop_official_daily_metric o
                    WHERE o.date_key = r.date_key
                      AND o.official_recovery_score IS NOT NULL
                )
            )
            ORDER BY date_key ASC
            """
        return try withStatement(database: database, sql: sql) { statement in
            var records: [DailyRecoveryRecord] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let dateKey = textColumn(statement, 0),
                    let score = doubleColumn(statement, 1),
                    let source = textColumn(statement, 2)
                {
                    records.append(
                        DailyRecoveryRecord(
                            dateKey: dateKey, score: score, source: source
                        ))
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw QueryError.failed(errorMessage(database))
            }
            return records
        }
    }

    private func dailyHealthRecord(from statement: OpaquePointer) -> DailyHealthRecord? {
        guard let dateKey = textColumn(statement, 0),
            let source = textColumn(statement, 9),
            let sourceUpdatedAt = textColumn(statement, 11)
        else { return nil }
        return DailyHealthRecord(
            dateKey: dateKey,
            sleepScore: doubleColumn(statement, 1),
            recoveryScore: doubleColumn(statement, 2),
            recoveryScoreSource: textColumn(statement, 3),
            sleepDurationMinutes: doubleColumn(statement, 4),
            hrvRMSSDMilliseconds: doubleColumn(statement, 5),
            restingHeartRateBPM: doubleColumn(statement, 6),
            sleepID: textColumn(statement, 7),
            cycleID: int64Column(statement, 8),
            source: source,
            sourceArchive: textColumn(statement, 10),
            sourceUpdatedAt: sourceUpdatedAt,
            sleepStartAt: textColumn(statement, 12),
            sleepEndAt: textColumn(statement, 13),
            sleepStartMinute: doubleColumn(statement, 14),
            sleepEndMinute: doubleColumn(statement, 15),
            sleepNeedMinutes: doubleColumn(statement, 16),
            sleepConsistencyPercentage: doubleColumn(statement, 17),
            sleepEfficiencyPercentage: doubleColumn(statement, 18),
            sleepSufficiencyPercentage: doubleColumn(statement, 19)
        )
    }

    private func withStatement<Value>(
        database: OpaquePointer,
        sql: String,
        operation: (OpaquePointer) throws -> Value
    ) throws -> Value {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw QueryError.failed(errorMessage(database)) }
        defer { sqlite3_finalize(statement) }
        return try operation(statement)
    }

    private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let bytes = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: bytes)
    }

    private func doubleColumn(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func int64Column(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    enum QueryError: LocalizedError {
        case databaseUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable: "The local WHOOP database is unavailable."
            case .failed(let detail): "The WHOOP history query failed: \(detail)"
            }
        }
    }
}
