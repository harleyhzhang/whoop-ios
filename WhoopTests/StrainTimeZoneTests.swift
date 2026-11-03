import SQLite3
import XCTest

@testable import Whoop

final class StrainTimeZoneTests: XCTestCase {
    private let model = WhoopStrainModel(
        calibration: StrainCalibration(version: "synthetic", exponent: 2, loadScale: 1, scoreScale: 4),
        maximumHeartRate: 190)

    func testStaleTorontoObservationsRepairMixedOffsetsAndCivilMidnightWithoutRawWrites() throws {
        let fixture = try Fixture()
        let start = try timestamp("2026-11-02T05:00:00Z")
        try fixture.observation("2026-10-31T21:50:00Z", "America/Toronto", -14400)
        try fixture.observation("2026-11-03T00:33:00Z", "America/Toronto", -18000)
        try fixture.sample(start, offset: -14400)
        try fixture.sample(start + 20 * 3600, offset: -18000)
        // A stale -04:00 label would incorrectly put this sample on November 3.
        try fixture.sample(start + 23.5 * 3600, offset: -14400)
        let rawBefore = try fixture.rawRows()
        let repository = LocalStrainRepository()
        let now = Date(timeIntervalSince1970: start + 86400)
        let result = try repository.load(database: fixture.database, model: model, now: now)
        XCTAssertEqual(result.records.map(\.dateKey), ["2026-11-02"])
        XCTAssertEqual(result.records.first?.estimate?.observedSeconds, 18)
        let cache = try cache(result, day: "2026-11-02")
        XCTAssertTrue(try XCTUnwrap(cache["signature"] as? String).hasSuffix("|\(start)|\(start + 86400)"))
        try fixture.persist(result.derivations)
        XCTAssertTrue(try repository.load(database: fixture.database, model: model, now: now).derivations.isEmpty)
        let replay = try LocalStrainRepository().load(database: fixture.database, model: model, now: now)
        XCTAssertTrue(replay.derivations.isEmpty)
        XCTAssertEqual(replay.records.first?.score, result.records.first?.score)
        XCTAssertEqual(try fixture.rawRows(), rawBefore)
    }

