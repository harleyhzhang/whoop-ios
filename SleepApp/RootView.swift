import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("selectedHealthRange") private var selectedRange: HealthRange = .month
    @State private var chartState = DashboardChartState()
    @State private var showsConnectionDetails = false
    @State private var history = HealthHistoryModel()
    var whoopCollector: WhoopHandshakeProbe

    private var publishedDay: PublishedDashboardDay {
        PublishedDashboardDay(
            healthRecords: history.snapshot.healthRecords,
            stepRecords: history.snapshot.stepRecords,
            recoveryRecords: history.snapshot.recoveryRecords
        )
    }

    private var availableRanges: [HealthRange] {
        guard let first = history.snapshot.healthRecords.first?.date,
            let last = history.snapshot.healthRecords.last?.date
        else { return HealthRange.allCases }
        let days =
            (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        return HealthRange.allCases.filter { range in
            guard let required = range.dayCount else { return true }
            return days >= required
        }
    }

    private var batteryLevel: Int? {
        WhoopLaunchOverrides.batteryLevel ?? whoopCollector.batteryLevel
    }

    private var isCharging: Bool {
        WhoopLaunchOverrides.isCharging || whoopCollector.isCharging
    }

    private var isConnected: Bool {
        WhoopLaunchOverrides.isConnected || whoopCollector.isConnected
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            dashboard(currentDate: context.date)
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedRange) { oldRange, _ in
            AppHaptics.selection()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                chartState.beginRangeTransition(from: oldRange, reduceMotion: reduceMotion)
            }
        }
        .task(id: chartState.morphGeneration) {
            guard !reduceMotion, chartState.morphProgress == 0 else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.52, extraBounce: 0)) {
                chartState.morphProgress = 1
            }
            try? await Task.sleep(for: .seconds(0.52))
            guard !Task.isCancelled else { return }
            chartState.morphFromRange = nil
        }
        .onChange(of: availableRanges) { _, ranges in
            guard !ranges.isEmpty, !ranges.contains(selectedRange) else { return }
            selectedRange = ranges.last ?? .all
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                WhoopStore.shared.flushStorageTelemetry()
                return
            }
            history.reload()
            whoopCollector.refreshHistoricalData()
            WhoopStore.shared.writeSleepDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .whoopDailyHealthUpdated)) {
            notification in
            guard let update = notification.object as? WhoopHealthHistoryUpdate else {
                history.reload()
                return
            }
            if case .dayPublished(let record) = update {
                withAnimation(.smooth(duration: 0.42)) {
                    history.merge(record)
                }
            }
            history.reload()
        }
        .sheet(isPresented: $showsConnectionDetails) {
            HandshakeView(probe: whoopCollector)
        }
    }

    private func dashboard(currentDate: Date) -> some View {
        let referenceDate = publishedDay.date ?? currentDate
        return ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DashboardHeader(
                        referenceDate: referenceDate,
                        errorMessage: history.errorMessage,
                        batteryLevel: batteryLevel,
                        isCharging: isCharging,
                        isConnected: isConnected,
                        showConnectionDetails: { showsConnectionDetails = true }
                    )
                    SummaryGrid(day: publishedDay)
                    RangePicker(selection: $selectedRange, availableRanges: availableRanges)

                    ForEach(MetricKind.trendOrder, id: \.self) { metric in
                        MetricTrendCard(
                            metric: metric,
                            series: metricSeries(for: metric, currentDate: currentDate),
                            selectedRange: selectedRange,
                            publishedDate: publishedDay.date,
                            currentValue: metricValue(for: metric),
                            chartState: chartState,
                            seriesForRange: { range in
                                metricSeries(for: metric, range: range, currentDate: currentDate)
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func metricSeries(
        for metric: MetricKind,
        range: HealthRange? = nil,
        currentDate: Date
    ) -> MetricSeries {
        history.metricSeries(
            for: metric,
            range: range ?? selectedRange,
            referenceDate: (metric == .steps || metric == .recovery)
                ? currentDate : (publishedDay.date ?? currentDate)
        )
    }

    private func metricValue(for metric: MetricKind) -> Double? {
        switch metric {
        case .steps: publishedDay.steps.map { Double($0.stepCount) }
        case .recovery: publishedDay.recovery?.score
        case .sleep: publishedDay.health?.sleepScore
        case .duration: publishedDay.health?.sleepDurationMinutes.map { $0 / 60 }
        case .hrv: publishedDay.health?.hrvRMSSDMilliseconds
        case .rhr: publishedDay.health?.restingHeartRateBPM
        }
    }
}

#Preview {
    RootView(whoopCollector: WhoopHandshakeProbe())
}
