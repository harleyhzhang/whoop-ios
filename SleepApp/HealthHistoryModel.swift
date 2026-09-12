import Combine
import Foundation

@MainActor
final class HealthHistoryModel: ObservableObject {
    @Published private(set) var records: [DailyHealthRecord] = []
    @Published private(set) var stepRecords: [DailyStepRecord] = []
    @Published private(set) var recoveryRecords: [DailyRecoveryRecord] = []
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
        let span = max(
            1,
            (calendar.dateComponents(
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
            max(
                0,
                (calendar.dateComponents(
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
            let median =
                values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
            guard let lastDate = bucket.last?.date else { return nil }
            return MetricPoint(date: lastDate, value: median)
        }
    }

    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
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
            }
        }
    }
}
