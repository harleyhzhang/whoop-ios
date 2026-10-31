import SQLite3
import XCTest

@testable import Whoop

final class WhoopStrainProjectionTests: XCTestCase {
    func testBackfillMetadataPublishesAtomicallyAndRollsBackOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("test.sqlite3"), runBackgroundDecoding: false)
        defer {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        store.queue.sync {
            guard let database = store.database else { return XCTFail("Missing temporary database") }
            XCTAssertTrue(
                store.execute(
                    "CREATE TEMP TRIGGER reject_projection BEFORE INSERT ON whoop_store_metadata WHEN NEW.key='projection-b' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
                ))
            XCTAssertFalse(store.persistStrainDerivations(["projection-a": "day", "projection-b": "summary"]))
            XCTAssertNil(store.metadataValue(database: database, key: "projection-a"))
            XCTAssertNil(store.metadataValue(database: database, key: "projection-b"))
            XCTAssertTrue(store.execute("DROP TRIGGER reject_projection"))
            XCTAssertTrue(store.persistStrainDerivations(["projection-a": "day", "projection-b": "summary"]))
            XCTAssertEqual(store.metadataValue(database: database, key: "projection-a"), "day")
            XCTAssertEqual(store.metadataValue(database: database, key: "projection-b"), "summary")
        }
    }
}
