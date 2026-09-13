import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Append-only local evidence store for direct WHOOP packets and derived samples.
/// Raw frames are retained so later protocol improvements never require another capture.
final class WhoopStore: Sendable, WhoopPacketPersisting {
    static let shared = WhoopStore()

    private let sqlite = SQLiteDatabase()
    private let dashboardReader = DashboardDatabaseReader()
    let readiness = WhoopStorageReadiness()
    private let databaseURLOverride: URL?
    private let databaseURL: URL?
    private let faultInjector: WhoopStorageFaultInjector
    private let targetSchemaVersion: Int
    private static let logger = Logger(subsystem: "com.clintonst.sideload.sleep", category: "WhoopStore")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let currentSchemaVersion = 10
    private static let decoderVersion = 3

    private var queue: DispatchQueue { sqlite.queue }
    private var database: OpaquePointer? {
        get { sqlite.connection }
        set { sqlite.connection = newValue }
    }
    private var cachedStatements: [String: OpaquePointer] {
        get { sqlite.cachedStatements }
        set { sqlite.cachedStatements = newValue }
    }
    private var pendingStepDateKeys: Set<String> {
        get { sqlite.pendingStepDateKeys }
        set { sqlite.pendingStepDateKeys = newValue }
    }
    private var cachedPublishedWakeBoundaries: [WhoopWakeBoundary]? {
        get { sqlite.publishedWakeBoundaries }
        set { sqlite.publishedWakeBoundaries = newValue }
    }
    private var storageTelemetry: WhoopStorageTelemetry? {
        get { sqlite.storageTelemetry }
        set { sqlite.storageTelemetry = newValue }
    }
    private var nextDeliverySequence: Int64 {
        get { sqlite.nextDeliverySequence }
        set { sqlite.nextDeliverySequence = newValue }
    }

    init(
        databaseURL: URL? = nil,
        runBackgroundDecoding: Bool = true,
        faultInjector: WhoopStorageFaultInjector = .none,
        targetSchemaVersion: Int? = nil
    ) {
        databaseURLOverride = databaseURL
        self.databaseURL =
            databaseURL
            ?? Self.databaseDirectory()?.appendingPathComponent("sleep.sqlite3")
        self.faultInjector = faultInjector
        self.targetSchemaVersion = min(
            max(1, targetSchemaVersion ?? Self.currentSchemaVersion),
            Self.currentSchemaVersion
        )
        if databaseURL != nil {
            queue.sync { [self] in
                initializeDatabase(
                    runBackgroundDecoding: runBackgroundDecoding,
                    permitsRetry: false
                )
            }
        } else {
            queue.async { [self] in
                initializeDatabase(
                    runBackgroundDecoding: runBackgroundDecoding,
                    permitsRetry: true
                )
            }
        }
    }

    deinit {
        // An async operation can own the store's final strong reference. In
        // that case ARC runs deinit on this queue, where sync would trap as a
        // self-deadlock. Every queued operation retains `self`, so once deinit
        // begins no other store work can still be pending or concurrent.
        if sqlite.isOnQueue {
            closeDatabase()
        } else {
            queue.sync { closeDatabase() }
        }
    }

    #if DEBUG
        /// Test fixtures own temporary database directories. Close the SQLite
        /// connection before a fixture removes that directory; relying on ARC's
        /// end-of-scope timing can unlink live WAL files on slower simulators.
        func shutdownForTesting() {
            if sqlite.isOnQueue {
                closeDatabase()
            } else {
                queue.sync { closeDatabase() }
            }
        }

        func ingestionTransactionCountForTesting() -> Int {
            if sqlite.isOnQueue { return sqlite.ingestionTransactionCount }
            return queue.sync { sqlite.ingestionTransactionCount }
        }

        func storageStateForTesting() -> WhoopStorageState {
            if sqlite.isOnQueue { return sqlite.storageState }
            return queue.sync { sqlite.storageState }
        }

