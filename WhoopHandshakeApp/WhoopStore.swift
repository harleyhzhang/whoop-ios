import Foundation
import SQLite3

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
              frameCRCIsValid(bytes) else { return nil }
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
        if !frameCRCIsValid(bytes) { return "CRC mismatch" }
        return "decodes"
    }

    private static func frameCRCIsValid(_ bytes: [UInt8]) -> Bool {
        let payloadEnd = bytes.count - 4
        let expected = UInt32(bytes[payloadEnd])
            | (UInt32(bytes[payloadEnd + 1]) << 8)
            | (UInt32(bytes[payloadEnd + 2]) << 16)
            | (UInt32(bytes[payloadEnd + 3]) << 24)
        return crc32(Array(bytes[8..<payloadEnd])) == expected
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

struct WhoopSleepSnapshot: Sendable {
    let isSleeping: Bool
    let sampleAt: Date?
    let finalizedRecord: DailyHealthRecord?
    /// A main sleep the strap already marked asleep that cleared the evidence
    /// gates but is not stored yet. Non-nil is exactly the condition the
    /// dashboard reports as "Sleep detected".
    let pendingSleep: WhoopPendingSleep?
}

struct WhoopPendingSleep: Sendable, Equatable {
    let sleepID: String
    let startedAt: Date
    let endedAt: Date
    let durationMinutes: Double
}

/// A factual account of why the latest night did or did not become a record.
/// Written beside the database so a night that produced nothing can still be
/// explained after the fact instead of only showing dashes.
struct WhoopSleepDiagnostics: Codable, Sendable {
    let generatedAt: String
    let windowHours: Int
    let sampleCount: Int
    let distinctSeconds: Int
    let firstSampleAt: String?
    let lastSampleAt: String?
    let secondsSinceLastSample: Int?
    let medianSampleIntervalSeconds: Double?
    let largestGapSeconds: Int?
    let asleepSampleCount: Int
    let sleepStateHistogram: [String: Int]
    let sessionStartedAt: String?
    let sessionEndedAt: String?
    let sessionSpanSeconds: Int?
    let asleepDistinctSeconds: Int?
    let sessionCoverage: Double?
    let wakeCoverageSeconds: Int?
    let secondsSinceLastAsleep: Int?
    let passesDurationGate: Bool?
    let passesCoverageGate: Bool?
    let passesWakeCoverageGate: Bool?
    let passesWakeElapsedGate: Bool?
    let storedRecordForSessionDate: String?
    let rawType47PacketTotal: Int
    let historicalSampleTotal: Int
    let recentType47Outcomes: [String: Int]
    let outcome: String
}

enum WhoopSleepProcessError: Error, Sendable {
    case storeUnavailable
    case noRecentData
    case stillAsleep
    case noSleepDetected
    case insufficientEvidence
    case writeFailed

    var message: String {
        switch self {
        case .storeUnavailable: return "Local store unavailable"
        case .noRecentData: return "No recent strap data"
        case .stillAsleep: return "Still asleep"
        case .noSleepDetected: return "No sleep detected"
        case .insufficientEvidence: return "Not enough data to score"
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
        historical: WhoopDecodedHistorical?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            completion(insert(
                packet: packet,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                frameType: frameType,
                realtime: realtime,
                historical: historical
            ))
        }
    }

    func refreshSleepSnapshot(
        completion: @escaping @Sendable (WhoopSleepSnapshot) -> Void
    ) {
        queue.async { [self] in
            completion(analyzeLatestSleep())
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
        do {
            guard let directory = Self.databaseDirectory() else { return }
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
                CREATE TABLE IF NOT EXISTS whoop_historical_sample (
                    sample_at REAL PRIMARY KEY,
                    source_packet_id TEXT NOT NULL,
                    heart_rate INTEGER NOT NULL,
                    rr_intervals_json TEXT NOT NULL,
                    sleep_state INTEGER NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                )
                """)
            execute("CREATE INDEX IF NOT EXISTS whoop_historical_sample_sleep_state ON whoop_historical_sample(sleep_state, sample_at)")
            backfillHistoricalSamplesIfNeeded()
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
        realtime: WhoopDecodedRealtime?,
        historical: WhoopDecodedHistorical?
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
        if let historical,
           !insertHistorical(database: database, packetID: packetID, sample: historical) {
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
        execute("BEGIN IMMEDIATE")
        var succeeded = true
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let packetID = textColumn(statement, 0),
                  let payload = dataColumn(statement, 1),
                  let historical = WhoopDecodedHistorical.decode(payload) else { continue }
            if !insertHistorical(database: database, packetID: packetID, sample: historical) {
                succeeded = false
                break
            }
        }
        execute(succeeded ? "COMMIT" : "ROLLBACK")
    }

    private struct HistoricalRow {
        let timestamp: TimeInterval
        let heartRate: Int
        let rrIntervals: [Double]
        let sleepState: Int
    }

    private struct SleepCandidate {
        let sessionRows: [HistoricalRow]
        let firstSleep: HistoricalRow
        let lastSleep: HistoricalRow
        let latest: HistoricalRow
        let asleepSeconds: Int
        let sessionCoverage: Double
        let wakeCoverage: Int

        var sleepID: String {
            "local-\(Int(firstSleep.timestamp))-\(Int(lastSleep.timestamp))"
        }

        var startedAt: Date { Date(timeIntervalSince1970: firstSleep.timestamp) }
        var endedAt: Date { Date(timeIntervalSince1970: lastSleep.timestamp) }
        var durationMinutes: Double { Double(asleepSeconds) / 60.0 }
        var dateKey: String { WhoopStore.dateKeyFormatter.string(from: endedAt) }

        /// Evidence gates. A manual process never waives these: they decide
        /// whether the night can be honestly scored at all.
        var meetsEvidenceGates: Bool {
            asleepSeconds >= 3 * 60 * 60 && sessionCoverage >= 0.50
        }

        /// Timing gates. These only ask whether Harley has actually woken up
        /// yet. Pressing Process answers that question directly, so the manual
        /// path waives them while keeping the evidence gates intact.
        var meetsWakeGates: Bool {
            wakeCoverage >= 30 * 60 && latest.timestamp - lastSleep.timestamp >= 30 * 60
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

    private enum SleepAnalysis {
        case noData
        case sleeping(Date)
        case awake(Date, SleepCandidate?)
    }

    /// Detects the latest main sleep without storing anything. Keeping detection
    /// separate from finalization lets the dashboard surface a night the
    /// automatic timing gates have not banked yet, and lets a manual process
    /// finish that exact night rather than re-deriving a different session.
    private func analyze(now: Date) -> SleepAnalysis {
        guard let database else { return .noData }
        let cutoff = now.addingTimeInterval(-48 * 60 * 60).timeIntervalSince1970
        let sql = """
            SELECT sample_at, heart_rate, rr_intervals_json, sleep_state
            FROM whoop_historical_sample
            WHERE sample_at >= ?
            ORDER BY sample_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return .noData
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)

        var rows: [HistoricalRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_double(statement, 0)
            let heartRate = Int(sqlite3_column_int(statement, 1))
            let rrText = textColumn(statement, 2) ?? "[]"
            let rr = (try? JSONDecoder().decode([Double].self, from: Data(rrText.utf8))) ?? []
            let sleepState = Int(sqlite3_column_int(statement, 3))
            rows.append(HistoricalRow(
                timestamp: timestamp,
                heartRate: heartRate,
                rrIntervals: rr,
                sleepState: sleepState
            ))
        }

        guard let latest = rows.last else { return .noData }
        let latestDate = Date(timeIntervalSince1970: latest.timestamp)
        let sampleIsCurrent = abs(now.timeIntervalSince(latestDate)) <= 30 * 60
        let lastAsleepTimestamp = rows.last { $0.sleepState == 2 }?.timestamp
        // Keep the pending state through short awakenings; the same 30-minute
        // wake threshold below flips the UI and finalizes the night together.
        let isSleeping = sampleIsCurrent && (
            latest.sleepState == 2
                || lastAsleepTimestamp.map { latest.timestamp - $0 < 30 * 60 } == true
        )
        guard !isSleeping else { return .sleeping(latestDate) }

        let asleepRows = rows.filter { $0.sleepState == 2 }
        guard !asleepRows.isEmpty else { return .awake(latestDate, nil) }

        // The strap can briefly leave state 2 during an awakening. Treat asleep
        // points less than 45 minutes apart as one night, then choose the latest.
        var groups: [[HistoricalRow]] = []
        for row in asleepRows {
            if let last = groups.last?.last,
               row.timestamp - last.timestamp <= 45 * 60 {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        guard let session = groups.last,
              let firstSleep = session.first,
              let lastSleep = session.last else {
            return .awake(latestDate, nil)
        }

        let wakeRows = rows.filter {
            $0.timestamp > lastSleep.timestamp && $0.sleepState != 2
        }
        let sessionSpan = max(1, Int(lastSleep.timestamp - firstSleep.timestamp) + 1)
        let sessionRows = rows.filter {
            $0.timestamp >= firstSleep.timestamp && $0.timestamp <= lastSleep.timestamp
        }
        let candidate = SleepCandidate(
            sessionRows: sessionRows,
            firstSleep: firstSleep,
            lastSleep: lastSleep,
            latest: latest,
            asleepSeconds: Set(session.map { Int($0.timestamp) }).count,
            sessionCoverage: Double(Set(sessionRows.map { Int($0.timestamp) }).count) / Double(sessionSpan),
            wakeCoverage: Set(wakeRows.map { Int($0.timestamp) }).count
        )
        return .awake(latestDate, candidate)
    }

    /// Automatic path. Stores only a main sleep the strap itself marked asleep,
    /// followed by at least 30 minutes of banked wake data. A night that clears
    /// the evidence gates but not the wake gates is reported as pending so the
    /// dashboard can offer to finish it instead of silently showing dashes.
    private func analyzeLatestSleep(now: Date = .now) -> WhoopSleepSnapshot {
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

        case .awake(let sampleAt, let candidate):
            guard let database,
                  let candidate,
                  candidate.meetsEvidenceGates else {
                return WhoopSleepSnapshot(
                    isSleeping: false,
                    sampleAt: sampleAt,
                    finalizedRecord: nil,
                    pendingSleep: nil
                )
            }

            guard candidate.meetsWakeGates else {
                let alreadyStored = storedSleepID(forDateKey: candidate.dateKey, database: database) != nil
                return WhoopSleepSnapshot(
                    isSleeping: false,
                    sampleAt: sampleAt,
                    finalizedRecord: nil,
                    pendingSleep: alreadyStored ? nil : candidate.pendingSleep
                )
            }

            let record = derivedRecord(for: candidate, now: now, database: database)
            _ = upsertLocalDailyHealthRecord(record, database: database)
            return WhoopSleepSnapshot(
                isSleeping: false,
                sampleAt: sampleAt,
                finalizedRecord: record,
                pendingSleep: nil
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

            case .awake(_, let candidate):
                guard let candidate else {
                    completion(.failure(.noSleepDetected))
                    return
                }
                guard candidate.meetsEvidenceGates else {
                    completion(.failure(.insufficientEvidence))
                    return
                }
                let record = derivedRecord(for: candidate, now: now, database: database)
                guard upsertLocalDailyHealthRecord(record, database: database) else {
                    completion(.failure(.writeFailed))
                    return
                }
                completion(.success(record))
            }
        }
    }

    /// Recomputes the same window the analyzer uses and reports every input and
    /// gate result, including the cases where the analyzer bails early.
    func sleepDiagnostics(
        now: Date = .now,
        completion: @escaping @Sendable (WhoopSleepDiagnostics) -> Void
    ) {
        queue.async { [self] in
            completion(buildSleepDiagnostics(now: now))
        }
    }

    /// Writes the diagnostics beside the database as JSON. The file is small and
    /// overwritten each time, so it can be pulled off the device when the
    /// dashboard shows nothing and the reason is not obvious.
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
        func stamp(_ interval: TimeInterval) -> String {
            iso.string(from: Date(timeIntervalSince1970: interval))
        }
        let audit = historicalDecodeAudit()
        func empty(_ outcome: String) -> WhoopSleepDiagnostics {
            WhoopSleepDiagnostics(
                generatedAt: iso.string(from: now), windowHours: 48, sampleCount: 0,
                distinctSeconds: 0, firstSampleAt: nil, lastSampleAt: nil,
                secondsSinceLastSample: nil, medianSampleIntervalSeconds: nil,
                largestGapSeconds: nil, asleepSampleCount: 0, sleepStateHistogram: [:],
                sessionStartedAt: nil, sessionEndedAt: nil, sessionSpanSeconds: nil,
                asleepDistinctSeconds: nil, sessionCoverage: nil, wakeCoverageSeconds: nil,
                secondsSinceLastAsleep: nil, passesDurationGate: nil, passesCoverageGate: nil,
                passesWakeCoverageGate: nil, passesWakeElapsedGate: nil,
                storedRecordForSessionDate: nil,
                rawType47PacketTotal: audit.rawTotal,
                historicalSampleTotal: audit.sampleTotal,
                recentType47Outcomes: audit.outcomes,
                outcome: outcome
            )
        }

        guard let database else { return empty("no database") }
        let cutoff = now.addingTimeInterval(-48 * 60 * 60).timeIntervalSince1970
        let sql = """
            SELECT sample_at, sleep_state
            FROM whoop_historical_sample
            WHERE sample_at >= ?
            ORDER BY sample_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return empty("could not read whoop_historical_sample")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)

        var stamps: [TimeInterval] = []
        var states: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            stamps.append(sqlite3_column_double(statement, 0))
            states.append(Int(sqlite3_column_int(statement, 1)))
        }
        guard let first = stamps.first, let last = stamps.last else {
            return empty("no historical samples in the last 48 hours")
        }

        var histogram: [String: Int] = [:]
        for state in states { histogram["\(state)", default: 0] += 1 }

        var gaps: [Double] = []
        for index in 1..<max(stamps.count, 1) where stamps.count > 1 {
            gaps.append(stamps[index] - stamps[index - 1])
        }
        let sortedGaps = gaps.sorted()
        let medianGap = sortedGaps.isEmpty ? nil : sortedGaps[sortedGaps.count / 2]

        let asleep = zip(stamps, states).filter { $0.1 == 2 }.map(\.0)
        guard let lastAsleep = asleep.last else {
            return WhoopSleepDiagnostics(
                generatedAt: iso.string(from: now), windowHours: 48,
                sampleCount: stamps.count, distinctSeconds: Set(stamps.map(Int.init)).count,
                firstSampleAt: stamp(first), lastSampleAt: stamp(last),
                secondsSinceLastSample: Int(now.timeIntervalSince1970 - last),
                medianSampleIntervalSeconds: medianGap, largestGapSeconds: sortedGaps.last.map(Int.init),
                asleepSampleCount: 0, sleepStateHistogram: histogram,
                sessionStartedAt: nil, sessionEndedAt: nil, sessionSpanSeconds: nil,
                asleepDistinctSeconds: nil, sessionCoverage: nil, wakeCoverageSeconds: nil,
                secondsSinceLastAsleep: nil, passesDurationGate: nil, passesCoverageGate: nil,
                passesWakeCoverageGate: nil, passesWakeElapsedGate: nil,
                storedRecordForSessionDate: nil,
                rawType47PacketTotal: audit.rawTotal,
                historicalSampleTotal: audit.sampleTotal,
                recentType47Outcomes: audit.outcomes,
                outcome: "no sample carried sleep_state 2 in the last 48 hours"
            )
        }

        var groups: [[TimeInterval]] = []
        for value in asleep {
            if let previous = groups.last?.last, value - previous <= 45 * 60 {
                groups[groups.count - 1].append(value)
            } else {
                groups.append([value])
            }
        }
        let session = groups.last ?? []
        let sessionStart = session.first ?? lastAsleep
        let sessionEnd = session.last ?? lastAsleep
        let span = max(1, Int(sessionEnd - sessionStart) + 1)
        let inSession = stamps.filter { $0 >= sessionStart && $0 <= sessionEnd }
        let coverage = Double(Set(inSession.map(Int.init)).count) / Double(span)
        let asleepSeconds = Set(session.map(Int.init)).count
        let wakeCoverage = Set(
            zip(stamps, states).filter { $0.0 > sessionEnd && $0.1 != 2 }.map { Int($0.0) }
        ).count
        let sinceLastAsleep = Int(last - sessionEnd)
        let dateKey = Self.dateKeyFormatter.string(from: Date(timeIntervalSince1970: sessionEnd))

        let durationGate = asleepSeconds >= 3 * 60 * 60
        let coverageGate = coverage >= 0.50
        let wakeCoverageGate = wakeCoverage >= 30 * 60
        let wakeElapsedGate = sinceLastAsleep >= 30 * 60
        let stored = storedSleepID(forDateKey: dateKey, database: database)

        let outcome: String
        if stored != nil {
            outcome = "already stored for \(dateKey)"
        } else if !durationGate || !coverageGate {
            outcome = "blocked by evidence gates; no Process control is offered"
        } else if !wakeCoverageGate || !wakeElapsedGate {
            outcome = "pending; Process control should be visible"
        } else {
            outcome = "all gates pass; should have finalized automatically"
        }

        return WhoopSleepDiagnostics(
            generatedAt: iso.string(from: now), windowHours: 48,
            sampleCount: stamps.count, distinctSeconds: Set(stamps.map(Int.init)).count,
            firstSampleAt: stamp(first), lastSampleAt: stamp(last),
            secondsSinceLastSample: Int(now.timeIntervalSince1970 - last),
            medianSampleIntervalSeconds: medianGap, largestGapSeconds: sortedGaps.last.map(Int.init),
            asleepSampleCount: asleep.count, sleepStateHistogram: histogram,
            sessionStartedAt: stamp(sessionStart), sessionEndedAt: stamp(sessionEnd),
            sessionSpanSeconds: span, asleepDistinctSeconds: asleepSeconds,
            sessionCoverage: coverage, wakeCoverageSeconds: wakeCoverage,
            secondsSinceLastAsleep: sinceLastAsleep,
            passesDurationGate: durationGate, passesCoverageGate: coverageGate,
            passesWakeCoverageGate: wakeCoverageGate, passesWakeElapsedGate: wakeElapsedGate,
            storedRecordForSessionDate: stored,
            rawType47PacketTotal: audit.rawTotal,
            historicalSampleTotal: audit.sampleTotal,
            recentType47Outcomes: audit.outcomes,
            outcome: outcome
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
            let length = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: blob, count: length)
            outcomes[WhoopDecodedHistorical.decodeFailureReason(data), default: 0] += 1
        }
        return (rawTotal, sampleTotal, outcomes)
    }

    private func derivedRecord(
        for candidate: SleepCandidate,
        now: Date,
        database: OpaquePointer
    ) -> DailyHealthRecord {
        let durationMinutes = candidate.durationMinutes
        let restingHR = restingHeartRate(rows: candidate.sessionRows)
        let hrv = nightlyRMSSD(rows: candidate.sessionRows.filter { $0.sleepState == 2 })
        let needMinutes = personalizedSleepNeedMinutes(database: database)
        let sleepScore = min(100, durationMinutes / max(needMinutes, 1) * 100)
        return DailyHealthRecord(
            dateKey: candidate.dateKey,
            sleepScore: sleepScore,
            sleepDurationMinutes: durationMinutes,
            hrvRMSSDMilliseconds: hrv,
            restingHeartRateBPM: restingHR,
            sleepID: candidate.sleepID,
            cycleID: nil,
            source: "whoop5_local",
            sourceArchive: nil,
            sourceUpdatedAt: ISO8601DateFormatter().string(from: now)
        )
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

    private func restingHeartRate(rows: [HistoricalRow]) -> Double? {
        guard let start = rows.first?.timestamp, let end = rows.last?.timestamp else { return nil }
        var means: [Double] = []
        var windowStart = start
        while windowStart <= end {
            let values = rows.filter {
                $0.timestamp >= windowStart && $0.timestamp < windowStart + 5 * 60 && $0.heartRate > 0
            }.map { Double($0.heartRate) }
            if values.count >= 120 {
                means.append(values.reduce(0, +) / Double(values.count))
            }
            windowStart += 5 * 60
        }
        return means.min().map { $0.rounded() }
    }

    private func nightlyRMSSD(rows: [HistoricalRow]) -> Double? {
        guard let start = rows.first?.timestamp, let end = rows.last?.timestamp else { return nil }
        var windowValues: [Double] = []
        var windowStart = start
        while windowStart <= end {
            let raw = rows.filter {
                $0.timestamp >= windowStart && $0.timestamp < windowStart + 5 * 60
            }.flatMap(\.rrIntervals)
            let cleaned = cleanRR(raw)
            if cleaned.values.count >= 20,
               let value = rmssd(values: cleaned.values, contiguous: cleaned.contiguous) {
                windowValues.append(value)
            }
            windowStart += 5 * 60
        }
        guard !windowValues.isEmpty else { return nil }
        return windowValues.reduce(0, +) / Double(windowValues.count)
    }

    private func cleanRR(_ raw: [Double]) -> (values: [Double], contiguous: [Bool]) {
        let ranged = raw.enumerated().filter { (300...2_000).contains($0.element) }
        var kept: [(offset: Int, element: Double)] = []
        for index in ranged.indices {
            let low = max(ranged.startIndex, index - 2)
            let high = min(ranged.index(before: ranged.endIndex), index + 2)
            let neighbours = (low...high).filter { $0 != index }.map { ranged[$0].element }.sorted()
            guard neighbours.count >= 2 else {
                kept.append(ranged[index])
                continue
            }
            let median = neighbours.count.isMultiple(of: 2)
                ? (neighbours[neighbours.count / 2 - 1] + neighbours[neighbours.count / 2]) / 2
                : neighbours[neighbours.count / 2]
            if median <= 0 || abs(ranged[index].element - median) / median <= 0.20 {
                kept.append(ranged[index])
            }
        }
        let values = kept.map(\.element)
        let contiguous = kept.indices.map { index in
            index > 0 && kept[index].offset == kept[index - 1].offset + 1
        }
        return (values, contiguous)
    }

    private func rmssd(values: [Double], contiguous: [Bool]) -> Double? {
        guard values.count == contiguous.count else { return nil }
        var sum = 0.0
        var count = 0
        for index in 1..<values.count where contiguous[index] {
            let difference = values[index] - values[index - 1]
            sum += difference * difference
            count += 1
        }
        return count > 0 ? sqrt(sum / Double(count)) : nil
    }

    private func personalizedSleepNeedMinutes(database: OpaquePointer) -> Double {
        let sql = """
            SELECT sleep_duration_minutes
            FROM daily_health_metric
            WHERE sleep_duration_minutes > 0
            ORDER BY date_key DESC
            LIMIT 28
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return 480 }
        defer { sqlite3_finalize(statement) }
        var values: [Double] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_double(statement, 0))
        }
        guard values.count >= 7 else { return 480 }
        values.sort()
        let position = 0.75 * Double(values.count - 1)
        let low = Int(position)
        let high = min(low + 1, values.count - 1)
        let percentile = values[low] + (position - Double(low)) * (values[high] - values[low])
        return min(max(percentile, 480), 570)
    }

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
