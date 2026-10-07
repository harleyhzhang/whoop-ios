import Foundation

enum ChartValueScale {
    /// Fit plotted values without magnifying small fluctuations. Missing
    /// observations add no zero baseline.
    static func domain(metric: HealthMetric, values: [Double]) -> ClosedRange<Double> {
        let values = values.filter { $0.isFinite && $0 >= 0 }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let minimumPadding: Double
        switch metric {
        case .duration: minimumPadding = 30  // Original half-hour padding, in minutes.
        case .steps: minimumPadding = 100
        default: minimumPadding = 0.5
        }
        let padding = max((high - low) * 0.5, high * 0.1, minimumPadding)
        return max(0, low - padding)...(high + padding)
    }
}
