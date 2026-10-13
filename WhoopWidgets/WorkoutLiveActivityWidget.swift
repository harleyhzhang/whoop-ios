import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WhoopWidgets: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivityWidget()
    }
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.Palette.canvas)
                .activitySystemActionForegroundColor(Theme.Palette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: context.attributes.symbol)
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.strain)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HeartRate(bpm: context.state.heartRate)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: Theme.Layout.spacing) {
                        HStack(alignment: .lastTextBaseline) {
                            Elapsed(start: context.attributes.start)
                            Spacer()
                            Summary(state: context.state)
                        }
                        ZoneSegments(current: context.state.zone)
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol)
                    .foregroundStyle(Theme.Palette.strain)
            } compactTrailing: {
                HeartRate(bpm: context.state.heartRate)
            } minimal: {
                Image(systemName: context.attributes.symbol)
                    .foregroundStyle(Theme.Palette.strain)
            }
        }
    }
}

private struct WorkoutLockScreen: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.spacing) {
            HStack {
                Label(attributes.title, systemImage: attributes.symbol)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.strain)
                Spacer()
                HeartRate(bpm: state.heartRate)
            }
            HStack(alignment: .lastTextBaseline) {
                Elapsed(start: attributes.start)
                Spacer()
                Summary(state: state)
            }
            ZoneSegments(current: state.zone)
        }
        .padding(Theme.Layout.cardPadding)
    }
}

private struct Elapsed: View {
    let start: Date

    var body: some View {
        Text(start, style: .timer)
            .font(Theme.Typography.hero)
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

private struct HeartRate: View {
    let bpm: Int?

    var body: some View {
        HStack(spacing: Theme.Layout.historyLabelSpacing) {
            Image(systemName: "heart.fill")
                .foregroundStyle(Theme.Palette.negative)
            Text(bpm.map(String.init) ?? "—")
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.text)
        }
        .font(Theme.Typography.unit)
    }
}

private struct Summary: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Layout.historyLabelSpacing) {
            row("Avg", state.averageHeartRate)
            row("Max", state.maxHeartRate)
        }
    }

    private func row(_ title: String, _ bpm: Int?) -> some View {
        HStack(spacing: Theme.Layout.historyLabelSpacing) {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.muted)
            Text(bpm.map(String.init) ?? "—")
                .font(Theme.Typography.unit)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.text)
        }
    }
}
