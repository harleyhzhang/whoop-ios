import SwiftUI

struct HistoryBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKey: String
    @State private var path: NavigationPath
    @State private var showsCalendar = false
    let history: RecordedHistory
    let log: ManualLogStore
    /// Set when opened from a dashboard card; that metric is the root, so back returns to the dashboard.
    private let rootMetric: HealthMetric?

    private static let metrics: [HealthMetric] = [.recovery, .sleep, .strain, .duration, .hrv, .rhr, .steps]

    init(snapshot: DashboardHistorySnapshot, log: ManualLogStore, initialMetric: HealthMetric? = nil) {
        let data = RecordedHistory(snapshot: snapshot)
        history = data
        self.log = log
        _selectedKey = State(initialValue: data.days.last?.day ?? "")
        _path = State(initialValue: NavigationPath())
        rootMetric = initialMetric
    }

    private var selected: HealthDay? { history.day(selectedKey) }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: HealthMetric.self) { metric in
                    MetricHistoryDetail(history: history, metric: metric, selectedKey: $selectedKey)
                }
                .navigationDestination(for: ManualEntry.self) { entry in
                    EntryDetail(entry: entry, log: log)
                }
        }
        .tint(Theme.Palette.text)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var root: some View {
        if let rootMetric {
            MetricHistoryDetail(history: history, metric: rootMetric, selectedKey: $selectedKey)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") { dismiss() }
                            .accessibilityIdentifier("history.back")
                    }
                }
        } else {
            dayList
        }
    }

    private var dayList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                if let selected {
                    dayNavigation(selected)
                    CardList(items: Self.metrics) { metric in
                        NavigationLink(value: metric) { metricRow(metric, day: selected) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("history.metric.\(metric.rawValue)")
                    }
                    let entries = log.entries(on: selectedKey)
                    if !entries.isEmpty {
                        CardList(items: entries) { entry in
                            NavigationLink(value: entry) { EntryRow(entry: entry) }
                                .buttonStyle(.plain)
                        }
                    }
                } else {
                    ContentUnavailableView("No history yet", systemImage: "calendar")
                }
            }
            .padding(Theme.Layout.screenInset)
        }
        .background(Theme.Palette.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showsCalendar) { calendar }
    }

    private func dayNavigation(_ day: HealthDay) -> some View {
        HStack(spacing: Theme.Layout.spacing) {
            dayButton(offset: -1, symbol: "chevron.left", label: "Previous day")
            Button {
                showsCalendar = true
            } label: {
                Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: Theme.Layout.historyTapHeight)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose a day")
            .accessibilityIdentifier("history.date")
            dayButton(offset: 1, symbol: "chevron.right", label: "Next day")
        }
    }

    private func dayButton(offset: Int, symbol: String, label: String) -> some View {
        Button {
            if let next = history.neighbor(of: selectedKey, offset: offset) { selectedKey = next }
        } label: {
            Image(systemName: symbol)
                .font(Theme.Icon.row)
                .frame(width: Theme.Layout.historyTapHeight, height: Theme.Layout.historyTapHeight)
                .background(Theme.Palette.surface, in: Circle())
        }
        .disabled(history.neighbor(of: selectedKey, offset: offset) == nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier(offset < 0 ? "history.previous" : "history.next")
    }

    private func metricRow(_ metric: HealthMetric, day: HealthDay) -> some View {
        let value = day.value(for: metric)
        return HStack(spacing: Theme.Layout.spacing) {
            Image(systemName: metric.symbol)
                .font(Theme.Icon.row)
                .foregroundStyle(metric.color(for: value))
                .frame(width: Theme.Layout.rowBadge, height: Theme.Layout.rowBadge)
                .background(metric.color(for: value).opacity(0.16), in: Circle())
            Text(metric.title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.text)
            Spacer()
            Text(metric.formatted(value))
                .font(Theme.Typography.unit)
                .foregroundStyle(value == nil ? Theme.Palette.muted : Theme.Palette.text)
            Image(systemName: "chevron.right")
                .font(Theme.Icon.label)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, Theme.Layout.cardPadding)
        .frame(minHeight: Theme.Layout.rowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var calendar: some View {
        if let first = history.days.first, let last = history.days.last {
            DatePicker(
                "Day",
                selection: Binding(
                    get: { selected?.date ?? last.date },
                    set: {
                        selectedKey = DayKey(date: $0, timeZone: .current).rawValue
                        showsCalendar = false
                    }),
                in: first.date...last.date, displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(Theme.Layout.screenInset)
            .presentationDetents([.medium])
            .preferredColorScheme(.dark)
            .tint(Theme.Palette.text)
        }
    }
}
