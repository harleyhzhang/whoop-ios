import Foundation

enum DashboardChartGeometry {
    private static let summaryLineWidth = 2.1
    private static let detailLineWidth = 1.25

    static func monthlyAxisDates(in points: [MetricPoint]) -> [Date] {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else {
            return []
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: points) { point in
            let components = calendar.dateComponents([.year, .month], from: point.date)
            return (components.year ?? 0) * 100 + (components.month ?? 0)
        }
        let representedMonths: [Date] = grouped.values.compactMap { month in
            guard let representativeDate = month.first?.date,
                let interval = calendar.dateInterval(of: .month, for: representativeDate)
            else { return nil }
            let visibleStart = max(interval.start, firstDate)
            let visibleEnd = min(interval.end, lastDate)
            return Date(
                timeIntervalSinceReferenceDate: visibleStart.timeIntervalSinceReferenceDate
                    + (visibleEnd.timeIntervalSince(visibleStart) / 2)
            )
        }
        .sorted()

        let maximumTickCount = 4
        guard representedMonths.count > maximumTickCount else { return representedMonths }
        let lastIndex = representedMonths.count - 1
        return (0..<maximumTickCount).map { position in
            let fraction = Double(position) / Double(maximumTickCount - 1)
            return representedMonths[Int((fraction * Double(lastIndex)).rounded())]
        }
    }

    static func averageLevels(from points: [MetricPoint]) -> [AverageLevel] {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else {
            return []
        }

        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: firstDate)
        let finalDay = calendar.startOfDay(for: lastDate)
        let spanDays = max(
            1,
            (calendar.dateComponents([.day], from: firstDay, to: finalDay).day ?? 0) + 1
        )
        let windowDays = max(1, Int(ceil(Double(spanDays) / 5)))
        var levels: [AverageLevel] = []
        var windowEnd = calendar.date(byAdding: .day, value: 1, to: finalDay) ?? lastDate

        while windowEnd > firstDay {
            let proposedStart =
                calendar.date(byAdding: .day, value: -windowDays, to: windowEnd) ?? firstDay
            let windowStart = max(proposedStart, firstDay)
            let windowPoints = points.filter {
                $0.date >= windowStart && $0.date < windowEnd
            }
            if !windowPoints.isEmpty {
                levels.append(
                    AverageLevel(
                        startDate: windowStart,
                        endDate: min(windowEnd, lastDate),
                        value: windowPoints.map(\.value).reduce(0, +)
                            / Double(windowPoints.count)
                    )
                )
            }
            windowEnd = proposedStart
        }
        return levels.reversed()
    }

    static func selectedPoint(in series: [MetricPoint], near date: Date?) -> MetricPoint? {
        guard let date else { return series.last }
        return series.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        } ?? series.last
    }

    static func normalizedPosition(of date: Date, in points: [MetricPoint]) -> Double {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else {
            return 0.5
        }
        let duration = lastDate.timeIntervalSince(firstDate)
        guard duration > 0 else { return 0.5 }
        return min(max(date.timeIntervalSince(firstDate) / duration, 0), 1)
    }

    /// Keeps one stable point topology while the calm all-history summary
    /// expands into the complete day-by-day line under the user's finger.
    static func detailMorphingPoints(
        in series: MetricSeries,
        progress: Double
    ) -> [MorphingMetricPoint] {
        let sampleCount = series.daily.count
        let summaryValues = ChartCurveSampler.resampledValues(
            from: series.plotted,
            count: sampleCount
        )
        let dailyValues = series.daily.map(\.value)
        guard summaryValues.count == dailyValues.count else { return [] }
        let eased = smoothStep(progress)
        return dailyValues.indices.map { index in
            MorphingMetricPoint(
                id: index,
                position: normalizedPosition(of: series.daily[index].date, in: series.daily),
                value: interpolate(summaryValues[index], dailyValues[index], eased)
            )
        }
    }

    static func yAxisValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 4
        return (0...4).map { domain.lowerBound + (Double($0) * step) }
    }

    static func lineWidth(detailProgress: Double) -> CGFloat {
        CGFloat(interpolate(summaryLineWidth, detailLineWidth, smoothStep(detailProgress)))
    }

    static func returningPosition(from selectedPosition: Double, progress: Double) -> Double {
        interpolate(min(max(selectedPosition, 0), 1), 1, smoothStep(progress))
    }

    static func selectionOverlayOpacity(releaseProgress: Double) -> Double {
        1 - smoothStep(releaseProgress)
    }

    private static func interpolate(_ source: Double, _ target: Double, _ progress: Double) -> Double {
        source + ((target - source) * progress)
    }

    static func smoothStep(_ rawValue: Double) -> Double {
        let value = min(max(rawValue, 0), 1)
        return value * value * (3 - (2 * value))
    }
}
