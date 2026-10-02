import Foundation

struct ChartBucket {
    let startDate: Date
    let endDate: Date
    let value: Double?
}

enum ChartBuckets {
    /// Keep the chart's 31 slots while averaging the entire visible history.
    /// Empty buckets stay empty; no value is carried into another interval.
    static func values(days: [HealthDay], metric: HealthMetric) -> [ChartBucket] {
        guard let first = days.first?.date, let last = days.last?.date else { return [] }
        let count = min(31, days.count)
        let span = last.timeIntervalSince(first)
        let points = days.compactMap { day -> (date: Date, value: Double)? in
            guard let value = day.value(for: metric) else { return nil }
            return (day.date, value)
        }
        return (0..<count).map { index in
            let start = first.addingTimeInterval(span * Double(index) / Double(count))
            let end = first.addingTimeInterval(span * Double(index + 1) / Double(count))
            let values = points.filter {
                $0.date >= start && ($0.date < end || (index == count - 1 && $0.date == end))
            }.map(\.value)
            return ChartBucket(
                startDate: start, endDate: end,
                value: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
        }
    }
}

struct ChartAverageStep {
    let startDate: Date
    let endDate: Date
    let value: Double
}

enum ChartAverageSteps {
    /// Partition the entire visible time axis equally so all ladder segments
    /// have the same width. Missing values are excluded; the final endpoint
    /// belongs only to the last window.
    static func levels(days: [HealthDay], metric: HealthMetric) -> [ChartAverageStep] {
        let points: [(date: Date, value: Double)] = days.compactMap { day in
            guard let value = day.value(for: metric) else { return nil }
            return (day.date, value)
        }
        guard !points.isEmpty, let firstDate = days.first?.date, let lastDate = days.last?.date else {
            return []
        }
        let span = lastDate.timeIntervalSince(firstDate)
        guard span > 0 else {
            return [
                ChartAverageStep(
                    startDate: firstDate, endDate: lastDate,
                    value: points.map(\.value).reduce(0, +) / Double(points.count))
            ]
        }
        let windowCount = min(4, days.count)
        var levels: [ChartAverageStep] = []
        for index in 0..<windowCount {
            let windowStart = firstDate.addingTimeInterval(span * Double(index) / Double(windowCount))
            let windowEnd = firstDate.addingTimeInterval(span * Double(index + 1) / Double(windowCount))
            let isLastWindow = index == windowCount - 1
            let values = points.filter {
                $0.date >= windowStart && ($0.date < windowEnd || (isLastWindow && $0.date == windowEnd))
            }
            .map(\.value)
            if !values.isEmpty {
                levels.append(
                    ChartAverageStep(
                        startDate: windowStart,
                        endDate: windowEnd,
                        value: values.reduce(0, +) / Double(values.count)
                    ))
            }
        }
        return levels
    }
}
