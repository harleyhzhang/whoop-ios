import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Time-zone observations, wake boundaries, and day-key assignment.
extension WhoopStore {
    func recordTimeZoneObservation(now: Date = .now) {
        guard let database else { return }
        let sql = """
            INSERT OR IGNORE INTO whoop_time_zone_observation
            (observed_at, time_zone_identifier, utc_offset_seconds)
            VALUES (?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        defer { sqlite3_finalize(statement) }
        let zone = TimeZone.autoupdatingCurrent
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        bind(zone.identifier, to: 2, in: statement)
        sqlite3_bind_int(statement, 3, Int32(zone.secondsFromGMT(for: now)))
        _ = sqlite3_step(statement)
    }

    func nearestRecordedUTCOffset(database: OpaquePointer, sampleAt: Date) -> Int {
        let sql = """
            SELECT utc_offset_seconds
            FROM whoop_time_zone_observation
            ORDER BY ABS(observed_at - ?)
            LIMIT 1
            """
        let storedOffset: Int? =
            withCachedStatement(database: database, sql: sql) { statement in
                sqlite3_bind_double(statement, 1, sampleAt.timeIntervalSince1970)
                if sqlite3_step(statement) == SQLITE_ROW {
                    return Int(sqlite3_column_int(statement, 0))
                }
                return nil
            } ?? nil
        if let storedOffset { return storedOffset }
        return TimeZone.autoupdatingCurrent.secondsFromGMT(for: sampleAt)
    }

    static func dateKey(for date: Date, utcOffsetSeconds: Int) -> String {
        DayKey.string(
            from: date,
            timeZone: TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        )
    }

    static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    func publishedWakeBoundaries(database: OpaquePointer) -> [WhoopWakeBoundary] {
        if let cachedPublishedWakeBoundaries { return cachedPublishedWakeBoundaries }
        let sql = """
            SELECT date_key, sleep_end_at
            FROM daily_health_metric
            WHERE sleep_end_at IS NOT NULL
            ORDER BY date_key ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var boundaries: [WhoopWakeBoundary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawDateKey = textColumn(statement, 0),
                let dateKey = DayKey(rawValue: rawDateKey),
                let rawWake = textColumn(statement, 1),
                let wokeAt = Self.parseISO8601(rawWake)
            else { continue }
            boundaries.append(WhoopWakeBoundary(dateKey: dateKey, wokeAt: wokeAt))
        }
        let sorted = boundaries.sorted { $0.wokeAt < $1.wokeAt }
        cachedPublishedWakeBoundaries = sorted
        return sorted
    }

    func physiologicalStepDateKey(
        for sampleAt: Date,
        utcOffsetSeconds: Int,
        database: OpaquePointer
    ) -> String {
        let fallback = DayKey(
            date: sampleAt,
            timeZone: TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        )
        return WhoopPhysiologicalDay.dateKey(
            for: sampleAt,
            publishedWakes: publishedWakeBoundaries(database: database),
            civilFallback: fallback
        ).rawValue
    }

    func addColumnIfNeeded(
        table: String,
        column: String,
        declaration: String
    ) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if textColumn(statement, 1) == column { return true }
        }
        return execute("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
    }
}
