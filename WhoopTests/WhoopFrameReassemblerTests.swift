import XCTest

@testable import Whoop

final class WhoopFrameReassemblerTests: XCTestCase {
    private let peripheral = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fragment(
        _ data: Data, id: String = "one", generation: UInt64 = 1, characteristic: String = "notify",
        time: TimeInterval = 0
    ) -> WhoopFrameFragment {
        WhoopFrameFragment(
            packetID: id, packet: data, peripheralID: peripheral,
            characteristicUUID: characteristic, generation: generation, deliveredAt: now.addingTimeInterval(time))
    }
    private func frame() -> Data {
        var bytes = WhoopTestFrameFactory.frame(length: 124, type: 47, version: 18)
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return Data(bytes)
    }
    func testEverySplitBoundaryReassemblesWithExactSourceSlices() throws {
        let packet = frame()
        for split in 1..<packet.count {
            var parser = WhoopFrameReassembler()
            XCTAssertTrue(parser.ingest(fragment(packet.prefix(split))).frames.isEmpty)
            let frame = try XCTUnwrap(
                parser.ingest(fragment(packet.dropFirst(split), id: "two", time: 0.01)).frames.first)
            XCTAssertEqual(frame.packet, packet)
            XCTAssertEqual(frame.sources.map(\.packetID), ["one", "two"])
            XCTAssertEqual(frame.sources.map(\.offset), [0, 0])
            XCTAssertEqual(frame.sources.map(\.length), [split, packet.count - split])
        }
    }
    func testCoalescedFramesGarbageAndBadPayloadResynchronize() {
        let packet = frame()
        var bad = packet
        bad[30] ^= 1
        var parser = WhoopFrameReassembler()
        let result = parser.ingest(fragment(Data([0, 1, 2]) + bad + packet + packet))
        XCTAssertEqual(result.frames.map(\.packet), [packet, packet])
        XCTAssertEqual(result.frames.compactMap { $0.sources.first?.offset }, [127, 251])
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }
    func testCorruptDeclaredLengthCannotHideLaterCompleteFrame() {
        let packet = frame()
        var header = WhoopTestFrameFactory.frame(length: 1244, type: 43, version: 21)
        WhoopTestFrameFactory.finishChecksums(&header)
        header = Array(header.prefix(12))
        var parser = WhoopFrameReassembler()
        XCTAssertEqual(parser.ingest(fragment(Data(header) + packet)).frames.map(\.packet), [packet])
    }
    func testGenerationsCharacteristicsTimeoutAndBoundsNeverMixFragments() {
        let packet = frame()
        var parser = WhoopFrameReassembler(maximumStreams: 2)
        _ = parser.ingest(fragment(packet.prefix(62)))
        XCTAssertTrue(parser.ingest(fragment(packet.suffix(62), generation: 2)).frames.isEmpty)
        XCTAssertTrue(parser.ingest(fragment(packet.suffix(62), characteristic: "other")).frames.isEmpty)
        parser.reset()
        _ = parser.ingest(fragment(packet.prefix(62)))
        XCTAssertTrue(parser.ingest(fragment(packet.suffix(62), time: 3)).frames.isEmpty)
        for index in 0..<300 {
            _ = parser.ingest(fragment(Data([0]), id: String(index), time: Double(index) / 1000 + 3))
        }
        XCTAssertLessThanOrEqual(parser.bufferedByteCount, WhoopFrameReassembler.maximumFrameBytes * 2)
        _ = parser.ingest(fragment(Data(repeating: 0, count: 20_000)))
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }
}
