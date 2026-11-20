import XCTest

@testable import Whoop

final class WhoopDeviceClockTests: XCTestCase {
    private let token = WhoopConnectionSession.Token(generation: 1, peripheralID: UUID())
    private let sent = Date(timeIntervalSince1970: 1_800_000_114)
    private func reply(origin: UInt8 = 7, delay: Double = 0.04, result: UInt8 = 1) -> WhoopMotionProtocol.Reply {
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

    func testFactoryEpochAuthorizesInitializationButNeverBecomesAReference() throws {
        var clock = WhoopDeviceClock()
        var factory = reply()
        factory.deviceClock = Date(timeIntervalSince1970: 946_700_000)
        clock.requested(token: token, origin: 7, at: sent, uptime: 100)
        XCTAssertNil(clock.receive(factory, token: token, uptime: 100.04, sourceSHA256: "factory"))
        XCTAssertNil(clock.reference)
        XCTAssertTrue(clock.needsInitialization)
        let command = try XCTUnwrap(clock.initializationCommand(now: sent.addingTimeInterval(0.25), uptime: 100.05))
        XCTAssertEqual(command.opcode, 146)
        XCTAssertEqual(command.payload.count, 7)
        XCTAssertEqual(command.payload.first, 1)
        XCTAssertTrue(WhoopFrameIntegrity.isValid(command.frame(sequence: 8)))
        XCTAssertNil(clock.initializationCommand(now: sent, uptime: 100.06))

        clock.requested(token: token, origin: 7, at: sent, uptime: 101)
        XCTAssertNotNil(clock.receive(reply(), token: token, uptime: 101.04, sourceSHA256: "healthy"))
        XCTAssertFalse(clock.needsInitialization)
        XCTAssertNil(clock.initializationCommand(now: sent, uptime: 200))
    }

    func testOnlyCorrelatedFreshFactoryReadCanAuthorizeInitialization() {
        var factory = reply()
        factory.deviceClock = Date(timeIntervalSince1970: 946_700_000)
        for scenario in 0..<5 {
            var clock = WhoopDeviceClock()
            clock.requested(token: token, origin: scenario == 0 ? 8 : 7, at: sent, uptime: 100)
            let reading = WhoopMotionProtocol.Reply(
                command: 147, origin: 7, result: scenario == 1 ? 0 : 1,
                receivedAt: scenario == 2 ? sent.addingTimeInterval(2) : factory.receivedAt,
                deviceClock: scenario == 3 ? sent.addingTimeInterval(2 * 86400) : factory.deviceClock)
            let connection =
                scenario == 4 ? WhoopConnectionSession.Token(generation: 2, peripheralID: token.peripheralID) : token
            XCTAssertNil(clock.receive(reading, token: connection, uptime: 100.04, sourceSHA256: "rejected"))
            XCTAssertFalse(clock.needsInitialization)
            XCTAssertNil(clock.initializationCommand(now: sent, uptime: 101))
        }
    }

    func testInitializationAttemptsAreBoundedAcrossReconnectsAndExpire() {
        var clock = WhoopDeviceClock()
        for attempt in 0..<5 {
            let elapsed = attempt == 4 ? 3601.0 : Double(attempt) * 60
            let now = sent.addingTimeInterval(elapsed)
            let reading = WhoopMotionProtocol.Reply(
                command: 147, origin: 7, result: 1, receivedAt: now.addingTimeInterval(0.04),
                deviceClock: Date(timeIntervalSince1970: 946_700_000))
            clock.reset(token)
            clock.requested(token: token, origin: 7, at: now, uptime: 100 + elapsed)
            XCTAssertNil(clock.receive(reading, token: token, uptime: 100.04 + elapsed, sourceSHA256: "factory"))
            let command = clock.initializationCommand(now: now, uptime: 100.05 + elapsed)
            XCTAssertEqual(command != nil, attempt != 3)
        }
    }

    func testClockInitializationWirePayloadUsesRevisionSecondsAndSubsecondTicks() {
        let command = WhoopCommand.initializeDeviceClock(seconds: 0x6B12_3456, subseconds: 0x1234)
        XCTAssertEqual(command.opcode, 146)
        XCTAssertEqual(command.payload, [1, 0x56, 0x34, 0x12, 0x6B, 0x34, 0x12])
    }
}
