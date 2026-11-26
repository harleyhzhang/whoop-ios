import Foundation
import XCTest

@testable import Whoop

final class WhoopStillnessTransportTests: XCTestCase {
    private let start: UInt32 = 1_800_000_000

    private func envelope(_ timestamp: UInt32, state: UInt8 = 0, motion: Float = 0.008) -> WhoopPacketEnvelope {
        var bytes = WhoopTestFrameFactory.frame(length: 124, type: 47, version: 18)
        for index in 0..<4 {
            bytes[15 + index] = UInt8(truncatingIfNeeded: timestamp >> (8 * index))
            bytes[41 + index] = UInt8(truncatingIfNeeded: motion.bitPattern >> (8 * index))
        }
        bytes[81] = state << 4
        bytes[22] = 55
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return .proprietary(
            packet: Data(bytes), peripheralID: UUID(), characteristicUUID: "synthetic",
            offloadSessionID: nil, deliveredAt: Date(timeIntervalSince1970: Double(timestamp)),
            proprietaryOrdinal: 1)
    }

    func testMotionDecoderReadsFloatAndRejectsUntrustedOrCorruptFrames() throws {
        let raw = envelope(start, state: 2, motion: 0.25)
        let decoded = try XCTUnwrap(WhoopStillnessSample.decode(raw))
        XCTAssertEqual(decoded.acceleration, 0.25)
        XCTAssertEqual(decoded.sleepState, 2)
        XCTAssertEqual(decoded.timestamp, Double(start))
        XCTAssertNil(WhoopStillnessSample.decode(raw.withoutSemanticEvents()))
        var bytes = [UInt8](raw.packet)
        bytes[41] ^= 1
        let corrupt = WhoopPacketEnvelope.proprietary(
            packet: Data(bytes), peripheralID: UUID(), characteristicUUID: "synthetic",
            offloadSessionID: nil, deliveredAt: .now, proprietaryOrdinal: 1)
        XCTAssertNil(WhoopStillnessSample.decode(corrupt))
    }

    @MainActor
    func testControllerWaitsForCompletionAndLiveGuardsBeforeOneWrite() throws {
        let suite = "WhoopStillnessTransportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: Double(start))
        var commands: [WhoopCommand] = []
        let controller = WhoopStillnessNudges(
            send: {
                commands.append($0)
                return 9
            }, defaults: defaults, clock: { now }, localHour: { _ in 12 })
        for offset in stride(from: 0, through: 3600, by: 120) {
            let packets = (offset..<min(offset + 120, 3601)).map { envelope(start + UInt32($0)) }
            controller.persisted(WhoopTransportBatchSummary(envelopes: packets))
        }
        XCTAssertTrue(commands.isEmpty)
        now = now.addingTimeInterval(3600)
        controller.historyCompleted(connected: true, worn: false, sleeping: false)
        controller.historyCompleted(connected: true, worn: true, sleeping: true)
        controller.historyCompleted(connected: false, worn: true, sleeping: false)
        XCTAssertTrue(commands.isEmpty)
        controller.historyCompleted(connected: true, worn: true, sleeping: false)
        XCTAssertEqual(commands, [.stillnessNudge])
        controller.historyCompleted(connected: true, worn: true, sleeping: false)
        XCTAssertEqual(commands.count, 1)
        controller.resetConnection()
        controller.historyCompleted(connected: true, worn: true, sleeping: false)
        XCTAssertEqual(commands.count, 1)
    }
}
