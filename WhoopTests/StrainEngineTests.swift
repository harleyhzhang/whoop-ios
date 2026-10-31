import Foundation
import XCTest

@testable import Whoop

final class StrainEngineTests: XCTestCase {
    let calibration = StrainCalibration(version: "test", exponent: 2, loadScale: 1, scoreScale: 4)

    func estimate(end: Double, samples: [(Double, Double)]) -> StrainEstimate {
        var engine = StrainAccumulator(calibration: calibration, start: 0, end: end, maximumHeartRate: 190)
        for (timestamp, heartRate) in samples {
            engine.append(StrainSample(timestamp: timestamp, heartRate: heartRate))
        }
        return engine.finish(day: "synthetic")
    }

    func testCardiovascularIntegrationAndFinalization() throws {
        let samples = stride(from: 0, to: 300, by: 6).map { (Double($0), 140.0) }
        let result = estimate(end: 300, samples: samples)
        let expected = calibration.score(load: 5 * calibration.loadPerMinute(heartRate: 140, maximumHeartRate: 190))
        XCTAssertEqual(try XCTUnwrap(result.score), expected, accuracy: 0.000_001)
        XCTAssertEqual(result.score, result.cardiovascularScore)
        XCTAssertEqual(result.source, "direct_hr_cardiovascular")
        XCTAssertEqual(result.coverage, 1)
        let dense = estimate(end: 300, samples: (0..<300).map { (Double($0), 140.0) })
        XCTAssertEqual(try XCTUnwrap(dense.score), expected, accuracy: 0.000_001)
        var engine = StrainAccumulator(calibration: calibration, start: 0, end: 300, maximumHeartRate: 190)
        engine.append(StrainSample(timestamp: 0, heartRate: 140))
        let first = engine.finish(day: "synthetic")
        engine.append(StrainSample(timestamp: 6, heartRate: 200))
        XCTAssertEqual(engine.finish(day: "synthetic").score, first.score)
        XCTAssertEqual(engine.finish(day: "synthetic").observedSeconds, 6)
    }

    func testMissingIntervalsAndShortOutagesAddNoExtrapolatedLoad() {
        let samples = stride(from: 0, to: 300, by: 6).map { (Double($0), 140.0) }
        let fiveMinutes = estimate(end: 300, samples: samples)
        let sparseDay = estimate(end: 86_400, samples: samples)
        XCTAssertEqual(sparseDay.score, fiveMinutes.score)
        XCTAssertEqual(sparseDay.observedSeconds, 300)
        XCTAssertEqual(sparseDay.coverage, 300.0 / 86_400, accuracy: 0.000_001)
        for gap in [30.0, 120, 3000] {
            let outage = estimate(end: 86_400, samples: [(0, 140), (gap, 140)])
            XCTAssertEqual(outage.observedSeconds, 12, "A sample never fills an unobserved outage")
            XCTAssertEqual(outage.score, estimate(end: 12, samples: [(0, 140), (6, 140)]).score)
        }
        let empty = estimate(end: 86_400, samples: [])
        XCTAssertEqual(empty.score, 0)
        XCTAssertEqual(empty.coverage, 0)
    }

    func testInvalidHRDuplicateOrderAndBoundariesCannotCreateLoad() {
        let expected = estimate(end: 30, samples: [(0, 140), (6, 140)])
        let duplicates = estimate(end: 30, samples: [(0, 140), (0, 220), (6, 140), (3, 200)])
        XCTAssertEqual(duplicates.score, expected.score)
        XCTAssertEqual(duplicates.observedSeconds, expected.observedSeconds)
        let invalid = estimate(end: 30, samples: [(-1, 200), (0, .nan), (6, 0), (12, 255), (30, 200)])
        XCTAssertEqual(invalid.score, 0)
        XCTAssertEqual(invalid.observedSeconds, 0)
        XCTAssertEqual(estimate(end: 3, samples: [(0, 140)]).observedSeconds, 3)
        let reset = estimate(end: 40, samples: [(0, 200), (1, 200), (2, 200), (30, 60)])
        let reference = estimate(end: 40, samples: [(0, 200), (1, 200), (2, 200)])
        XCTAssertEqual(reset.score, reference.score, "Smoothing cannot carry old high HR across an outage")
    }

    func testInvalidCalibrationAndWindowsRemainUnavailable() {
        let invalid = StrainCalibration(version: "invalid", exponent: .nan, loadScale: 1, scoreScale: 4)
        for (model, start, end, maximum) in [
            (invalid, 0.0, 300.0, 190.0), (calibration, 0, 300, .nan),
            (calibration, 0, 300, 80), (calibration, .nan, 300, 190),
            (calibration, 0, .infinity, 190), (calibration, 0, 0, 190), (calibration, 0, 90001, 190),
        ] {
            var engine = StrainAccumulator(calibration: model, start: start, end: end, maximumHeartRate: maximum)
            XCTAssertNil(engine.finish(day: "synthetic").score)
        }
    }
}
