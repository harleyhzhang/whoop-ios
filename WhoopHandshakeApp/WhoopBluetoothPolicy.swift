import Foundation

enum WhoopHistoryCompletionAction: Equatable {
    case ignore
    case finalizeManualProcess
    case analyzeAutomatically
}

struct WhoopHistoricalMetadata: Equatable {
    let type: UInt8
    let chunkEndData: [UInt8]?

    init?(data: Data, frameType: UInt8?) {
        let bytes = [UInt8](data)
        guard
            bytes.count > 10,
            frameType == 49 || frameType == 56,
            WhoopFrameIntegrity.isValid(data)
        else { return nil }

        type = bytes[10]
        if type == 2 {
            // The eight-byte chunk terminator ends at offset 28; four trailer
            // checksum bytes must still follow it.
            guard bytes.count >= 33 else { return nil }
            chunkEndData = Array(bytes[21..<29])
        } else {
            chunkEndData = nil
        }
    }

    func shouldForcePresentation(historicalSyncActive: Bool) -> Bool {
        type == 1 || (type == 3 && historicalSyncActive)
    }
}

/// Typed commands keep wire opcodes and payload shapes out of the Bluetooth
/// lifecycle coordinator. The low-level frame encoder remains independently
/// testable, while production call sites can only construct known commands.
enum WhoopCommand: Equatable {
    case clientHello
    case requestHistory
    case acknowledgeHistoryChunk([UInt8])
    case realtimeSensors(enabled: Bool)
    case realtimeHeartRate(enabled: Bool)

    var opcode: UInt8 {
        switch self {
        case .clientHello: 0x91
        case .requestHistory: 22
        case .acknowledgeHistoryChunk: 23
        case .realtimeSensors: 0x3F
        case .realtimeHeartRate: 0x03
        }
    }

    var payload: [UInt8] {
        switch self {
        case .clientHello: [0x01]
        case .requestHistory: [0x00]
        case .acknowledgeHistoryChunk(let endData): [0x01] + endData
        case .realtimeSensors(let enabled), .realtimeHeartRate(let enabled):
            [enabled ? 0x01 : 0x00]
        }
    }

    func frame(sequence: UInt8) -> [UInt8] {
        WhoopBluetoothPolicy.commandFrame(
            command: opcode,
            sequence: sequence,
            payload: payload
        )
    }
}

enum WhoopBluetoothPolicy {
    static func matchesAdvertisement(
        serviceUUIDs: Set<String>,
        advertisedName: String?,
        peripheralName: String?,
        whoopServiceUUID: String
    ) -> Bool {
        if serviceUUIDs.contains(whoopServiceUUID.uppercased()) { return true }
        let name = (advertisedName ?? peripheralName ?? "").lowercased()
        return name == "w" || name.contains("whoop") || name.contains("puffin")
    }

    static func inferredCharging(
        previousLevel: Int?,
        currentLevel: Int,
        hasExplicitChargingState: Bool,
        currentChargingState: Bool
    ) -> Bool {
        guard !hasExplicitChargingState, let previousLevel else { return currentChargingState }
        if currentLevel > previousLevel { return true }
        if currentLevel < previousLevel { return false }
        return currentChargingState
    }

    static func shouldAcknowledgeChunk(
        endData: [UInt8],
        previousEndData: [UInt8]?,
        previousAcknowledgedAt: Date?,
        now: Date,
        minimumRetryInterval: TimeInterval = 2
    ) -> Bool {
        guard endData.count == 8 else { return false }
        guard
            endData == previousEndData,
            let previousAcknowledgedAt
        else { return true }
        return now.timeIntervalSince(previousAcknowledgedAt) >= minimumRetryInterval
    }

    static func historyCompletionAction(
        metadataType: UInt8?,
        historicalSyncActive: Bool,
        hasPendingProcess: Bool
    ) -> WhoopHistoryCompletionAction {
        guard metadataType == 3, historicalSyncActive || hasPendingProcess else { return .ignore }
        return hasPendingProcess ? .finalizeManualProcess : .analyzeAutomatically
    }

    static func commandFrame(command: UInt8, sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        var inner = [UInt8(0x23), sequence, command] + payload
        let padding = (4 - inner.count % 4) % 4
        if padding > 0 {
            inner += [UInt8](repeating: 0, count: padding)
        }

        let declaredLength = inner.count + 4
        var frame: [UInt8] = [
            0xAA,
            0x01,
            UInt8(declaredLength & 0xFF),
            UInt8((declaredLength >> 8) & 0xFF),
            0x00,
            0x01,
        ]
        let headerCRC = WhoopFrameIntegrity.crc16Modbus(frame)
        frame += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]
        frame += inner
        let trailer = WhoopFrameIntegrity.crc32(inner)
        frame += [
            UInt8(trailer & 0xFF),
            UInt8((trailer >> 8) & 0xFF),
            UInt8((trailer >> 16) & 0xFF),
            UInt8((trailer >> 24) & 0xFF),
        ]
        return frame
    }
}
