import SQLite3
import XCTest

@testable import Sleep

extension WhoopSleepStateTests {
    func testVersion18DecoderPreservesMotionFieldsAndRejectsCorruption() {
        var frame = version18Frame(
            timestamp: 1_800_000_000,
            sleepState: 2,
            stepCounter: 54_321,
            cadenceRaw: 73,
            motionClassRaw: 4
        )

        let decoded = WhoopDecodedHistorical.decode(frame)
        XCTAssertEqual(decoded?.stepMotionCounter, 54_321)
        XCTAssertEqual(decoded?.stepCadenceRaw, 73)
        XCTAssertEqual(decoded?.motionClassRaw, 4)

        frame[57] ^= 0x01
        XCTAssertNil(WhoopDecodedHistorical.decode(frame))
    }

    func testStepSummaryCountsNormalAndWrappedDeltas() {
        let summary = WhoopStepDaySummary.summarize([
            WhoopStepCounterSample(timestamp: 0, counter: 65_532),
            WhoopStepCounterSample(timestamp: 1, counter: 65_534),
            WhoopStepCounterSample(timestamp: 2, counter: 2),
            WhoopStepCounterSample(timestamp: 3, counter: 5),
        ])

        XCTAssertEqual(summary.stepCount, 9)
        XCTAssertEqual(summary.counterWrapCount, 1)
        XCTAssertEqual(summary.rejectedDeltaCount, 0)
        XCTAssertEqual(summary.sampleCount, 4)
        XCTAssertEqual(summary.coverageFraction, 1, accuracy: 0.001)
    }

    func testStepSummaryRejectsImplausibleResetAndTracksCoverage() {
        let summary = WhoopStepDaySummary.summarize([
            WhoopStepCounterSample(timestamp: 0, counter: 30_000),
            WhoopStepCounterSample(timestamp: 10, counter: 2),
            WhoopStepCounterSample(timestamp: 11, counter: 5),
        ])

        XCTAssertEqual(summary.stepCount, 3)
        XCTAssertEqual(summary.rejectedDeltaCount, 1)
        XCTAssertEqual(summary.gapSeconds, 9)
        XCTAssertEqual(summary.spanSeconds, 12)
        XCTAssertEqual(summary.coverageFraction, 0.25, accuracy: 0.001)
    }

    func testStepSummaryRejectsAmbiguousWrapAcrossLongMissingInterval() {
        let summary = WhoopStepDaySummary.summarize([
            WhoopStepCounterSample(timestamp: 0, counter: 8_819),
            WhoopStepCounterSample(timestamp: 12 * 60 * 60, counter: 15),
            WhoopStepCounterSample(timestamp: 12 * 60 * 60 + 1, counter: 20),
        ])

        XCTAssertEqual(summary.stepCount, 5)
        XCTAssertEqual(summary.counterWrapCount, 0)
        XCTAssertEqual(summary.rejectedDeltaCount, 1)
    }

    func testCompletedOffloadMaterializesDailyStepsWithProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let timestamp = UInt32(Date().timeIntervalSince1970)

        let first = try await append(
            version18Frame(timestamp: timestamp, sleepState: 0, stepCounter: 100),
            store: store, peripheral: peripheral, sessionID: nil
        )
        XCTAssertTrue(first.success)
        let second = try await append(
            version18Frame(timestamp: timestamp + 1, sleepState: 0, stepCounter: 103),
            store: store, peripheral: peripheral, sessionID: nil
        )
        XCTAssertTrue(second.success)
        let completion = try await append(
            metadataFrame(type: 3),
            store: store, peripheral: peripheral, sessionID: nil
        )
        XCTAssertTrue(completion.success)

