import SQLite3
import XCTest

@testable import Sleep

final class WhoopReliabilityTests: XCTestCase {
    func testConnectionSessionRejectsSupersededTokensAndPeripherals() throws {
        let firstID = UUID()
        let secondID = UUID()
        var session = WhoopConnectionSession()

        let first = session.select(firstID)
        XCTAssertTrue(session.accepts(first))
        XCTAssertTrue(session.accepts(peripheralID: firstID))

        let reset = try XCTUnwrap(session.resetKeepingPeripheral())
        XCTAssertFalse(session.accepts(first))
        XCTAssertTrue(session.accepts(reset))

        let second = session.select(secondID)
        XCTAssertFalse(session.accepts(reset))
        XCTAssertFalse(session.accepts(peripheralID: firstID))
        XCTAssertTrue(session.accepts(second))

        session.clear()
        XCTAssertNil(session.token())
        XCTAssertFalse(session.accepts(second))
    }

    func testHistoricalSyncStateEnforcesTransitionsAndTracksProgress() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let token = WhoopConnectionSession.Token(generation: 7, peripheralID: UUID())
        let wrongToken = WhoopConnectionSession.Token(generation: 8, peripheralID: token.peripheralID)
        var state = WhoopHistoricalSyncState()

        XCTAssertTrue(state.begin(for: token, at: startedAt))
        XCTAssertFalse(state.begin(for: token, at: startedAt))
        XCTAssertFalse(state.activate(sessionID: "wrong", for: wrongToken))
        XCTAssertTrue(state.activate(sessionID: "session", for: token))
        XCTAssertEqual(state.sessionID, "session")

