import XCTest

@testable import Whoop

final class WhoopDeviceClockTests: XCTestCase {
    private let token = WhoopConnectionSession.Token(generation: 1, peripheralID: UUID())
    private let sent = Date(timeIntervalSince1970: 1_800_000_114)
    private func reply(origin: UInt8 = 7, delay: Double = 0.04, result: UInt8 = 0) -> WhoopMotionProtocol.Reply {
        WhoopMotionProtocol.Reply(
            command: 147, origin: origin, result: result,
            receivedAt: sent.addingTimeInterval(delay), deviceClock: sent.addingTimeInterval(-114 + delay / 2))
    }
    private func wrist(seconds: UInt32, event: UInt8 = 9) -> Data {
        var bytes = WhoopTestFrameFactory.frame(length: 20, type: 48, version: 1)
        bytes[10] = event
        for index in 0..<4 { bytes[12 + index] = UInt8(truncatingIfNeeded: seconds >> (index * 8)) }
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return Data(bytes)
    }
    func testReferenceAcceptsFreshLaggedWristButRejectsDelayedAndOutOfOrderEvents() throws {
        var clock = WhoopDeviceClock()
        clock.requested(token: token, origin: 7, at: sent, uptime: 100)
        let reference = try XCTUnwrap(clock.receive(reply(), token: token, uptime: 100.04, sourceSHA256: "synthetic"))
        XCTAssertEqual(reference.offsetSeconds, 114, accuracy: 0.001)
        XCTAssertEqual(reference.roundTripSeconds, 0.04, accuracy: 0.001)
        let fresh = wrist(seconds: 1_800_000_001)
        XCTAssertNil(WhoopBluetoothPolicy.freshWristState(fresh, receivedAt: sent.addingTimeInterval(1)))
        XCTAssertEqual(
            clock.wristState(packet: fresh, token: token, receivedAt: sent.addingTimeInterval(1), uptime: 101), true)
        XCTAssertNil(
            clock.wristState(
                packet: wrist(seconds: 1_799_999_900), token: token,
                receivedAt: sent.addingTimeInterval(2), uptime: 102))
        XCTAssertNil(
            clock.wristState(
                packet: wrist(seconds: 1_800_000_000, event: 10), token: token,
                receivedAt: sent.addingTimeInterval(2), uptime: 102))
        XCTAssertNil(
            clock.wristState(
                packet: wrist(seconds: 1_800_000_400), token: token,
                receivedAt: sent.addingTimeInterval(400), uptime: 500))
    }
    func testStaleConnectionRawEvidenceCannotBecomeClockOrWristAuthority() {
        let packet = wrist(seconds: 1_800_000_000)
        let raw = WhoopPacketEnvelope.proprietary(
            packet: packet, peripheralID: token.peripheralID,
            characteristicUUID: "notify", offloadSessionID: nil, deliveredAt: sent, proprietaryOrdinal: 1,
            connectionToken: token
        ).withoutSemanticEvents()
        XCTAssertTrue(raw.integrityIsValid)
        XCTAssertEqual(raw.packet, packet)
        let summary = WhoopTransportBatchSummary(envelopes: [raw])
        XCTAssertNil(summary.connectionToken)
        XCTAssertTrue(summary.clockEnvelopes.isEmpty)
        XCTAssertTrue(summary.motionEvents.isEmpty)
        XCTAssertTrue(summary.motionFragments.isEmpty)
        XCTAssertNil(summary.latestWristState)
    }

    func testWrongOriginReconnectTimeoutAndWallClockJumpRejectReference() {
        var clock = WhoopDeviceClock()
        clock.requested(token: token, origin: 7, at: sent, uptime: 100)
        XCTAssertNil(clock.receive(reply(origin: 6), token: token, uptime: 100.04, sourceSHA256: "old"))
        XCTAssertNil(
            clock.receive(
                reply(), token: .init(generation: 2, peripheralID: token.peripheralID),
                uptime: 100.04, sourceSHA256: "wrong generation"))
        XCTAssertNil(clock.receive(reply(result: 2), token: token, uptime: 100.02, sourceSHA256: "pending"))
        XCTAssertNotNil(clock.receive(reply(), token: token, uptime: 100.04, sourceSHA256: "accepted"))
        XCTAssertNil(clock.receive(reply(), token: token, uptime: 100.05, sourceSHA256: "duplicate"))
        clock.reset(token)
        XCTAssertNil(clock.reference)
        clock.requested(token: token, origin: 7, at: sent, uptime: 100)
        XCTAssertNil(clock.receive(reply(delay: 2), token: token, uptime: 102, sourceSHA256: "late"))
        clock.requested(token: token, origin: 7, at: sent, uptime: 100)
        XCTAssertNil(clock.receive(reply(delay: 0.5), token: token, uptime: 100.04, sourceSHA256: "wall jump"))
        clock.requested(token: token, origin: 8, at: sent, uptime: 100)
        XCTAssertNil(clock.receive(reply(), token: token, uptime: 100.04, sourceSHA256: "superseded"))
    }
}
