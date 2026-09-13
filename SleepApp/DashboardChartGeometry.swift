import Foundation

enum DashboardChartGeometry {
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

    static func averageLevels(
        from points: [MetricPoint],
        for range: HealthRange
    ) -> [AverageLevel] {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else {
            return []
        }
        switch range {
        case .week, .month: return []
        case .year, .all: break
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

    static func morphingPoints(
        target: MetricSeries,
        source: MetricSeries?,
        progress: Double
    ) -> [MorphingMetricPoint] {
        let sampleCount = 48
        let targetValues = ChartCurveSampler.resampledValues(
            from: target.plotted,
            count: sampleCount
        )
        guard !targetValues.isEmpty else { return [] }
        let sampledSource = source.map {
            ChartCurveSampler.resampledValues(from: $0.plotted, count: sampleCount)
        }
        let sourceValues: [Double]
        if let sampledSource, sampledSource.count == targetValues.count {
            sourceValues = sampledSource
        } else {
            sourceValues = targetValues
        }
        return targetValues.indices.map { index in
            MorphingMetricPoint(
                id: index,
                position: Double(index) / Double(max(targetValues.count - 1, 1)),
                value: interpolate(sourceValues[index], targetValues[index], progress)
            )
        }
    }

    static func morphingDomain(
        metric: MetricKind,
        target: MetricSeries,
        source: MetricSeries?,
        progress: Double
    ) -> ClosedRange<Double> {
        let targetDomain = metric.chartDomain(for: target.daily)
        guard let source, !source.daily.isEmpty else { return targetDomain }
        let sourceDomain = metric.chartDomain(for: source.daily)
        let lowerBound = interpolate(sourceDomain.lowerBound, targetDomain.lowerBound, progress)
        let upperBound = interpolate(sourceDomain.upperBound, targetDomain.upperBound, progress)
        return lowerBound...upperBound
    }

    static func averageOpacity(
        selectedRange: HealthRange,
        sourceRange: HealthRange?,
        progress: Double
    ) -> Double {
        let targetIsLong = selectedRange.usesMonthlyAxis
        guard let sourceRange else { return targetIsLong ? 1 : 0 }
        let sourceIsLong = sourceRange.usesMonthlyAxis
        let eased = smoothStep(progress)
        if targetIsLong { return eased }
        return sourceIsLong ? 1 - eased : 0
    }

    static func longRangeStyleProgress(
        selectedRange: HealthRange,
        sourceRange: HealthRange?,
        progress: Double
    ) -> Double {
        let target = selectedRange.usesMonthlyAxis ? 1.0 : 0.0
        guard let sourceRange else { return target }
        let source = sourceRange.usesMonthlyAxis ? 1.0 : 0.0
        return interpolate(source, target, progress)
    }

    static func axisLabel(for date: Date, range: HealthRange) -> String {
        switch range {
        case .week, .month:
            date.formatted(.dateTime.month(.abbreviated).day())
        case .year, .all:
            date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    static func yAxisValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 4
        return (0...4).map { domain.lowerBound + (Double($0) * step) }
    }

    private static func interpolate(_ source: Double, _ target: Double, _ progress: Double) -> Double {
        source + ((target - source) * progress)
    }

    private static func smoothStep(_ rawValue: Double) -> Double {
        let value = min(max(rawValue, 0), 1)
        return value * value * (3 - (2 * value))
    }
}
