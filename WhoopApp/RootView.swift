import SwiftUI

enum DashboardCurrentDayPolicy {
    static func displayedDay(
        snapshot: DashboardHistorySnapshot,
        metricsArePending: Bool
    ) -> PublishedDashboardDay {
        PublishedDashboardDay(
            healthRecords: metricsArePending ? [] : snapshot.healthRecords,
            stepRecords: metricsArePending ? [] : snapshot.stepRecords,
            recoveryRecords: metricsArePending ? [] : snapshot.recoveryRecords
        )
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var history = HealthHistoryModel()
    var whoopCollector: WhoopCollector
    var powerPackMonitor: WhoopPowerPackMonitor
    let replicaCoordinator: WhoopReplicaCoordinator

    private var publishedDay: PublishedDashboardDay {
        if let previewDay = WhoopLaunchOverrides.previewDay, !sleepMetricsArePending {
            return PublishedDashboardDay(
                healthRecords: history.snapshot.healthRecords.filter { $0.dateKey == previewDay },
                stepRecords: history.snapshot.stepRecords.filter { $0.dateKey == previewDay },
                recoveryRecords: history.snapshot.recoveryRecords.filter { $0.dateKey == previewDay }
            )
        }
        return DashboardCurrentDayPolicy.displayedDay(
            snapshot: history.snapshot,
            metricsArePending: sleepMetricsArePending
        )
    }

    private var sleepMetricsArePending: Bool {
        #if DEBUG
            if ProcessInfo.processInfo.environment["WHOOP_MOCK_SLEEPING"] == "1" {
                return true
            }
        #endif
        return whoopCollector.isSleeping
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

    private var powerPackBatteryLevel: Int? {
        WhoopLaunchOverrides.powerPackBatteryLevel ?? powerPackMonitor.batteryLevel
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            dashboard(currentDate: context.date)
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                history.reload()
            }
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
            powerPackMonitor.refresh()
            WhoopStore.shared.writeSleepDiagnostics()
            replicaCoordinator.requestSync(reason: .foreground)
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
        let referenceDate = publishedDay.date ?? currentDate
        let projection = DashboardCardProjection(
            snapshot: history.snapshot, published: publishedDay, referenceDate: referenceDate
        )
        return ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.spacing) {
                    DashboardHeader(
                        referenceDate: referenceDate,
                        errorMessage: history.errorMessage,
                        batteryLevel: batteryLevel,
                        isCharging: isCharging,
                        isConnected: isConnected,
                        powerPackBatteryLevel: powerPackBatteryLevel
                    )
                    VStack(spacing: Theme.Layout.spacing) {
                        SummaryRings(selected: projection.selected)

                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: Theme.Layout.spacing),
                                count: typeSize.isAccessibilitySize ? 1 : 2), spacing: Theme.Layout.spacing
                        ) {
                            ForEach([HealthMetric.steps, .duration, .rhr, .sleep, .recovery, .strain]) { metric in
                                MetricCard(metric: metric, selected: projection.selected, days: projection.days)
                                    .accessibilityIdentifier("card.\(metric.rawValue)")
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Layout.screenInset)
                .padding(.top, Theme.Layout.screenTopInset)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

}

#Preview {
    let coordinator = WhoopReplicaCoordinator(configuration: nil, sourceURL: nil)
    RootView(
        whoopCollector: WhoopCollector(replicaScheduler: coordinator),
        powerPackMonitor: WhoopPowerPackMonitor(),
        replicaCoordinator: coordinator
    )
}
