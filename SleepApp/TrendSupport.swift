import Foundation

struct MetricPoint: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

enum ChartCurveSampler {
    /// Resample a shape-preserving cubic curve onto the fixed topology used by
    /// range morphing. Unlike linear resampling followed by rounded joins, the
    /// sparse Week points produce one continuous curve without overshooting a
    /// neighboring value interval.
    static func resampledValues(from points: [MetricPoint], count: Int) -> [Double] {
        guard count > 0, let first = points.first else { return [] }
        guard points.count > 1 else {
            return Array(repeating: first.value, count: count)
        }

        let offsets = points.map { $0.date.timeIntervalSince(first.date) }
        guard let span = offsets.last, span > 0 else {
            return Array(repeating: first.value, count: count)
        }

        var widths: [Double] = []
        var slopes: [Double] = []
        widths.reserveCapacity(points.count - 1)
        slopes.reserveCapacity(points.count - 1)

        for index in 0..<(points.count - 1) {
            let width = offsets[index + 1] - offsets[index]
            widths.append(width)
            slopes.append(
                width > 0 ? (points[index + 1].value - points[index].value) / width : 0
            )
        }

        var tangents = Array(repeating: 0.0, count: points.count)
        tangents[0] = slopes[0]
        tangents[points.count - 1] = slopes[slopes.count - 1]

        if points.count > 2 {
            for index in 1..<(points.count - 1) {
                let before = slopes[index - 1]
                let after = slopes[index]
                guard before != 0, after != 0, before.sign == after.sign else { continue }

                let previousWidth = widths[index - 1]
                let nextWidth = widths[index]
                let previousWeight = (2 * nextWidth) + previousWidth
                let nextWeight = nextWidth + (2 * previousWidth)
                tangents[index] =
                    (previousWeight + nextWeight)
                    / ((previousWeight / before) + (nextWeight / after))
            }
        }

        var upperIndex = 1
        return (0..<count).map { index in
            let position = Double(index) / Double(max(count - 1, 1))
            let targetOffset = span * position

            while upperIndex < points.count - 1, offsets[upperIndex] < targetOffset {
                upperIndex += 1
            }

            let lowerIndex = upperIndex - 1
            let width = widths[lowerIndex]
            guard width > 0 else { return points[upperIndex].value }

            let progress = (targetOffset - offsets[lowerIndex]) / width
            let squared = progress * progress
            let cubed = squared * progress
            let lowerBasis = (2 * cubed) - (3 * squared) + 1
            let lowerTangentBasis = cubed - (2 * squared) + progress
            let upperBasis = (-2 * cubed) + (3 * squared)
            let upperTangentBasis = cubed - squared

            return (lowerBasis * points[lowerIndex].value)
                + (lowerTangentBasis * width * tangents[lowerIndex])
                + (upperBasis * points[upperIndex].value)
                + (upperTangentBasis * width * tangents[upperIndex])
        }
    }
}

struct MorphingMetricPoint: Identifiable {
    let id: Int
    let position: Double
    let value: Double
}

enum ChartPointAlignment {
    static func nearestCurvePoint(
        to requestedPosition: Double,
        in points: [MorphingMetricPoint]
    ) -> MorphingMetricPoint? {
        points.min {
            abs($0.position - requestedPosition) < abs($1.position - requestedPosition)
        }
    }
}

struct ChartContentOpacity: Equatable {
    let line: Double
    let area: Double

    static func resolve(
        longRangeStyleProgress: Double,
        isScrubbing: Bool
    ) -> ChartContentOpacity {
        if isScrubbing {
            return ChartContentOpacity(line: 1, area: 0.26)
        }

        let progress = min(max(longRangeStyleProgress, 0), 1)
        return ChartContentOpacity(
            line: 1 + ((0.3 - 1) * progress),
            area: 0.26 + ((0.07 - 0.26) * progress)
        )
    }
}

struct AverageLevel: Identifiable {
    let startDate: Date
    let endDate: Date
    let value: Double

    var id: Date { startDate }
}

struct MetricSeries {
    let daily: [MetricPoint]
    let plotted: [MetricPoint]
}

enum MetricKind: Hashable {
    case sleep
    case recovery
    case duration
    case hrv
    case rhr
    case steps
}

enum HealthRange: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"

    var id: String { rawValue }

    var dayCount: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .year: 365
        case .all: nil
        }
    }

    var accessibilityName: String {
        switch self {
        case .week: "one week"
        case .month: "one month"
        case .year: "one year"
        case .all: "all history"
        }
    }

    var usesMonthlyAxis: Bool {
        switch self {
        case .week, .month: false
        case .year, .all: true
        }
    }

}