        state.observeHistoryStart(at: startedAt.addingTimeInterval(1))
        state.observe(sampleAt: startedAt.addingTimeInterval(10), receivedAt: startedAt.addingTimeInterval(2))
        state.observe(sampleAt: startedAt.addingTimeInterval(5), receivedAt: startedAt.addingTimeInterval(3))
        XCTAssertEqual(state.newestSampleAt, startedAt.addingTimeInterval(10))
        XCTAssertEqual(state.stalledDuration(at: startedAt.addingTimeInterval(92)), 90)
        XCTAssertEqual(state.reset(), "session")
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.stalledDuration(at: startedAt))
    }

    func testSQLiteFailuresHaveTypedRecoverySemantics() {
        let busy = WhoopStorageFailure.sqlite(
            operation: .commit,
            database: nil,
            resultCode: SQLITE_BUSY
        )
        let full = WhoopStorageFailure.sqlite(
            operation: .insert,
            database: nil,
            resultCode: SQLITE_FULL
        )
        let corrupt = WhoopStorageFailure.sqlite(
            operation: .integrityCheck,
            database: nil,
            resultCode: SQLITE_CORRUPT
        )

        XCTAssertEqual(busy.kind, .busy)
        XCTAssertTrue(busy.isTransient)
        XCTAssertEqual(full.kind, .full)
        XCTAssertFalse(full.isTransient)
        XCTAssertEqual(corrupt.kind, .corrupt)
        XCTAssertFalse(corrupt.isTransient)
    }

    func testOpenFailureProducesTerminalStorageState() throws {
        let fixture = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failure = WhoopStorageFailure.sqlite(
            operation: .open,
            database: nil,
            resultCode: SQLITE_CANTOPEN
        )
        let store = WhoopStore(
            databaseURL: fixture.url,
            runBackgroundDecoding: false,
            faultInjector: WhoopStorageFaultInjector { operation in
                operation == .open ? failure : nil
            }
        )

        XCTAssertEqual(store.storageStateForTesting(), .failed(failure))
        store.shutdownForTesting()
    }

    func testInjectedCommitFailureRollsBackRawEvidence() async throws {
        let fixture = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failure = WhoopStorageFailure.sqlite(
            operation: .commit,
            database: nil,
            resultCode: SQLITE_FULL
        )
        let store = WhoopStore(
            databaseURL: fixture.url,
            runBackgroundDecoding: false,
            faultInjector: WhoopStorageFaultInjector { operation in
                operation == .commit ? failure : nil
            }
        )
        defer { store.shutdownForTesting() }
        let envelope = try XCTUnwrap(
            WhoopPacketEnvelope.standardHeartRate(
                packet: Data([0, 61]),
                peripheralID: UUID(),
                characteristicUUID: "2A37",
                deliveredAt: .now
            )
        )

        let result = await append([envelope], to: store)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure, failure)
        XCTAssertEqual(try rawPacketCount(at: fixture.url), 0)
    }

    func testInjectedBeginAndInsertFailuresNeverCommitRawEvidence() async throws {
        let cases: [(WhoopSQLiteOperation, Int32)] = [
            (.beginTransaction, SQLITE_BUSY),
            (.insert, SQLITE_IOERR),
        ]
        for (operation, code) in cases {
            let fixture = try temporaryDatabaseURL()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let failure = WhoopStorageFailure.sqlite(
                operation: operation,
                database: nil,
                resultCode: code
            )
            let store = WhoopStore(
                databaseURL: fixture.url,
                runBackgroundDecoding: false,
                faultInjector: WhoopStorageFaultInjector { candidate in
                    candidate == operation ? failure : nil
                }
            )
            let envelope = try XCTUnwrap(
                WhoopPacketEnvelope.standardHeartRate(
                    packet: Data([0, 61]),
                    peripheralID: UUID(),
                    characteristicUUID: "2A37",
                    deliveredAt: .now
                )
            )

            let result = await append([envelope], to: store)

            XCTAssertFalse(result.success)
            XCTAssertEqual(result.failure, failure)
            XCTAssertEqual(try rawPacketCount(at: fixture.url), 0)
            store.shutdownForTesting()
        }
    }

    func testCorruptDatabaseFailsClosed() throws {
        let fixture = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("not a sqlite database".utf8).write(to: fixture.url)

        let store = WhoopStore(databaseURL: fixture.url, runBackgroundDecoding: false)

        guard case .failed(let failure) = store.storageStateForTesting() else {
            XCTFail("Corrupt storage must not become ready")
            store.shutdownForTesting()
            return
        }
        XCTAssertTrue(failure.kind == .corrupt || failure.kind == .unknown)
        store.shutdownForTesting()
    }

    func testPipelineRetriesTransientFailureBeforePublishingSuccess() throws {
        let transient = WhoopStorageFailure.sqlite(
            operation: .commit,
            database: nil,
            resultCode: SQLITE_BUSY
        )
        let persister = ScriptedPersister(results: [
            WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: transient
            ),
            WhoopPacketBatchPersistenceResult(success: true, deliverySequences: [1]),
        ])
        let completion = expectation(description: "terminal persistence result")
        let terminalResults = LockedPersistenceResults()
        let pipeline = WhoopTransportPipeline(
            store: persister,
            maximumBatchSize: 1,
            persistenceRetryDelay: { _ in 0 },
            idleFlushDelay: 60,
            didPublishUI: { _ in },
            didPersist: { result, _ in
                terminalResults.append(result)
                completion.fulfill()
            }
        )

        submitHeartRate(to: pipeline, value: 61)
        wait(for: [completion], timeout: 2)

        XCTAssertEqual(persister.callCount, 2)
        XCTAssertEqual(terminalResults.count, 1)
        XCTAssertTrue(try XCTUnwrap(terminalResults.first).success)
    }

    func testPipelineBoundsBacklogAndSurfacesBackpressure() throws {
        let persister = HoldingPersister()
        let overflow = expectation(description: "overflow surfaced")
        let pressure = expectation(description: "backpressure surfaced")
        let pipeline = WhoopTransportPipeline(
            store: persister,
            maximumBatchSize: 1,
            maximumQueuedEnvelopeCount: 2,
            idleFlushDelay: 60,
            didPublishUI: { _ in },
            didPersist: { result, _ in
                if result.failure?.kind == .full { overflow.fulfill() }
            },
            didChangePressure: { snapshot in
                if snapshot.isBackpressured { pressure.fulfill() }
            }
        )

        submitHeartRate(to: pipeline, value: 61)
        submitHeartRate(to: pipeline, value: 62)
        submitHeartRate(to: pipeline, value: 63)

        wait(for: [overflow, pressure], timeout: 2)
        XCTAssertEqual(persister.callCount, 1)
        persister.completeAllSuccessfully()
    }

    func testDashboardReadDoesNotWaitForBlockedWriter() throws {
        let fixture = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = WhoopStore(databaseURL: fixture.url, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }
        let writerStarted = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        store.blockWriterForTesting(started: writerStarted, release: releaseWriter)
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 2), .success)
        defer { releaseWriter.signal() }
        let loaded = expectation(description: "read completed independently")

        store.loadDashboardHistory { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 2)
    }

    func testProtocolDecodersSurviveDeterministicMutationCorpus() {
        var state: UInt64 = 0xC0FFEE
        for length in 0...256 {
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            for _ in 0..<length {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            let data = Data(bytes)
            _ = WhoopFrameIntegrity.isValid(data)
            _ = WhoopDecodedRealtime.decodeStandardHeartRate(data)
            _ = WhoopDecodedRealtime.decodeWhoop5Realtime(data)
            _ = WhoopDecodedHistorical.decode(data)
            _ = WhoopDecodedHistorical.decodeFailureReason(data)
            _ = WhoopDecodedPPG.decode(data)
            _ = WhoopPacketEnvelope.proprietary(
                packet: data,
                peripheralID: UUID(),
                characteristicUUID: "FUZZ",
                offloadSessionID: "synthetic",
                deliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
                proprietaryOrdinal: length
            )
        }
    }

    private func submitHeartRate(to pipeline: WhoopTransportPipeline, value: UInt8) {
        pipeline.submitStandardHeartRate(
            packet: Data([0, value]),
            peripheralID: UUID(),
            characteristicUUID: "2A37",
            deliveredAt: .now
        )
    }

    private func append(
        _ envelopes: [WhoopPacketEnvelope],
        to store: WhoopStore
    ) async -> WhoopPacketBatchPersistenceResult {
        await withCheckedContinuation { continuation in
            store.appendBatch(envelopes) { continuation.resume(returning: $0) }
        }
    }

    private func temporaryDatabaseURL() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("sleep.sqlite3"))
    }

    private func rawPacketCount(at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM whoop_raw_packet",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement
        else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private final class LockedPersistenceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WhoopPacketBatchPersistenceResult] = []

    var count: Int { lock.withLock { values.count } }
    var first: WhoopPacketBatchPersistenceResult? { lock.withLock { values.first } }

    func append(_ value: WhoopPacketBatchPersistenceResult) {
        lock.withLock { values.append(value) }
    }
}

