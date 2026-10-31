import CryptoKit
import Foundation

struct WhoopMotionFragment: Sendable {
    let packet: Data
    let peripheralID: UUID
    let characteristicUUID: String
    let deliveredAt: Date
}

/// Capture-only interpretation of already durable notifications. Original rows
/// remain untouched. Streams cannot cross a characteristic, device or long gap.
struct WhoopMotionReassembler {
    struct Frame {
        let packet: Data
        let sourceHashes: [String]
    }
    struct Result {
        var frames: [Frame] = []
        var liveIMUHeader = false
    }
    private struct Stream {
        var bytes: [UInt8] = []
        var hashes: [String] = []
        var lastAt: Date
    }
    private var streams: [String: Stream] = [:]
    private(set) var bufferedByteCount = 0

    mutating func reset() {
        streams.removeAll()
        bufferedByteCount = 0
    }

    mutating func ingest(_ fragment: WhoopMotionFragment) -> Result {
        var result = Result()
        guard fragment.packet.count <= 4096 else {
            reset()
            return result
        }
        let key = fragment.peripheralID.uuidString + fragment.characteristicUUID
        if streams[key] == nil, streams.count >= 4 { reset() }
        var stream = streams[key] ?? Stream(lastAt: fragment.deliveredAt)
        if fragment.deliveredAt.timeIntervalSince(stream.lastAt) > 2
            || fragment.deliveredAt < stream.lastAt || stream.hashes.count >= 256
        {
            stream = Stream(lastAt: fragment.deliveredAt)
        }
        stream.lastAt = fragment.deliveredAt
        stream.bytes.append(contentsOf: fragment.packet)
        stream.hashes.append(SHA256.hash(data: fragment.packet).map { String(format: "%02x", $0) }.joined())
        while stream.bytes.count >= 8 {
            let bytes = stream.bytes
            guard bytes[0] == 0xAA, bytes[1] == 1,
                WhoopFrameIntegrity.crc16Modbus(bytes.prefix(6)) == UInt16(bytes[6]) | UInt16(bytes[7]) << 8
            else {
                stream.bytes.removeFirst()
                continue
            }
            let count = Int(bytes[2]) | Int(bytes[3]) << 8
            let total = count + 8
            guard (16...4096).contains(total), (count - 4).isMultiple(of: 4) else {
                stream.bytes.removeFirst()
                continue
            }
            if bytes.count >= 10, bytes[8] == 43, bytes[9] == 21, total == 1244 {
                result.liveIMUHeader = true
            }
            guard bytes.count >= total else { break }
            let packet = Array(bytes.prefix(total))
            guard WhoopFrameIntegrity.isValid(packet) else {
                stream.bytes.removeFirst()
                continue
            }
            result.frames.append(Frame(packet: Data(packet), sourceHashes: stream.hashes))
            stream.bytes.removeFirst(total)
            // A notification can contain the tail of one frame and the next.
            stream.hashes = stream.bytes.isEmpty ? [] : [stream.hashes.last ?? ""]
        }
        if stream.bytes.count > 4096 { stream = Stream(lastAt: fragment.deliveredAt) }
        streams[key] = stream
        bufferedByteCount = streams.values.reduce(0) { $0 + $1.bytes.count }
        return result
    }

}
