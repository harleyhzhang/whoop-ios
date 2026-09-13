import Observation
import SwiftUI

@Observable
@MainActor
final class DashboardChartState {
    var selectedDate: Date?
    var activeMetric: MetricKind?
    var detailedMetric: MetricKind?
    var detailProgress: CGFloat = 0

    func beginSelection(metric: MetricKind, date: Date, reduceMotion: Bool) {
        if activeMetric != metric {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                detailedMetric = metric
                detailProgress = reduceMotion ? 1 : 0
            }
            if !reduceMotion {
                withAnimation(.smooth(duration: 0.28, extraBounce: 0)) {
                    detailProgress = 1
                }
            }
        }
        activeMetric = metric
        selectedDate = date
    }

    func endSelection(metric: MetricKind, reduceMotion: Bool) {
        guard activeMetric == metric else { return }
        activeMetric = nil
        selectedDate = nil
        if reduceMotion {
            detailProgress = 0
        } else {
            withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
                detailProgress = 0
            }
        }
    }
}
