import Charts
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("selectedHealthRange") private var selectedRange: HealthRange = .month
    @State private var selectedDate: Date?
    @State private var activeMetric: MetricKind?
    @State private var currentDate = Date()
    @State private var debugMockPendingSleepDismissed = false
    @ObservedObject var whoopCollector: WhoopHandshakeProbe
    @StateObject private var history = HealthHistoryModel()

    private var referenceDate: Date {
        sleepMetricsArePending ? currentDate : (currentSleepRecord?.date ?? currentDate)
    }

    /// A range is offered only when the history is long enough to mean anything
    /// by it. All history is always offered; it is the one range that describes
    /// whatever exists rather than a fixed window.
    private var availableRanges: [HealthRange] {
        guard let first = history.records.first?.date,
              let last = history.records.last?.date else {
            return HealthRange.allCases
        }
        let days = (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        return HealthRange.allCases.filter { range in
            guard let required = range.dayCount else { return true }
            return days >= required
        }
    }

    private var todayRecord: DailyHealthRecord? {
        history.records.last { Calendar.current.isDate($0.date, inSameDayAs: currentDate) }
    }

    private var currentSleepRecord: DailyHealthRecord? {
        guard !sleepMetricsArePending else { return nil }
        return todayRecord ?? history.latestRecord
    }

    private var sleepMetricsArePending: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHOOP_MOCK_SLEEPING"] == "1" {
            return true
        }
        #endif
        return whoopCollector.isSleeping
            || displayedPendingSleep != nil
            || whoopCollector.isProcessingSleep
    }

    private var whoopBatteryLevel: Int? {
        #if DEBUG
        if let mockValue = ProcessInfo.processInfo.environment["WHOOP_MOCK_BATTERY"],
           let level = Int(mockValue) {
            return min(max(level, 0), 100)
        }
        #endif

        return whoopCollector.batteryLevel
    }

    private var whoopCharging: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHOOP_MOCK_CHARGING"] == "1" {
            return true
        }
        #endif

        return whoopCollector.isCharging
    }

    private var whoopConnected: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHOOP_MOCK_CONNECTED"] == "1" {
            return true
        }
        #endif

        return whoopCollector.isConnected
    }

    private var displayedPendingSleep: WhoopPendingSleep? {
        #if DEBUG
        if !debugMockPendingSleepDismissed,
           let rawMinutes = ProcessInfo.processInfo.environment["WHOOP_MOCK_PENDING_SLEEP_MINUTES"],
           let minutes = Double(rawMinutes) {
            return WhoopPendingSleep(
                sleepID: "mock-pending-sleep",
                startedAt: currentDate.addingTimeInterval(-minutes * 60),
                endedAt: currentDate,
                durationMinutes: minutes
            )
        }
        #endif

        return whoopCollector.pendingSleep
    }

    /// Once the strap has identified sleep, keep the prompt in the layout
    /// through waking and finalization. Processing intentionally clears the
    /// candidate while the fresh history offload settles.
    private var showsSleepDetectedCard: Bool {
        whoopCollector.isSleeping
            || displayedPendingSleep != nil
            || whoopCollector.isProcessingSleep
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sleepDetectedSection
                        .animation(
                            .smooth(duration: 0.45, extraBounce: 0.18),
                            value: showsSleepDetectedCard
                        )
                    dateHeader
                    summaryGrid
                    rangePicker

                    metricCard(
                        metric: .sleep,
                        title: "Sleep",
                        symbol: "moon.stars.fill",
                        unit: "",
                        series: metricSeries(for: .sleep),
                        color: sleepAccent,
                        formatValue: { "\(Int($0.rounded()))%" }
                    )

                    metricCard(
                        metric: .duration,
                        title: "Sleep duration",
                        symbol: "bed.double.fill",
                        unit: "",
                        series: metricSeries(for: .duration),
                        color: .cyan,
                        formatValue: formatDuration
                    )

                    metricCard(
                        metric: .steps,
                        title: "Steps",
                        symbol: "figure.walk",
                        unit: "",
                        series: metricSeries(for: .steps),
                        color: .green,
                        formatValue: formatSteps
                    )

                    metricCard(
                        metric: .recovery,
                        title: "Recovery",
                        symbol: "gauge.with.dots.needle.50percent",
                        unit: "",
                        series: metricSeries(for: .recovery),
                        color: .mint,
                        formatValue: { "\(Int($0.rounded()))%" }
                    )

                    metricCard(
                        metric: .rhr,
                        title: "RHR",
                        symbol: "heart.fill",
                        unit: "BPM",
                        series: metricSeries(for: .rhr),
                        color: .red,
                        formatValue: { String(Int($0.rounded())) }
                    )

                    metricCard(
                        metric: .hrv,
                        title: "HRV",
                        symbol: "waveform.path.ecg",
                        unit: "MS",
                        series: metricSeries(for: .hrv),
                        color: .pink,
                        formatValue: { String(Int($0.rounded())) }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedRange) { _, _ in
            AppHaptics.selection()
            selectedDate = nil
            activeMetric = nil
        }
        .onChange(of: availableRanges) { _, ranges in
            // History can shorten as well as grow. Fall back to the longest
            // range that still exists rather than leaving a selection that no
            // longer has a button.
            guard !ranges.isEmpty, !ranges.contains(selectedRange) else { return }
            selectedRange = ranges.last ?? .all
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            currentDate = .now
            history.reload()
            whoopCollector.refreshHistoricalData()
            WhoopStore.shared.writeSleepDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .whoopDailyHealthUpdated)) { notification in
            currentDate = .now
            // Show the finished night on the next frame; the full reload behind it
            // only has to agree, not to be waited for.
            if let record = notification.object as? DailyHealthRecord {
                withAnimation(.smooth(duration: 0.42)) {
                    history.merge(record)
                }
            }
            history.reload()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                currentDate = .now
            }
        }
    }

    private var dateHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(referenceDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                if whoopCollector.isProcessingSleep {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Finishing sleep…")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if let errorMessage = history.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            HStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Image("WhoopBand")
                        .resizable()
                        .scaledToFit()
                        .brightness(0.07)
                        .contrast(1.03)
                        .frame(width: 33, height: 33)

                    Circle()
                        .fill(whoopConnected ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                        .overlay {
                            Circle()
                                .stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 1.5)
                        }
                        .offset(x: -1, y: -1)
                }

                WhoopBatteryPercentIcon(
                    level: whoopBatteryLevel,
                    isCharging: whoopCharging
                )
                    .opacity(whoopConnected ? 1 : 0.45)
            }
            .frame(minHeight: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "WHOOP \(whoopConnected ? "connected" : "disconnected"), battery \(whoopBatteryLevel.map { "\($0) percent" } ?? "unavailable")\(whoopCharging ? ", charging" : "")"
            )
        }
    }

    /// A compact status card above the entire dashboard. It exists only while
    /// sleep is detected or the detected night is waiting to be written. It
    /// stays put while a complete history offload is being processed.
    @ViewBuilder
    private var sleepDetectedSection: some View {
        if showsSleepDetectedCard {
            sleepDetectedCard
                .transition(
                    .modifier(
                        active: SleepDetectedCardHeightTransition(progress: 0),
                        identity: SleepDetectedCardHeightTransition(progress: 1)
                    )
                )
        }
    }

    private var sleepDetectedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(sleepAccent)
                .frame(width: 34, height: 34)
                .background(sleepAccent.opacity(0.14), in: Circle())

            Text("Sleep detected")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Button {
                // processPendingSleep clears the row synchronously on the main
                // actor, so wrapping the call is what puts that removal inside
                // the animated transaction.
                withAnimation(.smooth(duration: 0.45, extraBounce: 0.18)) {
                    processPendingSleepCard()
                }
            } label: {
                Text("Process")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(sleepAccent, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(whoopCollector.isProcessingSleep)
        }
        .padding(.horizontal, 14)
        .frame(height: SleepDetectedCardHeightTransition.expandedHeight)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep detected")
        .accessibilityHint(
            whoopCollector.isProcessingSleep
                ? "Finishing sleep"
                : (whoopCollector.sleepProcessFailure ?? "Process the complete sleep record")
        )
    }

    private func processPendingSleepCard() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHOOP_MOCK_PENDING_SLEEP_MINUTES"] != nil {
            debugMockPendingSleepDismissed = true
            return
        }
        #endif

        whoopCollector.processPendingSleep()
    }

    private var sleepAccent: Color { Color(red: 0.39, green: 0.69, blue: 1.0) }

    private var rangePicker: some View {
        HStack(spacing: 12) {
            Text("Trends")
                .font(.title3.weight(.semibold))

            Spacer(minLength: 8)

            rangeSelector
                .accessibilityValue(selectedRange.accessibilityName)
        }
        .padding(.top, 12)
    }

    private var rangeSelector: some View {
        Picker("Trend range", selection: $selectedRange) {
            ForEach(availableRanges) { range in
                Text(range.rawValue)
                    .tag(range)
                    .accessibilityLabel(range.accessibilityName)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var summaryGrid: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                activityMetric(
                    title: "Sleep",
                    symbol: "moon.stars.fill",
                    value: summarySleepScore,
                    iconTint: sleepAccent
                )
                activityMetric(
                    title: "Duration",
                    symbol: "bed.double.fill",
                    value: summarySleepDuration,
                    iconTint: .cyan
                )
            }

            HStack(alignment: .top, spacing: 12) {
                activityMetric(
                    title: "Steps",
                    symbol: "figure.walk",
                    value: summarySteps,
                    iconTint: .green
                )
                activityMetric(
                    title: "Recovery",
                    symbol: "gauge.with.dots.needle.50percent",
                    value: summaryRecovery,
                    iconTint: .mint
                )
                activityMetric(
                    title: "RHR",
                    symbol: "heart.fill",
                    value: summaryRHR,
                    unit: summaryRHR == "—" ? "" : "BPM",
                    iconTint: .red
                )
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Sleep \(summarySleepScore), duration \(summarySleepDuration), steps \(summarySteps), recovery \(summaryRecovery), resting heart rate \(summaryRHR) beats per minute"
        )
    }

    private func activityMetric(
        title: String,
        symbol: String,
        value: String,
        unit: String = "",
        iconTint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)

                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                AnimatedMetricValue(value: value)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summarySleepScore: String {
        currentSleepRecord?.sleepScore.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private var summarySleepDuration: String {
        currentSleepRecord?.sleepDurationMinutes.map { formatDuration($0 / 60) } ?? "—"
    }

    private var summarySteps: String {
        let record = history.stepRecords.last {
            Calendar.current.isDate($0.date, inSameDayAs: currentDate)
        } ?? history.stepRecords.last
        return record.map { formatSteps(Double($0.stepCount)) } ?? "—"
    }

    private var summaryRecovery: String {
        let record = history.recoveryRecords.last {
            Calendar.current.isDate($0.date, inSameDayAs: currentDate)
        } ?? history.recoveryRecords.last
        return record.map { "\(Int($0.score.rounded()))%" } ?? "—"
    }

    private var summaryRHR: String {
        currentSleepRecord?.restingHeartRateBPM.map { String(Int($0.rounded())) } ?? "—"
    }

    private func metricCard(
        metric: MetricKind,
        title: String,
        symbol: String,
        unit: String,
        series: MetricSeries,
        color: Color,
        formatValue: @escaping (Double) -> String
    ) -> some View {
        let cardSelection = activeMetric == metric ? selectedDate : nil
        let selectedMetricPoint: MetricPoint? = cardSelection.flatMap {
            self.selectedPoint(in: series.plotted, near: $0)
        }
        let usesLatestTimelinePoint = metric == .steps || metric == .recovery
        let currentTimelinePoint = usesLatestTimelinePoint
            ? series.daily.last { Calendar.current.isDate($0.date, inSameDayAs: currentDate) } ?? series.daily.last
            : nil
        let currentValue = usesLatestTimelinePoint
            ? currentTimelinePoint?.value
            : metricValue(for: metric, in: currentSleepRecord)
        let displayedValue = cardSelection == nil ? currentValue : selectedMetricPoint?.value
        let value = displayedValue.map(formatValue) ?? "—"
        let valueDateLabel = cardSelection == nil
            ? (usesLatestTimelinePoint
                ? currentTimelinePoint.map { selectionLabel(for: $0.date) } ?? "No real data"
                : "Today")
            : selectedMetricPoint.map { selectionLabel(for: $0.date) } ?? "No real data"

        return VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(valueDateLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        AnimatedMetricValue(
                            value: value,
                            fontSize: 24,
                            animateChanges: cardSelection == nil
                        )

                        if value != "—", !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .frame(width: 88, alignment: .leading)
                .padding(.bottom, 22)

                metricChart(metric: metric, series: series, color: color, title: title)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func metricChart(metric: MetricKind, series: MetricSeries, color: Color, title: String) -> some View {
        if series.daily.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                Text("No real data in this range")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 148)
            .accessibilityLabel("\(title), no real data in \(selectedRange.accessibilityName)")
        } else {
            populatedMetricChart(metric: metric, series: series, color: color, title: title)
        }
    }

    private func populatedMetricChart(metric: MetricKind, series: MetricSeries, color: Color, title: String) -> some View {
        let plottedPoints = series.plotted
        let chartPoints = plottedPoints.enumerated().map { index, point in
            PositionedMetricPoint(
                id: index,
                position: normalizedPosition(of: point, in: plottedPoints),
                value: point.value
            )
        }
        let domain = chartDomain(for: series.daily, metric: metric)
        let chartSelection = activeMetric == metric ? selectedDate : nil
        let showsAverageLevels = selectedRange.usesMonthlyAxis && chartSelection == nil
        let highlightedPoint = selectedPoint(in: plottedPoints, near: chartSelection) ?? plottedPoints.last!
        let highlightedPosition = normalizedPosition(of: highlightedPoint, in: plottedPoints)
        let highlightedValue = chartSelection == nil
            ? (chartPoints.last?.value ?? highlightedPoint.value)
            : highlightedPoint.value
        let firstDate = series.daily.first!.date
        let middleDate = series.daily[series.daily.count / 2].date
        let monthTicks = monthlyAxisDates(in: series.daily)
        let averageLevels = adaptiveAverageLevels(from: series.daily, for: selectedRange)
        return VStack(spacing: 0) {
            Chart {
                ForEach(chartPoints) { point in
                    AreaMark(
                        x: .value("Position", point.position),
                        yStart: .value("Minimum", domain.lowerBound),
                        yEnd: .value(title, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                color.opacity(showsAverageLevels ? 0.07 : 0.26),
                                color.opacity(showsAverageLevels ? 0.004 : 0.015)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Position", point.position),
                        y: .value(title, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(color.opacity(showsAverageLevels ? 0.3 : 1))
                }

                if showsAverageLevels {
                    ForEach(averageLevels) { level in
                        RuleMark(
                            xStart: .value(
                                "Average window start",
                                normalizedPosition(of: level.startDate, in: series.daily)
                            ),
                            xEnd: .value(
                                "Average window end",
                                normalizedPosition(of: level.endDate, in: series.daily)
                            ),
                            y: .value("Window average", level.value)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .butt))
                        .foregroundStyle(Color.white)
                        .annotation(position: .top, spacing: 5) {
                            Text(averageLevelLabel(level.value, for: metric))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .tracking(-0.35)
                                .foregroundStyle(Color.white)
                        }
                    }
                }

                if chartSelection != nil {
                    RectangleMark(
                        xStart: .value(
                            "Dimmed future start",
                            min(highlightedPosition + 0.002, 1)
                        ),
                        xEnd: .value(
                            "Dimmed future end",
                            1.02
                        ),
                        yStart: .value("Dimmed future minimum", domain.lowerBound),
                        yEnd: .value("Dimmed future maximum", domain.upperBound)
                    )
                    .foregroundStyle(
                        Color(uiColor: .secondarySystemGroupedBackground).opacity(0.58)
                    )

                    RuleMark(x: .value("Selected position", highlightedPosition))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }

                // Keep the endpoint visually continuous with the trend. A
                // single same-color mark avoids the dark cutout/halo that made
                // the old stacked symbols look separated from the line.
                PointMark(
                    x: .value("Position", highlightedPosition),
                    y: .value(title, highlightedValue)
                )
                .symbolSize(48)
                .foregroundStyle(color.opacity(showsAverageLevels ? 0.3 : 1))
            }
            .chartYScale(domain: domain)
            // Keep every metric inside its final range immediately. Range
            // changes intentionally do not morph between incompatible scales.
            .chartPlotStyle { plot in
                plot.clipped()
            }
            // Leave a small plot inset at both ends so the endpoint symbol is
            // never sheared by plot clipping.
            .chartXScale(domain: -0.02...1.02)
            .chartXSelection(
                value: normalizedSelectionBinding(for: metric, selectableSeries: plottedPoints)
            )
            .chartYAxis {
                AxisMarks(position: .trailing, values: yAxisValues(for: domain)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.secondary.opacity(0.16))

                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(yAxisLabel(number, for: metric))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
            }
            // Range labels live in the fixed-height footer below. Keeping them
            // out of Swift Charts prevents it from reserving a second,
            // invisible strip beneath the plot.
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: 126)
            .accessibilityLabel("\(title), \(selectedRange.accessibilityName)")

            rangeAxisFooter(
                monthDates: monthTicks,
                firstDate: firstDate,
                middleDate: middleDate
            )
        }
        .frame(height: 145, alignment: .top)
    }

    @ViewBuilder
    private func rangeAxisFooter(
        monthDates: [Date],
        firstDate: Date,
        middleDate: Date
    ) -> some View {
        if selectedRange.usesMonthlyAxis {
            monthlyAxisFooter(dates: monthDates)
        } else {
            chartAxisFooter(firstDate: firstDate, middleDate: middleDate)
        }
    }

    @ViewBuilder
    private func chartAxisFooter(firstDate: Date, middleDate: Date) -> some View {
        HStack {
            Text(axisLabel(for: firstDate))
            Spacer()
            Text(axisLabel(for: middleDate))
            Spacer()
            Text("Today")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.trailing, 28)
        .frame(height: 19, alignment: .top)
    }

    private func monthlyAxisFooter(dates: [Date]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                monthlyAxisLabel(for: date)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(
                        date.formatted(.dateTime.month(.wide).year())
                    )
                    .accessibilitySortPriority(Double(dates.count - index))
            }
        }
        // Match the plot width rather than extending beneath the trailing
        // y-axis values. Equal-width cells make each month visually regular.
        .padding(.trailing, 28)
        .frame(height: 19, alignment: .top)
    }

    private func monthlyAxisDates(in points: [MetricPoint]) -> [Date] {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else {
            return []
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: points) { point in
            let components = calendar.dateComponents([.year, .month], from: point.date)
            return (components.year ?? 0) * 100 + (components.month ?? 0)
        }

        let representedMonths: [Date] = grouped.values.compactMap { month in
            guard let representativeDate = month.first?.date,
                  let interval = calendar.dateInterval(of: .month, for: representativeDate) else {
                return nil
            }

            let visibleStart = max(interval.start, firstDate)
            let visibleEnd = min(interval.end, lastDate)
            let midpoint = visibleStart.timeIntervalSinceReferenceDate
                + (visibleEnd.timeIntervalSince(visibleStart) / 2)
            return Date(timeIntervalSinceReferenceDate: midpoint)
        }
        .sorted()

        let maximumTickCount = 4
        guard representedMonths.count > maximumTickCount else {
            return representedMonths
        }

        let lastIndex = representedMonths.count - 1
        return (0..<maximumTickCount).map { position in
            let fraction = Double(position) / Double(maximumTickCount - 1)
            let index = Int((fraction * Double(lastIndex)).rounded())
            return representedMonths[index]
        }
    }

    private func adaptiveAverageLevels(
        from points: [MetricPoint],
        for range: HealthRange
    ) -> [AverageLevel] {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else {
            return []
        }

        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: firstDate)
        let finalDay = calendar.startOfDay(for: lastDate)
        let spanDays = max(
            1,
            (calendar.dateComponents([.day], from: firstDay, to: finalDay).day ?? 0) + 1
        )
        let targetCount: Int
        switch range {
        case .year, .all:
            targetCount = 5
        case .week, .month:
            return []
        }
        let windowDays = max(1, Int(ceil(Double(spanDays) / Double(targetCount))))

        var levels: [AverageLevel] = []
        var windowEnd = calendar.date(byAdding: .day, value: 1, to: finalDay) ?? lastDate

        while windowEnd > firstDay {
            let proposedStart = calendar.date(byAdding: .day, value: -windowDays, to: windowEnd) ?? firstDay
            let windowStart = max(proposedStart, firstDay)
            let windowPoints = points.filter { point in
                point.date >= windowStart && point.date < windowEnd
            }

            if !windowPoints.isEmpty {
                let mean = windowPoints.map(\.value).reduce(0, +) / Double(windowPoints.count)
                levels.append(
                    AverageLevel(
                        startDate: windowStart,
                        endDate: min(windowEnd, lastDate),
                        value: mean
                    )
                )
            }

            windowEnd = proposedStart
        }

        return levels.reversed()
    }

    private func averageLevelLabel(_ value: Double, for metric: MetricKind) -> String {
        switch metric {
        case .sleep, .recovery:
            return "\(Int(value.rounded()))%"
        case .duration:
            return formatDuration(value)
        case .hrv, .rhr:
            return String(Int(value.rounded()))
        case .steps:
            return formatCompactSteps(value)
        }
    }

    @ViewBuilder
    private func monthlyAxisLabel(for date: Date) -> some View {
        VStack(spacing: 0) {
            Text(date, format: .dateTime.month(.abbreviated))
            Text(date, format: .dateTime.year(.twoDigits))
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func normalizedSelectionBinding(
        for metric: MetricKind,
        selectableSeries: [MetricPoint]
    ) -> Binding<Double?> {
        Binding(
            get: {
                guard activeMetric == metric, let selectedDate else { return nil }
                return normalizedPosition(of: selectedDate, in: selectableSeries)
            },
            set: { position in
                if let position,
                   let firstDate = selectableSeries.first?.date,
                   let lastDate = selectableSeries.last?.date {
                    let clampedPosition = min(max(position, 0), 1)
                    let date = firstDate.addingTimeInterval(
                        lastDate.timeIntervalSince(firstDate) * clampedPosition
                    )
                    guard let point = selectedPoint(in: selectableSeries, near: date) else { return }
                    if activeMetric != metric || selectedDate != point.date {
                        AppHaptics.selection()
                    }
                    activeMetric = metric
                    selectedDate = point.date
                } else if activeMetric == metric {
                    activeMetric = nil
                    selectedDate = nil
                }
            }
        )
    }

    private func normalizedPosition(of point: MetricPoint, in points: [MetricPoint]) -> Double {
        normalizedPosition(of: point.date, in: points)
    }

    private func normalizedPosition(of date: Date, in points: [MetricPoint]) -> Double {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date else { return 0.5 }
        let duration = lastDate.timeIntervalSince(firstDate)
        guard duration > 0 else { return 0.5 }
        return min(max(date.timeIntervalSince(firstDate) / duration, 0), 1)
    }

    private func selectedPoint(in series: [MetricPoint], near date: Date?) -> MetricPoint? {
        guard let date else { return series.last }

        return series.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        } ?? series.last
    }

    private func selectionLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func axisLabel(for date: Date) -> String {
        switch selectedRange {
        case .week, .month:
            date.formatted(.dateTime.month(.abbreviated).day())
        case .year, .all:
            date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private func formatDuration(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    private func formatSteps(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    private func formatCompactSteps(_ value: Double) -> String {
        guard abs(value) >= 1_000 else { return String(Int(value.rounded())) }
        let thousands = value / 1_000
        return thousands >= 10
            ? "\(Int(thousands.rounded()))k"
            : String(format: "%.1fk", thousands)
    }

    private func yAxisValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 4
        return (0...4).map { domain.lowerBound + (Double($0) * step) }
    }

    private func yAxisLabel(_ value: Double, for metric: MetricKind) -> String {
        switch metric {
        case .sleep, .recovery:
            "\(Int(value.rounded()))%"
        case .duration:
            String(format: "%.1fh", value)
        case .hrv, .rhr:
            String(Int(value.rounded()))
        case .steps:
            formatCompactSteps(value)
        }
    }

    private func metricSeries(
        for metric: MetricKind,
        range requestedRange: HealthRange? = nil
    ) -> MetricSeries {
        history.metricSeries(
            for: metric,
            range: requestedRange ?? selectedRange,
            referenceDate: (metric == .steps || metric == .recovery) ? currentDate : referenceDate
        )
    }

    private func metricValue(for metric: MetricKind, in record: DailyHealthRecord?) -> Double? {
        guard let record else { return nil }
        return switch metric {
        case .sleep: record.sleepScore
        case .recovery: record.recoveryScore
        case .duration: record.sleepDurationMinutes.map { $0 / 60 }
        case .hrv: record.hrvRMSSDMilliseconds
        case .rhr: record.restingHeartRateBPM
        case .steps: nil
        }
    }

    private func chartDomain(for points: [MetricPoint], metric: MetricKind) -> ClosedRange<Double> {
        if metric == .sleep || metric == .recovery { return 0...100 }
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        if metric == .steps {
            return 0...max(100, high * 1.12)
        }
        let padding = max((high - low) * 0.18, 0.5)
        return (low - padding)...(high + padding)
    }
}

private struct SleepDetectedCardHeightTransition: ViewModifier, Animatable {
    static let expandedHeight: CGFloat = 64

    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: Self.expandedHeight * progress, alignment: .top)
            .opacity(progress)
            .clipped()
    }
}

private struct WhoopBatteryPercentIcon: View {
    let level: Int?
    let isCharging: Bool

    private var clampedLevel: Int {
        min(max(level ?? 0, 0), 100)
    }

    private var fillColor: Color {
        if isCharging { return .green }
        if clampedLevel <= 20 { return .red }
        if clampedLevel <= 35 { return .yellow }
        return .primary
    }

    private var percentageText: String {
        level.map(String.init) ?? "–"
    }

    private var fillFraction: CGFloat {
        level == nil ? 0 : CGFloat(clampedLevel) / 100
    }

    private var trackColor: Color {
        if isCharging { return Color.white.opacity(0.24) }
        return Color.primary.opacity(0.58)
    }

    private static let shellWidth: CGFloat = 29
    private static let shellHeight: CGFloat = 16
    private static let shellRadius: CGFloat = 4.6

    private func percentageLabel(color: Color) -> some View {
        HStack(spacing: -0.5) {
            ForEach(Array(percentageText.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
            }
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(color)
        .frame(width: Self.shellWidth, height: Self.shellHeight)
    }

    private var chargingLabel: some View {
        HStack(spacing: 1) {
            HStack(spacing: -0.5) {
                ForEach(Array(percentageText.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                }
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))

            Image(systemName: "bolt.fill")
                .font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: Self.shellWidth, height: Self.shellHeight)
    }

    var body: some View {
        HStack(spacing: 1.6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.shellRadius, style: .continuous)
                    .fill(trackColor)

                Rectangle()
                    .fill(fillColor)
                    .frame(width: Self.shellWidth * fillFraction)

                if isCharging {
                    chargingLabel
                } else {
                    percentageLabel(color: .black)
                }
            }
            .frame(width: Self.shellWidth, height: Self.shellHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.shellRadius, style: .continuous))

            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 3.3,
                topTrailingRadius: 3.3,
                style: .continuous
            )
                .fill(trackColor)
                .frame(width: 2.4, height: 6.6)
        }
        .accessibilityHidden(true)
    }
}

