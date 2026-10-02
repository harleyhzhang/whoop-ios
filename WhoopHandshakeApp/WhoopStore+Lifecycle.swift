import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Database location, opening, snapshots, and pre-migration backups.
extension WhoopStore {
    static func databaseDirectory() -> URL? {
        let fileManager = FileManager.default
        guard
            let base = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else { return nil }
        let directory = base.appendingPathComponent("Sleep", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func productionDatabaseURL() -> URL? {
        databaseDirectory()?.appendingPathComponent("sleep.sqlite3")
    }

    func initializeDatabase(
        runBackgroundDecoding: Bool,
        permitsRetry: Bool,
        attempt: Int = 0
    ) {
        sqlite.storageState = .opening
        switch openDatabase() {
        case .success(let url):
            sqlite.storageState = .ready
            readiness.resolve(.success(url))
            if databaseURLOverride == nil {
                queue.asyncAfter(deadline: .now() + 2) { [self] in
                    performDeferredMaintenance(runBackgroundDecoding: runBackgroundDecoding)
                }
            } else {
                performDeferredMaintenance(runBackgroundDecoding: runBackgroundDecoding)
            }
        case .failure(let failure):
            guard permitsRetry,
                failure.isTransient,
                attempt + 1 < WhoopStorageRetryPolicy.maximumAttempts
            else {
                sqlite.storageState = .failed(failure)
                readiness.resolve(.failure(failure))
                Self.logger.fault("Storage initialization failed: \(failure.localizedDescription, privacy: .public)")
                return
            }
            let nextAttempt = attempt + 1
            sqlite.storageState = .retrying(attempt: nextAttempt, failure: failure)
            let delay = WhoopStorageRetryPolicy.delaySeconds(forAttempt: attempt)
            Self.logger.notice(
                "Retrying storage initialization attempt \(nextAttempt + 1) in \(delay, privacy: .public) seconds"
            )
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                initializeDatabase(
                    runBackgroundDecoding: runBackgroundDecoding,
                    permitsRetry: permitsRetry,
                    attempt: nextAttempt
                )
            }
        }
    }

    func performDeferredMaintenance(runBackgroundDecoding: Bool) {
        guard database != nil else { return }
        _ = execute("PRAGMA optimize")
        backfillHistoricalSamplesIfNeeded()
        if databaseURLOverride == nil {
            importBundledHistory()
            importBundledOfficialMetrics()
            backfillLocalSleepScoresIfNeeded()
            rebuildWakeAnchoredStepDaysIfNeeded()
            rebuildRecoveryMetricsIfNeeded()
        }
        if runBackgroundDecoding {
            backfillVersion26PPG()
            backfillVersion18Motion()
        }
    }

    func openDatabase() -> Result<URL, WhoopStorageFailure> {
        let signpost = WhoopRuntimeDiagnostics.signposter.beginInterval("StorageOpen")
        defer {
            WhoopRuntimeDiagnostics.signposter.endInterval("StorageOpen", signpost)
        }
        guard let url = databaseURL else {
            return .failure(
                .unavailable(operation: .open, detail: "Application Support is unavailable")
            )
        }
        if let injected = faultInjector.failure(for: .open) {
            return .failure(injected)
        }
        if databaseURLOverride != nil {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                return .failure(
                    .unavailable(operation: .open, detail: error.localizedDescription)
                )
            }
        }
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK else {
            let failure = WhoopStorageFailure.sqlite(
                operation: .open,
                database: database,
                resultCode: openResult
            )
            if let database { sqlite3_close(database) }
            database = nil
            return .failure(failure)
        }
        // Install the busy handler before changing journal mode. A prior
        // connection can have released its last Swift reference while SQLite
        // is still finishing WAL cleanup; without an early timeout, an
        // immediate reopen fails `PRAGMA journal_mode=WAL` with SQLITE_BUSY and
        // leaves the store permanently unavailable.
        guard let openedDatabase = database else {
            return .failure(
                .unavailable(operation: .open, detail: "SQLite returned no connection")
            )
        }
        sqlite3_extended_result_codes(openedDatabase, 1)
        let busyResult = sqlite3_busy_timeout(openedDatabase, 5_000)
        guard busyResult == SQLITE_OK else {
            let failure = WhoopStorageFailure.sqlite(
                operation: .configure,
                database: openedDatabase,
                resultCode: busyResult
            )
            if let database { sqlite3_close_v2(database) }
            database = nil
            return .failure(failure)
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        if let injected = faultInjector.failure(for: .configure) {
            if let database { sqlite3_close(database) }
            database = nil
            return .failure(injected)
        }
        for statement in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=FULL",
            "PRAGMA foreign_keys=ON",
            "PRAGMA wal_autocheckpoint=1000",
            "PRAGMA journal_size_limit=8388608",
        ] {
            let result = sqlite3_exec(openedDatabase, statement, nil, nil, nil)
            guard result == SQLITE_OK else {
                let failure = WhoopStorageFailure.sqlite(
                    operation: .configure,
                    database: openedDatabase,
                    resultCode: result
                )
                sqlite3_close_v2(openedDatabase)
                database = nil
                return .failure(failure)
            }
        }
        let versionBeforeMigration = try? scalarInt(openedDatabase, sql: "PRAGMA user_version")
        if let injected = faultInjector.failure(for: .migrate) {
            sqlite3_close_v2(openedDatabase)
            database = nil
            return .failure(injected)
        }
        guard
            createPreMigrationSnapshotIfNeeded(databaseURL: url),
            migrateSchema()
        else {
            let failure = WhoopStorageFailure.sqlite(
                operation: .migrate,
                database: openedDatabase,
                resultCode: sqlite3_errcode(openedDatabase)
            )
            if let database { sqlite3_close(database) }
            database = nil
            return .failure(failure)
        }
        if let versionBeforeMigration,
            versionBeforeMigration > 0,
            versionBeforeMigration < targetSchemaVersion
        {
            let retainedSnapshot = Self.migrationSnapshotURL(
                databaseURL: url,
                sourceVersion: versionBeforeMigration,
                targetVersion: Int64(targetSchemaVersion)
            )
            Self.pruneMigrationBackups(
                in: retainedSnapshot.deletingLastPathComponent(),
                keeping: retainedSnapshot
            )
        }
        nextDeliverySequence =
            ((try? scalarInt(
                openedDatabase,
                sql: """
                    SELECT MAX(value) FROM (
                        SELECT COALESCE(MAX(delivery_sequence), 0) AS value FROM whoop_raw_packet
                        UNION ALL
                        SELECT COALESCE(MAX(last_sequence), 0) FROM whoop_offload_session
                        UNION ALL
                        SELECT COALESCE(MAX(completion_sequence), 0) FROM whoop_offload_session
                    )
                    """)) ?? 0) + 1
        abandonInterruptedOffloads()
        recordTimeZoneObservation()
        // Injected database URLs are short-lived test fixtures. Avoid starting
        // an asynchronous census that could outlive a fixture directory.
        if databaseURLOverride == nil {
            storageTelemetry = WhoopStorageTelemetry(databaseURL: url, ownerQueue: queue)
            storageTelemetry?.captureIfDue()
        }
        return .success(url)
    }

