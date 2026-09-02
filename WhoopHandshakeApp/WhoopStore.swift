import Foundation
import SQLite3

struct WhoopDecodedRealtime: Sendable {
    let deviceTimestamp: UInt32?
    let heartRate: Int
    let rrIntervals: [UInt16]
}

/// Append-only local evidence store for direct WHOOP packets and derived samples.
/// Raw frames are retained so later protocol improvements never require another capture.
final class WhoopStore: @unchecked Sendable {
    static let shared = WhoopStore()

    private let queue = DispatchQueue(label: "com.clintonst.sleep.whoop-store", qos: .utility)
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        queue.sync { openDatabase() }
    }

    deinit {
        queue.sync {
            if let database { sqlite3_close(database) }
        }
    }

    func append(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        frameType: UInt8?,
        realtime: WhoopDecodedRealtime?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            completion(insert(
                packet: packet,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                frameType: frameType,
                realtime: realtime
            ))
        }
    }

    func loadDailyHealthRecords(
        completion: @escaping @Sendable (Result<[DailyHealthRecord], Error>) -> Void
    ) {
        queue.async { [self] in
            guard let database else {
                completion(.failure(StoreError.databaseUnavailable))
                return
            }
            let sql = """
                SELECT date_key, sleep_score, sleep_duration_minutes,
                       hrv_rmssd_milliseconds, resting_heart_rate_bpm,
                       sleep_id, cycle_id, source, source_archive, source_updated_at
                FROM daily_health_metric
                ORDER BY date_key ASC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                completion(.failure(StoreError.queryFailed(errorMessage(database))))
                return
            }
            defer { sqlite3_finalize(statement) }

            var records: [DailyHealthRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let dateKey = textColumn(statement, 0),
                      let source = textColumn(statement, 7),
                      let sourceUpdatedAt = textColumn(statement, 9) else { continue }
                records.append(DailyHealthRecord(
                    dateKey: dateKey,
                    sleepScore: doubleColumn(statement, 1),
                    sleepDurationMinutes: doubleColumn(statement, 2),
                    hrvRMSSDMilliseconds: doubleColumn(statement, 3),
                    restingHeartRateBPM: doubleColumn(statement, 4),
                    sleepID: textColumn(statement, 5),
                    cycleID: int64Column(statement, 6),
                    source: source,
                    sourceArchive: textColumn(statement, 8),
                    sourceUpdatedAt: sourceUpdatedAt
                ))
            }
            completion(.success(records))
        }
    }

    private func openDatabase() {
        let fileManager = FileManager.default
        do {
            let directory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Sleep", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("sleep.sqlite3")
            guard sqlite3_open_v2(
                url.path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK else {
                database = nil
                return
            }
            execute("PRAGMA journal_mode=WAL")
            execute("PRAGMA foreign_keys=ON")
            execute("""
                CREATE TABLE IF NOT EXISTS whoop_raw_packet (
                    id TEXT PRIMARY KEY,
                    received_at REAL NOT NULL,
                    peripheral_id TEXT NOT NULL,
                    characteristic_uuid TEXT NOT NULL,
                    frame_type INTEGER,
                    payload BLOB NOT NULL
                )
                """)
            execute("CREATE INDEX IF NOT EXISTS whoop_raw_packet_received_at ON whoop_raw_packet(received_at)")
            execute("""
                CREATE TABLE IF NOT EXISTS heart_rate_sample (
                    id TEXT PRIMARY KEY,
                    source_packet_id TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    device_timestamp INTEGER,
                    heart_rate INTEGER NOT NULL,
                    rr_intervals_json TEXT NOT NULL,
                    source TEXT NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                )
                """)
            execute("CREATE INDEX IF NOT EXISTS heart_rate_sample_received_at ON heart_rate_sample(received_at)")
            execute("""
                CREATE TABLE IF NOT EXISTS daily_health_metric (
                    date_key TEXT PRIMARY KEY,
                    sleep_score REAL,
                    sleep_duration_minutes REAL,
                    hrv_rmssd_milliseconds REAL,
                    resting_heart_rate_bpm REAL,
                    sleep_id TEXT,
                    cycle_id INTEGER,
                    source TEXT NOT NULL,
                    source_archive TEXT,
                    source_updated_at TEXT NOT NULL,
                    imported_at REAL NOT NULL
                )
                """)
            importBundledHistory()
        } catch {
            database = nil
        }
    }

    private func importBundledHistory() {
        guard let database,
              let url = Bundle.main.url(forResource: "whoop-history", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([DailyHealthRecord].self, from: data) else { return }
        execute("BEGIN IMMEDIATE")
        for record in records where !upsertDailyHealthRecord(record, database: database) {
            execute("ROLLBACK")
            return
        }
        execute("COMMIT")
    }

    private func upsertDailyHealthRecord(_ record: DailyHealthRecord, database: OpaquePointer) -> Bool {
        let sql = """
            INSERT INTO daily_health_metric
            (date_key, sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
             resting_heart_rate_bpm, sleep_id, cycle_id, source, source_archive,
             source_updated_at, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                sleep_score = excluded.sleep_score,
                sleep_duration_minutes = excluded.sleep_duration_minutes,
                hrv_rmssd_milliseconds = excluded.hrv_rmssd_milliseconds,
                resting_heart_rate_bpm = excluded.resting_heart_rate_bpm,
                sleep_id = excluded.sleep_id,
                cycle_id = excluded.cycle_id,
                source = excluded.source,
                source_archive = excluded.source_archive,
                source_updated_at = excluded.source_updated_at,
                imported_at = excluded.imported_at
            WHERE daily_health_metric.source = 'whoop_api'
              AND excluded.source_updated_at >= daily_health_metric.source_updated_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.dateKey, to: 1, in: statement)
        bind(record.sleepScore, to: 2, in: statement)
        bind(record.sleepDurationMinutes, to: 3, in: statement)
        bind(record.hrvRMSSDMilliseconds, to: 4, in: statement)
        bind(record.restingHeartRateBPM, to: 5, in: statement)
        bind(record.sleepID, to: 6, in: statement)
        bind(record.cycleID, to: 7, in: statement)
        bind(record.source, to: 8, in: statement)
        bind(record.sourceArchive, to: 9, in: statement)
        bind(record.sourceUpdatedAt, to: 10, in: statement)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func execute(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func insert(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        frameType: UInt8?,
        realtime: WhoopDecodedRealtime?
    ) -> Bool {
        guard let database else { return false }
        let packetID = UUID().uuidString
        let receivedAt = Date().timeIntervalSince1970
        execute("BEGIN IMMEDIATE")
        guard insertPacket(
            database: database,
            id: packetID,
            receivedAt: receivedAt,
            peripheralID: peripheralID.uuidString,
            characteristicUUID: characteristicUUID,
            frameType: frameType,
            payload: packet
        ) else {
            execute("ROLLBACK")
            return false
        }
        if let realtime,
           !insertRealtime(database: database, packetID: packetID, receivedAt: receivedAt, realtime: realtime) {
            execute("ROLLBACK")
            return false
        }
        execute("COMMIT")
        return true
    }

    private func insertPacket(
        database: OpaquePointer,
        id: String,
        receivedAt: TimeInterval,
        peripheralID: String,
        characteristicUUID: String,
        frameType: UInt8?,
        payload: Data
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_raw_packet
            (id, received_at, peripheral_id, characteristic_uuid, frame_type, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, receivedAt)
        bind(peripheralID, to: 3, in: statement)
        bind(characteristicUUID, to: 4, in: statement)
        if let frameType {
            sqlite3_bind_int(statement, 5, Int32(frameType))
        } else {
            sqlite3_bind_null(statement, 5)
        }
        _ = payload.withUnsafeBytes {
            sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), Self.transient)
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func insertRealtime(
        database: OpaquePointer,
        packetID: String,
        receivedAt: TimeInterval,
        realtime: WhoopDecodedRealtime
    ) -> Bool {
        let sql = """
            INSERT INTO heart_rate_sample
            (id, source_packet_id, received_at, device_timestamp, heart_rate, rr_intervals_json, source)
            VALUES (?, ?, ?, ?, ?, ?, 'whoop5_type40')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(UUID().uuidString, to: 1, in: statement)
        bind(packetID, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, receivedAt)
        if let timestamp = realtime.deviceTimestamp {
            sqlite3_bind_int64(statement, 4, sqlite3_int64(timestamp))
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int(statement, 5, Int32(realtime.heartRate))
        let rrJSON = "[" + realtime.rrIntervals.map(String.init).joined(separator: ",") + "]"
        bind(rrJSON, to: 6, in: statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bind(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, index) else { return nil }
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

    private enum StoreError: LocalizedError {
        case databaseUnavailable
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable: "The local WHOOP database is unavailable."
            case .queryFailed(let detail): "The WHOOP history query failed: \(detail)"
            }
        }
    }
}