    func testSpringAndFallDSTUse23And25HourCalendarDays() throws {
        for (day, first, next, duration) in [
            ("2026-03-08", "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23.0 * 3600),
            ("2026-11-01", "2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25.0 * 3600),
        ] {
            let fixture = try Fixture()
            try fixture.observation("2026-01-01T12:00:00Z", "America/Toronto", -18000)
            let start = try timestamp(first)
            let end = try timestamp(next)
            // Every legacy row carries the same stale offset. Calendar rules,
            // rather than that offset or the current timezone, define the day.
            try fixture.sql(
                """
                WITH RECURSIVE samples(t) AS (SELECT \(start) UNION ALL SELECT t+6 FROM samples WHERE t+6 < \(end))
                INSERT INTO whoop_historical_sample(sample_at,peripheral_id,step_utc_offset_seconds,heart_rate,ordinal)
                SELECT t,'synthetic',-18000,140,0 FROM samples;
                """)
            let result = try LocalStrainRepository().load(
                database: fixture.database, model: model, now: Date(timeIntervalSince1970: end))
            let record = try XCTUnwrap(result.records.first { $0.dateKey == day })
            XCTAssertEqual(result.records.count, 1)
            XCTAssertEqual(record.estimate?.observedSeconds, duration)
            XCTAssertEqual(record.estimate?.coverage, 1)
            XCTAssertTrue(
                try XCTUnwrap(try cache(result, day: day)["signature"] as? String).hasSuffix("|\(start)|\(end)"))
        }
    }

    func testTimezoneOnlyChangesInvalidateSlicesAndScoresButRedundantObservationsDoNot() throws {
        let fixture = try Fixture()
        let start = try timestamp("2026-11-02T05:00:00Z")
        try fixture.sample(start + 3600, offset: -14400)
        try fixture.sample(start + 7200, offset: -18000)
        let now = Date(timeIntervalSince1970: start + 86400)
        let repository = LocalStrainRepository()
        let unknown = try repository.load(database: fixture.database, model: model, now: now)
        XCTAssertTrue(unknown.records.isEmpty)
        try fixture.persist(unknown.derivations)
        try fixture.observation("2026-10-31T12:00:00Z", "America/Toronto", -14400)
        let repaired = try repository.load(database: fixture.database, model: model, now: now)
        XCTAssertEqual(repaired.records.count, 1)
        XCTAssertTrue(repaired.derivations.keys.contains { $0.hasPrefix("local-strain-input.v2.") })
        try fixture.persist(repaired.derivations)
        try fixture.observation("2026-11-03T12:00:00Z", "America/Toronto", -18000)
        XCTAssertTrue(try repository.load(database: fixture.database, model: model, now: now).derivations.isEmpty)
        try fixture.sql("UPDATE whoop_time_zone_observation SET time_zone_identifier='America/Chicago'")
        let changed = try repository.load(database: fixture.database, model: model, now: now)
        XCTAssertNotEqual(
            try cache(changed, day: "2026-11-02")["signature"] as? String,
            try cache(repaired, day: "2026-11-02")["signature"] as? String)
        try fixture.persist(changed.derivations)
        XCTAssertTrue(
            try LocalStrainRepository().load(database: fixture.database, model: model, now: now).derivations.isEmpty)
    }

    func testTravelAndInvalidIdentifiersStayUnknownWhileOfficialScoreWins() throws {
        for identifier in ["Europe/London", "not/a/timezone"] {
            let fixture = try Fixture()
            let start = try timestamp("2026-11-02T05:00:00Z")
            try fixture.observation("2026-11-01T12:00:00Z", "America/Toronto", -18000)
            try fixture.observation("2026-11-03T12:00:00Z", identifier, 0)
            try fixture.sample(start + 3600, offset: -18000)
            let now = Date(timeIntervalSince1970: start + 86400)
            let repository = LocalStrainRepository()
            let result = try repository.load(database: fixture.database, model: model, now: now)
            XCTAssertTrue(result.records.isEmpty)
            try fixture.sql("INSERT INTO whoop_official_daily_metric VALUES('2026-11-02',0)")
            let official = try repository.load(database: fixture.database, model: model, now: now)
            XCTAssertEqual(official.records.first?.score, 0)
            XCTAssertNil(official.records.first?.estimate)
        }
    }

    func testRecordedOffsetResolvesAtSampleDateAndInvalidIdentifierFallsBack() throws {
        XCTAssertEqual(
            RecordedTimeZone.offset(
                identifier: "America/Toronto", recordedOffset: -14400,
                at: try date("2026-11-02T12:00:00Z")), -18000)
        XCTAssertEqual(
            RecordedTimeZone.offset(
                identifier: "America/Toronto", recordedOffset: -18000,
                at: try date("2026-07-02T12:00:00Z")), -14400)
        XCTAssertEqual(
            RecordedTimeZone.offset(
                identifier: "invalid", recordedOffset: 3600,
                at: try date("2026-11-02T12:00:00Z")), 3600)
    }

    private func cache(_ result: LocalStrainRepository.Result, day: String) throws -> [String: Any] {
        let value = try XCTUnwrap(result.derivations.first { $0.key.hasPrefix("local-strain.\(day).") }?.value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func timestamp(_ value: String) throws -> Double { try date(value).timeIntervalSince1970 }

    private final class Fixture {
        let database: OpaquePointer

        init() throws {
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
            database = try XCTUnwrap(handle)
            try sql(
                """
                CREATE TABLE whoop_time_zone_observation(observed_at REAL,time_zone_identifier TEXT,utc_offset_seconds INTEGER);
                CREATE TABLE whoop_store_metadata(key TEXT PRIMARY KEY,value TEXT);
                CREATE TABLE whoop_official_daily_metric(date_key TEXT,official_day_strain REAL);
                CREATE TABLE whoop_historical_sample(id INTEGER PRIMARY KEY,sample_at REAL,peripheral_id TEXT,
                    step_date_key TEXT,step_utc_offset_seconds INTEGER,heart_rate REAL,
                    step_motion_counter INTEGER,sleep_state INTEGER,ordinal INTEGER);
                CREATE INDEX historical_time ON whoop_historical_sample(peripheral_id,sample_at);
                """)
            try sql(WhoopStrainInputIndex.schema)
        }

        deinit { sqlite3_close(database) }

        func sql(_ value: String) throws {
            guard sqlite3_exec(database, value, nil, nil, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "SyntheticSQLite", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
            }
        }

        func observation(_ instant: String, _ zone: String, _ offset: Int) throws {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: instant))
            try sql("INSERT INTO whoop_time_zone_observation VALUES(\(date.timeIntervalSince1970),'\(zone)',\(offset))")
        }

        func sample(_ timestamp: Double, offset: Int) throws {
            try sql(
                "INSERT INTO whoop_historical_sample(sample_at,peripheral_id,step_utc_offset_seconds,heart_rate,ordinal) VALUES(\(timestamp),'synthetic',\(offset),140,0)"
            )
        }

        func persist(_ values: [String: String]) throws {
            for (key, value) in values {
                try sql(
                    "INSERT OR REPLACE INTO whoop_store_metadata VALUES('\(key)','\(value.replacingOccurrences(of: "'", with: "''"))')"
                )
            }
        }

        func rawRows() throws -> String {
            var handle: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    database,
                    "SELECT group_concat(id || ':' || sample_at || ':' || step_utc_offset_seconds || ':' || heart_rate) FROM whoop_historical_sample",
                    -1, &handle, nil), SQLITE_OK)
            let statement = try XCTUnwrap(handle)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return try XCTUnwrap(sqlite3_column_text(statement, 0)).withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
