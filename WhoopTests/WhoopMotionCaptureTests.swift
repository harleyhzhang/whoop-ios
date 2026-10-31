import Foundation
import XCTest

@testable import Whoop

/// Synthetic archive fixture: production no longer exposes a recording initializer.
func legacyMotionState(
    phase: WhoopMotionCaptureState.Phase = .recording, peripheralID: UUID = UUID(),
    now: Date, extra: [String: Any] = [:]
) throws -> WhoopMotionCaptureState {
    var json: [String: Any] = [
        "id": UUID().uuidString, "peripheralID": peripheralID.uuidString,
        "label": "Rest", "notes": "Synthetic original note", "sourceCommit": "synthetic-legacy",
        "startedAt": now.timeIntervalSinceReferenceDate - 30,
        "deadline": now.timeIntervalSinceReferenceDate + 30, "phase": phase.rawValue,
        "reason": "Original evidence", "buffers": [], "commandResults": [],
        "rawBytesReceived": 1234, "rawStopAccepted": false, "imuStopAccepted": false,
        "rawStartUnsupported": false, "imuStartUnsupported": false,
    ]
    json.merge(extra) { _, new in new }
    return try JSONDecoder().decode(WhoopMotionCaptureState.self, from: JSONSerialization.data(withJSONObject: json))
}

final class WhoopMotionCaptureTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAllInterruptedLegacyPhasesCanOnlyIssueBothOFFCommands() throws {
        for phase: WhoopMotionCaptureState.Phase in [
            .readingClock, .startingRaw, .enablingIMU, .awaitingSamples, .recording,
            .stoppingRaw, .disablingIMU, .settling, .needsCleanup,
        ] {
            var state = try legacyMotionState(phase: phase, now: now)
            state.disconnected(now: now)
            state.reconnect(now: now)
            XCTAssertEqual(state.nextCommand, .stopRawMotion)
            XCTAssertEqual(state.nextCommand?.opcode, 82)
            XCTAssertEqual(state.nextCommand?.payload, [1])
            state.sent(.stopRawMotion, sequence: 7, now: now)
            XCTAssertNil(state.nextCommand)
            state.reply(.init(command: 82, origin: 8, result: 1, receivedAt: now), now: now)
            state.reply(.init(command: 82, origin: 7, result: 2, receivedAt: now), now: now)
            XCTAssertEqual(state.phase, .stoppingRaw)
            state.reply(.init(command: 82, origin: 7, result: 1, receivedAt: now), now: now)
            XCTAssertEqual(state.nextCommand, .disableLiveIMU)
            XCTAssertEqual(state.nextCommand?.opcode, 106)
            XCTAssertEqual(state.nextCommand?.payload, [1, 0])
            state.sent(.disableLiveIMU, sequence: 8, now: now)
            state.reply(.init(command: 106, origin: 8, result: 1, receivedAt: now), now: now)
            state.tick(now: now.addingTimeInterval(2.9))
            XCTAssertTrue(state.needsCleanup)
            state.tick(now: now.addingTimeInterval(3))
            XCTAssertFalse(state.needsCleanup)
            XCTAssertEqual(state.notes, "Synthetic original note")
            XCTAssertEqual(state.rawBytesReceived, 1234)
        }
    }

    func testRejectedOrTimedOutStopsRetainCleanupAndNeverRestart() throws {
        for result: UInt8? in [3, nil] {
            var state = try legacyMotionState(now: now)
            state.reconnect(now: now)
            state.sent(.stopRawMotion, sequence: 1, now: now)
            if let result {
                state.reply(.init(command: 82, origin: 1, result: result, receivedAt: now), now: now)
            } else {
                state.tick(now: now.addingTimeInterval(4))
            }
            XCTAssertEqual(state.nextCommand, .disableLiveIMU)
            state.sent(.disableLiveIMU, sequence: 2, now: now.addingTimeInterval(4))
            state.tick(now: now.addingTimeInterval(8))
            state.tick(now: now.addingTimeInterval(18))
            XCTAssertEqual(state.phase, .needsCleanup)
            XCTAssertNil(state.nextCommand)
            state.reconnect(now: now.addingTimeInterval(20))
            XCTAssertEqual(state.nextCommand, .stopRawMotion)
        }
    }

    func testObservedProducerPreventsUnsupportedShortcutAndQuietResetsOnLateTraffic() throws {
        var state = try legacyMotionState(
            phase: .settling, now: now,
            extra: [
                "rawStartUnsupported": true, "settlingAt": now.timeIntervalSinceReferenceDate,
            ])
        state.observeProducerTraffic(now: now)
        state.tick(now: now.addingTimeInterval(10))
        XCTAssertEqual(state.phase, .needsCleanup)
        var stopped = try legacyMotionState(
            phase: .settling, now: now,
            extra: [
                "rawStopAccepted": true, "imuStopAccepted": true,
                "settlingAt": now.timeIntervalSinceReferenceDate,
            ])
        stopped.observeProducerTraffic(now: now.addingTimeInterval(2))
        stopped.tick(now: now.addingTimeInterval(3))
        XCTAssertEqual(stopped.phase, .settling)
        stopped.tick(now: now.addingTimeInterval(5))
        XCTAssertEqual(stopped.phase, .complete)
        stopped.observeProducerTraffic(now: now.addingTimeInterval(6))
        XCTAssertEqual(stopped.nextCommand, .stopRawMotion)
    }
}
