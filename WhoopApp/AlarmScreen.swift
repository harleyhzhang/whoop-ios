import SwiftUI

/// Daily strap wake alarm: pick a time, toggle, test buzz.
struct AlarmScreen: View {
    let collector: WhoopCollector
    @State private var time: Date

    init(collector: WhoopCollector) {
        self.collector = collector
        let alarm = collector.alarm
        _time = State(
            initialValue: Calendar.current.date(
                bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now)
    }

    private var isOn: Binding<Bool> {
        Binding(get: { collector.alarm.isEnabled }, set: { save(enabled: $0) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .opacity(collector.alarm.isEnabled ? 1 : Theme.Layout.staleOpacity)
                    .accessibilityIdentifier("alarm.time")
                Toggle(isOn: isOn) {
                    HStack(spacing: Theme.Layout.spacing) {
                        Image(systemName: "alarm")
                            .font(Theme.Icon.row)
                            .foregroundStyle(Theme.Palette.sleep)
                        Text("Alarm")
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.text)
                    }
                }
                .tint(Theme.Palette.sleep)
                .padding(.horizontal, Theme.Layout.cardPadding)
                .frame(minHeight: Theme.Layout.rowHeight)
                .cardBackground()
                .accessibilityIdentifier("alarm.toggle")
                Button("Test") { collector.testAlarm() }
                    .buttonStyle(
                        ActionButtonStyle(
                            fill: Theme.Palette.surfaceRaised, foreground: Theme.Palette.text)
                    )
                    .disabled(!collector.isConnected)
                    .accessibilityIdentifier("alarm.test")
            }
            .padding(Theme.Layout.screenInset)
        }
        .background(Theme.Palette.canvas)
        .navigationTitle("Alarm")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: time) { _, _ in save(enabled: collector.alarm.isEnabled) }
    }

    private func save(enabled: Bool) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        collector.updateAlarm(
            WhoopAlarm(isEnabled: enabled, hour: parts.hour ?? 7, minute: parts.minute ?? 0))
    }
}

/// Sleep-sheet entry row showing the armed wake time.
struct AlarmRow: View {
    let alarm: WhoopAlarm

    private var time: String {
        let date = Calendar.current.date(
            bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: Theme.Layout.spacing) {
            Image(systemName: "alarm")
                .font(Theme.Icon.row)
                .foregroundStyle(Theme.Palette.sleep)
                .frame(width: Theme.Layout.rowBadge)
            Text("Alarm")
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.text)
            Spacer()
            Text(alarm.isEnabled ? time : "Off")
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.muted)
            Image(systemName: "chevron.right")
                .font(Theme.Icon.label)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, Theme.Layout.cardPadding)
        .frame(minHeight: Theme.Layout.rowHeight)
        .contentShape(Rectangle())
        .cardBackground()
    }
}