        func blockWriterForTesting(
            started: DispatchSemaphore,
            release: DispatchSemaphore
        ) {
            queue.async {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
    #endif

    private func closeDatabase() {
        sqlite.close()
    }

    func append(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        frameType: FrameType?,
        realtime: WhoopDecodedRealtime?,
        historical: WhoopDecodedHistorical?,
        offloadSessionID: String? = nil,
        deduplicateTransportRetries: Bool = true,
        deliveredAt: Date = .now,
        completion: @escaping @Sendable (WhoopPacketPersistenceResult) -> Void
    ) {
        let bytes = [UInt8](packet)
        let integrityIsValid = frameType == nil ? false : WhoopFrameIntegrity.isValid(bytes)
        let envelope = WhoopPacketEnvelope(
            packet: packet,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            frameType: frameType,
            integrityIsValid: integrityIsValid,
            realtime: realtime,
            historical: historical,
            ppg: WhoopDecodedPPG.decode(bytes: bytes, integrityIsValid: integrityIsValid),
            metadata: WhoopHistoricalMetadata(
                bytes: bytes,
                frameType: frameType,
                integrityIsValid: integrityIsValid
            ),
            freshWristState: nil,
            offloadSessionID: offloadSessionID,
            deduplicateTransportRetries: deduplicateTransportRetries,
            deliveredAt: deliveredAt,
            proprietaryOrdinal: nil
        )
        appendBatch([envelope]) { result in
            completion(
                WhoopPacketPersistenceResult(
                    success: result.success,
                    deliverySequence: result.deliverySequences.first,
                    failure: result.failure
                ))
        }
    }

    /// Persists a FIFO packet slice in one SQLite transaction. A completion
    /// containing a chunk terminator proves that every earlier envelope in the
    /// slice committed before the caller can issue its destructive ACK.
    func appendBatch(
        _ envelopes: [WhoopPacketEnvelope],
        completion: @escaping @Sendable (WhoopPacketBatchPersistenceResult) -> Void
    ) {
        guard !envelopes.isEmpty else {
            completion(
                WhoopPacketBatchPersistenceResult(success: true, deliverySequences: [])
            )
            return
        }
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            let queueWait = DispatchTime.now().uptimeNanoseconds - enqueuedAt
            completion(insertBatch(envelopes, queueWaitNanoseconds: queueWait))
        }
    }

    func flushStorageTelemetry() {
        queue.async { [self] in storageTelemetry?.flush() }
    }

    func beginHistoricalOffload(
        peripheralID: UUID,
        startedAt: Date = .now,
        completion: @escaping @Sendable (Result<String, WhoopStorageFailure>) -> Void
    ) {
        queue.async { [self] in
            guard let database else {
                completion(
                    .failure(
                        .unavailable(
                            operation: .historicalOffload,
                            detail: "database connection is unavailable"
                        )
                    )
                )
                return
            }
            if let injected = faultInjector.failure(for: .historicalOffload) {
                completion(.failure(injected))
                return
            }
            let sessionID = UUID().uuidString
            let sql = """
                INSERT INTO whoop_offload_session
                (id, peripheral_id, started_at, status)
                VALUES (?, ?, ?, 'in_progress')
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                let statement
            else {
                completion(
                    .failure(
                        .sqlite(
                            operation: .historicalOffload,
                            database: database,
                            resultCode: sqlite3_errcode(database)
                        )
                    )
                )
                return
            }
            bind(sessionID, to: 1, in: statement)
            bind(peripheralID.uuidString, to: 2, in: statement)
            sqlite3_bind_double(statement, 3, startedAt.timeIntervalSince1970)
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            if result == SQLITE_DONE {
                completion(.success(sessionID))
            } else {
                completion(
                    .failure(
                        .sqlite(
                            operation: .historicalOffload,
                            database: database,
                            resultCode: result
                        )
                    )
                )
            }
        }
    }

    func abandonHistoricalOffload(_ sessionID: String, reason: String) {
        queue.async { [self] in
            guard let database else { return }
            let sql = """
                UPDATE whoop_offload_session
                SET status = 'abandoned', completed_at = ?, failure_reason = ?
                WHERE id = ? AND status = 'in_progress'
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                let statement
            else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            bind(reason, to: 2, in: statement)
            bind(sessionID, to: 3, in: statement)
            _ = sqlite3_step(statement)
        }
    }

    func refreshSleepSnapshot(
        now: Date = .now,
        allowAutomaticFinalization: Bool = false,
        completion: @escaping @Sendable (WhoopSleepSnapshot) -> Void
    ) {
        queue.async { [self] in
            completion(
                analyzeLatestSleep(
                    now: now,
                    allowAutomaticFinalization: allowAutomaticFinalization
                ))
        }
    }

    func loadDashboardHistory(
        completion: @escaping @Sendable (Result<DashboardHistorySnapshot, Error>) -> Void
    ) {
        readiness.whenResolved { [dashboardReader] result in
            switch result {
            case .success(let url):
                dashboardReader.loadSnapshot(at: url, completion: completion)
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    func loadDailyStepRecords(
        completion: @escaping @Sendable (Result<[DailyStepRecord], Error>) -> Void
    ) {
        readiness.whenResolved { [dashboardReader] result in
            switch result {
            case .success(let url):
                dashboardReader.loadStepRecords(at: url, completion: completion)
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    func loadDailyRecoveryRecords(
        completion: @escaping @Sendable (Result<[DailyRecoveryRecord], Error>) -> Void
    ) {
        readiness.whenResolved { [dashboardReader] result in
            switch result {
            case .success(let url):
                dashboardReader.loadRecoveryRecords(at: url, completion: completion)
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    func loadLatestHeartRateSample(
        completion: @escaping @Sendable (WhoopLatestHeartRateSample?) -> Void
    ) {
        queue.async { [self] in
            guard let database else {
                completion(nil)
                return
            }
            let sql = """
                SELECT heart_rate, received_at
                FROM whoop_latest_heart_rate
                WHERE singleton = 1
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                let statement
            else {
                completion(nil)
                return
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                completion(nil)
                return
            }
            completion(
                WhoopLatestHeartRateSample(
                    heartRate: Int(sqlite3_column_int(statement, 0)),
                    receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                )
            )
        }
    }

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

    private func initializeDatabase(
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

    private func performDeferredMaintenance(runBackgroundDecoding: Bool) {
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

    private func openDatabase() -> Result<URL, WhoopStorageFailure> {
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
    private func createPreMigrationSnapshotIfNeeded(databaseURL: URL) -> Bool {
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

    private static func removeSQLiteFiles(at url: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: url)
        removeSQLiteSidecars(at: url, fileManager: fileManager)
    }

    private static func removeSQLiteSidecars(at url: URL, fileManager: FileManager) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? fileManager.removeItem(atPath: url.path + suffix)
        }
    }

    private static func migrationSnapshotURL(
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

    private static func validSQLiteSnapshot(at url: URL, expectedVersion: Int64) -> Bool {
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

    private func migrateSchema() -> Bool {
        guard let database,
            let current = try? scalarInt(database, sql: "PRAGMA user_version"),
            current <= targetSchemaVersion
        else { return false }
        guard current < targetSchemaVersion else { return true }
        for version in (Int(current) + 1)...targetSchemaVersion {
            do {
                try withTransaction(.immediate) { database in
                    guard applyMigration(version), execute("PRAGMA user_version = \(version)") else {
                        throw StoreError.queryFailed(errorMessage(database))
                    }
                }
            } catch {
                return false
            }
        }
        return true
    }

    private func applyMigration(_ version: Int) -> Bool {
        switch version {
        case 1:
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_raw_packet (
                    id TEXT PRIMARY KEY,
                    received_at REAL NOT NULL,
                    peripheral_id TEXT NOT NULL,
                    characteristic_uuid TEXT NOT NULL,
                    frame_type INTEGER,
                    payload BLOB NOT NULL
                )
                """)
                && execute("CREATE INDEX IF NOT EXISTS whoop_raw_packet_received_at ON whoop_raw_packet(received_at)")
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS heart_rate_sample (
                        id TEXT PRIMARY KEY,
                        source_packet_id TEXT NOT NULL,
                        received_at REAL NOT NULL,
                        device_timestamp INTEGER,
                        heart_rate INTEGER NOT NULL,
                        rr_intervals_json TEXT NOT NULL,
                        source TEXT NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute("CREATE INDEX IF NOT EXISTS heart_rate_sample_received_at ON heart_rate_sample(received_at)")
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_historical_sample (
                        sample_at REAL PRIMARY KEY,
                        source_packet_id TEXT NOT NULL,
                        heart_rate INTEGER NOT NULL,
                        rr_intervals_json TEXT NOT NULL,
                        sleep_state INTEGER NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_historical_sample_sleep_state ON whoop_historical_sample(sleep_state, sample_at)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_packet_replay (
                        signature BLOB PRIMARY KEY,
                        first_packet_id TEXT NOT NULL,
                        duplicate_count INTEGER NOT NULL DEFAULT 0,
                        last_received_at REAL NOT NULL
                    )
                    """)
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS daily_health_metric (
                        date_key TEXT PRIMARY KEY,
                        sleep_score REAL,
                        sleep_duration_minutes REAL,
                        hrv_rmssd_milliseconds REAL,
                        resting_heart_rate_bpm REAL,
                        sleep_id TEXT,
                        cycle_id INTEGER,
                        source TEXT NOT NULL,
                        source_archive TEXT,
                        source_updated_at TEXT NOT NULL,
                        imported_at REAL NOT NULL
                    )
                    """)
        case 2:
            return addColumnIfNeeded(
                table: "whoop_raw_packet",
                column: "delivery_sequence",
                declaration: "INTEGER"
            )
                && addColumnIfNeeded(
                    table: "whoop_raw_packet",
                    column: "protocol_version",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_raw_packet",
                    column: "crc_valid",
                    declaration: "INTEGER"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_raw_packet_delivery_sequence ON whoop_raw_packet(delivery_sequence)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_decode_result (
                        source_packet_id TEXT NOT NULL,
                        decoder_version INTEGER NOT NULL,
                        protocol_version INTEGER,
                        stream TEXT NOT NULL,
                        status TEXT NOT NULL,
                        error TEXT,
                        decoded_at REAL NOT NULL,
                        PRIMARY KEY(source_packet_id, decoder_version),
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_decode_result_status ON whoop_decode_result(decoder_version, status)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_ppg_packet (
                        source_packet_id TEXT PRIMARY KEY,
                        sample_at REAL NOT NULL,
                        channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 255),
                        sample_rate_hz REAL NOT NULL,
                        samples_i16_le BLOB NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_ppg_packet_sample_at ON whoop_ppg_packet(sample_at, channel)")
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_store_metadata (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                    """)
        case 3:
            return addColumnIfNeeded(
                table: "whoop_raw_packet",
                column: "offload_session_id",
                declaration: "TEXT"
            )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_offload_session (
                        id TEXT PRIMARY KEY,
                        peripheral_id TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        completed_at REAL,
                        first_sequence INTEGER,
                        last_sequence INTEGER,
                        completion_sequence INTEGER,
                        completion_packet_id TEXT,
                        status TEXT NOT NULL CHECK(status IN ('in_progress','complete','abandoned')),
                        failure_reason TEXT,
                        FOREIGN KEY(completion_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_offload_session_status ON whoop_offload_session(status, completed_at)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_raw_packet_offload_session ON whoop_raw_packet(offload_session_id, delivery_sequence)"
                )
                && execute(
                    """
                    UPDATE whoop_offload_session
                    SET status = 'abandoned', completed_at = strftime('%s','now'),
                        failure_reason = 'app relaunched before completion'
                    WHERE status = 'in_progress'
                    """)
        case 4:
            return execute(
                """
                CREATE TABLE whoop_historical_sample_v4 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sample_at REAL NOT NULL,
                    source_packet_id TEXT NOT NULL UNIQUE,
                    peripheral_id TEXT NOT NULL,
                    protocol_version INTEGER NOT NULL,
                    ordinal INTEGER NOT NULL DEFAULT 0,
                    heart_rate INTEGER NOT NULL CHECK(heart_rate BETWEEN 0 AND 255),
                    rr_intervals_json TEXT NOT NULL,
                    sleep_state INTEGER NOT NULL CHECK(sleep_state BETWEEN 0 AND 3),
                    decoder_version INTEGER NOT NULL,
                    UNIQUE(peripheral_id, protocol_version, sample_at, ordinal),
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                )
                """)
                && execute(
                    """
                    INSERT INTO whoop_historical_sample_v4
                    (sample_at, source_packet_id, peripheral_id, protocol_version,
                     ordinal, heart_rate, rr_intervals_json, sleep_state, decoder_version)
                    SELECT h.sample_at, h.source_packet_id,
                           COALESCE(p.peripheral_id, 'legacy-unknown'),
                           COALESCE(p.protocol_version, 18), 0,
                           h.heart_rate, h.rr_intervals_json, h.sleep_state, 1
                    FROM whoop_historical_sample h
                    LEFT JOIN whoop_raw_packet p ON p.id = h.source_packet_id
                    """)
                && execute("DROP TABLE whoop_historical_sample")
                && execute("ALTER TABLE whoop_historical_sample_v4 RENAME TO whoop_historical_sample")
                && execute(
                    "CREATE INDEX whoop_historical_sample_sleep_state ON whoop_historical_sample(peripheral_id, sleep_state, sample_at)"
                )
                && execute(
                    "CREATE INDEX whoop_historical_sample_sample_at ON whoop_historical_sample(peripheral_id, sample_at)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS heart_rate_sample_source_time ON heart_rate_sample(source, device_timestamp, received_at)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS heart_rate_sample_source_received ON heart_rate_sample(source, received_at)"
                )
        case 5:
            return addColumnIfNeeded(
                table: "daily_health_metric", column: "sleep_start_at", declaration: "TEXT"
            )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_end_at", declaration: "TEXT"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_start_minute", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_end_minute", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_need_minutes", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_consistency_percentage", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_efficiency_percentage", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_sufficiency_percentage", declaration: "REAL"
                )
        case 6:
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_api_source_record (
                    date_key TEXT PRIMARY KEY,
                    sleep_payload_json TEXT NOT NULL,
                    recovery_payload_json TEXT,
                    source_archive TEXT,
                    imported_at REAL NOT NULL,
                    FOREIGN KEY(date_key) REFERENCES daily_health_metric(date_key)
                )
                """)
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_api_numeric_metric (
                        date_key TEXT NOT NULL,
                        source_kind TEXT NOT NULL CHECK(source_kind IN ('sleep','recovery')),
                        field_path TEXT NOT NULL,
                        value REAL NOT NULL,
                        PRIMARY KEY(date_key, source_kind, field_path),
                        FOREIGN KEY(date_key) REFERENCES whoop_api_source_record(date_key)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_api_numeric_metric_path ON whoop_api_numeric_metric(source_kind, field_path, date_key)"
                )
        case 7:
            // A travel-safe provenance timeline. Raw timestamps remain
            // absolute; this captures the local civil-time context needed to
            // reproduce timing consistency after the phone changes zones.
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_time_zone_observation (
                    observed_at REAL PRIMARY KEY,
                    time_zone_identifier TEXT NOT NULL,
                    utc_offset_seconds INTEGER NOT NULL
                )
                """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_time_zone_observation_zone ON whoop_time_zone_observation(time_zone_identifier, observed_at)"
                )
        case 8:
            // Version-18 packets already contain these candidate motion
            // fields. Materialize them without replacing their immutable raw
            // packet, then keep the UI-facing daily total in a separate table
            // with coverage and derivation provenance.
            return addColumnIfNeeded(
                table: "whoop_historical_sample",
                column: "step_motion_counter",
                declaration: "INTEGER"
            )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "step_cadence_raw",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "motion_class_raw",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "step_utc_offset_seconds",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "step_date_key",
                    declaration: "TEXT"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_historical_sample_step_day ON whoop_historical_sample(step_date_key, peripheral_id, sample_at)"
                )
                && execute(
                    """
                        CREATE TABLE IF NOT EXISTS whoop_daily_step_metric (
                            date_key TEXT PRIMARY KEY,
                            peripheral_id TEXT NOT NULL,
                            step_count INTEGER NOT NULL CHECK(step_count >= 0),
                            sample_count INTEGER NOT NULL CHECK(sample_count >= 0),
                            span_seconds INTEGER NOT NULL CHECK(span_seconds >= 0),
                            coverage_fraction REAL NOT NULL CHECK(coverage_fraction BETWEEN 0 AND 1),
                            gap_seconds INTEGER NOT NULL CHECK(gap_seconds >= 0),
                            counter_wrap_count INTEGER NOT NULL CHECK(counter_wrap_count >= 0),
                            rejected_delta_count INTEGER NOT NULL CHECK(rejected_delta_count >= 0),
                            first_sample_at REAL,
                            last_sample_at REAL,
                            source TEXT NOT NULL,
                            algorithm_version INTEGER NOT NULL,
                            derived_at REAL NOT NULL
                        )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_daily_step_metric_last_sample ON whoop_daily_step_metric(last_sample_at)"
                )
        case 9:
            // WHOOP cloud targets remain independent of local predictions so
            // every model version can be backtested without overwriting its
            // answer key. The UI reads a COALESCE projection only at query time.
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_official_daily_metric (
                    date_key TEXT PRIMARY KEY,
                    official_recovery_score REAL,
                    official_steps INTEGER,
                    official_day_strain REAL,
                    day_strain_target REAL,
                    steps_baseline REAL,
                    hrv REAL,
                    hrv_baseline REAL,
                    rhr REAL,
                    rhr_baseline REAL,
                    respiratory_rate REAL,
                    respiratory_rate_baseline REAL,
                    sleep_performance REAL,
                    sleep_performance_baseline REAL,
                    source_recovery_sha256 TEXT,
                    source_strain_sha256 TEXT,
                    source_archive TEXT NOT NULL,
                    source_manifest_sha256 TEXT NOT NULL,
                    imported_at REAL NOT NULL
                )
                """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_official_daily_recovery ON whoop_official_daily_metric(official_recovery_score, date_key)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_official_daily_steps ON whoop_official_daily_metric(official_steps, date_key)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_daily_recovery_metric (
                        date_key TEXT PRIMARY KEY,
                        score REAL NOT NULL CHECK(score BETWEEN 0 AND 100),
                        confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),
                        hrv_component REAL,
                        rhr_component REAL,
                        sleep_component REAL,
                        steps_component REAL,
                        hrv_baseline REAL,
                        rhr_baseline REAL,
                        sleep_baseline REAL,
                        steps_baseline REAL,
                        input_json TEXT NOT NULL,
                        model_version TEXT NOT NULL,
                        derived_at REAL NOT NULL,
                        FOREIGN KEY(date_key) REFERENCES daily_health_metric(date_key)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_daily_recovery_model ON whoop_daily_recovery_metric(model_version, date_key)"
                )
        case 10:
            // The raw packet remains the lossless evidence layer. Realtime
            // rows without R-R intervals are only a cache of data already in
            // that packet, so retain one latest-value projection and keep the
            // full indexed history only where it can contribute to HRV.
            return execute(
                """
                CREATE TABLE whoop_latest_heart_rate (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    heart_rate INTEGER NOT NULL CHECK(heart_rate > 0),
                    received_at REAL NOT NULL
                )
                """)
                && execute(
                    """
                    INSERT INTO whoop_latest_heart_rate(singleton, heart_rate, received_at)
                    SELECT 1, heart_rate, received_at
                    FROM heart_rate_sample
                    WHERE heart_rate > 0
                    ORDER BY received_at DESC
                    LIMIT 1
                    """)
                && execute(
                    """
                    CREATE TABLE heart_rate_sample_v10 (
                        source_packet_id TEXT PRIMARY KEY,
                        received_at REAL NOT NULL,
                        device_timestamp INTEGER,
                        heart_rate INTEGER NOT NULL,
                        rr_intervals_json TEXT NOT NULL CHECK(rr_intervals_json != '[]'),
                        source TEXT NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    """
                    INSERT INTO heart_rate_sample_v10
                    (source_packet_id, received_at, device_timestamp,
                     heart_rate, rr_intervals_json, source)
                    SELECT source_packet_id, received_at, device_timestamp,
                           heart_rate, rr_intervals_json, source
                    FROM heart_rate_sample
                    WHERE rr_intervals_json != '[]'
                    """)
                && execute("DROP TABLE heart_rate_sample")
                && execute("ALTER TABLE heart_rate_sample_v10 RENAME TO heart_rate_sample")
                && execute(
                    "CREATE INDEX heart_rate_sample_source_time ON heart_rate_sample(source, device_timestamp, received_at)"
                )
                && execute(
                    "CREATE INDEX heart_rate_sample_source_received ON heart_rate_sample(source, received_at)"
                )
                && addColumnIfNeeded(
                    table: "whoop_ppg_packet",
                    column: "decoder_version",
                    declaration: "INTEGER NOT NULL DEFAULT 2"
                )
                && execute(
                    """
                    CREATE TABLE whoop_decode_failure (
                        source_packet_id TEXT NOT NULL,
                        decoder_version INTEGER NOT NULL,
                        protocol_version INTEGER,
                        stream TEXT NOT NULL,
                        status TEXT NOT NULL CHECK(status IN ('unsupported','rejected')),
                        error TEXT,
                        decoded_at REAL NOT NULL,
                        PRIMARY KEY(source_packet_id, decoder_version),
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    """
                    INSERT INTO whoop_decode_failure
                    (source_packet_id, decoder_version, protocol_version,
                     stream, status, error, decoded_at)
                    SELECT source_packet_id, decoder_version, protocol_version,
                           stream, status, error, decoded_at
                    FROM whoop_decode_result
                    WHERE status != 'decoded'
                    """)
                && execute("DROP TABLE whoop_decode_result")
        default:
            return false
        }
    }

    private func recordTimeZoneObservation(now: Date = .now) {
        guard let database else { return }
        let sql = """
            INSERT OR IGNORE INTO whoop_time_zone_observation
            (observed_at, time_zone_identifier, utc_offset_seconds)
            VALUES (?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        defer { sqlite3_finalize(statement) }
        let zone = TimeZone.autoupdatingCurrent
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        bind(zone.identifier, to: 2, in: statement)
        sqlite3_bind_int(statement, 3, Int32(zone.secondsFromGMT(for: now)))
        _ = sqlite3_step(statement)
    }

    private func nearestRecordedUTCOffset(database: OpaquePointer, sampleAt: Date) -> Int {
        let sql = """
            SELECT utc_offset_seconds
            FROM whoop_time_zone_observation
            ORDER BY ABS(observed_at - ?)
            LIMIT 1
            """
        let storedOffset: Int? =
            withCachedStatement(database: database, sql: sql) { statement in
                sqlite3_bind_double(statement, 1, sampleAt.timeIntervalSince1970)
                if sqlite3_step(statement) == SQLITE_ROW {
                    return Int(sqlite3_column_int(statement, 0))
                }
                return nil
            } ?? nil
        if let storedOffset { return storedOffset }
        return TimeZone.autoupdatingCurrent.secondsFromGMT(for: sampleAt)
    }

    static func dateKey(for date: Date, utcOffsetSeconds: Int) -> String {
        DayKey.string(
            from: date,
            timeZone: TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private func publishedWakeBoundaries(database: OpaquePointer) -> [WhoopWakeBoundary] {
        if let cachedPublishedWakeBoundaries { return cachedPublishedWakeBoundaries }
        let sql = """
            SELECT date_key, sleep_end_at
            FROM daily_health_metric
            WHERE sleep_end_at IS NOT NULL
            ORDER BY date_key ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var boundaries: [WhoopWakeBoundary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawDateKey = textColumn(statement, 0),
                let dateKey = DayKey(rawValue: rawDateKey),
                let rawWake = textColumn(statement, 1),
                let wokeAt = Self.parseISO8601(rawWake)
            else { continue }
            boundaries.append(WhoopWakeBoundary(dateKey: dateKey, wokeAt: wokeAt))
        }
        let sorted = boundaries.sorted { $0.wokeAt < $1.wokeAt }
        cachedPublishedWakeBoundaries = sorted
        return sorted
    }

    private func physiologicalStepDateKey(
        for sampleAt: Date,
        utcOffsetSeconds: Int,
        database: OpaquePointer
    ) -> String {
        let fallback = DayKey(
            date: sampleAt,
            timeZone: TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        )
        return WhoopPhysiologicalDay.dateKey(
            for: sampleAt,
            publishedWakes: publishedWakeBoundaries(database: database),
            civilFallback: fallback
        ).rawValue
    }

    private func addColumnIfNeeded(
        table: String,
        column: String,
        declaration: String
    ) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if textColumn(statement, 1) == column { return true }
        }
        return execute("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
    }

    private func importBundledHistory() {
        guard let database,
            let url = Bundle.main.url(forResource: "whoop-history", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let records = try? JSONDecoder().decode([DailyHealthRecord].self, from: data)
        else { return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard metadataValue(database: database, key: "bundled-history-sha256") != digest else {
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for record in records where !upsertDailyHealthRecord(record, database: database) {
            execute("ROLLBACK")
            return
        }
        guard
            setMetadataValue(
                database: database,
                key: "bundled-history-sha256",
                value: digest
            )
        else {
            execute("ROLLBACK")
            return
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
    }

    /// Imports only the stable daily projection into the hot database while
    /// installing a compact, checksum-verified sidecar containing every exact
    /// official-app response. This keeps launch queries small without throwing
    /// away fields that a future model may need.
    private func importBundledOfficialMetrics() {
        guard let database,
            let metricsURL = Bundle.main.url(
                forResource: "whoop-official-metrics", withExtension: "json"
            ),
            let metricsData = try? Data(contentsOf: metricsURL),
            let seed = try? JSONDecoder().decode(OfficialMetricsSeed.self, from: metricsData),
            seed.formatVersion == 1
        else { return }
        let digest = SHA256.hash(data: metricsData).map { String(format: "%02x", $0) }.joined()
        if metadataValue(database: database, key: "bundled-official-metrics-sha256") == digest {
            if let directory = Self.databaseDirectory(),
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("whoop-official-archive.sqlite3").path
                )
            {
                _ = installBundledOfficialArchive(expectedSHA256: seed.sourceDatabaseSHA256)
            }
            return
        }
        guard installBundledOfficialArchive(expectedSHA256: seed.sourceDatabaseSHA256) else {
            Self.logger.error("Refusing official metric import because its complete raw sidecar is unavailable")
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for record in seed.daily
        where !upsertOfficialDailyMetric(
            record,
            sourceArchive: seed.sourceArchive,
            sourceManifestSHA256: seed.sourceManifestSHA256,
            database: database
        ) {
            execute("ROLLBACK")
            return
        }
        guard
            setMetadataValue(
                database: database,
                key: "bundled-official-metrics-sha256",
                value: digest
            ),
            setMetadataValue(
                database: database,
                key: "bundled-official-archive-sha256",
                value: seed.sourceDatabaseSHA256
            )
        else {
            execute("ROLLBACK")
            return
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
    }

    private func installBundledOfficialArchive(expectedSHA256: String) -> Bool {
        guard
            let source = Bundle.main.url(
                forResource: "whoop-official-archive", withExtension: "sqlite3"
            ), let directory = Self.databaseDirectory()
        else { return false }
        let destination = directory.appendingPathComponent("whoop-official-archive.sqlite3")
        let fileManager = FileManager.default

        func fileDigest(_ url: URL) -> String? {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        if fileManager.fileExists(atPath: destination.path),
            fileDigest(destination) == expectedSHA256
        {
            return true
        }

        let temporary = directory.appendingPathComponent(".whoop-official-archive-installing.sqlite3")
        try? fileManager.removeItem(at: temporary)
        do {
            try fileManager.copyItem(at: source, to: temporary)
            guard fileDigest(temporary) == expectedSHA256 else {
                try? fileManager.removeItem(at: temporary)
                return false
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            return true
        } catch {
            try? fileManager.removeItem(at: temporary)
            Self.logger.error(
                "Could not install official response archive: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func upsertOfficialDailyMetric(
        _ record: OfficialDailyMetricSeed,
        sourceArchive: String,
        sourceManifestSHA256: String,
        database: OpaquePointer
    ) -> Bool {
        guard DayKey(rawValue: record.dateKey) != nil else { return false }
        let sql = """
            INSERT INTO whoop_official_daily_metric
            (date_key, official_recovery_score, official_steps, official_day_strain,
             day_strain_target, steps_baseline, hrv, hrv_baseline, rhr, rhr_baseline,
             respiratory_rate, respiratory_rate_baseline, sleep_performance,
             sleep_performance_baseline, source_recovery_sha256, source_strain_sha256,
             source_archive, source_manifest_sha256, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                official_recovery_score = excluded.official_recovery_score,
                official_steps = excluded.official_steps,
                official_day_strain = excluded.official_day_strain,
                day_strain_target = excluded.day_strain_target,
                steps_baseline = excluded.steps_baseline,
                hrv = excluded.hrv, hrv_baseline = excluded.hrv_baseline,
                rhr = excluded.rhr, rhr_baseline = excluded.rhr_baseline,
                respiratory_rate = excluded.respiratory_rate,
                respiratory_rate_baseline = excluded.respiratory_rate_baseline,
                sleep_performance = excluded.sleep_performance,
                sleep_performance_baseline = excluded.sleep_performance_baseline,
                source_recovery_sha256 = excluded.source_recovery_sha256,
                source_strain_sha256 = excluded.source_strain_sha256,
                source_archive = excluded.source_archive,
                source_manifest_sha256 = excluded.source_manifest_sha256,
                imported_at = excluded.imported_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.dateKey, to: 1, in: statement)
        bind(record.officialRecoveryScore, to: 2, in: statement)
        bind(record.officialSteps.map(Int64.init), to: 3, in: statement)
        bind(record.officialDayStrain, to: 4, in: statement)
        bind(record.dayStrainTarget, to: 5, in: statement)
        bind(record.stepsBaseline, to: 6, in: statement)
        bind(record.hrv, to: 7, in: statement)
        bind(record.hrvBaseline, to: 8, in: statement)
        bind(record.rhr, to: 9, in: statement)
        bind(record.rhrBaseline, to: 10, in: statement)
        bind(record.respiratoryRate, to: 11, in: statement)
        bind(record.respiratoryRateBaseline, to: 12, in: statement)
        bind(record.sleepPerformance, to: 13, in: statement)
        bind(record.sleepPerformanceBaseline, to: 14, in: statement)
        bind(record.sourceRecoverySHA256, to: 15, in: statement)
        bind(record.sourceStrainSHA256, to: 16, in: statement)
        bind(sourceArchive, to: 17, in: statement)
        bind(sourceManifestSHA256, to: 18, in: statement)
        sqlite3_bind_double(statement, 19, Date().timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func upsertDailyHealthRecord(_ record: DailyHealthRecord, database: OpaquePointer) -> Bool {
        guard DayKey(rawValue: record.dateKey) != nil else { return false }
        let sql = """
            INSERT INTO daily_health_metric
            (date_key, sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
             resting_heart_rate_bpm, sleep_id, cycle_id, source, source_archive,
             source_updated_at, imported_at, sleep_start_at, sleep_end_at,
             sleep_start_minute, sleep_end_minute, sleep_need_minutes,
             sleep_consistency_percentage, sleep_efficiency_percentage,
             sleep_sufficiency_percentage)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                sleep_score = excluded.sleep_score,
                sleep_duration_minutes = excluded.sleep_duration_minutes,
                hrv_rmssd_milliseconds = excluded.hrv_rmssd_milliseconds,
                resting_heart_rate_bpm = excluded.resting_heart_rate_bpm,
                sleep_id = excluded.sleep_id,
                cycle_id = excluded.cycle_id,
                source = excluded.source,
                source_archive = excluded.source_archive,
                source_updated_at = excluded.source_updated_at,
                imported_at = excluded.imported_at,
                sleep_start_at = excluded.sleep_start_at,
                sleep_end_at = excluded.sleep_end_at,
                sleep_start_minute = excluded.sleep_start_minute,
                sleep_end_minute = excluded.sleep_end_minute,
                sleep_need_minutes = excluded.sleep_need_minutes,
                sleep_consistency_percentage = excluded.sleep_consistency_percentage,
                sleep_efficiency_percentage = excluded.sleep_efficiency_percentage,
                sleep_sufficiency_percentage = excluded.sleep_sufficiency_percentage
            WHERE daily_health_metric.source = 'whoop_api'
              AND excluded.source_updated_at >= daily_health_metric.source_updated_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.dateKey, to: 1, in: statement)
        bind(record.sleepScore, to: 2, in: statement)
        bind(record.sleepDurationMinutes, to: 3, in: statement)
        bind(record.hrvRMSSDMilliseconds, to: 4, in: statement)
        bind(record.restingHeartRateBPM, to: 5, in: statement)
        bind(record.sleepID, to: 6, in: statement)
        bind(record.cycleID, to: 7, in: statement)
        bind(record.source, to: 8, in: statement)
        bind(record.sourceArchive, to: 9, in: statement)
        bind(record.sourceUpdatedAt, to: 10, in: statement)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        bind(record.sleepStartAt, to: 12, in: statement)
        bind(record.sleepEndAt, to: 13, in: statement)
        bind(record.sleepStartMinute, to: 14, in: statement)
        bind(record.sleepEndMinute, to: 15, in: statement)
        bind(record.sleepNeedMinutes, to: 16, in: statement)
        bind(record.sleepConsistencyPercentage, to: 17, in: statement)
        bind(record.sleepEfficiencyPercentage, to: 18, in: statement)
        bind(record.sleepSufficiencyPercentage, to: 19, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        cachedPublishedWakeBoundaries = nil
        if record.source == "whoop_api", let sleepJSON = record.sourceSleepPayloadJSON {
            return upsertWhoopAPISource(
                dateKey: record.dateKey,
                sleepJSON: sleepJSON,
                recoveryJSON: record.sourceRecoveryPayloadJSON,
                sourceArchive: record.sourceArchive,
                database: database
            )
        }
        return true
    }

    private func upsertWhoopAPISource(
        dateKey: String,
        sleepJSON: String,
        recoveryJSON: String?,
        sourceArchive: String?,
        database: OpaquePointer
    ) -> Bool {
        let sourceSQL = """
            INSERT INTO whoop_api_source_record
            (date_key, sleep_payload_json, recovery_payload_json, source_archive, imported_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                sleep_payload_json = excluded.sleep_payload_json,
                recovery_payload_json = excluded.recovery_payload_json,
                source_archive = excluded.source_archive,
                imported_at = excluded.imported_at
            """
        var sourceStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sourceSQL, -1, &sourceStatement, nil) == SQLITE_OK,
            let sourceStatement
        else { return false }
        bind(dateKey, to: 1, in: sourceStatement)
        bind(sleepJSON, to: 2, in: sourceStatement)
        bind(recoveryJSON, to: 3, in: sourceStatement)
        bind(sourceArchive, to: 4, in: sourceStatement)
        sqlite3_bind_double(sourceStatement, 5, Date().timeIntervalSince1970)
        let sourceSucceeded = sqlite3_step(sourceStatement) == SQLITE_DONE
        sqlite3_finalize(sourceStatement)
        guard sourceSucceeded else { return false }

        var deleteStatement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "DELETE FROM whoop_api_numeric_metric WHERE date_key = ?",
                -1,
                &deleteStatement,
                nil
            ) == SQLITE_OK, let deleteStatement
        else { return false }
        bind(dateKey, to: 1, in: deleteStatement)
        let deleteSucceeded = sqlite3_step(deleteStatement) == SQLITE_DONE
        sqlite3_finalize(deleteStatement)
        guard deleteSucceeded else { return false }

        let metricSQL = """
            INSERT INTO whoop_api_numeric_metric
            (date_key, source_kind, field_path, value) VALUES (?, ?, ?, ?)
            """
        var metricStatement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, metricSQL, -1, &metricStatement, nil
            ) == SQLITE_OK, let metricStatement
        else { return false }
        defer { sqlite3_finalize(metricStatement) }

        for (kind, payload) in [("sleep", sleepJSON), ("recovery", recoveryJSON)] {
            guard let payload,
                let data = payload.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            var metrics: [(String, Double)] = []
            Self.flattenNumericJSON(object, path: "", into: &metrics)
            for (path, value) in metrics where !path.isEmpty {
                bind(dateKey, to: 1, in: metricStatement)
                bind(kind, to: 2, in: metricStatement)
                bind(path, to: 3, in: metricStatement)
                sqlite3_bind_double(metricStatement, 4, value)
                let succeeded = sqlite3_step(metricStatement) == SQLITE_DONE
                guard succeeded else { return false }
                sqlite3_reset(metricStatement)
                sqlite3_clear_bindings(metricStatement)
            }
        }
        return true
    }

    private static func flattenNumericJSON(
        _ value: Any,
        path: String,
        into output: inout [(String, Double)]
    ) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if let child = dictionary[key] {
                    flattenNumericJSON(child, path: childPath, into: &output)
                }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                flattenNumericJSON(child, path: "\(path)[\(index)]", into: &output)
            }
        } else if let number = value as? NSNumber {
            output.append((path, number.doubleValue))
        }
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let database else { return false }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result != SQLITE_OK {
            Self.logger.error("SQLite operation failed (\(result)): \(self.errorMessage(database), privacy: .public)")
        }
        return result == SQLITE_OK
    }

    private enum TransactionMode {
        case deferred
        case immediate

        var beginSQL: String {
            switch self {
            case .deferred: "BEGIN DEFERRED"
            case .immediate: "BEGIN IMMEDIATE"
            }
        }
    }

    private func withTransaction<Value>(
        _ mode: TransactionMode,
        _ operation: (OpaquePointer) throws -> Value
    ) throws -> Value {
        guard let database else { throw StoreError.databaseUnavailable }
        guard execute(mode.beginSQL) else {
            throw StoreError.queryFailed(errorMessage(database))
        }
        do {
            let value = try operation(database)
            guard execute("COMMIT") else {
                throw StoreError.queryFailed(errorMessage(database))
            }
            return value
        } catch {
            _ = execute("ROLLBACK")
            throw error
        }
    }

    /// Cached statements are always returned to a reset, binding-free state,
    /// including when a caller exits while a SELECT is positioned on a row.
    private func withCachedStatement<Value>(
        database: OpaquePointer,
        sql: String,
        _ operation: (OpaquePointer) -> Value
    ) -> Value? {
        guard let statement = cachedStatement(database: database, sql: sql) else { return nil }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        return operation(statement)
    }

    /// Returns a reset, binding-free prepared statement owned by the store.
    /// Only use this for hot paths that cannot be re-entered before the caller
    /// steps the statement; the serial store queue enforces that invariant.
    private func cachedStatement(database: OpaquePointer, sql: String) -> OpaquePointer? {
        if let statement = cachedStatements[sql] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            Self.logger.error("SQLite prepare failed: \(self.errorMessage(database), privacy: .public)")
            return nil
        }
        cachedStatements[sql] = statement
        return statement
    }

    private func insertBatch(
        _ envelopes: [WhoopPacketEnvelope],
        queueWaitNanoseconds: UInt64
    ) -> WhoopPacketBatchPersistenceResult {
        let signpost = WhoopRuntimeDiagnostics.signposter.beginInterval("PacketBatchCommit")
        defer {
            WhoopRuntimeDiagnostics.signposter.endInterval("PacketBatchCommit", signpost)
        }
        let telemetryStartedAt = DispatchTime.now().uptimeNanoseconds
        guard let database else {
            recordBatchTelemetry(
                envelopes: envelopes,
                outcomes: Array(repeating: .failed, count: envelopes.count),
                transactionNanoseconds: DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                queueWaitNanoseconds: queueWaitNanoseconds
            )
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: .unavailable(
                    operation: .beginTransaction,
                    detail: "database connection is unavailable"
                )
            )
        }
        if let injected = faultInjector.failure(for: .beginTransaction) {
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: injected
            )
        }
        let beginResult = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
        guard beginResult == SQLITE_OK else {
            recordBatchTelemetry(
                envelopes: envelopes,
                outcomes: Array(repeating: .failed, count: envelopes.count),
                transactionNanoseconds: DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                queueWaitNanoseconds: queueWaitNanoseconds
            )
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: .sqlite(
                    operation: .beginTransaction,
                    database: database,
                    resultCode: beginResult
                )
            )
        }
        #if DEBUG
            sqlite.ingestionTransactionCount += 1
        #endif
        let pendingStepDaysBeforeTransaction = pendingStepDateKeys
        var outcomes: [WhoopIngestionTelemetryOutcome] = []
        outcomes.reserveCapacity(envelopes.count)
        var deliverySequences: [Int64] = []
        deliverySequences.reserveCapacity(envelopes.count)
        var materializedStepDays: Set<String> = []

        for envelope in envelopes {
            if let injected = faultInjector.failure(for: .insert) {
                _ = execute("ROLLBACK")
                pendingStepDateKeys = pendingStepDaysBeforeTransaction
                recordBatchTelemetry(
                    envelopes: envelopes,
                    outcomes: Array(repeating: .failed, count: envelopes.count),
                    transactionNanoseconds:
                        DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                    queueWaitNanoseconds: queueWaitNanoseconds
                )
                return WhoopPacketBatchPersistenceResult(
                    success: false,
                    deliverySequences: [],
                    failure: injected
                )
            }
            guard
                let insertion = insertInOpenTransaction(
                    envelope,
                    database: database
                )
            else {
                _ = execute("ROLLBACK")
                pendingStepDateKeys = pendingStepDaysBeforeTransaction
                recordBatchTelemetry(
                    envelopes: envelopes,
                    outcomes: Array(repeating: .failed, count: envelopes.count),
                    transactionNanoseconds:
                        DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                    queueWaitNanoseconds: queueWaitNanoseconds
                )
                return WhoopPacketBatchPersistenceResult(
                    success: false,
                    deliverySequences: [],
                    failure: .sqlite(
                        operation: .insert,
                        database: database,
                        resultCode: sqlite3_errcode(database)
                    )
                )
            }
            outcomes.append(insertion.outcome)
            deliverySequences.append(insertion.deliverySequence)
            materializedStepDays.formUnion(insertion.materializedStepDays)
        }
        if let injected = faultInjector.failure(for: .commit) {
            _ = execute("ROLLBACK")
            pendingStepDateKeys = pendingStepDaysBeforeTransaction
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: injected
            )
        }
        let commitResult = sqlite3_exec(database, "COMMIT", nil, nil, nil)
        guard commitResult == SQLITE_OK else {
            _ = execute("ROLLBACK")
            pendingStepDateKeys = pendingStepDaysBeforeTransaction
            recordBatchTelemetry(
                envelopes: envelopes,
                outcomes: Array(repeating: .failed, count: envelopes.count),
                transactionNanoseconds: DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                queueWaitNanoseconds: queueWaitNanoseconds
            )
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: .sqlite(
                    operation: .commit,
                    database: database,
                    resultCode: commitResult
                )
            )
        }
        let telemetryFinishedAt = DispatchTime.now().uptimeNanoseconds
        finishCommittedStepMaterialization(materializedStepDays)
        recordBatchTelemetry(
            envelopes: envelopes,
            outcomes: outcomes,
            transactionNanoseconds: telemetryFinishedAt - telemetryStartedAt,
            queueWaitNanoseconds: queueWaitNanoseconds
        )
        return WhoopPacketBatchPersistenceResult(
            success: true,
            deliverySequences: deliverySequences
        )
    }

    private func recordBatchTelemetry(
        envelopes: [WhoopPacketEnvelope],
        outcomes: [WhoopIngestionTelemetryOutcome],
        transactionNanoseconds: UInt64,
        queueWaitNanoseconds: UInt64
    ) {
        guard storageTelemetry != nil, !envelopes.isEmpty else { return }
        let perEnvelopeTransaction = transactionNanoseconds / UInt64(envelopes.count)
        for (envelope, outcome) in zip(envelopes, outcomes) {
            storageTelemetry?.recordIngestion(
                outcome: outcome,
                transactionNanoseconds: perEnvelopeTransaction,
                queueWaitNanoseconds: queueWaitNanoseconds,
                frameType: envelope.frameType,
                payloadBytes: envelope.packet.count,
                retryDetectionEnabled: envelope.deduplicateTransportRetries,
                now: envelope.deliveredAt
            )
        }
    }

    private struct OpenTransactionInsertion {
        let deliverySequence: Int64
        let outcome: WhoopIngestionTelemetryOutcome
        let materializedStepDays: Set<String>
    }

    private func insertInOpenTransaction(
        _ envelope: WhoopPacketEnvelope,
        database: OpaquePointer
    ) -> OpenTransactionInsertion? {
        let packet = envelope.packet
        let deliveredAt = envelope.deliveredAt
        let deliverySequence = nextDeliverySequence
        nextDeliverySequence += 1
        let packetID = "p" + String(deliverySequence, radix: 36)
        let receivedAt = deliveredAt.timeIntervalSince1970
        let registration: PacketSignatureRegistration =
            envelope.deduplicateTransportRetries
            ? registerPacketSignature(
                database: database,
                signature: Self.packetSignature(
                    peripheralID: envelope.peripheralID,
                    characteristicUUID: envelope.characteristicUUID,
                    payload: packet
                ),
                packetID: packetID,
                receivedAt: receivedAt
            )
            : .new
        switch registration {
        case .duplicate(let canonicalPacketID):
            if let realtime = envelope.realtime,
                !insertRealtime(
                    database: database,
                    packetID: canonicalPacketID,
                    receivedAt: receivedAt,
                    realtime: realtime
                )
            {
                return nil
            }
            guard
                updateOffloadProgress(
                    database: database,
                    sessionID: envelope.offloadSessionID,
                    deliverySequence: deliverySequence,
                    packetID: canonicalPacketID,
                    metadata: envelope.metadata,
                    completedAt: deliveredAt
                ),
                let materializedStepDays = materializePendingStepsIfNeeded(
                    metadata: envelope.metadata,
                    database: database
                )
            else { return nil }
            return OpenTransactionInsertion(
                deliverySequence: deliverySequence,
                outcome: .retry,
                materializedStepDays: materializedStepDays
            )
        case .new:
            break
        case .failed:
            return nil
        }
        guard
            insertPacket(
                database: database,
                id: packetID,
                receivedAt: receivedAt,
                deliverySequence: deliverySequence,
                offloadSessionID: envelope.offloadSessionID,
                peripheralID: envelope.peripheralID.uuidString,
                characteristicUUID: envelope.characteristicUUID,
                frameType: envelope.frameType,
                integrityIsValid: envelope.integrityIsValid,
                payload: packet
            )
        else { return nil }
        if let realtime = envelope.realtime,
            !insertRealtime(
                database: database,
                packetID: packetID,
                receivedAt: receivedAt,
                realtime: realtime
            )
        {
            return nil
        }
        guard
            decodePacketIfNeeded(
                database: database,
                packetID: packetID,
                packet: packet,
                historical: envelope.historical,
                ppg: envelope.ppg,
                integrityIsValid: envelope.integrityIsValid
            ),
            updateOffloadProgress(
                database: database,
                sessionID: envelope.offloadSessionID,
                deliverySequence: deliverySequence,
                packetID: packetID,
                metadata: envelope.metadata,
                completedAt: deliveredAt
            ),
            let materializedStepDays = materializePendingStepsIfNeeded(
                metadata: envelope.metadata,
                database: database
            )
        else { return nil }
        return OpenTransactionInsertion(
            deliverySequence: deliverySequence,
            outcome: .unique,
            materializedStepDays: materializedStepDays
        )
    }

    private enum PacketSignatureRegistration {
        case new
        case duplicate(String)
        case failed
    }

    /// Exact BLE transport retries contain no new evidence. Keep the first raw
    /// frame losslessly and aggregate later identical deliveries so a stuck
    /// history acknowledgement cannot grow the database by hundreds of MB.
    private func registerPacketSignature(
        database: OpaquePointer,
        signature: Data,
        packetID: String,
        receivedAt: TimeInterval
    ) -> PacketSignatureRegistration {
        let sql = """
            INSERT INTO whoop_packet_replay
            (signature, first_packet_id, duplicate_count, last_received_at)
            VALUES (?, ?, 0, ?)
            ON CONFLICT(signature) DO UPDATE SET
                duplicate_count = whoop_packet_replay.duplicate_count + 1,
                last_received_at = excluded.last_received_at
            RETURNING first_packet_id
            """
        let canonicalPacketID: String? =
            withCachedStatement(database: database, sql: sql) { statement in
                bind(signature, to: 1, in: statement)
                bind(packetID, to: 2, in: statement)
                sqlite3_bind_double(statement, 3, receivedAt)
                guard sqlite3_step(statement) == SQLITE_ROW,
                    let returnedPacketID = textColumn(statement, 0),
                    sqlite3_step(statement) == SQLITE_DONE
                else { return nil }
                return returnedPacketID
            } ?? nil
        guard let canonicalPacketID else { return .failed }
        return canonicalPacketID == packetID ? .new : .duplicate(canonicalPacketID)
    }

    static func packetSignature(
        peripheralID: UUID,
        characteristicUUID: String,
        payload: Data
    ) -> Data {
        var input = Data(peripheralID.uuidString.lowercased().utf8)
        input.append(0)
        input.append(contentsOf: characteristicUUID.uppercased().utf8)
        input.append(0)
        input.append(payload)
        return Data(SHA256.hash(data: input))
    }

    private func insertPacket(
        database: OpaquePointer,
        id: String,
        receivedAt: TimeInterval,
        deliverySequence: Int64,
        offloadSessionID: String?,
        peripheralID: String,
        characteristicUUID: String,
        frameType: FrameType?,
        integrityIsValid: Bool,
        payload: Data
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_raw_packet
            (id, received_at, delivery_sequence, offload_session_id, peripheral_id,
             characteristic_uuid, frame_type, protocol_version, crc_valid, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(id, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, receivedAt)
            sqlite3_bind_int64(statement, 3, deliverySequence)
            bind(offloadSessionID, to: 4, in: statement)
            bind(peripheralID, to: 5, in: statement)
            bind(characteristicUUID, to: 6, in: statement)
            if let frameType {
                sqlite3_bind_int(statement, 7, Int32(frameType.rawValue))
            } else {
                sqlite3_bind_null(statement, 7)
            }
            if payload.count > 9 {
                sqlite3_bind_int(statement, 8, Int32(payload[9]))
            } else {
                sqlite3_bind_null(statement, 8)
            }
            sqlite3_bind_int(statement, 9, integrityIsValid ? 1 : 0)
            _ = payload.withUnsafeBytes {
                sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32($0.count), Self.transient)
            }
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    private func updateOffloadProgress(
        database: OpaquePointer,
        sessionID: String?,
        deliverySequence: Int64,
        packetID: String,
        metadata: WhoopHistoricalMetadata?,
        completedAt: Date
    ) -> Bool {
        guard let sessionID else { return true }
        let isCompletion = metadata?.type == .historyComplete
        let sql: String
        if isCompletion {
            sql = """
                UPDATE whoop_offload_session
                SET first_sequence = COALESCE(first_sequence, ?),
                    last_sequence = ?, completion_sequence = ?,
                    completion_packet_id = ?, completed_at = ?,
                    status = 'complete', failure_reason = NULL
                WHERE id = ? AND status = 'in_progress'
                """
        } else {
            sql = """
                UPDATE whoop_offload_session
                SET first_sequence = COALESCE(first_sequence, ?), last_sequence = ?
                WHERE id = ? AND status = 'in_progress'
                """
        }
        return withCachedStatement(database: database, sql: sql) { statement in
            sqlite3_bind_int64(statement, 1, deliverySequence)
            sqlite3_bind_int64(statement, 2, deliverySequence)
            if isCompletion {
                sqlite3_bind_int64(statement, 3, deliverySequence)
                bind(packetID, to: 4, in: statement)
                sqlite3_bind_double(statement, 5, completedAt.timeIntervalSince1970)
                bind(sessionID, to: 6, in: statement)
            } else {
                bind(sessionID, to: 3, in: statement)
            }
            return sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(database) == 1
        } ?? false
    }

    private func abandonInterruptedOffloads() {
        _ = execute(
            """
            UPDATE whoop_offload_session
            SET status = 'abandoned', completed_at = strftime('%s','now'),
                failure_reason = 'app relaunched before completion'
            WHERE status = 'in_progress'
            """)
    }

    private func decodePacketIfNeeded(
        database: OpaquePointer,
        packetID: String,
        packet: Data,
        historical: WhoopDecodedHistorical?,
        ppg: WhoopDecodedPPG? = nil,
        integrityIsValid: Bool? = nil
    ) -> Bool {
        guard packet.count > 9, packet[8] == 47 else { return true }
        let protocolVersion = Int(packet[9])

        if let historical {
            return insertHistorical(
                database: database,
                packetID: packetID,
                sample: historical
            )
        } else if integrityIsValid == nil,
            let historical = WhoopDecodedHistorical.decode(packet)
        {
            return insertHistorical(
                database: database,
                packetID: packetID,
                sample: historical
            )
        } else if let ppg {
            return insertPPG(database: database, packetID: packetID, packet: ppg)
        } else if integrityIsValid == nil,
            let ppg = WhoopDecodedPPG.decode(packet)
        {
            return insertPPG(database: database, packetID: packetID, packet: ppg)
        }

        let integrityIsValid = integrityIsValid ?? WhoopFrameIntegrity.isValid(packet)
        return insertDecodeFailure(
            database: database,
            packetID: packetID,
            protocolVersion: protocolVersion,
            status: integrityIsValid ? "unsupported" : "rejected",
            error: integrityIsValid
                ? "unsupported type-47 version \(protocolVersion), length \(packet.count)"
                : "CRC mismatch"
        )
    }

    private func insertDecodeFailure(
        database: OpaquePointer,
        packetID: String,
        protocolVersion: Int,
        status: String,
        error: String
    ) -> Bool {
        let sql = """
            INSERT OR IGNORE INTO whoop_decode_failure
            (source_packet_id, decoder_version, protocol_version, stream, status, error, decoded_at)
            VALUES (?, ?, ?, 'historical_unknown', ?, ?, ?)
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(packetID, to: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(Self.decoderVersion))
            sqlite3_bind_int(statement, 3, Int32(protocolVersion))
            bind(status, to: 4, in: statement)
            bind(error, to: 5, in: statement)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    private func insertPPG(
        database: OpaquePointer,
        packetID: String,
        packet: WhoopDecodedPPG
    ) -> Bool {
        var samples = Data(capacity: packet.samples.count * 2)
        for sample in packet.samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { samples.append(contentsOf: $0) }
        }
        let sql = """
            INSERT INTO whoop_ppg_packet
            (source_packet_id, sample_at, channel, sample_rate_hz, samples_i16_le, decoder_version)
            VALUES (?, ?, ?, 24, ?, ?)
            ON CONFLICT(source_packet_id) DO UPDATE SET
                sample_at = excluded.sample_at,
                channel = excluded.channel,
                sample_rate_hz = excluded.sample_rate_hz,
                samples_i16_le = excluded.samples_i16_le,
                decoder_version = excluded.decoder_version
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(packetID, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, packet.sampleAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(packet.channel))
            bind(samples, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(Self.decoderVersion))
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    /// Decoder upgrades are replayed from immutable raw evidence. The legacy
    /// v18 summary table was already backfilled by schema v1; decoder v2 adds
    /// the previously ignored v26 optical stream in bounded transactions so a
    /// large phone database remains responsive during migration.
    private func backfillVersion26PPG(cursor: Int64 = 0, batchSize: Int = 500) {
        guard let database,
            metadataValue(database: database, key: "decoder-2-v26-backfill") != "complete"
        else {
            return
        }
        let sql = """
            SELECT rowid, id, payload
            FROM whoop_raw_packet
            WHERE rowid > ?
              AND frame_type = \(FrameType.historicalSample.rawValue)
              AND length(payload) = 88
              AND hex(substr(payload, 10, 1)) = '1A'
            ORDER BY rowid
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int(statement, 2, Int32(batchSize))
        var rows: [(Int64, String, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = textColumn(statement, 1), let payload = dataColumn(statement, 2) {
                rows.append((sqlite3_column_int64(statement, 0), id, payload))
            }
        }
        sqlite3_finalize(statement)

        guard !rows.isEmpty else {
            _ = setMetadataValue(
                database: database,
                key: "decoder-2-v26-backfill",
                value: "complete"
            )
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for (_, packetID, payload) in rows {
            guard
                decodePacketIfNeeded(
                    database: database,
                    packetID: packetID,
                    packet: payload,
                    historical: nil
                )
            else {
                execute("ROLLBACK")
                return
            }
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
        guard let nextCursor = rows.last?.0 else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
            backfillVersion26PPG(cursor: nextCursor, batchSize: batchSize)
        }
    }

    /// Materializes the candidate counter/cadence/class bytes that older app
    /// versions preserved only inside immutable v18 packets. Work is bounded
    /// so upgrading a phone-sized store cannot monopolize the store queue.
    private func backfillVersion18Motion(cursor: Int64 = 0, batchSize: Int = 1_000) {
        guard let database,
            metadataValue(database: database, key: "decoder-3-v18-motion-backfill") != "complete"
        else {
            return
        }
        let sql = """
            SELECT rowid, id, payload
            FROM whoop_raw_packet
            WHERE rowid > ?
              AND frame_type = \(FrameType.historicalSample.rawValue)
              AND length(payload) = 124
              AND hex(substr(payload, 10, 1)) = '12'
            ORDER BY rowid
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int(statement, 2, Int32(batchSize))
        var rows: [(Int64, String, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = textColumn(statement, 1), let payload = dataColumn(statement, 2) {
                rows.append((sqlite3_column_int64(statement, 0), id, payload))
            }
        }
        sqlite3_finalize(statement)

        guard !rows.isEmpty else {
            // Re-derive the durable set instead of trusting the in-memory set.
            // If the app was suspended mid-backfill, packets decoded before
            // that restart no longer appear in `pendingStepDateKeys`.
            guard let changedDays = allStoredStepDateKeys(database: database),
                execute("BEGIN IMMEDIATE")
            else { return }
            guard rebuildDailySteps(for: changedDays, database: database),
                setMetadataValue(
                    database: database,
                    key: "decoder-3-v18-motion-backfill",
                    value: "complete"
                ),
                execute("COMMIT")
            else {
                execute("ROLLBACK")
                return
            }
            pendingStepDateKeys.removeAll(keepingCapacity: true)
            if !changedDays.isEmpty { publishStepUpdate() }
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for (_, packetID, payload) in rows {
            guard
                decodePacketIfNeeded(
                    database: database,
                    packetID: packetID,
                    packet: payload,
                    historical: nil
                )
            else {
                execute("ROLLBACK")
                return
            }
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
        guard let nextCursor = rows.last?.0 else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
            backfillVersion18Motion(cursor: nextCursor, batchSize: batchSize)
        }
    }

    private func allStoredStepDateKeys(database: OpaquePointer) -> Set<String>? {
        let sql = """
            SELECT DISTINCT step_date_key
            FROM whoop_historical_sample
            WHERE step_date_key IS NOT NULL AND step_motion_counter IS NOT NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var dateKeys: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let dateKey = textColumn(statement, 0) { dateKeys.insert(dateKey) }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? dateKeys : nil
    }

    /// One-time correction for data written by the old civil-midnight policy.
    /// Official daily totals stay untouched; only the local raw-sample
    /// projection is reassigned and rebuilt from retained evidence.
    private func rebuildWakeAnchoredStepDaysIfNeeded() {
        guard let database,
            metadataValue(database: database, key: "wake-anchored-step-days") != "2"
        else { return }
        let boundaries = publishedWakeBoundaries(database: database)
        guard !boundaries.isEmpty, execute("BEGIN IMMEDIATE") else { return }
        guard execute("DELETE FROM whoop_daily_step_metric") else {
            execute("ROLLBACK")
            return
        }
        for (index, boundary) in boundaries.enumerated() {
            let upperBound =
                boundaries.indices.contains(index + 1)
                ? boundaries[index + 1].wokeAt.timeIntervalSince1970
                : nil
            guard
                assignStepSamples(
                    to: boundary.dateKey.rawValue,
                    from: boundary.wokeAt.timeIntervalSince1970,
                    until: upperBound,
                    database: database
                )
            else {
                execute("ROLLBACK")
                return
            }
        }
        guard let dateKeys = allStoredStepDateKeys(database: database),
            rebuildDailySteps(for: dateKeys, database: database),
            setMetadataValue(
                database: database,
                key: "wake-anchored-step-days",
                value: "2"
            ),
            execute("COMMIT")
        else {
            execute("ROLLBACK")
            return
        }
        pendingStepDateKeys.removeAll(keepingCapacity: true)
        rebuildRecoveryMetricsIfNeeded(force: true)
        if !dateKeys.isEmpty { publishStepUpdate() }
    }

    /// Re-buckets the newly published day's post-wake samples atomically with
    /// its sleep metrics. Samples before this wake—including after midnight and
    /// during the just-finished sleep—remain on the preceding day.
    private func assignStepsToPublishedDay(
        _ record: DailyHealthRecord,
        replacingWakeAt previousWakeAt: Date?,
        database: OpaquePointer
    ) -> Bool {
        guard let wakeRaw = record.sleepEndAt,
            let wokeAt = Self.parseISO8601(wakeRaw)
        else { return true }
        // This helper normally runs inside the caller's transaction. Do not
        // retain a boundary that could disappear if a later write rolls back.
        defer { cachedPublishedWakeBoundaries = nil }
        let boundaries = publishedWakeBoundaries(database: database)
        let upperBound =
            boundaries
            .filter { $0.wokeAt > wokeAt }
            .map(\.wokeAt)
            .min()?
            .timeIntervalSince1970
        let lowerBound = wokeAt.timeIntervalSince1970
        guard
            let oldDateKeys = stepDateKeys(
                from: lowerBound,
                until: upperBound,
                database: database
            ),
            assignStepSamples(
                to: record.dateKey,
                from: lowerBound,
                until: upperBound,
                database: database
            )
        else { return false }

        var affectedDateKeys = oldDateKeys.union([record.dateKey])

        // A provisional wake can move later when state-2 sleep returns inside
        // the reopen window. Move the interval that used to be post-wake back
        // to the preceding physiological day in the same transaction.
        if let previousWakeAt, previousWakeAt < wokeAt {
            let previousDateKey =
                (boundaries
                .filter { $0.wokeAt < wokeAt }
                .max(by: { $0.wokeAt < $1.wokeAt })?
                .dateKey
                ?? DayKey(
                    date: previousWakeAt.addingTimeInterval(-1),
                    timeZone: .autoupdatingCurrent
                )).rawValue
            let correctionLowerBound = previousWakeAt.timeIntervalSince1970
            guard
                let correctionDateKeys = stepDateKeys(
                    from: correctionLowerBound,
                    until: lowerBound,
                    database: database
                ),
                assignStepSamples(
                    to: previousDateKey,
                    from: correctionLowerBound,
                    until: lowerBound,
                    database: database
                )
            else { return false }
            affectedDateKeys.formUnion(correctionDateKeys)
            affectedDateKeys.insert(previousDateKey)
        }
        for dateKey in affectedDateKeys {
            guard deleteLocalStepMetric(dateKey: dateKey, database: database) else {
                return false
            }
        }
        guard rebuildDailySteps(for: affectedDateKeys, database: database) else {
            return false
        }
        pendingStepDateKeys.subtract(affectedDateKeys)
        return true
    }

    private func stepDateKeys(
        from lowerBound: TimeInterval,
        until upperBound: TimeInterval?,
        database: OpaquePointer
    ) -> Set<String>? {
        let sql = """
            SELECT DISTINCT step_date_key
            FROM whoop_historical_sample
            WHERE step_motion_counter IS NOT NULL AND sample_at >= ?
              AND (? IS NULL OR sample_at < ?)
              AND step_date_key IS NOT NULL
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            sqlite3_bind_double(statement, 1, lowerBound)
            bind(upperBound, to: 2, in: statement)
            bind(upperBound, to: 3, in: statement)
            var dateKeys: Set<String> = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let dateKey = textColumn(statement, 0) { dateKeys.insert(dateKey) }
                result = sqlite3_step(statement)
            }
            return result == SQLITE_DONE ? dateKeys : nil
        } ?? nil
    }

    private func assignStepSamples(
        to dateKey: String,
        from lowerBound: TimeInterval,
        until upperBound: TimeInterval?,
        database: OpaquePointer
    ) -> Bool {
        let sql = """
            UPDATE whoop_historical_sample
            SET step_date_key = ?
            WHERE step_motion_counter IS NOT NULL AND sample_at >= ?
              AND (? IS NULL OR sample_at < ?)
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(dateKey, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, lowerBound)
            bind(upperBound, to: 3, in: statement)
            bind(upperBound, to: 4, in: statement)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    private func deleteLocalStepMetric(dateKey: String, database: OpaquePointer) -> Bool {
        let sql = "DELETE FROM whoop_daily_step_metric WHERE date_key = ?"
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(dateKey, to: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    private func rebuildDailySteps(for dateKeys: Set<String>, database: OpaquePointer) -> Bool {
        guard !dateKeys.isEmpty else { return true }
        let selectSQL = """
            SELECT peripheral_id, sample_at, step_motion_counter
            FROM whoop_historical_sample
            WHERE step_date_key = ? AND step_motion_counter IS NOT NULL
            ORDER BY peripheral_id, sample_at
            """
        let upsertSQL = """
            INSERT INTO whoop_daily_step_metric
            (date_key, peripheral_id, step_count, sample_count, span_seconds,
             coverage_fraction, gap_seconds, counter_wrap_count,
             rejected_delta_count, first_sample_at, last_sample_at,
             source, algorithm_version, derived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    'whoop5_v18_step_counter', ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                peripheral_id = excluded.peripheral_id,
                step_count = excluded.step_count,
                sample_count = excluded.sample_count,
                span_seconds = excluded.span_seconds,
                coverage_fraction = excluded.coverage_fraction,
                gap_seconds = excluded.gap_seconds,
                counter_wrap_count = excluded.counter_wrap_count,
                rejected_delta_count = excluded.rejected_delta_count,
                first_sample_at = excluded.first_sample_at,
                last_sample_at = excluded.last_sample_at,
                source = excluded.source,
                algorithm_version = excluded.algorithm_version,
                derived_at = excluded.derived_at
            """

        for dateKey in dateKeys.sorted() {
            let grouped: [String: [WhoopStepCounterSample]]? =
                withCachedStatement(
                    database: database, sql: selectSQL
                ) { select in
                    bind(dateKey, to: 1, in: select)
                    var byPeripheral: [String: [WhoopStepCounterSample]] = [:]
                    var result = sqlite3_step(select)
                    while result == SQLITE_ROW {
                        if let peripheralID = textColumn(select, 0) {
                            byPeripheral[peripheralID, default: []].append(
                                WhoopStepCounterSample(
                                    timestamp: sqlite3_column_double(select, 1),
                                    counter: UInt16(truncatingIfNeeded: sqlite3_column_int(select, 2))
                                )
                            )
                        }
                        result = sqlite3_step(select)
                    }
                    return result == SQLITE_DONE ? byPeripheral : nil
                } ?? nil
            guard let byPeripheral = grouped else { return false }
            let candidates = byPeripheral.map { peripheralID, samples in
                (peripheralID, WhoopStepDaySummary.summarize(samples))
            }
            guard
                let chosen = candidates.max(by: { lhs, rhs in
                    if lhs.1.sampleCount == rhs.1.sampleCount {
                        return (lhs.1.lastSampleAt ?? 0) < (rhs.1.lastSampleAt ?? 0)
                    }
                    return lhs.1.sampleCount < rhs.1.sampleCount
                })
            else { continue }
            let summary = chosen.1
            let upserted =
                withCachedStatement(database: database, sql: upsertSQL) { upsert in
                    bind(dateKey, to: 1, in: upsert)
                    bind(chosen.0, to: 2, in: upsert)
                    sqlite3_bind_int64(upsert, 3, Int64(summary.stepCount))
                    sqlite3_bind_int64(upsert, 4, Int64(summary.sampleCount))
                    sqlite3_bind_int64(upsert, 5, Int64(summary.spanSeconds))
                    sqlite3_bind_double(upsert, 6, summary.coverageFraction)
                    sqlite3_bind_int64(upsert, 7, Int64(summary.gapSeconds))
                    sqlite3_bind_int64(upsert, 8, Int64(summary.counterWrapCount))
                    sqlite3_bind_int64(upsert, 9, Int64(summary.rejectedDeltaCount))
                    bind(summary.firstSampleAt, to: 10, in: upsert)
                    bind(summary.lastSampleAt, to: 11, in: upsert)
                    sqlite3_bind_int(upsert, 12, Int32(WhoopStepDaySummary.algorithmVersion))
                    sqlite3_bind_double(upsert, 13, Date().timeIntervalSince1970)
                    return sqlite3_step(upsert) == SQLITE_DONE
                } ?? false
            guard upserted else { return false }
        }
        return true
    }

    /// Runs in the packet transaction so a history-complete acknowledgement
    /// cannot become durable before its UI-facing totals do.
    private func materializePendingStepsIfNeeded(
        metadata: WhoopHistoricalMetadata?,
        database: OpaquePointer
    ) -> Set<String>? {
        guard metadata?.type == .historyComplete else { return [] }
        let changedDays = pendingStepDateKeys
        return rebuildDailySteps(for: changedDays, database: database) ? changedDays : nil
    }

    private func finishCommittedStepMaterialization(_ changedDays: Set<String>) {
        guard !changedDays.isEmpty else { return }
        pendingStepDateKeys.subtract(changedDays)
        rebuildRecoveryMetricsIfNeeded(force: true)
        publishStepUpdate()
    }

    private func publishStepUpdate() {
        DispatchQueue.main.async {
            WhoopHealthHistoryEvents.post(.projectionsChanged)
        }
    }

    private func metadataValue(database: OpaquePointer, key: String) -> String? {
        let sql = "SELECT value FROM whoop_store_metadata WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, 0)
    }

    private func setMetadataValue(
        database: OpaquePointer,
        key: String,
        value: String
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_store_metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        bind(value, to: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func insertRealtime(
        database: OpaquePointer,
        packetID: String,
        receivedAt: TimeInterval,
        realtime: WhoopDecodedRealtime
    ) -> Bool {
        if realtime.heartRate > 0 {
            let latestSQL = """
                INSERT INTO whoop_latest_heart_rate(singleton, heart_rate, received_at)
                VALUES (1, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    heart_rate = excluded.heart_rate,
                    received_at = excluded.received_at
                WHERE excluded.received_at >= whoop_latest_heart_rate.received_at
                """
            let latestUpdated =
                withCachedStatement(database: database, sql: latestSQL) { statement in
                    sqlite3_bind_int(statement, 1, Int32(realtime.heartRate))
                    sqlite3_bind_double(statement, 2, receivedAt)
                    return sqlite3_step(statement) == SQLITE_DONE
                } ?? false
            guard latestUpdated else { return false }
        }
        guard !realtime.rrIntervals.isEmpty else { return true }

        let sampleSQL = """
            INSERT INTO heart_rate_sample
            (source_packet_id, received_at, device_timestamp, heart_rate, rr_intervals_json, source)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_packet_id) DO UPDATE SET
                received_at = excluded.received_at,
                device_timestamp = excluded.device_timestamp,
                heart_rate = excluded.heart_rate,
                rr_intervals_json = excluded.rr_intervals_json,
                source = excluded.source
            """
        return withCachedStatement(database: database, sql: sampleSQL) { statement in
            bind(packetID, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, receivedAt)
            if let timestamp = realtime.deviceTimestamp {
                sqlite3_bind_int64(statement, 3, sqlite3_int64(timestamp))
            } else {
                sqlite3_bind_null(statement, 3)
            }
            sqlite3_bind_int(statement, 4, Int32(realtime.heartRate))
            let rrJSON = "[" + realtime.rrIntervals.map(String.init).joined(separator: ",") + "]"
            bind(rrJSON, to: 5, in: statement)
            bind(realtime.source, to: 6, in: statement)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    private func insertHistorical(
        database: OpaquePointer,
        packetID: String,
        sample: WhoopDecodedHistorical
    ) -> Bool {
        let utcOffsetSeconds = nearestRecordedUTCOffset(
            database: database,
            sampleAt: sample.sampleAt
        )
        let stepDateKey = physiologicalStepDateKey(
            for: sample.sampleAt,
            utcOffsetSeconds: utcOffsetSeconds,
            database: database
        )
        let sql = """
            INSERT INTO whoop_historical_sample
            (sample_at, source_packet_id, peripheral_id, protocol_version, ordinal,
             heart_rate, rr_intervals_json, sleep_state, decoder_version,
             step_motion_counter, step_cadence_raw, motion_class_raw,
             step_utc_offset_seconds, step_date_key)
            SELECT ?, ?, p.peripheral_id, COALESCE(p.protocol_version, 18), 0,
                   ?, ?, ?, ?, ?, ?, ?, ?, ?
            FROM whoop_raw_packet p WHERE p.id = ?
            ON CONFLICT(peripheral_id, protocol_version, sample_at, ordinal) DO UPDATE SET
                source_packet_id = excluded.source_packet_id,
                heart_rate = excluded.heart_rate,
                rr_intervals_json = excluded.rr_intervals_json,
                sleep_state = excluded.sleep_state,
                decoder_version = excluded.decoder_version,
                step_motion_counter = excluded.step_motion_counter,
                step_cadence_raw = excluded.step_cadence_raw,
                motion_class_raw = excluded.motion_class_raw,
                step_utc_offset_seconds = excluded.step_utc_offset_seconds,
                step_date_key = excluded.step_date_key
            """
        let succeeded =
            withCachedStatement(database: database, sql: sql) { statement in
                sqlite3_bind_double(statement, 1, sample.sampleAt.timeIntervalSince1970)
                bind(packetID, to: 2, in: statement)
                sqlite3_bind_int(statement, 3, Int32(sample.heartRate))
                let rrJSON = "[" + sample.rrIntervals.map(String.init).joined(separator: ",") + "]"
                bind(rrJSON, to: 4, in: statement)
                sqlite3_bind_int(statement, 5, Int32(sample.sleepState.rawValue))
                sqlite3_bind_int(statement, 6, Int32(Self.decoderVersion))
                sqlite3_bind_int(statement, 7, Int32(sample.stepMotionCounter))
                sqlite3_bind_int(statement, 8, Int32(sample.stepCadenceRaw))
                sqlite3_bind_int(statement, 9, Int32(sample.motionClassRaw))
                sqlite3_bind_int(statement, 10, Int32(utcOffsetSeconds))
                bind(stepDateKey, to: 11, in: statement)
                bind(packetID, to: 12, in: statement)
                return sqlite3_step(statement) == SQLITE_DONE
            } ?? false
        if succeeded { pendingStepDateKeys.insert(stepDateKey) }
        return succeeded
    }

    private func backfillHistoricalSamplesIfNeeded() {
        guard let database else { return }
        let count = Int((try? scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample")) ?? 0)
        guard count == 0 else { return }
        let sql = """
            SELECT id, payload
            FROM whoop_raw_packet
            WHERE frame_type = \(FrameType.historicalSample.rawValue)
            ORDER BY received_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        defer { sqlite3_finalize(statement) }
        guard execute("BEGIN IMMEDIATE") else { return }
        var succeeded = true
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let packetID = textColumn(statement, 0),
                let payload = dataColumn(statement, 1),
                let historical = WhoopDecodedHistorical.decode(payload)
            else {
                stepResult = sqlite3_step(statement)
                continue
            }
            if !insertHistorical(database: database, packetID: packetID, sample: historical) {
                succeeded = false
                break
            }
            stepResult = sqlite3_step(statement)
        }
        succeeded = succeeded && stepResult == SQLITE_DONE
        if succeeded {
            guard execute("COMMIT") else {
                execute("ROLLBACK")
                return
            }
        } else {
            execute("ROLLBACK")
        }
    }

    struct HistoricalRow {
        let timestamp: TimeInterval
        let heartRate: Int
        let sleepState: SleepState
    }

    struct RealtimeRRPacket: Sendable {
        let timestamp: TimeInterval
        let intervals: [Double]
    }

    private struct SleepCandidate {
        let sessionRows: [HistoricalRow]
        let asleepRows: [HistoricalRow]
        let firstSleep: HistoricalRow
        let lastSleep: HistoricalRow
        let latest: HistoricalRow
        let latestSampleIsCurrent: Bool
        /// Observed spacing of the strap's own historical record.
        let cadenceSeconds: Double
        /// The detected sleep interval. A bounded `up` interval followed by
        /// more sleep remains inside the same night; otherwise a false interim
        /// state can shorten a still-running night by an hour.
        let sleepSeconds: Double
        /// Observed samples over samples expected at the observed cadence.
        let sessionCoverage: Double
        /// Elapsed wake time banked after the session ended.
        let wakeSeconds: Double

        var sleepID: String {
            "local-\(Int(firstSleep.timestamp))-\(Int(lastSleep.timestamp))"
        }

        var startedAt: Date { Date(timeIntervalSince1970: firstSleep.timestamp) }
        var endedAt: Date { Date(timeIntervalSince1970: lastSleep.timestamp) }
        var durationMinutes: Double { sleepSeconds / 60.0 }
        var dateKey: String { DayKey.string(from: endedAt, timeZone: .autoupdatingCurrent) }
        var secondsSinceLastAsleep: Double { latest.timestamp - lastSleep.timestamp }

        /// Evidence gates decide whether the night can be honestly scored at all.
        var meetsEvidenceGates: Bool {
            sleepSeconds >= 3 * 60 * 60 && sessionCoverage >= 0.50
        }

        /// Explicit awake is final immediately. The ambiguous `up` state gets
        /// a short provisional delay, then remains reversible if sleep resumes.
        var meetsAutomaticWakeGate: Bool {
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: latest.sleepState,
                secondsSinceLastAsleep: secondsSinceLastAsleep,
                latestSampleIsCurrent: latestSampleIsCurrent
            )
        }

    }

    /// The strap's historical record is not one hertz. It stores roughly one
    /// distinct sample every six seconds, so every duration and coverage figure
    /// is derived from the observed cadence rather than from counting seconds
    /// that happen to carry a sample. Counting seconds made a full night look
    /// like minutes and put both evidence gates permanently out of reach.
    static func cadenceSeconds(of rows: [HistoricalRow]) -> Double {
        guard rows.count > 1 else { return 6 }
        var gaps: [Double] = []
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            if delta > 0, delta <= 300 { gaps.append(delta) }
        }
        guard !gaps.isEmpty else { return 6 }
        gaps.sort()
        return min(max(gaps[gaps.count / 2], 1), 60)
    }

    /// Fraction of a session the strap actually gave evidence for. Only gaps
    /// longer than the outage cap count against it, which is the same cap the
    /// duration integration refuses to count as sleep, so the two agree.
    /// Sampling density is deliberately excluded: a night recorded every sixteen
    /// seconds instead of every six is still a fully observed night, and gating
    /// on density rejected good nights for a property that does not threaten
    /// the duration estimate.
    static func observedFraction(of rows: [HistoricalRow], cadence: Double) -> Double {
        guard rows.count > 1, let first = rows.first, let last = rows.last else { return 0 }
        let span = max(1.0, last.timestamp - first.timestamp)
        let cap = max(cadence * 4, 120.0)
        var unobserved = 0.0
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            if delta > cap { unobserved += delta - cadence }
        }
        return max(0.0, min(1.0, (span - unobserved) / span))
    }

    /// Elapsed time represented by a run of samples. A gap longer than the
    /// outage cap contributes one sample of time rather than the whole gap, so
    /// neither a dropout nor a long awakening is ever counted as sleep.
    static func elapsedSeconds(across rows: [HistoricalRow], cadence: Double) -> Double {
        guard !rows.isEmpty else { return 0 }
        guard rows.count > 1 else { return cadence }
        let cap = max(cadence * 4, 120.0)
        var total = cadence
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            total += delta <= cap ? delta : cadence
        }
        return total
    }

    /// A long `up` interval can occur inside a night and then return to the
    /// strap's explicit asleep state. Keep that as one sleep session. A gap
    /// longer than 90 minutes is treated as a separate sleep instead.
    static func groupedAsleepRows(
        _ asleepRows: [HistoricalRow],
        maximumInterruptionSeconds: Double = WhoopAutomaticSleepPolicy.reopenWindow
    ) -> [[HistoricalRow]] {
        var groups: [[HistoricalRow]] = []
        for row in asleepRows {
            if let last = groups.last?.last,
                row.timestamp - last.timestamp <= maximumInterruptionSeconds
            {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups
    }

    private enum SleepAnalysis {
        case noData
        case sleeping(Date, SleepCandidate?)
        /// Every main sleep in the window, oldest first. All of them are
        /// considered, not only the most recent: a night that ends while the app
        /// is never opened would otherwise be skipped permanently, because the
        /// strap trims its history once a chunk is acknowledged.
        case awake(Date, [SleepCandidate])
    }

    /// Detects the latest main sleep without storing anything. Keeping detection
    /// separate from finalization lets automatic timing and evidence gates decide
    /// when a coherent night is ready to publish.
    /// The 48-hour window every sleep decision is made from.
    private func recentHistoricalRows(now: Date) -> [HistoricalRow] {
        guard let database else { return [] }
        let cutoff = now.addingTimeInterval(-48 * 60 * 60).timeIntervalSince1970
        let sql = """
            SELECT sample_at, heart_rate, sleep_state
            FROM whoop_historical_sample
            WHERE sample_at >= ?
              AND peripheral_id = (
                  SELECT peripheral_id FROM whoop_historical_sample
                  ORDER BY sample_at DESC LIMIT 1
              )
            ORDER BY sample_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)

        var rows: [HistoricalRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                HistoricalRow(
                    timestamp: sqlite3_column_double(statement, 0),
                    heartRate: Int(sqlite3_column_int(statement, 1)),
                    sleepState: SleepState(rawValue: Int(sqlite3_column_int(statement, 2)))
                ))
        }
        return rows
    }

    /// Replays retained raw sleep-state evidence once for each score model
    /// version. Without this, an app update would fix future nights but leave
    /// the handful of locally scored pre-update nights on the old duration-only
    /// formula forever merely because they fell outside the 48-hour live window.
    private func backfillLocalSleepScoresIfNeeded() {
        guard let database,
            metadataValue(database: database, key: "local-sleep-score-backfill") != Self.localSource
        else { return }
        let sql = """
            SELECT sample_at, heart_rate, sleep_state
            FROM whoop_historical_sample
            WHERE peripheral_id = (
                SELECT peripheral_id FROM whoop_historical_sample
                ORDER BY sample_at DESC LIMIT 1
            )
            ORDER BY sample_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        var rows: [HistoricalRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                HistoricalRow(
                    timestamp: sqlite3_column_double(statement, 0),
                    heartRate: Int(sqlite3_column_int(statement, 1)),
                    sleepState: SleepState(rawValue: Int(sqlite3_column_int(statement, 2)))
                ))
        }
        sqlite3_finalize(statement)
        guard let latest = rows.last, execute("BEGIN IMMEDIATE") else { return }
        let ranges = WhoopBackfillPlanner.indexedSleepRanges(
            in: rows,
            timestamp: { $0.timestamp },
            isAsleep: { $0.sleepState == .asleep }
        )
        for range in ranges {
            let session = Array(rows[range.sessionRange])
            let group = range.asleepIndices.map { rows[$0] }
            guard let first = group.first, let last = group.last else { continue }
            let cadence = Self.cadenceSeconds(of: session)
            let candidate = SleepCandidate(
                sessionRows: session,
                asleepRows: group,
                firstSleep: first,
                lastSleep: last,
                latest: latest,
                latestSampleIsCurrent: false,
                cadenceSeconds: cadence,
                sleepSeconds: Self.elapsedSeconds(across: group, cadence: cadence),
                sessionCoverage: Self.observedFraction(of: session, cadence: cadence),
                wakeSeconds: 0
            )
            guard candidate.meetsEvidenceGates,
                shouldDerive(candidate: candidate, database: database)
            else { continue }
            guard
                updateLocalSleepScore(
                    derivedRecord(for: candidate, now: .now), database: database
                )
            else {
                execute("ROLLBACK")
                return
            }
        }
        guard
            setMetadataValue(
                database: database, key: "local-sleep-score-backfill", value: Self.localSource
            ), execute("COMMIT")
        else {
            execute("ROLLBACK")
            return
        }
    }

    private func rebuildRecoveryMetricsIfNeeded(force: Bool = false) {
        guard let database, let model = Self.bundledRecoveryScoreModel else { return }
        if !force,
            metadataValue(database: database, key: "local-recovery-score-backfill") == model.version
        {
            return
        }
        let healthSQL = """
            SELECT date_key, sleep_score, sleep_duration_minutes,
                   hrv_rmssd_milliseconds, resting_heart_rate_bpm,
                   sleep_id, cycle_id, source, source_archive, source_updated_at,
                   sleep_start_at, sleep_end_at, sleep_start_minute, sleep_end_minute,
                   sleep_need_minutes, sleep_consistency_percentage,
                   sleep_efficiency_percentage, sleep_sufficiency_percentage
            FROM daily_health_metric
            WHERE sleep_score IS NOT NULL AND sleep_duration_minutes IS NOT NULL
              AND hrv_rmssd_milliseconds IS NOT NULL
              AND resting_heart_rate_bpm IS NOT NULL
              AND sleep_start_minute IS NOT NULL AND sleep_end_minute IS NOT NULL
              AND sleep_efficiency_percentage IS NOT NULL
            ORDER BY date_key ASC
            """
        var healthStatementPointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, healthSQL, -1, &healthStatementPointer, nil) == SQLITE_OK,
            let healthStatement = healthStatementPointer
        else { return }
        var records: [DailyHealthRecord] = []
        var result = sqlite3_step(healthStatement)
        while result == SQLITE_ROW {
            guard let dateKey = textColumn(healthStatement, 0),
                let source = textColumn(healthStatement, 7),
                let sourceUpdatedAt = textColumn(healthStatement, 9)
            else {
                result = sqlite3_step(healthStatement)
                continue
            }
            records.append(
                DailyHealthRecord(
                    dateKey: dateKey,
                    sleepScore: doubleColumn(healthStatement, 1),
                    sleepDurationMinutes: doubleColumn(healthStatement, 2),
                    hrvRMSSDMilliseconds: doubleColumn(healthStatement, 3),
                    restingHeartRateBPM: doubleColumn(healthStatement, 4),
                    sleepID: textColumn(healthStatement, 5),
                    cycleID: int64Column(healthStatement, 6),
                    source: source,
                    sourceArchive: textColumn(healthStatement, 8),
                    sourceUpdatedAt: sourceUpdatedAt,
                    sleepStartAt: textColumn(healthStatement, 10),
                    sleepEndAt: textColumn(healthStatement, 11),
                    sleepStartMinute: doubleColumn(healthStatement, 12),
                    sleepEndMinute: doubleColumn(healthStatement, 13),
                    sleepNeedMinutes: doubleColumn(healthStatement, 14),
                    sleepConsistencyPercentage: doubleColumn(healthStatement, 15),
                    sleepEfficiencyPercentage: doubleColumn(healthStatement, 16),
                    sleepSufficiencyPercentage: doubleColumn(healthStatement, 17)
                ))
            result = sqlite3_step(healthStatement)
        }
        sqlite3_finalize(healthStatement)
        guard result == SQLITE_DONE else { return }

        let stepsSQL = """
            SELECT date_key, step_count FROM (
                SELECT date_key, official_steps AS step_count
                FROM whoop_official_daily_metric WHERE official_steps IS NOT NULL
                UNION ALL
                SELECT l.date_key, l.step_count FROM whoop_daily_step_metric l
                WHERE NOT EXISTS (
                    SELECT 1 FROM whoop_official_daily_metric o
                    WHERE o.date_key = l.date_key AND o.official_steps IS NOT NULL
                )
            )
            """
        var stepsStatementPointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, stepsSQL, -1, &stepsStatementPointer, nil) == SQLITE_OK,
            let stepsStatement = stepsStatementPointer
        else { return }
        var stepsByDate: [String: Double] = [:]
        result = sqlite3_step(stepsStatement)
        while result == SQLITE_ROW {
            if let dateKey = textColumn(stepsStatement, 0) {
                stepsByDate[dateKey] = Double(sqlite3_column_int64(stepsStatement, 1))
            }
            result = sqlite3_step(stepsStatement)
        }
        sqlite3_finalize(stepsStatement)
        guard result == SQLITE_DONE, execute("BEGIN IMMEDIATE") else { return }

        let upsertSQL = """
            INSERT INTO whoop_daily_recovery_metric
            (date_key, score, confidence, hrv_component, rhr_component,
             sleep_component, steps_component, hrv_baseline, rhr_baseline,
             sleep_baseline, steps_baseline, input_json, model_version, derived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                score = excluded.score, confidence = excluded.confidence,
                hrv_component = excluded.hrv_component,
                rhr_component = excluded.rhr_component,
                sleep_component = excluded.sleep_component,
                steps_component = excluded.steps_component,
                hrv_baseline = excluded.hrv_baseline,
                rhr_baseline = excluded.rhr_baseline,
                sleep_baseline = excluded.sleep_baseline,
                steps_baseline = excluded.steps_baseline,
                input_json = excluded.input_json,
                model_version = excluded.model_version,
                derived_at = excluded.derived_at
            """
        var upsertStatementPointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, upsertSQL, -1, &upsertStatementPointer, nil) == SQLITE_OK,
            let upsertStatement = upsertStatementPointer
        else {
            execute("ROLLBACK")
            return
        }
        let encoder = JSONEncoder()
        var rollingHistory = WhoopRollingRecoveryHistory()
        for record in records {
            let features = RecoveryScoreFeatureBuilder.features(
                current: record,
                history: rollingHistory.records,
                stepsByDate: stepsByDate
            )
            rollingHistory.append(record)
            guard
                let features, let prediction = model.prediction(features),
                let inputs = try? encoder.encode(features.map { $0.isFinite ? Optional($0) : nil }),
                let inputJSON = String(data: inputs, encoding: .utf8)
            else { continue }
            bind(record.dateKey, to: 1, in: upsertStatement)
            sqlite3_bind_double(upsertStatement, 2, prediction.score)
            sqlite3_bind_double(upsertStatement, 3, prediction.confidence)
            sqlite3_bind_double(upsertStatement, 4, prediction.hrvComponent)
            sqlite3_bind_double(upsertStatement, 5, prediction.rhrComponent)
            sqlite3_bind_double(upsertStatement, 6, prediction.sleepComponent)
            sqlite3_bind_double(upsertStatement, 7, prediction.stepsComponent)
            bind(prediction.hrvBaseline, to: 8, in: upsertStatement)
            bind(prediction.rhrBaseline, to: 9, in: upsertStatement)
            bind(prediction.sleepBaseline, to: 10, in: upsertStatement)
            bind(prediction.stepsBaseline, to: 11, in: upsertStatement)
            bind(inputJSON, to: 12, in: upsertStatement)
            bind(model.version, to: 13, in: upsertStatement)
            sqlite3_bind_double(upsertStatement, 14, Date().timeIntervalSince1970)
            guard sqlite3_step(upsertStatement) == SQLITE_DONE else {
                sqlite3_finalize(upsertStatement)
                execute("ROLLBACK")
                return
            }
            sqlite3_reset(upsertStatement)
            sqlite3_clear_bindings(upsertStatement)
        }
        sqlite3_finalize(upsertStatement)
        guard
            setMetadataValue(
                database: database, key: "local-recovery-score-backfill", value: model.version
            ), execute("COMMIT")
        else {
            execute("ROLLBACK")
            return
        }
    }

    private func analyze(now: Date) -> SleepAnalysis {
        let rows = recentHistoricalRows(now: now)
        guard let latest = rows.last else { return .noData }
        let latestDate = Date(timeIntervalSince1970: latest.timestamp)
        let sampleIsCurrent = abs(now.timeIntervalSince(latestDate)) <= 30 * 60
        let lastAsleepTimestamp = rows.last { $0.sleepState == .asleep }?.timestamp
        let secondsSinceLastAsleep = lastAsleepTimestamp.map { latest.timestamp - $0 } ?? .infinity
        let detectorReportsSleeping = WhoopAutomaticSleepPolicy.reportsSleeping(
            latestState: latest.sleepState,
            secondsSinceLastAsleep: secondsSinceLastAsleep,
            latestSampleIsCurrent: sampleIsCurrent
        )
        let asleepRows = rows.filter { $0.sleepState == .asleep }
        guard !asleepRows.isEmpty else { return .awake(latestDate, []) }

        let groups = Self.groupedAsleepRows(asleepRows)
        var candidates: [SleepCandidate] = []
        for session in groups {
            guard let firstSleep = session.first, let lastSleep = session.last else { continue }
            let sessionRows = rows.filter {
                $0.timestamp >= firstSleep.timestamp && $0.timestamp <= lastSleep.timestamp
            }
            let cadence = Self.cadenceSeconds(of: sessionRows)
            let wakeRows = rows.filter {
                $0.timestamp > lastSleep.timestamp && $0.sleepState != .asleep
            }
            candidates.append(
                SleepCandidate(
                    sessionRows: sessionRows,
                    asleepRows: session,
                    firstSleep: firstSleep,
                    lastSleep: lastSleep,
                    latest: latest,
                    latestSampleIsCurrent: sampleIsCurrent,
                    cadenceSeconds: cadence,
                    // State 3 ("up") may bridge two state-2 runs into one night,
                    // but it is not sleep. Group with the asleep rows and measure
                    // with the asleep rows; conflating those two operations added
                    // an hour-long up interval to a real night's duration.
                    sleepSeconds: Self.elapsedSeconds(across: session, cadence: cadence),
                    sessionCoverage: Self.observedFraction(of: sessionRows, cadence: cadence),
                    wakeSeconds: Self.elapsedSeconds(across: wakeRows, cadence: cadence)
                ))
        }
        if detectorReportsSleeping { return .sleeping(latestDate, candidates.last) }
        return .awake(latestDate, candidates)
    }

    /// Automatic path. Explicit awake finalizes immediately; ambiguous `up`
    /// finalizes after ten minutes. Both remain gated on a coherent completed
    /// offload and can grow silently if sleep resumes within ninety minutes.
    private func analyzeLatestSleep(
        now: Date = .now,
        allowAutomaticFinalization: Bool = false
    ) -> WhoopSleepSnapshot {
        switch analyze(now: now) {
        case .noData:
            return WhoopSleepSnapshot(
                isSleeping: false,
                sampleAt: nil,
                finalizedRecord: nil
            )

        case .sleeping(let sampleAt, _):
            return WhoopSleepSnapshot(
                isSleeping: true,
                sampleAt: sampleAt,
                finalizedRecord: nil
            )

        case .awake(let sampleAt, let candidates):
            guard let database else {
                return WhoopSleepSnapshot(
                    isSleeping: false,
                    sampleAt: sampleAt,
                    finalizedRecord: nil
                )
            }

            // Only a completed history offload may bank a night, and the four
            // primary metrics are written together. The persisted completion
            // marker also makes this safe immediately after an app relaunch;
            // a newer partial chunk invalidates it until the next COMPLETE.
            let coherentHistory =
                allowAutomaticFinalization
                && completedOffloadCoversLatestHistory(database: database)
            var publishable: [DailyHealthRecord] = []
            for candidate in candidates
            where coherentHistory
                && candidate.meetsEvidenceGates
                && candidate.meetsAutomaticWakeGate
            {
                guard shouldDerive(candidate: candidate, database: database) else { continue }
                let record = derivedRecord(for: candidate, now: now)
                guard record.hasCompletePrimarySleepMetrics else { continue }
                publishable.append(record)
            }
            var newest: DailyHealthRecord?
            if !publishable.isEmpty, execute("BEGIN IMMEDIATE") {
                let succeeded = publishable.allSatisfy {
                    upsertLocalDailyHealthRecord($0, database: database)
                }
                if succeeded, execute("COMMIT") {
                    newest = publishable.last
                } else {
                    execute("ROLLBACK")
                }
            }
            if newest != nil { rebuildRecoveryMetricsIfNeeded(force: true) }

            return WhoopSleepSnapshot(
                isSleeping: false,
                sampleAt: sampleAt,
                finalizedRecord: newest
            )
        }
    }

    func completedOffloadCoversLatestHistoryForTesting() -> Bool {
        queue.sync { [self] in
            guard let database else { return false }
            return completedOffloadCoversLatestHistory(database: database)
        }
    }

    /// Writes the diagnostics beside the database as JSON. Small and overwritten
    /// each time, so it can be pulled off the device when the dashboard shows
    /// nothing and the reason is not obvious.
    func writeSleepDiagnostics(now: Date = .now) {
        queue.async { [self] in
            let diagnostics = buildSleepDiagnostics(now: now)
            guard let directory = Self.databaseDirectory() else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(diagnostics) else { return }
            try? data.write(
                to: directory.appendingPathComponent("sleep-diagnostics.json"),
                options: .atomic
            )
        }
    }

    private func buildSleepDiagnostics(now: Date) -> WhoopSleepDiagnostics {
        let iso = ISO8601DateFormatter()
        let audit = historicalDecodeAudit()
        func stamp(_ interval: TimeInterval) -> String {
            iso.string(from: Date(timeIntervalSince1970: interval))
        }
        func shell(_ outcome: String, rows: [HistoricalRow] = []) -> WhoopSleepDiagnostics {
            var histogram: [String: Int] = [:]
            for row in rows { histogram["\(row.sleepState.rawValue)", default: 0] += 1 }
            return WhoopSleepDiagnostics(
                generatedAt: iso.string(from: now), windowHours: 48,
                sampleCount: rows.count,
                firstSampleAt: rows.first.map { stamp($0.timestamp) },
                lastSampleAt: rows.last.map { stamp($0.timestamp) },
                secondsSinceLastSample: rows.last.map { Int(now.timeIntervalSince1970 - $0.timestamp) },
                observedCadenceSeconds: rows.isEmpty ? nil : Self.cadenceSeconds(of: rows),
                largestGapSeconds: nil, sleepStateHistogram: histogram,
                rawType47PacketTotal: audit.rawTotal,
                historicalSampleTotal: audit.sampleTotal,
                recentType47Outcomes: audit.outcomes,
                sessions: [], outcome: outcome
            )
        }

        guard let database else { return shell("no database") }
        let rows = recentHistoricalRows(now: now)
        guard !rows.isEmpty else { return shell("no historical samples in the last 48 hours") }

        var histogram: [String: Int] = [:]
        for row in rows { histogram["\(row.sleepState.rawValue)", default: 0] += 1 }
        let cadence = Self.cadenceSeconds(of: rows)
        var largestGap = 0.0
        for index in 1..<rows.count {
            largestGap = max(largestGap, rows[index].timestamp - rows[index - 1].timestamp)
        }

        let asleepRows = rows.filter { $0.sleepState == .asleep }
        let groups = Self.groupedAsleepRows(asleepRows)

        let latest = rows[rows.count - 1]
        var sessions: [WhoopSleepSessionDiagnostics] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let span = max(1.0, last.timestamp - first.timestamp)
            let inSession = rows.filter { $0.timestamp >= first.timestamp && $0.timestamp <= last.timestamp }
            let sessionCadence = Self.cadenceSeconds(of: inSession)
            let wakeRows = rows.filter { $0.timestamp > last.timestamp && $0.sleepState != .asleep }
            let duration = Self.elapsedSeconds(across: inSession, cadence: sessionCadence)
            let coverage = Self.observedFraction(of: inSession, cadence: sessionCadence)
            let density = min(1.0, Double(inSession.count) / max(1.0, span / sessionCadence))
            let wake = Self.elapsedSeconds(across: wakeRows, cadence: sessionCadence)
            let since = latest.timestamp - last.timestamp
            let dateKey = DayKey.string(
                from: Date(timeIntervalSince1970: last.timestamp),
                timeZone: .autoupdatingCurrent
            )
            let stored = storedSleepID(forDateKey: dateKey, database: database)
            let durationGate = duration >= 3 * 60 * 60
            let coverageGate = coverage >= 0.50
            let latestSampleIsCurrent = abs(now.timeIntervalSince1970 - latest.timestamp) <= 30 * 60
            let automaticWakeGate = WhoopAutomaticSleepPolicy.canFinalize(
                latestState: latest.sleepState,
                secondsSinceLastAsleep: since,
                latestSampleIsCurrent: latestSampleIsCurrent
            )

            let candidate = SleepCandidate(
                sessionRows: inSession,
                asleepRows: group,
                firstSleep: first,
                lastSleep: last,
                latest: latest,
                latestSampleIsCurrent: latestSampleIsCurrent,
                cadenceSeconds: sessionCadence,
                sleepSeconds: duration,
                sessionCoverage: coverage,
                wakeSeconds: wake
            )
            let storedComplete = !shouldDerive(candidate: candidate, database: database)
            let metricsComplete = derivedRecord(for: candidate, now: now).hasCompletePrimarySleepMetrics

            let verdict: String
            if storedComplete {
                verdict = "already stored"
            } else if !durationGate || !coverageGate {
                verdict = "pending; evidence incomplete"
            } else if !metricsComplete {
                verdict = "pending; primary metrics still loading"
            } else if !automaticWakeGate {
                verdict = "pending; automatic wake delay"
            } else {
                verdict = "all gates pass; finalizes automatically"
            }

            sessions.append(
                WhoopSleepSessionDiagnostics(
                    startedAt: stamp(first.timestamp), endedAt: stamp(last.timestamp),
                    spanMinutes: (span / 60).rounded(), durationMinutes: (duration / 60).rounded(),
                    sampleCount: inSession.count, coverage: coverage, sampleDensity: density,
                    bankedWakeMinutes: (wake / 60).rounded(),
                    minutesSinceLastAsleep: (since / 60).rounded(),
                    passesDurationGate: durationGate, passesCoverageGate: coverageGate,
                    passesWakeCoverageGate: automaticWakeGate,
                    passesWakeElapsedGate: automaticWakeGate,
                    dateKey: dateKey, storedSleepID: stored,
                    storedSummary: storedRecordSummary(forDateKey: dateKey, database: database),
                    verdict: verdict
                ))
        }

        return WhoopSleepDiagnostics(
            generatedAt: iso.string(from: now), windowHours: 48,
            sampleCount: rows.count,
            firstSampleAt: stamp(rows[0].timestamp),
            lastSampleAt: stamp(latest.timestamp),
            secondsSinceLastSample: Int(now.timeIntervalSince1970 - latest.timestamp),
            observedCadenceSeconds: cadence, largestGapSeconds: Int(largestGap),
            sleepStateHistogram: histogram,
            rawType47PacketTotal: audit.rawTotal,
            historicalSampleTotal: audit.sampleTotal,
            recentType47Outcomes: audit.outcomes,
            sessions: sessions,
            outcome: sessions.last?.verdict ?? "no sample carried sleep_state 2 in the last 48 hours"
        )
    }

    /// Compares stored type-47 packets against the samples they produced. A ratio
    /// near one means the strap itself reports sparsely; a large ratio means this
    /// app is discarding frames it already acknowledged and cannot re-request.
    private func historicalDecodeAudit() -> (rawTotal: Int, sampleTotal: Int, outcomes: [String: Int]) {
        guard let database else { return (0, 0, [:]) }
        // Successful derived rows and the sparse failure ledger together have
        // the indexed shape diagnostics need. Counting the raw table forced a
        // full scan of more than a million retained frames.
        let rawTotal = Int(
            (try? scalarInt(
                database,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM whoop_historical_sample
                         WHERE decoder_version = \(Self.decoderVersion))
                      + (SELECT COUNT(*) FROM whoop_ppg_packet
                         WHERE decoder_version = \(Self.decoderVersion))
                      + (SELECT COUNT(*) FROM whoop_decode_failure
                         WHERE decoder_version = \(Self.decoderVersion))
                    """
            )) ?? 0)
        let sampleTotal = Int((try? scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample")) ?? 0)
        var outcomes: [String: Int] = [:]
        let sql = """
            SELECT payload FROM whoop_raw_packet
            WHERE frame_type = \(FrameType.historicalSample.rawValue)
            ORDER BY received_at DESC
            LIMIT 3000
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return (rawTotal, sampleTotal, outcomes) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            outcomes[WhoopDecodedHistorical.decodeFailureReason(data), default: 0] += 1
        }
        return (rawTotal, sampleTotal, outcomes)
    }

    private func derivedRecord(
        for candidate: SleepCandidate,
        now: Date
    ) -> DailyHealthRecord {
        let durationMinutes = candidate.durationMinutes
        let restingHR = restingHeartRate(rows: candidate.asleepRows, cadence: candidate.cadenceSeconds)
        let hrv = nightlyRMSSD(for: candidate)
        let elapsedMinutes = max(
            durationMinutes,
            (candidate.lastSleep.timestamp - candidate.firstSleep.timestamp + candidate.cadenceSeconds) / 60
        )
        let efficiency = min(100, durationMinutes / elapsedMinutes * 100)
        let current = SleepScoreNight(
            dateKey: candidate.dateKey,
            durationMinutes: durationMinutes,
            efficiencyPercentage: efficiency,
            startMinute: Self.minuteOfDay(candidate.startedAt),
            endMinute: Self.minuteOfDay(candidate.endedAt)
        )
        let features = SleepScoreFeatureBuilder.features(
            current: current,
            history: scoreHistory(before: candidate.dateKey)
        )
        let timingAgreement = features.last ?? 100
        let modelPrediction = Self.bundledSleepScoreModel?.prediction(features)
        let sleepScore =
            modelPrediction?.score
            ?? Self.fallbackSleepScore(
                durationMinutes: durationMinutes,
                efficiencyPercentage: efficiency,
                timingAgreementPercentage: timingAgreement
            )
        let iso = ISO8601DateFormatter()
        return DailyHealthRecord(
            dateKey: candidate.dateKey,
            sleepScore: sleepScore,
            sleepDurationMinutes: durationMinutes,
            hrvRMSSDMilliseconds: hrv,
            restingHeartRateBPM: restingHR,
            sleepID: candidate.sleepID,
            cycleID: nil,
            source: Self.localSource,
            sourceArchive: nil,
            sourceUpdatedAt: iso.string(from: now),
            sleepStartAt: iso.string(from: candidate.startedAt),
            sleepEndAt: iso.string(from: candidate.endedAt),
            sleepStartMinute: current.startMinute,
            sleepEndMinute: current.endMinute,
            sleepNeedMinutes: modelPrediction?.sleepNeedMinutes,
            sleepConsistencyPercentage: modelPrediction?.consistencyPercentage
                ?? timingAgreement,
            sleepEfficiencyPercentage: efficiency,
            sleepSufficiencyPercentage: modelPrediction?.sufficiencyPercentage
        )
    }

    private func scoreHistory(before dateKey: String) -> [SleepScoreNight] {
        guard let database else { return [] }
        let sql = """
            SELECT date_key, sleep_duration_minutes, sleep_efficiency_percentage,
                   sleep_start_minute, sleep_end_minute
            FROM daily_health_metric
            WHERE date_key < ?
              AND sleep_duration_minutes IS NOT NULL
              AND sleep_efficiency_percentage IS NOT NULL
              AND sleep_start_minute IS NOT NULL
              AND sleep_end_minute IS NOT NULL
            ORDER BY date_key DESC
            LIMIT 10
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        var nights: [SleepScoreNight] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = textColumn(statement, 0) else { continue }
            nights.append(
                SleepScoreNight(
                    dateKey: key,
                    durationMinutes: sqlite3_column_double(statement, 1),
                    efficiencyPercentage: sqlite3_column_double(statement, 2),
                    startMinute: sqlite3_column_double(statement, 3),
                    endMinute: sqlite3_column_double(statement, 4)
                ))
        }
        return nights
    }

    /// Whether a night still needs deriving. Older local model versions are
    /// always replaced once a coherent offload exists, including when a bug fix
    /// correctly makes a metric smaller. Within one model version, a later
    /// offload remains grow-only so a partial reconstruction cannot shrink a
    /// settled record. Archived WHOOP rows remain authoritative.
    private func shouldDerive(candidate: SleepCandidate, database: OpaquePointer) -> Bool {
        let sql = """
            SELECT source, sleep_score, sleep_duration_minutes,
                   hrv_rmssd_milliseconds, resting_heart_rate_bpm
            FROM daily_health_metric WHERE date_key = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(candidate.dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        guard let source = textColumn(statement, 0),
            source.hasPrefix(Self.localSourcePrefix)
        else { return false }
        if source != Self.localSource { return true }
        if (1...4).contains(where: { sqlite3_column_type(statement, Int32($0)) == SQLITE_NULL }) {
            return true
        }
        let existingDuration = sqlite3_column_double(statement, 2)
        return Self.shouldReplaceLocalSleep(
            existingDurationMinutes: existingDuration,
            candidateDurationMinutes: candidate.durationMinutes
        )
    }

    /// A one-minute tolerance avoids rewriting a settled record for harmless
    /// cadence-edge jitter while still repairing any meaningful missing tail.
    static func shouldReplaceLocalSleep(
        existingDurationMinutes: Double,
        candidateDurationMinutes: Double
    ) -> Bool {
        return candidateDurationMinutes > existingDurationMinutes + 1
    }

    /// A completed offload is an explicit, CRC-validated durable session. The
    /// completion sequence must cover every unique historical sample currently
    /// stored; a later partial offload invalidates the proof until it completes.
    private func completedOffloadCoversLatestHistory(database: OpaquePointer) -> Bool {
        let sql = """
            SELECT
                (SELECT COALESCE(MAX(p.delivery_sequence), 0)
                 FROM whoop_historical_sample h
                 JOIN whoop_raw_packet p ON p.id = h.source_packet_id),
                (SELECT MAX(completion_sequence)
                 FROM whoop_offload_session
                 WHERE status = 'complete')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            sqlite3_column_type(statement, 0) != SQLITE_NULL,
            sqlite3_column_type(statement, 1) != SQLITE_NULL
        else { return false }
        let newestSampleSequence = sqlite3_column_int64(statement, 0)
        let newestCompletionSequence = sqlite3_column_int64(statement, 1)
        return newestCompletionSequence >= newestSampleSequence
    }

    private func storedRecordSummary(forDateKey dateKey: String, database: OpaquePointer) -> String? {
        let sql = """
            SELECT sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
                   resting_heart_rate_bpm, source
            FROM daily_health_metric WHERE date_key = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let score = sqlite3_column_double(statement, 0)
        let duration = sqlite3_column_double(statement, 1)
        let hrv = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
        let rhr = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
        let source = textColumn(statement, 4) ?? "?"
        return
            "score \(Int(score.rounded()))% | \(Int(duration.rounded())) min | HRV \(hrv.map { String(Int($0.rounded())) } ?? "nil") | RHR \(rhr.map { String(Int($0.rounded())) } ?? "nil") | \(source)"
    }

    private func storedSleepID(forDateKey dateKey: String, database: OpaquePointer) -> String? {
        let sql = "SELECT sleep_id FROM daily_health_metric WHERE date_key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, 0)
    }

    /// Lowest five-minute mean heart rate across the night. The minimum sample
    /// requirement is a fraction of what the observed cadence can actually
    /// deliver in five minutes; a fixed count assumed a one-hertz record and so
    /// no window ever qualified, leaving resting heart rate permanently nil.
    private func restingHeartRate(rows: [HistoricalRow], cadence: Double) -> Double? {
        guard let start = rows.first?.timestamp, let end = rows.last?.timestamp else { return nil }
        let expectedPerWindow = 5 * 60 / max(cadence, 1)
        let required = max(3, Int((expectedPerWindow * 0.4).rounded()))
        var buckets: [Int: (sum: Double, count: Int)] = [:]
        for row in rows where row.heartRate > 0 && row.timestamp >= start && row.timestamp <= end {
            let bucket = Int((row.timestamp - start) / (5 * 60))
            let current = buckets[bucket] ?? (0, 0)
            buckets[bucket] = (current.sum + Double(row.heartRate), current.count + 1)
        }
        return buckets.values
            .filter { $0.count >= required }
            .map { $0.sum / Double($0.count) }
            .min()
            .map { $0.rounded() }
    }

    /// Prefer the live stream for RMSSD, then fall back to the completed history
    /// offload. iOS can suspend live Bluetooth delivery for an entire night even
    /// though the strap later supplies a dense, timestamped R-R history. Keeping
    /// every historical row as a packet preserves both its boundary and sample
    /// timestamp, so the same continuity and artifact rules apply to both paths.
    private func nightlyRMSSD(for candidate: SleepCandidate) -> Double? {
        guard let database else { return nil }
        let standardPackets = realtimeRRPackets(
            database: database,
            from: candidate.firstSleep.timestamp - 30,
            through: candidate.lastSleep.timestamp + 30,
            source: "standard_2a37"
        )
        let ranges = Self.observedAsleepRanges(
            rows: candidate.asleepRows,
            cadence: candidate.cadenceSeconds
        )
        let asleepStandardPackets = standardPackets.filter { packet in
            ranges.contains { packet.timestamp >= $0.lowerBound && packet.timestamp <= $0.upperBound }
        }
        if let value = Self.rmssdFromRealtimePackets(asleepStandardPackets) {
            return value
        }
        let proprietaryPackets = realtimeRRPackets(
            database: database,
            from: candidate.firstSleep.timestamp - 30,
            through: candidate.lastSleep.timestamp + 30,
            source: "whoop5_type40"
        )
        let asleepProprietaryPackets = proprietaryPackets.filter { packet in
            ranges.contains { packet.timestamp >= $0.lowerBound && packet.timestamp <= $0.upperBound }
        }
        if let value = Self.rmssdFromRealtimePackets(asleepProprietaryPackets) {
            return value
        }
        let historicalPackets = historicalRRPackets(
            database: database,
            from: candidate.firstSleep.timestamp - 30,
            through: candidate.lastSleep.timestamp + 30
        )
        let asleepHistoricalPackets = historicalPackets.filter { packet in
            ranges.contains { packet.timestamp >= $0.lowerBound && packet.timestamp <= $0.upperBound }
        }
        return Self.rmssdFromRealtimePackets(asleepHistoricalPackets)
    }

    private func realtimeRRPackets(
        database: OpaquePointer,
        from start: TimeInterval,
        through end: TimeInterval,
        source: String
    ) -> [RealtimeRRPacket] {
        let timeColumn = source == "standard_2a37" ? "received_at" : "device_timestamp"
        let sql = """
            SELECT \(timeColumn), rr_intervals_json
            FROM heart_rate_sample
            WHERE source = ?
              AND \(timeColumn) BETWEEN ? AND ?
              AND rr_intervals_json != '[]'
            ORDER BY \(timeColumn), received_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(source, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, start)
        sqlite3_bind_double(statement, 3, end)
        var packets: [RealtimeRRPacket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = textColumn(statement, 1) ?? "[]"
            let intervals = (try? JSONDecoder().decode([Double].self, from: Data(text.utf8))) ?? []
            if !intervals.isEmpty {
                packets.append(
                    RealtimeRRPacket(
                        timestamp: sqlite3_column_double(statement, 0),
                        intervals: intervals
                    ))
            }
        }
        return packets
    }

    private func historicalRRPackets(
        database: OpaquePointer,
        from start: TimeInterval,
        through end: TimeInterval
    ) -> [RealtimeRRPacket] {
        let sql = """
            SELECT sample_at, rr_intervals_json
            FROM whoop_historical_sample
            WHERE peripheral_id = (
                SELECT peripheral_id FROM whoop_historical_sample
                ORDER BY sample_at DESC LIMIT 1
            )
              AND sample_at BETWEEN ? AND ?
              AND sleep_state = 2
              AND rr_intervals_json != '[]'
            ORDER BY sample_at, ordinal
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, end)
        var packets: [RealtimeRRPacket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = textColumn(statement, 1) ?? "[]"
            let intervals = (try? JSONDecoder().decode([Double].self, from: Data(text.utf8))) ?? []
            if !intervals.isEmpty {
                packets.append(
                    RealtimeRRPacket(
                        timestamp: sqlite3_column_double(statement, 0),
                        intervals: intervals
                    ))
            }
        }
        return packets
    }

    static func observedAsleepRanges(
        rows: [HistoricalRow],
        cadence: Double
    ) -> [ClosedRange<TimeInterval>] {
        guard let first = rows.first else { return [] }
        let maximumGap = max(cadence * 4, 120)
        var ranges: [ClosedRange<TimeInterval>] = []
        var start = first.timestamp
        var previous = first.timestamp
        for row in rows.dropFirst() {
            if row.timestamp - previous > maximumGap {
                ranges.append((start - cadence)...(previous + cadence))
                start = row.timestamp
            }
            previous = row.timestamp
        }
        ranges.append((start - cadence)...(previous + cadence))
        return ranges
    }

    /// Computes artifact-filtered five-minute RMSSD windows while allowing
    /// continuity only inside one packet or across packets delivered no more
    /// than three seconds apart. An interval more than 20% from that window's
    /// median breaks the chain rather than stitching its neighbours together.
    /// The nightly median prevents a few motion-heavy windows from dominating
    /// the result. Returning nil is preferable to false precision.
    static func rmssdFromRealtimePackets(
        _ packets: [RealtimeRRPacket],
        minimumDifferencesPerWindow: Int = 20
    ) -> Double? {
        guard !packets.isEmpty else { return nil }
        let alreadyOrdered = zip(packets, packets.dropFirst()).allSatisfy {
            $0.timestamp <= $1.timestamp
        }
        let ordered =
            alreadyOrdered
            ? packets
            : packets.sorted { lhs, rhs in
                lhs.timestamp == rhs.timestamp
                    ? lhs.intervals.count < rhs.intervals.count
                    : lhs.timestamp < rhs.timestamp
            }
        let windows = Dictionary(grouping: ordered) { Int($0.timestamp / 300) }
        var values: [Double] = []
        for packets in windows.values {
            let plausible =
                packets
                .flatMap(\.intervals)
                .filter { (300...2_000).contains($0) }
                .sorted()
            guard !plausible.isEmpty else { continue }
            let middle = plausible.count / 2
            let median =
                plausible.count.isMultiple(of: 2)
                ? (plausible[middle - 1] + plausible[middle]) / 2
                : plausible[middle]
            var squares: [Double] = []
            var previousInterval: Double?
            var previousPacketTimestamp: TimeInterval?
            var previousWasValid = false
            for packet in packets {
                let packetGap = previousPacketTimestamp.map { packet.timestamp - $0 }
                for (index, interval) in packet.intervals.enumerated() {
                    let valid =
                        (300...2_000).contains(interval)
                        && median > 0
                        && abs(interval - median) / median <= 0.20
                    let adjacent =
                        index > 0
                        || packetGap.map { $0 > 0 && $0 <= 3 } == true
                    if valid, previousWasValid, adjacent, let previousInterval {
                        let difference = interval - previousInterval
                        squares.append(difference * difference)
                    }
                    previousInterval = valid ? interval : nil
                    previousWasValid = valid
                }
                previousPacketTimestamp = packet.timestamp
            }
            if squares.count >= minimumDifferencesPerWindow {
                values.append(sqrt(squares.reduce(0, +) / Double(squares.count)))
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
    }

    /// Versioned so a change to any derivation re-derives the nights written by
    /// the previous version instead of leaving stale values in the history.
    /// Anything with the `whoop5_local` prefix is ours; anything else is an
    /// archived WHOOP row and is authoritative.
    private static let bundledSleepScoreModel = SleepScoreModelBundle.load()
    private static let bundledRecoveryScoreModel = RecoveryScoreModelBundle.load()
    static let localSource = "\(bundledSleepScoreModel?.version ?? "whoop5_local_v5_fallback")_materialized_3"
    static let localSourcePrefix = "whoop5_local"

    /// A deterministic, coefficient-only safety net for development builds
    /// without Harley's private model bundle. The production private bundle is
    /// an Extra Trees + RBF-SVR ensemble and replaces this automatically.
    static func fallbackSleepScore(
        durationMinutes: Double,
        efficiencyPercentage: Double,
        timingAgreementPercentage: Double
    ) -> Double {
        min(
            99,
            max(
                0,
                -101.418011
                    + 0.10204614 * durationMinutes
                    + 0.43013477 * efficiencyPercentage
                    + 1.06691453 * timingAgreementPercentage
            ))
    }

    private static func minuteOfDay(_ date: Date) -> Double {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute, .second, .nanosecond], from: date
        )
        return Double(components.hour ?? 0) * 60
            + Double(components.minute ?? 0)
            + Double(components.second ?? 0) / 60
            + Double(components.nanosecond ?? 0) / 60_000_000_000
    }

    private func upsertLocalDailyHealthRecord(
        _ record: DailyHealthRecord,
        database: OpaquePointer
    ) -> Bool {
        let previousWakeAt = storedWakeAt(dateKey: record.dateKey, database: database)
        let sql = """
            INSERT INTO daily_health_metric
            (date_key, sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
             resting_heart_rate_bpm, sleep_id, cycle_id, source, source_archive,
             source_updated_at, imported_at, sleep_start_at, sleep_end_at,
             sleep_start_minute, sleep_end_minute, sleep_need_minutes,
             sleep_consistency_percentage, sleep_efficiency_percentage,
             sleep_sufficiency_percentage)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                sleep_score = excluded.sleep_score,
                sleep_duration_minutes = excluded.sleep_duration_minutes,
                hrv_rmssd_milliseconds = excluded.hrv_rmssd_milliseconds,
                resting_heart_rate_bpm = excluded.resting_heart_rate_bpm,
                sleep_id = excluded.sleep_id,
                cycle_id = excluded.cycle_id,
                source = excluded.source,
                source_archive = excluded.source_archive,
                source_updated_at = excluded.source_updated_at,
                imported_at = excluded.imported_at,
                sleep_start_at = excluded.sleep_start_at,
                sleep_end_at = excluded.sleep_end_at,
                sleep_start_minute = excluded.sleep_start_minute,
                sleep_end_minute = excluded.sleep_end_minute,
                sleep_need_minutes = excluded.sleep_need_minutes,
                sleep_consistency_percentage = excluded.sleep_consistency_percentage,
                sleep_efficiency_percentage = excluded.sleep_efficiency_percentage,
                sleep_sufficiency_percentage = excluded.sleep_sufficiency_percentage
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.dateKey, to: 1, in: statement)
        bind(record.sleepScore, to: 2, in: statement)
        bind(record.sleepDurationMinutes, to: 3, in: statement)
        bind(record.hrvRMSSDMilliseconds, to: 4, in: statement)
        bind(record.restingHeartRateBPM, to: 5, in: statement)
        bind(record.sleepID, to: 6, in: statement)
        bind(record.cycleID, to: 7, in: statement)
        bind(record.source, to: 8, in: statement)
        bind(record.sourceArchive, to: 9, in: statement)
        bind(record.sourceUpdatedAt, to: 10, in: statement)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        bind(record.sleepStartAt, to: 12, in: statement)
        bind(record.sleepEndAt, to: 13, in: statement)
        bind(record.sleepStartMinute, to: 14, in: statement)
        bind(record.sleepEndMinute, to: 15, in: statement)
        bind(record.sleepNeedMinutes, to: 16, in: statement)
        bind(record.sleepConsistencyPercentage, to: 17, in: statement)
        bind(record.sleepEfficiencyPercentage, to: 18, in: statement)
        bind(record.sleepSufficiencyPercentage, to: 19, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        cachedPublishedWakeBoundaries = nil
        return assignStepsToPublishedDay(
            record,
            replacingWakeAt: previousWakeAt,
            database: database
        )
    }

    private func storedWakeAt(dateKey: String, database: OpaquePointer) -> Date? {
        let sql = "SELECT sleep_end_at FROM daily_health_metric WHERE date_key = ? LIMIT 1"
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(dateKey, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                let raw = textColumn(statement, 0)
            else { return nil }
            return Self.parseISO8601(raw)
        } ?? nil
    }

    /// Score-model backfills must not erase a previously valid HRV or RHR if
    /// the old realtime R-R window is no longer available to recompute it.
    private func updateLocalSleepScore(
        _ record: DailyHealthRecord,
        database: OpaquePointer
    ) -> Bool {
        let sql = """
            UPDATE daily_health_metric
            SET sleep_score = ?, source = ?, source_updated_at = ?, imported_at = ?,
                sleep_start_at = ?, sleep_end_at = ?, sleep_start_minute = ?,
                sleep_end_minute = ?, sleep_consistency_percentage = ?,
                sleep_efficiency_percentage = ?, sleep_need_minutes = ?,
                sleep_sufficiency_percentage = ?
            WHERE date_key = ? AND source LIKE 'whoop5_local%'
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.sleepScore, to: 1, in: statement)
        bind(record.source, to: 2, in: statement)
        bind(record.sourceUpdatedAt, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        bind(record.sleepStartAt, to: 5, in: statement)
        bind(record.sleepEndAt, to: 6, in: statement)
        bind(record.sleepStartMinute, to: 7, in: statement)
        bind(record.sleepEndMinute, to: 8, in: statement)
        bind(record.sleepConsistencyPercentage, to: 9, in: statement)
        bind(record.sleepEfficiencyPercentage, to: 10, in: statement)
        bind(record.sleepNeedMinutes, to: 11, in: statement)
        bind(record.sleepSufficiencyPercentage, to: 12, in: statement)
        bind(record.dateKey, to: 13, in: statement)
        let succeeded = sqlite3_step(statement) == SQLITE_DONE
        if succeeded { cachedPublishedWakeBoundaries = nil }
        return succeeded
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bind(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let bytes = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: bytes)
    }

    private func doubleColumn(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func int64Column(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func dataColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let bytes = sqlite3_column_blob(statement, index)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func scalarInt(_ database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw StoreError.queryFailed(errorMessage(database)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private enum StoreError: LocalizedError {
        case databaseUnavailable
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable: "The local WHOOP database is unavailable."
            case .queryFailed(let detail): "The WHOOP history query failed: \(detail)"
            }
        }
    }
}