private struct AnimatedMetricValue: View {
    private static let duration = 0.24
    private static let stagger = 0.014
    private static let maximumStagger = 0.042

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: String
    let fontSize: CGFloat
    let animateChanges: Bool

    @State private var previousValue: String
    @State private var displayedValue: String
    @State private var animationProgress: CGFloat = 1
    @State private var animationGeneration = 0

    init(value: String, fontSize: CGFloat = 30, animateChanges: Bool = true) {
        self.value = value
        self.fontSize = fontSize
        self.animateChanges = animateChanges
        _previousValue = State(initialValue: value)
        _displayedValue = State(initialValue: value)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(previousValue)
                .modifier(PreviousMetricValueFade(progress: animationProgress))

            HStack(spacing: 0) {
                ForEach(Array(displayedValue.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .modifier(
                            MetricDigitPop(
                                progress: animationProgress,
                                delay: min(Double(index) * Self.stagger, Self.maximumStagger),
                                duration: Self.duration,
                                totalDuration: Self.duration + Self.maximumStagger
                            )
                        )
                }
            }
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayedValue)
        .onChange(of: value) { _, newValue in
            guard newValue != displayedValue else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                previousValue = reduceMotion || !animateChanges ? newValue : displayedValue
                displayedValue = newValue
                animationProgress = reduceMotion || !animateChanges ? 1 : 0
                animationGeneration &+= 1
            }
        }
        .task(id: animationGeneration) {
            guard !reduceMotion, animationProgress == 0 else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: Self.duration + Self.maximumStagger)) {
                animationProgress = 1
            }
            try? await Task.sleep(for: .seconds(Self.duration + Self.maximumStagger))
            guard !Task.isCancelled else { return }
            previousValue = displayedValue
        }
    }
}

