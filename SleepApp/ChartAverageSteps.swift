import Foundation

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
