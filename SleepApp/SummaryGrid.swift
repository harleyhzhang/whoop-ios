import SwiftUI

struct SummaryGrid: View {
    let day: PublishedDashboardDay

    private var sleepScore: String {
        day.health?.sleepScore.map(MetricKind.sleep.formattedValue) ?? "—"
    }

    private var sleepDuration: String {
        day.health?.sleepDurationMinutes.map {
            MetricKind.duration.formattedValue($0 / 60)
        } ?? "—"
    }

    private var steps: String {
        day.steps.map { MetricKind.steps.formattedValue(Double($0.stepCount)) } ?? "—"
    }

    private var recovery: String {
        day.recovery.map { MetricKind.recovery.formattedValue($0.score) } ?? "—"
    }

    private var restingHeartRate: String {
        day.health?.restingHeartRateBPM.map { String(Int($0.rounded())) } ?? "—"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                metric(
                    kind: .sleep,
                    value: sleepScore
                )
                metric(
                    kind: .duration,
                    value: sleepDuration
                )
            }

            HStack(alignment: .top, spacing: 12) {
                metric(kind: .steps, value: steps)
                metric(kind: .recovery, value: recovery)
                metric(
                    kind: .rhr,
                    value: restingHeartRate,
                    unit: restingHeartRate == "—" ? "" : "BPM"
                )
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Sleep \(sleepScore), duration \(sleepDuration), steps \(steps), recovery \(recovery), resting heart rate \(restingHeartRate) beats per minute"
        )
    }

    private func metric(
        kind: MetricKind,
        value: String,
        unit: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.color)

                Text(kind.summaryTitle)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                AnimatedMetricValue(value: value)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
