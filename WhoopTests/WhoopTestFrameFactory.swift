import Foundation

@testable import Whoop

enum WhoopTestFrameFactory {
    static func frame(length: Int, type: UInt8, version: UInt8) -> [UInt8] {
        precondition(length >= 12)
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 0xAA
        bytes[1] = 0x01
        let declared = UInt16(length - 8)
        bytes[2] = UInt8(truncatingIfNeeded: declared)
        bytes[3] = UInt8(truncatingIfNeeded: declared >> 8)
        bytes[4] = 0x01
        bytes[8] = type
        bytes[9] = version
        return bytes
    }

    static func finishChecksums(_ bytes: inout [UInt8]) {
        precondition(bytes.count >= 12)
        let headerCRC = WhoopFrameIntegrity.crc16Modbus(bytes[0..<6])
        bytes[6] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[7] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        let payloadEnd = bytes.count - 4
        let payloadCRC = WhoopFrameIntegrity.crc32(bytes[8..<payloadEnd])
        bytes[payloadEnd] = UInt8(truncatingIfNeeded: payloadCRC)
        bytes[payloadEnd + 1] = UInt8(truncatingIfNeeded: payloadCRC >> 8)
        bytes[payloadEnd + 2] = UInt8(truncatingIfNeeded: payloadCRC >> 16)
        bytes[payloadEnd + 3] = UInt8(truncatingIfNeeded: payloadCRC >> 24)
    }

    static func historicalMetadata(
        type: UInt8,
        chunkEnd: [UInt8] = [],
        length: Int = 36,
        frameType: UInt8 = 49
    ) -> Data {
        var bytes = frame(length: length, type: frameType, version: 1)
        bytes[10] = type
        if type == 2 {
            precondition(chunkEnd.count == 8)
            precondition(length >= 29)
            bytes.replaceSubrange(21..<29, with: chunkEnd)
        }
        finishChecksums(&bytes)
        return Data(bytes)
    }
}
