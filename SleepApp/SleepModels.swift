import Combine
import Foundation

extension Notification.Name {
    static let whoopDailyHealthUpdated = Notification.Name("whoopDailyHealthUpdated")
}

enum WhoopHealthHistoryUpdate: Sendable {
    case dayPublished(DailyHealthRecord)
    case projectionsChanged
}

@MainActor
enum WhoopHealthHistoryEvents {
    static func post(_ update: WhoopHealthHistoryUpdate) {
        NotificationCenter.default.post(name: .whoopDailyHealthUpdated, object: update)
    }
}

struct DailyHealthRecord: Codable, Hashable, Identifiable, Sendable {
    let dateKey: String
    let sleepScore: Double?
    /// Display projection only. The store retains WHOOP's official target and
    /// our independently derived score in separate tables/columns.
    let recoveryScore: Double?
    let recoveryScoreSource: String?
    let sleepDurationMinutes: Double?
    let hrvRMSSDMilliseconds: Double?
    let restingHeartRateBPM: Double?
    let sleepID: String?
    let cycleID: Int64?
    let source: String
    let sourceArchive: String?
    let sourceUpdatedAt: String

    /// Retained score inputs. WHOOP API rows preserve the values WHOOP
    /// published; locally derived rows preserve the measurements used by the
    /// versioned replacement model. They intentionally remain optional so an
    /// older private seed can still be decoded during an in-place update.
    let sleepStartAt: String?
    let sleepEndAt: String?
    let sleepStartMinute: Double?
    let sleepEndMinute: Double?
    let sleepNeedMinutes: Double?
    let sleepConsistencyPercentage: Double?
    let sleepEfficiencyPercentage: Double?
    let sleepSufficiencyPercentage: Double?
    /// Complete source rows, retained outside the display projection so future
    /// models can recover fields this version does not yet materialize.
    let sourceSleepPayloadJSON: String?
    let sourceRecoveryPayloadJSON: String?

    init(
        dateKey: String,
        sleepScore: Double?,
        recoveryScore: Double? = nil,
        recoveryScoreSource: String? = nil,
        sleepDurationMinutes: Double?,
        hrvRMSSDMilliseconds: Double?,
        restingHeartRateBPM: Double?,
        sleepID: String?,
        cycleID: Int64?,
        source: String,
        sourceArchive: String?,
        sourceUpdatedAt: String,
        sleepStartAt: String? = nil,
        sleepEndAt: String? = nil,
        sleepStartMinute: Double? = nil,
        sleepEndMinute: Double? = nil,
        sleepNeedMinutes: Double? = nil,
        sleepConsistencyPercentage: Double? = nil,
        sleepEfficiencyPercentage: Double? = nil,
        sleepSufficiencyPercentage: Double? = nil,
        sourceSleepPayloadJSON: String? = nil,
        sourceRecoveryPayloadJSON: String? = nil
    ) {
        self.dateKey = dateKey
        self.sleepScore = sleepScore
        self.recoveryScore = recoveryScore
        self.recoveryScoreSource = recoveryScoreSource
        self.sleepDurationMinutes = sleepDurationMinutes
        self.hrvRMSSDMilliseconds = hrvRMSSDMilliseconds
        self.restingHeartRateBPM = restingHeartRateBPM
        self.sleepID = sleepID
        self.cycleID = cycleID
        self.source = source
        self.sourceArchive = sourceArchive
        self.sourceUpdatedAt = sourceUpdatedAt
        self.sleepStartAt = sleepStartAt
        self.sleepEndAt = sleepEndAt
        self.sleepStartMinute = sleepStartMinute
        self.sleepEndMinute = sleepEndMinute
        self.sleepNeedMinutes = sleepNeedMinutes
        self.sleepConsistencyPercentage = sleepConsistencyPercentage
        self.sleepEfficiencyPercentage = sleepEfficiencyPercentage
        self.sleepSufficiencyPercentage = sleepSufficiencyPercentage
        self.sourceSleepPayloadJSON = sourceSleepPayloadJSON
        self.sourceRecoveryPayloadJSON = sourceRecoveryPayloadJSON
    }

