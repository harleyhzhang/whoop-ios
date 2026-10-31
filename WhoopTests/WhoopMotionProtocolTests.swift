import Foundation
import XCTest

@testable import Whoop

final class WhoopMotionProtocolTests: XCTestCase {
    private func envelope(_ bytes: [UInt8]) -> WhoopPacketEnvelope {
        .proprietary(
            packet: Data(bytes), peripheralID: UUID(), characteristicUUID: "synthetic",
            offloadSessionID: nil, deliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
            proprietaryOrdinal: 1)
    }

    private func frame(type: UInt8 = 43, accel: UInt8 = 100, gyro: UInt8 = 100) -> [UInt8] {
        var bytes = WhoopTestFrameFactory.frame(length: 1244, type: type, version: 21)
        let seconds: UInt32 = 1_800_000_000
        for offset in 0..<4 { bytes[15 + offset] = UInt8(truncatingIfNeeded: seconds >> (8 * offset)) }
        bytes[24] = accel
        bytes[630] = gyro
        bytes[21] = 4
        bytes[22] = 100
        bytes[26] = 3
        bytes[628] = 100
        bytes[632] = 5
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return bytes
    }

    func testR21PreservesIndependentCountsTimestampConfigurationAndRawHash() throws {
        for type: UInt8 in [43, 47] {
            let packet = frame(type: type, accel: 37, gyro: 92)
            guard case .buffer(let buffer) = WhoopMotionProtocol.event(envelope(packet)) else {
                return XCTFail("Expected R21")
            }
            XCTAssertEqual(buffer.accelerometerCount, 37)
            XCTAssertEqual(buffer.gyroscopeCount, 92)
            XCTAssertEqual(buffer.sensorAt, Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(buffer.configuration, [4, 100, 3, 0, 100, 5, 0])
            XCTAssertEqual(buffer.sha256.count, 64)
        }
    }

    func testCorruptUnknownTruncatedAndOversizedCountsAreRejected() {
        var corrupt = frame()
        corrupt[100] ^= 1
        var wrongLayout = frame()
        wrongLayout[9] = 18
        WhoopTestFrameFactory.finishChecksums(&wrongLayout)
        var badFraction = frame()
        badFraction[19] = 255
        badFraction[20] = 255
        WhoopTestFrameFactory.finishChecksums(&badFraction)
        for packet in [
            corrupt, wrongLayout, badFraction, frame(accel: 101), frame(gyro: 101),
            frame(type: 51), Array(frame().prefix(100)),
        ] {
            XCTAssertNil(WhoopMotionProtocol.event(envelope(packet)))
        }
    }

    func testReplyUsesOriginSequenceAndResultNotResponseSequence() {
        var packet = WhoopTestFrameFactory.frame(length: 20, type: 36, version: 99)
        packet[10] = 106
        packet[11] = 7
        packet[12] = 3
        WhoopTestFrameFactory.finishChecksums(&packet)
        guard case .reply(let reply) = WhoopMotionProtocol.event(envelope(packet)) else {
            return XCTFail("Expected command reply")
        }
        XCTAssertEqual(reply.command, 106)
        XCTAssertEqual(reply.origin, 7)
        XCTAssertEqual(reply.result, 3)
    }

    func testSummaryOnlyReportsIntegrityCheckedMotionWithPeripheralProvenance() {
        let packet = envelope(frame())
        let summary = WhoopTransportBatchSummary(envelopes: [packet])
        XCTAssertEqual(summary.motionEvents.count, 1)
        XCTAssertEqual(summary.motionEvents.first?.0, packet.peripheralID)
    }
    func testReadOnlyClockReplyRetainsValidatedDeviceTime() {
        var packet = WhoopTestFrameFactory.frame(length: 24, type: 36, version: 5)
        packet[10] = 147
        packet[11] = 3
        packet[12] = 1
        packet[13] = 1
        let seconds: UInt32 = 1_800_000_000
        for offset in 0..<4 { packet[14 + offset] = UInt8(truncatingIfNeeded: seconds >> (8 * offset)) }
        WhoopTestFrameFactory.finishChecksums(&packet)
        guard case .reply(let reply) = WhoopMotionProtocol.event(envelope(packet)) else {
            return XCTFail("Clock reply")
        }
        XCTAssertEqual(reply.deviceClock, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(WhoopCommand.readMotionClock.opcode, 147)
        XCTAssertEqual(WhoopCommand.readMotionClock.payload, [1])
    }

}
