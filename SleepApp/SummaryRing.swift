import SwiftUI

struct SummaryRing: View {
    let metric: HealthMetric
    let value: Double?
    private var fraction: Double {
        min(max((value ?? 0) / (metric == .strain ? 21 : 100), 0), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color(uiColor: .systemGray5), lineWidth: 7)
                Circle().trim(from: 0, to: fraction)
                    .stroke(metric.ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                MetricValue(metric: metric, value: value, numberFontSize: 32, unitFontSize: 20)
                    .foregroundStyle(.primary)
                    .padding(12)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            Text(metric.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(metric.title), \(metric.formatted(value))")
    }
}
