import SwiftUI

/// One source of truth for presentation metadata shared by summary values,
/// trend cards, chart axes, and accessibility labels.
extension MetricKind {
    static let trendOrder: [MetricKind] = [
        .sleep, .duration, .steps, .recovery, .rhr, .hrv,
    ]

    var trendTitle: String {
        switch self {
        case .sleep: "Sleep"
        case .recovery: "Recovery"
        case .duration: "Sleep duration"
        case .hrv: "HRV"
        case .rhr: "RHR"
        case .steps: "Steps"
        }
    }

    var summaryTitle: String {
        self == .duration ? "Duration" : trendTitle
    }

    var symbol: String {
        switch self {
        case .sleep: "moon.stars.fill"
        case .recovery: "gauge.with.dots.needle.50percent"
        case .duration: "bed.double.fill"
        case .hrv: "waveform.path.ecg"
        case .rhr: "heart.fill"
        case .steps: "figure.walk"
        }
    }

    var color: Color {
        switch self {
        case .sleep: Color(red: 0.39, green: 0.69, blue: 1.0)
        case .recovery: .mint
        case .duration: .cyan
        case .hrv: .pink
        case .rhr: .red
        case .steps: .green
        }
    }

    var unit: String {
        switch self {
        case .hrv: "MS"
        case .rhr: "BPM"
        case .sleep, .recovery, .duration, .steps: ""
        }
    }

    func formattedValue(_ value: Double) -> String {
        switch self {
        case .sleep, .recovery:
            "\(Int(value.rounded()))%"
        case .duration:
            Self.formattedDuration(value)
        case .hrv, .rhr:
            String(Int(value.rounded()))
        case .steps:
            Int(value.rounded()).formatted(.number.grouping(.automatic))
        }
    }

    func formattedAxisValue(_ value: Double) -> String {
        switch self {
        case .sleep, .recovery:
            "\(Int(value.rounded()))%"
        case .duration:
            String(format: "%.1fh", value)
        case .hrv, .rhr:
            String(Int(value.rounded()))
        case .steps:
            Self.formattedCompactSteps(value)
        }
    }

    func formattedAverage(_ value: Double) -> String {
        switch self {
        case .duration:
            Self.formattedDuration(value)
        default:
            formattedAxisValue(value)
        }
    }

    func chartDomain(for points: [MetricPoint]) -> ClosedRange<Double> {
        if self == .sleep || self == .recovery { return 0...100 }
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        if self == .steps {
            return 0...max(100, high * 1.12)
        }
        let padding = max((high - low) * 0.18, 0.5)
        return (low - padding)...(high + padding)
    }

    private static func formattedDuration(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    private static func formattedCompactSteps(_ value: Double) -> String {
        guard abs(value) >= 1_000 else { return String(Int(value.rounded())) }
        let thousands = value / 1_000
        return thousands >= 10
            ? "\(Int(thousands.rounded()))k"
            : String(format: "%.1fk", thousands)
    }
}