    /// Creates a standalone, WAL-free snapshot before any non-empty schema
    /// upgrade. SQLite's online-backup API observes one consistent read
    /// transaction even while the source database has committed WAL pages.
    /// Migration fails closed if the snapshot cannot be completed.
    func createPreMigrationSnapshotIfNeeded(databaseURL: URL) -> Bool {
        guard let database,
            let current = try? scalarInt(database, sql: "PRAGMA user_version"),
            current > 0,
            current < targetSchemaVersion
        else { return true }

        let snapshotURL = Self.migrationSnapshotURL(
            databaseURL: databaseURL,
            sourceVersion: current,
            targetVersion: Int64(targetSchemaVersion)
        )
        let directory = snapshotURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        if Self.validSQLiteSnapshot(at: snapshotURL, expectedVersion: current) {
            return true
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try fileManager.removeItem(at: snapshotURL)
            }
        } catch {
            Self.logger.error(
                "Could not prepare migration backup directory: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let temporaryURL = directory.appendingPathComponent(".migration-backup-in-progress.sqlite3")
        Self.removeSQLiteFiles(at: temporaryURL, fileManager: fileManager)
        guard Self.copySQLiteDatabase(source: database, destinationURL: temporaryURL),
            Self.validSQLiteSnapshot(at: temporaryURL, expectedVersion: current)
        else {
            Self.removeSQLiteFiles(at: temporaryURL, fileManager: fileManager)
            Self.logger.error("Refusing schema migration because its SQLite snapshot failed validation")
            return false
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
            Self.removeSQLiteSidecars(at: temporaryURL, fileManager: fileManager)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: snapshotURL.path
            )
            return true
        } catch {
            Self.removeSQLiteFiles(at: temporaryURL, fileManager: fileManager)
            Self.logger.error("Could not finalize migration snapshot: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func removeSQLiteFiles(at url: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: url)
        removeSQLiteSidecars(at: url, fileManager: fileManager)
    }

    static func removeSQLiteSidecars(at url: URL, fileManager: FileManager) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? fileManager.removeItem(atPath: url.path + suffix)
        }
    }

