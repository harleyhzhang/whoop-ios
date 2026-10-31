import CryptoKit
import Foundation

/// A byte-exact slice of an original delivered notification. IDs are allocated
/// before persistence and used as raw packet IDs, so a completed frame cannot
/// be committed unless every source notification exists in the same database.
struct WhoopFrameSource: Sendable {
    let packetID: String
    let sha256: String
    let offset: Int
    let length: Int
}

struct WhoopFrameFragment: Sendable {
    let packetID: String
    let packet: Data
    let peripheralID: UUID
    let characteristicUUID: String
    let generation: UInt64
    let deliveredAt: Date
}

/// WHOOP5 framing, before semantic routing. Raw delivery retention is owned by
/// the caller even when these bounded buffers reject corrupt/unknown framing.
struct WhoopFrameReassembler {
    struct Frame {
        let packet: Data
        let sources: [WhoopFrameSource]
    }
    struct Result {
        var frames: [Frame] = []
        var liveIMUHeader = false
    }
    private struct Key: Hashable {
        let peripheralID: UUID
        let characteristicUUID: String
        let generation: UInt64
    }
    private struct Segment {
        let start: Int
        let end: Int
        let packetID: String
        let sha256: String
        let sourceOffset: Int
    }
    private struct Stream {
        var bytes: [UInt8] = []
        var segments: [Segment] = []
        var lastAt: Date
    }
    static let maximumFrameBytes = 4096
    static let maximumNotificationBytes = 16_384
    private let maximumStreams: Int
    private var streams: [Key: Stream] = [:]
    private(set) var bufferedByteCount = 0

    init(maximumStreams: Int = 8) { self.maximumStreams = max(1, maximumStreams) }

    mutating func reset() {
        streams.removeAll()
        bufferedByteCount = 0
    }

    mutating func ingest(_ fragment: WhoopFrameFragment) -> Result {
        var result = Result()
        guard fragment.packet.count <= Self.maximumNotificationBytes else {
            reset()
            return result
        }
        let key = Key(
            peripheralID: fragment.peripheralID,
            characteristicUUID: fragment.characteristicUUID, generation: fragment.generation)
        if streams[key] == nil, streams.count >= maximumStreams { reset() }
        var stream = streams[key] ?? Stream(lastAt: fragment.deliveredAt)
        if fragment.deliveredAt.timeIntervalSince(stream.lastAt) > 2
            || fragment.deliveredAt < stream.lastAt || stream.segments.count >= 256
        {
            stream = Stream(lastAt: fragment.deliveredAt)
        }
        stream.lastAt = fragment.deliveredAt
        let start = stream.bytes.count
        stream.bytes.append(contentsOf: fragment.packet)
        stream.segments.append(
            Segment(
                start: start, end: stream.bytes.count,
                packetID: fragment.packetID,
                sha256: SHA256.hash(data: fragment.packet).map { String(format: "%02x", $0) }.joined(), sourceOffset: 0)
        )
        var cursor = 0
        while stream.bytes.count - cursor >= 8 {
            guard let total = Self.frameLength(stream.bytes, at: cursor) else {
                cursor += 1
                continue
            }
            if stream.bytes.count - cursor >= 10,
                stream.bytes[cursor + 8] == 43, stream.bytes[cursor + 9] == 21, total == 1244
            {
                result.liveIMUHeader = true
            }
            if stream.bytes.count - cursor < total {
                // A CRC-valid header with a corrupted declared length must not
                // hide a later complete CRC-valid frame indefinitely.
                if let next = Self.nextCompleteFrame(stream.bytes, after: cursor) {
                    cursor = next
                    continue
                }
                break
            }
            let packet = Array(stream.bytes[cursor..<cursor + total])
            guard WhoopFrameIntegrity.isValid(packet) else {
                cursor += 1
                continue
            }
            let range = cursor..<cursor + total
            let sources = stream.segments.compactMap { segment -> WhoopFrameSource? in
                let lower = max(range.lowerBound, segment.start)
                let upper = min(range.upperBound, segment.end)
                guard upper > lower else { return nil }
                return WhoopFrameSource(
                    packetID: segment.packetID, sha256: segment.sha256,
                    offset: segment.sourceOffset + lower - segment.start, length: upper - lower)
            }
            result.frames.append(Frame(packet: Data(packet), sources: sources))
            cursor += total
        }
        // Compact once per notification, preserving exact offsets into each
        // original source even when one notification holds several frames.
        if cursor > 0 {
            stream.bytes.removeFirst(cursor)
            stream.segments = stream.segments.compactMap { segment in
                guard segment.end > cursor else { return nil }
                let consumed = max(0, cursor - segment.start)
                return Segment(
                    start: max(0, segment.start - cursor), end: segment.end - cursor,
                    packetID: segment.packetID, sha256: segment.sha256,
                    sourceOffset: segment.sourceOffset + consumed)
            }
        }
        if stream.bytes.count > Self.maximumFrameBytes { stream = Stream(lastAt: fragment.deliveredAt) }
        streams[key] = stream
        bufferedByteCount = streams.values.reduce(0) { $0 + $1.bytes.count }
        return result
    }

    private static func frameLength(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard bytes.count - offset >= 8, bytes[offset] == 0xAA, bytes[offset + 1] == 1,
            WhoopFrameIntegrity.crc16Modbus(bytes[offset..<offset + 6])
                == UInt16(bytes[offset + 6]) | UInt16(bytes[offset + 7]) << 8
        else { return nil }
        let declared = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
        let total = declared + 8
        guard (16...maximumFrameBytes).contains(total), (declared - 4).isMultiple(of: 4) else { return nil }
        return total
    }

    private static func nextCompleteFrame(_ bytes: [UInt8], after offset: Int) -> Int? {
        guard bytes.count - offset > 8 else { return nil }
        for candidate in offset + 1...bytes.count - 8 where bytes[candidate] == 0xAA {
            guard let length = frameLength(bytes, at: candidate), bytes.count - candidate >= length else { continue }
            if WhoopFrameIntegrity.isValid(Array(bytes[candidate..<candidate + length])) { return candidate }
        }
        return nil
    }
}
