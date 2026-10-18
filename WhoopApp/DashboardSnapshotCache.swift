import Foundation
import OSLog

/// The last dashboard the store produced, persisted so a cold launch draws real
/// values in its first frame. The store's first read then replaces it. Strain
/// derivations stay out: they are pending store writes, not display state.
final class DashboardSnapshotCache: @unchecked Sendable {
    static let production = DashboardSnapshotCache(
        url: WhoopStore.databaseDirectory()?.appendingPathComponent("dashboard-snapshot-v1.json")
    )

    private struct Document: Codable {
        let healthRecords: [DailyHealthRecord]
        let stepRecords: [DailyStepRecord]
        let recoveryRecords: [DailyRecoveryRecord]
        let strainRecords: [DailyStrainRecord]
    }

    private static let logger = Logger(subsystem: "whoop", category: "DashboardSnapshotCache")
    private let url: URL?
    private let queue = DispatchQueue(label: "whoop.dashboard-snapshot-cache", qos: .utility)
    private let lock = NSLock()
    private var didRead = false
    private var launchSnapshot: DashboardHistorySnapshot?
    // Confined to `queue`; skips rewriting an unchanged dashboard every reload.
    private var lastWritten: Data?

    init(url: URL?) {
        self.url = url
    }

    /// Reads the file once; SwiftUI may construct and discard models repeatedly.
    func cachedSnapshot() -> DashboardHistorySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !didRead else { return launchSnapshot }
        didRead = true
        guard let url, let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return nil }
        queue.async { [self] in lastWritten = data }
        launchSnapshot = DashboardHistorySnapshot(
            healthRecords: document.healthRecords,
            stepRecords: document.stepRecords,
            recoveryRecords: document.recoveryRecords,
            strainRecords: document.strainRecords
        )
        return launchSnapshot
    }

    func save(_ snapshot: DashboardHistorySnapshot, completion: (@Sendable () -> Void)? = nil) {
        guard let url else { return }
        queue.async { [self] in
            defer { completion?() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let document = Document(
                healthRecords: snapshot.healthRecords,
                stepRecords: snapshot.stepRecords,
                recoveryRecords: snapshot.recoveryRecords,
                strainRecords: snapshot.strainRecords
            )
            guard let data = try? encoder.encode(document), data != lastWritten else { return }
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                lastWritten = data
            } catch {
                Self.logger.error(
                    "Could not persist dashboard snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
