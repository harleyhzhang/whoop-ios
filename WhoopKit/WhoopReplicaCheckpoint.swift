import CryptoKit
import Foundation

/// A completed, immutable local snapshot survives interrupted uploads. The
/// authenticated checkpoint is written last; partial preparation never resumes.
/// Every uploaded chunk still verifies its plaintext identifier before sealing.
enum WhoopReplicaCheckpoint {
    struct Prepared: Sendable {
        let snapshot: WhoopReplicaSnapshot
        let manifest: WhoopReplicaSnapshotManifest
        let descriptors: [WhoopReplicaChunkDescriptor]
    }
    private struct Checkpoint: Codable {
        let manifest: WhoopReplicaSnapshotManifest
        let descriptors: [WhoopReplicaChunkDescriptor]
        let modifiedAt: Date
    }

    static func prepare(
        sourceURL: URL, snapshotURL: URL, key: SymmetricKey,
        scope: String, createdAt: Date
    ) throws -> Prepared {
        try Task.checkCancellation()
        if let prepared = load(snapshotURL: snapshotURL, key: key, scope: scope) { return prepared }
        try remove(at: snapshotURL)
        var complete = false
        defer { if !complete { try? remove(at: snapshotURL) } }
        let snapshot = try WhoopReplicaSnapshotter.create(sourceURL: sourceURL, destinationURL: snapshotURL)
        let (manifest, descriptors) = try WhoopReplicaSnapshotter.describe(
            snapshot: snapshot, key: key, createdAt: createdAt)
        try Task.checkCancellation()
        let attributes = try snapshotURL.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modifiedAt = attributes.contentModificationDate else {
            throw WhoopReplicaSnapshotError.readFailed
        }
        let checkpoint = Checkpoint(manifest: manifest, descriptors: descriptors, modifiedAt: modifiedAt)
        let sealed = try AES.GCM.seal(
            JSONEncoder().encode(checkpoint), using: key,
            authenticating: Data(scope.utf8))
        guard let data = sealed.combined else { throw WhoopReplicaSnapshotError.readFailed }
        try data.write(
            to: checkpointURL(snapshotURL),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        complete = true
        return Prepared(snapshot: snapshot, manifest: manifest, descriptors: descriptors)
    }

    private static func load(snapshotURL: URL, key: SymmetricKey, scope: String) -> Prepared? {
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: checkpointURL(snapshotURL)))
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: Data(scope.utf8))
            let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: plaintext)
            let attributes = try snapshotURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = attributes.fileSize, Int64(size) == checkpoint.manifest.sourceBytes,
                attributes.contentModificationDate == checkpoint.modifiedAt
            else { return nil }
            return Prepared(
                snapshot: WhoopReplicaSnapshot(
                    url: snapshotURL,
                    schemaVersion: checkpoint.manifest.schemaVersion, sourceBytes: Int64(size)),
                manifest: checkpoint.manifest, descriptors: checkpoint.descriptors)
        } catch { return nil }
    }

    static func remove(at snapshotURL: URL) throws {
        // Remove the marker first so an interrupted cleanup cannot be resumed.
        let checkpoint = checkpointURL(snapshotURL)
        if FileManager.default.fileExists(atPath: checkpoint.path) {
            try FileManager.default.removeItem(at: checkpoint)
        }
        try WhoopReplicaSnapshotter.removeArtifacts(at: snapshotURL)
    }

    private static func checkpointURL(_ snapshotURL: URL) -> URL {
        snapshotURL.appendingPathExtension("checkpoint")
    }
}
