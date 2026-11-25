import Foundation
import SQLite3

/// Small month-chunked daily summaries for the Mac's read-only memory pull.
///
/// The full database is several gigabytes and Wi-Fi file copies stall on it.
/// Each pass writes `memory-export/daily-YYYY-MM.json`: only months touched by
/// recent rows, plus months with no file yet. Unchanged chunks are left alone,
/// so older months are effectively append-only and a puller copies only files
/// whose size or date changed.
struct WhoopDailyExport {
    static let directoryName = "memory-export"
    static let schemaVersion = 1
    /// Months containing rows dated within this window are re-checked each pass.
    static let recentDays = 40

    struct Row: Codable, Equatable {
        let dateKey: String
        let sleepStartAt: String?
        let sleepEndAt: String?
        let sleepDurationMinutes: Double?
        let hrvRmssdMilliseconds: Double?
        let restingHeartRateBpm: Double?
        let sleepScore: Double?
        let source: String
        let sourceUpdatedAt: String
    }

    struct Chunk: Codable, Equatable {
        let schemaVersion: Int
        let month: String
        let generatedAt: String
        let rows: [Row]
    }

    enum Failure: Error {
        case sqlite(String)
    }

    let database: OpaquePointer

    func monthsToWrite(directory: URL, now: Date) throws -> [String] {
        let cutoff = DayKey.string(
            from: now.addingTimeInterval(-Double(Self.recentDays) * 86_400), timeZone: .current)
        let recent = try strings(
            sql: "SELECT DISTINCT substr(date_key, 1, 7) FROM daily_health_metric WHERE date_key >= ?",
            binding: cutoff)
        let all = try strings(
            sql: "SELECT DISTINCT substr(date_key, 1, 7) FROM daily_health_metric", binding: nil)
        let fileManager = FileManager.default
        let missing = all.filter {
            !fileManager.fileExists(atPath: directory.appendingPathComponent(Self.fileName(month: $0)).path)
        }
        return Array(Set(recent + missing)).sorted()
    }

    func chunk(month: String, now: Date) throws -> Chunk {
        let sql = """
            SELECT date_key, sleep_start_at, sleep_end_at, sleep_duration_minutes,
                   hrv_rmssd_milliseconds, resting_heart_rate_bpm, sleep_score,
                   source, source_updated_at
            FROM daily_health_metric
            WHERE date_key >= ? AND date_key < ?
            ORDER BY date_key ASC
            """
        var rows: [Row] = []
        try query(sql: sql, bindings: ["\(month)-01", "\(month)-99"]) { statement in
            rows.append(
                Row(
                    dateKey: Self.text(statement, 0) ?? "",
                    sleepStartAt: Self.text(statement, 1),
                    sleepEndAt: Self.text(statement, 2),
                    sleepDurationMinutes: Self.real(statement, 3),
                    hrvRmssdMilliseconds: Self.real(statement, 4),
                    restingHeartRateBpm: Self.real(statement, 5),
                    sleepScore: Self.real(statement, 6),
                    source: Self.text(statement, 7) ?? "",
                    sourceUpdatedAt: Self.text(statement, 8) ?? ""))
        }
        return Chunk(
            schemaVersion: Self.schemaVersion, month: month,
            generatedAt: ISO8601DateFormatter().string(from: now), rows: rows)
    }

    /// Writes changed chunks beside the database; returns the months written.
    @discardableResult
    func write(besideDatabaseAt databaseURL: URL, now: Date) throws -> [String] {
        let directory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var written: [String] = []
        for month in try monthsToWrite(directory: directory, now: now) {
            let chunk = try chunk(month: month, now: now)
            let url = directory.appendingPathComponent(Self.fileName(month: month))
            if let existing = try? Data(contentsOf: url),
                let decoded = try? Self.decoder.decode(Chunk.self, from: existing),
                decoded.rows == chunk.rows
            {
                continue
            }
            try encoder.encode(chunk).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            written.append(month)
        }
        return written
    }

    static func fileName(month: String) -> String { "daily-\(month).json" }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func strings(sql: String, binding: String?) throws -> [String] {
        var values: [String] = []
        try query(sql: sql, bindings: binding.map { [$0] } ?? []) { statement in
            if let value = Self.text(statement, 0) { values.append(value) }
        }
        return values
    }

    private func query(sql: String, bindings: [String], row: (OpaquePointer) -> Void) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared
        else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            row(statement)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw Failure.sqlite(String(cString: sqlite3_errmsg(database))) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let pointer = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: pointer)
    }

    private static func real(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }
}
