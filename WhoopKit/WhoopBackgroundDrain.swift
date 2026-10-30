import UIKit

/// Keeps the ordinary packet drain separate from sensor-control cleanup.
@MainActor
final class WhoopBackgroundDrain {
    private var task = UIBackgroundTaskIdentifier.invalid

    func begin(flush: (@escaping @Sendable () -> Void) -> Void) {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Persist pending WHOOP packets") { [weak self] in
            Task { @MainActor in self?.finish() }
        }
        flush { [weak self] in
            Task { @MainActor in self?.finish() }
        }
    }

    private func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
