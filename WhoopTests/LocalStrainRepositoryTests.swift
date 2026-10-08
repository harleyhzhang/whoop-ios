import SQLite3
import XCTest

@testable import Whoop

final class LocalStrainRepositoryTests: XCTestCase {
    func testReadOnlyReplayCacheInvalidationAndOfficialPrecedence() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        func sql(_ value: String) throws {
            XCTAssertEqual(
                sqlite3_exec(database, value, nil, nil, nil), SQLITE_OK,
                String(cString: sqlite3_errmsg(database)))
        }
        try sql(
            """
            CREATE TABLE whoop_store_metadata(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE whoop_official_daily_metric(date_key TEXT, official_day_strain REAL);
            CREATE TABLE whoop_historical_sample(id INTEGER PRIMARY KEY, sample_at REAL,
                peripheral_id TEXT, step_date_key TEXT, step_utc_offset_seconds INTEGER,
                heart_rate REAL, step_motion_counter INTEGER, sleep_state INTEGER, ordinal INTEGER);
            """)
        try sql("CREATE INDEX historical_time ON whoop_historical_sample(peripheral_id, sample_at)")
        let start = try XCTUnwrap(DayKey.date(from: "2026-01-02", timeZone: .gmt))
            .addingTimeInterval(-12 * 3_600).timeIntervalSince1970
        let now = Date(timeIntervalSince1970: start + 86_460)
        try sql("BEGIN")
        for index in 0..<14_400 {
            try sql(
                "INSERT INTO whoop_historical_sample VALUES (\(index + 1),\(start + Double(index * 6)),'synthetic','2026-01-02',0,110,0,0,0)"
            )
        }
        try sql("COMMIT")
        try sql("UPDATE whoop_historical_sample SET step_date_key = '2026-01-01' WHERE sample_at < \(start + 7 * 3600)")
        let health = DailyHealthRecord(
            dateKey: "2026-01-02", sleepScore: 80,
            sleepDurationMinutes: 480, hrvRMSSDMilliseconds: 60, restingHeartRateBPM: 50,
            sleepID: nil, cycleID: nil, source: "synthetic", sourceArchive: nil,
            sourceUpdatedAt: "synthetic")
        let model = WhoopStrainModel(
            calibration: StrainCalibration(
                version: "synthetic",
                exponent: 2, loadScale: 1, scoreScale: 4), maximumHeartRate: 190)
        // Initial materialization also covers authentic pre-migration rows.
        try sql(WhoopStrainInputIndex.schema)
        let repository = LocalStrainRepository()
        let first = try repository.load(database: database, health: [health], model: model, now: now)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(first.records.first?.estimate?.coverage, 1)
        XCTAssertEqual(first.records.first?.estimate?.probableStrengthSessions, 0)
        XCTAssertEqual(first.derivations.keys.filter { $0.hasPrefix("local-strain.") }.count, 2)
        // Persist through the same existing metadata projection used by the store writer.
        for (key, value) in first.derivations {
            try sql(
                "INSERT INTO whoop_store_metadata VALUES ('\(key)', '\(value.replacingOccurrences(of: "'", with: "''"))')"
            )
        }
        let operations = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        operations.initialize(to: 0)
        defer {
            operations.deinitialize(count: 1)
            operations.deallocate()
        }
        sqlite3_progress_handler(
            database, 100,
            { context in
                context?.assumingMemoryBound(to: Int.self).pointee += 100
                return 0
            }, operations)
        let cached = try repository.load(database: database, health: [health], model: model, now: now)
        let relaunched = try LocalStrainRepository().load(database: database, health: [health], model: model, now: now)
        XCTAssertTrue(relaunched.derivations.isEmpty)
        XCTAssertEqual(relaunched.records.first?.score, first.records.first?.score)
        sqlite3_progress_handler(database, 0, nil, nil)
        XCTAssertLessThan(operations.pointee, 5000, "A cache hit must not walk historical rows")
        XCTAssertTrue(cached.derivations.isEmpty)
        XCTAssertEqual(cached.records.first?.score, first.records.first?.score)
        try sql("UPDATE whoop_historical_sample SET heart_rate = 135 WHERE id=1")
        XCTAssertEqual(
            try repository.load(database: database, health: [health], model: model, now: now).derivations.keys.filter {
                $0.hasPrefix("local-strain.")
            }.count, 1)
        try sql("INSERT INTO whoop_historical_sample VALUES (20000,\(start + 10),'synthetic','2026-01-02',0,130,0,0,1)")
        let changed = try repository.load(database: database, health: [health], model: model, now: now)
        XCTAssertEqual(
            changed.derivations.keys.filter { $0.hasPrefix("local-strain.") }.count, 1,
            "Late-arriving samples invalidate cached days")
        try sql("UPDATE whoop_historical_sample SET step_utc_offset_seconds = 3600 WHERE id=1")
        XCTAssertTrue(try repository.load(database: database, health: [health], model: model, now: now).records.isEmpty)
        try sql("DELETE FROM whoop_historical_sample WHERE id=1")
        XCTAssertEqual(
            try repository.load(database: database, health: [health], model: model, now: now).records.count, 1,
            "Deleting a conflicting offset must restore eligibility")
        try sql("BEGIN")
        try sql("UPDATE whoop_historical_sample SET step_utc_offset_seconds=3600 WHERE id=2")
        try sql("ROLLBACK")
        XCTAssertEqual(
            try repository.load(database: database, health: [health], model: model, now: now).records.count, 1)
        try sql("INSERT INTO whoop_official_daily_metric VALUES ('2026-01-02',12.3)")
        let official = try repository.load(database: database, health: [health], model: model, now: now)
        XCTAssertEqual(official.records.first?.score, 12.3)
        XCTAssertNil(official.records.first?.estimate)
        XCTAssertEqual(
            try repository.load(database: database, health: [], model: nil, now: now).records.first?.score, 12.3)
    }
}
