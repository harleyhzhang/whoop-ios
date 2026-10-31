import SQLite3
import XCTest

@testable import Whoop

final class WhoopBackendReadTests: XCTestCase {
    func testScalarEmptyNullAndZeroAreDistinctAndBindingsChecked() throws {
        var candidate: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &candidate), SQLITE_OK)
        let database = try XCTUnwrap(candidate)
        defer { sqlite3_close(database) }
        XCTAssertEqual(try SQLiteRead.integer(database, sql: "SELECT 0"), .value(0))
        XCTAssertEqual(try SQLiteRead.integer(database, sql: "SELECT NULL"), .null)
        XCTAssertEqual(try SQLiteRead.integer(database, sql: "SELECT 1 WHERE 0"), .noRow)
        XCTAssertThrowsError(try SQLiteRead.requiredInteger(database, sql: "SELECT NULL"))
        XCTAssertThrowsError(try SQLiteRead.integer(database, sql: "SELECT 1 UNION ALL SELECT 2"))
        XCTAssertThrowsError(try SQLiteRead.integer(database, sql: "SELECT ?"))
        XCTAssertThrowsError(try SQLiteRead.integer(database, sql: "SELECT missing"))
        XCTAssertEqual(try SQLiteRead.integer(database, sql: "SELECT length(?)", bindings: [.blob(Data())]), .value(0))
        XCTAssertEqual(try SQLiteRead.text(database, sql: "SELECT ?", bindings: [.text("value")]), .value("value"))
    }

    func testFailureAfterFourRowsNeverReturnsPrefixAndFinalizesStatement() throws {
        var candidate: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &candidate), SQLITE_OK)
        let database = try XCTUnwrap(candidate)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_create_function_v2(
                database, "fail_on_five", 1, SQLITE_UTF8, nil,
                { context, _, arguments in
                    let value = sqlite3_value_int(arguments?[0])
                    if value == 5 {
                        sqlite3_result_error(context, "injected row five failure", -1)
                    } else {
                        sqlite3_result_int(context, value)
                    }
                }, nil, nil, nil), SQLITE_OK)
        let sql =
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<8) SELECT fail_on_five(x) FROM n"
        XCTAssertThrowsError(try SQLiteRead.rows(database, sql: sql, map: { sqlite3_column_int($0, 0) }))
        XCTAssertNil(sqlite3_next_stmt(database, nil))
        XCTAssertEqual(try SQLiteRead.requiredInteger(database, sql: "SELECT 12"), 12)
    }

    func testFailedHistoricalBackfillCannotWriteCompletionMarkerOrPublishPartialSleep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("fixture.sqlite3"), runBackgroundDecoding: false)
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        try store.queue.sync {
            let database = try XCTUnwrap(store.database)
            XCTAssertTrue(store.execute("DELETE FROM whoop_store_metadata WHERE key='local-sleep-score-backfill'"))
            XCTAssertTrue(store.execute("ALTER TABLE whoop_historical_sample RENAME TO retained_history"))
            XCTAssertFalse(store.backfillLocalSleepScoresIfNeeded())
            XCTAssertEqual(try store.metadataValue(database: database, key: "local-sleep-score-backfill"), .noRow)
            let snapshot = store.analyzeLatestSleep(includeProvisional: true)
            XCTAssertNil(snapshot.finalizedRecord)
            XCTAssertFalse(snapshot.evaluatedProvisional)
            XCTAssertThrowsError(try store.scalarInt(database, sql: "SELECT COUNT(*) FROM missing"))
        }
    }
}
