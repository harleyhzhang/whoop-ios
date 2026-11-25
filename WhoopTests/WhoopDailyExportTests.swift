import SQLite3
import XCTest

@testable import Whoop

final class WhoopDailyExportTests: XCTestCase {
    private func makeStore() throws -> (WhoopStore, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        return (WhoopStore(databaseURL: url, runBackgroundDecoding: false), url, directory)
    }

    private func insert(_ url: URL, dateKey: String, minutes: Double, source: String = "whoop5_local_v5") throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        let sql = """
            INSERT OR REPLACE INTO daily_health_metric(date_key, sleep_duration_minutes,
                hrv_rmssd_milliseconds, resting_heart_rate_bpm, source, source_updated_at, imported_at)
            VALUES ('\(dateKey)', \(minutes), 55, 52, '\(source)', '2026-01-01T00:00:00Z', 0)
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func chunk(_ directory: URL, month: String) throws -> WhoopDailyExport.Chunk {
        let url = directory.appendingPathComponent(WhoopDailyExport.directoryName)
            .appendingPathComponent(WhoopDailyExport.fileName(month: month))
        return try WhoopDailyExport.decoder.decode(WhoopDailyExport.Chunk.self, from: Data(contentsOf: url))
    }

    func testFirstPassWritesEveryMonthThenOnlyChangedRecentMonths() throws {
        let (store, url, directory) = try makeStore()
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        try insert(url, dateKey: "2026-09-10", minutes: 400)
        try insert(url, dateKey: "2026-11-20", minutes: 480)
        try insert(url, dateKey: "2026-11-21", minutes: 470)
        let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z") ?? .now

        XCTAssertEqual(try WhoopDailyExportWriterProbe.write(url, now), ["2026-09", "2026-11"])
        XCTAssertEqual(try chunk(directory, month: "2026-11").rows.map(\.dateKey), ["2026-11-20", "2026-11-21"])
        XCTAssertEqual(try chunk(directory, month: "2026-09").rows.first?.sleepDurationMinutes, 400)

        // Unchanged data writes nothing; old months are never revisited.
        XCTAssertEqual(try WhoopDailyExportWriterProbe.write(url, now), [])

        try insert(url, dateKey: "2026-11-22", minutes: 500)
        XCTAssertEqual(try WhoopDailyExportWriterProbe.write(url, now), ["2026-11"])
        XCTAssertEqual(try chunk(directory, month: "2026-11").rows.count, 3)
    }
}

/// Runs the export the way the diagnostics reader does: a read-only snapshot.
private enum WhoopDailyExportWriterProbe {
    static func write(_ url: URL, _ now: Date) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw WhoopDailyExport.Failure.sqlite("open")
        }
        defer { sqlite3_close(handle) }
        return try WhoopDailyExport(database: handle).write(besideDatabaseAt: url, now: now)
    }
}
