import CryptoKit
import Foundation
import SQLite3

enum WhoopFrameIntegrity {
    static func isValid(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0] == 0xAA,
              Int(UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)) + 8 == bytes.count else {
            return false
        }
        let expectedHeader = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        guard crc16Modbus(bytes[0..<6]) == expectedHeader else { return false }
        let payloadEnd = bytes.count - 4
        let expected = UInt32(bytes[payloadEnd])
            | (UInt32(bytes[payloadEnd + 1]) << 8)
            | (UInt32(bytes[payloadEnd + 2]) << 16)
            | (UInt32(bytes[payloadEnd + 3]) << 24)
        return crc32(bytes[8..<payloadEnd]) == expected
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func crc16Modbus<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

struct WhoopDecodedRealtime: Sendable {
    let deviceTimestamp: UInt32?
    let heartRate: Int
    let rrIntervals: [UInt16]
}

struct WhoopDecodedHistorical: Sendable {
    let sampleAt: Date
    let heartRate: Int
    let rrIntervals: [UInt16]
    let sleepState: Int

    /// WHOOP 5 v18 offsets cross-checked against the independent NOOP and Goose
    /// implementations before enabling the destructive-on-ACK history trim.
    /// https://github.com/ryanbr/noop/blob/main/docs/BLE_REVERSE_ENGINEERING.md
    static func decode(_ data: Data) -> WhoopDecodedHistorical? {
        let bytes = [UInt8](data)
        guard bytes.count == 124,
              bytes[8] == 47,
              bytes[9] == 18,
              WhoopFrameIntegrity.isValid(data) else { return nil }
        let timestamp = UInt32(bytes[15])
            | (UInt32(bytes[16]) << 8)
            | (UInt32(bytes[17]) << 16)
            | (UInt32(bytes[18]) << 24)
        let count = min(Int(bytes[23]), 4)
        var intervals: [UInt16] = []
        for index in 0..<count {
            let offset = 24 + index * 2
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            if value > 0 { intervals.append(value) }
        }
        return WhoopDecodedHistorical(
            sampleAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            heartRate: Int(bytes[22]),
            rrIntervals: intervals,
            sleepState: Int((bytes[81] >> 4) & 3)
        )
    }

    /// Why a stored type-47 packet did not become a historical sample. Used by
    /// the diagnostics to tell sparse strap data apart from frames this app
    /// silently drops after the destructive chunk acknowledgement.
    static func decodeFailureReason(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return "shorter than 10 bytes" }
        if bytes.count != 124 { return "length \(bytes.count), expected 124" }
        if bytes[8] != 47 { return "type \(bytes[8]), expected 47" }
        if bytes[9] != 18 { return "version \(bytes[9]), expected 18" }
        if !WhoopFrameIntegrity.isValid(data) { return "CRC mismatch" }
        return "decodes"
    }
}

struct WhoopDecodedPPG: Sendable, Equatable {
    let sampleAt: Date
    let channel: Int
    let samples: [Int16]

    /// WHOOP 5 v26 is one second of 24 Hz AC-coupled optical data. Channel is
    /// retained as the firmware's raw non-zero index; no LED colour or
    /// physiological unit is invented. Harley's current firmware uses values
    /// beyond the 1...26 range seen in the original reference captures.
    static func decode(_ data: Data) -> WhoopDecodedPPG? {
        let bytes = [UInt8](data)
        guard bytes.count == 88,
              bytes[8] == 47,
              bytes[9] == 26,
              bytes[21] != 0,
              WhoopFrameIntegrity.isValid(data) else { return nil }
        let timestamp = UInt32(bytes[15])
            | (UInt32(bytes[16]) << 8)
            | (UInt32(bytes[17]) << 16)
            | (UInt32(bytes[18]) << 24)
        var samples: [Int16] = []
        samples.reserveCapacity(24)
        for offset in stride(from: 27, to: 75, by: 2) {
            let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Int16(bitPattern: raw))
        }
        return WhoopDecodedPPG(
            sampleAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            channel: Int(bytes[21]),
            samples: samples
        )
    }
}

struct WhoopSleepSnapshot: Sendable {
    let isSleeping: Bool
    let sampleAt: Date?
    let finalizedRecord: DailyHealthRecord?
    /// A main sleep the strap has detected but has not atomically stored with
    /// all four primary metrics yet. Non-nil is exactly the condition the
    /// dashboard reports as "Sleep detected".
    let pendingSleep: WhoopPendingSleep?
}

struct WhoopPendingSleep: Sendable, Equatable {
    let sleepID: String
    let startedAt: Date
    let endedAt: Date
    let durationMinutes: Double
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

enum WhoopSleepProcessError: Error, Sendable {
    case storeUnavailable
    case noRecentData
    case stillAsleep
    case noSleepDetected
    case insufficientEvidence
    case historyStillLoading
    case metricsStillLoading
    case writeFailed

    var message: String {
        switch self {
        case .storeUnavailable: return "Local store unavailable"
        case .noRecentData: return "No recent strap data"
        case .stillAsleep: return "Still asleep"
        case .noSleepDetected: return "No sleep detected"
        case .insufficientEvidence: return "Not enough data to score"
        case .historyStillLoading: return "Still receiving sleep history"
        case .metricsStillLoading: return "Still receiving sleep data"
        case .writeFailed: return "Could not save"
        }
    }
}

struct WhoopLatestHeartRateSample: Sendable {
    let heartRate: Int
    let receivedAt: Date
}

/// Append-only local evidence store for direct WHOOP packets and derived samples.
/// Raw frames are retained so later protocol improvements never require another capture.
final class WhoopStore: @unchecked Sendable {
    static let shared = WhoopStore()

    private let queue = DispatchQueue(label: "com.clintonst.sleep.whoop-store", qos: .utility)
    private let databaseURLOverride: URL?
    private var database: OpaquePointer?
    private var nextDeliverySequence: Int64 = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let schemaVersion = 2
    private static let decoderVersion = 2

    init(databaseURL: URL? = nil, runBackgroundDecoding: Bool = true) {
        databaseURLOverride = databaseURL
        queue.sync { openDatabase() }
        if runBackgroundDecoding {
            queue.async { [self] in backfillVersion26PPG() }
        }
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
        historical: WhoopDecodedHistorical?,
        deliveredAt: Date = .now,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            completion(insert(
                packet: packet,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                frameType: frameType,
                realtime: realtime,
                historical: historical,
                deliveredAt: deliveredAt
            ))
        }
    }

