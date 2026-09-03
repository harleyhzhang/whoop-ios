import Charts
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedRange: HealthRange = .month
    @State private var selectedDate: Date?
    @State private var activeMetric: MetricKind?
    @State private var currentDate = Date()
    @StateObject private var whoopCollector = WhoopHandshakeProbe()
    @StateObject private var history = HealthHistoryModel()

    private var referenceDate: Date { currentDate }

    private var todayRecord: DailyHealthRecord? {
        history.records.last { Calendar.current.isDate($0.date, inSameDayAs: currentDate) }
    }

    private var currentSleepRecord: DailyHealthRecord? {
        sleepMetricsArePending ? nil : todayRecord
    }

    private var sleepMetricsArePending: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHOOP_MOCK_SLEEPING"] == "1" {
            return true
        }
        #endif
        return whoopCollector.isSleeping
    }

    private var liveHeartRateValue: String {
        #if DEBUG
        if let mockValue = ProcessInfo.processInfo.environment["WHOOP_MOCK_LIVE_HR"],
           !mockValue.isEmpty {
            return mockValue
        }
        #endif

        return whoopCollector.heartRate.split(separator: " ").first.map(String.init) ?? "—"
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

    private var whoopConnected: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WHOOP_MOCK_CONNECTED"] == "1" {
            return true
        }
        #endif

        return whoopCollector.isConnected
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dateHeader
                    sleepDetectedSection
                        .animation(
                            .smooth(duration: 0.45, extraBounce: 0.18),
                            value: whoopCollector.pendingSleep
                        )
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
                        metric: .hrv,
                        title: "HRV",
                        symbol: "waveform.path.ecg",
                        unit: "MS",
                        series: metricSeries(for: .hrv),
                        color: .pink,
                        formatValue: { String(Int($0.rounded())) }
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
                }
                .padding(.horizontal, 16)
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
                currentDate = .now
                history.reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var dateHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(referenceDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                if let errorMessage = history.errorMessage {
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

                WhoopBatteryPercentIcon(level: whoopBatteryLevel)
                    .opacity(whoopConnected ? 1 : 0.45)
            }
            .frame(minHeight: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "WHOOP \(whoopConnected ? "connected" : "disconnected"), battery \(whoopBatteryLevel.map { "\($0) percent" } ?? "unavailable")"
            )
        }
        .padding(.top, 8)
    }

    /// One borderless line between the date and the summary. It exists only
    /// while the store reports a detected night that is not written yet, so a
    /// night the automatic gates finish first never shows it at all.
    @ViewBuilder
    private var sleepDetectedSection: some View {
        if let pending = whoopCollector.pendingSleep {
            sleepDetectedRow(pending)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            .combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                    )
                )
        }
    }

    private func sleepDetectedRow(_ pending: WhoopPendingSleep) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sleepAccent)

            Text("Sleep detected")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)

            Text(whoopCollector.sleepProcessFailure ?? formatDuration(pending.durationMinutes / 60))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(whoopCollector.sleepProcessFailure == nil ? .secondary : Color.orange)
                .contentTransition(.opacity)

            Spacer(minLength: 8)

            Button {
                // processPendingSleep clears the row synchronously on the main
                // actor, so wrapping the call is what puts that removal inside
                // the animated transaction.
                withAnimation(.smooth(duration: 0.45, extraBounce: 0.18)) {
                    whoopCollector.processPendingSleep()
                }
            } label: {
                Text("Process")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(sleepAccent)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(sleepAccent.opacity(0.16), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(whoopCollector.isProcessingSleep)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Sleep detected, \(formatDuration(pending.durationMinutes / 60)). Double tap Process to finish it."
        )
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

    private var rangeSelectorButtons: some View {
        HStack(spacing: 2) {
            ForEach(HealthRange.allCases) { range in
                Button {
                    selectedRange = range
                } label: {
                    Text(range.rawValue)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background {
                            if selectedRange == range {
                                rangeSelectionHighlight
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.accessibilityName)
                .accessibilityAddTraits(selectedRange == range ? .isSelected : [])
            }
        }
        .padding(3)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var rangeSelector: some View {
        if #available(iOS 26.0, *) {
            rangeSelectorButtons
                .glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            rangeSelectorButtons
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        }
    }

    @ViewBuilder
    private var rangeSelectionHighlight: some View {
        if #available(iOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(Color.clear)
                .glassEffect(
                    .regular.tint(Color.white.opacity(0.16)).interactive(),
                    in: Capsule(style: .continuous)
                )
        } else {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.28))
        }
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
                    title: "HRV",
                    symbol: "waveform.path.ecg",
                    value: summaryHRV,
                    unit: summaryHRV == "—" ? "" : "MS",
                    iconTint: .pink
                )
                activityMetric(
                    title: "RHR",
                    symbol: "heart.fill",
                    value: summaryRHR,
                    unit: summaryRHR == "—" ? "" : "BPM",
                    iconTint: .red
                )
                activityMetric(
                    title: "Heart Rate",
                    symbol: "heart.fill",
                    value: liveHeartRateValue,
                    unit: liveHeartRateValue == "—" ? "" : "BPM",
                    iconTint: .red
                )
            }
        }
        .padding(.vertical, 2)
        .animation(.smooth(duration: 0.42), value: currentSleepRecord)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Sleep \(summarySleepScore), duration \(summarySleepDuration), heart rate variability \(summaryHRV) milliseconds, resting heart rate \(summaryRHR) beats per minute, live heart rate \(liveHeartRateValue) beats per minute"
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
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
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

    private var summaryHRV: String {
        currentSleepRecord?.hrvRMSSDMilliseconds.map { String(Int($0.rounded())) } ?? "—"
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
        let currentValue = metricValue(for: metric, in: currentSleepRecord)
        let displayedValue = cardSelection == nil ? currentValue : selectedMetricPoint?.value
        let value = displayedValue.map(formatValue) ?? "—"
        let valueDateLabel = cardSelection == nil
            ? "Today"
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
                        Text(value)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)

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
        let domain = chartDomain(for: series.daily, metric: metric)
        let chartSelection = activeMetric == metric ? selectedDate : nil
        let showsAverageLevels = selectedRange.usesMonthlyAxis && chartSelection == nil
        let highlightedPoint = selectedPoint(in: plottedPoints, near: chartSelection) ?? plottedPoints.last!
        let firstDate = series.daily.first!.date
        let middleDate = series.daily[series.daily.count / 2].date
        let monthTicks = monthlyAxisDates(in: series.daily)
        let lastDate = series.daily.last!.date
        let chartStartDate: Date
        let chartEndDate: Date
        if series.daily.count == 1 {
            chartStartDate = Calendar.current.date(byAdding: .hour, value: -12, to: firstDate) ?? firstDate
            chartEndDate = Calendar.current.date(byAdding: .hour, value: 12, to: lastDate) ?? lastDate
        } else {
            chartStartDate = firstDate
            chartEndDate = selectedRange.usesMonthlyAxis
                ? Calendar.current.date(byAdding: .day, value: 3, to: lastDate) ?? lastDate
                : lastDate
        }
        let averageLevels = adaptiveAverageLevels(from: series.daily, for: selectedRange)
        return VStack(spacing: 3) {
            Chart {
                ForEach(plottedPoints) { point in
                    AreaMark(
                        x: .value("Date", point.date),
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
                        x: .value("Date", point.date),
                        y: .value(title, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(color.opacity(showsAverageLevels ? 0.3 : 1))
                }

                if showsAverageLevels {
                    PointMark(
                        x: .value("Date", highlightedPoint.date),
                        y: .value(title, highlightedPoint.value)
                    )
                    .symbolSize(48)
                    .foregroundStyle(color.opacity(0.3))

                    ForEach(averageLevels) { level in
                        RuleMark(
                            xStart: .value("Average window start", level.startDate),
                            xEnd: .value("Average window end", level.endDate),
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
                            highlightedPoint.date.addingTimeInterval(1)
                        ),
                        xEnd: .value(
                            "Dimmed future end",
                            // Past the domain so the round line cap overhanging
                            // the final point is covered too. Marks are clipped
                            // to the plot area, so overshooting is safe and the
                            // right edge no longer shows an undimmed nub.
                            chartEndDate.addingTimeInterval(60 * 60 * 24 * 4)
                        ),
                        yStart: .value("Dimmed future minimum", domain.lowerBound),
                        yEnd: .value("Dimmed future maximum", domain.upperBound)
                    )
                    .foregroundStyle(
                        Color(uiColor: .secondarySystemGroupedBackground).opacity(0.58)
                    )

                    RuleMark(x: .value("Selected date", highlightedPoint.date))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }

                if !showsAverageLevels {
                    PointMark(
                        x: .value("Date", highlightedPoint.date),
                        y: .value(title, highlightedPoint.value)
                    )
                    .symbolSize(104)
                    .foregroundStyle(Color(uiColor: .secondarySystemGroupedBackground))

                    PointMark(
                        x: .value("Date", highlightedPoint.date),
                        y: .value(title, highlightedPoint.value)
                    )
                    .symbolSize(48)
                    .foregroundStyle(color)
                }
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: chartStartDate...chartEndDate)
            .chartXSelection(value: selectionBinding(for: metric, selectableSeries: plottedPoints))
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
            .chartXAxis {
                if selectedRange.usesMonthlyAxis {
                    AxisMarks(values: monthTicks) { value in
                        AxisValueLabel(collisionResolution: .disabled) {
                            if let date = value.as(Date.self) {
                                monthlyAxisLabel(for: date, firstTick: monthTicks.first)
                            }
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: 126)
            .accessibilityLabel("\(title), \(selectedRange.accessibilityName)")

            if !selectedRange.usesMonthlyAxis {
                chartAxisFooter(firstDate: firstDate, middleDate: middleDate, lastDate: lastDate)
            }
        }
        .frame(height: 145, alignment: .top)
    }

    @ViewBuilder
    private func chartAxisFooter(firstDate: Date, middleDate: Date, lastDate: Date) -> some View {
        HStack {
            Text(axisLabel(for: firstDate))
            Spacer()
            Text(axisLabel(for: middleDate))
            Spacer()
            Text(Calendar.current.isDateInToday(lastDate) ? "Today" : "Latest")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.trailing, 28)
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

        return grouped.values.compactMap { month in
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
        case .sleep:
            return "\(Int(value.rounded()))%"
        case .duration:
            return formatDuration(value)
        case .hrv, .rhr:
            return String(Int(value.rounded()))
        }
    }

    @ViewBuilder
    private func monthlyAxisLabel(for date: Date, firstTick: Date?) -> some View {
        let calendar = Calendar.current
        VStack(spacing: 0) {
            Text(date, format: .dateTime.month(.narrow))
            if date == firstTick || calendar.component(.month, from: date) == 1 {
                Text(date, format: .dateTime.year(.twoDigits))
            }
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func selectionBinding(for metric: MetricKind, selectableSeries: [MetricPoint]) -> Binding<Date?> {
        Binding(
            get: { activeMetric == metric ? selectedDate : nil },
            set: { date in
                if let date, let point = selectedPoint(in: selectableSeries, near: date) {
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

    private func yAxisValues(for domain: ClosedRange<Double>) -> [Double] {
        let step = (domain.upperBound - domain.lowerBound) / 4
        return (0...4).map { domain.lowerBound + (Double($0) * step) }
    }

    private func yAxisLabel(_ value: Double, for metric: MetricKind) -> String {
        switch metric {
        case .sleep:
            "\(Int(value.rounded()))%"
        case .duration:
            String(format: "%.1fh", value)
        case .hrv, .rhr:
            String(Int(value.rounded()))
        }
    }

    private func metricSeries(for metric: MetricKind) -> MetricSeries {
        let calendar = Calendar.current
        let records: [DailyHealthRecord]
        if let dayCount = selectedRange.dayCount,
           let cutoff = calendar.date(byAdding: .day, value: -(dayCount - 1), to: referenceDate) {
            records = history.records.filter { $0.date >= calendar.startOfDay(for: cutoff) }
        } else {
            records = history.records
        }

        let daily = records.compactMap { record in
            metricValue(for: metric, in: record).map { MetricPoint(date: record.date, value: $0) }
        }

        return MetricSeries(
            daily: daily,
            plotted: aggregatedPoints(from: daily, for: selectedRange)
        )
    }

    private func metricValue(for metric: MetricKind, in record: DailyHealthRecord?) -> Double? {
        guard let record else { return nil }
        switch metric {
        case .sleep:
            return record.sleepScore
        case .duration:
            return record.sleepDurationMinutes.map { $0 / 60 }
        case .hrv:
            return record.hrvRMSSDMilliseconds
        case .rhr:
            return record.restingHeartRateBPM
        }
    }

    private func aggregatedPoints(from daily: [MetricPoint], for range: HealthRange) -> [MetricPoint] {
        switch range {
        case .week, .month:
            daily
        case .year:
            medianBuckets(from: daily, spanning: 7)
        case .all:
            medianBuckets(from: daily, spanning: adaptiveAllHistoryBucketDays(for: daily))
        }
    }

    private func adaptiveAllHistoryBucketDays(for points: [MetricPoint]) -> Int {
        guard let first = points.first, let last = points.last else { return 7 }
        let calendar = Calendar.current
        let span = max(
            1,
            (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: first.date),
                to: calendar.startOfDay(for: last.date)
            ).day ?? 0) + 1
        )

        return max(7, Int(ceil(Double(span) / 50.0)))
    }

    private func medianBuckets(from points: [MetricPoint], spanning bucketDays: Int) -> [MetricPoint] {
        guard let first = points.first, bucketDays > 1 else { return points }
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: first.date)
        let grouped = Dictionary(grouping: points) { point in
            let dayOffset = calendar.dateComponents(
                [.day],
                from: anchor,
                to: calendar.startOfDay(for: point.date)
            ).day ?? 0
            return max(0, dayOffset / bucketDays)
        }

        let finalBucketKey = grouped.keys.max()
        return grouped.keys.sorted().compactMap { key in
            guard let bucket = grouped[key]?.sorted(by: { $0.date < $1.date }), !bucket.isEmpty else {
                return nil
            }
            // The dashboard's current value is an exact observation. Anchor the
            // trend to that same point so its endpoint and marker cannot diverge.
            if key == finalBucketKey {
                return bucket.last
            }
            let values = bucket.map(\.value).sorted()
            let middle = values.count / 2
            let median = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
            let representativeDate = bucket.last!.date
            return MetricPoint(date: representativeDate, value: median)
        }
    }

    private func chartDomain(for points: [MetricPoint], metric: MetricKind) -> ClosedRange<Double> {
        if metric == .sleep { return 0...100 }
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.18, 0.5)
        return (low - padding)...(high + padding)
    }
}

private struct WhoopBatteryPercentIcon: View {
    let level: Int?

    private var clampedLevel: Int {
        min(max(level ?? 0, 0), 100)
    }

    private var fillColor: Color {
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
        Color.primary.opacity(0.45)
    }

    private static let shellWidth: CGFloat = 29
    private static let shellHeight: CGFloat = 16
    private static let shellRadius: CGFloat = 4.6

    private func percentageLabel(color: Color) -> some View {
        HStack(spacing: -0.7) {
            ForEach(Array(percentageText.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
            }
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(color)
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

                percentageLabel(color: .black)
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

private struct MetricPoint: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

private struct AverageLevel: Identifiable {
    let startDate: Date
    let endDate: Date
    let value: Double

    var id: Date { startDate }
}

private struct MetricSeries {
    let daily: [MetricPoint]
    let plotted: [MetricPoint]
}

private enum MetricKind: Hashable {
    case sleep
    case duration
    case hrv
    case rhr
}

private enum HealthRange: String, CaseIterable, Identifiable {
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
    RootView()
}
