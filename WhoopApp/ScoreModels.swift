import Foundation

struct SleepScoreNight: Sendable, Equatable {
    let dateKey: String
    let durationMinutes: Double
    let efficiencyPercentage: Double
    let startMinute: Double
    let endMinute: Double
}

enum SleepScoreFeatureBuilder {
    static let version = GeneratedModelFeatures.Sleep.version
    static let featureCount = GeneratedModelFeatures.Sleep.featureCount

    static func features(current: SleepScoreNight, history: [SleepScoreNight]) -> [Double] {
        let currentKey = DayKey(rawValue: current.dateKey)
        let recent = history.compactMap { night -> (SleepScoreNight, DayKey)? in
            DayKey(rawValue: night.dateKey).map { (night, $0) }
        }
        .filter { pair in currentKey.map { pair.1 < $0 } ?? false }
        .sorted { $0.1 > $1.1 }
        .map(\.0)

        var values = [
            current.durationMinutes,
            current.efficiencyPercentage,
            sin(2 * .pi * current.startMinute / 1_440),
            cos(2 * .pi * current.startMinute / 1_440),
            sin(2 * .pi * current.endMinute / 1_440),
            cos(2 * .pi * current.endMinute / 1_440),
        ]
        var previous: [SleepScoreNight] = []
        for lag in 1...7 {
            let candidate = recent.indices.contains(lag - 1) ? recent[lag - 1] : nil
            let gap: Int? = candidate.flatMap { night in
                guard let key = DayKey(rawValue: night.dateKey), let currentKey else { return nil }
                return key.dayGap(to: currentKey)
            }
            let usableCandidate =
                candidate.flatMap { candidate in
                    gap.map { ($0 <= lag + 3) ? candidate : nil }
                } ?? nil
            let night = usableCandidate ?? current
            previous.append(night)
            values.append(contentsOf: [
                night.durationMinutes,
                night.efficiencyPercentage,
                circularMinuteDistance(current.startMinute, night.startMinute),
                circularMinuteDistance(current.endMinute, night.endMinute),
                usableCandidate == nil ? 0 : Double(gap ?? 0),
            ])
        }

        let firstFour = Array(previous.prefix(4))
        let durations = firstFour.map(\.durationMinutes)
        let efficiencies = firstFour.map(\.efficiencyPercentage)
        values.append(contentsOf: [
            mean(durations), standardDeviation(durations),
            mean(efficiencies), standardDeviation(efficiencies),
        ])

        let agreements = firstFour.map { prior in
            max(
                0,
                100
                    * (1
                        - (circularMinuteDistance(current.startMinute, prior.startMinute)
                            + circularMinuteDistance(current.endMinute, prior.endMinute)) / 1_440)
            )
        }
        values.append(contentsOf: agreements)
        values.append(
            zip(agreements, GeneratedModelFeatures.Sleep.agreementWeights).map(*).reduce(0, +)
        )
        precondition(values.count == featureCount)
        return values
    }

    private static func circularMinuteDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 1_440)
        return min(difference, 1_440 - difference)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(1, values.count))
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        let average = mean(values)
        return sqrt(values.map { pow($0 - average, 2) }.reduce(0, +) / Double(max(1, values.count)))
    }

}

struct SleepScoreModelBundle: Decodable, Sendable {
    struct Prediction: Sendable {
        let score: Double
        let sleepNeedMinutes: Double
        let consistencyPercentage: Double
        let sufficiencyPercentage: Double
    }

    struct ExtraTree: Decodable, Sendable {
        let childrenLeft: [Int]
        let childrenRight: [Int]
        let features: [Int]
        let thresholds: [Double]
        let values: [Double]

        func predict(_ input: [Double]) -> Double? {
            var node = 0
            while childrenLeft.indices.contains(node) {
                let left = childrenLeft[node]
                if left == -1 { return values.indices.contains(node) ? values[node] : nil }
                guard features.indices.contains(node), thresholds.indices.contains(node),
                    input.indices.contains(features[node]), childrenRight.indices.contains(node)
                else {
                    return nil
                }
                node = input[features[node]] <= thresholds[node] ? left : childrenRight[node]
            }
            return nil
        }
    }

    struct SVRModel: Decodable, Sendable {
        let means: [Double]
        let scales: [Double]
        let supportVectors: [[Double]]
        let dualCoefficients: [Double]
        let intercept: Double
        let gamma: Double

        func predict(_ input: [Double]) -> Double? {
            guard input.count == means.count, means.count == scales.count,
                supportVectors.count == dualCoefficients.count
            else { return nil }
            let standardized = zip(zip(input, means), scales).map { pair, scale in
                (pair.0 - pair.1) / max(scale, 1e-12)
            }
            var prediction = intercept
            for (vector, coefficient) in zip(supportVectors, dualCoefficients) {
                guard vector.count == standardized.count else { return nil }
                let squaredDistance = zip(vector, standardized)
                    .map { pow($0 - $1, 2) }
                    .reduce(0, +)
                prediction += coefficient * exp(-gamma * squaredDistance)
            }
            return prediction
        }
    }