    func refreshSleepSnapshot(
        allowAutomaticFinalization: Bool = false,
        completion: @escaping @Sendable (WhoopSleepSnapshot) -> Void
    ) {
        queue.async { [self] in
            completion(analyzeLatestSleep(allowAutomaticFinalization: allowAutomaticFinalization))
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
                WHERE source NOT LIKE 'whoop5_local_%'
                   OR (sleep_score IS NOT NULL
                       AND sleep_duration_minutes IS NOT NULL
                       AND hrv_rmssd_milliseconds IS NOT NULL
                       AND resting_heart_rate_bpm IS NOT NULL)
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
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let dateKey = textColumn(statement, 0),
                      let source = textColumn(statement, 7),
                      let sourceUpdatedAt = textColumn(statement, 9) else {
                    stepResult = sqlite3_step(statement)
                    continue
                }
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
                stepResult = sqlite3_step(statement)
            }
            guard stepResult == SQLITE_DONE else {
                completion(.failure(StoreError.queryFailed(errorMessage(database))))
                return
            }
            completion(.success(records))
        }
    }

    func loadLatestHeartRateSample(
        completion: @escaping @Sendable (WhoopLatestHeartRateSample?) -> Void
    ) {
        queue.async { [self] in
            guard let database else {
                completion(nil)
                return
            }
            let sql = """
                SELECT heart_rate, received_at
                FROM heart_rate_sample
                ORDER BY received_at DESC
                LIMIT 1
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                completion(nil)
                return
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                completion(nil)
                return
            }
            completion(
                WhoopLatestHeartRateSample(
                    heartRate: Int(sqlite3_column_int(statement, 0)),
                    receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                )
            )
        }
    }

    static func databaseDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("Sleep", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func openDatabase() {
        let url: URL
        if let databaseURLOverride {
            url = databaseURLOverride
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            guard let directory = Self.databaseDirectory() else { return }
            url = directory.appendingPathComponent("sleep.sqlite3")
        }
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            return
        }
        let opened = execute("PRAGMA journal_mode=WAL")
            && execute("PRAGMA foreign_keys=ON")
            && execute("PRAGMA busy_timeout=5000")
            && migrateSchema()
        guard opened else {
            if let database { sqlite3_close(database) }
            database = nil
            return
        }
        nextDeliverySequence = ((try? scalarInt(
            database!,
            sql: "SELECT COALESCE(MAX(delivery_sequence), 0) FROM whoop_raw_packet"
        )) ?? 0) + 1
        backfillHistoricalSamplesIfNeeded()
        if databaseURLOverride == nil { importBundledHistory() }
    }

    private func migrateSchema() -> Bool {
        guard let database,
              let current = try? scalarInt(database, sql: "PRAGMA user_version"),
              current <= Self.schemaVersion else { return false }
        guard current < Self.schemaVersion else { return true }
        for version in (Int(current) + 1)...Self.schemaVersion {
            guard execute("BEGIN IMMEDIATE"), applyMigration(version) else {
                execute("ROLLBACK")
                return false
            }
            guard execute("PRAGMA user_version = \(version)"), execute("COMMIT") else {
                execute("ROLLBACK")
                return false
            }
        }
        return true
    }

    private func applyMigration(_ version: Int) -> Bool {
        switch version {
        case 1:
            return execute("""
                CREATE TABLE IF NOT EXISTS whoop_raw_packet (
                    id TEXT PRIMARY KEY,
                    received_at REAL NOT NULL,
                    peripheral_id TEXT NOT NULL,
                    characteristic_uuid TEXT NOT NULL,
                    frame_type INTEGER,
                    payload BLOB NOT NULL
                )
                """)
            && execute("CREATE INDEX IF NOT EXISTS whoop_raw_packet_received_at ON whoop_raw_packet(received_at)")
            && execute("""
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
            && execute("CREATE INDEX IF NOT EXISTS heart_rate_sample_received_at ON heart_rate_sample(received_at)")
            && execute("""
                CREATE TABLE IF NOT EXISTS whoop_historical_sample (
                    sample_at REAL PRIMARY KEY,
                    source_packet_id TEXT NOT NULL,
                    heart_rate INTEGER NOT NULL,
                    rr_intervals_json TEXT NOT NULL,
                    sleep_state INTEGER NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                )
                """)
            && execute("CREATE INDEX IF NOT EXISTS whoop_historical_sample_sleep_state ON whoop_historical_sample(sleep_state, sample_at)")
            && execute("""
                CREATE TABLE IF NOT EXISTS whoop_packet_replay (
                    signature BLOB PRIMARY KEY,
                    first_packet_id TEXT NOT NULL,
                    duplicate_count INTEGER NOT NULL DEFAULT 0,
                    last_received_at REAL NOT NULL
                )
                """)
            && execute("""
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
        case 2:
            return addColumnIfNeeded(
                table: "whoop_raw_packet",
                column: "delivery_sequence",
                declaration: "INTEGER"
            )
            && addColumnIfNeeded(
                table: "whoop_raw_packet",
                column: "protocol_version",
                declaration: "INTEGER"
            )
            && addColumnIfNeeded(
                table: "whoop_raw_packet",
                column: "crc_valid",
                declaration: "INTEGER"
            )
            && execute("CREATE INDEX IF NOT EXISTS whoop_raw_packet_delivery_sequence ON whoop_raw_packet(delivery_sequence)")
            && execute("""
                CREATE TABLE IF NOT EXISTS whoop_decode_result (
                    source_packet_id TEXT NOT NULL,
                    decoder_version INTEGER NOT NULL,
                    protocol_version INTEGER,
                    stream TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error TEXT,
                    decoded_at REAL NOT NULL,
                    PRIMARY KEY(source_packet_id, decoder_version),
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                )
                """)
            && execute("CREATE INDEX IF NOT EXISTS whoop_decode_result_status ON whoop_decode_result(decoder_version, status)")
            && execute("""
                CREATE TABLE IF NOT EXISTS whoop_ppg_packet (
                    source_packet_id TEXT PRIMARY KEY,
                    sample_at REAL NOT NULL,
                    channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 255),
                    sample_rate_hz REAL NOT NULL,
                    samples_i16_le BLOB NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                )
                """)
            && execute("CREATE INDEX IF NOT EXISTS whoop_ppg_packet_sample_at ON whoop_ppg_packet(sample_at, channel)")
            && execute("""
                CREATE TABLE IF NOT EXISTS whoop_store_metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """)
        default:
            return false
        }
    }

    private func addColumnIfNeeded(
        table: String,
        column: String,
        declaration: String
    ) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if textColumn(statement, 1) == column { return true }
        }
        return execute("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
    }

    private func importBundledHistory() {
        guard let database,
              let url = Bundle.main.url(forResource: "whoop-history", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([DailyHealthRecord].self, from: data) else { return }
        guard execute("BEGIN IMMEDIATE") else { return }
        for record in records where !upsertDailyHealthRecord(record, database: database) {
            execute("ROLLBACK")
            return
        }
        guard execute("COMMIT") else { execute("ROLLBACK"); return }
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

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let database else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func insert(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        frameType: UInt8?,
        realtime: WhoopDecodedRealtime?,
        historical: WhoopDecodedHistorical?,
        deliveredAt: Date
    ) -> Bool {
        guard let database else { return false }
        let packetID = UUID().uuidString
        let receivedAt = deliveredAt.timeIntervalSince1970
        let deliverySequence = nextDeliverySequence
        nextDeliverySequence += 1
        let signature = Self.packetSignature(
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            payload: packet
        )
        guard execute("BEGIN IMMEDIATE") else { return false }
        switch registerPacketSignature(
            database: database,
            signature: signature,
            packetID: packetID,
            receivedAt: receivedAt
        ) {
        case .duplicate(let canonicalPacketID):
            guard decodePacketIfNeeded(
                database: database,
                packetID: canonicalPacketID,
                packet: packet,
                historical: historical
            ) else {
                execute("ROLLBACK")
                return false
            }
            guard execute("COMMIT") else { execute("ROLLBACK"); return false }
            return true
        case .new:
            break
        case .failed:
            execute("ROLLBACK")
            return false
        }
        guard insertPacket(
            database: database,
            id: packetID,
            receivedAt: receivedAt,
            deliverySequence: deliverySequence,
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
        guard decodePacketIfNeeded(
            database: database,
            packetID: packetID,
            packet: packet,
            historical: historical
        ) else {
            execute("ROLLBACK")
            return false
        }
        guard execute("COMMIT") else { execute("ROLLBACK"); return false }
        return true
    }

    private enum PacketSignatureRegistration {
        case new
        case duplicate(String)
        case failed
    }

    /// Exact BLE transport retries contain no new evidence. Keep the first raw
    /// frame losslessly and aggregate later identical deliveries so a stuck
    /// history acknowledgement cannot grow the database by hundreds of MB.
    private func registerPacketSignature(
        database: OpaquePointer,
        signature: Data,
        packetID: String,
        receivedAt: TimeInterval
    ) -> PacketSignatureRegistration {
        let updateSQL = """
            UPDATE whoop_packet_replay
            SET duplicate_count = duplicate_count + 1, last_received_at = ?
            WHERE signature = ?
            """
        var update: OpaquePointer?
        guard sqlite3_prepare_v2(database, updateSQL, -1, &update, nil) == SQLITE_OK,
              let update else { return .failed }
        sqlite3_bind_double(update, 1, receivedAt)
        bind(signature, to: 2, in: update)
        let updateResult = sqlite3_step(update)
        sqlite3_finalize(update)
        guard updateResult == SQLITE_DONE else { return .failed }
        if sqlite3_changes(database) > 0 {
            let selectSQL = "SELECT first_packet_id FROM whoop_packet_replay WHERE signature = ?"
            var select: OpaquePointer?
            guard sqlite3_prepare_v2(database, selectSQL, -1, &select, nil) == SQLITE_OK,
                  let select else { return .failed }
            defer { sqlite3_finalize(select) }
            bind(signature, to: 1, in: select)
            guard sqlite3_step(select) == SQLITE_ROW,
                  let packetID = textColumn(select, 0) else { return .failed }
            return .duplicate(packetID)
        }

        let insertSQL = """
            INSERT INTO whoop_packet_replay
            (signature, first_packet_id, duplicate_count, last_received_at)
            VALUES (?, ?, 0, ?)
            """
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(database, insertSQL, -1, &insert, nil) == SQLITE_OK,
              let insert else { return .failed }
        defer { sqlite3_finalize(insert) }
        bind(signature, to: 1, in: insert)
        bind(packetID, to: 2, in: insert)
        sqlite3_bind_double(insert, 3, receivedAt)
        return sqlite3_step(insert) == SQLITE_DONE ? .new : .failed
    }

    static func packetSignature(
        peripheralID: UUID,
        characteristicUUID: String,
        payload: Data
    ) -> Data {
        var input = Data(peripheralID.uuidString.lowercased().utf8)
        input.append(0)
        input.append(contentsOf: characteristicUUID.uppercased().utf8)
        input.append(0)
        input.append(payload)
        return Data(SHA256.hash(data: input))
    }

    private func insertPacket(
        database: OpaquePointer,
        id: String,
        receivedAt: TimeInterval,
        deliverySequence: Int64,
        peripheralID: String,
        characteristicUUID: String,
        frameType: UInt8?,
        payload: Data
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_raw_packet
            (id, received_at, delivery_sequence, peripheral_id,
             characteristic_uuid, frame_type, protocol_version, crc_valid, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, receivedAt)
        sqlite3_bind_int64(statement, 3, deliverySequence)
        bind(peripheralID, to: 4, in: statement)
        bind(characteristicUUID, to: 5, in: statement)
        if let frameType {
            sqlite3_bind_int(statement, 6, Int32(frameType))
        } else {
            sqlite3_bind_null(statement, 6)
        }
        if payload.count > 9 {
            sqlite3_bind_int(statement, 7, Int32(payload[9]))
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_int(statement, 8, WhoopFrameIntegrity.isValid(payload) ? 1 : 0)
        _ = payload.withUnsafeBytes {
            sqlite3_bind_blob(statement, 9, $0.baseAddress, Int32($0.count), Self.transient)
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func decodePacketIfNeeded(
        database: OpaquePointer,
        packetID: String,
        packet: Data,
        historical: WhoopDecodedHistorical?
    ) -> Bool {
        guard packet.count > 9, packet[8] == 47 else { return true }
        if decodeResultExists(database: database, packetID: packetID) { return true }
        let protocolVersion = Int(packet[9])
        let stream: String
        let status: String
        let error: String?

        if let historical = historical ?? WhoopDecodedHistorical.decode(packet) {
            guard insertHistorical(database: database, packetID: packetID, sample: historical) else {
                return false
            }
            stream = "historical_summary"
            status = "decoded"
            error = nil
        } else if let ppg = WhoopDecodedPPG.decode(packet) {
            guard insertPPG(database: database, packetID: packetID, packet: ppg) else {
                return false
            }
            stream = "optical_ppg"
            status = "decoded"
            error = nil
        } else {
            stream = "historical_unknown"
            status = WhoopFrameIntegrity.isValid(packet) ? "unsupported" : "rejected"
            error = WhoopFrameIntegrity.isValid(packet)
                ? "unsupported type-47 version \(protocolVersion), length \(packet.count)"
                : "CRC mismatch"
        }
        return insertDecodeResult(
            database: database,
            packetID: packetID,
            protocolVersion: protocolVersion,
            stream: stream,
            status: status,
            error: error
        )
    }

    private func decodeResultExists(database: OpaquePointer, packetID: String) -> Bool {
        let sql = "SELECT 1 FROM whoop_decode_result WHERE source_packet_id = ? AND decoder_version = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(packetID, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(Self.decoderVersion))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func insertDecodeResult(
        database: OpaquePointer,
        packetID: String,
        protocolVersion: Int,
        stream: String,
        status: String,
        error: String?
    ) -> Bool {
        let sql = """
            INSERT OR IGNORE INTO whoop_decode_result
            (source_packet_id, decoder_version, protocol_version, stream, status, error, decoded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(packetID, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(Self.decoderVersion))
        sqlite3_bind_int(statement, 3, Int32(protocolVersion))
        bind(stream, to: 4, in: statement)
        bind(status, to: 5, in: statement)
        bind(error, to: 6, in: statement)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func insertPPG(
        database: OpaquePointer,
        packetID: String,
        packet: WhoopDecodedPPG
    ) -> Bool {
        var samples = Data(capacity: packet.samples.count * 2)
        for sample in packet.samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { samples.append(contentsOf: $0) }
        }
        let sql = """
            INSERT OR IGNORE INTO whoop_ppg_packet
            (source_packet_id, sample_at, channel, sample_rate_hz, samples_i16_le)
            VALUES (?, ?, ?, 24, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(packetID, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, packet.sampleAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(packet.channel))
        bind(samples, to: 4, in: statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Decoder upgrades are replayed from immutable raw evidence. The legacy
    /// v18 summary table was already backfilled by schema v1; decoder v2 adds
    /// the previously ignored v26 optical stream in bounded transactions so a
    /// large phone database remains responsive during migration.
    private func backfillVersion26PPG(cursor: Int64 = 0, batchSize: Int = 500) {
        guard let database,
              metadataValue(database: database, key: "decoder-2-v26-backfill") != "complete" else {
            return
        }
        let sql = """
            SELECT rowid, id, payload
            FROM whoop_raw_packet
            WHERE rowid > ?
              AND frame_type = 47
              AND length(payload) = 88
              AND hex(substr(payload, 10, 1)) = '1A'
            ORDER BY rowid
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int(statement, 2, Int32(batchSize))
        var rows: [(Int64, String, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = textColumn(statement, 1), let payload = dataColumn(statement, 2) {
                rows.append((sqlite3_column_int64(statement, 0), id, payload))
            }
        }
        sqlite3_finalize(statement)

        guard !rows.isEmpty else {
            _ = setMetadataValue(
                database: database,
                key: "decoder-2-v26-backfill",
                value: "complete"
            )
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for (_, packetID, payload) in rows {
            guard decodePacketIfNeeded(
                database: database,
                packetID: packetID,
                packet: payload,
                historical: nil
            ) else {
                execute("ROLLBACK")
                return
            }
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
        let nextCursor = rows.last!.0
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
            backfillVersion26PPG(cursor: nextCursor, batchSize: batchSize)
        }
    }

    private func metadataValue(database: OpaquePointer, key: String) -> String? {
        let sql = "SELECT value FROM whoop_store_metadata WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, 0)
    }

    private func setMetadataValue(
        database: OpaquePointer,
        key: String,
        value: String
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_store_metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        bind(value, to: 2, in: statement)
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

    private func insertHistorical(
        database: OpaquePointer,
        packetID: String,
        sample: WhoopDecodedHistorical
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_historical_sample
            (sample_at, source_packet_id, heart_rate, rr_intervals_json, sleep_state)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(sample_at) DO UPDATE SET
                source_packet_id = excluded.source_packet_id,
                heart_rate = excluded.heart_rate,
                rr_intervals_json = excluded.rr_intervals_json,
                sleep_state = excluded.sleep_state
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, sample.sampleAt.timeIntervalSince1970)
        bind(packetID, to: 2, in: statement)
        sqlite3_bind_int(statement, 3, Int32(sample.heartRate))
        let rrJSON = "[" + sample.rrIntervals.map(String.init).joined(separator: ",") + "]"
        bind(rrJSON, to: 4, in: statement)
        sqlite3_bind_int(statement, 5, Int32(sample.sleepState))
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func backfillHistoricalSamplesIfNeeded() {
        guard let database else { return }
        let count = Int((try? scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample")) ?? 0)
        guard count == 0 else { return }
        let sql = """
            SELECT id, payload
            FROM whoop_raw_packet
            WHERE frame_type = 47
            ORDER BY received_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        guard execute("BEGIN IMMEDIATE") else { return }
        var succeeded = true
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let packetID = textColumn(statement, 0),
                  let payload = dataColumn(statement, 1),
                  let historical = WhoopDecodedHistorical.decode(payload) else {
                stepResult = sqlite3_step(statement)
                continue
            }
            if !insertHistorical(database: database, packetID: packetID, sample: historical) {
                succeeded = false
                break
            }
            stepResult = sqlite3_step(statement)
        }
        succeeded = succeeded && stepResult == SQLITE_DONE
        if succeeded {
            guard execute("COMMIT") else { execute("ROLLBACK"); return }
        } else {
            execute("ROLLBACK")
        }
    }

    struct HistoricalRow {
        let timestamp: TimeInterval
        let heartRate: Int
        let rrIntervals: [Double]
        let sleepState: Int
    }

    struct RealtimeRRPacket: Sendable {
        let timestamp: TimeInterval
        let intervals: [Double]
    }

    private struct SleepCandidate {
        let sessionRows: [HistoricalRow]
        let asleepRows: [HistoricalRow]
        let firstSleep: HistoricalRow
        let lastSleep: HistoricalRow
        let latest: HistoricalRow
        /// Observed spacing of the strap's own historical record.
        let cadenceSeconds: Double
        /// The detected sleep interval. A bounded `up` interval followed by
        /// more sleep remains inside the same night; otherwise a false interim
        /// state can shorten a still-running night by an hour.
        let sleepSeconds: Double
        /// Observed samples over samples expected at the observed cadence.
        let sessionCoverage: Double
        /// Elapsed wake time banked after the session ended.
        let wakeSeconds: Double

        var sleepID: String {
            "local-\(Int(firstSleep.timestamp))-\(Int(lastSleep.timestamp))"
        }

        var startedAt: Date { Date(timeIntervalSince1970: firstSleep.timestamp) }
        var endedAt: Date { Date(timeIntervalSince1970: lastSleep.timestamp) }
        var durationMinutes: Double { sleepSeconds / 60.0 }
        var dateKey: String { WhoopStore.dateKeyFormatter.string(from: endedAt) }
        var secondsSinceLastAsleep: Double { latest.timestamp - lastSleep.timestamp }

        /// Evidence gates. A manual process never waives these: they decide
        /// whether the night can be honestly scored at all.
        var meetsEvidenceGates: Bool {
            sleepSeconds >= 3 * 60 * 60 && sessionCoverage >= 0.50
        }

        /// Timing gates. These only ask whether Harley has actually woken up
        /// yet. Pressing Process answers that question directly, so the manual
        /// path waives them while keeping the evidence gates intact.
        var meetsWakeGates: Bool {
            wakeSeconds >= 30 * 60 && secondsSinceLastAsleep >= 30 * 60
        }

        var pendingSleep: WhoopPendingSleep {
            WhoopPendingSleep(
                sleepID: sleepID,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMinutes: durationMinutes
            )
        }
    }

    /// The strap's historical record is not one hertz. It stores roughly one
    /// distinct sample every six seconds, so every duration and coverage figure
    /// is derived from the observed cadence rather than from counting seconds
    /// that happen to carry a sample. Counting seconds made a full night look
    /// like minutes and put both evidence gates permanently out of reach.
    static func cadenceSeconds(of rows: [HistoricalRow]) -> Double {
        guard rows.count > 1 else { return 6 }
        var gaps: [Double] = []
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            if delta > 0, delta <= 300 { gaps.append(delta) }
        }
        guard !gaps.isEmpty else { return 6 }
        gaps.sort()
        return min(max(gaps[gaps.count / 2], 1), 60)
    }

    /// Fraction of a session the strap actually gave evidence for. Only gaps
    /// longer than the outage cap count against it, which is the same cap the
    /// duration integration refuses to count as sleep, so the two agree.
    /// Sampling density is deliberately excluded: a night recorded every sixteen
    /// seconds instead of every six is still a fully observed night, and gating
    /// on density rejected good nights for a property that does not threaten
    /// the duration estimate.
    static func observedFraction(of rows: [HistoricalRow], cadence: Double) -> Double {
        guard rows.count > 1, let first = rows.first, let last = rows.last else { return 0 }
        let span = max(1.0, last.timestamp - first.timestamp)
        let cap = max(cadence * 4, 120.0)
        var unobserved = 0.0
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            if delta > cap { unobserved += delta - cadence }
        }
        return max(0.0, min(1.0, (span - unobserved) / span))
    }

    /// Elapsed time represented by a run of samples. A gap longer than the
    /// outage cap contributes one sample of time rather than the whole gap, so
    /// neither a dropout nor a long awakening is ever counted as sleep.
    static func elapsedSeconds(across rows: [HistoricalRow], cadence: Double) -> Double {
        guard !rows.isEmpty else { return 0 }
        guard rows.count > 1 else { return cadence }
        let cap = max(cadence * 4, 120.0)
        var total = cadence
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            total += delta <= cap ? delta : cadence
        }
        return total
    }

    /// A long `up` interval can occur inside a night and then return to the
    /// strap's explicit asleep state. Keep that as one sleep session. A gap
    /// longer than 90 minutes is treated as a separate sleep instead.
    static func groupedAsleepRows(
        _ asleepRows: [HistoricalRow],
        maximumInterruptionSeconds: Double = 90 * 60
    ) -> [[HistoricalRow]] {
        var groups: [[HistoricalRow]] = []
        for row in asleepRows {
            if let last = groups.last?.last,
               row.timestamp - last.timestamp <= maximumInterruptionSeconds {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups
    }

    private enum SleepAnalysis {
        case noData
        case sleeping(Date)
        /// Every main sleep in the window, oldest first. All of them are
        /// considered, not only the most recent: a night that ends while the app
        /// is never opened would otherwise be skipped permanently, because the
        /// strap trims its history once a chunk is acknowledged.
        case awake(Date, [SleepCandidate])
    }

    /// Detects the latest main sleep without storing anything. Keeping detection
    /// separate from finalization lets the dashboard surface a night the
    /// automatic timing gates have not banked yet, and lets a manual process
    /// finish that exact night rather than re-deriving a different session.
    /// The 48-hour window every sleep decision is made from.
    private func recentHistoricalRows(now: Date) -> [HistoricalRow] {
        guard let database else { return [] }
        let cutoff = now.addingTimeInterval(-48 * 60 * 60).timeIntervalSince1970
        let sql = """
            SELECT sample_at, heart_rate, rr_intervals_json, sleep_state
            FROM whoop_historical_sample
            WHERE sample_at >= ?
            ORDER BY sample_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)

        var rows: [HistoricalRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rrText = textColumn(statement, 2) ?? "[]"
            rows.append(HistoricalRow(
                timestamp: sqlite3_column_double(statement, 0),
                heartRate: Int(sqlite3_column_int(statement, 1)),
                rrIntervals: (try? JSONDecoder().decode([Double].self, from: Data(rrText.utf8))) ?? [],
                sleepState: Int(sqlite3_column_int(statement, 3))
            ))
        }
        return rows
    }

    private func analyze(now: Date) -> SleepAnalysis {
        guard database != nil else { return .noData }
        let rows = recentHistoricalRows(now: now)
        guard let latest = rows.last else { return .noData }
        let latestDate = Date(timeIntervalSince1970: latest.timestamp)
        let sampleIsCurrent = abs(now.timeIntervalSince(latestDate)) <= 30 * 60
        let lastAsleepTimestamp = rows.last { $0.sleepState == 2 }?.timestamp
        // State 3 ("up") can occur inside a still-running night and is followed
        // by more state-2 sleep in real captures. Keep dashes through it. The
        // first current state-0 sample is the wake transition and should expose
        // Process immediately rather than waiting another 30 minutes.
        let recentSleepBeforeUp = lastAsleepTimestamp.map {
            latest.timestamp - $0 <= 90 * 60
        } == true
        let isSleeping = sampleIsCurrent
            && (latest.sleepState == 2
                || (latest.sleepState == 3 && recentSleepBeforeUp))
        guard !isSleeping else { return .sleeping(latestDate) }

        let asleepRows = rows.filter { $0.sleepState == 2 }
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
                $0.timestamp > lastSleep.timestamp && $0.sleepState != 2
            }
            candidates.append(SleepCandidate(
                sessionRows: sessionRows,
                asleepRows: session,
                firstSleep: firstSleep,
                lastSleep: lastSleep,
                latest: latest,
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
        return .awake(latestDate, candidates)
    }

    /// Automatic path. Stores only a main sleep the strap itself marked asleep,
    /// followed by at least 30 minutes of banked wake data. A night that clears
    /// the evidence gates but not the wake gates is reported as pending so the
    /// dashboard can offer to finish it instead of silently showing dashes.
    private func analyzeLatestSleep(
        now: Date = .now,
        allowAutomaticFinalization: Bool = false
    ) -> WhoopSleepSnapshot {
        switch analyze(now: now) {
        case .noData:
            return WhoopSleepSnapshot(
                isSleeping: false,
                sampleAt: nil,
                finalizedRecord: nil,
                pendingSleep: nil
            )

        case .sleeping(let sampleAt):
            return WhoopSleepSnapshot(
                isSleeping: true,
                sampleAt: sampleAt,
                finalizedRecord: nil,
                pendingSleep: nil
            )

        case .awake(let sampleAt, let candidates):
            guard let database, let latest = candidates.last else {
                return WhoopSleepSnapshot(
                    isSleeping: false,
                    sampleAt: sampleAt,
                    finalizedRecord: nil,
                    pendingSleep: nil
                )
            }

            // Only a completed history offload may bank a night, and the four
            // primary metrics are written together. The persisted completion
            // marker also makes this safe immediately after an app relaunch;
            // a newer partial chunk invalidates it until the next COMPLETE.
            let coherentHistory = allowAutomaticFinalization
                && completedOffloadCoversLatestHistory(database: database)
            var newest: DailyHealthRecord?
            for candidate in candidates
                where coherentHistory
                    && candidate.meetsEvidenceGates
                    && candidate.meetsWakeGates {
                guard shouldDerive(candidate: candidate, database: database) else { continue }
                let record = derivedRecord(for: candidate, now: now)
                guard record.hasCompletePrimarySleepMetrics else { continue }
                if upsertLocalDailyHealthRecord(record, database: database) {
                    newest = record
                }
            }

            let pending: WhoopPendingSleep?
            if shouldDerive(candidate: latest, database: database) {
                pending = latest.pendingSleep
            } else {
                pending = nil
            }

            return WhoopSleepSnapshot(
                isSleeping: false,
                sampleAt: sampleAt,
                finalizedRecord: newest,
                pendingSleep: pending
            )
        }
    }

    /// Manual path behind the dashboard's Process control. It waives only the
    /// wake-timing gates, because pressing the button is itself the proof that
    /// the night is over.
    func finalizePendingSleep(
        completion: @escaping @Sendable (Result<DailyHealthRecord, WhoopSleepProcessError>) -> Void
    ) {
        queue.async { [self] in
            let now = Date()
            guard let database else {
                completion(.failure(.storeUnavailable))
                return
            }

            switch analyze(now: now) {
            case .noData:
                completion(.failure(.noRecentData))

            case .sleeping:
                completion(.failure(.stillAsleep))

            case .awake(_, let candidates):
                guard let candidate = candidates.last else {
                    completion(.failure(.noSleepDetected))
                    return
                }
                // Process may waive the wake timer, but it must never publish
                // while a history chunk is still arriving. That was able to
                // turn an 8h32m night into a complete-looking 3h50m row.
                guard completedOffloadCoversLatestHistory(database: database) else {
                    completion(.failure(.historyStillLoading))
                    return
                }
                guard candidate.meetsEvidenceGates else {
                    completion(.failure(.insufficientEvidence))
                    return
                }
                let record = derivedRecord(for: candidate, now: now)
                guard record.hasCompletePrimarySleepMetrics else {
                    completion(.failure(.metricsStillLoading))
                    return
                }
                guard upsertLocalDailyHealthRecord(record, database: database) else {
                    completion(.failure(.writeFailed))
                    return
                }
                completion(.success(record))
            }
        }
    }

    func sleepDiagnostics(
        now: Date = .now,
        completion: @escaping @Sendable (WhoopSleepDiagnostics) -> Void
    ) {
        queue.async { [self] in completion(buildSleepDiagnostics(now: now)) }
    }

    /// Writes the diagnostics beside the database as JSON. Small and overwritten
    /// each time, so it can be pulled off the device when the dashboard shows
    /// nothing and the reason is not obvious.
    func writeSleepDiagnostics(now: Date = .now) {
        queue.async { [self] in
            let diagnostics = buildSleepDiagnostics(now: now)
            guard let directory = Self.databaseDirectory() else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(diagnostics) else { return }
            try? data.write(
                to: directory.appendingPathComponent("sleep-diagnostics.json"),
                options: .atomic
            )
        }
    }

    private func buildSleepDiagnostics(now: Date) -> WhoopSleepDiagnostics {
        let iso = ISO8601DateFormatter()
        let audit = historicalDecodeAudit()
        func stamp(_ interval: TimeInterval) -> String {
            iso.string(from: Date(timeIntervalSince1970: interval))
        }
        func shell(_ outcome: String, rows: [HistoricalRow] = []) -> WhoopSleepDiagnostics {
            var histogram: [String: Int] = [:]
            for row in rows { histogram["\(row.sleepState)", default: 0] += 1 }
            return WhoopSleepDiagnostics(
                generatedAt: iso.string(from: now), windowHours: 48,
                sampleCount: rows.count,
                firstSampleAt: rows.first.map { stamp($0.timestamp) },
                lastSampleAt: rows.last.map { stamp($0.timestamp) },
                secondsSinceLastSample: rows.last.map { Int(now.timeIntervalSince1970 - $0.timestamp) },
                observedCadenceSeconds: rows.isEmpty ? nil : Self.cadenceSeconds(of: rows),
                largestGapSeconds: nil, sleepStateHistogram: histogram,
                rawType47PacketTotal: audit.rawTotal,
                historicalSampleTotal: audit.sampleTotal,
                recentType47Outcomes: audit.outcomes,
                sessions: [], outcome: outcome
            )
        }

        guard let database else { return shell("no database") }
        let rows = recentHistoricalRows(now: now)
        guard !rows.isEmpty else { return shell("no historical samples in the last 48 hours") }

        var histogram: [String: Int] = [:]
        for row in rows { histogram["\(row.sleepState)", default: 0] += 1 }
        let cadence = Self.cadenceSeconds(of: rows)
        var largestGap = 0.0
        for index in 1..<rows.count {
            largestGap = max(largestGap, rows[index].timestamp - rows[index - 1].timestamp)
        }

        let asleepRows = rows.filter { $0.sleepState == 2 }
        let groups = Self.groupedAsleepRows(asleepRows)

        let latest = rows[rows.count - 1]
        var sessions: [WhoopSleepSessionDiagnostics] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let span = max(1.0, last.timestamp - first.timestamp)
            let inSession = rows.filter { $0.timestamp >= first.timestamp && $0.timestamp <= last.timestamp }
            let sessionCadence = Self.cadenceSeconds(of: inSession)
            let wakeRows = rows.filter { $0.timestamp > last.timestamp && $0.sleepState != 2 }
            let duration = Self.elapsedSeconds(across: inSession, cadence: sessionCadence)
            let coverage = Self.observedFraction(of: inSession, cadence: sessionCadence)
            let density = min(1.0, Double(inSession.count) / max(1.0, span / sessionCadence))
            let wake = Self.elapsedSeconds(across: wakeRows, cadence: sessionCadence)
            let since = latest.timestamp - last.timestamp
            let dateKey = Self.dateKeyFormatter.string(from: Date(timeIntervalSince1970: last.timestamp))
            let stored = storedSleepID(forDateKey: dateKey, database: database)
            let durationGate = duration >= 3 * 60 * 60
            let coverageGate = coverage >= 0.50
            let wakeGate = wake >= 30 * 60
            let elapsedGate = since >= 30 * 60

            let candidate = SleepCandidate(
                sessionRows: inSession,
                asleepRows: group,
                firstSleep: first,
                lastSleep: last,
                latest: latest,
                cadenceSeconds: sessionCadence,
                sleepSeconds: duration,
                sessionCoverage: coverage,
                wakeSeconds: wake
            )
            let storedComplete = !shouldDerive(candidate: candidate, database: database)
            let metricsComplete = derivedRecord(for: candidate, now: now).hasCompletePrimarySleepMetrics

            let verdict: String
            if storedComplete {
                verdict = "already stored"
            } else if !durationGate || !coverageGate {
                verdict = "pending; Process visible, evidence incomplete"
            } else if !metricsComplete {
                verdict = "pending; Process visible, primary metrics still loading"
            } else if !wakeGate || !elapsedGate {
                verdict = "pending; Process control visible"
            } else {
                verdict = "all gates pass; finalizes automatically"
            }

            sessions.append(WhoopSleepSessionDiagnostics(
                startedAt: stamp(first.timestamp), endedAt: stamp(last.timestamp),
                spanMinutes: (span / 60).rounded(), durationMinutes: (duration / 60).rounded(),
                sampleCount: inSession.count, coverage: coverage, sampleDensity: density,
                bankedWakeMinutes: (wake / 60).rounded(),
                minutesSinceLastAsleep: (since / 60).rounded(),
                passesDurationGate: durationGate, passesCoverageGate: coverageGate,
                passesWakeCoverageGate: wakeGate, passesWakeElapsedGate: elapsedGate,
                dateKey: dateKey, storedSleepID: stored,
                storedSummary: storedRecordSummary(forDateKey: dateKey, database: database),
                verdict: verdict
            ))
        }

        return WhoopSleepDiagnostics(
            generatedAt: iso.string(from: now), windowHours: 48,
            sampleCount: rows.count,
            firstSampleAt: stamp(rows[0].timestamp),
            lastSampleAt: stamp(latest.timestamp),
            secondsSinceLastSample: Int(now.timeIntervalSince1970 - latest.timestamp),
            observedCadenceSeconds: cadence, largestGapSeconds: Int(largestGap),
            sleepStateHistogram: histogram,
            rawType47PacketTotal: audit.rawTotal,
            historicalSampleTotal: audit.sampleTotal,
            recentType47Outcomes: audit.outcomes,
            sessions: sessions,
            outcome: sessions.last?.verdict ?? "no sample carried sleep_state 2 in the last 48 hours"
        )
    }

    /// Compares stored type-47 packets against the samples they produced. A ratio
    /// near one means the strap itself reports sparsely; a large ratio means this
    /// app is discarding frames it already acknowledged and cannot re-request.
    private func historicalDecodeAudit() -> (rawTotal: Int, sampleTotal: Int, outcomes: [String: Int]) {
        guard let database else { return (0, 0, [:]) }
        let rawTotal = Int((try? scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_raw_packet WHERE frame_type = 47")) ?? 0)
        let sampleTotal = Int((try? scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample")) ?? 0)
        var outcomes: [String: Int] = [:]
        let sql = """
            SELECT payload FROM whoop_raw_packet
            WHERE frame_type = 47
            ORDER BY received_at DESC
            LIMIT 3000
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return (rawTotal, sampleTotal, outcomes) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            outcomes[WhoopDecodedHistorical.decodeFailureReason(data), default: 0] += 1
        }
        return (rawTotal, sampleTotal, outcomes)
    }

    private func derivedRecord(
        for candidate: SleepCandidate,
        now: Date
    ) -> DailyHealthRecord {
        let durationMinutes = candidate.durationMinutes
        let restingHR = restingHeartRate(rows: candidate.asleepRows, cadence: candidate.cadenceSeconds)
        let hrv = nightlyRMSSD(for: candidate)
        let sleepScore = min(
            Self.maximumSleepScore,
            durationMinutes / Self.baselineSleepNeedMinutes * 100
        )
        return DailyHealthRecord(
            dateKey: candidate.dateKey,
            sleepScore: sleepScore,
            sleepDurationMinutes: durationMinutes,
            hrvRMSSDMilliseconds: hrv,
            restingHeartRateBPM: restingHR,
            sleepID: candidate.sleepID,
            cycleID: nil,
            source: Self.localSource,
            sourceArchive: nil,
            sourceUpdatedAt: ISO8601DateFormatter().string(from: now)
        )
    }

    /// Whether a night still needs deriving. Older local model versions are
    /// always replaced once a coherent offload exists, including when a bug fix
    /// correctly makes a metric smaller. Within one model version, a later
    /// offload remains grow-only so a partial reconstruction cannot shrink a
    /// settled record. Archived WHOOP rows remain authoritative.
    private func shouldDerive(candidate: SleepCandidate, database: OpaquePointer) -> Bool {
        let sql = """
            SELECT source, sleep_score, sleep_duration_minutes,
                   hrv_rmssd_milliseconds, resting_heart_rate_bpm
            FROM daily_health_metric WHERE date_key = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(candidate.dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        guard let source = textColumn(statement, 0),
              source.hasPrefix(Self.localSourcePrefix) else { return false }
        if source != Self.localSource { return true }
        if (1...4).contains(where: { sqlite3_column_type(statement, Int32($0)) == SQLITE_NULL }) {
            return true
        }
        let existingDuration = sqlite3_column_double(statement, 2)
        return Self.shouldReplaceLocalSleep(
            existingDurationMinutes: existingDuration,
            candidateDurationMinutes: candidate.durationMinutes
        )
    }

    /// A one-minute tolerance avoids rewriting a settled record for harmless
    /// cadence-edge jitter while still repairing any meaningful missing tail.
    static func shouldReplaceLocalSleep(
        existingDurationMinutes: Double,
        candidateDurationMinutes: Double
    ) -> Bool {
        return candidateDurationMinutes > existingDurationMinutes + 1
    }

    /// A HISTORY_COMPLETE packet is inserted after every sample in its offload
    /// on the store's serial queue. If the newest sample was received later
    /// than the newest completion, a chunk is still in flight and must not be
    /// published yet. This survives relaunches without a second state store.
    private func completedOffloadCoversLatestHistory(database: OpaquePointer) -> Bool {
        let sql = """
            SELECT
                (SELECT MAX(p.received_at)
                 FROM whoop_historical_sample h
                 JOIN whoop_raw_packet p ON p.id = h.source_packet_id),
                (SELECT MAX(received_at)
                 FROM whoop_raw_packet
                 WHERE frame_type = 49
                   AND hex(substr(payload, 11, 1)) = '03')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL,
              sqlite3_column_type(statement, 1) != SQLITE_NULL else { return false }
        let newestSampleReceivedAt = sqlite3_column_double(statement, 0)
        let newestCompletionReceivedAt = sqlite3_column_double(statement, 1)
        return newestCompletionReceivedAt >= newestSampleReceivedAt
    }

    private func storedRecordSummary(forDateKey dateKey: String, database: OpaquePointer) -> String? {
        let sql = """
            SELECT sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
                   resting_heart_rate_bpm, source
            FROM daily_health_metric WHERE date_key = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let score = sqlite3_column_double(statement, 0)
        let duration = sqlite3_column_double(statement, 1)
        let hrv = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
        let rhr = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
        let source = textColumn(statement, 4) ?? "?"
        return "score \(Int(score.rounded()))% | \(Int(duration.rounded())) min | HRV \(hrv.map { String(Int($0.rounded())) } ?? "nil") | RHR \(rhr.map { String(Int($0.rounded())) } ?? "nil") | \(source)"
    }

    private func storedSleepID(forDateKey dateKey: String, database: OpaquePointer) -> String? {
        let sql = "SELECT sleep_id FROM daily_health_metric WHERE date_key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, 0)
    }

    /// Lowest five-minute mean heart rate across the night. The minimum sample
    /// requirement is a fraction of what the observed cadence can actually
    /// deliver in five minutes; a fixed count assumed a one-hertz record and so
    /// no window ever qualified, leaving resting heart rate permanently nil.
    private func restingHeartRate(rows: [HistoricalRow], cadence: Double) -> Double? {
        guard let start = rows.first?.timestamp, let end = rows.last?.timestamp else { return nil }
        let expectedPerWindow = 5 * 60 / max(cadence, 1)
        let required = max(3, Int((expectedPerWindow * 0.4).rounded()))
        var means: [Double] = []
        var windowStart = start
        while windowStart <= end {
            let values = rows.filter {
                $0.timestamp >= windowStart && $0.timestamp < windowStart + 5 * 60 && $0.heartRate > 0
            }.map { Double($0.heartRate) }
            if values.count >= required {
                means.append(values.reduce(0, +) / Double(values.count))
            }
            windowStart += 5 * 60
        }
        return means.min().map { $0.rounded() }
    }

    /// RMSSD requires differences between adjacent heartbeats. Historical v18
    /// records are too sparse to prove adjacency: almost every record contains
    /// zero or one R-R value. Use the dense realtime stream and preserve packet
    /// boundaries and device timestamps instead of flattening unrelated beats.
    private func nightlyRMSSD(for candidate: SleepCandidate) -> Double? {
        guard let database else { return nil }
        let packets = realtimeRRPackets(
            database: database,
            from: candidate.firstSleep.timestamp - 30,
            through: candidate.lastSleep.timestamp + 30
        )
        let ranges = Self.observedAsleepRanges(
            rows: candidate.asleepRows,
            cadence: candidate.cadenceSeconds
        )
        let asleepPackets = packets.filter { packet in
            ranges.contains { packet.timestamp >= $0.lowerBound && packet.timestamp <= $0.upperBound }
        }
        return Self.rmssdFromRealtimePackets(asleepPackets)
    }

    private func realtimeRRPackets(
        database: OpaquePointer,
        from start: TimeInterval,
        through end: TimeInterval
    ) -> [RealtimeRRPacket] {
        let sql = """
            SELECT COALESCE(device_timestamp, received_at), rr_intervals_json
            FROM heart_rate_sample
            WHERE COALESCE(device_timestamp, received_at) BETWEEN ? AND ?
              AND source = 'whoop5_type40'
              AND rr_intervals_json != '[]'
            ORDER BY COALESCE(device_timestamp, received_at), received_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, end)
        var packets: [RealtimeRRPacket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = textColumn(statement, 1) ?? "[]"
            let intervals = (try? JSONDecoder().decode([Double].self, from: Data(text.utf8))) ?? []
            if !intervals.isEmpty {
                packets.append(RealtimeRRPacket(
                    timestamp: sqlite3_column_double(statement, 0),
                    intervals: intervals
                ))
            }
        }
        return packets
    }

    static func observedAsleepRanges(
        rows: [HistoricalRow],
        cadence: Double
    ) -> [ClosedRange<TimeInterval>] {
        guard let first = rows.first else { return [] }
        let maximumGap = max(cadence * 4, 120)
        var ranges: [ClosedRange<TimeInterval>] = []
        var start = first.timestamp
        var previous = first.timestamp
        for row in rows.dropFirst() {
            if row.timestamp - previous > maximumGap {
                ranges.append((start - cadence)...(previous + cadence))
                start = row.timestamp
            }
            previous = row.timestamp
        }
        ranges.append((start - cadence)...(previous + cadence))
        return ranges
    }

    /// Computes five-minute RMSSD windows while allowing continuity only inside
    /// one packet or across packets delivered no more than three seconds apart.
    /// Filtering an implausible beat breaks the chain rather than stitching its
    /// neighbours together. Returning nil is preferable to false precision.
    static func rmssdFromRealtimePackets(
        _ packets: [RealtimeRRPacket],
        minimumDifferencesPerWindow: Int = 20
    ) -> Double? {
        guard !packets.isEmpty else { return nil }
        let ordered = packets.sorted { lhs, rhs in
            lhs.timestamp == rhs.timestamp
                ? lhs.intervals.count < rhs.intervals.count
                : lhs.timestamp < rhs.timestamp
        }
        var differencesByWindow: [Int: [Double]] = [:]
        var previousInterval: Double?
        var previousPacketTimestamp: TimeInterval?
        var previousWasValid = false

        for packet in ordered {
            let packetGap = previousPacketTimestamp.map { packet.timestamp - $0 }
            for (index, interval) in packet.intervals.enumerated() {
                let valid = (300...2_000).contains(interval)
                let crossesPacket = index == 0
                let adjacent = crossesPacket
                    ? packetGap.map { $0 > 0 && $0 <= 3 } == true
                    : true
                if valid, previousWasValid, adjacent, let previousInterval {
                    let difference = interval - previousInterval
                    let window = Int(packet.timestamp / 300)
                    differencesByWindow[window, default: []].append(difference * difference)
                }
                previousInterval = valid ? interval : nil
                previousWasValid = valid
            }
            previousPacketTimestamp = packet.timestamp
        }

        let values = differencesByWindow.values.compactMap { squares -> Double? in
            guard squares.count >= minimumDifferencesPerWindow else { return nil }
            return sqrt(squares.reduce(0, +) / Double(squares.count))
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Baseline sleep need, calibrated against WHOOP's own archived scores.
    ///
    /// The previous model took the 75th percentile of the last 28 nights'
    /// durations, which is circular: it derived how much sleep is needed from
    /// how much sleep actually happened, so a run of short nights lowered the
    /// bar and flattered the next score. Clamped to a 480 minute floor, it also
    /// scored any night past eight hours at 100%.
    ///
    /// Dividing each archived night's duration by the sleep performance WHOOP
    /// published for it recovers the need WHOOP itself used: a median of 517
    /// minutes across 306 nights. A constant 519 minute need reproduces WHOOP's
    /// median score of 82 exactly and its mean within about one point.
    ///
    /// This is a baseline only. WHOOP also raises need for sleep debt, strain,
    /// and naps, none of which are modelled here, so a night after heavy strain
    /// will score higher than WHOOP would score it.
    static let baselineSleepNeedMinutes: Double = 519

    /// WHOOP never awarded 100% in 306 archived nights; its highest was 99.
    static let maximumSleepScore: Double = 99

    /// Versioned so a change to any derivation re-derives the nights written by
    /// the previous version instead of leaving stale values in the history.
    /// Anything with the `whoop5_local` prefix is ours; anything else is an
    /// archived WHOOP row and is authoritative.
    static let localSource = "whoop5_local_v3"
    static let localSourcePrefix = "whoop5_local"

    private func upsertLocalDailyHealthRecord(
        _ record: DailyHealthRecord,
        database: OpaquePointer
    ) -> Bool {
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

    static let dateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
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

    private func dataColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func scalarInt(_ database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.queryFailed(errorMessage(database)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
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
