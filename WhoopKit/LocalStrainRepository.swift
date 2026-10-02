import Foundation
import SQLite3

struct DailyStrainRecord: Sendable {
    let dateKey: String
    let score: Double
    let source: String
    let estimate: StrainEstimate?
}

struct WhoopStrainModel: Codable, Sendable {
    let calibration: StrainCalibration
    let maximumHeartRate: Double

    static func load() -> Self? {
        let configured = ProcessInfo.processInfo.environment["WHOOP_STRAIN_MODEL_PATH"]
        let url =
            configured.map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "whoop-strain-model", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
            let model = try? JSONDecoder().decode(Self.self, from: data),
            model.calibration.isValid, model.maximumHeartRate.isFinite,
            (90...230).contains(model.maximumHeartRate)
        else { return nil }
        return model
    }
}

/// Read-only scoring on the dashboard reader queue. Derivations return to the
/// single store writer for persistence in the existing metadata table, retaining
/// provenance without adding a schema or touching official targets/raw samples.
struct LocalStrainRepository {
    struct Result {
        let records: [DailyStrainRecord]
        let derivations: [String: String]
    }
    private struct CachedDay: Codable {
        let signature: String
        let estimate: StrainEstimate
    }
    private struct InputDay {
        let day: String
        let count: Int64
        let latestID: Int64
        let firstOffset: Int
        let lastOffset: Int
        let latestSample: Double
        let contentSignature: String
    }

