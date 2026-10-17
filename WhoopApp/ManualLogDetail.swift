import SwiftUI

/// The in-progress activity: elapsed time, live heart rate, and End.
struct LiveActivityView: View {
    let log: ManualLogStore
    var finished: () -> Void = {}
    @State private var confirmsEnd = false

    var body: some View {
        if let entry = log.live {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                VStack(spacing: Theme.Layout.spacing) {
                    EntryIcon(kind: entry.kind, large: true)
                    Text(entry.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.text)
                }
                Text(entry.start, style: .timer)
                    .font(Theme.Typography.hero)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.text)
                    .accessibilityIdentifier("live.timer")
                HStack(spacing: Theme.Layout.spacing) {
                    stat("Now", log.heartRate)
                    stat("Average", entry.averageHeartRate)
                    stat("Max", entry.maxHeartRate)
                }
                VStack(spacing: Theme.Layout.spacing) {
                    Text(log.currentZone.map { "Zone \($0 + 1)" } ?? "Zone —")
                        .font(Theme.Typography.value)
                        .foregroundStyle(log.currentZone.map { Theme.Palette.zones[$0] } ?? Theme.Palette.muted)
                    ZoneSegments(current: log.currentZone)
                }
                .padding(Theme.Layout.cardPadding)
                .cardBackground()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("live.zone")
                Button("End \(entry.title)") { confirmsEnd = true }
                    .buttonStyle(ActionButtonStyle(fill: Theme.Palette.negative, foreground: Theme.Palette.text))
                    .accessibilityIdentifier("log.end")
            }
            .confirmationDialog("End \(entry.title)?", isPresented: $confirmsEnd, titleVisibility: .visible) {
                Button("Save") {
                    log.stop()
                    finished()
                }
                Button("Discard", role: .destructive) {
                    log.stop(keep: false)
                    finished()
                }
            }
        }
    }

    private func stat(_ title: String, _ bpm: Int?) -> some View {
        VStack(spacing: Theme.Layout.historyLabelSpacing) {
            HStack(spacing: Theme.Layout.historyLabelSpacing) {
                Image(systemName: "heart.fill")
                    .font(Theme.Icon.label)
                    .foregroundStyle(Theme.Palette.negative)
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Text(bpm.map(String.init) ?? "—")
                .font(Theme.Typography.value)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Layout.cardPadding)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

struct LiveActivityScreen: View {
    @Environment(\.dismiss) private var dismiss
    let log: ManualLogStore

    var body: some View {
        NavigationStack {
            ScrollView {
                LiveActivityView(log: log) { dismiss() }
                    .padding(Theme.Layout.screenInset)
            }
            .background(Theme.Palette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.Palette.text)
        .preferredColorScheme(.dark)
    }
}

/// One finished activity, sleep, or nap.
struct EntryDetail: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ManualEntry
    let log: ManualLogStore

    private struct Stat: Identifiable {
        let id: String
        let value: String
        var color = Theme.Palette.text
    }

    private var stats: [Stat] {
        var rows: [Stat] = []
        if let strain = entry.strain {
            rows.append(
                Stat(
                    id: "Strain", value: strain.formatted(.number.precision(.fractionLength(1))),
                    color: HealthMetric.strain.color))
        }
        if let score = entry.sleepScore {
            rows.append(Stat(id: "Sleep performance", value: "\(Int(score))%", color: HealthMetric.sleep.color))
        }
        rows.append(Stat(id: "Duration", value: EntryRow.duration(entry.duration(at: .now))))
        rows.append(Stat(id: "Time", value: EntryRow.timeRange(entry)))
        if let average = entry.averageHeartRate { rows.append(Stat(id: "Average heart rate", value: "\(average) bpm")) }
        if let peak = entry.maxHeartRate { rows.append(Stat(id: "Max heart rate", value: "\(peak) bpm")) }
        if let calories = entry.calories { rows.append(Stat(id: "Calories", value: "\(calories)")) }
        return rows
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                VStack(spacing: Theme.Layout.spacing) {
                    EntryIcon(kind: entry.kind, large: true)
                    Text(entry.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.text)
                    Text(entry.start, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.muted)
                }
                CardList(items: stats) { stat in
                    HStack {
                        Text(stat.id)
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.muted)
                        Spacer()
                        Text(stat.value)
                            .font(Theme.Typography.unit)
                            .foregroundStyle(stat.color)
                    }
                    .padding(.horizontal, Theme.Layout.cardPadding)
                    .frame(minHeight: Theme.Layout.rowHeight)
                }
                if let shares = entry.zoneShares(at: .now) {
                    ZoneBreakdown(shares: shares, duration: entry.duration(at: .now))
                }
                if !entry.isImported {
                    Button("Delete", role: .destructive) {
                        log.delete(entry.id)
                        dismiss()
                    }
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.negative)
                }
            }
            .padding(Theme.Layout.screenInset)
        }
        .background(Theme.Palette.canvas)
        .navigationBarTitleDisplayMode(.inline)
    }
}
