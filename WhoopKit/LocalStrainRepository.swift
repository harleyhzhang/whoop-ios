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
final class LocalStrainRepository {
    struct Result {
        let records: [DailyStrainRecord]
        let derivations: [String: String]
    }
    private struct CachedDay: Codable {
        let signature: String
        let estimate: StrainEstimate
    }
    private struct InputDay: Codable {
        let day: String
        var firstOffset: Int
        var lastOffset: Int
        var latestSample: Double
    }
    private struct InputSlice: Codable {
        let revision: Int64
        let days: [InputDay]
    }
    // Confined to the dashboard reader's serial queue, just like its connection.
    private var slices: [Int: InputSlice] = [:]
    private var cachedPeripheral: String?

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
        try query(database, WhoopStrainInputIndex.latestPeripheralQuery) { row in
            peripheral = text(row, 0)
        }
        guard let peripheral else { return Result(records: sorted(records), derivations: [:]) }
        if cachedPeripheral != peripheral {
            slices.removeAll()
            cachedPeripheral = peripheral
        }
        var revisions: [Int: Int64] = [:]
        try query(
            database,
            "SELECT utc_day, revision FROM whoop_strain_input_revision WHERE peripheral_id = ?",
            strings: [peripheral]
        ) { row in
            revisions[Int(sqlite3_column_int64(row, 0))] = sqlite3_column_int64(row, 1)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var derivations: [String: String] = [:]
        slices = slices.filter { revisions[$0.key] != nil }
        for (utcDay, revision) in revisions where slices[utcDay]?.revision != revision {
            let cacheKey = "local-strain-input.v1.\(peripheral).\(utcDay)"
            var storedSlice: InputSlice?
            try query(database, "SELECT value FROM whoop_store_metadata WHERE key = ?", strings: [cacheKey]) { row in
                if let value = text(row, 0) {
                    storedSlice = try? JSONDecoder().decode(InputSlice.self, from: Data(value.utf8))
                }
            }
            if let storedSlice, storedSlice.revision == revision {
                slices[utcDay] = storedSlice
                continue
            }
            var days: [InputDay] = []
            try query(
                database,
                """
                SELECT strftime('%Y-%m-%d', sample_at + step_utc_offset_seconds, 'unixepoch'),
                       MIN(step_utc_offset_seconds), MAX(step_utc_offset_seconds), MAX(sample_at)
                FROM whoop_historical_sample
                WHERE peripheral_id = ? AND sample_at >= ? AND sample_at < ?
                  AND step_utc_offset_seconds IS NOT NULL
                GROUP BY 1
                """, strings: [peripheral], numbers: [Double(utcDay * 86400), Double((utcDay + 1) * 86400)]
            ) { row in
                guard let day = text(row, 0) else { return }
                days.append(
                    InputDay(
                        day: day, firstOffset: Int(sqlite3_column_int(row, 1)),
                        lastOffset: Int(sqlite3_column_int(row, 2)), latestSample: sqlite3_column_double(row, 3)))
            }
            let slice = InputSlice(revision: revision, days: days)
            slices[utcDay] = slice
            derivations[cacheKey] = String(decoding: try encoder.encode(slice), as: UTF8.self)
        }
        var inputDays: [String: InputDay] = [:]
        for slice in slices.values {
            for day in slice.days {
                if var previous = inputDays[day.day] {
                    previous.firstOffset = min(previous.firstOffset, day.firstOffset)
                    previous.lastOffset = max(previous.lastOffset, day.lastOffset)
                    previous.latestSample = max(previous.latestSample, day.latestSample)
                    inputDays[day.day] = previous
                } else {
                    inputDays[day.day] = day
                }
            }
        }

        let modelKey = "local-strain.model.\(model.calibration.version)"
        let modelJSON = String(decoding: try encoder.encode(model), as: UTF8.self)
        var storedModel: String?
        try query(database, "SELECT value FROM whoop_store_metadata WHERE key = ?", strings: [modelKey]) { row in
            storedModel = text(row, 0)
        }
        if storedModel != modelJSON { derivations[modelKey] = modelJSON }
        for day in inputDays.values where records[day.day] == nil {
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
            // Absolute-day revisions cover every row read below, even unknown
            // offsets and a correction that moves a sample across civil days.
            let firstUTC = Int(floor(start / 86400))
            let lastUTC = Int(floor((tomorrow.timeIntervalSince1970 - 1) / 86400))
            let inputRevision = (firstUTC...lastUTC).map { "\($0):\(revisions[$0] ?? 0)" }.joined(separator: ",")
            let signature =
                "utc-revision-v1|\(StrainAccumulator.version)|\(modelJSON)|\(rhr)|\(peripheral)|\(inputRevision)|\(start)|\(end)"
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
