import SQLite3
import XCTest

@testable import Whoop

extension WhoopSleepStateTests {
    private struct ProvisionalFixture {
        let store: WhoopStore
        let databaseURL: URL
        let peripheral = UUID()
    }

    private func provisionalFixture() -> ProvisionalFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
        addTeardownBlock {
            store.shutdownForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        return ProvisionalFixture(store: store, databaseURL: url)
    }

    private func local(_ hour: Int, _ minute: Int = 0, day: Int = 15) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute)))
    }

    private func appendMinutes(
        _ fixture: ProvisionalFixture, session: String, from start: Date, through end: Date,
        state: UInt8, stepCounter: (Date) -> UInt16 = { _ in 100 }
    ) async throws {
        for timestamp in stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: 30) {
            let at = Date(timeIntervalSince1970: timestamp)
            _ = try await append(
                version18Frame(
                    timestamp: UInt32(timestamp), sleepState: state,
                    rrIntervals: state == 2 ? [900, 1_000, 900, 1_000] : [], stepCounter: stepCounter(at)),
                store: fixture.store, peripheral: fixture.peripheral, sessionID: session)
        }
    }

    private func snapshot(
        _ fixture: ProvisionalFixture, now: Date, publish: Bool = false, includeProvisional: Bool = true
    ) async -> WhoopSleepSnapshot {
        await withCheckedContinuation { continuation in
            fixture.store.refreshSleepSnapshot(
                now: now, allowAutomaticFinalization: publish, includeProvisional: includeProvisional
            ) { continuation.resume(returning: $0) }
        }
    }

    private func storedNightCount(_ fixture: ProvisionalFixture) -> Int64 {
        var database: OpaquePointer?
        sqlite3_open_v2(fixture.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        return scalarInt(database, sql: "SELECT COUNT(*) FROM daily_health_metric")
    }

    /// Asleep 01:00–05:00 local, awake from 05:01 while walking ten steps a
    /// minute, with a completed offload so the night is publishable.
    private func fourHourNightThenWalk(_ fixture: ProvisionalFixture) async throws -> Date {
        let session = try await beginOffload(store: fixture.store, peripheral: fixture.peripheral)
        try await appendMinutes(fixture, session: session, from: try local(1), through: try local(5), state: 2)
        let wake = try local(5, 1)
        try await appendMinutes(
            fixture, session: session, from: wake, through: try local(5, 30), state: 0,
            stepCounter: { UInt16(100 + Int($0.timeIntervalSince(wake) / 60 + 1) * 10) })
        _ = try await append(
            metadataFrame(type: 3), store: fixture.store, peripheral: fixture.peripheral, sessionID: session)
        return try local(5, 31)
    }

    func testRunningNightRollsWithoutStoringOrPublishing() async throws {
        let fixture = provisionalFixture()
        let session = try await beginOffload(store: fixture.store, peripheral: fixture.peripheral)
        try await appendMinutes(fixture, session: session, from: try local(1), through: try local(3), state: 2)

        let early = await snapshot(fixture, now: try local(3, 0))
        let night = try XCTUnwrap(early.provisional)
        XCTAssertTrue(early.isSleeping)
        XCTAssertTrue(early.evaluatedProvisional)
        XCTAssertNil(early.finalizedRecord)
        XCTAssertEqual(night.dateKey, DayKey.string(from: try local(3), timeZone: .autoupdatingCurrent))
        XCTAssertEqual(night.health.sleepDurationMinutes ?? 0, 121, accuracy: 1)
        XCTAssertEqual(night.health.hrvRMSSDMilliseconds ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(night.health.restingHeartRateBPM, 55)
        XCTAssertNil(night.health.sleepScore, "Scores wait for the three-hour evidence minimum")
        XCTAssertNil(night.recovery)
        XCTAssertNotNil(night.health.sleepEfficiencyPercentage)
        XCTAssertEqual(night.steps?.stepCount, 0)
        XCTAssertEqual(storedNightCount(fixture), 0, "A running night is never stored")

        let background = await snapshot(fixture, now: try local(3, 0), includeProvisional: false)
        XCTAssertNil(background.provisional)
        XCTAssertFalse(background.evaluatedProvisional)

        try await appendMinutes(
            fixture, session: session, from: try local(3, 1), through: try local(4), state: 2)
        let laterSnapshot = await snapshot(fixture, now: try local(4))
        let later = try XCTUnwrap(laterSnapshot.provisional)
        XCTAssertEqual(later.dateKey, night.dateKey)
        XCTAssertGreaterThan(later.health.sleepDurationMinutes ?? 0, (night.health.sleepDurationMinutes ?? 0) + 55)
        XCTAssertNotNil(later.health.sleepScore, "Past three hours the score rolls")
        XCTAssertEqual(storedNightCount(fixture), 0)
    }

    func testFinalRollingValuesEqualThePublishedNightAndItsSteps() async throws {
        let fixture = provisionalFixture()
        let now = try await fourHourNightThenWalk(fixture)

        let waiting = await snapshot(fixture, now: now)
        XCTAssertFalse(waiting.isSleeping)
        let night = try XCTUnwrap(waiting.provisional, "Awake but unpublished keeps the night")
        XCTAssertEqual(night.steps?.stepCount, 300, "Steps counted from the wake sample, as publication does")

        let published = await snapshot(fixture, now: now, publish: true)
        let record = try XCTUnwrap(published.finalizedRecord)
        XCTAssertNil(published.provisional, "The banked night replaces the rolling one")
        XCTAssertEqual(record.dateKey, night.dateKey)
        XCTAssertEqual(record.sleepID, night.health.sleepID)
        XCTAssertEqual(record.sleepScore, night.health.sleepScore)
        XCTAssertEqual(record.sleepDurationMinutes, night.health.sleepDurationMinutes)
        XCTAssertEqual(record.hrvRMSSDMilliseconds, night.health.hrvRMSSDMilliseconds)
        XCTAssertEqual(record.restingHeartRateBPM, night.health.restingHeartRateBPM)

        let history = try await dashboardSnapshot(store: fixture.store)
        XCTAssertEqual(
            history.stepRecords.first { $0.dateKey == night.dateKey }?.stepCount, night.steps?.stepCount,
            "Publication re-buckets exactly the steps the rolling day showed")
    }

    func testNapAfterAPublishedNightKeepsTheBankedDay() async throws {
        let fixture = provisionalFixture()
        let now = try await fourHourNightThenWalk(fixture)
        let morning = await snapshot(fixture, now: now, publish: true)
        XCTAssertNotNil(morning.finalizedRecord)

        let session = try await beginOffload(store: fixture.store, peripheral: fixture.peripheral)
        try await appendMinutes(fixture, session: session, from: try local(15), through: try local(15, 30), state: 2)
        let nap = await snapshot(fixture, now: try local(15, 30))

        XCTAssertTrue(nap.isSleeping)
        XCTAssertNil(nap.provisional, "An afternoon nap never replaces the morning's night")
    }

    func testShortSleepFallsBackAfterTheReopenWindow() async throws {
        let fixture = provisionalFixture()
        let session = try await beginOffload(store: fixture.store, peripheral: fixture.peripheral)
        try await appendMinutes(fixture, session: session, from: try local(1), through: try local(2), state: 2)
        try await appendMinutes(fixture, session: session, from: try local(2, 1), through: try local(2, 5), state: 0)

        let inside = await snapshot(fixture, now: try local(3, 30))
        XCTAssertNotNil(inside.provisional, "Sleep could still resume within ninety minutes")
        let outside = await snapshot(fixture, now: try local(3, 31))
        XCTAssertNil(outside.provisional)
        XCTAssertTrue(outside.evaluatedProvisional)
    }
}
