import Foundation
import XCTest

@testable import Whoop

final class WhoopMotionCaptureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let peripheralID = UUID()

    private func state(duration: TimeInterval = 60) throws -> WhoopMotionCaptureState {
        var state = try XCTUnwrap(
            WhoopMotionCaptureState(
                peripheralID: peripheralID, label: .lifting, notes: "Synthetic exercise", duration: duration,
                sourceCommit: "synthetic", now: now
            ))
        state.sent(.readMotionClock, sequence: 1, now: now)
        state.reply(.init(command: 147, origin: 1, result: 1, receivedAt: now, deviceClock: now), now: now)
        return state
    }

    private func accept(
        _ state: inout WhoopMotionCaptureState, sequence: UInt8 = 10,
        at date: Date, result: UInt8 = 1
    ) throws {
        let command = try XCTUnwrap(state.nextCommand)
        state.sent(command, sequence: sequence, now: date)
        state.reply(.init(command: command.opcode, origin: sequence, result: result, receivedAt: date), now: date)
    }

    private func buffer(at date: Date, accel: Int = 100, gyro: Int = 100) -> WhoopMotionProtocol.Buffer {
        .init(
            sha256: "synthetic", sensorAt: date, receivedAt: date, accelerometerCount: accel,
            gyroscopeCount: gyro, configuration: [4, 100, 3, 0, 100, 5, 0])
    }

    func testCommandsAreTemporaryAndHaveExactObservedPayloads() {
        XCTAssertEqual(WhoopCommand.rawMotion(start: true).opcode, 81)
        XCTAssertEqual(WhoopCommand.rawMotion(start: false).opcode, 82)
        XCTAssertEqual(WhoopCommand.rawMotion(start: true).payload, [1])
        XCTAssertEqual(WhoopCommand.liveIMU(enabled: true).opcode, 106)
        XCTAssertEqual(WhoopCommand.liveIMU(enabled: true).payload, [1, 1])
        XCTAssertEqual(WhoopCommand.liveIMU(enabled: false).payload, [1, 0])
    }

    func testCaptureRequiresActualBothSensorDataAndDeduplicatesSensorTime() throws {
        var state = try state()
        try accept(&state, at: now)
        try accept(&state, at: now)
        XCTAssertEqual(state.phase, .awaitingSamples)
        state.observe(buffer(at: now, gyro: 0), now: now)
        XCTAssertEqual(state.phase, .awaitingSamples)
        state.observe(buffer(at: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        state.observe(buffer(at: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(state.buffers.count, 2)
    }

    func testFailedStartStillAttemptsBothStopCommands() throws {
        var state = try state()
        try accept(&state, at: now, result: 0)
        XCTAssertEqual(state.nextCommand, .rawMotion(start: false))
        try accept(&state, at: now, result: 0)
        XCTAssertEqual(state.nextCommand, .liveIMU(enabled: false))
        try accept(&state, at: now)
        state.tick(now: now.addingTimeInterval(11))
        XCTAssertEqual(state.phase, .needsCleanup)
        XCTAssertTrue(state.needsCleanup)
    }

    func testExplicitUnsupportedStartRestoresHistoryAfterBothStopAttemptsAndQuiet() throws {
        var state = try state()
        try accept(&state, at: now, result: 3)
        XCTAssertEqual(state.nextCommand, .rawMotion(start: false))
        try accept(&state, at: now, result: 3)
        XCTAssertEqual(state.nextCommand, .liveIMU(enabled: false))
        try accept(&state, at: now, result: 3)
        state.tick(now: now.addingTimeInterval(3))
        XCTAssertEqual(state.phase, .complete)
        XCTAssertFalse(state.hasBothSensors)
        XCTAssertTrue(state.buffers.isEmpty)
    }

    func testActualMotionContradictsUnsupportedShortcutAndStillRequiresBothStops() throws {
        var state = try state()
        try accept(&state, at: now, result: 3)
        state.observe(buffer(at: now), now: now)
        try accept(&state, at: now, result: 3)
        try accept(&state, at: now, result: 3)
        state.tick(now: now.addingTimeInterval(11))
        XCTAssertEqual(state.phase, .needsCleanup)
    }

    func testUnsupportedIMUStartRequiresSuccessfulRawStop() throws {
        for rawStopResult: UInt8 in [1, 3] {
            var state = try state()
            try accept(&state, at: now)
            try accept(&state, at: now, result: 3)
            try accept(&state, at: now, result: rawStopResult)
            try accept(&state, at: now, result: 3)
            state.tick(now: now.addingTimeInterval(11))
            XCTAssertEqual(state.phase, rawStopResult == 1 ? .complete : .needsCleanup)
        }
    }

    func testDeadlineStopsAndCleanCompletionNeedsBothRepliesAndQuietInterval() throws {
        var state = try state()
        try accept(&state, at: now)
        try accept(&state, at: now)
        state.observe(buffer(at: now), now: now)
        state.tick(now: now.addingTimeInterval(60))
        XCTAssertEqual(state.nextCommand, .rawMotion(start: false))
        try accept(&state, at: now.addingTimeInterval(60))
        try accept(&state, at: now.addingTimeInterval(60))
        state.tick(now: now.addingTimeInterval(62))
        XCTAssertEqual(state.phase, .settling)
        state.tick(now: now.addingTimeInterval(63))
        XCTAssertEqual(state.phase, .complete)
        XCTAssertFalse(state.needsCleanup)
    }

    func testContinuedMotionPreventsFalseStopVerification() throws {
        var state = try state()
        state.stop(reason: "User", now: now)
        try accept(&state, at: now)
        try accept(&state, at: now)
        for second in 1...10 {
            let date = now.addingTimeInterval(Double(second))
            state.observe(buffer(at: date), now: date)
            state.tick(now: date)
        }
        XCTAssertEqual(state.phase, .needsCleanup)
        XCTAssertTrue(state.buffers.isEmpty)
    }

    func testEmptyR21BuffersStillPreventFalseQuietStopWithoutAddingCoverage() throws {
        var state = try state()
        state.stop(reason: "User", now: now)
        try accept(&state, at: now)
        try accept(&state, at: now)
        for second in 1...10 {
            let date = now.addingTimeInterval(Double(second))
            state.observe(buffer(at: date, accel: 0, gyro: 0), now: date)
            state.tick(now: date)
        }
        XCTAssertEqual(state.phase, .needsCleanup)
        XCTAssertTrue(state.buffers.isEmpty)
        XCTAssertFalse(state.hasBothSensors)
    }

    func testNoSensorsOrStalledSensorsStopPromptly() throws {
        var missing = try state()
        try accept(&missing, at: now)
        try accept(&missing, at: now)
        missing.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(missing.phase, .stoppingRaw)
        var stalled = try state()
        try accept(&stalled, at: now)
        try accept(&stalled, at: now)
        stalled.observe(buffer(at: now), now: now)
        stalled.tick(now: now.addingTimeInterval(6))
        XCTAssertEqual(stalled.phase, .stoppingRaw)
    }

    func testReplyCorrelationPendingAndTimeout() throws {
        var state = try state()
        state.sent(.rawMotion(start: true), sequence: 7, now: now)
        for reply in [
            WhoopMotionProtocol.Reply(command: 81, origin: 6, result: 1, receivedAt: now),
            .init(command: 82, origin: 7, result: 1, receivedAt: now),
            .init(command: 81, origin: 7, result: 1, receivedAt: now.addingTimeInterval(-1)),
            .init(command: 81, origin: 7, result: 2, receivedAt: now),
        ] { state.reply(reply, now: now) }
        XCTAssertEqual(state.phase, .startingRaw)
        XCTAssertNotNil(state.pending)
        state.tick(now: now.addingTimeInterval(4))
        XCTAssertEqual(state.phase, .stoppingRaw)
    }

    func testReconnectNeverRestartsAnInterruptedCapture() throws {
        var state = try state()
        try accept(&state, at: now)
        state.disconnected(now: now)
        XCTAssertNil(state.nextCommand)
        state.reconnect(now: now.addingTimeInterval(1))
        XCTAssertEqual(state.nextCommand, .rawMotion(start: false))
        XCTAssertFalse(state.isCollecting)
    }

    func testRawByteBudgetAndSingleSensorDropoutStopCapture() throws {
        var budget = try state()
        budget.observeRawBytes(10 * 1024 * 1024, now: now)
        XCTAssertEqual(budget.phase, .stoppingRaw)
        var dropout = try state()
        try accept(&dropout, at: now)
        try accept(&dropout, at: now)
        dropout.observe(buffer(at: now), now: now)
        let later = now.addingTimeInterval(6)
        dropout.observe(buffer(at: later, gyro: 0), now: later)
        dropout.tick(now: later)
        XCTAssertEqual(dropout.phase, .stoppingRaw)
    }

    func testOutOfIntervalAndUncorrelatedClockSkewedBuffersDoNotCount() throws {
        var state = try state()
        state.observe(buffer(at: now.addingTimeInterval(-10)), now: now)
        let skewed = WhoopMotionProtocol.Buffer(
            sha256: "synthetic", sensorAt: now.addingTimeInterval(-114), receivedAt: now,
            accelerometerCount: 100, gyroscopeCount: 100, configuration: []
        )
        state.observe(skewed, now: now)
        XCTAssertTrue(state.buffers.isEmpty)
    }

    func testDurationAndNotesAreBounded() throws {
        for duration in [Double.nan, .infinity, -1, 0, 29, 601] {
            XCTAssertNil(
                WhoopMotionCaptureState(
                    peripheralID: peripheralID, label: .rest, notes: "",
                    duration: duration, sourceCommit: "test", now: now))
        }
        XCTAssertEqual(try state(duration: 600).deadline, now.addingTimeInterval(600))
    }

    func testJournalSurvivesInterruptionAndRemovesObligationOnlyAfterVerifiedCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WhoopMotionCaptureJournal(directory: directory)
        var state = try state()
        try journal.save(state)
        XCTAssertEqual(try journal.load()?.id, state.id)
        state.stop(reason: "Background", now: now)
        try accept(&state, at: now)
        try accept(&state, at: now)
        state.tick(now: now.addingTimeInterval(3))
        try journal.save(state)
        XCTAssertNil(try journal.load())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("motion-calibration.json").path))
    }
    func testCorrelatedDelayedHistoryRepairsOnlyTheActualLabelIntervalWithoutResumingCapture() throws {
        var state = try XCTUnwrap(
            WhoopMotionCaptureState(
                peripheralID: peripheralID, label: .rest, notes: "",
                duration: 60, sourceCommit: "synthetic", now: now))
        state.sent(.readMotionClock, sequence: 1, now: now)
        state.reply(
            .init(
                command: 147, origin: 1, result: 1, receivedAt: now,
                deviceClock: now.addingTimeInterval(-120)), now: now)
        try accept(&state, at: now)
        try accept(&state, at: now)
        state.stop(reason: "Stopped", now: now.addingTimeInterval(5))
        try accept(&state, at: now.addingTimeInterval(5))
        try accept(&state, at: now.addingTimeInterval(5))
        state.tick(now: now.addingTimeInterval(8))
        XCTAssertEqual(state.phase, .complete)
        let raw = now.addingTimeInterval(-118)
        let repaired = WhoopMotionProtocol.Buffer(
            sha256: "synthetic", sensorAt: raw,
            receivedAt: now.addingTimeInterval(20), accelerometerCount: 100, gyroscopeCount: 100,
            configuration: [], realtime: false)
        state.observe(repaired, now: now.addingTimeInterval(20))
        XCTAssertEqual(state.buffers.count, 1)
        XCTAssertEqual(state.buffers.first?.sensorAt, raw)
        XCTAssertEqual(state.phase, .complete)
        XCTAssertNil(state.nextCommand)
        var outside = repaired
        outside = .init(
            sha256: "outside", sensorAt: now.addingTimeInterval(-110),
            receivedAt: now.addingTimeInterval(20), accelerometerCount: 100, gyroscopeCount: 100,
            configuration: [], realtime: false)
        state.observe(outside, now: now.addingTimeInterval(20))
        XCTAssertEqual(state.buffers.count, 1)
        state.observeProducerTraffic(now: now.addingTimeInterval(21))
        XCTAssertEqual(state.phase, .stoppingRaw)
        XCTAssertEqual(state.nextCommand, .rawMotion(start: false))
    }

    func testClockRefusalAndTimeoutNeverStartSensors() throws {
        for timeout in [false, true] {
            var state = try XCTUnwrap(
                WhoopMotionCaptureState(
                    peripheralID: peripheralID, label: .rest, notes: "",
                    duration: 60, sourceCommit: "synthetic", now: now))
            state.sent(.readMotionClock, sequence: 1, now: now)
            if timeout {
                state.tick(now: now.addingTimeInterval(4))
            } else {
                state.reply(.init(command: 147, origin: 1, result: 3, receivedAt: now), now: now)
            }
            XCTAssertEqual(state.phase, .complete)
            XCTAssertNil(state.clockReference)
            XCTAssertNil(state.nextCommand)
        }
    }

    func testFailedClockStillStopsAnObservedProducerAndSlowReferenceIsRejected() throws {
        for observed in [false, true] {
            var state = try XCTUnwrap(
                WhoopMotionCaptureState(
                    peripheralID: peripheralID, label: .rest, notes: "",
                    duration: 60, sourceCommit: "synthetic", now: now))
            state.sent(.readMotionClock, sequence: 1, now: now)
            if observed { state.observeProducerTraffic(now: now) }
            state.reply(
                .init(
                    command: 147, origin: 1, result: 1,
                    receivedAt: now.addingTimeInterval(3), deviceClock: now), now: now.addingTimeInterval(3))
            XCTAssertNil(state.clockReference)
            XCTAssertEqual(state.phase, observed ? .stoppingRaw : .complete)
        }
    }

}