        let records: [DailyStepRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyStepRecords { continuation.resume(with: $0) }
        }
        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.stepCount, 3)
        XCTAssertEqual(record.sampleCount, 2)
        XCTAssertEqual(record.coverageFraction, 1, accuracy: 0.001)
        XCTAssertEqual(record.rejectedDeltaCount, 0)
        XCTAssertEqual(record.source, "whoop5_v18_step_counter")
        XCTAssertEqual(record.algorithmVersion, WhoopStepDaySummary.algorithmVersion)
    }

    func testStepMaterializationUsesPublishedWakeInsteadOfMidnight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }

        let parser = ISO8601DateFormatter()
        let firstWake = try XCTUnwrap(parser.date(from: "2027-01-14T15:00:00Z"))
        let nextWake = try XCTUnwrap(parser.date(from: "2027-01-15T15:00:00Z"))
        try insertWakeBoundary(dateKey: "2027-01-14", wokeAt: firstWake, databaseURL: databaseURL)
        try insertWakeBoundary(dateKey: "2027-01-15", wokeAt: nextWake, databaseURL: databaseURL)

        let peripheral = UUID()
        let samples: [(TimeInterval, UInt16)] = [
            (firstWake.timeIntervalSince1970 + 100, 100),
            // 2 a.m. local civil time: still Jan 14's physiological day.
            (nextWake.timeIntervalSince1970 - 8 * 60 * 60, 150),
            (nextWake.timeIntervalSince1970, 150),
            (nextWake.timeIntervalSince1970 + 100, 160),
        ]
        for (timestamp, counter) in samples {
            let result = try await append(
                version18Frame(
                    timestamp: UInt32(timestamp),
                    sleepState: 0,
                    stepCounter: counter
                ),
                store: store,
                peripheral: peripheral,
                sessionID: nil
            )
            XCTAssertTrue(result.success)
        }
        let completion = try await append(
            metadataFrame(type: 3),
            store: store,
            peripheral: peripheral,
            sessionID: nil
        )
        XCTAssertTrue(completion.success)

        let records: [DailyStepRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyStepRecords { continuation.resume(with: $0) }
        }
        XCTAssertEqual(records.map(\.dateKey), ["2027-01-14", "2027-01-15"])
        XCTAssertEqual(records.map(\.stepCount), [50, 10])
    }

    func testMotionBackfillRebuildsPreviouslyDecodedDaysAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let peripheral = UUID()
        let timestamp = UInt32(Date().timeIntervalSince1970)

        var initialStore: WhoopStore? = WhoopStore(
            databaseURL: databaseURL,
            runBackgroundDecoding: false
        )
        _ = try await append(
            version18Frame(timestamp: timestamp, sleepState: 0, stepCounter: 100),
            store: try XCTUnwrap(initialStore),
            peripheral: peripheral,
            sessionID: nil
        )
        _ = try await append(
            version18Frame(timestamp: timestamp + 1, sleepState: 0, stepCounter: 103),
            store: try XCTUnwrap(initialStore),
            peripheral: peripheral,
            sessionID: nil
        )

        // A restart requires the original SQLite connection to be closed.
        // Explicit shutdown avoids relying on ARC timing across async work.
        initialStore?.shutdownForTesting()
        initialStore = nil

        let restarted = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: true)
        defer { restarted.shutdownForTesting() }
        var records: [DailyStepRecord] = []
        for _ in 0..<100 {
            records = try await withCheckedThrowingContinuation { continuation in
                restarted.loadDailyStepRecords { continuation.resume(with: $0) }
            }
            if !records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.stepCount, 3)
        XCTAssertEqual(record.sampleCount, 2)
    }

    func testOfficialStepsOverrideOverlappingLocalDayAndJoinLocalTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                INSERT INTO whoop_official_daily_metric
                    (date_key, official_recovery_score, official_steps,
                     source_archive, source_manifest_sha256, imported_at)
                VALUES ('2026-08-31', 91, 7493, 'archive', 'manifest', 0);
                INSERT INTO whoop_daily_step_metric
                    (date_key, peripheral_id, step_count, sample_count, span_seconds,
                     coverage_fraction, gap_seconds, counter_wrap_count, rejected_delta_count,
                     source, algorithm_version, derived_at)
                VALUES
                    ('2026-08-31', 'strap', 7000, 1, 1, 1, 0, 0, 0, 'local', 1, 0),
                    ('2026-09-01', 'strap', 8123, 1, 1, 1, 0, 0, 0, 'local', 1, 0);
                """, nil, nil, nil), SQLITE_OK)

        let records: [DailyStepRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyStepRecords { continuation.resume(with: $0) }
        }

        XCTAssertEqual(records.map(\.stepCount), [7_493, 8_123])
        XCTAssertEqual(records.map(\.source), ["whoop_private_ios_api", "local"])
        let recovery: [DailyRecoveryRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyRecoveryRecords { continuation.resume(with: $0) }
        }
        XCTAssertEqual(recovery.map(\.score), [91])
        XCTAssertEqual(recovery.map(\.source), ["whoop_private_ios_api"])
    }
}
