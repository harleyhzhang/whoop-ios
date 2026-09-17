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
    private var task: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private static let logger = Logger(
        subsystem: "com.clintonst.sideload.sleep",
        category: "WhoopReplica"
    )

    init(
        configuration: WhoopReplicaConfiguration? = .load(),
        sourceURL: URL? = WhoopStore.productionDatabaseURL(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.sourceURL = sourceURL
        self.defaults = defaults
        self.now = now
    }

    func requestSync(reason: WhoopReplicaReason) {
        guard task == nil, configuration != nil, sourceURL != nil else { return }
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

    private func performSync(createdAt: Date) async {
        guard let configuration, let sourceURL else { return }
        let directory = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("replica", isDirectory: true)
        let snapshotURL = directory.appendingPathComponent("upload.sqlite3")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try WhoopReplicaSnapshotter.create(
                    sourceURL: sourceURL,
                    destinationURL: snapshotURL
                )
            }.value
            let key = try WhoopReplicaCodec.key(from: configuration.encryptionKey)
            let (manifest, descriptors) = try await Task.detached(priority: .utility) {
                try WhoopReplicaSnapshotter.describe(
                    snapshot: snapshot,
                    key: key,
                    createdAt: createdAt
                )
            }.value
            let client = WhoopReplicaClient(
                siteURL: configuration.siteURL,
                uploadToken: configuration.uploadToken
            )
            let missing = try await client.missing(chunkIds: manifest.chunkIds)
            for descriptor in descriptors where missing.contains(descriptor.identifier) {
                let encrypted = try await Task.detached(priority: .utility) {
                    try WhoopReplicaSnapshotter.encryptedChunk(
                        snapshotURL: snapshot.url,
                        descriptor: descriptor,
                        key: key
                    )
                }.value
                try await client.upload(
                    identifier: descriptor.identifier,
                    encrypted: encrypted,
                    createdAt: createdAt
                )
            }
            try await client.commit(manifest: manifest)
            defaults.set(now(), forKey: DefaultsKey.lastSuccess)
            Self.logger.info(
                "Encrypted phone replica committed: \(manifest.sourceFingerprint.prefix(12), privacy: .public)"
            )
        } catch {
            Self.logger.error("Phone replica failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Upload encrypted WHOOP replica"
        ) { [weak self] in
            Task { @MainActor in self?.finish() }
        }
    }

    private func finish() {
        task?.cancel()
        task = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
