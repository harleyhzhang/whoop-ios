import XCTest
import SQLite3
@testable import Sleep

final class WhoopSleepStateTests: XCTestCase {
    func testReconnectPolicyBacksOffAndCapsAtOneMinute() {
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 0), 2)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 1), 4)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 4), 32)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 5), 60)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 100), 60)
    }

    func testManualSleepProcessingAlwaysUsesCurrentOrFreshOffload() {
        XCTAssertEqual(
            WhoopHandshakeProbe.sleepProcessStart(
                isConnected: true,
                historicalSyncActive: true
            ),
            .waitForCurrentOffload
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.sleepProcessStart(
                isConnected: true,
                historicalSyncActive: false
            ),
            .startFreshOffload
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.sleepProcessStart(
                isConnected: false,
                historicalSyncActive: false
            ),
            .unavailable
        )
    }

    func testReplayIndexIsLimitedToReplayPronePacketClasses() {
        XCTAssertFalse(WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: nil))
        XCTAssertFalse(WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: 40))
        XCTAssertTrue(WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: 47))
        XCTAssertTrue(WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: 49))
        XCTAssertTrue(WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: 50))
    }

    func testBatteryLevelStatusReportsChargingOrExternalPower() {
        XCTAssertEqual(
            WhoopHandshakeProbe.batteryLevelStatusCharging(Data([0x02, 0x23, 0x00, 68])),
            true
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.batteryLevelStatusCharging(Data([0x02, 0x63, 0x00, 100])),
            true
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.batteryLevelStatusCharging(Data([0x02, 0x41, 0x00, 67])),
            false
        )
        XCTAssertNil(WhoopHandshakeProbe.batteryLevelStatusCharging(Data([0x02, 0x01, 0x00])))
    }

    func testLegacyBatteryPowerStateReportsCharging() {
        XCTAssertEqual(WhoopHandshakeProbe.legacyBatteryPowerStateCharging(Data([0x30])), true)
        XCTAssertEqual(WhoopHandshakeProbe.legacyBatteryPowerStateCharging(Data([0x20])), false)
        XCTAssertNil(WhoopHandshakeProbe.legacyBatteryPowerStateCharging(Data([0x00])))
    }

    func testFreshWristEventsReportOnAndOffState() {
        let timestamp: UInt32 = 1_800_000_000
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(timestamp + 20))

        XCTAssertEqual(
            WhoopHandshakeProbe.freshWhoop5WristState(
                wristEventFrame(event: 9, timestamp: timestamp),
                receivedAt: receivedAt
            ),
            true
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.freshWhoop5WristState(
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
            WhoopHandshakeProbe.freshWhoop5WristState(
                event,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp + 46))
            )
        )

        var corruptEvent = event
        corruptEvent[10] ^= 0x01
        XCTAssertNil(
            WhoopHandshakeProbe.freshWhoop5WristState(
                corruptEvent,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
            )
        )
    }

    func testInterimUpStateDoesNotSplitOneNight() {
        var firstRun: [WhoopStore.HistoricalRow] = []
        for timestamp in stride(from: 0.0, through: 7 * 60 * 60, by: 20.0) {
            firstRun.append(row(at: timestamp, state: 2))
        }
        var resumedRun: [WhoopStore.HistoricalRow] = []
        let resumedStart = 8.0 * 60 * 60
        let resumedEnd = resumedStart + 15 * 60
        for timestamp in stride(from: resumedStart, through: resumedEnd, by: 20.0) {
            resumedRun.append(row(at: timestamp, state: 2))
        }

        let groups = WhoopStore.groupedAsleepRows(firstRun + resumedRun)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].first?.timestamp, 0)
        XCTAssertEqual(groups[0].last?.timestamp, 8 * 60 * 60 + 15 * 60)
    }

    func testLongGapStartsANewSleep() {
        let rows = [
            row(at: 0, state: 2),
            row(at: 60, state: 2),
            row(at: 2 * 60 * 60, state: 2),
        ]

        XCTAssertEqual(WhoopStore.groupedAsleepRows(rows).count, 2)
    }

    func testUpStateGroupsOneNightButDoesNotAddSleepDuration() {
        let asleep = [
            row(at: 0, state: 2),
            row(at: 60, state: 2),
            row(at: 20 * 60, state: 2),
            row(at: 21 * 60, state: 2),
        ]

        XCTAssertEqual(WhoopStore.groupedAsleepRows(asleep).count, 1)
        XCTAssertEqual(
            WhoopStore.elapsedSeconds(across: asleep, cadence: 60),
            4 * 60,
            accuracy: 0.001
        )
    }

    func testObservedAsleepRangesExcludeLongUpInterval() {
        let asleep = [
            row(at: 0, state: 2),
            row(at: 60, state: 2),
            row(at: 20 * 60, state: 2),
            row(at: 21 * 60, state: 2),
        ]

        let ranges = WhoopStore.observedAsleepRanges(rows: asleep, cadence: 60)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertFalse(ranges.contains { $0.contains(10 * 60) })
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

        XCTAssertNil(WhoopStore.rmssdFromRealtimePackets(
            packets,
            minimumDifferencesPerWindow: 1
        ))
    }

    func testRealtimeRMSSDRejectsImplausibleBeatWithoutBridgingIt() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900, 100, 1_000]),
        ]

        XCTAssertNil(WhoopStore.rmssdFromRealtimePackets(
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

    func testPrimaryMetricsMustArriveTogether() {
        let partial = DailyHealthRecord(
            dateKey: "2026-09-05",
            sleepScore: 82,
            sleepDurationMinutes: 426,
            hrvRMSSDMilliseconds: nil,
            restingHeartRateBPM: nil,
            sleepID: "partial",
            cycleID: nil,
            source: "whoop5_local_v2",
            sourceArchive: nil,
            sourceUpdatedAt: "2026-09-05T13:46:00Z"
        )
        let complete = DailyHealthRecord(
            dateKey: "2026-09-05",
            sleepScore: 96,
            sleepDurationMinutes: 501,
            hrvRMSSDMilliseconds: 62,
            restingHeartRateBPM: 49,
            sleepID: "complete",
            cycleID: nil,
            source: "whoop5_local_v2",
            sourceArchive: nil,
            sourceUpdatedAt: "2026-09-05T16:23:00Z"
        )

        XCTAssertFalse(partial.hasCompletePrimarySleepMetrics)
        XCTAssertTrue(complete.hasCompletePrimarySleepMetrics)
    }

    func testFullerCoherentOffloadRepairsPrematureLocalNight() {
        XCTAssertTrue(WhoopStore.shouldReplaceLocalSleep(
            existingDurationMinutes: 230.4,
            candidateDurationMinutes: 512
        ))
    }

    func testPartialOffloadCannotShrinkStoredNight() {
        XCTAssertFalse(WhoopStore.shouldReplaceLocalSleep(
            existingDurationMinutes: 512,
            candidateDurationMinutes: 230.4
        ))
    }

    func testCadenceJitterDoesNotRewriteSettledNight() {
        XCTAssertFalse(WhoopStore.shouldReplaceLocalSleep(
            existingDurationMinutes: 512,
            candidateDurationMinutes: 512.5
        ))
    }

    func testHeartRateFreshnessRejectsOldCachedReading() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(WhoopHandshakeProbe.heartRateIsFresh(
            receivedAt: now.addingTimeInterval(-30),
            now: now
        ))
        XCTAssertFalse(WhoopHandshakeProbe.heartRateIsFresh(
            receivedAt: now.addingTimeInterval(-91),
            now: now
        ))
        XCTAssertFalse(WhoopHandshakeProbe.heartRateIsFresh(
            receivedAt: nil,
            now: now
        ))
    }

    func testPacketReplaySignatureIncludesCharacteristicAndPayload() {
        let peripheral = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let payload = Data([0xAA, 0x01, 0x02])
        let first = WhoopStore.packetSignature(peripheralID: peripheral, characteristicUUID: "FD4B0003", payload: payload)
        let repeated = WhoopStore.packetSignature(peripheralID: peripheral, characteristicUUID: "fd4b0003", payload: payload)
        let differentCharacteristic = WhoopStore.packetSignature(peripheralID: peripheral, characteristicUUID: "FD4B0004", payload: payload)
        let differentPayload = WhoopStore.packetSignature(
            peripheralID: peripheral,
            characteristicUUID: "FD4B0003",
            payload: Data([0xAA, 0x01, 0x03])
        )
        let differentPeripheral = WhoopStore.packetSignature(
            peripheralID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
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
        var bytes = framedPacket(length: 24, type: 40, version: 1)
        let timestamp: UInt32 = 1_800_000_000
        bytes[10] = UInt8(truncatingIfNeeded: timestamp)
        bytes[11] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[12] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[13] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[16] = 61
        bytes[17] = 1
        bytes[18] = 0x84
        bytes[19] = 0x03
        finishChecksums(&bytes)

        let decoded = WhoopDecodedRealtime.decodeWhoop5Realtime(Data(bytes))
        XCTAssertEqual(decoded?.deviceTimestamp, timestamp)
        XCTAssertEqual(decoded?.heartRate, 61)
        XCTAssertEqual(decoded?.rrIntervals, [900])

        bytes[18] ^= 0x01
        XCTAssertNil(WhoopDecodedRealtime.decodeWhoop5Realtime(Data(bytes)))
    }

    func testEmptyLegacyDatabaseMigratesIdempotentlyToCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            _ = store
        }
        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            _ = store
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(scalarInt(database, sql: "PRAGMA user_version"), 4)
        XCTAssertEqual(scalarInt(
            database,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_decode_result','whoop_ppg_packet','whoop_store_metadata')"
        ), 3)
    }

    func testOffloadCompletionRequiresDurableCRCValidCompletionAfterHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
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
        let packet = version18Frame(timestamp: 1_800_000_000, sleepState: 2)

        let first = try await append(
            packet,
            store: store,
            peripheral: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionID: nil
        )
        let second = try await append(
            packet,
            store: store,
            peripheral: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
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
    }

    private func row(at timestamp: TimeInterval, state: Int) -> WhoopStore.HistoricalRow {
        WhoopStore.HistoricalRow(
            timestamp: timestamp,
            heartRate: 55,
            rrIntervals: [1_000],
            sleepState: state
        )
    }

    private func version26Frame(
        timestamp: UInt32,
        channel: UInt8,
        samples: [Int16]
    ) -> Data {
        precondition(samples.count == 24)
        var bytes = [UInt8](repeating: 0, count: 88)
        bytes[0] = 0xAA
        bytes[1] = 0x01
        bytes[2] = 80
        bytes[4] = 0x01
        bytes[8] = 47
        bytes[9] = 26
        bytes[15] = UInt8(truncatingIfNeeded: timestamp)
        bytes[16] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[21] = channel
        for (index, sample) in samples.enumerated() {
            let raw = UInt16(bitPattern: sample)
            bytes[27 + index * 2] = UInt8(truncatingIfNeeded: raw)
            bytes[28 + index * 2] = UInt8(truncatingIfNeeded: raw >> 8)
        }
        let headerCRC = WhoopFrameIntegrity.crc16Modbus(bytes[0..<6])
        bytes[6] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[7] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        let crc = WhoopFrameIntegrity.crc32(bytes[8..<84])
        bytes[84] = UInt8(truncatingIfNeeded: crc)
        bytes[85] = UInt8(truncatingIfNeeded: crc >> 8)
        bytes[86] = UInt8(truncatingIfNeeded: crc >> 16)
        bytes[87] = UInt8(truncatingIfNeeded: crc >> 24)
        return Data(bytes)
    }

    private func version18Frame(timestamp: UInt32, sleepState: UInt8) -> Data {
        var bytes = framedPacket(length: 124, type: 47, version: 18)
        bytes[15] = UInt8(truncatingIfNeeded: timestamp)
        bytes[16] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[22] = 55
        bytes[81] = sleepState << 4
        finishChecksums(&bytes)
        return Data(bytes)
    }

    private func metadataFrame(type: UInt8) -> Data {
        var bytes = framedPacket(length: 16, type: 49, version: 1)
        bytes[10] = type
        finishChecksums(&bytes)
        return Data(bytes)
    }

    private func wristEventFrame(event: UInt8, timestamp: UInt32) -> Data {
        var bytes = framedPacket(length: 20, type: 48, version: 1)
        bytes[10] = event
        bytes[12] = UInt8(truncatingIfNeeded: timestamp)
        bytes[13] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[14] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[15] = UInt8(truncatingIfNeeded: timestamp >> 24)
        finishChecksums(&bytes)
        return Data(bytes)
    }

    private func framedPacket(length: Int, type: UInt8, version: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 0xAA
        bytes[1] = 0x01
        let declared = UInt16(length - 8)
        bytes[2] = UInt8(truncatingIfNeeded: declared)
        bytes[3] = UInt8(truncatingIfNeeded: declared >> 8)
        bytes[4] = 0x01
        bytes[8] = type
        bytes[9] = version
        return bytes
    }

    private func finishChecksums(_ bytes: inout [UInt8]) {
        let headerCRC = WhoopFrameIntegrity.crc16Modbus(bytes[0..<6])
        bytes[6] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[7] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        let payloadEnd = bytes.count - 4
        let crc = WhoopFrameIntegrity.crc32(bytes[8..<payloadEnd])
        bytes[payloadEnd] = UInt8(truncatingIfNeeded: crc)
        bytes[payloadEnd + 1] = UInt8(truncatingIfNeeded: crc >> 8)
        bytes[payloadEnd + 2] = UInt8(truncatingIfNeeded: crc >> 16)
        bytes[payloadEnd + 3] = UInt8(truncatingIfNeeded: crc >> 24)
    }

    private func beginOffload(store: WhoopStore, peripheral: UUID) async throws -> String {
        let result: String? = await withCheckedContinuation { continuation in
            store.beginHistoricalOffload(peripheralID: peripheral) {
                continuation.resume(returning: $0)
            }
        }
        return try XCTUnwrap(result)
    }

    private func append(
        _ packet: Data,
        store: WhoopStore,
        peripheral: UUID,
        sessionID: String?
    ) async throws -> WhoopPacketPersistenceResult {
        let result: WhoopPacketPersistenceResult = await withCheckedContinuation { continuation in
            store.append(
                packet: packet,
                peripheralID: peripheral,
                characteristicUUID: "FD4B0003",
                frameType: packet.count > 8 ? packet[8] : nil,
                realtime: nil,
                historical: WhoopDecodedHistorical.decode(packet),
                offloadSessionID: sessionID
            ) {
                continuation.resume(returning: $0)
            }
        }
        return result
    }

    private func scalarInt(_ database: OpaquePointer?, sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }
}
