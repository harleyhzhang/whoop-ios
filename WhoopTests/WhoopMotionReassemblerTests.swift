import Foundation
import XCTest

@testable import Whoop

final class WhoopMotionReassemblerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let peripheral = UUID()
    private func fragment(_ bytes: [UInt8], channel: String = "data", at offset: TimeInterval = 0)
        -> WhoopMotionFragment
    {
        WhoopMotionFragment(
            packet: Data(bytes), peripheralID: peripheral,
            characteristicUUID: channel, deliveredAt: now.addingTimeInterval(offset))
    }
    private func frame() -> [UInt8] {
        var bytes = WhoopTestFrameFactory.frame(length: 1244, type: 43, version: 21)
        bytes[24] = 100
        bytes[630] = 100
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return bytes
    }
    func test244ByteFragmentsProduceOneFullCRCVerifiedFrameAndSourceHashes() {
        let bytes = frame()
        var assembler = WhoopMotionReassembler()
        var frames: [WhoopMotionReassembler.Frame] = []
        for start in stride(from: 0, to: bytes.count, by: 244) {
            let result = assembler.ingest(fragment(Array(bytes[start..<min(start + 244, bytes.count)])))
            frames += result.frames
            if start == 0 { XCTAssertTrue(result.liveIMUHeader) }
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.packet, Data(bytes))
        XCTAssertEqual(frames.first?.sourceHashes.count, 6)
    }
    func testChannelsNeverJoinAndResetOrLongGapDropsPartialFrames() {
        let bytes = frame()
        for reset in [false, true] {
            var assembler = WhoopMotionReassembler()
            XCTAssertTrue(assembler.ingest(fragment(Array(bytes.prefix(244)))).frames.isEmpty)
            XCTAssertTrue(assembler.ingest(fragment(Array(bytes.dropFirst(244)), channel: "other")).frames.isEmpty)
            if reset { assembler.reset() }
            XCTAssertTrue(assembler.ingest(fragment(Array(bytes.dropFirst(244)), at: 3)).frames.isEmpty)
        }
    }
    func testJunkBadCRCPartialHeaderAndConcatenatedFramesResynchronizeWithinBound() {
        let bytes = frame()
        var corrupt = bytes
        corrupt[100] ^= 1
        var assembler = WhoopMotionReassembler()
        XCTAssertTrue(assembler.ingest(fragment([3, 4, 0xAA])).frames.isEmpty)
        let result = assembler.ingest(fragment(Array(bytes.dropFirst()) + corrupt + bytes))
        XCTAssertEqual(result.frames.map(\.packet), [Data(bytes), Data(bytes)])
        for _ in 0..<20 { _ = assembler.ingest(fragment(Array(repeating: 0xFF, count: 4096))) }
        // Shared parser memory limits are asserted in WhoopFrameReassemblerTests.
    }
}
