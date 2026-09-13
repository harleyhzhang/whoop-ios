import SQLite3
import XCTest

@testable import Sleep

final class WhoopTransportPipelineTests: XCTestCase {
    func testEnvelopeParsesAndValidatesProprietaryFrameOnce() throws {
        let deliveredAt = Date(timeIntervalSince1970: 1_800_000_010)
        let frame = historicalFrame(timestamp: 1_800_000_000, stepCounter: 321)

        let envelope = WhoopPacketEnvelope.proprietary(
            packet: frame,
            peripheralID: UUID(),
            characteristicUUID: "FD4B0003",
            offloadSessionID: "session",
            deliveredAt: deliveredAt,
            proprietaryOrdinal: 7
        )

        XCTAssertTrue(envelope.integrityIsValid)
        XCTAssertEqual(envelope.frameType, .historicalSample)
        XCTAssertEqual(envelope.historical?.stepMotionCounter, 321)
        XCTAssertNil(envelope.realtime)
        XCTAssertNil(envelope.ppg)
        XCTAssertNil(envelope.metadata)
        XCTAssertEqual(envelope.proprietaryOrdinal, 7)
        XCTAssertTrue(envelope.deduplicateTransportRetries)
    }

    func testCorruptEnvelopeRetainsRawEvidenceWithoutPublishingDecodedState() {
        var frame = historicalFrame(timestamp: 1_800_000_000, stepCounter: 321)
        frame[57] ^= 0x01

        let envelope = WhoopPacketEnvelope.proprietary(
            packet: frame,
            peripheralID: UUID(),
            characteristicUUID: "FD4B0003",
            offloadSessionID: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_010),
            proprietaryOrdinal: 1
        )

