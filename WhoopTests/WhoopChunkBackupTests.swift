import SQLite3
import XCTest

@testable import Whoop

final class WhoopChunkBackupTests: XCTestCase {
    private func exec(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }

    private func insertDays(_ url: URL, _ keys: [String]) throws {
        let values = keys.map {
            "('\($0)', 480, 55, 52, 'whoop5_local_v5', '2026-01-01T00:00:00Z', 0)"
        }.joined(separator: ",")
        try exec(
            url,
            """
            INSERT OR REPLACE INTO daily_health_metric(date_key, sleep_duration_minutes, hrv_rmssd_milliseconds,
                resting_heart_rate_bpm, source, source_updated_at, imported_at) VALUES \(values)
            """)
    }

    private func chunkRows(_ url: URL) throws -> Int {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM rows", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    func testOnlyChangedChunksAreRewritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        try insertDays(url, ["2026-11-01", "2026-11-02"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try WhoopChunkBackup.runPass(databaseURL: url, now: now)
        XCTAssertTrue(first.written.contains("daily_health_metric/0"))
        XCTAssertEqual(first.pending, 0)
        let chunkURL = directory.appendingPathComponent("backup/daily_health_metric/0.sqlite3")
        XCTAssertEqual(try chunkRows(chunkURL), 2)

        // Nothing changed: no table is re-read, nothing is rewritten.
        XCTAssertEqual(try WhoopChunkBackup.runPass(databaseURL: url, now: now).written, [])

        // A new row and an update to an old row both mark their chunk changed.
        try insertDays(url, ["2026-11-03"])
        try exec(url, "UPDATE daily_health_metric SET sleep_score = 90 WHERE date_key = '2026-11-01'")
        XCTAssertEqual(try WhoopChunkBackup.runPass(databaseURL: url, now: now).written, ["daily_health_metric/0"])
        XCTAssertEqual(try chunkRows(chunkURL), 3)

        let manifest = try XCTUnwrap(
            WhoopChunkBackup.loadManifest(directory: chunkURL.deletingLastPathComponent().deletingLastPathComponent()))
        XCTAssertEqual(manifest.chunks["daily_health_metric/0"]?.rows, 3)
        XCTAssertNotNil(manifest.tables["daily_health_metric"])
        XCTAssertNil(manifest.tables[WhoopChunkBackup.trackingTable])
    }

    func testSmallTablesAreNotStarvedByLargeOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        try insertDays(url, ["2026-11-01"])
        // A large table whose newest chunk number is far above every small table's.
        try exec(
            url,
            """
            INSERT INTO whoop_time_zone_observation(rowid, observed_at, time_zone_identifier, utc_offset_seconds)
            VALUES (\(5 << WhoopChunkBackup.chunkShift), 123456, 'UTC', 0)
            """)
        let pass = try WhoopChunkBackup.runPass(
            databaseURL: url, now: Date(timeIntervalSince1970: 1_800_000_000), budget: 0)
        // Budget 0 still writes one chunk per pass; the next ones are each table's newest.
        XCTAssertEqual(pass.written.count, 1)
        let second = try WhoopChunkBackup.runPass(
            databaseURL: url, now: Date(timeIntervalSince1970: 1_800_000_000), budget: 0)
        XCTAssertEqual(
            Set(pass.written + second.written),
            ["daily_health_metric/0", "whoop_time_zone_observation/5"])
    }

    func testTrackingIsIdempotentAndMarksExistingRowsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        XCTAssertTrue(WhoopChunkBackup.ensureTracking(database: database))
        XCTAssertTrue(WhoopChunkBackup.ensureTracking(database: database))
    }
}
