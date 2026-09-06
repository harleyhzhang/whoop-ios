import XCTest
import SQLite3
@testable import Sleep

final class WhoopSleepStateTests: XCTestCase {
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
        XCTAssertEqual(scalarInt(database, sql: "PRAGMA user_version"), 2)
        XCTAssertEqual(scalarInt(
            database,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_decode_result','whoop_ppg_packet','whoop_store_metadata')"
        ), 3)
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

    private func scalarInt(_ database: OpaquePointer?, sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }
}