        XCTAssertFalse(envelope.integrityIsValid)
        XCTAssertNil(envelope.historical)
        XCTAssertNil(envelope.realtime)
        XCTAssertNil(envelope.ppg)
        XCTAssertNil(envelope.metadata)
        XCTAssertNil(envelope.freshWristState)
        XCTAssertEqual(envelope.packet, frame)
    }

    func testBatcherBoundsBurstsAndPreservesFIFOOrder() throws {
        var batcher = WhoopPacketBatcher(maximumBatchSize: 3)
        let first = try standardEnvelope(heartRate: 61, deliveredAt: 1)
        let second = try standardEnvelope(heartRate: 62, deliveredAt: 2)
        let third = try standardEnvelope(heartRate: 63, deliveredAt: 3)

        XCTAssertNil(batcher.ingest(first))
        XCTAssertNil(batcher.ingest(second))
        let batch = try XCTUnwrap(batcher.ingest(third))

        XCTAssertEqual(batch.map(\.realtime?.heartRate), [61, 62, 63])
        XCTAssertTrue(batcher.pending.isEmpty)
    }

    func testMetadataEndsBatchSoAckCannotRaceAheadOfCommit() throws {
        var batcher = WhoopPacketBatcher(maximumBatchSize: 128)
        let history = WhoopPacketEnvelope.proprietary(
            packet: historicalFrame(timestamp: 1_800_000_000, stepCounter: 1),
            peripheralID: UUID(),
            characteristicUUID: "FD4B0003",
            offloadSessionID: "session",
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_001),
            proprietaryOrdinal: 1
        )
        let chunkEnd = WhoopPacketEnvelope.proprietary(
            packet: WhoopTestFrameFactory.historicalMetadata(
                type: 2,
                chunkEnd: [1, 2, 3, 4, 5, 6, 7, 8]
            ),
            peripheralID: history.peripheralID,
            characteristicUUID: "FD4B0003",
            offloadSessionID: "session",
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_002),
            proprietaryOrdinal: 2
        )

        XCTAssertNil(batcher.ingest(history))
        let batch = try XCTUnwrap(batcher.ingest(chunkEnd))

        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.last?.metadata?.type, .chunkEnd)
        XCTAssertEqual(batch.last?.metadata?.chunkEndData, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testBatcherSplitsLargeBurstAtHardBound() throws {
        var batcher = WhoopPacketBatcher(maximumBatchSize: 128)
        var committedSizes: [Int] = []
        for index in 0..<257 {
            let envelope = try standardEnvelope(
                heartRate: UInt8(60 + index % 100),
                deliveredAt: TimeInterval(index)
            )
            if let batch = batcher.ingest(envelope) {
                committedSizes.append(batch.count)
            }
        }
        committedSizes.append(try XCTUnwrap(batcher.drain()).count)

        XCTAssertEqual(committedSizes, [128, 128, 1])
    }

    func testOneHundredTwentyEightPacketsUseOneIngestionTransaction() async throws {
        let fixture = try makeStoreFixture()
        defer {
            fixture.store.shutdownForTesting()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let envelopes = try (0..<128).map { index in
            try standardEnvelope(
                heartRate: UInt8(60 + index % 100),
                deliveredAt: TimeInterval(1_800_000_000 + index)
            )
        }

        let result = await appendBatch(envelopes, store: fixture.store)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.committedEnvelopeCount, 128)
        XCTAssertEqual(fixture.store.ingestionTransactionCountForTesting(), 1)
        let database = try openReadOnlyDatabase(fixture.databaseURL)
        defer { sqlite3_close(database) }
        XCTAssertEqual(scalarInt(database, "SELECT COUNT(*) FROM whoop_raw_packet"), 128)
    }

    func testPipelineParsesAndPersistsOffMainInOneFIFOQueue() throws {
        let fixture = try makeStoreFixture()
        defer {
            fixture.store.shutdownForTesting()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let recorder = TransportCallbackRecorder()
        let pipeline = WhoopTransportPipeline(
            store: fixture.store,
            idleFlushDelay: 60,
            didPublishUI: { snapshot in recorder.recordUI(snapshot) },
            didPersist: { result, summary in recorder.recordPersistence(result, summary) }
        )

        pipeline.submitStandardHeartRate(
            packet: Data([0, 61]),
            peripheralID: fixture.peripheralID,
            characteristicUUID: "2A37",
            deliveredAt: Date(timeIntervalSince1970: 1)
        )
        pipeline.submitStandardHeartRate(
            packet: Data([0, 62]),
            peripheralID: fixture.peripheralID,
            characteristicUUID: "2A37",
            deliveredAt: Date(timeIntervalSince1970: 2)
        )
        pipeline.flushAndWaitForPersistence { recorder.recordDrain() }

        XCTAssertEqual(recorder.drainSemaphore.wait(timeout: .now() + 5), .success)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.persistedBatchSizes, [2])
        XCTAssertEqual(snapshot.uiHeartRates, [61, 62])
        XCTAssertTrue(snapshot.callbacksWereOffMain)
        XCTAssertEqual(fixture.store.ingestionTransactionCountForTesting(), 1)
    }

    func testStoreCommitsHistoricalBatchInOneTransaction() async throws {
        let fixture = try makeStoreFixture()
        defer {
            fixture.store.shutdownForTesting()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let sessionID = try await beginOffload(
            store: fixture.store,
            peripheralID: fixture.peripheralID
        )
        let packets = [
            historicalFrame(timestamp: 1_800_000_000, stepCounter: 100),
            historicalFrame(timestamp: 1_800_000_001, stepCounter: 103),
            WhoopTestFrameFactory.historicalMetadata(type: 3, length: 16),
        ]
        let envelopes = packets.enumerated().map { index, packet in
            WhoopPacketEnvelope.proprietary(
                packet: packet,
                peripheralID: fixture.peripheralID,
                characteristicUUID: "FD4B0003",
                offloadSessionID: sessionID,
                deliveredAt: Date(timeIntervalSince1970: 1_800_000_010 + Double(index)),
                proprietaryOrdinal: index + 1
            )
        }

        let result = await appendBatch(envelopes, store: fixture.store)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.committedEnvelopeCount, 3)
        XCTAssertEqual(result.deliverySequences, [1, 2, 3])
        XCTAssertEqual(fixture.store.ingestionTransactionCountForTesting(), 1)
        XCTAssertTrue(fixture.store.completedOffloadCoversLatestHistoryForTesting())
        let database = try openReadOnlyDatabase(fixture.databaseURL)
        defer { sqlite3_close(database) }
        XCTAssertEqual(scalarInt(database, "SELECT COUNT(*) FROM whoop_raw_packet"), 3)
        XCTAssertEqual(scalarInt(database, "SELECT COUNT(*) FROM whoop_historical_sample"), 2)
        XCTAssertEqual(
            scalarInt(
                database,
                "SELECT COUNT(*) FROM whoop_offload_session WHERE status = 'complete'"
            ),
            1
        )
    }

    func testStoreRollsBackEntireBatchWhenOneEnvelopeCannotAdvanceSession() async throws {
        let fixture = try makeStoreFixture()
        defer {
            fixture.store.shutdownForTesting()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let first = WhoopPacketEnvelope.proprietary(
            packet: historicalFrame(timestamp: 1_800_000_000, stepCounter: 100),
            peripheralID: fixture.peripheralID,
            characteristicUUID: "FD4B0003",
            offloadSessionID: nil,
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_010),
            proprietaryOrdinal: 1
        )
        let invalidSession = WhoopPacketEnvelope.proprietary(
            packet: historicalFrame(timestamp: 1_800_000_001, stepCounter: 101),
            peripheralID: fixture.peripheralID,
            characteristicUUID: "FD4B0003",
            offloadSessionID: "missing-session",
            deliveredAt: Date(timeIntervalSince1970: 1_800_000_011),
            proprietaryOrdinal: 2
        )

        let result = await appendBatch([first, invalidSession], store: fixture.store)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.committedEnvelopeCount, 0)
        XCTAssertEqual(fixture.store.ingestionTransactionCountForTesting(), 1)
        let database = try openReadOnlyDatabase(fixture.databaseURL)
        defer { sqlite3_close(database) }
        XCTAssertEqual(scalarInt(database, "SELECT COUNT(*) FROM whoop_raw_packet"), 0)
        XCTAssertEqual(scalarInt(database, "SELECT COUNT(*) FROM whoop_historical_sample"), 0)
    }

    func testEnvelopeParsingPerformance() {
        let packet = historicalFrame(timestamp: 1_800_000_000, stepCounter: 321)
        let peripheralID = UUID()
        measure(metrics: [XCTClockMetric()]) {
            var validCount = 0
            for ordinal in 1...10_000 {
                let envelope = WhoopPacketEnvelope.proprietary(
                    packet: packet,
                    peripheralID: peripheralID,
                    characteristicUUID: "FD4B0003",
                    offloadSessionID: "session",
                    deliveredAt: Date(timeIntervalSince1970: 1_800_000_010),
                    proprietaryOrdinal: ordinal
                )
                if envelope.integrityIsValid { validCount += 1 }
            }
            XCTAssertEqual(validCount, 10_000)
        }
    }

    private func historicalFrame(timestamp: UInt32, stepCounter: UInt16) -> Data {
        var bytes = WhoopTestFrameFactory.frame(length: 124, type: 47, version: 18)
        bytes[15] = UInt8(truncatingIfNeeded: timestamp)
        bytes[16] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[22] = 55
        bytes[57] = UInt8(truncatingIfNeeded: stepCounter)
        bytes[58] = UInt8(truncatingIfNeeded: stepCounter >> 8)
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return Data(bytes)
    }

    private func standardEnvelope(
        heartRate: UInt8,
        deliveredAt: TimeInterval
    ) throws -> WhoopPacketEnvelope {
        try XCTUnwrap(
            WhoopPacketEnvelope.standardHeartRate(
                packet: Data([0, heartRate]),
                peripheralID: UUID(),
                characteristicUUID: "2A37",
                deliveredAt: Date(timeIntervalSince1970: deliveredAt)
            ))
    }

    private func makeStoreFixture() throws -> (
        directory: URL,
        databaseURL: URL,
        store: WhoopStore,
        peripheralID: UUID
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        return (
            directory,
            databaseURL,
            WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false),
            UUID()
        )
    }

    private func beginOffload(store: WhoopStore, peripheralID: UUID) async throws -> String {
        let sessionID: String? = await withCheckedContinuation { continuation in
            store.beginHistoricalOffload(peripheralID: peripheralID) {
                continuation.resume(returning: $0)
            }
        }
        return try XCTUnwrap(sessionID)
    }

    private func appendBatch(
        _ envelopes: [WhoopPacketEnvelope],
        store: WhoopStore
    ) async -> WhoopPacketBatchPersistenceResult {
        await withCheckedContinuation { continuation in
            store.appendBatch(envelopes) { continuation.resume(returning: $0) }
        }
    }

    private func openReadOnlyDatabase(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else { throw CocoaError(.fileReadUnknown) }
        return database
    }

    private func scalarInt(_ database: OpaquePointer?, _ sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }
}

