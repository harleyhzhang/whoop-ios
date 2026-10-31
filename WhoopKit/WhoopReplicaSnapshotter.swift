import CryptoKit
import Foundation
import SQLite3

struct WhoopReplicaSnapshot: Sendable {
    let url: URL
    let schemaVersion: Int
    let sourceBytes: Int64
}

enum WhoopReplicaSnapshotError: Error {
    case openSource(Int32)
    case openDestination(Int32)
    case backupInitialization
    case backup(Int32)
    case invalidSnapshot
    case readFailed
}

enum WhoopReplicaSnapshotter {
    private static let artifactSuffixes = ["", "-wal", "-shm", "-journal"]

    /// Detached CPU work must still finish unwinding before its caller cleans
    /// up files or starts another replica. Cancellation propagates both ways.
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func removeArtifacts(at databaseURL: URL, fileManager: FileManager = .default) throws {
        for suffix in artifactSuffixes {
            let artifactURL = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: artifactURL.path) {
                try fileManager.removeItem(at: artifactURL)
            }
        }
    }

    static func create(
        sourceURL: URL, destinationURL: URL,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> WhoopReplicaSnapshot {
        try checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try removeArtifacts(at: destinationURL, fileManager: fileManager)
        var completed = false
        defer {
            if !completed { try? removeArtifacts(at: destinationURL, fileManager: fileManager) }
        }
        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceResult == SQLITE_OK, let source else {
            if let source { sqlite3_close(source) }
            throw WhoopReplicaSnapshotError.openSource(sourceResult)
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 10_000)
        // Keep one WAL read snapshot across bounded steps. Otherwise incoming
        // strap writes can restart the backup from page one indefinitely.
        guard sqlite3_exec(source, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK,
            scalarInt(source, sql: "PRAGMA user_version") != nil
        else { throw WhoopReplicaSnapshotError.backupInitialization }

        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw WhoopReplicaSnapshotError.openDestination(destinationResult)
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 10_000)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw WhoopReplicaSnapshotError.backupInitialization
        }
        var backupFinished = false
        defer {
            if !backupFinished { sqlite3_backup_finish(backup) }
        }
        var step: Int32
        repeat {
            try checkCancellation()
            step = sqlite3_backup_step(backup, 64)
        } while step == SQLITE_OK
        let finish = sqlite3_backup_finish(backup)
        backupFinished = true
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw WhoopReplicaSnapshotError.backup(step == SQLITE_DONE ? finish : step)
        }
        try checkCancellation()
        sqlite3_progress_handler(destination, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        let integrity = scalarText(destination, sql: "PRAGMA quick_check")
        try checkCancellation()
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK,
            let schemaVersion = scalarInt(destination, sql: "PRAGMA user_version"),
            integrity == "ok"
        else { throw WhoopReplicaSnapshotError.invalidSnapshot }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destinationURL.path
        )
        let bytes = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        completed = true
        return WhoopReplicaSnapshot(
            url: destinationURL,
            schemaVersion: Int(schemaVersion),
            sourceBytes: Int64(bytes)
        )
    }

    static func describe(
        snapshot: WhoopReplicaSnapshot,
        key: SymmetricKey,
        createdAt: Date
    ) throws -> (WhoopReplicaSnapshotManifest, [WhoopReplicaChunkDescriptor]) {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: snapshot.url)
        defer { try? handle.close() }
        var sourceAuthentication = HMAC<SHA256>(key: key)
        var descriptors: [WhoopReplicaChunkDescriptor] = []
        while true {
            try Task.checkCancellation()
            let index = descriptors.count
            // FileHandle returns autoreleased buffers, and a detached worker
            // never drains its pool mid-loop. Without a per-chunk pool the
            // whole snapshot stays resident until iOS jetsams the app.
            let descriptor = try autoreleasepool { () throws -> WhoopReplicaChunkDescriptor? in
                guard let plaintext = try handle.read(upToCount: WhoopReplicaCodec.chunkSize),
                    !plaintext.isEmpty
                else { return nil }
                sourceAuthentication.update(data: plaintext)
                return WhoopReplicaChunkDescriptor(
                    index: index,
                    identifier: WhoopReplicaCodec.chunkIdentifier(
                        key: key,
                        index: index,
                        plaintext: plaintext
                    ),
                    plainBytes: plaintext.count
                )
            }
            guard let descriptor else { break }
            descriptors.append(descriptor)
        }
        guard !descriptors.isEmpty else { throw WhoopReplicaSnapshotError.readFailed }
        let fingerprint = Data(sourceAuthentication.finalize()).hexEncoded
        return (
            WhoopReplicaSnapshotManifest(
                chunkIds: descriptors.map(\.identifier),
                chunkPlainBytes: descriptors.map(\.plainBytes),
                chunkSize: WhoopReplicaCodec.chunkSize,
                createdAt: Int64(createdAt.timeIntervalSince1970 * 1_000),
                schemaVersion: snapshot.schemaVersion,
                sourceBytes: snapshot.sourceBytes,
                sourceFingerprint: fingerprint
            ),
            descriptors
        )
    }

    static func encryptedChunk(
        snapshotURL: URL,
        descriptor: WhoopReplicaChunkDescriptor,
        key: SymmetricKey
    ) throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: snapshotURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(descriptor.index * WhoopReplicaCodec.chunkSize))
        guard let plaintext = try handle.read(upToCount: descriptor.plainBytes),
            plaintext.count == descriptor.plainBytes,
            WhoopReplicaCodec.chunkIdentifier(
                key: key,
                index: descriptor.index,
                plaintext: plaintext
            ) == descriptor.identifier
        else { throw WhoopReplicaSnapshotError.readFailed }
        return try WhoopReplicaCodec.encrypt(
            plaintext: plaintext,
            identifier: descriptor.identifier,
            key: key
        )
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String) -> Int64? {
        try? SQLiteRead.requiredInteger(database, sql: sql)
    }

    private static func scalarText(_ database: OpaquePointer, sql: String) -> String? {
        guard case .value(let value) = try? SQLiteRead.text(database, sql: sql) else { return nil }
        return value
    }
}

extension Data {
    fileprivate var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
