import Foundation
import SQLite3
import XCTest

@testable import Sleep

final class WhoopStorageTelemetryTests: XCTestCase {
    func testLatencyWindowTracksOutcomesBucketsAndFrameTypes() {
        var window = WhoopIngestionLatencyWindow()

        window.record(
            outcome: .unique,
            transactionNanoseconds: 750_000,
            queueWaitNanoseconds: 250_000,
            frameType: .historicalSample,
            payloadBytes: 80,
            retryDetectionEnabled: true
        )
        window.record(
            outcome: .retry,
            transactionNanoseconds: 6_000_000,
            queueWaitNanoseconds: 1_500_000,
            frameType: .historicalSample,
            payloadBytes: 80,
            retryDetectionEnabled: true
        )
        window.record(
            outcome: .failed,
            transactionNanoseconds: 110_000_000,
            queueWaitNanoseconds: 150_000_000,
            frameType: nil,
            payloadBytes: 12,
            retryDetectionEnabled: false
        )

        XCTAssertEqual(window.deliveryCount, 3)
        XCTAssertEqual(window.uniqueCount, 1)
        XCTAssertEqual(window.retryCount, 1)
        XCTAssertEqual(window.failedCount, 1)
        XCTAssertEqual(window.maximumNanoseconds, 110_000_000)
        XCTAssertEqual(window.transactionLatencyBucketCounts[1], 1)
        XCTAssertEqual(window.transactionLatencyBucketCounts[4], 1)
        XCTAssertEqual(window.transactionLatencyBucketCounts[8], 1)
        XCTAssertEqual(window.queueWaitBucketCounts[0], 1)
        XCTAssertEqual(window.queueWaitBucketCounts[2], 1)
        XCTAssertEqual(window.queueWaitBucketCounts[8], 1)
        XCTAssertEqual(window.frameOutcomes[47].suppressedRetries, 1)
        XCTAssertEqual(window.frameOutcomes[47].payloadBytes, 160)
        XCTAssertEqual(window.frameOutcomes[256].retryDetectionDisabled, 1)
    }

    func testHotCounterPerformance() {
        measure {
            var window = WhoopIngestionLatencyWindow()
            for index in 0..<100_000 {
                window.record(
                    outcome: index.isMultiple(of: 10) ? .retry : .unique,
                    transactionNanoseconds: UInt64(index + 1),
                    queueWaitNanoseconds: UInt64(index),
                    frameType: .historicalSample,
                    payloadBytes: 80,
                    retryDetectionEnabled: true
                )
            }
            XCTAssertEqual(window.deliveryCount, 100_000)
        }
    }

    func testLatencyBucketBoundaryIsInclusive() {
        var window = WhoopIngestionLatencyWindow()
        window.record(
            outcome: .unique,
            transactionNanoseconds: 500_000,
            queueWaitNanoseconds: 500_001,
            frameType: .unknown(1),
            payloadBytes: 1,
            retryDetectionEnabled: true
        )
        XCTAssertEqual(window.transactionLatencyBucketCounts[0], 1)
        XCTAssertEqual(window.queueWaitBucketCounts[1], 1)
    }

    func testFailedCensusRetriesAreBackedOffWithoutDelayingDailySnapshots() {
        let now: TimeInterval = 1_800_000_000
        XCTAssertFalse(
            WhoopStorageTelemetry.censusIsDue(
                lastAttemptAt: now - 60,
                lastSnapshotAt: nil,
                now: now
            ))
        XCTAssertTrue(
            WhoopStorageTelemetry.censusIsDue(
                lastAttemptAt: now - WhoopStorageTelemetry.failedCensusRetryInterval,
                lastSnapshotAt: nil,
                now: now
            ))
        XCTAssertFalse(
            WhoopStorageTelemetry.censusIsDue(
                lastAttemptAt: now - 3_600,
                lastSnapshotAt: now - 3_600,
                now: now
            ))
        XCTAssertTrue(
            WhoopStorageTelemetry.censusIsDue(
                lastAttemptAt: now - WhoopStorageTelemetry.minimumSnapshotInterval,
                lastSnapshotAt: now - WhoopStorageTelemetry.minimumSnapshotInterval,
                now: now
            ))
    }

