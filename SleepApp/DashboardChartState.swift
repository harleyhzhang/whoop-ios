import Observation
import SwiftUI

@Observable
@MainActor
final class DashboardChartState {
    private static let revealDuration = 0.28
    private static let concealDuration = 0.34

    var selectedDate: Date?
    var activeMetric: MetricKind?
    var detailedMetric: MetricKind?
    var releasingMetric: MetricKind?
    var detailProgress: CGFloat = 0
    var detailTargetProgress: CGFloat = 0
    var releaseProgress: CGFloat = 1
    var detailGeneration = 0

    func beginSelection(metric: MetricKind, date: Date, reduceMotion: Bool) {
        if activeMetric != metric {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                releasingMetric = nil
                releaseProgress = 1
                detailedMetric = metric
                detailProgress = reduceMotion ? 1 : 0
                detailTargetProgress = 1
                detailGeneration &+= 1
            }
        }
        activeMetric = metric
        selectedDate = date
    }

    func endSelection(metric: MetricKind, reduceMotion: Bool) {
        guard activeMetric == metric else { return }
        activeMetric = nil
        if reduceMotion {
            selectedDate = nil
            releasingMetric = nil
            releaseProgress = 1
            detailProgress = 0
            detailTargetProgress = 0
            detailedMetric = nil
        } else {
            releasingMetric = metric
            releaseProgress = 0
            detailTargetProgress = 0
            detailGeneration &+= 1
        }
    }

    /// Defers the animation until SwiftUI has rendered the explicitly staged
    /// source geometry. Without this frame boundary, the first hold can
    /// coalesce progress 0 and 1 and appear to snap directly to daily detail.
    func runDetailTransition(generation: Int, reduceMotion: Bool) async {
        guard generation == detailGeneration else { return }
        let target = detailTargetProgress
        guard !reduceMotion else {
            detailProgress = target
            if target == 0 { finishRelease() }
            return
        }

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, generation == detailGeneration else { return }

        let duration = target == 1 ? Self.revealDuration : Self.concealDuration
        withAnimation(.smooth(duration: duration, extraBounce: 0)) {
            detailProgress = target
            if target == 0 { releaseProgress = 1 }
        }

        try? await Task.sleep(for: .seconds(duration + 0.02))
        guard !Task.isCancelled, generation == detailGeneration else { return }
        if target == 0 { finishRelease() }
    }

    private func finishRelease() {
        selectedDate = nil
        releasingMetric = nil
        releaseProgress = 1
        detailedMetric = nil
    }
}
