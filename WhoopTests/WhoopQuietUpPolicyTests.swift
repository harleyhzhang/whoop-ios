import XCTest

@testable import Whoop

private typealias Row = WhoopStore.HistoricalRow

extension WhoopSleepStateTests {
    /// Thirty-second samples from `start` for `minutes`, with a flat step
    /// counter unless a per-sample increment is given.
    private func run(
        from start: TimeInterval,
        minutes: Int,
        state: Int,
        heartRate: Int = 56,
        steps: UInt16 = 0,
        stepsPerSample: UInt16 = 0,
        counted: Bool = true
    ) -> [Row] {
        (0..<(minutes * 2)).map { index in
            Row(
                timestamp: start + Double(index) * 30,
                heartRate: heartRate,
                sleepState: SleepState(rawValue: state),
                stepCounter: counted ? steps &+ UInt16(index) &* stepsPerSample : nil
            )
        }
    }

    /// The October 30 shape: asleep, 40 quiet `up` minutes, asleep, 68 quiet
    /// `up` minutes, asleep, then the real morning wake.
    private func octoberThirtiethNight(secondUp: (TimeInterval) -> [Row]) -> [Row] {
        var rows = run(from: 0, minutes: 133, state: 2, heartRate: 57)
        rows += run(from: 133 * 60, minutes: 40, state: 3, heartRate: 56)
        rows += run(from: 173 * 60, minutes: 35, state: 2, heartRate: 56)
        rows += secondUp(208 * 60)
        rows += run(from: 276 * 60, minutes: 160, state: 2, heartRate: 59)
        return rows
    }

    func testQuietBoundedUpStretchesCountAsSleep() {
        let night = octoberThirtiethNight { run(from: $0, minutes: 68, state: 3, heartRate: 56) }
        let asleep = night.filter { $0.sleepState == .asleep }

        let explicit = WhoopStore.elapsedSeconds(across: asleep, cadence: 30) / 60
        let bridged = WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30) / 60

