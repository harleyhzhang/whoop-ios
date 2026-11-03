import SQLite3
import XCTest

@testable import Whoop

final class WhoopStrainProjectionTests: XCTestCase {
    func testHistoricalIngestResolvesRecordedIdentifierAtSampleInstant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("test.sqlite3"), runBackgroundDecoding: false)
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        try store.queue.sync {
            let database = try XCTUnwrap(store.database)
            XCTAssertTrue(store.execute("DELETE FROM whoop_time_zone_observation"))
            XCTAssertTrue(
                store.execute(
                    "INSERT INTO whoop_time_zone_observation VALUES(1793480400,'America/Toronto',-14400)"))
            let winter = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z"))
            let summer = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-02T12:00:00Z"))
            XCTAssertEqual(try store.nearestRecordedUTCOffset(database: database, sampleAt: winter), -18000)
            XCTAssertEqual(try store.nearestRecordedUTCOffset(database: database, sampleAt: summer), -14400)
        }
    }

    func testBackfillMetadataPublishesAtomicallyAndRollsBackOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("test.sqlite3"), runBackgroundDecoding: false)
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        try store.queue.sync {
            guard let database = store.database else { return XCTFail("Missing temporary database") }
            XCTAssertTrue(
                store.execute(
                    "CREATE TEMP TRIGGER reject_projection BEFORE INSERT ON whoop_store_metadata WHEN NEW.key='projection-b' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
                ))
            XCTAssertFalse(store.persistStrainDerivations(["projection-a": "day", "projection-b": "summary"]))
            XCTAssertEqual(try store.metadataValue(database: database, key: "projection-a"), .noRow)
            XCTAssertEqual(try store.metadataValue(database: database, key: "projection-b"), .noRow)
            XCTAssertTrue(store.execute("DROP TRIGGER reject_projection"))
            XCTAssertTrue(store.persistStrainDerivations(["projection-a": "day", "projection-b": "summary"]))
            XCTAssertEqual(try store.metadataValue(database: database, key: "projection-a"), .value("day"))
            XCTAssertEqual(try store.metadataValue(database: database, key: "projection-b"), .value("summary"))
        }
    }
}
