import Foundation
import SQLite3

enum WhoopReplicaRecovery {
    private static let databaseName = "sleep.sqlite3"
    private static let pendingName = "replica-restore.sqlite3"
    private static let rollbackName = "replica-restore-rollback.sqlite3"
    private static let markerName = "replica-restore-awaiting-health"

    static func applyPending() {
        guard let directory = WhoopStore.databaseDirectory() else { return }
        try? applyPending(in: directory, expectedSchema: WhoopStore.expectedSchemaVersion)
    }

    static func applyPending(in directory: URL, expectedSchema: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent(databaseName)
        let pending = directory.appendingPathComponent(pendingName)
        let rollback = directory.appendingPathComponent(rollbackName)
        let marker = directory.appendingPathComponent(markerName)

        if fileManager.fileExists(atPath: marker.path),
            fileManager.fileExists(atPath: rollback.path),
            !isValid(database, expectedSchema: expectedSchema)
        {
            removeDatabase(at: database)
            try moveDatabase(from: rollback, to: database)
            try? fileManager.removeItem(at: marker)
        }
        guard fileManager.fileExists(atPath: pending.path) else { return }
        guard isValid(pending, expectedSchema: expectedSchema) else {
            throw RecoveryError.invalidPendingDatabase
        }

        removeDatabase(at: rollback)
        if fileManager.fileExists(atPath: database.path) {
            try moveDatabase(from: database, to: rollback)
        }
        do {
            try fileManager.moveItem(at: pending, to: database)
            try? fileManager.removeItem(
                at: directory.appendingPathComponent(WhoopDeploymentHealthReporter.fileName)
            )
            try Data("pending\n".utf8).write(
                to: marker,
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
        } catch {
            if fileManager.fileExists(atPath: rollback.path),
                !fileManager.fileExists(atPath: database.path)
            {
                try? moveDatabase(from: rollback, to: database)
            }
            throw error
        }
    }

    static func finalizeIfHealthy(databaseURL: URL) {
        let directory = databaseURL.deletingLastPathComponent()
        let marker = directory.appendingPathComponent(markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        removeDatabase(at: directory.appendingPathComponent(rollbackName))
        try? FileManager.default.removeItem(at: marker)
    }

    private static func isValid(_ url: URL, expectedSchema: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        return scalarInt(database, sql: "PRAGMA user_version") == expectedSchema
            && scalarText(database, sql: "PRAGMA quick_check") == "ok"
            && rowCount(database, sql: "PRAGMA foreign_key_check") == 0
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : nil
    }

    private static func scalarText(_ database: OpaquePointer, sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: text)
    }

    private static func rowCount(_ database: OpaquePointer, sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var count = 0
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            count += 1
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? count : nil
    }

    private static func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        removeSidecars(at: url)
    }

    private static func moveDatabase(from source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sourceSidecar = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: sourceSidecar.path) else { continue }
            try FileManager.default.moveItem(
                at: sourceSidecar,
                to: URL(fileURLWithPath: destination.path + suffix)
            )
        }
    }

    private static func removeSidecars(at url: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    enum RecoveryError: Error {
        case invalidPendingDatabase
    }
}
