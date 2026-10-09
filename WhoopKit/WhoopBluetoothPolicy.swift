import Foundation

struct WhoopHistoricalMetadata: Equatable {
    let type: MetadataType
    let chunkEndData: [UInt8]?

    init(type: MetadataType, chunkEndData: [UInt8]?) {
        self.type = type
        self.chunkEndData = chunkEndData
    }

    init?(data: Data, frameType: FrameType?) {
        let bytes = [UInt8](data)
        self.init(
            bytes: bytes,
            frameType: frameType,
            integrityIsValid: WhoopFrameIntegrity.isValid(bytes)
        )
    }

    init?(
        bytes: [UInt8],
        frameType: FrameType?,
        integrityIsValid: Bool
    ) {
        guard
            bytes.count > 10,
            frameType?.isHistoricalMetadata == true,
            integrityIsValid
        else { return nil }

        type = MetadataType(rawValue: bytes[10])
        if type == .chunkEnd {
            // The eight-byte chunk terminator ends at offset 28; four trailer
            // checksum bytes must still follow it.
            guard bytes.count >= 33 else { return nil }
            chunkEndData = Array(bytes[21..<29])
        } else {
            chunkEndData = nil
        }
    }

    func shouldForcePresentation(historicalSyncActive: Bool) -> Bool {
        type == .historyStart || (type == .historyComplete && historicalSyncActive)
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
    static func freshWristState(
        _ data: Data,
        receivedAt: Date,
        freshnessWindow: TimeInterval = 45
    ) -> Bool? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20,
            FrameType(rawValue: bytes[8]) == .wristState,
            WhoopFrameIntegrity.isValid(bytes)
        else { return nil }
        return freshWristState(
            bytes: bytes,
            receivedAt: receivedAt,
            freshnessWindow: freshnessWindow
        )
    }

    static func freshWristState(
        bytes: [UInt8],
        receivedAt: Date,
        freshnessWindow: TimeInterval
    ) -> Bool? {
        guard bytes.count >= 20 else { return nil }
        let timestamp =
            UInt32(bytes[12])
            | (UInt32(bytes[13]) << 8)
            | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)
        let eventDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        guard abs(receivedAt.timeIntervalSince(eventDate)) <= freshnessWindow else { return nil }
        switch bytes[10] {
        case 9: return true
        case 10: return false
        default: return nil
        }
    }

    /// Keep the last valid percentage across disconnects and relaunches, regardless of age.
    static func cachedBatteryLevel(_ value: Any?) -> Int? {
        guard let level = value as? Int, (0...100).contains(level) else { return nil }
        return level
    }

    static func batteryLevelStatus(_ data: Data) -> BatteryStatus? {
        guard data.count >= 3 else { return nil }
        let powerState = UInt16(data[1]) | (UInt16(data[2]) << 8)
        let wiredPower = (powerState >> 1) & 0b11
        let wirelessPower = (powerState >> 3) & 0b11
        let chargeState = (powerState >> 5) & 0b11
        if chargeState == 1 || wiredPower == 1 || wirelessPower == 1 { return .charging }
        if chargeState == 2 || chargeState == 3 { return .notCharging }
        return .unknown(rawValue: powerState)
    }

    static func legacyBatteryStatus(_ data: Data) -> BatteryStatus? {
        guard let powerState = data.first else { return nil }
        switch (powerState >> 4) & 0b11 {
        case 3: return .charging
        case 1, 2: return .notCharging
        default: return .unknown(rawValue: UInt16(powerState))
        }
    }

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

    static func shouldAnalyzeHistoryCompletion(
        metadataType: MetadataType?,
        historicalSyncActive: Bool
    ) -> Bool {
        metadataType == .historyComplete && historicalSyncActive
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

/// Keeps hardware status separate from trend estimates so estimates cannot latch.
struct WhoopBatteryState {
    private(set) var level: Int?
    private(set) var status = BatteryStatus.unavailable
    private var hardwareStatus = BatteryStatus.unavailable
    private var previousLiveLevel: Int?

    init(cachedLevel: Int? = nil) {
        level = cachedLevel
    }

    mutating func observe(_ observation: BatteryObservation) {
        if observation.status.isExplicit {
            hardwareStatus = observation.status
        }
        if hardwareStatus.isExplicit {
            status = hardwareStatus
        } else if let currentLevel = observation.level, let previousLiveLevel {
            if currentLevel > previousLiveLevel { status = .charging }
            if currentLevel < previousLiveLevel { status = .notCharging }
        }
        if let currentLevel = observation.level {
            level = currentLevel
            previousLiveLevel = currentLevel
        }
    }

    mutating func resetConnection() {
        hardwareStatus = .unavailable
        status = .unavailable
        previousLiveLevel = nil
    }
}