    func load(
        database: OpaquePointer, health: [DailyHealthRecord],
        model: WhoopStrainModel?, now: Date = .now
    ) throws -> Result {
        var records: [String: DailyStrainRecord] = [:]
        try query(
            database,
            "SELECT date_key, official_day_strain FROM whoop_official_daily_metric WHERE official_day_strain > 0"
        ) { row in
            guard let day = text(row, 0) else { return }
            let score = sqlite3_column_double(row, 1)
            guard score.isFinite, (0...21).contains(score) else { return }
            records[day] = DailyStrainRecord(
                dateKey: day, score: score,
                source: "whoop_private_ios_api", estimate: nil)
        }
        guard let model else { return Result(records: sorted(records), derivations: [:]) }
        var peripheral: String?
        try query(database, "SELECT peripheral_id FROM whoop_historical_sample ORDER BY sample_at DESC LIMIT 1") {
            row in
            peripheral = text(row, 0)
        }
        guard let peripheral else { return Result(records: sorted(records), derivations: [:]) }
        var inputDays: [InputDay] = []
        try query(
            database,
            """
            SELECT strftime('%Y-%m-%d', sample_at + step_utc_offset_seconds, 'unixepoch'),
                   COUNT(*), MAX(id), MIN(step_utc_offset_seconds), MAX(step_utc_offset_seconds), MAX(sample_at),
                   TOTAL(1.0 * id * heart_rate), TOTAL(1.0 * id * step_motion_counter), TOTAL(1.0 * id * sleep_state)
            FROM whoop_historical_sample WHERE peripheral_id = ? AND step_utc_offset_seconds IS NOT NULL
            GROUP BY 1 ORDER BY 1
            """, strings: [peripheral]
        ) { row in
            guard let day = text(row, 0) else { return }
            inputDays.append(
                InputDay(
                    day: day, count: sqlite3_column_int64(row, 1),
                    latestID: sqlite3_column_int64(row, 2), firstOffset: Int(sqlite3_column_int(row, 3)),
                    lastOffset: Int(sqlite3_column_int(row, 4)), latestSample: sqlite3_column_double(row, 5),
                    contentSignature:
                        "\(sqlite3_column_double(row, 6))|\(sqlite3_column_double(row, 7))|\(sqlite3_column_double(row, 8))"
                ))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var derivations: [String: String] = [:]
        let modelKey = "local-strain.model.\(model.calibration.version)"
        let modelJSON = String(decoding: try encoder.encode(model), as: UTF8.self)
        var storedModel: String?
        try query(database, "SELECT value FROM whoop_store_metadata WHERE key = ?", strings: [modelKey]) { row in
            storedModel = text(row, 0)
        }
        if storedModel != modelJSON { derivations[modelKey] = modelJSON }
        for day in inputDays where records[day.day] == nil {
            // Travel/DST dates with conflicting recorded offsets stay unknown.
            // Never silently assign samples to the wrong civil day.
            guard day.firstOffset == day.lastOffset,
                let zone = TimeZone(secondsFromGMT: day.firstOffset),
                let date = DayKey.date(from: day.day, timeZone: zone),
                let rhr = health.last(where: { $0.dateKey <= day.day && $0.restingHeartRateBPM != nil })?
                    .restingHeartRateBPM,
                rhr.isFinite, rhr >= 30, rhr < model.maximumHeartRate
            else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let start = calendar.startOfDay(for: date).timeIntervalSince1970
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
                continue
            }
            let end = min(tomorrow.timeIntervalSince1970, floor(now.timeIntervalSince1970 / 60) * 60)
            guard end > start, day.latestSample >= start else { continue }
            let signature =
                "\(StrainAccumulator.version)|\(model.calibration.version)|\(model.maximumHeartRate)|\(rhr)|\(peripheral)|\(day.count)|\(day.latestID)|\(day.latestSample)|\(day.contentSignature)|\(start)|\(end)"
            let key = "local-strain.\(day.day).\(peripheral).\(model.calibration.version)"
            var cached: CachedDay?
            try query(database, "SELECT value FROM whoop_store_metadata WHERE key = ?", strings: [key]) { row in
                if let value = text(row, 0) {
                    cached = try? JSONDecoder().decode(CachedDay.self, from: Data(value.utf8))
                }
            }
            let estimate: StrainEstimate
            if let cached, cached.signature == signature {
                estimate = cached.estimate
            } else {
                var accumulator = StrainAccumulator(
                    calibration: model.calibration,
                    start: start, end: end, maximumHeartRate: model.maximumHeartRate, restingHeartRate: rhr)
                try query(
                    database,
                    """
                    SELECT sample_at, heart_rate, step_motion_counter, sleep_state
                    FROM whoop_historical_sample WHERE peripheral_id = ? AND sample_at >= ? AND sample_at < ?
                    ORDER BY sample_at, ordinal
                    """, strings: [peripheral], numbers: [start, tomorrow.timeIntervalSince1970]
                ) { row in
                    accumulator.append(
                        StrainSample(
                            timestamp: sqlite3_column_double(row, 0),
                            heartRate: sqlite3_column_double(row, 1),
                            stepCounter: sqlite3_column_type(row, 2) == SQLITE_NULL
                                ? nil : Int(sqlite3_column_int(row, 2)),
                            sleepState: sqlite3_column_type(row, 3) == SQLITE_NULL
                                ? nil : Int(sqlite3_column_int(row, 3))))
                }
                estimate = accumulator.finish(day: day.day)
                let encoded = try encoder.encode(CachedDay(signature: signature, estimate: estimate))
                derivations[key] = String(decoding: encoded, as: UTF8.self)
            }
            if let score = estimate.score {
                records[day.day] = DailyStrainRecord(
                    dateKey: day.day, score: score,
                    source: estimate.source, estimate: estimate)
            }
        }
        return Result(records: sorted(records), derivations: derivations)
    }

    private func sorted(_ records: [String: DailyStrainRecord]) -> [DailyStrainRecord] {
        records.values.sorted { $0.dateKey < $1.dateKey }
    }

    private func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private func query(
        _ database: OpaquePointer, _ sql: String, strings: [String] = [], numbers: [Double] = [],
        read: (OpaquePointer) throws -> Void
    ) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            throw DashboardRepository.QueryError.failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(handle) }
        for (index, value) in strings.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(
                    handle, Int32(index + 1), $0, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else {
                throw DashboardRepository.QueryError.failed("Strain query binding failed")
            }
        }
        for (index, value) in numbers.enumerated() {
            guard sqlite3_bind_double(handle, Int32(strings.count + index + 1), value) == SQLITE_OK else {
                throw DashboardRepository.QueryError.failed("Strain time binding failed")
            }
        }
        var status = sqlite3_step(handle)
        while status == SQLITE_ROW {
            try read(handle)
            status = sqlite3_step(handle)
        }
        guard status == SQLITE_DONE else {
            throw DashboardRepository.QueryError.failed(String(cString: sqlite3_errmsg(database)))
        }
    }
}
