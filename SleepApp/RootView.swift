import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chartState = DashboardChartState()
    @State private var history = HealthHistoryModel()
    var whoopCollector: WhoopHandshakeProbe

    private var publishedDay: PublishedDashboardDay {
        PublishedDashboardDay(
            healthRecords: history.snapshot.healthRecords,
            stepRecords: history.snapshot.stepRecords,
            recoveryRecords: history.snapshot.recoveryRecords,
            metricsArePending: sleepMetricsArePending
        )
    }

    private var sleepMetricsArePending: Bool {
        WhoopLaunchOverrides.isSleeping || whoopCollector.isSleeping
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
        .task(id: chartState.detailGeneration) {
            await chartState.runDetailTransition(
                generation: chartState.detailGeneration,
                reduceMotion: reduceMotion
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                WhoopStore.shared.flushStorageTelemetry()
                if phase == .background {
                    whoopCollector.prepareForBackground()
                }
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
    }

    private func dashboard(currentDate: Date) -> some View {
        let referenceDate = sleepMetricsArePending ? currentDate : (publishedDay.date ?? currentDate)
        return ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DashboardHeader(
                        referenceDate: referenceDate,
                        errorMessage: history.errorMessage,
                        batteryLevel: batteryLevel,
                        isCharging: isCharging,
                        isConnected: isConnected
                    )
                    SummaryGrid(day: publishedDay)

                    ForEach(MetricKind.trendOrder, id: \.self) { metric in
                        MetricTrendCard(
                            metric: metric,
                            series: metricSeries(for: metric),
                            publishedDate: publishedDay.date,
                            currentValue: metricValue(for: metric),
                            chartState: chartState
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

    private func metricSeries(for metric: MetricKind) -> MetricSeries {
        history.metricSeries(for: metric)
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
