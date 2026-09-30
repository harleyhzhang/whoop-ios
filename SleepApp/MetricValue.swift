import SwiftUI

struct MetricValue: View {
    let metric: HealthMetric
    let value: Double?
    var numberFontSize: CGFloat = 32
    var unitFontSize: CGFloat = 20

    private func number(_ text: String) -> Text {
        Text(text).font(.system(size: numberFontSize, weight: .semibold, design: .rounded))
    }

    private func unit(_ text: String) -> Text {
        Text(text).font(.system(size: unitFontSize, weight: .semibold, design: .rounded))
    }

    private var label: Text {
        guard let value else { return number("—") }
        switch metric {
        case .duration:
            let minutes = Int(value.rounded())
            return Text(
                "\(number(String(minutes / 60)))\(unit("h")) \(number(String(minutes % 60)))\(unit("m"))")
        case .sleep, .recovery:
            return Text("\(number(String(Int(value.rounded()))))\(unit("%"))")
        case .hrv, .rhr:
            return Text("\(number(metric.formatted(value)))\(unit(metric.unit.uppercased()))")
        case .steps, .strain:
            return number(metric.formatted(value))
        }
    }

    var body: some View {
        label.monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
    }
}