private final class TransportCallbackRecorder: @unchecked Sendable {
    let drainSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var persistedBatchSizes: [Int] = []
    private var uiHeartRates: [Int] = []
    private var callbacksWereOffMain = true

    func recordUI(_ snapshot: WhoopTransportUISnapshot) {
        lock.withLock {
            if let heartRate = snapshot.heartRate { uiHeartRates.append(heartRate) }
            callbacksWereOffMain = callbacksWereOffMain && !Thread.isMainThread
        }
    }

    func recordPersistence(
        _ result: WhoopPacketBatchPersistenceResult,
        _ summary: WhoopTransportBatchSummary
    ) {
        lock.withLock {
            persistedBatchSizes.append(result.committedEnvelopeCount)
            callbacksWereOffMain = callbacksWereOffMain && !Thread.isMainThread
            callbacksWereOffMain = callbacksWereOffMain && summary.firstProprietaryOrdinal == nil
        }
    }

    func recordDrain() {
        lock.withLock {
            callbacksWereOffMain = callbacksWereOffMain && !Thread.isMainThread
        }
        drainSemaphore.signal()
    }

    func snapshot() -> (
        persistedBatchSizes: [Int],
        uiHeartRates: [Int],
        callbacksWereOffMain: Bool
    ) {
        lock.withLock {
            (persistedBatchSizes, uiHeartRates, callbacksWereOffMain)
        }
    }
}