    static func migrationSnapshotURL(
        databaseURL: URL,
        sourceVersion: Int64,
        targetVersion: Int64
    ) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent("migration-backups", isDirectory: true)
            .appendingPathComponent(
                "sleep-v\(sourceVersion)-before-v\(targetVersion).sqlite3"
            )
    }

    /// Keep the newly validated rollback point and remove only older snapshots
    /// created by this store. The current database and unrelated files are
    /// never candidates. Retaining one rollback image preserves fail-safe
    /// recovery without multiplying a phone-sized database on every upgrade.
    static func pruneMigrationBackups(
        in directory: URL,
        keeping retainedSnapshot: URL,
        fileManager: FileManager = .default
    ) {
        guard fileManager.fileExists(atPath: retainedSnapshot.path),
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return }

        for candidate in contents where candidate.standardizedFileURL != retainedSnapshot.standardizedFileURL {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("sleep-v"),
                name.contains("-before-v"),
                name.hasSuffix(".sqlite3")
            else { continue }
            removeSQLiteFiles(at: candidate, fileManager: fileManager)
        }
    }

    /// Internal for a focused WAL-consistency regression test.
    static func copySQLiteDatabase(source: OpaquePointer, destinationURL: URL) -> Bool {
        var destination: OpaquePointer?
        guard
            sqlite3_open_v2(
                destinationURL.path,
                &destination,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK, let destination
        else {
            if let destination { sqlite3_close(destination) }
            return false
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 5_000)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            return false
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { return false }
        // The source is WAL-backed, and that persistent journal setting is
        // copied with page 1. Convert the destination while it is still open
        // so the artifact can be restored as one standalone file.
        return sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK
    }

    static func validSQLiteSnapshot(at url: URL, expectedVersion: Int64) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var snapshot: OpaquePointer?
        guard sqlite3_open_v2(url.path, &snapshot, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let snapshot
        else {
            if let snapshot { sqlite3_close(snapshot) }
            return false
        }
        defer { sqlite3_close(snapshot) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                snapshot,
                "SELECT (SELECT user_version FROM pragma_user_version), (SELECT quick_check FROM pragma_quick_check)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            sqlite3_column_int64(statement, 0) == expectedVersion,
            let check = sqlite3_column_text(statement, 1)
        else { return false }
        return String(cString: check) == "ok"
    }
}
