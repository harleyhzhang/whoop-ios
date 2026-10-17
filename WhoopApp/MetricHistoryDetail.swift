import Charts
import SwiftUI

struct MetricHistoryDetail: View {
    let history: RecordedHistory
    let metric: HealthMetric
    @Binding var selectedKey: String
    @State private var range = 30
    @State private var chartDate: Date?
    @State private var anchor: String

    init(history: RecordedHistory, metric: HealthMetric, selectedKey: Binding<String>) {
        self.history = history
        self.metric = metric
        _selectedKey = selectedKey
        _anchor = State(initialValue: selectedKey.wrappedValue)
    }

    private var days: [HealthDay] { history.window(endingAt: anchor, count: range) }
    private var selected: HealthDay? { history.day(selectedKey) }
    private var hasValues: Bool { days.contains { $0.value(for: metric) != nil } }
    private var chartDomain: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: days.first?.date ?? .now)
        let end = Calendar.current.startOfDay(for: days.last?.date ?? start)
        return start...(Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                if let selected {
                    VStack(alignment: .leading, spacing: Theme.Layout.historyLabelSpacing) {
                        Text(selected.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.muted)
                            .accessibilityIdentifier("history.detail.date")
                        MetricValue(metric: metric, value: selected.value(for: metric))
                            .accessibilityIdentifier("history.detail.value")
                    }
                }
                Picker("Range", selection: $range) {
                    ForEach([7, 30, 90], id: \.self) { Text("\($0)D").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("history.range")
                if hasValues { chart }
                CardList(items: days.reversed()) { day in
                    Button {
                        selectedKey = day.day
                    } label: {
                        row(day)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history.row.\(day.day)")
                }
            }
            .padding(Theme.Layout.screenInset)
        }
        .background(Theme.Palette.canvas)
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: chartDate) { _, date in
            guard let date else { return }
            let key = DayKey(date: date, timeZone: .current).rawValue
            if days.contains(where: { $0.day == key }) { selectedKey = key }
        }
        .onChange(of: range) { _, _ in
            if !days.contains(where: { $0.day == selectedKey }) { selectedKey = anchor }
        }
    }

    private func row(_ day: HealthDay) -> some View {
        let value = day.value(for: metric)
        let isSelected = day.day == selectedKey
        return HStack {
            Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(Theme.Typography.row)
                .foregroundStyle(isSelected ? Theme.Palette.text : Theme.Palette.muted)
            Spacer()
            Text(metric.formatted(value))
                .font(Theme.Typography.unit)
                .foregroundStyle(value == nil ? Theme.Palette.mutedDark : metric.color(for: value))
        }
        .padding(.horizontal, Theme.Layout.cardPadding)
        .frame(minHeight: Theme.Layout.historyTapHeight)
        .background(isSelected ? Theme.Palette.surfaceRaised : .clear)
        .contentShape(Rectangle())
    }

    private var chart: some View {
        Chart {
            ForEach(days) { day in
                if let value = day.value(for: metric) {
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value(metric.title, value))
                        .foregroundStyle(
                            metric.color(for: value).opacity(day.day == selectedKey ? 1 : 0.55))
                }
            }
        }
        .chartXScale(domain: chartDomain)
        .chartXSelection(value: $chartDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisValueLabel().font(Theme.Typography.caption).foregroundStyle(Theme.Palette.chartDate)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(Theme.Palette.guide)
                AxisValueLabel().font(Theme.Typography.caption).foregroundStyle(Theme.Palette.chartDate)
            }
        }
        .frame(height: Theme.Layout.historyChartHeight)
        .padding(Theme.Layout.cardPadding)
        .cardBackground()
        .accessibilityLabel("\(metric.title) by day")
    }
}
