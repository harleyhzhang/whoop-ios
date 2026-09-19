import Observation
import SwiftUI

@Observable
@MainActor
final class DashboardChartState {
    static let revealDuration = 0.22
    static let releaseFrameCount = 34
    static let releaseFrameDuration = Duration.milliseconds(8)

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

        if target == 0 {
            await runReleaseTransition(generation: generation)
            return
        }

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, generation == detailGeneration else { return }

        withAnimation(.smooth(duration: Self.revealDuration, extraBounce: 0)) {
            detailProgress = target
        }

        try? await Task.sleep(for: .seconds(Self.revealDuration + 0.02))
        guard !Task.isCancelled, generation == detailGeneration else { return }
    }

    /// Advances one shared phase without implicit coordinate interpolation.
    /// Each frame therefore rebuilds the current curve first, then lets the
    /// marker sample that curve at its eased horizontal position.
    private func runReleaseTransition(generation: Int) async {
        let initialDetailProgress = detailProgress
        for frame in 1...Self.releaseFrameCount {
            try? await Task.sleep(for: Self.releaseFrameDuration)
            guard !Task.isCancelled, generation == detailGeneration else { return }

            let progress = CGFloat(frame) / CGFloat(Self.releaseFrameCount)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                releaseProgress = progress
                detailProgress = initialDetailProgress * (1 - progress)
            }
        }
        finishRelease()
    }

    private func finishRelease() {
        selectedDate = nil
        releasingMetric = nil
        releaseProgress = 1
        detailedMetric = nil
    }
}
