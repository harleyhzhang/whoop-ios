import Foundation

/// Immutable result of parsing one delivered packet. Proprietary payloads are
/// converted to bytes and CRC-checked exactly once before they reach storage.
struct WhoopPacketEnvelope: Sendable {
    let packet: Data
    let peripheralID: UUID
    let characteristicUUID: String
    let frameType: FrameType?
    let integrityIsValid: Bool
    let realtime: WhoopDecodedRealtime?
    let historical: WhoopDecodedHistorical?
    let ppg: WhoopDecodedPPG?
    let metadata: WhoopHistoricalMetadata?
    let freshWristState: Bool?
    let offloadSessionID: String?
    let deduplicateTransportRetries: Bool
    let deliveredAt: Date
    let proprietaryOrdinal: Int?

    static func standardHeartRate(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        deliveredAt: Date
    ) -> WhoopPacketEnvelope? {
        guard let realtime = WhoopDecodedRealtime.decodeStandardHeartRate(packet) else {
            return nil
        }
        return WhoopPacketEnvelope(
            packet: packet,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            frameType: nil,
            integrityIsValid: false,
            realtime: realtime,
            historical: nil,
            ppg: nil,
            metadata: nil,
            freshWristState: nil,
            offloadSessionID: nil,
            deduplicateTransportRetries: false,
            deliveredAt: deliveredAt,
            proprietaryOrdinal: nil
        )
    }

    static func proprietary(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        offloadSessionID: String?,
        deliveredAt: Date,
        proprietaryOrdinal: Int,
        wristFreshnessWindow: TimeInterval = 45
    ) -> WhoopPacketEnvelope {
        let bytes = [UInt8](packet)
        let frameType = bytes.count > 8 ? FrameType(rawValue: bytes[8]) : nil
        let integrityIsValid = WhoopFrameIntegrity.isValid(bytes)
        return WhoopPacketEnvelope(
            packet: packet,
            peripheralID: peripheralID,
            characteristicUUID: characteristicUUID,
            frameType: frameType,
            integrityIsValid: integrityIsValid,
            realtime: WhoopDecodedRealtime.decodeWhoop5Realtime(
                bytes: bytes,
                integrityIsValid: integrityIsValid
            ),
            historical: WhoopDecodedHistorical.decode(
                bytes: bytes,
                integrityIsValid: integrityIsValid
            ),
            ppg: WhoopDecodedPPG.decode(
                bytes: bytes,
                integrityIsValid: integrityIsValid
            ),
            metadata: WhoopHistoricalMetadata(
                bytes: bytes,
                frameType: frameType,
                integrityIsValid: integrityIsValid
            ),
            freshWristState: freshWristState(
                bytes: bytes,
                frameType: frameType,
                integrityIsValid: integrityIsValid,
                deliveredAt: deliveredAt,
                freshnessWindow: wristFreshnessWindow
            ),
            offloadSessionID: offloadSessionID,
            deduplicateTransportRetries: frameType?.isReplayProne == true,
            deliveredAt: deliveredAt,
            proprietaryOrdinal: proprietaryOrdinal
        )
    }

    private static func freshWristState(
        bytes: [UInt8],
        frameType: FrameType?,
        integrityIsValid: Bool,
        deliveredAt: Date,
        freshnessWindow: TimeInterval
    ) -> Bool? {
        guard bytes.count >= 20,
            frameType == .wristState,
            integrityIsValid
        else { return nil }
        let timestamp =
            UInt32(bytes[12])
            | (UInt32(bytes[13]) << 8)
            | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)
        let eventDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        guard abs(deliveredAt.timeIntervalSince(eventDate)) <= freshnessWindow else { return nil }
        switch bytes[10] {
        case 9: return true
        case 10: return false
        default: return nil
        }
    }
}