    struct GradientBoostedModel: Decodable, Sendable {
        let initialPrediction: Double
        let learningRate: Double
        let trees: [ExtraTree]

        func predict(_ input: [Double]) -> Double? {
            let predictions = trees.compactMap { $0.predict(input) }
            guard predictions.count == trees.count else { return nil }
            return initialPrediction + learningRate * predictions.reduce(0, +)
        }
    }

    let version: String
    let featureVersion: String
    let featureCount: Int
    let directWeight: Double
    let extraTreesWeight: Double
    let trees: [ExtraTree]
    let svr: SVRModel
    let needModel: GradientBoostedModel
    let consistencyModel: GradientBoostedModel
    let pillarSVR: SVRModel

    func prediction(_ features: [Double]) -> Prediction? {
        guard featureVersion == SleepScoreFeatureBuilder.version,
            featureCount == SleepScoreFeatureBuilder.featureCount,
            features.count == SleepScoreFeatureBuilder.featureCount,
            !trees.isEmpty,
            let svrPrediction = svr.predict(features),
            let need = needModel.predict(features), need > 0,
            let consistency = consistencyModel.predict(features)
        else { return nil }
        let treePredictions = trees.compactMap { $0.predict(features) }
        guard treePredictions.count == trees.count else { return nil }
        let forestPrediction = treePredictions.reduce(0, +) / Double(treePredictions.count)
        let directPrediction =
            extraTreesWeight * forestPrediction
            + (1 - extraTreesWeight) * svrPrediction
        let sufficiency = min(
            100,
            features[GeneratedModelFeatures.Sleep.durationIndex] / need * 100
        )
        guard
            let pillarPrediction = pillarSVR.predict([
                sufficiency,
                consistency,
                features[GeneratedModelFeatures.Sleep.efficiencyIndex],
            ])
        else { return nil }
        return Prediction(
            score: min(
                99,
                max(
                    0,
                    directWeight * directPrediction + (1 - directWeight) * pillarPrediction
                )),
            sleepNeedMinutes: need,
            consistencyPercentage: min(100, max(0, consistency)),
            sufficiencyPercentage: sufficiency
        )
    }

    func predict(_ features: [Double]) -> Double? {
        prediction(features)?.score
    }

