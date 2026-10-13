import XCTest

@testable import Whoop

extension WhoopSleepStateTests {
    func testRecordedHistoryShowsStoredMetricsWithoutPublishingIncompleteLiveDay() throws {
        let health = dailyHealthRecord(dateKey: "2026-01-02")
        let snapshot = DashboardHistorySnapshot(
            healthRecords: [health], stepRecords: [],
            recoveryRecords: [DailyRecoveryRecord(dateKey: health.dateKey, score: 81, source: "synthetic")])
        let history = RecordedHistory(snapshot: snapshot)
        XCTAssertEqual(history.day(health.dateKey)?.sleep, 88)
        XCTAssertEqual(history.day(health.dateKey)?.recovery, 81)
        XCTAssertNil(history.day(health.dateKey)?.steps)
        XCTAssertNil(DashboardCurrentDayPolicy.displayedDay(snapshot: snapshot, metricsArePending: false).health)
        XCTAssertNil(DashboardCurrentDayPolicy.displayedDay(snapshot: snapshot, metricsArePending: true).health)
    }

    func testRecordedHistoryRetainsMissingDatesAndExactStepDay() throws {
        let history = RecordedHistory(
            snapshot: DashboardHistorySnapshot(
                healthRecords: [dailyHealthRecord(dateKey: "2026-01-01")],
                stepRecords: [dailyStepRecord(dateKey: "2026-01-03", stepCount: 0)],
                recoveryRecords: []))
        XCTAssertEqual(history.days.map(\.day), ["2026-01-01", "2026-01-02", "2026-01-03"])
        XCTAssertNil(history.day("2026-01-02")?.sleep)
        XCTAssertNil(history.day("2026-01-02")?.steps)
        XCTAssertEqual(history.day("2026-01-03")?.steps, 0)
        XCTAssertNil(history.day("2026-01-03")?.sleep)
        XCTAssertNil(history.neighbor(of: "2026-01-01", offset: -1))
        XCTAssertNil(history.neighbor(of: "2026-01-03", offset: 1))
        XCTAssertEqual(history.neighbor(of: "2026-01-01", offset: 1), "2026-01-02")
        XCTAssertEqual(history.window(endingAt: "2026-01-02", count: 7).map(\.day), ["2026-01-01", "2026-01-02"])
        XCTAssertTrue(history.window(endingAt: "2026-01-02", count: 0).isEmpty)
        XCTAssertNil(history.day("2026-01-04"))
        XCTAssertTrue(RecordedHistory(snapshot: .empty).days.isEmpty)
    }

    func testExportedDayPublishesWithoutStepsButStrapDayStillNeedsThem() {
        func record(_ source: String) -> DailyHealthRecord {
            DailyHealthRecord(
                dateKey: "2026-01-02", sleepScore: 80, sleepDurationMinutes: 400,
                hrvRMSSDMilliseconds: 60, restingHeartRateBPM: 50,
                sleepID: nil, cycleID: nil, source: source, sourceArchive: nil,
                sourceUpdatedAt: "2026-01-03T00:00:00Z")
        }
        let recovery = [DailyRecoveryRecord(dateKey: "2026-01-02", score: 71, source: "synthetic")]
        let exported = PublishedDashboardDay(
            healthRecords: [record(PublishedDashboardDay.accountExportSource)], stepRecords: [],
            recoveryRecords: recovery)
        XCTAssertEqual(exported.health?.sleepScore, 80)
        XCTAssertEqual(exported.recovery?.score, 71)
        XCTAssertNil(exported.steps)
        let strap = PublishedDashboardDay(
            healthRecords: [record("whoop_strap")], stepRecords: [], recoveryRecords: recovery)
        XCTAssertNil(strap.health)
    }
}
