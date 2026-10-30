import CryptoKit
import Foundation

/// Observed WHOOP 5 format-1 protocol, not an assertion of support on every firmware.
/// Raw packets remain authoritative; no resampling, orientation or strength score is inferred.
enum WhoopMotionProtocol {
    struct Reply: Equatable, Sendable {
        let command: UInt8
        let origin: UInt8
        let result: UInt8
        let receivedAt: Date
    }

    struct Buffer: Codable, Equatable, Sendable {
        let sha256: String
        let sensorAt: Date
        let receivedAt: Date
        let accelerometerCount: Int
        let gyroscopeCount: Int
        let configuration: [UInt8]
    }

    enum Event: Sendable {
        case reply(Reply)
        case buffer(Buffer)
    }

    static func event(_ envelope: WhoopPacketEnvelope) -> Event? {
        guard envelope.integrityIsValid else { return nil }
        let bytes = [UInt8](envelope.packet)
        guard bytes.count >= 12, bytes[1] == 1 else { return nil }
        if bytes.count >= 20, bytes[8] == 36 {
            return .reply(
                Reply(command: bytes[10], origin: bytes[11], result: bytes[12], receivedAt: envelope.deliveredAt))
        }
        // R21 has independent, bounded valid-sample counts. Types 51/52 have a
        // different layout; an ACK or an R18 gravity vector is never IMU evidence.
        guard bytes.count == 1244, [43, 47].contains(bytes[8]), bytes[9] == 21 else { return nil }
        let fraction = unsigned16(bytes, at: 19)
        let accelCount = unsigned16(bytes, at: 24)
        let gyroCount = unsigned16(bytes, at: 630)
        guard fraction <= 32440, accelCount <= 100, gyroCount <= 100 else { return nil }
        let seconds =
            UInt32(bytes[15]) | UInt32(bytes[16]) << 8
            | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 24
        let sensorAt = Date(timeIntervalSince1970: Double(seconds) + Double(fraction) / 32768)
        return .buffer(
            Buffer(
                sha256: SHA256.hash(data: envelope.packet).map { String(format: "%02x", $0) }.joined(),
                sensorAt: sensorAt, receivedAt: envelope.deliveredAt,
                accelerometerCount: Int(accelCount), gyroscopeCount: Int(gyroCount),
                configuration: [21, 22, 26, 27, 628, 632, 633].map { bytes[$0] }
            ))
    }

    private static func unsigned16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}