    static func load(from bundle: Bundle = .main) -> SleepScoreModelBundle? {
        guard let url = bundle.url(forResource: "whoop-score-model", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum RecoveryScoreFeatureBuilder {
    static let version = GeneratedModelFeatures.Recovery.version
    static let featureCount = GeneratedModelFeatures.Recovery.featureCount

    static func isEligibleHistoryRecord(_ record: DailyHealthRecord) -> Bool {
        DayKey(rawValue: record.dateKey) != nil && sleepNight(record) != nil
    }

    static func features(
        current: DailyHealthRecord,
        history: [DailyHealthRecord],
        stepsByDate: [String: Double]
    ) -> [Double]? {
        guard let currentNight = sleepNight(current),
            let hrv = current.hrvRMSSDMilliseconds,
            let rhr = current.restingHeartRateBPM,
            let sleepScore = current.sleepScore
        else { return nil }
        guard let currentKey = DayKey(rawValue: current.dateKey) else { return nil }
        let eligible = history.compactMap { record -> (DailyHealthRecord, DayKey)? in
            guard let key = DayKey(rawValue: record.dateKey), isEligibleHistoryRecord(record) else {
                return nil
            }
            return (record, key)
        }
        .filter { $0.1 < currentKey }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
        let sleepHistory = eligible.compactMap(sleepNight)
        var values = SleepScoreFeatureBuilder.features(
            current: currentNight,
            history: sleepHistory
        )
        let currentSteps = stepsByDate[current.dateKey] ?? .nan
        values.append(contentsOf: [hrv, rhr, currentSteps, sleepScore])

        let recent = Array(eligible.reversed())
        for lag in 1...7 {
            let candidate =
                recent.indices.contains(lag - 1)
                ? recent[lag - 1]
                : current
            let candidateKey = DayKey(rawValue: candidate.dateKey)
            let dayGap = candidateKey.flatMap { $0.dayGap(to: currentKey) } ?? 0
            values.append(contentsOf: [
                candidate.hrvRMSSDMilliseconds ?? hrv,
                candidate.restingHeartRateBPM ?? rhr,
                stepsByDate[candidate.dateKey] ?? currentSteps,
                candidate.sleepScore ?? sleepScore,
                Double(
                    candidateKey == currentKey
                        ? 0
                        : dayGap),
            ])
        }

        for window in [7, 14, 30, 60] {
            let prior = Array(eligible.suffix(window))
            appendStatistics(
                current: hrv,
                history: prior.compactMap(\.hrvRMSSDMilliseconds),
                to: &values
            )
            appendStatistics(
                current: rhr,
                history: prior.compactMap(\.restingHeartRateBPM),
                to: &values
            )
            appendStatistics(
                current: currentSteps,
                history: prior.compactMap { stepsByDate[$0.dateKey] },
                to: &values
            )
            appendStatistics(
                current: sleepScore,
                history: prior.compactMap(\.sleepScore),
                to: &values
            )
        }
        guard values.count == featureCount else { return nil }
        return values
    }

    private static func appendStatistics(
        current: Double,
        history: [Double],
        to values: inout [Double]
    ) {
        let finite = history.filter(\.isFinite)
        let mean =
            finite.isEmpty
            ? current
            : finite.reduce(0, +) / Double(finite.count)
        let deviation =
            finite.isEmpty
            ? 0
            : sqrt(finite.map { pow($0 - mean, 2) }.reduce(0, +) / Double(finite.count))
        values.append(contentsOf: [
            mean,
            deviation,
            current - mean,
            mean == 0 ? 1 : current / mean,
            deviation == 0 ? 0 : (current - mean) / deviation,
        ])
    }

    private static func sleepNight(_ record: DailyHealthRecord) -> SleepScoreNight? {
        guard let duration = record.sleepDurationMinutes,
            let efficiency = record.sleepEfficiencyPercentage,
            let start = record.sleepStartMinute,
            let end = record.sleepEndMinute
        else { return nil }
        return SleepScoreNight(
            dateKey: record.dateKey,
            durationMinutes: duration,
            efficiencyPercentage: efficiency,
            startMinute: start,
            endMinute: end
        )
    }

}

struct RecoveryScoreModelBundle: Decodable, Sendable {
    struct RidgeModel: Decodable, Sendable {
        let imputerMedians: [Double]
        let means: [Double]
        let scales: [Double]
        let coefficients: [Double]
        let intercept: Double

        func predict(_ input: [Double]) -> Double? {
            guard input.count == imputerMedians.count,
                input.count == means.count,
                input.count == scales.count,
                input.count == coefficients.count
            else { return nil }
            return input.indices.reduce(intercept) { prediction, index in
                let value = input[index].isFinite ? input[index] : imputerMedians[index]
                let standardized = (value - means[index]) / max(scales[index], 1e-12)
                return prediction + standardized * coefficients[index]
            }
        }
    }

    struct Prediction: Sendable {
        let score: Double
        let confidence: Double
        let hrvComponent: Double
        let rhrComponent: Double
        let sleepComponent: Double
        let stepsComponent: Double
        let hrvBaseline: Double?
        let rhrBaseline: Double?
        let sleepBaseline: Double?
        let stepsBaseline: Double?
    }

    let version: String
    let featureVersion: String
    let featureCount: Int
    let boostedWeight: Double
    let imputerMedians: [Double]
    let boostedModel: SleepScoreModelBundle.GradientBoostedModel
    let ridgeModel: RidgeModel

    func prediction(_ input: [Double]) -> Prediction? {
        guard featureVersion == RecoveryScoreFeatureBuilder.version,
            featureCount == RecoveryScoreFeatureBuilder.featureCount,
            input.count == featureCount,
            imputerMedians.count == featureCount
        else { return nil }
        let prepared = input.indices.map {
            input[$0].isFinite ? input[$0] : imputerMedians[$0]
        }
        guard let full = score(prepared) else { return nil }
        func component(_ indices: [Int]) -> Double {
            var neutral = prepared
            for index in indices where neutral.indices.contains(index) {
                neutral[index] = imputerMedians[index]
            }
            return full - (score(neutral) ?? full)
        }
        return Prediction(
            score: min(99, max(0, full)),
            confidence: input[GeneratedModelFeatures.Recovery.currentStepsIndex].isFinite
                ? 0.90 : 0.82,
            hrvComponent: component(GeneratedModelFeatures.Recovery.hrvIndices),
            rhrComponent: component(GeneratedModelFeatures.Recovery.rhrIndices),
            sleepComponent: component(GeneratedModelFeatures.Recovery.sleepIndices),
            stepsComponent: component(GeneratedModelFeatures.Recovery.stepsIndices),
            hrvBaseline: prepared[GeneratedModelFeatures.Recovery.hrvBaselineIndex],
            rhrBaseline: prepared[GeneratedModelFeatures.Recovery.rhrBaselineIndex],
            sleepBaseline: prepared[GeneratedModelFeatures.Recovery.sleepBaselineIndex],
            stepsBaseline: prepared[GeneratedModelFeatures.Recovery.stepsBaselineIndex]
        )
    }

    private func score(_ prepared: [Double]) -> Double? {
        guard let boosted = boostedModel.predict(prepared),
            let ridge = ridgeModel.predict(prepared)
        else { return nil }
        return boostedWeight * boosted + (1 - boostedWeight) * ridge
    }

    static func load(from bundle: Bundle = .main) -> RecoveryScoreModelBundle? {
        guard let url = bundle.url(forResource: "whoop-recovery-model", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
