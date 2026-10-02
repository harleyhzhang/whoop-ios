import Compression
import CryptoKit
import SQLite3
import XCTest

@testable import Whoop

final class WhoopReplicaTests: XCTestCase {
    func testSyncPolicyThrottlesSuccessesAndFailures() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertTrue(
            WhoopReplicaSyncPolicy.shouldStart(
                reason: .launch,
                now: now,
                lastSuccess: nil,
                lastAttempt: nil
            )
        )
        XCTAssertFalse(
            WhoopReplicaSyncPolicy.shouldStart(
                reason: .dataChanged,
                now: now,
                lastSuccess: now.addingTimeInterval(-60 * 60),
                lastAttempt: nil
            )
        )
        XCTAssertTrue(
            WhoopReplicaSyncPolicy.shouldStart(
                reason: .sleepPublished,
                now: now,
                lastSuccess: now.addingTimeInterval(-61 * 60),
                lastAttempt: now.addingTimeInterval(-16 * 60)
            )
        )
        XCTAssertFalse(
            WhoopReplicaSyncPolicy.shouldStart(
                reason: .sleepPublished,
                now: now,
                lastSuccess: now.addingTimeInterval(-2 * 60 * 60),
                lastAttempt: now.addingTimeInterval(-14 * 60)
            )
        )
    }

    func testChunkIdentityMatchesCrossLanguageGoldenVector() throws {
        let keyData = Data(0..<32)
        let key = try WhoopReplicaCodec.key(from: keyData)

        XCTAssertEqual(
            WhoopReplicaCodec.chunkIdentifier(
                key: key,
                index: 7,
                plaintext: Data("synthetic-whoop-chunk".utf8)
            ),
            "25e1603876ebc069ac14d2f0fe5c8676a013388654cca3c36e8e731c63250b98"
        )
    }

    func testChunkEncryptionRoundTripsAndAuthenticatesIdentifier() throws {
        let key = try WhoopReplicaCodec.key(from: Data(0..<32))
        let plaintext = Data(repeating: 0x4A, count: 128 * 1024) + Data("tail".utf8)
        let identifier = WhoopReplicaCodec.chunkIdentifier(
            key: key,
            index: 0,
            plaintext: plaintext
        )

        let encrypted = try WhoopReplicaCodec.encrypt(
            plaintext: plaintext,
            identifier: identifier,
            key: key
        )

        XCTAssertLessThan(encrypted.count, plaintext.count)
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let compressed = try AES.GCM.open(
            box,
            using: key,
            authenticating: Data(identifier.utf8)
        )
        XCTAssertEqual(
            try decompress(compressed, expectedSize: plaintext.count),
            plaintext
        )
        XCTAssertThrowsError(
            try AES.GCM.open(
                box,
                using: key,
                authenticating: Data(String(repeating: "0", count: 64).utf8)
            )
        )
    }

    func testSnapshotIsStandaloneAndDescribedExactly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.sqlite3")
        let snapshotURL = directory.appendingPathComponent("snapshot.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(sourceURL.path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        XCTAssertEqual(sqlite3_exec(opened, "PRAGMA user_version = 10", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                opened,
                "CREATE TABLE sample(value TEXT NOT NULL); INSERT INTO sample VALUES ('private health data')",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(opened)

        let snapshot = try WhoopReplicaSnapshotter.create(
            sourceURL: sourceURL,
            destinationURL: snapshotURL
        )
        let key = try WhoopReplicaCodec.key(from: Data(0..<32))
        let (manifest, descriptors) = try WhoopReplicaSnapshotter.describe(
            snapshot: snapshot,
            key: key,
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertEqual(snapshot.schemaVersion, 10)
        XCTAssertEqual(manifest.sourceBytes, snapshot.sourceBytes)
        XCTAssertEqual(descriptors.map(\.plainBytes).reduce(0, +), Int(snapshot.sourceBytes))
        XCTAssertEqual(manifest.chunkIds, descriptors.map(\.identifier))
    }

    func testSnapshotArtifactCleanupRemovesDatabaseAndSQLiteSidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("upload.sqlite3")
        let artifactURLs = ["", "-wal", "-shm", "-journal"].map {
            URL(fileURLWithPath: snapshotURL.path + $0)
        }
        for artifactURL in artifactURLs {
            try Data("private snapshot bytes".utf8).write(to: artifactURL)
        }

        try WhoopReplicaSnapshotter.removeArtifacts(at: snapshotURL)

        for artifactURL in artifactURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        }
    }

    func testPendingRecoverySwapsOnlyAValidDatabaseAndRetainsRollbackUntilHealth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let pendingURL = directory.appendingPathComponent("replica-restore.sqlite3")
        try makeDatabase(at: databaseURL, value: "current")
        try makeDatabase(at: pendingURL, value: "recovered")

        try WhoopReplicaRecovery.applyPending(in: directory, expectedSchema: 10)

        XCTAssertEqual(try storedValue(at: databaseURL), "recovered")
        XCTAssertEqual(
            try storedValue(at: directory.appendingPathComponent("replica-restore-rollback.sqlite3")),
            "current"
        )
        WhoopReplicaRecovery.finalizeIfHealthy(databaseURL: databaseURL)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("replica-restore-rollback.sqlite3").path
            )
        )
    }

    func testPendingRecoveryRejectsWrongSchemaWithoutTouchingCurrentDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let pendingURL = directory.appendingPathComponent("replica-restore.sqlite3")
        try makeDatabase(at: databaseURL, value: "current")
        try makeDatabase(at: pendingURL, value: "wrong-schema", schema: 9)

        XCTAssertThrowsError(
            try WhoopReplicaRecovery.applyPending(in: directory, expectedSchema: 10)
        )
        XCTAssertEqual(try storedValue(at: databaseURL), "current")
    }

    private func makeDatabase(at url: URL, value: String, schema: Int = 10) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        XCTAssertEqual(sqlite3_exec(opened, "PRAGMA user_version = \(schema)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                opened,
                "CREATE TABLE sample(value TEXT NOT NULL); INSERT INTO sample VALUES ('\(value)')",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
    }

    private func storedValue(at url: URL) throws -> String {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(opened, "SELECT value FROM sample", -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        return String(cString: sqlite3_column_text(prepared, 0))
    }

    private func decompress(_ source: Data, expectedSize: Int) throws -> Data {
        var destination = Data(count: expectedSize)
        let written = destination.withUnsafeMutableBytes { destinationBuffer in
            source.withUnsafeBytes { sourceBuffer in
                guard
                    let destinationAddress = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let sourceAddress = sourceBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationAddress,
                    expectedSize,
                    sourceAddress,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw DecompressionError.failed }
        return destination
    }

    private enum DecompressionError: Error {
        case failed
    }
}
