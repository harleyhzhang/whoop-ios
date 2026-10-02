import Foundation
@preconcurrency import MetricKit
import OSLog

final class WhoopRuntimeDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = WhoopRuntimeDiagnostics()
    static let signposter = OSSignposter(
        logger: Logger(
            subsystem: "whoop",
            category: "Performance"
        )
    )

    private static let logger = Logger(
        subsystem: "whoop",
        category: "RuntimeDiagnostics"
    )
    private let persistenceQueue = DispatchQueue(
        label: "whoop.runtime-diagnostics",
        qos: .utility
    )
    private var started = false
    private let lock = NSLock()

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, name: "metric-kit-metrics.json")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persist(payloads.map { $0.jsonRepresentation() }, name: "metric-kit-diagnostics.json")
    }

    private func persist(_ payloads: [Data], name: String) {
        guard !payloads.isEmpty else { return }
        persistenceQueue.async {
            guard let directory = WhoopStore.databaseDirectory() else { return }
            let url = directory.appendingPathComponent(name)
            let document = Data(
                "[\(payloads.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: ","))]"
                    .utf8
            )
            do {
                try document.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                Self.logger.error(
                    "Could not persist MetricKit payload: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
