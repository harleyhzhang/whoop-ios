import Foundation

struct WhoopMotionFragment: Sendable {
    let packet: Data
    let peripheralID: UUID
    let characteristicUUID: String
    let deliveredAt: Date
}

/// Legacy OFF-only cleanup uses the same framing policy as ordinary ingestion.
/// It consumes committed notifications and never writes or starts a producer.
struct WhoopMotionReassembler {
    struct Frame {
        let packet: Data
        let sourceHashes: [String]
    }
    struct Result {
        var frames: [Frame] = []
        var liveIMUHeader = false
    }
    private var shared = WhoopFrameReassembler(maximumStreams: 4)
    var bufferedByteCount: Int { shared.bufferedByteCount }
    mutating func reset() { shared.reset() }
    mutating func ingest(_ fragment: WhoopMotionFragment) -> Result {
        let result = shared.ingest(
            WhoopFrameFragment(
                packetID: UUID().uuidString,
                packet: fragment.packet, peripheralID: fragment.peripheralID,
                characteristicUUID: fragment.characteristicUUID, generation: 0, deliveredAt: fragment.deliveredAt))
        return Result(
            frames: result.frames.map { frame in
                Frame(packet: frame.packet, sourceHashes: frame.sources.map(\.sha256))
            }, liveIMUHeader: result.liveIMUHeader)
    }
}