        XCTAssertEqual(explicit, 328, accuracy: 0.01)
        XCTAssertEqual(bridged, 108, accuracy: 0.01)
    }

    func testRaisedHeartRateKeepsStretchAwake() {
        let night = octoberThirtiethNight { run(from: $0, minutes: 68, state: 3, heartRate: 64) }

        XCTAssertEqual(
            WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30) / 60, 40, accuracy: 0.01)
    }

    func testWalkingBurstKeepsStretchAwake() {
        let night = octoberThirtiethNight { start in
            var rows = run(from: start, minutes: 30, state: 3)
            // 9 steps every 30 s for 15 minutes: 90 steps within five minutes.
            rows += run(from: start + 30 * 60, minutes: 15, state: 3, stepsPerSample: 9)
            let resumed = rows.last?.stepCounter ?? 0
            rows += run(from: start + 45 * 60, minutes: 23, state: 3, steps: resumed)
            return rows
        }

        XCTAssertEqual(
            WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30) / 60, 40, accuracy: 0.01)
    }

    func testSleepLevelStepNoiseStillCounts() {
        // About 60 steps in any five minutes, the most seen inside explicit sleep.
        let night = octoberThirtiethNight { run(from: $0, minutes: 68, state: 3, stepsPerSample: 6) }

        XCTAssertEqual(
            WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30) / 60, 108, accuracy: 0.01)
    }

    func testExplicitAwakeSampleKeepsStretchAwake() {
        let night = octoberThirtiethNight { start in
            var rows = run(from: start, minutes: 68, state: 3)
            rows[40] = Row(timestamp: rows[40].timestamp, heartRate: 56, sleepState: .awakePrimary, stepCounter: 0)
            return rows
        }

        XCTAssertEqual(
            WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30) / 60, 40, accuracy: 0.01)
    }

    func testMissingStepEvidenceKeepsStretchAwake() {
        let night = octoberThirtiethNight { run(from: $0, minutes: 68, state: 3, counted: false) }

        XCTAssertEqual(
            WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30) / 60, 40, accuracy: 0.01)
    }

    func testOutageInsideQuietStretchIsNotCounted() {
        let night = octoberThirtiethNight { start in
            run(from: start, minutes: 20, state: 3) + run(from: start + 50 * 60, minutes: 18, state: 3)
        }

        // 40 + 20 + 18 minutes; the outage counts one sample, exactly as the
        // unbridged gap did.
        XCTAssertEqual(
            WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30) / 60, 78, accuracy: 0.01)
    }

    func testUnboundedUpIsNeverBridged() {
        let night =
            run(from: 0, minutes: 30, state: 3)
            + run(from: 30 * 60, minutes: 200, state: 2)
            + run(from: 230 * 60, minutes: 30, state: 3)

        XCTAssertEqual(WhoopQuietUpPolicy.bridgedSleepSeconds(session: night, cadence: 30), 0)
    }

    func testStepCounterWrapIsNotABurst() {
        let rows = run(from: 0, minutes: 10, state: 3, steps: 65_530, stepsPerSample: 1)

        XCTAssertEqual(WhoopQuietUpPolicy.largestStepBurst(rows), 10)
    }

    func testCounterResetAcrossLongGapIsIgnored() {
        let rows = [
            Row(timestamp: 0, heartRate: 56, sleepState: .up, stepCounter: 40_000),
            Row(timestamp: 600, heartRate: 56, sleepState: .up, stepCounter: 10),
        ]

        XCTAssertEqual(WhoopQuietUpPolicy.largestStepBurst(rows), 0)
    }

    /// The full-history backfill holds every retained row in memory at once.
    func testStepCounterDoesNotGrowHistoricalRows() {
        XCTAssertEqual(MemoryLayout<Row>.stride, 32)
    }

    func testBridgedTimeNeverPassesTheEvidenceGate() {
        let rows = run(from: 0, minutes: 150, state: 2)
        let candidate = WhoopStore.SleepCandidate(
            sessionRows: rows,
            asleepRows: rows,
            firstSleep: rows[0],
            lastSleep: rows[rows.count - 1],
            latest: rows[rows.count - 1],
            latestSampleIsCurrent: false,
            cadenceSeconds: 30,
            sleepSeconds: 150 * 60,
            bridgedSleepSeconds: 60 * 60,
            sessionCoverage: 1,
            wakeSeconds: 0
        )

        XCTAssertFalse(candidate.meetsEvidenceGates)
        XCTAssertEqual(candidate.durationMinutes, 210)
    }

    func testPublishedNightIncludesQuietUpStretch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let wakeCheck = Date(timeIntervalSince1970: 1_800_000_000)
        let start = wakeCheck.addingTimeInterval(-(5 * 60 * 60 + 60)).timeIntervalSince1970
        let sessionID = try await beginOffload(store: store, peripheral: peripheral)
        // Two asleep hours, one quiet `up` hour, two asleep hours.
        for minute in 0...300 {
            let state: UInt8 = (120..<180).contains(minute) ? 3 : 2
            _ = try await append(
                version18Frame(timestamp: UInt32(start) + UInt32(minute * 60), sleepState: state),
                store: store,
                peripheral: peripheral,
                sessionID: sessionID
            )
        }
        _ = await appendRealtime(
            Data([0x01]),
            heartRate: 55,
            rrIntervals: Array(repeating: [UInt16(900), UInt16(1_000)], count: 11).flatMap { $0 },
            deliveredAt: Date(timeIntervalSince1970: start + 60 * 60),
            store: store,
            peripheral: peripheral
        )
        _ = try await append(
            version18Frame(timestamp: UInt32(wakeCheck.timeIntervalSince1970), sleepState: 0),
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        _ = try await append(
            metadataFrame(type: 3), store: store, peripheral: peripheral, sessionID: sessionID)

        let snapshot = await sleepSnapshot(
            store: store, now: wakeCheck, allowAutomaticFinalization: true)
        let record = try XCTUnwrap(snapshot.finalizedRecord)

        XCTAssertEqual(try XCTUnwrap(record.sleepDurationMinutes), 301, accuracy: 0.01)
        XCTAssertEqual(record.source, WhoopStore.localSource)
    }
}
