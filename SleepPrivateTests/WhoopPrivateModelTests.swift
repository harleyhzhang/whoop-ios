import XCTest

@testable import Sleep

final class WhoopPrivateModelTests: XCTestCase {
    func testPrivateRecoveryModelMatchesPythonExporter() throws {
        let model = try XCTUnwrap(
            RecoveryScoreModelBundle.load(),
            "The private Recovery model was not embedded in the test host."
        )
        var features = model.imputerMedians
        features[50] += 10
        features[51] -= 2
        features[52] = .nan
        features[53] += 3

        let prediction = try XCTUnwrap(model.prediction(features))

        XCTAssertEqual(model.version, "whoop5_local_recovery_v1_gbt_ridge")
        XCTAssertEqual(prediction.score, 64.61710245284407, accuracy: 0.000_000_1)
        XCTAssertEqual(prediction.confidence, 0.82)
    }

    func testPrivateSleepScoreModelDecodesAndPredicts() throws {
        let path = try XCTUnwrap(
            Bundle.main.url(forResource: "whoop-score-model", withExtension: "json"),
            "The private Sleep model was not embedded in the test host."
        )
        let model = try JSONDecoder().decode(
            SleepScoreModelBundle.self,
            from: Data(contentsOf: path)
        )
        let current = SleepScoreNight(
            dateKey: "2026-09-07",
            durationMinutes: 480,
            efficiencyPercentage: 95,
            startMinute: 1_410,
            endMinute: 420
        )
        let prediction = model.predict(
            SleepScoreFeatureBuilder.features(current: current, history: [])
        )

        XCTAssertEqual(model.version, "whoop5_local_v5_score_staged_1")
        XCTAssertNotNil(prediction)
        XCTAssertTrue((0...99).contains(prediction ?? -1))
    }
}
