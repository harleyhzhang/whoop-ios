import Charts
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("selectedHealthRange") private var selectedRange: HealthRange = .month
    @State private var selectedDate: Date?
    @State private var activeMetric: MetricKind?
    @State private var chartMorphFromRange: HealthRange?
    @State private var chartMorphProgress: CGFloat = 1
    @State private var chartMorphGeneration = 0
    @State private var currentDate = Date()
    @State private var debugMockPendingSleepDismissed = false
    @State private var showsConnectionDetails = false
    @ObservedObject var whoopCollector: WhoopHandshakeProbe
    @StateObject private var history = HealthHistoryModel()

    private var publishedDay: PublishedDashboardDay {
        PublishedDashboardDay(
            healthRecords: history.records,
            stepRecords: history.stepRecords,
            recoveryRecords: history.recoveryRecords,
            isWakePending: sleepMetricsArePending
        )
    }

    private var referenceDate: Date {
        sleepMetricsArePending ? currentDate : (publishedDay.date ?? currentDate)
    }

    /// A range is offered only when the history is long enough to mean anything
    /// by it. All history is always offered; it is the one range that describes
    /// whatever exists rather than a fixed window.
    private var availableRanges: [HealthRange] {
        guard let first = history.records.first?.date,
            let last = history.records.last?.date
        else {
            return HealthRange.allCases
        }
        let days = (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        return HealthRange.allCases.filter { range in
            guard let required = range.dayCount else { return true }
            return days >= required
        }
    }

    private var currentSleepRecord: DailyHealthRecord? {
        publishedDay.health
    }

    private var sleepMetricsArePending: Bool {
        WhoopLaunchOverrides.isSleeping || whoopCollector.isSleeping
            || displayedPendingSleep != nil
            || whoopCollector.isProcessingSleep
    }

    private var whoopBatteryLevel: Int? {
        WhoopLaunchOverrides.batteryLevel ?? whoopCollector.batteryLevel
    }

    private var whoopCharging: Bool {
        WhoopLaunchOverrides.isCharging || whoopCollector.isCharging
    }

    private var whoopConnected: Bool {
        WhoopLaunchOverrides.isConnected || whoopCollector.isConnected
    }

    private var displayedPendingSleep: WhoopPendingSleep? {
        if !debugMockPendingSleepDismissed, let minutes = WhoopLaunchOverrides.pendingSleepMinutes {
            return WhoopPendingSleep(
                sleepID: "mock-pending-sleep",
                startedAt: currentDate.addingTimeInterval(-minutes * 60),
                endedAt: currentDate,
                durationMinutes: minutes
            )
        }

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

                    ForEach(MetricKind.trendOrder, id: \.self) { metric in
                        metricCard(
                            metric: metric,
                            series: metricSeries(for: metric)
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedRange) { oldRange, _ in
            AppHaptics.selection()
            selectedDate = nil
            activeMetric = nil

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                chartMorphFromRange = reduceMotion ? nil : oldRange
                chartMorphProgress = reduceMotion ? 1 : 0
                chartMorphGeneration &+= 1
            }
        }
        .task(id: chartMorphGeneration) {
            guard !reduceMotion, chartMorphProgress == 0 else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.52, extraBounce: 0)) {
                chartMorphProgress = 1
            }
            try? await Task.sleep(for: .seconds(0.52))
            guard !Task.isCancelled else { return }
            chartMorphFromRange = nil
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
            guard let update = notification.object as? WhoopHealthHistoryUpdate else {
                history.reload()
                return
            }
            // Show a finished night on the next frame. The atomic reload behind
            // it verifies all three metric families from one database generation.
            if case .dayPublished(let record) = update {
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
        .sheet(isPresented: $showsConnectionDetails) {
            HandshakeView(probe: whoopCollector)
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

            Button {
                AppHaptics.softImpact()
                showsConnectionDetails = true
            } label: {
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
            }
            .buttonStyle(.plain)
            .frame(minHeight: 36)
            .accessibilityLabel(
                "WHOOP \(whoopConnected ? "connected" : "disconnected"), battery \(whoopBatteryLevel.map { "\($0) percent" } ?? "unavailable")\(whoopCharging ? ", charging" : "")"
            )
            .accessibilityHint("Show connection details")
            .accessibilityIdentifier("whoop.connection.details")
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
                .foregroundStyle(MetricKind.sleep.color)
                .frame(width: 34, height: 34)
                .background(MetricKind.sleep.color.opacity(0.14), in: Circle())

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
                    .background(MetricKind.sleep.color, in: Capsule(style: .continuous))
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
        if WhoopLaunchOverrides.pendingSleepMinutes != nil {
            debugMockPendingSleepDismissed = true
            return
        }

        whoopCollector.processPendingSleep()
    }

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
                    title: MetricKind.sleep.summaryTitle,
                    symbol: MetricKind.sleep.symbol,
                    value: summarySleepScore,
                    iconTint: MetricKind.sleep.color
                )
                activityMetric(
                    title: MetricKind.duration.summaryTitle,
                    symbol: MetricKind.duration.symbol,
                    value: summarySleepDuration,
                    iconTint: MetricKind.duration.color
                )
            }

            HStack(alignment: .top, spacing: 12) {
                activityMetric(
                    title: MetricKind.steps.summaryTitle,
                    symbol: MetricKind.steps.symbol,
                    value: summarySteps,
                    iconTint: MetricKind.steps.color
                )
                activityMetric(
                    title: MetricKind.recovery.summaryTitle,
                    symbol: MetricKind.recovery.symbol,
                    value: summaryRecovery,
                    iconTint: MetricKind.recovery.color
                )
                activityMetric(
                    title: MetricKind.rhr.summaryTitle,
                    symbol: MetricKind.rhr.symbol,
                    value: summaryRHR,
                    unit: summaryRHR == "—" ? "" : "BPM",
                    iconTint: MetricKind.rhr.color
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
        currentSleepRecord?.sleepScore.map(MetricKind.sleep.formattedValue) ?? "—"
    }

    private var summarySleepDuration: String {
        currentSleepRecord?.sleepDurationMinutes.map { MetricKind.duration.formattedValue($0 / 60) } ?? "—"
    }

    private var summarySteps: String {
        publishedDay.steps.map { MetricKind.steps.formattedValue(Double($0.stepCount)) } ?? "—"
    }

    private var summaryRecovery: String {
        publishedDay.recovery.map { MetricKind.recovery.formattedValue($0.score) } ?? "—"
    }

    private var summaryRHR: String {
        currentSleepRecord?.restingHeartRateBPM.map { String(Int($0.rounded())) } ?? "—"
    }

    private func metricCard(
        metric: MetricKind,
        series: MetricSeries
    ) -> some View {
        let title = metric.trendTitle
        let symbol = metric.symbol
        let unit = metric.unit
        let color = metric.color
        let cardSelection =
            !sleepMetricsArePending && activeMetric == metric
            ? selectedDate
            : nil
        let selectedMetricPoint: MetricPoint? = cardSelection.flatMap {
            self.selectedPoint(in: series.plotted, near: $0)
        }
        let currentValue: Double? =
            switch metric {
            case .steps: publishedDay.steps.map { Double($0.stepCount) }
            case .recovery: publishedDay.recovery?.score
            default: metricValue(for: metric, in: publishedDay.health)
            }
        let displayedValue =
            sleepMetricsArePending
            ? nil
            : (cardSelection == nil ? currentValue : selectedMetricPoint?.value)
        let value = displayedValue.map(metric.formattedValue) ?? "—"
        let valueDateLabel =
            cardSelection == nil
            ? publishedDay.date.map { selectionLabel(for: $0) } ?? "Today"
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
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    private func populatedMetricChart(metric: MetricKind, series: MetricSeries, color: Color, title: String)
        -> some View
    {
        let plottedPoints = series.plotted
        let chartPoints = morphingPoints(for: metric, target: series)
        let domain = morphingDomain(for: metric, target: series)
        let chartSelection = activeMetric == metric ? selectedDate : nil
        let averageOpacity = chartSelection == nil ? averageLevelOpacity : 0
        let longRangeStyle = longRangeStyleProgress
        let contentOpacity = ChartContentOpacity.resolve(
            longRangeStyleProgress: longRangeStyle,
            isScrubbing: chartSelection != nil
        )
        let lineOpacity = contentOpacity.line
        let areaOpacity = contentOpacity.area
        let markerSymbolArea: CGFloat = 48
        let highlightedPoint =
            selectedPoint(in: plottedPoints, near: chartSelection)
            ?? plottedPoints.last
            ?? MetricPoint(date: .now, value: 0)
        let requestedHighlightPosition = normalizedPosition(of: highlightedPoint, in: plottedPoints)
        // The colored trend is drawn through the resampled morph points, not
        // the original daily values. Snap the marker to the nearest one of
        // those exact curve anchors so monotone smoothing can never leave the
        // dot floating above or below the visible line.
        let highlightedCurvePoint = ChartPointAlignment.nearestCurvePoint(
            to: requestedHighlightPosition,
            in: chartPoints
        )
        let highlightedPosition = highlightedCurvePoint?.position ?? requestedHighlightPosition
        let highlightedValue = highlightedCurvePoint?.value ?? highlightedPoint.value
        let firstDate = series.daily.first?.date ?? highlightedPoint.date
        let middleDate = series.daily[series.daily.count / 2].date
        let monthTicks = monthlyAxisDates(in: series.daily)
        let averageRange = averageLevelRange
        let averageSeries =
            averageRange == selectedRange
            ? series
            : metricSeries(for: metric, range: averageRange)
        let averageLevels = adaptiveAverageLevels(from: averageSeries.daily, for: averageRange)
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
                                color,
                                color.opacity(0.015 / 0.26),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(areaOpacity)

                    LineMark(
                        x: .value("Position", point.position),
                        y: .value(title, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    // Swift Charts uses foreground style to group an unkeyed
                    // line into a series. Keep that identity stable while the
                    // dedicated mark opacity participates in the animation.
                    .foregroundStyle(color)
                    .opacity(lineOpacity)
                }

                if averageOpacity > 0.001 {
                    ForEach(averageLevels) { level in
                        RuleMark(
                            xStart: .value(
                                "Average window start",
                                normalizedPosition(of: level.startDate, in: averageSeries.daily)
                            ),
                            xEnd: .value(
                                "Average window end",
                                normalizedPosition(of: level.endDate, in: averageSeries.daily)
                            ),
                            y: .value("Window average", level.value)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .butt))
                        .foregroundStyle(Color.white)
                        .opacity(averageOpacity)
                        .annotation(position: .top, spacing: 5) {
                            Text(metric.formattedAverage(level.value))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .tracking(-0.35)
                                .foregroundStyle(Color.white.opacity(averageOpacity))
                        }
                        // Average levels remain visually above the passive
                        // endpoint if the two happen to intersect.
                        .zIndex(3)
                    }
                }

                if chartSelection != nil {
                    // Scrubbing restores the base chart to full strength. This
                    // is the only dimming overlay, so history stays opaque and
                    // only the future to the right of the marker is subdued.
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

                // Erase only the trend directly beneath the marker before its
                // translucent color is composited. Matching the mask and dot
                // sizes keeps the line connected at the edge without the dark
                // overlap or the halo created by an oversized cutout.
                PointMark(
                    x: .value("Position", highlightedPosition),
                    y: .value(title, highlightedValue)
                )
                .symbolSize(markerSymbolArea)
                .foregroundStyle(Color(uiColor: .secondarySystemGroupedBackground))
                .zIndex(1)

                PointMark(
                    x: .value("Position", highlightedPosition),
                    y: .value(title, highlightedValue)
                )
                .symbolSize(markerSymbolArea)
                .foregroundStyle(color)
                .opacity(lineOpacity)
                .zIndex(2)
            }
            .chartYScale(domain: domain)
            // The colored curve and its y-domain morph together between every
            // range. Year/All average steps are a separate opacity-only layer.
            .chartPlotStyle { plot in
                plot.clipped()
            }
            // Fixed horizontal coordinates make the colored curve morph
            // vertically without sliding or stretching sideways.
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
                let interval = calendar.dateInterval(of: .month, for: representativeDate)
            else {
                return nil
            }

            let visibleStart = max(interval.start, firstDate)
            let visibleEnd = min(interval.end, lastDate)
            let midpoint =
                visibleStart.timeIntervalSinceReferenceDate
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
                    let lastDate = selectableSeries.last?.date
                {
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

    private func morphingPoints(for metric: MetricKind, target: MetricSeries) -> [MorphingMetricPoint] {
        let sampleCount = 48
        let targetValues = ChartCurveSampler.resampledValues(
            from: target.plotted,
            count: sampleCount
        )
        guard !targetValues.isEmpty else { return [] }

        let sourceValues: [Double]
        if let chartMorphFromRange {
            let sourceSeries = metricSeries(for: metric, range: chartMorphFromRange)
            let sampledSource = ChartCurveSampler.resampledValues(
                from: sourceSeries.plotted,
                count: sampleCount
            )
            sourceValues = sampledSource.count == targetValues.count ? sampledSource : targetValues
        } else {
            sourceValues = targetValues
        }

        let progress = Double(chartMorphProgress)
        return targetValues.indices.map { index in
            MorphingMetricPoint(
                id: index,
                position: Double(index) / Double(max(targetValues.count - 1, 1)),
                value: interpolated(sourceValues[index], targetValues[index], progress: progress)
            )
        }
    }

    private func morphingDomain(for metric: MetricKind, target: MetricSeries) -> ClosedRange<Double> {
        let targetDomain = chartDomain(for: target.daily, metric: metric)
        guard let chartMorphFromRange else { return targetDomain }

        let source = metricSeries(for: metric, range: chartMorphFromRange)
        guard !source.daily.isEmpty else { return targetDomain }
        let sourceDomain = chartDomain(for: source.daily, metric: metric)
        let progress = Double(chartMorphProgress)
        let lowerBound = interpolated(
            sourceDomain.lowerBound,
            targetDomain.lowerBound,
            progress: progress
        )
        let upperBound = interpolated(
            sourceDomain.upperBound,
            targetDomain.upperBound,
            progress: progress
        )
        return lowerBound...upperBound
    }

    private func interpolated(_ source: Double, _ target: Double, progress: Double) -> Double {
        source + ((target - source) * progress)
    }

    /// The white Year/All average steps never interpolate their geometry.
    /// The target steps fade in, or the retained source steps fade out.
    private var averageLevelOpacity: Double {
        let targetIsLong = selectedRange.usesMonthlyAxis
        guard let sourceRange = chartMorphFromRange else { return targetIsLong ? 1 : 0 }
        let sourceIsLong = sourceRange.usesMonthlyAxis
        let progress = smoothStep(Double(chartMorphProgress))
        if targetIsLong { return progress }
        return sourceIsLong ? 1 - progress : 0
    }

    private var averageLevelRange: HealthRange {
        if selectedRange.usesMonthlyAxis { return selectedRange }
        if let source = chartMorphFromRange, source.usesMonthlyAxis { return source }
        return selectedRange
    }

    private var longRangeStyleProgress: Double {
        let target = selectedRange.usesMonthlyAxis ? 1.0 : 0.0
        guard let sourceRange = chartMorphFromRange else { return target }
        let source = sourceRange.usesMonthlyAxis ? 1.0 : 0.0
        return interpolated(source, target, progress: Double(chartMorphProgress))
    }

    private func smoothStep(_ rawValue: Double) -> Double {
        let value = min(max(rawValue, 0), 1)
        return value * value * (3 - (2 * value))
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

    private func yAxisValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 4
        return (0...4).map { domain.lowerBound + (Double($0) * step) }
    }

    private func yAxisLabel(_ value: Double, for metric: MetricKind) -> String {
        metric.formattedAxisValue(value)
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
        metric.chartDomain(for: points)
    }
}

#Preview {
    RootView(whoopCollector: WhoopHandshakeProbe())
}
