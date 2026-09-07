import Combine
import Foundation

extension Notification.Name {
    static let whoopDailyHealthUpdated = Notification.Name("whoopDailyHealthUpdated")
}

struct DailyHealthRecord: Codable, Hashable, Identifiable, Sendable {
    let dateKey: String
    let sleepScore: Double?
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

@MainActor
final class HealthHistoryModel: ObservableObject {
    @Published private(set) var records: [DailyHealthRecord] = []
    @Published private(set) var stepRecords: [DailyStepRecord] = []
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

    /// Chart construction is intentionally cached outside `View.body`.
    /// SwiftUI evaluates the chart repeatedly during a range morph; date
    /// parsing, filtering and bucket medians only need to run when history,
    /// range, metric, or the reference day changes.
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
        } else {
            daily = records.compactMap { record -> MetricPoint? in
                let date = cachedDate(for: record)
                if let cutoff, date < calendar.startOfDay(for: cutoff) { return nil }
                let value: Double?
                switch metric {
                case .sleep: value = record.sleepScore
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
        store.loadDailyHealthRecords { [weak self] result in
            store.loadDailyStepRecords { stepResult in
                Task { @MainActor in
                    guard let self, generation == self.reloadGeneration else { return }
                    var errors: [String] = []
                    switch result {
                    case .success(let records):
                        self.records = records
                    case .failure(let error):
                        errors.append(error.localizedDescription)
                    }
                    switch stepResult {
                    case .success(let records):
                        self.stepRecords = records
                    case .failure(let error):
                        errors.append(error.localizedDescription)
                    }
                    // Preserve either last known-good dataset through a
                    // transient read failure instead of blanking its chart.
                    self.seriesCache.removeAll(keepingCapacity: true)
                    self.dateCache.removeAll(keepingCapacity: true)
                    self.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                    self.isLoading = false
                }
            }
        }
    }
}
