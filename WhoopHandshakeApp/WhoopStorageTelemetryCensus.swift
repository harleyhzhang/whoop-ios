import Foundation
import SQLite3

/// Expensive database census work. Production calls this on a dedicated
/// utility queue and a separate SQLite connection, never on packet ingestion.
enum WhoopStorageTelemetryCensus {
    private static let derivedTables = [
        "heart_rate_sample", "whoop_historical_sample", "whoop_packet_replay",
        "whoop_ppg_packet", "whoop_decode_failure", "whoop_offload_session",
        "daily_health_metric", "whoop_daily_step_metric", "whoop_daily_recovery_metric",
        "whoop_api_numeric_metric", "whoop_api_source_record", "whoop_time_zone_observation",
        "whoop_official_daily_metric", "whoop_latest_heart_rate",
    ]

    static func capture(
        databaseURL: URL,
        ingestion: WhoopIngestionLatencyWindow,
        persistenceFailureCount: Int64,
        censusFailureCount: Int64,
        now: Date
    ) -> WhoopStorageTelemetrySnapshot? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        return capture(
            database: database,
            databaseURL: databaseURL,
            ingestion: ingestion,
            persistenceFailureCount: persistenceFailureCount,
            censusFailureCount: censusFailureCount,
            now: now
        )
    }

    static func capture(
        database: OpaquePointer,
        databaseURL: URL,
        ingestion: WhoopIngestionLatencyWindow,
        persistenceFailureCount: Int64,
        censusFailureCount: Int64,
        now: Date
    ) -> WhoopStorageTelemetrySnapshot? {
        let censusStartedAt = DispatchTime.now().uptimeNanoseconds
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        var readTransactionOpen = true
        defer {
            if readTransactionOpen { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        }
        guard let schemaVersion = scalarInt(database, sql: "PRAGMA user_version"),
            let pageSize = scalarInt(database, sql: "PRAGMA page_size"),
            let pageCount = scalarInt(database, sql: "PRAGMA page_count"),
            let freelistPages = scalarInt(database, sql: "PRAGMA freelist_count"),
            let packetTotals = pair(
                database,
                sql: "SELECT COUNT(*), COALESCE(SUM(length(payload)), 0) FROM whoop_raw_packet"
            ),
            let sourceCount = scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM (SELECT DISTINCT peripheral_id, characteristic_uuid FROM whoop_raw_packet)"
            ),
            let frameRetries = readFrameRetries(database),
            let derivedRows = readDerivedRows(database)
        else { return nil }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { return nil }
        readTransactionOpen = false

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let sequenceBefore = walCheckpointSequence(at: walURL)
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let checkpointStartedAt = DispatchTime.now().uptimeNanoseconds
        let checkpointResult = sqlite3_wal_checkpoint_v2(
            database, nil, SQLITE_CHECKPOINT_PASSIVE, &logFrames, &checkpointedFrames
        )
        let checkpointDuration = DispatchTime.now().uptimeNanoseconds - checkpointStartedAt
        let fileSample = makeFileSample(databaseURL: databaseURL, now: now)
        let censusDuration = DispatchTime.now().uptimeNanoseconds - censusStartedAt
        return WhoopStorageTelemetrySnapshot(
            capturedAt: now.timeIntervalSince1970,
            schemaVersion: schemaVersion,
            sourceCommit: sourceCommit(),
            databaseBytes: fileSample.databaseBytes,
            walBytes: fileSample.walBytes,
            sharedMemoryBytes: fileSample.sharedMemoryBytes,
            pageSize: pageSize,
            pageCount: pageCount,
            freelistPages: freelistPages,
            usedDatabaseBytes: max(0, pageCount - freelistPages) * pageSize,
            uniquePackets: packetTotals.0,
            rawPayloadBytes: packetTotals.1,
            sourcePairCount: sourceCount,
            frameRetries: frameRetries,
            derivedTableRows: derivedRows,
            walCheckpointSequenceBefore: sequenceBefore,
            walCheckpointSequenceAfter: fileSample.walCheckpointSequence,
            passiveCheckpointResult: checkpointResult,
            walLogFrames: logFrames,
            walCheckpointedFrames: checkpointedFrames,
            passiveCheckpointNanoseconds: checkpointDuration,
            snapshotCollectionNanoseconds: censusDuration,
            persistenceFailureCount: persistenceFailureCount,
            censusFailureCount: censusFailureCount,
            ingestion: ingestion
        )
    }

    static func makeFileSample(databaseURL: URL, now: Date) -> WhoopStorageFileSample {
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        return WhoopStorageFileSample(
            capturedAt: now.timeIntervalSince1970,
            databaseBytes: fileSize(databaseURL),
            walBytes: fileSize(walURL),
            sharedMemoryBytes: fileSize(URL(fileURLWithPath: databaseURL.path + "-shm")),
            walCheckpointSequence: walCheckpointSequence(at: walURL)
        )
    }

    private static func readFrameRetries(_ database: OpaquePointer) -> [WhoopFrameRetryTelemetry]? {
        guard
            let uniqueRows = groupedCounts(
                database,
                sql:
                    "SELECT COALESCE(CAST(frame_type AS TEXT), 'unknown'), COUNT(*) FROM whoop_raw_packet GROUP BY frame_type"
            ),
            let eligibleRows = groupedPairs(
                database,
                sql: """
                    SELECT COALESCE(CAST(r.frame_type AS TEXT), 'unknown'),
                           COUNT(*), COALESCE(SUM(p.duplicate_count), 0)
                    FROM whoop_packet_replay p
                    JOIN whoop_raw_packet r ON r.id = p.first_packet_id
                    GROUP BY r.frame_type
                    """
            )
        else { return nil }
        return Set(uniqueRows.keys).union(eligibleRows.keys).sorted().map { frameType in
            WhoopFrameRetryTelemetry(
                frameType: frameType,
                allHistoricalUniquePackets: uniqueRows[frameType, default: 0],
                retryEligibleUniquePackets: eligibleRows[frameType]?.0 ?? 0,
                retries: eligibleRows[frameType]?.1 ?? 0
            )
        }
    }

    private static func readDerivedRows(_ database: OpaquePointer) -> [String: Int64]? {
        var result: [String: Int64] = [:]
        for table in derivedTables {
            guard let count = scalarInt(database, sql: "SELECT COUNT(*) FROM \(table)") else {
                return nil
            }
            result[table] = count
        }
        return result
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func pair(_ database: OpaquePointer, sql: String) -> (Int64, Int64)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
    }

    private static func groupedCounts(_ database: OpaquePointer, sql: String) -> [String: Int64]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [String: Int64] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawKey = sqlite3_column_text(statement, 0) else { return nil }
                result[String(cString: rawKey)] = sqlite3_column_int64(statement, 1)
            case SQLITE_DONE:
                return result
            default:
                return nil
            }
        }
    }

    private static func groupedPairs(
        _ database: OpaquePointer,
        sql: String
    ) -> [String: (Int64, Int64)]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [String: (Int64, Int64)] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawKey = sqlite3_column_text(statement, 0) else { return nil }
                result[String(cString: rawKey)] = (
                    sqlite3_column_int64(statement, 1), sqlite3_column_int64(statement, 2)
                )
            case SQLITE_DONE:
                return result
            default:
                return nil
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func sourceCommit() -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: "WHOOPSourceCommit") as? String
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? "development"
    }

    private static func walCheckpointSequence(at url: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else { return nil }
        let bytes = [UInt8](header)
        return bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
