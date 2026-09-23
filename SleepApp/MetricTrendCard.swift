import Charts
import SwiftUI
import UIKit

struct MetricTrendCard: View {
    private static let lineWidth: CGFloat = 2.1
    private static let lineOpacity = 0.3
    private static let areaOpacity = 0.07
    private static let markerSymbolArea: CGFloat = 48

    let metric: MetricKind
    let series: MetricSeries
    let publishedDate: Date?
    let currentValue: Double?

    var body: some View {
        let value = currentValue.map(metric.formattedValue) ?? "—"
        let valueDateLabel = publishedDate.map(Self.dateLabel) ?? "Today"

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
                            numericValue: currentValue,
                            fontSize: 24
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
                "\(metric.trendTitle), no real data in all history"
            )
        } else {
            populatedMetricChart
        }
    }

    private var populatedMetricChart: some View {
        let chartPoints = DashboardChartGeometry.summaryCurvePoints(in: series)
        let domain = metric.chartDomain(for: series.daily)
        let latestPosition = chartPoints.last?.position ?? 1
        let latestValue = chartPoints.last?.value ?? series.daily.last?.value ?? 0
        let monthTicks = DashboardChartGeometry.monthlyAxisDates(in: series.daily)
        let averageLevels = DashboardChartGeometry.averageLevels(from: series.daily)

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
                    .opacity(Self.areaOpacity)

                    LineMark(
                        x: .value("Position", point.position),
                        y: .value(metric.trendTitle, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(
                        StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .foregroundStyle(metric.color)
                    .opacity(Self.lineOpacity)
                }

                ForEach(averageLevels) { level in
                    RuleMark(
                        xStart: .value(
                            "Average window start",
                            DashboardChartGeometry.normalizedPosition(
                                of: level.startDate,
                                in: series.daily
                            )
                        ),
                        xEnd: .value(
                            "Average window end",
                            DashboardChartGeometry.normalizedPosition(
                                of: level.endDate,
                                in: series.daily
                            )
                        ),
                        y: .value("Window average", level.value)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .butt))
                    .foregroundStyle(Color.white)
                    .annotation(position: .top, spacing: 5) {
                        Text(metric.formattedAverage(level.value))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .tracking(-0.35)
                            .foregroundStyle(Color.white)
                    }
                    .zIndex(3)
                }

                PointMark(
                    x: .value("Position", latestPosition),
                    y: .value(metric.trendTitle, latestValue)
                )
                .symbolSize(Self.markerSymbolArea)
                .foregroundStyle(Color(uiColor: .secondarySystemGroupedBackground))
                .zIndex(1)

                PointMark(
                    x: .value("Position", latestPosition),
                    y: .value(metric.trendTitle, latestValue)
                )
                .symbolSize(Self.markerSymbolArea)
                .foregroundStyle(metric.color)
                .opacity(Self.lineOpacity)
                .zIndex(2)
            }
            .chartYScale(domain: domain)
            .chartPlotStyle { $0.clipped() }
            .chartXScale(domain: -0.02...1.02)
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
            .accessibilityIdentifier("whoop.chart.\(metric.accessibilityID)")
            .accessibilityLabel("\(metric.trendTitle), all history")
            .accessibilityValue("Summary line")

            rangeAxisFooter(monthDates: monthTicks)
        }
        .frame(height: 145, alignment: .top)
    }

    @ViewBuilder
    private func rangeAxisFooter(monthDates: [Date]) -> some View {
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
    }

    private static func dateLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
