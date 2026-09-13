import Observation
import SwiftUI

@Observable
@MainActor
final class DashboardChartState {
    var selectedDate: Date?
    var activeMetric: MetricKind?
    var morphFromRange: HealthRange?
    var morphProgress: CGFloat = 1
    var morphGeneration = 0

    func beginRangeTransition(from oldRange: HealthRange, reduceMotion: Bool) {
        selectedDate = nil
        activeMetric = nil
        morphFromRange = reduceMotion ? nil : oldRange
        morphProgress = reduceMotion ? 1 : 0
        morphGeneration &+= 1
    }
}
