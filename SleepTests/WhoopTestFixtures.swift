import SQLite3
import XCTest

@testable import Sleep

final class WhoopSleepStateTests: XCTestCase {}

extension WhoopSleepStateTests {
    func dailyHealthRecord(dateKey: String) -> DailyHealthRecord {
        DailyHealthRecord(
            dateKey: dateKey,
            sleepScore: 88,
            sleepDurationMinutes: 480,
            hrvRMSSDMilliseconds: 64,
            restingHeartRateBPM: 52,
            sleepID: "synthetic-\(dateKey)",
            cycleID: nil,
            source: "synthetic",
            sourceArchive: nil,
            sourceUpdatedAt: "2026-09-09T12:00:00Z"
        )
    }

    func dailyStepRecord(dateKey: String, stepCount: Int) -> DailyStepRecord {
        DailyStepRecord(
            dateKey: dateKey,
            stepCount: stepCount,
            sampleCount: 2,
            spanSeconds: 2,
            coverageFraction: 1,
            gapSeconds: 0,
            counterWrapCount: 0,
            rejectedDeltaCount: 0,
            firstSampleAt: nil,
            lastSampleAt: nil,
            source: "synthetic",
            algorithmVersion: WhoopStepDaySummary.algorithmVersion
        )
    }

    func insertWakeBoundary(
        dateKey: String,
        wokeAt: Date,
        databaseURL: URL
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            XCTFail("Could not open SQLite fixture")
            return
        }
        defer { sqlite3_close(database) }
        let sql = """
            INSERT INTO daily_health_metric
            (date_key, source, source_updated_at, imported_at, sleep_end_at)
            VALUES (?, 'synthetic', '2027-01-15T12:00:00Z', 0, ?)
            """
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else {
            XCTFail("Could not prepare SQLite fixture")
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, dateKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let wake = ISO8601DateFormatter().string(from: wokeAt)
        sqlite3_bind_text(statement, 2, wake, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func row(at timestamp: TimeInterval, state: Int) -> WhoopStore.HistoricalRow {
        WhoopStore.HistoricalRow(
            timestamp: timestamp,
            heartRate: 55,
            sleepState: SleepState(rawValue: state)
        )
    }

    func version26Frame(
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

    func version18Frame(
        timestamp: UInt32,
        sleepState: UInt8,
        rrIntervals: [UInt16] = [],
        stepCounter: UInt16 = 0,
        cadenceRaw: UInt8 = 0,
        motionClassRaw: UInt8 = 0
    ) -> Data {
        precondition(rrIntervals.count <= 4)
        var bytes = WhoopTestFrameFactory.frame(length: 124, type: 47, version: 18)
        bytes[15] = UInt8(truncatingIfNeeded: timestamp)
        bytes[16] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[22] = 55
        bytes[23] = UInt8(rrIntervals.count)
        for (index, interval) in rrIntervals.enumerated() {
            bytes[24 + index * 2] = UInt8(truncatingIfNeeded: interval)
            bytes[25 + index * 2] = UInt8(truncatingIfNeeded: interval >> 8)
        }
        bytes[57] = UInt8(truncatingIfNeeded: stepCounter)
        bytes[58] = UInt8(truncatingIfNeeded: stepCounter >> 8)
        bytes[59] = cadenceRaw
        bytes[63] = motionClassRaw
        bytes[81] = sleepState << 4
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return Data(bytes)
    }

    func metadataFrame(type: UInt8) -> Data {
        WhoopTestFrameFactory.historicalMetadata(type: type, length: 16)
    }

    func wristEventFrame(event: UInt8, timestamp: UInt32) -> Data {
        var bytes = WhoopTestFrameFactory.frame(length: 20, type: 48, version: 1)
        bytes[10] = event
        bytes[12] = UInt8(truncatingIfNeeded: timestamp)
        bytes[13] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[14] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[15] = UInt8(truncatingIfNeeded: timestamp >> 24)
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return Data(bytes)
    }

    func beginOffload(store: WhoopStore, peripheral: UUID) async throws -> String {
        let result: String? = await withCheckedContinuation { continuation in
            store.beginHistoricalOffload(peripheralID: peripheral) {
                continuation.resume(returning: $0)
            }
        }
        return try XCTUnwrap(result)
    }

    func append(
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
                frameType: packet.count > 8 ? FrameType(rawValue: packet[8]) : nil,
                realtime: nil,
                historical: WhoopDecodedHistorical.decode(packet),
                offloadSessionID: sessionID
            ) {
                continuation.resume(returning: $0)
            }
        }
        return result
    }

    func appendRealtime(
        _ packet: Data,
        heartRate: Int,
        rrIntervals: [UInt16],
        deliveredAt: Date,
        store: WhoopStore,
        peripheral: UUID
    ) async -> WhoopPacketPersistenceResult {
        await withCheckedContinuation { continuation in
            store.append(
                packet: packet,
                peripheralID: peripheral,
                characteristicUUID: "FD4B0003",
                frameType: .realtimeHeartRate,
                realtime: WhoopDecodedRealtime(
                    deviceTimestamp: UInt32(deliveredAt.timeIntervalSince1970),
                    heartRate: heartRate,
                    rrIntervals: rrIntervals,
                    source: "whoop5_type40"
                ),
                historical: nil,
                deliveredAt: deliveredAt
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    func sleepSnapshot(
        store: WhoopStore,
        now: Date,
        allowAutomaticFinalization: Bool = false
    ) async -> WhoopSleepSnapshot {
        await withCheckedContinuation { continuation in
            store.refreshSleepSnapshot(
                now: now,
                allowAutomaticFinalization: allowAutomaticFinalization
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    func dashboardSnapshot(store: WhoopStore) async throws -> DashboardHistorySnapshot {
        let result: Result<DashboardHistorySnapshot, Error> = await withCheckedContinuation {
            continuation in
            store.loadDashboardHistory {
                continuation.resume(returning: $0)
            }
        }
        return try result.get()
    }

    func scalarInt(_ database: OpaquePointer?, sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }

    func scalarText(_ database: OpaquePointer?, sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: value)
    }
}
