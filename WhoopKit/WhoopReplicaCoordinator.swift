import CryptoKit
import Foundation
import OSLog
import UIKit

@MainActor
protocol WhoopReplicaScheduling: AnyObject {
    func requestSync(reason: WhoopReplicaReason)
}

@MainActor
final class WhoopReplicaCoordinator: WhoopReplicaScheduling {
    private enum DefaultsKey {
        static let lastAttempt = "WhoopReplica.lastAttempt"
        static let lastSuccess = "WhoopReplica.lastSuccess"
    }

    private let configuration: WhoopReplicaConfiguration?
    private let sourceURL: URL?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let isForeground: () -> Bool
    private var task: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private static let logger = Logger(
        subsystem: "whoop",
        category: "WhoopReplica"
    )

    init(
        configuration: WhoopReplicaConfiguration? = .load(),
        sourceURL: URL? = WhoopStore.productionDatabaseURL(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        isForeground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.configuration = configuration
        self.sourceURL = sourceURL
        self.defaults = defaults
        self.now = now
        self.isForeground = isForeground
    }

    func requestSync(reason: WhoopReplicaReason) {
        guard isForeground(), task == nil, configuration != nil, sourceURL != nil else { return }
        let requestedAt = now()
        guard
            WhoopReplicaSyncPolicy.shouldStart(
                reason: reason,
                now: requestedAt,
                lastSuccess: defaults.object(forKey: DefaultsKey.lastSuccess) as? Date,
                lastAttempt: defaults.object(forKey: DefaultsKey.lastAttempt) as? Date
            )
        else { return }
        defaults.set(requestedAt, forKey: DefaultsKey.lastAttempt)
        beginBackgroundTask()
        task = Task { [weak self] in
            guard let self else { return }
            await self.performSync(createdAt: requestedAt)
            self.finish()
        }
    }

    func prepareForBackground() {
        // Keep ownership until the worker has closed SQLite and checkpointed
        // completed work or removed its partial file. Clearing ownership here
        // would allow overlapping snapshots.
        task?.cancel()
    }

    private func performSync(createdAt: Date) async {
        guard let configuration, let sourceURL else { return }
        let directory = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("replica", isDirectory: true)
        let snapshotURL = directory.appendingPathComponent("upload.sqlite3")
        defer {
            if Task.isCancelled {
                // A short foreground visit is not a failed upload; the next
                // active visit may retry immediately after cleanup completes.
                defaults.removeObject(forKey: DefaultsKey.lastAttempt)
            }
        }
        do {
            let key = try WhoopReplicaCodec.key(from: configuration.encryptionKey)
            let prepared = try await WhoopReplicaSnapshotter.run {
                try WhoopReplicaCheckpoint.prepare(
                    sourceURL: sourceURL, snapshotURL: snapshotURL,
                    key: key,
                    scope: configuration.siteURL.absoluteString + "|" + sourceURL.path
                        + "|schema=\(WhoopStore.expectedSchemaVersion)",
                    createdAt: createdAt)
            }
            let snapshot = prepared.snapshot
            let manifest = prepared.manifest
            let descriptors = prepared.descriptors
            try Task.checkCancellation()
            let client = WhoopReplicaClient(
                siteURL: configuration.siteURL,
                uploadToken: configuration.uploadToken
            )
            let missing = try await client.missing(chunkIds: manifest.chunkIds)
            for descriptor in descriptors where missing.contains(descriptor.identifier) {
                try Task.checkCancellation()
                let encrypted = try await WhoopReplicaSnapshotter.run {
                    try WhoopReplicaSnapshotter.encryptedChunk(
                        snapshotURL: snapshot.url,
                        descriptor: descriptor,
                        key: key
                    )
                }
                try Task.checkCancellation()
                try await client.upload(
                    identifier: descriptor.identifier,
                    encrypted: encrypted,
                    createdAt: createdAt
                )
            }
            try Task.checkCancellation()
            try await client.commit(manifest: manifest)
            try WhoopReplicaCheckpoint.remove(at: snapshotURL)
            // A resumed snapshot may be old. Do not claim newer backup coverage
            // or defer the next fresh snapshot by six hours from this upload.
            defaults.set(
                Date(timeIntervalSince1970: Double(manifest.createdAt) / 1_000),
                forKey: DefaultsKey.lastSuccess)
            Self.logger.info(
                "Encrypted phone replica committed: \(manifest.sourceFingerprint.prefix(12), privacy: .public)"
            )
        } catch is CancellationError {
            Self.logger.info("Phone replica paused when foreground time ended")
        } catch {
            Self.logger.error("Phone replica failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Upload encrypted WHOOP replica"
        ) { [weak self] in
            Task { @MainActor in
                self?.prepareForBackground()
                self?.endBackgroundTask()
            }
        }
    }

    private func finish() {
        task = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
