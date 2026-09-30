import XCTest

@testable import Sleep

extension WhoopSleepStateTests {
    func testMonthProjectionPreservesMissingDaysAndOneHeadlineDate() throws {
        let record = dailyHealthRecord(dateKey: "2026-01-31")
        let snapshot = DashboardHistorySnapshot(
            healthRecords: [record],
            stepRecords: [dailyStepRecord(dateKey: record.dateKey, stepCount: 1234)],
            recoveryRecords: [DailyRecoveryRecord(dateKey: record.dateKey, score: 80, source: "synthetic")],
            strainRecords: [DailyStrainRecord(dateKey: record.dateKey, score: 10, source: "synthetic", estimate: nil)]
        )
        let published = DashboardCurrentDayPolicy.displayedDay(snapshot: snapshot, metricsArePending: false)
        let projection = DashboardCardProjection(snapshot: snapshot, published: published, referenceDate: record.date)
        XCTAssertEqual(projection.days.count, 31)
        XCTAssertEqual(projection.days.first?.day, "2026-01-01")
        XCTAssertEqual(projection.days.last?.day, "2026-01-31")
        XCTAssertEqual(projection.days.filter { $0.steps == nil }.count, 30)
        XCTAssertEqual(projection.selected?.day, record.dateKey)
        XCTAssertEqual(projection.selected?.strain, 10)
        XCTAssertEqual(projection.selected?.steps, 1234)
        XCTAssertEqual(projection.selected?.hrv, record.hrvRMSSDMilliseconds)
        let sleeping = DashboardCurrentDayPolicy.displayedDay(snapshot: snapshot, metricsArePending: true)
        XCTAssertNil(
            DashboardCardProjection(snapshot: snapshot, published: sleeping, referenceDate: record.date).selected)
    }

    func testAverageLaddersHaveFourEqualWindowsAndExcludeMissingValues() throws {
        let days = (1...31).map { day in
            HealthDay(
                day: String(format: "2026-01-%02d", day), sleep: nil, recovery: nil,
                strain: nil, steps: day == 4 ? nil : Double(day), duration: nil,
                hrv: nil, rhr: nil, localStrain: nil)
        }
        let levels = ChartAverageSteps.levels(days: days, metric: .steps)
        XCTAssertEqual(levels.count, 4)
        let width = try XCTUnwrap(levels.first).endDate.timeIntervalSince(levels[0].startDate)
        for level in levels {
            XCTAssertEqual(level.endDate.timeIntervalSince(level.startDate), width, accuracy: 0.001)
        }
        XCTAssertEqual(levels[0].value, 32.0 / 7, accuracy: 0.0001)
        XCTAssertEqual(levels[3].value, 27.5, accuracy: 0.0001)
        XCTAssertTrue(ChartAverageSteps.levels(days: [], metric: .steps).isEmpty)
    }
}