    var id: String { dateKey }

    var hasCompletePrimarySleepMetrics: Bool {
        sleepScore != nil
            && sleepDurationMinutes != nil
            && hrvRMSSDMilliseconds != nil
            && restingHeartRateBPM != nil
    }

    var date: Date {
        let pieces = dateKey.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return .distantPast }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = pieces[0]
        components.month = pieces[1]
        components.day = pieces[2]
        components.hour = 12
        return components.date ?? .distantPast
    }
}

struct OfficialMetricsSeed: Decodable, Sendable {
    let formatVersion: Int
    let source: String
    let sourceArchive: String
    let sourceManifestSHA256: String
    let sourceDatabaseSHA256: String
    let coverageStart: String
    let coverageEnd: String
    let daily: [OfficialDailyMetricSeed]
}

struct OfficialDailyMetricSeed: Decodable, Sendable {
    let dateKey: String
    let officialRecoveryScore: Double?
    let officialSteps: Int?
    let officialDayStrain: Double?
    let dayStrainTarget: Double?
    let stepsBaseline: Double?
    let hrv: Double?
    let hrvBaseline: Double?
    let rhr: Double?
    let rhrBaseline: Double?
    let respiratoryRate: Double?
    let respiratoryRateBaseline: Double?
    let sleepPerformance: Double?
    let sleepPerformanceBaseline: Double?
    let sourceRecoverySHA256: String?
    let sourceStrainSHA256: String?
}

struct DailyStepRecord: Hashable, Identifiable, Sendable {
    let dateKey: String
    let stepCount: Int
    let sampleCount: Int
    let spanSeconds: Int
    let coverageFraction: Double
    let gapSeconds: Int
    let counterWrapCount: Int
    let rejectedDeltaCount: Int
    let firstSampleAt: Date?
    let lastSampleAt: Date?
    let source: String
    let algorithmVersion: Int

    var id: String { dateKey }

    var date: Date {
        let pieces = dateKey.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return .distantPast }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = pieces[0]
        components.month = pieces[1]
        components.day = pieces[2]
        components.hour = 12
        return components.date ?? .distantPast
    }
}

struct DailyRecoveryRecord: Hashable, Identifiable, Sendable {
    let dateKey: String
    let score: Double
    let source: String

    var id: String { dateKey }

    var date: Date {
        let pieces = dateKey.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return .distantPast }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = pieces[0]
        components.month = pieces[1]
        components.day = pieces[2]
        components.hour = 12
        return components.date ?? .distantPast
    }
}

/// One coherent, wake-published dashboard day. A detected or processing sleep
/// is the boundary between days, so no metric may independently fall back to a
/// stale or provisional timeline point while that boundary is unpublished.
struct PublishedDashboardDay: Sendable {
    let health: DailyHealthRecord?
    let steps: DailyStepRecord?
    let recovery: DailyRecoveryRecord?

    init(
        healthRecords: [DailyHealthRecord],
        stepRecords: [DailyStepRecord],
        recoveryRecords: [DailyRecoveryRecord],
        isWakePending: Bool
    ) {
        guard !isWakePending,
              let health = healthRecords.last,
              let steps = stepRecords.last(where: { $0.dateKey == health.dateKey }),
              let recovery = recoveryRecords.last(where: { $0.dateKey == health.dateKey }) else {
            self.health = nil
            self.steps = nil
            self.recovery = nil
            return
        }

        self.health = health
        self.steps = steps
        self.recovery = recovery
    }

    var date: Date? { health?.date }
}

