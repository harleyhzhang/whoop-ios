import XCTest

@testable import Whoop

extension WhoopSleepStateTests {
    func testRecoveryBandsMatchDisplayedScoreBoundaries() {
        for score in [0.0, 1, 33, 33.49] {
            XCTAssertEqual(RecoveryBand(score: score), .low)
        }
        for score in [33.5, 34, 50, 66, 66.49] {
            XCTAssertEqual(RecoveryBand(score: score), .moderate)
        }
        for score in [66.5, 67, 93, 100] {
            XCTAssertEqual(RecoveryBand(score: score), .high)
        }
    }

    func testMissingOrInvalidRecoveryHasNoScoreBand() {
        for score: Double? in [nil, .nan, .infinity, -.infinity, -1, 101] {
            XCTAssertNil(RecoveryBand(score: score))
            XCTAssertEqual(HealthMetric.recovery.color(for: score), HealthMetric.recovery.color)
        }
    }

    func testRecoveryPaletteIsSharedAndOtherMetricsKeepTheirColors() {
        XCTAssertEqual(HealthMetric.recovery.color(for: 20), RecoveryBand.low.color)
        XCTAssertEqual(HealthMetric.recovery.color(for: 50), RecoveryBand.moderate.color)
        XCTAssertEqual(HealthMetric.recovery.color(for: 93), RecoveryBand.high.color)
        for metric in HealthMetric.allCases where metric != .recovery {
            XCTAssertEqual(metric.color(for: 20), metric.color)
            XCTAssertEqual(metric.color(for: 93), metric.color)
            XCTAssertEqual(metric.color(for: nil), metric.color)
        }
    }

    func testAllHistoryProjectionPreservesMissingDaysAndOneHeadlineDate() throws {
        let record = dailyHealthRecord(dateKey: "2026-01-31")
        let snapshot = DashboardHistorySnapshot(
            healthRecords: [record],
            stepRecords: [
                dailyStepRecord(dateKey: "2025-11-01", stepCount: 100),
                dailyStepRecord(dateKey: record.dateKey, stepCount: 1234),
                dailyStepRecord(dateKey: "2026-02-10", stepCount: 200),
            ],
            recoveryRecords: [DailyRecoveryRecord(dateKey: record.dateKey, score: 80, source: "synthetic")],
            strainRecords: [DailyStrainRecord(dateKey: record.dateKey, score: 10, source: "synthetic", estimate: nil)]
        )
        let published = PublishedDashboardDay(
            healthRecords: snapshot.healthRecords,
            stepRecords: snapshot.stepRecords.filter { $0.dateKey <= record.dateKey },
            recoveryRecords: snapshot.recoveryRecords)
        let referenceDate = try XCTUnwrap(published.date)
        let projection = DashboardCardProjection(snapshot: snapshot, published: published, referenceDate: referenceDate)
        XCTAssertEqual(projection.days.count, 92)
        XCTAssertEqual(projection.days.first?.day, "2025-11-01")
        XCTAssertEqual(projection.days.last?.day, "2026-01-31")
        XCTAssertEqual(projection.days.filter { $0.steps == nil }.count, 90)
        XCTAssertEqual(projection.days.first?.steps, 100)
        XCTAssertEqual(projection.selected?.day, record.dateKey)
        XCTAssertEqual(projection.selected?.strain, 10)
        XCTAssertEqual(projection.selected?.steps, 1234)
        XCTAssertEqual(projection.selected?.hrv, record.hrvRMSSDMilliseconds)
        let sleeping = DashboardCurrentDayPolicy.displayedDay(snapshot: snapshot, metricsArePending: true)
        XCTAssertNil(
            DashboardCardProjection(snapshot: snapshot, published: sleeping, referenceDate: referenceDate).selected)
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

    func testFullHistoryUses31AveragedBucketsAndPreservesMissingIntervals() throws {
        let start = try XCTUnwrap(DayKey.date(from: "2026-01-01", timeZone: .current))
        let days = try (0..<62).map { index in
            let date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: index, to: start))
            return HealthDay(
                day: DayKey(date: date, timeZone: .current).rawValue,
                sleep: nil, recovery: nil, strain: nil,
                steps: [3, 14, 15].contains(index) ? nil : Double(index),
                duration: nil, hrv: Double(100 + index), rhr: nil, localStrain: nil)
        }
        let buckets = ChartBuckets.values(days: days, metric: .steps)
        XCTAssertEqual(buckets.count, 31)
        XCTAssertEqual(try XCTUnwrap(buckets[0].value), 0.5)
        XCTAssertEqual(try XCTUnwrap(buckets[1].value), 2)
        XCTAssertNil(buckets[7].value)
        XCTAssertEqual(try XCTUnwrap(buckets[30].value), 60.5)
        XCTAssertEqual(buckets.first?.startDate, days.first?.date)
        XCTAssertEqual(buckets.last?.endDate, days.last?.date)
        let width = buckets[0].endDate.timeIntervalSince(buckets[0].startDate)
        for bucket in buckets {
            XCTAssertEqual(bucket.endDate.timeIntervalSince(bucket.startDate), width, accuracy: 0.001)
        }
        XCTAssertEqual(try XCTUnwrap(ChartBuckets.values(days: days, metric: .hrv).first?.value), 100.5)
        XCTAssertTrue(ChartBuckets.values(days: [], metric: .steps).isEmpty)
    }
}
