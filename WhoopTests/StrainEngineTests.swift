import Foundation
import XCTest

@testable import Whoop

final class StrainEngineTests: XCTestCase {
    let calibration = StrainCalibration(
        version: "test", exponent: 2, loadScale: 1, scoreScale: 4)

    func replay(
        cadence: Int = 6, stepsPerSample: Int = 0, sleepState: Int = 0,
        counters: Bool = true, duplicate: Bool = false, patterned: Bool = true,
        dropRange: Range<Int>? = nil
    ) -> StrainEstimate {
        var engine = StrainAccumulator(
            calibration: calibration, start: 0, end: 7_200,
            maximumHeartRate: 190, restingHeartRate: 50)
        var counter = 65_520
        for second in stride(from: 0, to: 7_200, by: cadence) {
            if dropRange?.contains(second) == true { continue }
            let minute = second / 60
            let values = [85.0, 95, 115, 95, 80]
            let hr = (10..<40).contains(minute) ? (patterned ? values[minute % 5] : 95) : 60
            counter = (counter + stepsPerSample) % 65_536
            let sample = StrainSample(
                timestamp: Double(second), heartRate: hr,
                stepCounter: counters ? counter : nil, sleepState: sleepState)
            engine.append(sample)
            if duplicate { engine.append(sample) }
        }
        return engine.finish(day: "synthetic")
    }

    func testPatternsCoverageAndFinalization() {
        let lift = replay()
        XCTAssertTrue(lift.coverage == 1 && lift.score != nil)
        XCTAssertTrue(lift.probableStrengthSessions == 1 && lift.probableStrengthMinutes >= 20)
        XCTAssertTrue(lift.muscularScore > 0)
        if let score = lift.score {
            XCTAssertTrue(score > lift.cardiovascularScore && score < 21)
            XCTAssertTrue(score < lift.cardiovascularScore + lift.muscularScore)
        }
        XCTAssertTrue(replay(stepsPerSample: 10).probableStrengthSessions == 0, "Walking is not lifting")
        XCTAssertTrue(replay(sleepState: 2).probableStrengthSessions == 0, "Sleeping is not lifting")
        XCTAssertTrue(
            replay(counters: false).probableStrengthSessions == 0, "Missing steps are not zero steps")
        XCTAssertTrue(
            replay(patterned: false).probableStrengthSessions == 0, "Flat HR is not set/rest evidence")
        let duplicates = replay(duplicate: true)
        XCTAssertTrue(duplicates.score == lift.score && duplicates.coverage == lift.coverage)
        let gap = replay(dropRange: 1_200..<3_600)
        XCTAssertTrue(gap.coverage < 0.7 && gap.score == nil && gap.probableStrengthSessions == 0)
        XCTAssertTrue(abs(replay(cadence: 1).cardiovascularScore - lift.cardiovascularScore) < 0.1)
        var invalid = StrainAccumulator(
            calibration: calibration, start: 0, end: 7_200,
            maximumHeartRate: 190, restingHeartRate: 50)
        invalid.append(StrainSample(timestamp: 0, heartRate: .nan, stepCounter: nil, sleepState: nil))
        invalid.append(StrainSample(timestamp: 6, heartRate: 0, stepCounter: nil, sleepState: nil))
        invalid.append(StrainSample(timestamp: 12, heartRate: 255, stepCounter: nil, sleepState: nil))
        let empty = invalid.finish(day: "synthetic")
        XCTAssertTrue(empty.score == nil && empty.observedSeconds == 0)
        invalid.append(StrainSample(timestamp: 18, heartRate: 100, stepCounter: 0, sleepState: 0))
        XCTAssertTrue(invalid.finish(day: "synthetic").observedSeconds == 0, "Finished days stay finalized")
        var invalidWindow = StrainAccumulator(
            calibration: calibration, start: .nan, end: .infinity,
            maximumHeartRate: 190, restingHeartRate: 50)
        XCTAssertTrue(invalidWindow.finish(day: "synthetic").score == nil)
    }
}
