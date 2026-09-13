import XCTest

@testable import Sleep

final class ModelFeatureGoldenVectorTests: XCTestCase {
    func testSwiftFeaturesMatchSharedPythonGoldenVectors() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "model-feature-golden",
                withExtension: "json"
            )
        )
        let fixture = try JSONDecoder().decode(
            ModelFeatureGoldenFixture.self,
            from: Data(contentsOf: url)
        )

        let sleepInput = fixture.sleep.input
        let sleepNight = SleepScoreNight(
            dateKey: sleepInput.dateKey,
            durationMinutes: sleepInput.durationMinutes,
            efficiencyPercentage: sleepInput.efficiencyPercentage,
            startMinute: sleepInput.startMinute,
            endMinute: sleepInput.endMinute
        )
        XCTAssertEqual(fixture.sleep.featureNames, GeneratedModelFeatures.Sleep.names)
        assertEqual(
            SleepScoreFeatureBuilder.features(current: sleepNight, history: []),
            fixture.sleep.features
        )

        let recoveryInput = fixture.recovery.input
        let record = DailyHealthRecord(
            dateKey: recoveryInput.dateKey,
            sleepScore: recoveryInput.sleepScore,
            sleepDurationMinutes: recoveryInput.durationMinutes,
            hrvRMSSDMilliseconds: recoveryInput.hrv,
            restingHeartRateBPM: recoveryInput.rhr,
            sleepID: "synthetic-golden",
            cycleID: nil,
            source: "synthetic-golden",
            sourceArchive: nil,
            sourceUpdatedAt: recoveryInput.dateKey,
            sleepStartMinute: recoveryInput.startMinute,
            sleepEndMinute: recoveryInput.endMinute,
            sleepEfficiencyPercentage: recoveryInput.efficiencyPercentage
        )
        let recoveryFeatures = try XCTUnwrap(
            RecoveryScoreFeatureBuilder.features(
                current: record,
                history: [],
                stepsByDate: [recoveryInput.dateKey: recoveryInput.steps]
            )
        )
        XCTAssertEqual(fixture.recovery.featureNames, GeneratedModelFeatures.Recovery.names)
        assertEqual(recoveryFeatures, fixture.recovery.features)
    }

    private func assertEqual(
        _ actual: [Double],
        _ expected: [Double],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, values) in zip(actual, expected).enumerated() {
            XCTAssertEqual(
                values.0,
                values.1,
                accuracy: 0.000_000_000_001,
                "Feature \(index)",
                file: file,
                line: line
            )
        }
    }
}

private struct ModelFeatureGoldenFixture: Decodable {
    struct SleepVector: Decodable {
        struct Input: Decodable {
            let dateKey: String
            let durationMinutes: Double
            let efficiencyPercentage: Double
            let startMinute: Double
            let endMinute: Double
        }

        let input: Input
        let featureNames: [String]
        let features: [Double]
    }

    struct RecoveryVector: Decodable {
        struct Input: Decodable {
            let dateKey: String
            let durationMinutes: Double
            let efficiencyPercentage: Double
            let startMinute: Double
            let endMinute: Double
            let hrv: Double
            let rhr: Double
            let steps: Double
            let sleepScore: Double
        }

        let input: Input
        let featureNames: [String]
        let features: [Double]
    }

    let sleep: SleepVector
    let recovery: RecoveryVector
}