private final class ScriptedPersister: WhoopPacketPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [WhoopPacketBatchPersistenceResult]
    private(set) var callCount = 0

    init(results: [WhoopPacketBatchPersistenceResult]) {
        self.results = results
    }

    func appendBatch(
        _ envelopes: [WhoopPacketEnvelope],
        completion: @escaping @Sendable (WhoopPacketBatchPersistenceResult) -> Void
    ) {
        let result = lock.withLock { () -> WhoopPacketBatchPersistenceResult in
            callCount += 1
            return results.removeFirst()
        }
        completion(result)
    }
}

private final class HoldingPersister: WhoopPacketPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [@Sendable (WhoopPacketBatchPersistenceResult) -> Void] = []
    private(set) var callCount = 0

    func appendBatch(
        _ envelopes: [WhoopPacketEnvelope],
        completion: @escaping @Sendable (WhoopPacketBatchPersistenceResult) -> Void
    ) {
        lock.withLock {
            callCount += 1
            completions.append(completion)
        }
    }

    func completeAllSuccessfully() {
        let callbacks = lock.withLock { () -> [@Sendable (WhoopPacketBatchPersistenceResult) -> Void] in
            let callbacks = completions
            completions.removeAll()
            return callbacks
        }
        for callback in callbacks {
            callback(WhoopPacketBatchPersistenceResult(success: true, deliverySequences: [1]))
        }
    }
}