    func testSnapshotMeasuresDatabaseWithoutChangingSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("Could not create telemetry fixture") }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE whoop_raw_packet(
                    id TEXT PRIMARY KEY,
                    received_at REAL NOT NULL,
                    peripheral_id TEXT NOT NULL,
                    characteristic_uuid TEXT NOT NULL,
                    frame_type INTEGER,
                    payload BLOB NOT NULL
                );
                CREATE TABLE whoop_packet_replay(
                    signature BLOB PRIMARY KEY,
                    first_packet_id TEXT NOT NULL,
                    duplicate_count INTEGER NOT NULL,
                    last_received_at REAL NOT NULL
                );
                CREATE TABLE heart_rate_sample(value INTEGER);
                CREATE TABLE whoop_historical_sample(value INTEGER);
                CREATE TABLE whoop_ppg_packet(value INTEGER);
                CREATE TABLE whoop_decode_failure(value INTEGER);
                CREATE TABLE whoop_offload_session(value INTEGER);
                CREATE TABLE daily_health_metric(value INTEGER);
                CREATE TABLE whoop_daily_step_metric(value INTEGER);
                CREATE TABLE whoop_daily_recovery_metric(value INTEGER);
                CREATE TABLE whoop_api_numeric_metric(value INTEGER);
                CREATE TABLE whoop_api_source_record(value INTEGER);
                CREATE TABLE whoop_time_zone_observation(value INTEGER);
                CREATE TABLE whoop_official_daily_metric(value INTEGER);
                CREATE TABLE whoop_latest_heart_rate(value INTEGER);
                INSERT INTO whoop_raw_packet VALUES
                    ('p1', 1, 'peripheral', 'characteristic-a', 47, X'010203'),
                    ('p2', 2, 'peripheral', 'characteristic-b', 36, X'0405');
                INSERT INTO whoop_packet_replay VALUES(X'01', 'p1', 2, 3);
                INSERT INTO whoop_historical_sample VALUES(1);
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        let schemaBefore = scalarText(database, sql: "SELECT group_concat(name, ',') FROM sqlite_master")
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let telemetry = WhoopStorageTelemetry(
            databaseURL: databaseURL,
            ownerQueue: DispatchQueue(label: "storage-telemetry-test"),
            now: startedAt
        )
        XCTAssertTrue(telemetry.captureSynchronouslyForTesting(database: database, now: startedAt))
        telemetry.recordIngestion(
            outcome: .unique,
            transactionNanoseconds: 2_000_000,
            queueWaitNanoseconds: 1_000_000,
            frameType: .historicalSample,
            payloadBytes: 3,
            retryDetectionEnabled: true,
            now: startedAt
        )
        XCTAssertTrue(telemetry.captureSynchronouslyForTesting(database: database, now: startedAt))
        let schemaAfter = scalarText(database, sql: "SELECT group_concat(name, ',') FROM sqlite_master")

        let data = try Data(contentsOf: telemetry.reportURL)
        let report = try JSONDecoder().decode(WhoopStorageTelemetryDocument.self, from: data)
        let snapshot = try XCTUnwrap(report.snapshots.last)
        XCTAssertEqual(schemaAfter, schemaBefore)
        XCTAssertEqual(snapshot.uniquePackets, 2)
        XCTAssertEqual(snapshot.schemaVersion, 0)
        XCTAssertFalse(snapshot.sourceCommit.isEmpty)
        XCTAssertEqual(snapshot.rawPayloadBytes, 5)
        XCTAssertEqual(snapshot.sourcePairCount, 2)
        XCTAssertEqual(snapshot.derivedTableRows["whoop_historical_sample"], 1)
        let frame47 = snapshot.frameRetries.first { $0.frameType == "47" }
        XCTAssertEqual(frame47?.allHistoricalUniquePackets, 1)
        XCTAssertEqual(frame47?.retryEligibleUniquePackets, 1)
        XCTAssertEqual(frame47?.retries, 2)
        XCTAssertEqual(snapshot.ingestion.uniqueCount, 1)
        XCTAssertEqual(snapshot.passiveCheckpointResult, SQLITE_OK)
        XCTAssertGreaterThanOrEqual(snapshot.walLogFrames, 0)
        XCTAssertGreaterThan(snapshot.snapshotCollectionNanoseconds, 0)
        XCTAssertFalse(report.fileSamples.isEmpty)
        XCTAssertEqual(report.pendingIngestion.deliveryCount, 0)
    }

    func testSnapshotRetentionIsBounded() throws {
        let fixture = try makeEmptyFixture()
        defer {
            sqlite3_close(fixture.database)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let telemetry = WhoopStorageTelemetry(
            databaseURL: fixture.databaseURL,
            ownerQueue: DispatchQueue(label: "storage-telemetry-retention-test"),
            now: start
        )

        for day in 0..<(WhoopStorageTelemetry.maximumSnapshots + 3) {
            XCTAssertTrue(
                telemetry.captureSynchronouslyForTesting(
                    database: fixture.database,
                    now: start.addingTimeInterval(Double(day) * 86_400)
                )
            )
        }

        let report = try JSONDecoder().decode(
            WhoopStorageTelemetryDocument.self,
            from: Data(contentsOf: telemetry.reportURL)
        )
        XCTAssertEqual(report.snapshots.count, WhoopStorageTelemetry.maximumSnapshots)
    }

    func testInterruptedCensusCountersMergeBackOnReload() throws {
        let fixture = try makeEmptyFixture()
        defer {
            sqlite3_close(fixture.database)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        var pending = WhoopIngestionLatencyWindow()
        pending.record(
            outcome: .unique,
            transactionNanoseconds: 1,
            queueWaitNanoseconds: 2,
            frameType: .historicalSample,
            payloadBytes: 3,
            retryDetectionEnabled: true
        )
        var inFlight = WhoopIngestionLatencyWindow()
        inFlight.record(
            outcome: .retry,
            transactionNanoseconds: 4,
            queueWaitNanoseconds: 5,
            frameType: .historicalSample,
            payloadBytes: 6,
            retryDetectionEnabled: true
        )
        let reportURL = fixture.directory.appendingPathComponent("storage-telemetry-v1.json")
        let document = WhoopStorageTelemetryDocument(
            updatedAt: 1_800_000_000,
            snapshots: [],
            fileSamples: [],
            pendingIngestion: pending,
            inFlightIngestion: inFlight,
            writeFailureCount: 0,
            censusFailureCount: 0
        )
        try JSONEncoder().encode(document).write(to: reportURL)

        let telemetry = WhoopStorageTelemetry(
            databaseURL: fixture.databaseURL,
            ownerQueue: DispatchQueue(label: "storage-telemetry-reload-test"),
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )
        telemetry.flush(now: Date(timeIntervalSince1970: 1_800_000_100))
        let reloaded = try JSONDecoder().decode(
            WhoopStorageTelemetryDocument.self,
            from: Data(contentsOf: reportURL)
        )
        XCTAssertNil(reloaded.inFlightIngestion)
        XCTAssertEqual(reloaded.pendingIngestion.deliveryCount, 2)
        XCTAssertEqual(reloaded.pendingIngestion.uniqueCount, 1)
        XCTAssertEqual(reloaded.pendingIngestion.retryCount, 1)
    }

    func testMalformedFixedArraysAreRejectedInsteadOfCrashingHotPath() throws {
        let fixture = try makeEmptyFixture()
        defer {
            sqlite3_close(fixture.database)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        var malformed = WhoopIngestionLatencyWindow()
        malformed.frameOutcomes.removeLast()
        let reportURL = fixture.directory.appendingPathComponent("storage-telemetry-v1.json")
        let document = WhoopStorageTelemetryDocument(
            updatedAt: 1_800_000_000,
            snapshots: [],
            fileSamples: [],
            pendingIngestion: malformed,
            inFlightIngestion: nil,
            writeFailureCount: 0,
            censusFailureCount: 0
        )
        try JSONEncoder().encode(document).write(to: reportURL)

        let telemetry = WhoopStorageTelemetry(
            databaseURL: fixture.databaseURL,
            ownerQueue: DispatchQueue(label: "storage-telemetry-malformed-test"),
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )
        telemetry.flush(now: Date(timeIntervalSince1970: 1_800_000_100))
        let reloaded = try JSONDecoder().decode(
            WhoopStorageTelemetryDocument.self,
            from: Data(contentsOf: reportURL)
        )
        XCTAssertEqual(reloaded.pendingIngestion.frameOutcomes.count, 257)
        XCTAssertEqual(reloaded.pendingIngestion.deliveryCount, 0)
    }

    private func makeEmptyFixture() throws -> (
        directory: URL, databaseURL: URL, database: OpaquePointer
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "WhoopStorageTelemetryTests", code: 1)
        }
        let schema = """
            CREATE TABLE whoop_raw_packet(
                id TEXT PRIMARY KEY, received_at REAL, peripheral_id TEXT,
                characteristic_uuid TEXT, frame_type INTEGER, payload BLOB
            );
            CREATE TABLE whoop_packet_replay(
                signature BLOB PRIMARY KEY, first_packet_id TEXT,
                duplicate_count INTEGER, last_received_at REAL
            );
            CREATE TABLE heart_rate_sample(value INTEGER);
            CREATE TABLE whoop_historical_sample(value INTEGER);
            CREATE TABLE whoop_ppg_packet(value INTEGER);
            CREATE TABLE whoop_decode_failure(value INTEGER);
            CREATE TABLE whoop_offload_session(value INTEGER);
            CREATE TABLE daily_health_metric(value INTEGER);
            CREATE TABLE whoop_daily_step_metric(value INTEGER);
            CREATE TABLE whoop_daily_recovery_metric(value INTEGER);
            CREATE TABLE whoop_api_numeric_metric(value INTEGER);
            CREATE TABLE whoop_api_source_record(value INTEGER);
            CREATE TABLE whoop_time_zone_observation(value INTEGER);
            CREATE TABLE whoop_official_daily_metric(value INTEGER);
            CREATE TABLE whoop_latest_heart_rate(value INTEGER);
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw NSError(domain: "WhoopStorageTelemetryTests", code: 2)
        }
        return (directory, databaseURL, database)
    }

    private func scalarText(_ database: OpaquePointer, sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: text)
    }
}