private struct MetricDigitPop: AnimatableModifier {
    var progress: CGFloat
    let delay: Double
    let duration: Double
    let totalDuration: Double

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let elapsed = progress * CGFloat(totalDuration)
        let localProgress = min(
            max((elapsed - CGFloat(delay)) / CGFloat(duration), 0),
            1
        )
        let easedProgress = easeOutBack(localProgress)

        content
            .opacity(localProgress)
            .blur(radius: (1 - localProgress) * 1.2)
            .scaleEffect(0.97 + (0.03 * easedProgress))
            .offset(y: (1 - easedProgress) * 5)
    }

    private func easeOutBack(_ progress: CGFloat) -> CGFloat {
        let overshoot: CGFloat = 0.72
        let shifted = progress - 1
        return 1 + ((overshoot + 1) * shifted * shifted * shifted)
            + (overshoot * shifted * shifted)
    }
}

private struct PreviousMetricValueFade: AnimatableModifier {
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let remaining = CGFloat(1) - min(progress, CGFloat(1))
        content.opacity(Double(remaining))
    }
}

struct MetricPoint: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

private struct PositionedMetricPoint: Identifiable {
    let id: Int
    let position: Double
    let value: Double
}

private struct AverageLevel: Identifiable {
    let startDate: Date
    let endDate: Date
    let value: Double

    var id: Date { startDate }
}

struct MetricSeries {
    let daily: [MetricPoint]
    let plotted: [MetricPoint]
}

enum MetricKind: Hashable {
    case sleep
    case recovery
    case duration
    case hrv
    case rhr
    case steps
}

enum HealthRange: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .week: "1 week"
        case .month: "1 month"
        case .year: "1 year"
        case .all: "All history"
        }
    }

    var dayCount: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .year: 365
        case .all: nil
        }
    }

    var accessibilityName: String {
        switch self {
        case .week: "one week"
        case .month: "one month"
        case .year: "one year"
        case .all: "all history"
        }
    }

    var usesMonthlyAxis: Bool {
        switch self {
        case .week, .month: false
        case .year, .all: true
        }
    }

}

@MainActor
enum AppHaptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let firmImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func softImpact() {
        softImpactGenerator.impactOccurred(intensity: 0.75)
        softImpactGenerator.prepare()
    }

    static func firmImpact() {
        firmImpactGenerator.impactOccurred(intensity: 0.85)
        firmImpactGenerator.prepare()
    }

    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func warning() {
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }
}

#Preview {
    RootView(whoopCollector: WhoopHandshakeProbe())
}
