import SwiftUI

struct ActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var fill = Theme.Palette.text
    var foreground = Theme.Palette.inverseText

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.action)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: Theme.Layout.actionHeight)
            .background(
                fill.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.3),
                in: Capsule())
    }
}

struct EntryIcon: View {
    let kind: LogKind
    var large = false

    var body: some View {
        let size = large ? Theme.Layout.heroBadge : Theme.Layout.rowBadge
        Image(systemName: kind.symbol)
            .font(large ? Theme.Icon.hero : Theme.Icon.row)
            .foregroundStyle(kind.color)
            .frame(width: size, height: size)
            .background(kind.color.opacity(0.16), in: Circle())
    }
}

struct RowDivider: View {
    var inset = Theme.Layout.rowDividerInset

    var body: some View {
        Rectangle()
            .fill(Theme.Palette.guide)
            .frame(height: Theme.Layout.hairline)
            .padding(.leading, inset)
    }
}

/// Rows grouped in one card, separated by hairlines.
struct CardList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider() }
                row(item)
            }
        }
        .cardBackground()
    }
}

struct ChoiceRow: View {
    let kind: LogKind

    var body: some View {
        HStack(spacing: Theme.Layout.spacing) {
            EntryIcon(kind: kind)
            Text(kind.title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(Theme.Icon.label)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, Theme.Layout.cardPadding)
        .frame(minHeight: Theme.Layout.rowHeight)
        .contentShape(Rectangle())
    }
}

struct EntryRow: View {
    let entry: ManualEntry

    var body: some View {
        HStack(spacing: Theme.Layout.spacing) {
            EntryIcon(kind: entry.kind)
            VStack(alignment: .leading, spacing: Theme.Layout.historyLabelSpacing) {
                Text(entry.title)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.text)
                Text(Self.timeRange(entry))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer()
            if let strain = entry.strain {
                Text(strain, format: .number.precision(.fractionLength(1)))
                    .font(Theme.Typography.unit)
                    .foregroundStyle(HealthMetric.strain.color)
            } else {
                Text(Self.duration(entry.duration(at: .now)))
                    .font(Theme.Typography.unit)
                    .foregroundStyle(Theme.Palette.text)
            }
        }
        .padding(.horizontal, Theme.Layout.cardPadding)
        .frame(minHeight: Theme.Layout.rowHeight)
        .contentShape(Rectangle())
    }

    static func timeRange(_ entry: ManualEntry) -> String {
        (entry.start..<(entry.end ?? entry.start)).formatted(.interval.hour().minute())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

/// Compact live activity shown on the dashboard and the activity sheet.
struct LiveEntryCard: View {
    let entry: ManualEntry
    let heartRate: Int?

    var body: some View {
        HStack(spacing: Theme.Layout.spacing) {
            EntryIcon(kind: entry.kind)
            VStack(alignment: .leading, spacing: Theme.Layout.historyLabelSpacing) {
                Text(entry.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.muted)
                Text(entry.start, style: .timer)
                    .font(Theme.Typography.value)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.text)
            }
            Spacer()
            HStack(spacing: Theme.Layout.historyLabelSpacing) {
                Image(systemName: "heart.fill")
                    .font(Theme.Icon.label)
                    .foregroundStyle(Theme.Palette.negative)
                Text(heartRate.map(String.init) ?? "—")
                    .font(Theme.Typography.unit)
                    .foregroundStyle(Theme.Palette.text)
            }
            Image(systemName: "chevron.right")
                .font(Theme.Icon.label)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(Theme.Layout.cardPadding)
        .cardBackground()
        .contentShape(Rectangle())
    }
}

/// Start an activity now or add one that already happened. Sleep is recorded
/// automatically, so sleep and naps can only be added after the fact.
struct LogEntryScreen: View {
    private enum Mode: String, CaseIterable {
        case start = "Start"
        case add = "Add"
    }

    let kind: LogKind
    let log: ManualLogStore
    let finish: () -> Void
    @State private var mode: Mode
    @State private var start: Date
    @State private var end: Date

    init(kind: LogKind, log: ManualLogStore, finish: @escaping () -> Void) {
        self.kind = kind
        self.log = log
        self.finish = finish
        let now = Date.now
        _mode = State(initialValue: kind.isSleep ? .add : .start)
        _end = State(initialValue: now)
        _start = State(initialValue: now.addingTimeInterval(-kind.typicalDuration))
    }

    private var isValid: Bool { ManualLogRules.isValid(start: start, end: end, now: .now) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                if mode == .start, log.live != nil {
                    LiveActivityView(log: log, finished: finish)
                } else {
                    VStack(spacing: Theme.Layout.spacing) {
                        EntryIcon(kind: kind, large: true)
                        Text(kind.title)
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Palette.text)
                    }
                    if !kind.isSleep {
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("log.mode")
                    }
                    switch mode {
                    case .start:
                        Button("Start \(kind.title)") { log.start(kind) }
                            .buttonStyle(ActionButtonStyle())
                            .accessibilityIdentifier("log.start")
                    case .add: addPanel
                    }
                }
            }
            .padding(Theme.Layout.screenInset)
        }
        .background(Theme.Palette.canvas)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var addPanel: some View {
        VStack(spacing: Theme.Layout.spacing) {
            VStack(spacing: 0) {
                DatePicker("Start", selection: $start, in: ...end)
                    .frame(minHeight: Theme.Layout.rowHeight)
                RowDivider(inset: 0)
                DatePicker("End", selection: $end, in: start...Date.now)
                    .frame(minHeight: Theme.Layout.rowHeight)
                RowDivider(inset: 0)
                HStack {
                    Text("Duration")
                    Spacer()
                    Text(EntryRow.duration(end.timeIntervalSince(start)))
                        .font(Theme.Typography.unit)
                        .foregroundStyle(isValid ? Theme.Palette.text : Theme.Palette.negative)
                }
                .frame(minHeight: Theme.Layout.rowHeight)
            }
            .font(Theme.Typography.row)
            .foregroundStyle(Theme.Palette.text)
            .padding(.horizontal, Theme.Layout.cardPadding)
            .cardBackground()
            Button("Save") {
                if log.add(kind, start: start, end: end) { finish() }
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(!isValid)
            .accessibilityIdentifier("log.save")
        }
    }
}
