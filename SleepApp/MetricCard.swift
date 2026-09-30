import SwiftUI

struct MetricCard: View {
    let metric: HealthMetric
    let selected: HealthDay?
    let days: [HealthDay]

    private var title: String {
        switch metric {
        case .steps: "Step Count"
        case .rhr: "RHR"
        default: metric.title
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.85)
            MetricValue(metric: metric, value: selected?.value(for: metric))
                .foregroundStyle(metric.color)
                .padding(.top, 8)
            Spacer(minLength: 6)
            MetricChart(metric: metric, days: days)
                .frame(height: 82)
        }
        .padding(17)
        .frame(height: 196)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255), location: 0),
                    .init(color: Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255), location: 0.65),
                    .init(color: Color(white: 36 / 255), location: 1),
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }
}

/// Every metric uses separate thin vertical strokes, matching the reference.
/// The long major grid lines
/// bracket four label bays; finer vertical lines stop at the plot baseline.
struct MetricChart: View {
    let metric: HealthMetric
    let days: [HealthDay]

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

    private var domain: ClosedRange<Double> {
        if metric == .sleep || metric == .recovery { return 0...100 }
        if metric == .strain { return 0...21 }
        let values = days.compactMap { $0.value(for: metric) }
        let high = values.max() ?? 1
        return 0...max(high * 1.1, 1)
    }

    var body: some View {
        Canvas { context, size in
            let levels = averageSteps
            let chartDomain = domain
            let plotHeight = max(size.height - 20, 1)
            let plotWidth = max(size.width - 1, 1)
            guard !days.isEmpty else { return }
            // Each day owns one grid interval, with its stroke at the midpoint.
            // Keep empty intervals for missing values so the remaining strokes don't shift.
            let slotCount = Double(days.count)
            let majorBoundaries = (0...4).map { Int((slotCount * Double($0) / 4).rounded()) }
            func boundaryX(_ index: Int) -> Double {
                0.5 + plotWidth * Double(index) / slotCount
            }
            for index in 0...days.count {
                let major = majorBoundaries.contains(index)
                let x = boundaryX(index)
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: plotHeight + (major ? 18 : 0)))
                context.stroke(
                    grid,
                    with: .color(Color(white: major ? 0.32 : 0.28)),
                    lineWidth: major ? 0.7 : 0.5
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
            var trace = Path()
            for (index, day) in days.enumerated() {
                guard let value = day.value(for: metric) else { continue }
                let x = 0.5 + plotWidth * (Double(index) + 0.5) / slotCount
                let y = height(value)
                trace.move(to: CGPoint(x: x, y: plotHeight - 1))
                trace.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(
                trace,
                with: .color(metric.color.opacity(levels.isEmpty ? 1 : 0.3)),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            )

            for step in levels {
                let startX = 0.5 + position(step.startDate) * plotWidth
                let endX = 0.5 + position(step.endDate) * plotWidth
                let y = height(step.value)
                var level = Path()
                level.move(to: CGPoint(x: startX, y: y))
                level.addLine(to: CGPoint(x: endX, y: y))
                context.stroke(
                    level, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                context.draw(
                    Text(averageLabel(step.value))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.white),
                    at: CGPoint(x: min(max((startX + endX) / 2, 11), size.width - 11), y: max(6, y - 9)),
                    anchor: .center
                )
            }

            for index in 0..<4 {
                let start = majorBoundaries[index]
                let end = majorBoundaries[index + 1]
                let labelIndex = min((start + end) / 2, days.count - 1)
                let label = days[labelIndex].date.formatted(.dateTime.month(.abbreviated).day())
                context.draw(
                    Text(label).font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color(white: 0.42)),
                    at: CGPoint(x: (boundaryX(start) + boundaryX(end)) / 2, y: plotHeight + 12),
                    anchor: .center
                )
            }
        }
        .accessibilityHidden(true)
    }
}
