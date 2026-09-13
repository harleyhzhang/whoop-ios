import Charts
import SwiftUI
import UIKit

struct MetricTrendCard: View {
    let metric: MetricKind
    let series: MetricSeries
    let selectedRange: HealthRange
    let publishedDate: Date?
    let currentValue: Double?
    @Bindable var chartState: DashboardChartState
    let seriesForRange: (HealthRange) -> MetricSeries

    private var cardSelection: Date? {
        chartState.activeMetric == metric ? chartState.selectedDate : nil
    }

    private var selectedMetricPoint: MetricPoint? {
        cardSelection.flatMap {
            DashboardChartGeometry.selectedPoint(in: series.plotted, near: $0)
        }
    }

    var body: some View {
        let displayedValue = cardSelection == nil ? currentValue : selectedMetricPoint?.value
        let value = displayedValue.map(metric.formattedValue) ?? "—"
        let valueDateLabel =
            cardSelection == nil
            ? publishedDate.map(Self.selectionLabel) ?? "Today"
            : selectedMetricPoint.map { Self.selectionLabel(for: $0.date) } ?? "No real data"

        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(metric.trendTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: metric.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(metric.color)
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

                        if value != "—", !metric.unit.isEmpty {
                            Text(metric.unit)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .frame(width: 88, alignment: .leading)
                .padding(.bottom, 22)

                metricChart
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private var metricChart: some View {
        if series.daily.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                Text("No real data in this range")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 148)
            .accessibilityLabel(
                "\(metric.trendTitle), no real data in \(selectedRange.accessibilityName)"
            )
        } else {
            populatedMetricChart
        }
    }

    private var populatedMetricChart: some View {
        let plottedPoints = series.plotted
        let sourceSeries = chartState.morphFromRange.map(seriesForRange)
        let chartPoints = DashboardChartGeometry.morphingPoints(
            target: series,
            source: sourceSeries,
            progress: Double(chartState.morphProgress)
        )
        let domain = DashboardChartGeometry.morphingDomain(
            metric: metric,
            target: series,
            source: sourceSeries,
            progress: Double(chartState.morphProgress)
        )
        let chartSelection = cardSelection
        let averageOpacity = chartSelection == nil ? resolvedAverageOpacity : 0
        let contentOpacity = ChartContentOpacity.resolve(
            longRangeStyleProgress: DashboardChartGeometry.longRangeStyleProgress(
                selectedRange: selectedRange,
                sourceRange: chartState.morphFromRange,
                progress: Double(chartState.morphProgress)
            ),
            isScrubbing: chartSelection != nil
        )
        let highlightedPoint =
            DashboardChartGeometry.selectedPoint(in: plottedPoints, near: chartSelection)
            ?? plottedPoints.last
            ?? MetricPoint(date: .now, value: 0)
        let requestedHighlightPosition = DashboardChartGeometry.normalizedPosition(
            of: highlightedPoint.date,
            in: plottedPoints
        )
        let highlightedCurvePoint = ChartPointAlignment.nearestCurvePoint(
            to: requestedHighlightPosition,
            in: chartPoints
        )
        let highlightedPosition = highlightedCurvePoint?.position ?? requestedHighlightPosition
        let highlightedValue = highlightedCurvePoint?.value ?? highlightedPoint.value
        let firstDate = series.daily.first?.date ?? highlightedPoint.date
        let middleDate = series.daily[series.daily.count / 2].date
        let monthTicks = DashboardChartGeometry.monthlyAxisDates(in: series.daily)
        let averageRange = resolvedAverageRange
        let averageSeries = averageRange == selectedRange ? series : seriesForRange(averageRange)
        let averageLevels = DashboardChartGeometry.averageLevels(
            from: averageSeries.daily,
            for: averageRange
        )
        let markerSymbolArea: CGFloat = 48

        return VStack(spacing: 0) {
            Chart {
                ForEach(chartPoints) { point in
                    AreaMark(
                        x: .value("Position", point.position),
                        yStart: .value("Minimum", domain.lowerBound),
                        yEnd: .value(metric.trendTitle, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                metric.color,
                                metric.color.opacity(0.015 / 0.26),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(contentOpacity.area)

                    LineMark(
                        x: .value("Position", point.position),
                        y: .value(metric.trendTitle, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(
                        StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    .foregroundStyle(metric.color)
                    .opacity(contentOpacity.line)
                }

                if averageOpacity > 0.001 {
                    ForEach(averageLevels) { level in
                        RuleMark(
                            xStart: .value(
                                "Average window start",
                                DashboardChartGeometry.normalizedPosition(
                                    of: level.startDate,
                                    in: averageSeries.daily
                                )
                            ),
                            xEnd: .value(
                                "Average window end",
                                DashboardChartGeometry.normalizedPosition(
                                    of: level.endDate,
                                    in: averageSeries.daily
                                )
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
                        .zIndex(3)
                    }
                }

                if chartSelection != nil {
                    RectangleMark(
                        xStart: .value(
                            "Dimmed future start",
                            min(highlightedPosition + 0.002, 1)
                        ),
                        xEnd: .value("Dimmed future end", 1.02),
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

                PointMark(
                    x: .value("Position", highlightedPosition),
                    y: .value(metric.trendTitle, highlightedValue)
                )
                .symbolSize(markerSymbolArea)
                .foregroundStyle(Color(uiColor: .secondarySystemGroupedBackground))
                .zIndex(1)

                PointMark(
                    x: .value("Position", highlightedPosition),
                    y: .value(metric.trendTitle, highlightedValue)
                )
                .symbolSize(markerSymbolArea)
                .foregroundStyle(metric.color)
                .opacity(contentOpacity.line)
                .zIndex(2)
            }
            .chartYScale(domain: domain)
            .chartPlotStyle { $0.clipped() }
            .chartXScale(domain: -0.02...1.02)
            .chartXSelection(value: normalizedSelectionBinding(selectableSeries: plottedPoints))
            .chartYAxis {
                AxisMarks(
                    position: .trailing,
                    values: DashboardChartGeometry.yAxisValues(for: domain)
                ) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.secondary.opacity(0.16))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(metric.formattedAxisValue(number))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: 126)
            .accessibilityLabel(
                "\(metric.trendTitle), \(selectedRange.accessibilityName)"
            )

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
            HStack(spacing: 0) {
                ForEach(Array(monthDates.enumerated()), id: \.offset) { index, date in
                    VStack(spacing: 0) {
                        Text(date, format: .dateTime.month(.abbreviated))
                        Text(date, format: .dateTime.year(.twoDigits))
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(date.formatted(.dateTime.month(.wide).year()))
                    .accessibilitySortPriority(Double(monthDates.count - index))
                }
            }
            .padding(.trailing, 28)
            .frame(height: 19, alignment: .top)
        } else {
            HStack {
                Text(DashboardChartGeometry.axisLabel(for: firstDate, range: selectedRange))
                Spacer()
                Text(DashboardChartGeometry.axisLabel(for: middleDate, range: selectedRange))
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
    }

    private var resolvedAverageOpacity: Double {
        DashboardChartGeometry.averageOpacity(
            selectedRange: selectedRange,
            sourceRange: chartState.morphFromRange,
            progress: Double(chartState.morphProgress)
        )
    }

    private var resolvedAverageRange: HealthRange {
        if selectedRange.usesMonthlyAxis { return selectedRange }
        if let source = chartState.morphFromRange, source.usesMonthlyAxis { return source }
        return selectedRange
    }

    private func normalizedSelectionBinding(
        selectableSeries: [MetricPoint]
    ) -> Binding<Double?> {
        Binding(
            get: {
                guard chartState.activeMetric == metric, let selectedDate = chartState.selectedDate
                else { return nil }
                return DashboardChartGeometry.normalizedPosition(
                    of: selectedDate,
                    in: selectableSeries
                )
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
                    guard
                        let point = DashboardChartGeometry.selectedPoint(
                            in: selectableSeries,
                            near: date
                        )
                    else { return }
                    if chartState.activeMetric != metric || chartState.selectedDate != point.date {
                        AppHaptics.selection()
                    }
                    chartState.activeMetric = metric
                    chartState.selectedDate = point.date
                } else if chartState.activeMetric == metric {
                    chartState.activeMetric = nil
                    chartState.selectedDate = nil
                }
            }
        )
    }

    private static func selectionLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
