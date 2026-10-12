import SwiftUI

/// What a dashboard tap opens.
enum DashboardSheet: Identifiable, Hashable {
    case history(HealthMetric?)
    case activity
    case sleep
    case live

    var id: Self { self }

    static func forCard(_ metric: HealthMetric) -> DashboardSheet {
        switch metric {
        case .strain: .activity
        case .sleep, .duration: .sleep
        default: .history(metric)
        }
    }
}

struct DashboardSheetContent: View {
    let sheet: DashboardSheet
    let snapshot: DashboardHistorySnapshot
    let log: ManualLogStore

    var body: some View {
        switch sheet {
        case .history(let metric): HistoryBrowser(snapshot: snapshot, log: log, initialMetric: metric)
        case .activity: ManualLogSheet(category: .activity, log: log)
        case .sleep: ManualLogSheet(category: .sleep, log: log)
        case .live: LiveActivityScreen(log: log)
        }
    }
}

/// WHOOP-style picker: choose an activity to start or add, or review sleep.
struct ManualLogSheet: View {
    enum Category { case activity, sleep }

    @Environment(\.dismiss) private var dismiss
    let category: Category
    let log: ManualLogStore
    @State private var query = ""

    private var todayEntries: [ManualEntry] {
        let today = DayKey(date: .now, timeZone: .current).rawValue
        return log.entries(on: today).filter { $0.kind.isSleep == (category == .sleep) }
    }

    private var choiceGroups: [[LogKind]] {
        switch category {
        case .sleep:
            return [[.sleep, .nap]]
        case .activity where !query.isEmpty:
            return [Sport.matching(query).map(LogKind.activity)]
        case .activity:
            return [Sport.pinned.map(LogKind.activity), Sport.others.map(LogKind.activity)]
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                    if category == .activity, let live = log.live {
                        NavigationLink {
                            ScrollView {
                                LiveActivityView(log: log) { dismiss() }
                                    .padding(Theme.Layout.screenInset)
                            }
                            .background(Theme.Palette.canvas)
                        } label: {
                            LiveEntryCard(entry: live, heartRate: log.heartRate)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("log.live")
                    }
                    if !todayEntries.isEmpty {
                        CardList(items: todayEntries) { entry in
                            NavigationLink(value: entry) { EntryRow(entry: entry) }
                                .buttonStyle(.plain)
                        }
                    }
                    ForEach(Array(choiceGroups.enumerated()), id: \.offset) { _, kinds in
                        CardList(items: kinds.map(Choice.init)) { choice in
                            NavigationLink(value: choice.kind) { ChoiceRow(kind: choice.kind) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("log.choice.\(choice.id)")
                        }
                    }
                }
                .padding(Theme.Layout.screenInset)
            }
            .background(Theme.Palette.canvas)
            .modifier(ActivitySearch(enabled: category == .activity, query: $query))
            .navigationTitle(category == .activity ? "Activity" : "Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: LogKind.self) { kind in
                LogEntryScreen(kind: kind, log: log) { dismiss() }
            }
            .navigationDestination(for: ManualEntry.self) { entry in
                EntryDetail(entry: entry, log: log)
            }
        }
        .tint(Theme.Palette.text)
        .preferredColorScheme(.dark)
    }

    private struct Choice: Identifiable {
        let kind: LogKind
        var id: String {
            switch kind {
            case .activity(let sport): sport.rawValue
            case .sleep: "sleep"
            case .nap: "nap"
            }
        }
    }
}

private struct ActivitySearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        } else {
            content
        }
    }
}
