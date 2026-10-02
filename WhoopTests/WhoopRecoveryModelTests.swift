import SQLite3
import XCTest

@testable import Whoop

extension WhoopSleepStateTests {
    func testOfficialMetricsSeedPreservesTargetsBaselinesAndProvenance() throws {
        let json = """
            {
              "formatVersion": 1,
              "source": "whoop_private_ios_api",
              "sourceArchive": "private-api-example",
              "sourceManifestSHA256": "manifest-sha",
              "sourceDatabaseSHA256": "database-sha",
              "coverageStart": "2025-10-15",
              "coverageEnd": "2026-09-07",
              "daily": [{
                "dateKey": "2026-08-31",
                "officialRecoveryScore": 91,
                "officialSteps": 7493,
                "officialDayStrain": 12.4,
                "dayStrainTarget": 13.2,
                "stepsBaseline": 8100,
                "hrv": 82.5,
                "hrvBaseline": 77.2,
                "rhr": 48,
                "rhrBaseline": 50.1,
                "respiratoryRate": 14.2,
                "respiratoryRateBaseline": 14.0,
                "sleepPerformance": 96,
                "sleepPerformanceBaseline": 91,
                "sourceRecoverySHA256": "recovery-sha",
                "sourceStrainSHA256": "strain-sha"
              }]
            }
            """

        let seed = try JSONDecoder().decode(OfficialMetricsSeed.self, from: Data(json.utf8))

        XCTAssertEqual(seed.daily.count, 1)
        XCTAssertEqual(seed.daily[0].officialRecoveryScore, 91)
        XCTAssertEqual(seed.daily[0].officialSteps, 7_493)
        XCTAssertEqual(seed.daily[0].hrvBaseline, 77.2)
        XCTAssertEqual(seed.daily[0].sourceStrainSHA256, "strain-sha")
    }

    func testRecoveryFeaturesArePastOnlyAndComplete() throws {
        func record(_ date: String, hrv: Double, rhr: Double, score: Double) -> DailyHealthRecord {
            DailyHealthRecord(
                dateKey: date,
                sleepScore: score,
                sleepDurationMinutes: 480,
                hrvRMSSDMilliseconds: hrv,
                restingHeartRateBPM: rhr,
                sleepID: date,
                cycleID: nil,
                source: "test",
                sourceArchive: nil,
                sourceUpdatedAt: date,
                sleepStartAt: nil,
                sleepEndAt: nil,
                sleepStartMinute: 1_410,
                sleepEndMinute: 420,
                sleepNeedMinutes: nil,
                sleepConsistencyPercentage: nil,
                sleepEfficiencyPercentage: 95,
                sleepSufficiencyPercentage: nil
            )
        }
        let current = record("2026-09-07", hrv: 80, rhr: 48, score: 96)
        let past = record("2026-09-06", hrv: 70, rhr: 51, score: 90)
        let future = record("2026-09-08", hrv: 1, rhr: 200, score: 1)

        let features = try XCTUnwrap(
            RecoveryScoreFeatureBuilder.features(
                current: current,
                history: [past, future],
                stepsByDate: ["2026-09-06": 8_000, "2026-09-07": 10_000]
            ))

        XCTAssertEqual(features.count, RecoveryScoreFeatureBuilder.featureCount)
        XCTAssertEqual(features[GeneratedModelFeatures.Recovery.currentHRVIndex], 80)
        XCTAssertEqual(features[GeneratedModelFeatures.Recovery.currentRHRIndex], 48)
        XCTAssertEqual(features[GeneratedModelFeatures.Recovery.currentStepsIndex], 10_000)
        XCTAssertEqual(features[GeneratedModelFeatures.Recovery.lag1HRVIndex], 70)
        XCTAssertEqual(features[GeneratedModelFeatures.Recovery.lag1RHRIndex], 51)
        XCTAssertEqual(features[GeneratedModelFeatures.Recovery.rolling7HRVMeanIndex], 70)
    }

    func testSerializedRecoveryModelBlendsAndBoundsPrediction() throws {
        let count = RecoveryScoreFeatureBuilder.featureCount
        let zeros = Array(repeating: 0.0, count: count)
        let ones = Array(repeating: 1.0, count: count)
        let payload: [String: Any] = [
            "version": "synthetic-recovery",
            "featureVersion": RecoveryScoreFeatureBuilder.version,
            "featureCount": count,
            "boostedWeight": 0.7,
            "imputerMedians": zeros,
            "boostedModel": [
                "initialPrediction": 80.0, "learningRate": 0.1, "trees": [],
            ],
            "ridgeModel": [
                "imputerMedians": zeros, "means": zeros, "scales": ones,
                "coefficients": zeros, "intercept": 20.0,
            ],
        ]
        let model = try JSONDecoder().decode(
            RecoveryScoreModelBundle.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        var features = zeros
        features[GeneratedModelFeatures.Recovery.currentStepsIndex] = .nan

        let prediction = try XCTUnwrap(model.prediction(features))

        XCTAssertEqual(prediction.score, 62, accuracy: 0.0001)
        XCTAssertEqual(prediction.confidence, 0.82)
    }
}