/// One database-generation of every history family consumed by the dashboard.
/// The store constructs this inside one SQLite read transaction so a write can
/// never land between the health, step, and recovery queries.
struct DashboardHistorySnapshot: Sendable {
    let healthRecords: [DailyHealthRecord]
    let stepRecords: [DailyStepRecord]
    let recoveryRecords: [DailyRecoveryRecord]
}

struct SleepScoreNight: Sendable, Equatable {
    let dateKey: String
    let durationMinutes: Double
    let efficiencyPercentage: Double
    let startMinute: Double
    let endMinute: Double
}

enum SleepScoreFeatureBuilder {
    static let version = "whoop_local_features_v1"
    static let featureCount = 50

    static func features(current: SleepScoreNight, history: [SleepScoreNight]) -> [Double] {
        let recent = history
            .filter { $0.dateKey < current.dateKey }
            .sorted { $0.dateKey > $1.dateKey }

        var values = [
            current.durationMinutes,
            current.efficiencyPercentage,
            sin(2 * .pi * current.startMinute / 1_440),
            cos(2 * .pi * current.startMinute / 1_440),
            sin(2 * .pi * current.endMinute / 1_440),
            cos(2 * .pi * current.endMinute / 1_440)
        ]
        var previous: [SleepScoreNight] = []
        for lag in 1...7 {
            let candidate = recent.indices.contains(lag - 1) ? recent[lag - 1] : nil
            let gap = candidate.flatMap { dayGap(from: $0.dateKey, to: current.dateKey) }
            let usable = candidate != nil && gap != nil && gap! <= lag + 3
            let night = usable ? candidate! : current
            previous.append(night)
            values.append(contentsOf: [
                night.durationMinutes,
                night.efficiencyPercentage,
                circularMinuteDistance(current.startMinute, night.startMinute),
                circularMinuteDistance(current.endMinute, night.endMinute),
                usable ? Double(gap!) : 0
            ])
        }

        let firstFour = Array(previous.prefix(4))
        let durations = firstFour.map(\.durationMinutes)
        let efficiencies = firstFour.map(\.efficiencyPercentage)
        values.append(contentsOf: [
            mean(durations), standardDeviation(durations),
            mean(efficiencies), standardDeviation(efficiencies)
        ])

        let agreements = firstFour.map { prior in
            max(0, 100 * (1 - (
                circularMinuteDistance(current.startMinute, prior.startMinute)
                    + circularMinuteDistance(current.endMinute, prior.endMinute)
            ) / 1_440))
        }
        values.append(contentsOf: agreements)
        values.append(zip(agreements, [0.52, 0.27, 0.14, 0.07]).map(*).reduce(0, +))
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

    private static func dayGap(from start: String, to end: String) -> Int? {
        let calendar = Calendar(identifier: .gregorian)
        guard let startDate = date(from: start), let endDate = date(from: end) else { return nil }
        return calendar.dateComponents([.day], from: startDate, to: endDate).day
    }

    private static func date(from key: String) -> Date? {
        let components = key.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(
            year: components[0], month: components[1], day: components[2], hour: 12
        ))
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
                      input.indices.contains(features[node]), childrenRight.indices.contains(node) else {
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
                  supportVectors.count == dualCoefficients.count else { return nil }
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
    let directWeight: Double
    let extraTreesWeight: Double
    let trees: [ExtraTree]
    let svr: SVRModel
    let needModel: GradientBoostedModel
    let consistencyModel: GradientBoostedModel
    let pillarSVR: SVRModel

    func prediction(_ features: [Double]) -> Prediction? {
        guard featureVersion == SleepScoreFeatureBuilder.version,
              features.count == SleepScoreFeatureBuilder.featureCount,
              !trees.isEmpty,
              let svrPrediction = svr.predict(features),
              let need = needModel.predict(features), need > 0,
              let consistency = consistencyModel.predict(features) else { return nil }
        let treePredictions = trees.compactMap { $0.predict(features) }
        guard treePredictions.count == trees.count else { return nil }
        let forestPrediction = treePredictions.reduce(0, +) / Double(treePredictions.count)
        let directPrediction = extraTreesWeight * forestPrediction
            + (1 - extraTreesWeight) * svrPrediction
        let sufficiency = min(100, features[0] / need * 100)
        guard let pillarPrediction = pillarSVR.predict([
            sufficiency, consistency, features[1]
        ]) else { return nil }
        return Prediction(
            score: min(99, max(0,
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
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum RecoveryScoreFeatureBuilder {
    static let version = "whoop_local_recovery_features_v1"
    static let featureCount = 169

    static func features(
        current: DailyHealthRecord,
        history: [DailyHealthRecord],
        stepsByDate: [String: Double]
    ) -> [Double]? {
        guard let currentNight = sleepNight(current),
              let hrv = current.hrvRMSSDMilliseconds,
              let rhr = current.restingHeartRateBPM,
              let sleepScore = current.sleepScore else { return nil }
        let eligible = history
            .filter { $0.dateKey < current.dateKey && sleepNight($0) != nil }
            .sorted { $0.dateKey < $1.dateKey }
        let sleepHistory = eligible.compactMap(sleepNight)
        var values = SleepScoreFeatureBuilder.features(
            current: currentNight,
            history: sleepHistory
        )
        let currentSteps = stepsByDate[current.dateKey] ?? .nan
        values.append(contentsOf: [hrv, rhr, currentSteps, sleepScore])

        let recent = Array(eligible.reversed())
        for lag in 1...7 {
            let candidate = recent.indices.contains(lag - 1)
                ? recent[lag - 1]
                : current
            values.append(contentsOf: [
                candidate.hrvRMSSDMilliseconds ?? hrv,
                candidate.restingHeartRateBPM ?? rhr,
                stepsByDate[candidate.dateKey] ?? currentSteps,
                candidate.sleepScore ?? sleepScore,
                Double(candidate.dateKey == current.dateKey
                    ? 0
                    : dayGap(from: candidate.dateKey, to: current.dateKey) ?? 0)
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
        let mean = finite.isEmpty
            ? current
            : finite.reduce(0, +) / Double(finite.count)
        let deviation = finite.isEmpty
            ? 0
            : sqrt(finite.map { pow($0 - mean, 2) }.reduce(0, +) / Double(finite.count))
        values.append(contentsOf: [
            mean,
            deviation,
            current - mean,
            mean == 0 ? 1 : current / mean,
            deviation == 0 ? 0 : (current - mean) / deviation
        ])
    }

    private static func sleepNight(_ record: DailyHealthRecord) -> SleepScoreNight? {
        guard let duration = record.sleepDurationMinutes,
              let efficiency = record.sleepEfficiencyPercentage,
              let start = record.sleepStartMinute,
              let end = record.sleepEndMinute else { return nil }
        return SleepScoreNight(
            dateKey: record.dateKey,
            durationMinutes: duration,
            efficiencyPercentage: efficiency,
            startMinute: start,
            endMinute: end
        )
    }

    private static func dayGap(from start: String, to end: String) -> Int? {
        let calendar = Calendar(identifier: .gregorian)
        func date(_ key: String) -> Date? {
            let values = key.split(separator: "-").compactMap { Int($0) }
            guard values.count == 3 else { return nil }
            return calendar.date(from: DateComponents(
                year: values[0], month: values[1], day: values[2], hour: 12
            ))
        }
        guard let startDate = date(start), let endDate = date(end) else { return nil }
        return calendar.dateComponents([.day], from: startDate, to: endDate).day
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
                  input.count == coefficients.count else { return nil }
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
              imputerMedians.count == featureCount else { return nil }
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
            confidence: input[52].isFinite ? 0.90 : 0.82,
            hrvComponent: component(Self.hrvIndices),
            rhrComponent: component(Self.rhrIndices),
            sleepComponent: component(Self.sleepIndices),
            stepsComponent: component(Self.stepsIndices),
            hrvBaseline: prepared.indices.contains(129) ? prepared[129] : nil,
            rhrBaseline: prepared.indices.contains(134) ? prepared[134] : nil,
            sleepBaseline: prepared.indices.contains(144) ? prepared[144] : nil,
            stepsBaseline: prepared.indices.contains(139) ? prepared[139] : nil
        )
    }

    private func score(_ prepared: [Double]) -> Double? {
        guard let boosted = boostedModel.predict(prepared),
              let ridge = ridgeModel.predict(prepared) else { return nil }
        return boostedWeight * boosted + (1 - boostedWeight) * ridge
    }

    private static let hrvIndices = featureIndices(
        current: [50], lagOffset: 54, rollingOffset: 89
    )
    private static let rhrIndices = featureIndices(
        current: [51], lagOffset: 55, rollingOffset: 94
    )
    private static let stepsIndices = featureIndices(
        current: [52], lagOffset: 56, rollingOffset: 99
    )
    private static let sleepIndices = featureIndices(
        current: Array(0..<50) + [53], lagOffset: 57, rollingOffset: 104
    )

    private static func featureIndices(
        current: [Int],
        lagOffset: Int,
        rollingOffset: Int
    ) -> [Int] {
        var indices = current
        for lag in 0..<7 { indices.append(lagOffset + lag * 5) }
        for window in 0..<4 {
            indices.append(contentsOf: (rollingOffset + window * 20)..<(rollingOffset + window * 20 + 5))
        }
        return indices
    }

    static func load(from bundle: Bundle = .main) -> RecoveryScoreModelBundle? {
        guard let url = bundle.url(forResource: "whoop-recovery-model", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

@MainActor
final class HealthHistoryModel: ObservableObject {
    @Published private(set) var records: [DailyHealthRecord] = []
    @Published private(set) var stepRecords: [DailyStepRecord] = []
    @Published private(set) var recoveryRecords: [DailyRecoveryRecord] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private let store: WhoopStore
    private var reloadGeneration = 0
    private var seriesCache: [ChartSeriesCacheKey: MetricSeries] = [:]
    private var dateCache: [String: Date] = [:]

    private struct ChartSeriesCacheKey: Hashable {
        let metric: MetricKind
        let range: HealthRange
        let referenceDay: Date
    }

    init(store: WhoopStore = .shared) {
        self.store = store
        reload()
    }

    var latestRecord: DailyHealthRecord? { records.last }

    var sourceSummary: String {
        guard let latestRecord else { return isLoading ? "Loading real history…" : "No real history imported" }
        return "WHOOP API history · \(records.count) nights · through \(latestRecord.date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Applies one freshly derived night without waiting for the full reload, so
    /// the dashboard can update on the frame after a manual process.
    func merge(_ record: DailyHealthRecord) {
        if let index = records.firstIndex(where: { $0.dateKey == record.dateKey }) {
            records[index] = record
        } else {
            records.append(record)
            records.sort { $0.dateKey < $1.dateKey }
        }
        seriesCache.removeAll(keepingCapacity: true)
        dateCache[record.dateKey] = record.date
    }

    /// Chart construction is intentionally cached outside `View.body` because
    /// date parsing, filtering and bucket medians only need to run when
    /// history, range, metric, or the reference day changes.
    func metricSeries(
        for metric: MetricKind,
        range: HealthRange,
        referenceDate: Date
    ) -> MetricSeries {
        let calendar = Calendar.current
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let key = ChartSeriesCacheKey(metric: metric, range: range, referenceDay: referenceDay)
        if let cached = seriesCache[key] { return cached }

        let cutoff = range.dayCount.flatMap {
            calendar.date(byAdding: .day, value: -($0 - 1), to: referenceDay)
        }
        let daily: [MetricPoint]
        if metric == .steps {
            daily = stepRecords.compactMap { record in
                let date = cachedDate(dateKey: record.dateKey, fallback: record.date)
                if let cutoff, date < calendar.startOfDay(for: cutoff) { return nil }
                return MetricPoint(date: date, value: Double(record.stepCount))
            }
        } else if metric == .recovery {
            daily = recoveryRecords.compactMap { record in
                let date = cachedDate(dateKey: record.dateKey, fallback: record.date)
                if let cutoff, date < calendar.startOfDay(for: cutoff) { return nil }
                return MetricPoint(date: date, value: record.score)
            }
        } else {
            daily = records.compactMap { record -> MetricPoint? in
                let date = cachedDate(for: record)
                if let cutoff, date < calendar.startOfDay(for: cutoff) { return nil }
                let value: Double?
                switch metric {
                case .sleep: value = record.sleepScore
                case .recovery: value = nil
                case .duration: value = record.sleepDurationMinutes.map { $0 / 60 }
                case .hrv: value = record.hrvRMSSDMilliseconds
                case .rhr: value = record.restingHeartRateBPM
                case .steps: value = nil
                }
                return value.map { MetricPoint(date: date, value: $0) }
            }
        }
        let plotted: [MetricPoint]
        switch range {
        case .week, .month:
            plotted = daily
        case .year:
            plotted = medianBuckets(from: daily, spanning: 7)
        case .all:
            plotted = medianBuckets(from: daily, spanning: adaptiveBucketDays(for: daily))
        }
        let result = MetricSeries(daily: daily, plotted: plotted)
        seriesCache[key] = result
        return result
    }

    private func cachedDate(for record: DailyHealthRecord) -> Date {
        cachedDate(dateKey: record.dateKey, fallback: record.date)
    }

    private func cachedDate(dateKey: String, fallback: Date) -> Date {
        if let cached = dateCache[dateKey] { return cached }
        dateCache[dateKey] = fallback
        return fallback
    }

    private func adaptiveBucketDays(for points: [MetricPoint]) -> Int {
        guard let first = points.first, let last = points.last else { return 7 }
        let calendar = Calendar.current
        let span = max(1, (calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: first.date),
            to: calendar.startOfDay(for: last.date)
        ).day ?? 0) + 1)
        return max(7, Int(ceil(Double(span) / 50)))
    }

    private func medianBuckets(from points: [MetricPoint], spanning bucketDays: Int) -> [MetricPoint] {
        guard let first = points.first, bucketDays > 1 else { return points }
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: first.date)
        let grouped = Dictionary(grouping: points) {
            max(0, (calendar.dateComponents(
                [.day], from: anchor, to: calendar.startOfDay(for: $0.date)
            ).day ?? 0) / bucketDays)
        }
        let finalBucket = grouped.keys.max()
        return grouped.keys.sorted().compactMap { key in
            guard let bucket = grouped[key]?.sorted(by: { $0.date < $1.date }), !bucket.isEmpty else {
                return nil
            }
            if key == finalBucket { return bucket.last }
            let values = bucket.map(\.value).sorted()
            let middle = values.count / 2
            let median = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
            return MetricPoint(date: bucket.last!.date, value: median)
        }
    }

    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        let store = store
        store.loadDashboardHistory { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.reloadGeneration else { return }
                switch result {
                case .success(let snapshot):
                    self.records = snapshot.healthRecords
                    self.stepRecords = snapshot.stepRecords
                    self.recoveryRecords = snapshot.recoveryRecords
                    self.errorMessage = nil
                case .failure(let error):
                    // Preserve every last known-good dataset through a
                    // transient read failure instead of blanking its charts.
                    self.errorMessage = error.localizedDescription
                }
                self.seriesCache.removeAll(keepingCapacity: true)
                self.dateCache.removeAll(keepingCapacity: true)
                self.isLoading = false
            }
        }
    }
}
