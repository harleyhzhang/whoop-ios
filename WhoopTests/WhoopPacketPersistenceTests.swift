import SQLite3
import XCTest

@testable import Whoop

extension WhoopSleepStateTests {
    func testReplayIndexIsLimitedToReplayPronePacketClasses() {
        XCTAssertFalse((nil as FrameType?).map(\.isReplayProne) ?? false)
        XCTAssertFalse(FrameType.realtimeHeartRate.isReplayProne)
        XCTAssertTrue(FrameType.historicalSample.isReplayProne)
        XCTAssertTrue(FrameType.historicalMetadata.isReplayProne)
        XCTAssertTrue(FrameType.transport50.isReplayProne)
    }

    func testFreshWristEventsReportOnAndOffState() {
        let timestamp: UInt32 = 1_800_000_000
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(timestamp + 20))

        XCTAssertEqual(
            WhoopBluetoothPolicy.freshWristState(
                wristEventFrame(event: 9, timestamp: timestamp),
                receivedAt: receivedAt
            ),
            true
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.freshWristState(
                wristEventFrame(event: 10, timestamp: timestamp),
                receivedAt: receivedAt
            ),
            false
        )
    }

    func testStaleOrCorruptWristEventsCannotScheduleWearState() {
        let timestamp: UInt32 = 1_800_000_000
        let event = wristEventFrame(event: 10, timestamp: timestamp)
        XCTAssertNil(
            WhoopBluetoothPolicy.freshWristState(
                event,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp + 46))
            )
        )

        var corruptEvent = event
        corruptEvent[10] ^= 0x01
        XCTAssertNil(
            WhoopBluetoothPolicy.freshWristState(
                corruptEvent,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
            )
        )
    }

    func testRealtimeRMSSDUsesAdjacentPackets() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900, 1_000]),
            WhoopStore.RealtimeRRPacket(timestamp: 2, intervals: [900]),
        ]

        let value = WhoopStore.rmssdFromRealtimePackets(
            packets,
            minimumDifferencesPerWindow: 2
        )

        XCTAssertNotNil(value)
        XCTAssertEqual(value ?? 0, 100, accuracy: 0.001)
    }

    func testRealtimeRMSSDBreaksContinuityAcrossDeliveryGap() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900]),
            WhoopStore.RealtimeRRPacket(timestamp: 10, intervals: [1_000]),
        ]

        XCTAssertNil(
            WhoopStore.rmssdFromRealtimePackets(
                packets,
                minimumDifferencesPerWindow: 1
            ))
    }

    func testRealtimeRMSSDRejectsImplausibleBeatWithoutBridgingIt() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900, 100, 1_000])
        ]

        XCTAssertNil(
            WhoopStore.rmssdFromRealtimePackets(
                packets,
                minimumDifferencesPerWindow: 1
            ))
    }

    func testRealtimeRMSSDUsesRobustMedianAcrossWindows() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900, 1_000]),
            WhoopStore.RealtimeRRPacket(timestamp: 301, intervals: [900, 950]),
            WhoopStore.RealtimeRRPacket(timestamp: 601, intervals: [800, 1_000]),
        ]

        let value = WhoopStore.rmssdFromRealtimePackets(
            packets,
            minimumDifferencesPerWindow: 1
        )

        XCTAssertEqual(value ?? 0, 100, accuracy: 0.001)
    }

    func testRealtimeRMSSDPerformanceAcrossEightHourStream() {
        let packets = (0..<(8 * 60 * 60)).map { second in
            WhoopStore.RealtimeRRPacket(
                timestamp: TimeInterval(second),
                intervals: [UInt16(second.isMultiple(of: 2) ? 900 : 1_000)].map(Double.init)
            )
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric()], options: options) {
            XCTAssertNotNil(WhoopStore.rmssdFromRealtimePackets(packets))
        }
    }

    func testPacketReplaySignatureIncludesCharacteristicAndPayload() throws {
        let peripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let otherPeripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let payload = Data([0xAA, 0x01, 0x02])
        let first = WhoopStore.packetSignature(
            peripheralID: peripheral, characteristicUUID: "FD4B0003", payload: payload)
        let repeated = WhoopStore.packetSignature(
            peripheralID: peripheral, characteristicUUID: "fd4b0003", payload: payload)
        let differentCharacteristic = WhoopStore.packetSignature(
            peripheralID: peripheral, characteristicUUID: "FD4B0004", payload: payload)
        let differentPayload = WhoopStore.packetSignature(
            peripheralID: peripheral,
            characteristicUUID: "FD4B0003",
            payload: Data([0xAA, 0x01, 0x03])
        )
        let differentPeripheral = WhoopStore.packetSignature(
            peripheralID: otherPeripheral,
            characteristicUUID: "FD4B0003",
            payload: payload
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, differentCharacteristic)
        XCTAssertNotEqual(first, differentPayload)
        XCTAssertNotEqual(first, differentPeripheral)
    }

    func testVersion26PPGDecoderPreservesSignedWaveformAndChannel() {
        let expected = (0..<24).map { Int16($0 - 12) }
        let frame = version26Frame(timestamp: 1_800_000_000, channel: 39, samples: expected)

        let decoded = WhoopDecodedPPG.decode(frame)

        XCTAssertEqual(decoded?.sampleAt.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(decoded?.channel, 39)
        XCTAssertEqual(decoded?.samples, expected)
    }

    func testVersion26PPGDecoderRejectsCorruptCRC() {
        var frame = version26Frame(
            timestamp: 1_800_000_000,
            channel: 1,
            samples: Array(repeating: 1, count: 24)
        )
        frame[30] ^= 0xFF

        XCTAssertNil(WhoopDecodedPPG.decode(frame))
    }

    func testStandardHeartRateDecoderConverts1024HzRRUnits() {
        let decoded = WhoopDecodedRealtime.decodeStandardHeartRate(
            Data([0x10, 60, 0x00, 0x04, 0x00, 0x02])
        )

        XCTAssertEqual(decoded?.heartRate, 60)
        XCTAssertEqual(decoded?.rrIntervals, [1_000, 500])
        XCTAssertEqual(decoded?.source, "standard_2a37")
    }

    func testStandardHeartRateDecoderHandlesUInt16AndEnergyField() {
        let decoded = WhoopDecodedRealtime.decodeStandardHeartRate(
            Data([0x19, 0x04, 0x01, 0x34, 0x12, 0x00, 0x04])
        )

        XCTAssertEqual(decoded?.heartRate, 260)
        XCTAssertEqual(decoded?.rrIntervals, [1_000])
    }

    func testWhoop5RealtimeDecoderRequiresCRCAndPreservesTimestamp() {
        var bytes = WhoopTestFrameFactory.frame(length: 24, type: 40, version: 1)
        let timestamp: UInt32 = 1_800_000_000
        bytes[10] = UInt8(truncatingIfNeeded: timestamp)
        bytes[11] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[12] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[13] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[16] = 61
        bytes[17] = 1
        bytes[18] = 0x84
        bytes[19] = 0x03
        WhoopTestFrameFactory.finishChecksums(&bytes)

        let decoded = WhoopDecodedRealtime.decodeWhoop5Realtime(Data(bytes))
        XCTAssertEqual(decoded?.deviceTimestamp, timestamp)
        XCTAssertEqual(decoded?.heartRate, 61)
        XCTAssertEqual(decoded?.rrIntervals, [900])

        bytes[18] ^= 0x01
        XCTAssertNil(WhoopDecodedRealtime.decodeWhoop5Realtime(Data(bytes)))
    }

    func testHistoricalInsertReleasesCachedTimezoneReaderForCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }

        let packet = version18Frame(
            timestamp: UInt32(Date().timeIntervalSince1970),
            sleepState: 0,
            stepCounter: 100
        )
        let persisted = try await append(
            packet,
            store: store,
            peripheral: UUID(),
            sessionID: nil
        )
        XCTAssertTrue(persisted.success)

        var checkpointConnection: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                databaseURL.path,
                &checkpointConnection,
                SQLITE_OPEN_READWRITE,
                nil
            ),
            SQLITE_OK
        )
        guard let checkpointConnection else {
            XCTFail("Could not open checkpoint fixture")
            return
        }
        defer { sqlite3_close(checkpointConnection) }
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        XCTAssertEqual(
            sqlite3_wal_checkpoint_v2(
                checkpointConnection,
                nil,
                SQLITE_CHECKPOINT_TRUNCATE,
                &logFrames,
                &checkpointedFrames
            ),
            SQLITE_OK,
            "A cached SELECT must not retain a reader after packet persistence finishes"
        )
    }

    func testRealtimeStorageKeepsLatestValueWithoutIndexingEmptyRRHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let repeatedPacket = Data([0xAA, 0x01, 0x28])

        let first = await appendRealtime(
            repeatedPacket,
            heartRate: 60,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 100),
            store: store,
            peripheral: peripheral
        )
        let duplicate = await appendRealtime(
            repeatedPacket,
            heartRate: 61,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 200),
            store: store,
            peripheral: peripheral
        )
        let withRR = await appendRealtime(
            Data([0xAA, 0x01, 0x29]),
            heartRate: 62,
            rrIntervals: [900],
            deliveredAt: Date(timeIntervalSince1970: 300),
            store: store,
            peripheral: peripheral
        )
        let stale = await appendRealtime(
            Data([0xAA, 0x01, 0x2A]),
            heartRate: 70,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 250),
            store: store,
            peripheral: peripheral
        )
        let invalidLatest = await appendRealtime(
            Data([0xAA, 0x01, 0x2B]),
            heartRate: 0,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 400),
            store: store,
            peripheral: peripheral
        )

        XCTAssertTrue(first.success)
        XCTAssertTrue(duplicate.success)
        XCTAssertTrue(withRR.success)
        XCTAssertTrue(stale.success)
        XCTAssertTrue(invalidLatest.success)
        let latest: WhoopLatestHeartRateSample? = await withCheckedContinuation { continuation in
            store.loadLatestHeartRateSample { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(latest?.heartRate, 62)
        XCTAssertEqual(latest?.receivedAt, Date(timeIntervalSince1970: 300))

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_raw_packet"), 4)
        XCTAssertEqual(scalarInt(database, sql: "SELECT SUM(duplicate_count) FROM whoop_packet_replay"), 1)
        XCTAssertEqual(scalarInt(database, sql: "SELECT COUNT(*) FROM heart_rate_sample"), 1)
    }

    func testCompletionLookupSkipsLivePacketsWithoutScanningRetainedHistory() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        let fixture = """
            CREATE TABLE whoop_raw_packet(id TEXT PRIMARY KEY, delivery_sequence INTEGER);
            CREATE INDEX whoop_raw_packet_delivery_sequence ON whoop_raw_packet(delivery_sequence);
            CREATE TABLE whoop_historical_sample(source_packet_id TEXT NOT NULL UNIQUE);
            CREATE TABLE whoop_offload_session(status TEXT, completion_sequence INTEGER);
            WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<20010)
            INSERT INTO whoop_raw_packet SELECT CAST(n AS TEXT), n FROM numbers;
            INSERT INTO whoop_historical_sample SELECT id FROM whoop_raw_packet WHERE delivery_sequence<=20000;
            INSERT INTO whoop_offload_session VALUES ('complete', 20001), ('abandoned', 20020);
            """
        XCTAssertEqual(sqlite3_exec(opened, fixture, nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(opened, WhoopStore.completedOffloadCoverageQuery, -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(prepared, 0), 20000)
        XCTAssertEqual(sqlite3_column_int64(prepared, 1), 20001)
        XCTAssertLessThan(sqlite3_stmt_status(prepared, SQLITE_STMTSTATUS_VM_STEP, 0), 1000)
        sqlite3_reset(prepared)
        XCTAssertEqual(
            sqlite3_exec(opened, "INSERT INTO whoop_historical_sample VALUES ('20010')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(prepared, 0), 20010)
        XCTAssertEqual(sqlite3_column_int64(prepared, 1), 20001)
        sqlite3_reset(prepared)
        XCTAssertEqual(sqlite3_exec(opened, "DELETE FROM whoop_historical_sample", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(prepared, 0), 0)
    }

    func testOffloadCompletionRequiresDurableCRCValidCompletionAfterHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let sessionID = try await beginOffload(store: store, peripheral: peripheral)
        let history = version18Frame(timestamp: 1_800_000_000, sleepState: 2)

        let historyResult = try await append(
            history,
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(historyResult.success)
        XCTAssertFalse(store.completedOffloadCoversLatestHistoryForTesting())

        let completion = metadataFrame(type: 3)
        let completionResult = try await append(
            completion,
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(completionResult.success)
        XCTAssertTrue(store.completedOffloadCoversLatestHistoryForTesting())

        let newerHistoryResult = try await append(
            version18Frame(timestamp: 1_800_000_100, sleepState: 2),
            store: store,
            peripheral: peripheral,
            sessionID: nil
        )
        XCTAssertTrue(newerHistoryResult.success)
        XCTAssertFalse(store.completedOffloadCoversLatestHistoryForTesting())
    }

    func testCorruptCompletionCannotCompleteOffload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let sessionID = try await beginOffload(store: store, peripheral: peripheral)
        let historyResult = try await append(
            version18Frame(timestamp: 1_800_000_000, sleepState: 2),
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(historyResult.success)
        var completion = metadataFrame(type: 3)
        completion[11] ^= 0x01
        let completionResult = try await append(
            completion,
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(completionResult.success)

        XCTAssertFalse(store.completedOffloadCoversLatestHistoryForTesting())
    }

    func testSameHistoricalTimestampFromDifferentStrapsDoesNotCollide() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }
        let packet = version18Frame(timestamp: 1_800_000_000, sleepState: 2)
        let firstPeripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondPeripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        let first = try await append(
            packet,
            store: store,
            peripheral: firstPeripheral,
            sessionID: nil
        )
        let second = try await append(
            packet,
            store: store,
            peripheral: secondPeripheral,
            sessionID: nil
        )
        XCTAssertTrue(first.success)
        XCTAssertTrue(second.success)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(
            scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample"),
            2
        )
        XCTAssertLessThanOrEqual(
            scalarInt(database, sql: "SELECT MAX(length(id)) FROM whoop_raw_packet"),
            8,
            "New raw evidence should use compact sequence-derived IDs, not UUID text"
        )
    }
}
