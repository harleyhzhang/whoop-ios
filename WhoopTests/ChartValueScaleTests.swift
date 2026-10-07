import XCTest

@testable import Whoop

final class ChartValueScaleTests: XCTestCase {
    func testRestingHeartRateLeavesRoomAroundObservedValues() {
        let domain = ChartValueScale.domain(metric: .rhr, values: [50, 52, 55])
        XCTAssertEqual(domain.lowerBound, 44.5, accuracy: 0.001)
        XCTAssertEqual(domain.upperBound, 60.5, accuracy: 0.001)
    }

    func testScoresAndStepsAlsoUseAdaptiveRanges() {
        for metric in [HealthMetric.sleep, .recovery, .strain, .steps] {
            let values: [Double] = metric == .steps ? [8000, 9000] : [10, 12]
            let domain = ChartValueScale.domain(metric: metric, values: values)
            XCTAssertGreaterThan(domain.lowerBound, 0)
            XCTAssertLessThan(domain.lowerBound, values[0])
            XCTAssertGreaterThan(domain.upperBound, values[1])
        }
    }

    func testDurationUsesProportionalPaddingWithHalfHourMinimum() {
        let domain = ChartValueScale.domain(metric: .duration, values: [420, 430])
        XCTAssertEqual(domain, 377...473)
        XCTAssertEqual(ChartValueScale.domain(metric: .duration, values: [60, 65]), 30...95)
    }

    func testTinyFluctuationsDoNotFillTheChart() {
        let domain = ChartValueScale.domain(metric: .rhr, values: [54, 54.1])
        let visibleFraction = 0.1 / (domain.upperBound - domain.lowerBound)
        XCTAssertLessThan(visibleFraction, 0.01)
    }

    func testWiderVariationsOccupyAtMostHalfThePaddedRange() {
        let domain = ChartValueScale.domain(metric: .steps, values: [6000, 12000])
        XCTAssertEqual(domain, 3000...15000)
    }

    func testConstantAndSingleObservationsHaveNonzeroRange() {
        for metric in HealthMetric.allCases {
            let single = ChartValueScale.domain(metric: metric, values: [50])
            XCTAssertLessThan(single.lowerBound, 50)
            XCTAssertGreaterThan(single.upperBound, 50)
            XCTAssertEqual(single, ChartValueScale.domain(metric: metric, values: [50, 50, 50]))
        }
    }

    func testRealZeroRemainsVisibleWithoutNegativeScale() {
        for metric in HealthMetric.allCases {
            let domain = ChartValueScale.domain(metric: metric, values: [0, 10])
            XCTAssertEqual(domain.lowerBound, 0)
            XCTAssertGreaterThan(domain.upperBound, 10)
        }
    }

    func testMissingAndInvalidObservationsDoNotDistortRange() {
        XCTAssertEqual(ChartValueScale.domain(metric: .hrv, values: []), 0...1)
        XCTAssertEqual(ChartValueScale.domain(metric: .hrv, values: [.nan, .infinity, -1]), 0...1)
        XCTAssertEqual(
            ChartValueScale.domain(metric: .hrv, values: [60, 65, .nan, .infinity, -1]),
            ChartValueScale.domain(metric: .hrv, values: [60, 65])
        )
    }
}
