import SwiftUI

struct MetricHeader: View {
    let metric: HealthMetric

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: metric.symbol)
                .font(Theme.Icon.label)
                .frame(width: 14)
                .foregroundStyle(Theme.Palette.muted)
                .accessibilityHidden(true)
            Text(metric.title)
                .font(Theme.Typography.body)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Palette.text)
    }
}

struct MetricCard: View {
    let metric: HealthMetric
    let selected: HealthDay?
    let days: [HealthDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricHeader(metric: metric)
            MetricValue(metric: metric, value: selected?.value(for: metric))
                .padding(.top, 2)
            Spacer(minLength: 6)
            MetricChart(metric: metric, days: days)
                .frame(height: 82)
        }
        .padding(Theme.Layout.cardPadding)
        .frame(height: 196)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// Every metric uses separate thin vertical strokes, matching the reference.
/// The long major grid lines
/// bracket four label bays; finer vertical lines stop at the plot baseline.
struct MetricChart: View {
    @Environment(\.displayScale) private var displayScale
    let metric: HealthMetric
    let days: [HealthDay]
    private let guideColor = Theme.Palette.guide

    private var averageSteps: [ChartAverageStep] {
        ChartAverageSteps.levels(days: days, metric: metric)
    }

    private func averageLabel(_ value: Double) -> String {
        switch metric {
        case .steps:
            return value >= 1_000 ? String(format: "%.1fk", value / 1_000) : String(Int(value.rounded()))
        case .duration:
            let minutes = Int(value.rounded())
            return "\(minutes / 60)h \(minutes % 60)m"
        case .sleep, .recovery: return "\(Int(value.rounded()))%"
        case .hrv, .rhr: return String(Int(value.rounded()))
        case .strain: return String(format: "%.1f", value)
        }
    }

    private func domain(buckets: [ChartBucket], levels: [ChartAverageStep]) -> ClosedRange<Double> {
        let values = buckets.compactMap(\.value) + levels.map(\.value)
        return ChartValueScale.domain(metric: metric, values: values)
    }

    var body: some View {
        Canvas { context, size in
            let levels = averageSteps
            let buckets = ChartBuckets.values(days: days, metric: metric)
            let chartDomain = domain(buckets: buckets, levels: levels)
            let plotHeight = max(size.height - 20, 1)
            let plotWidth = max(size.width - 1, 1)
            guard !buckets.isEmpty else { return }
            // Each full-history bucket owns a grid interval and one centered stroke.
            // Keep empty buckets in place so the remaining strokes don't shift.
            let slotCount = Double(buckets.count)
            let bayCount = min(4, buckets.count)
            let majorBoundaries = (0...bayCount).map { Int((slotCount * Double($0) / Double(bayCount)).rounded()) }
            func boundaryX(_ index: Int) -> Double {
                0.5 + plotWidth * Double(index) / slotCount
            }
            for index in 0...buckets.count {
                let major = majorBoundaries.contains(index)
                // Uniform pixel-aligned strokes keep every guide the same visible grey.
                let x = (boundaryX(index) * displayScale).rounded() / displayScale
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: plotHeight + (major ? 18 : 0)))
                context.stroke(
                    grid,
                    with: .color(guideColor),
                    lineWidth: 2 / displayScale
                )
            }

            guard let first = days.first, let last = days.last else { return }
            let timeSpan = max(last.date.timeIntervalSince(first.date), 1)
            let valueSpan = max(chartDomain.upperBound - chartDomain.lowerBound, 1)
            let plotTop = 10.0
            func position(_ date: Date) -> Double {
                min(max(date.timeIntervalSince(first.date) / timeSpan, 0), 1)
            }
            func height(_ value: Double) -> Double {
                plotTop + (1 - (value - chartDomain.lowerBound) / valueSpan) * (plotHeight - plotTop - 1)
            }
            for (index, bucket) in buckets.enumerated() {
                guard let value = bucket.value else { continue }
                let x = 0.5 + plotWidth * (Double(index) + 0.5) / slotCount
                let y = height(value)
                var trace = Path()
                trace.move(to: CGPoint(x: x, y: plotHeight - 1))
                trace.addLine(to: CGPoint(x: x, y: y))
                context.stroke(
                    trace,
                    with: .linearGradient(
                        Theme.chartStrokeGradient(
                            metric.color(for: value), environment: context.environment,
                            opacity: levels.isEmpty ? 1 : 0.75
                        ),
                        startPoint: CGPoint(x: x, y: plotHeight - 1),
                        endPoint: CGPoint(x: x, y: y)
                    ),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
            }

            for step in levels {
                let startX = 0.5 + position(step.startDate) * plotWidth
                let endX = 0.5 + position(step.endDate) * plotWidth
                let y = height(step.value)
                var level = Path()
                level.move(to: CGPoint(x: startX, y: y))
                level.addLine(to: CGPoint(x: endX, y: y))
                context.stroke(
                    level, with: .color(Theme.Palette.text), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                context.draw(
                    Text(averageLabel(step.value))
                        .font(Theme.Typography.caption)
                        .tracking(-0.15).foregroundStyle(Theme.Palette.text),
                    at: CGPoint(x: min(max((startX + endX) / 2, 11), size.width - 11), y: max(6, y - 9)),
                    anchor: .center
                )
            }

            for index in 0..<bayCount {
                let start = majorBoundaries[index]
                let end = majorBoundaries[index + 1]
                let fraction = Double(start + end) / (2 * slotCount)
                let labelDate = first.date.addingTimeInterval(timeSpan * fraction)
                let label =
                    days.count > 90
                    ? labelDate.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
                    : labelDate.formatted(.dateTime.month(.abbreviated).day())
                context.draw(
                    Text(label).font(Theme.Typography.caption)
                        .foregroundStyle(guideColor),
                    at: CGPoint(x: (boundaryX(start) + boundaryX(end)) / 2, y: plotHeight + 12),
                    anchor: .center
                )
            }
        }
        .accessibilityHidden(true)
    }
}
