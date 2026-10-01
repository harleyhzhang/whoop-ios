import SwiftUI

struct SummaryRings: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let selected: HealthDay?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                rings.frame(width: 174, height: 174).offset(x: -24)
                values
            }
            VStack(spacing: 20) {
                rings.frame(width: 174, height: 174)
                values
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255), Color(white: 36 / 255)],
                startPoint: .bottomLeading, endPoint: .topTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.rings")
    }

    private var rings: some View {
        ZStack {
            SummaryRing(metric: .strain, value: selected?.strain)
            SummaryRing(metric: .recovery, value: selected?.recovery).padding(23)
            SummaryRing(metric: .sleep, value: selected?.sleep).padding(46)
        }
        .accessibilityHidden(true)
    }

    private var values: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([HealthMetric.sleep, .recovery, .strain]) { metric in
                VStack(alignment: .leading, spacing: 0) {
                    Text(metric.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                    MetricValue(
                        metric: metric, value: selected?.value(for: metric),
                        numberFontSize: typeSize.isAccessibilitySize ? 36 : 30,
                        unitFontSize: 20
                    )
                    .foregroundStyle(metric.color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(metric.title), \(metric.formatted(selected?.value(for: metric)))")
                .accessibilityIdentifier("summary.\(metric.rawValue)")
            }
        }
    }
}

private struct SummaryRing: View {
    let metric: HealthMetric
    let value: Double?

    private var fraction: Double {
        min(max((value ?? 0) / (metric == .strain ? 21 : 100), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle().stroke(metric.color.opacity(0.16), lineWidth: 18)
            Circle().trim(from: 0, to: fraction)
                .stroke(metric.color, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(9)
    }
}
