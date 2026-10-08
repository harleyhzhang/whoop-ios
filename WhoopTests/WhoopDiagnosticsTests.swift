import SQLite3
import XCTest

@testable import Whoop

final class WhoopDiagnosticsTests: XCTestCase {
    func testReportReadsCommittedDataWithoutWaitingForWriterOrDerivingMetrics() throws {
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
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<2 {
            let time = now.timeIntervalSince1970 - Double(index * 60)
            let sql = """
                INSERT INTO whoop_raw_packet(id, received_at, peripheral_id, characteristic_uuid, payload)
                VALUES ('synthetic-\(index)', \(time), 'synthetic', 'synthetic', X'00');
                INSERT INTO whoop_historical_sample(sample_at,source_packet_id,peripheral_id,protocol_version,
                    heart_rate,rr_intervals_json,sleep_state,decoder_version,step_utc_offset_seconds)
                VALUES (\(time),'synthetic-\(index)','synthetic',18,60,'[]',2,3,0);
                """
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(database)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.blockWriterForTesting(started: started, release: release)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        let report = try WhoopDiagnosticsReader.read(at: url, now: now)
        XCTAssertEqual(report.sampleCount, 2)
        XCTAssertEqual(report.historicalSampleTotal, 2)
        XCTAssertNil(report.rawType47PacketTotal)
        XCTAssertEqual(report.sessions.count, 1)
        XCTAssertNil(report.sessions.first?.storedSleepID)
        XCTAssertEqual(report.sessions.first?.verdict, "pending; evidence incomplete")
    }

    func testMissingDatabaseIsNotCreatedByDiagnostics() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try WhoopDiagnosticsReader.read(at: url, now: .now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
