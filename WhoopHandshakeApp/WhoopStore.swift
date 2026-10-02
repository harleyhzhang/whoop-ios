import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Append-only local evidence store for direct WHOOP packets and derived samples.
/// Raw frames are retained so later protocol improvements never require another capture.
final class WhoopStore: Sendable, WhoopPacketPersisting {
    static let shared = WhoopStore()

    let sqlite = SQLiteDatabase()
    let dashboardReader = DashboardDatabaseReader()
    let readiness = WhoopStorageReadiness()
    let databaseURLOverride: URL?
    let databaseURL: URL?
    let faultInjector: WhoopStorageFaultInjector
    let targetSchemaVersion: Int
    static let logger = Logger(subsystem: "com.clintonst.sideload.sleep", category: "WhoopStore")
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let currentSchemaVersion = 10
    static let expectedSchemaVersion = currentSchemaVersion
    static let decoderVersion = 3

    var queue: DispatchQueue { sqlite.queue }
    var database: OpaquePointer? {
        get { sqlite.connection }
        set { sqlite.connection = newValue }
    }
    var cachedStatements: [String: OpaquePointer] {
        get { sqlite.cachedStatements }
        set { sqlite.cachedStatements = newValue }
    }
    var pendingStepDateKeys: Set<String> {
        get { sqlite.pendingStepDateKeys }
        set { sqlite.pendingStepDateKeys = newValue }
    }
    var cachedPublishedWakeBoundaries: [WhoopWakeBoundary]? {
        get { sqlite.publishedWakeBoundaries }
        set { sqlite.publishedWakeBoundaries = newValue }
    }
    var storageTelemetry: WhoopStorageTelemetry? {
        get { sqlite.storageTelemetry }
        set { sqlite.storageTelemetry = newValue }
    }
    var nextDeliverySequence: Int64 {
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

    func closeDatabase() {
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
        readiness.whenResolved { [self] result in
            switch result {
            case .success(let url):
                dashboardReader.loadSnapshot(at: url) { [self] result in
                    if case .success(let snapshot) = result, !snapshot.strainDerivations.isEmpty {
                        queue.async { [self] in
                            guard let database else { return }
                            for (key, value) in snapshot.strainDerivations {
                                _ = setMetadataValue(database: database, key: key, value: value)
                            }
                        }
                    }
                    completion(result)
                }
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

}
