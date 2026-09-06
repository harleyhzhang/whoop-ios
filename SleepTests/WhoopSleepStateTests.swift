import XCTest
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
        let payload = Data([0xAA, 0x01, 0x02])
        let first = WhoopStore.packetSignature(characteristicUUID: "FD4B0003", payload: payload)
        let repeated = WhoopStore.packetSignature(characteristicUUID: "fd4b0003", payload: payload)
        let differentCharacteristic = WhoopStore.packetSignature(characteristicUUID: "FD4B0004", payload: payload)
        let differentPayload = WhoopStore.packetSignature(
            characteristicUUID: "FD4B0003",
            payload: Data([0xAA, 0x01, 0x03])
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, differentCharacteristic)
        XCTAssertNotEqual(first, differentPayload)
    }

    private func row(at timestamp: TimeInterval, state: Int) -> WhoopStore.HistoricalRow {
        WhoopStore.HistoricalRow(
            timestamp: timestamp,
            heartRate: 55,
            rrIntervals: [1_000],
            sleepState: state
        )
    }
}
