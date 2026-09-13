import Foundation

/// Semantic handshake state. User-facing copy is derived from this value and
/// must never be parsed to decide connection behavior.
enum HandshakePhase: Sendable, Equatable {
    case waitingForDevice
    case ready
    case writingClientHello
    case acknowledged
    case confirmedWritesUnavailable
    case disconnectedBeforeAcknowledgement
    case timedOut
    case refused(reason: String)

    var isAcknowledged: Bool { self == .acknowledged }
    var canAutomaticallyAttempt: Bool { self == .ready }

    var displayText: String {
        switch self {
        case .waitingForDevice: "Waiting for WHOOP 5"
        case .ready: "Ready"
        case .writingClientHello: "Writing CLIENT_HELLO"
        case .acknowledged: "Acknowledged — encrypted link established"
        case .confirmedWritesUnavailable: "Confirmed writes unavailable"
        case .disconnectedBeforeAcknowledgement:
            "Link dropped before CLIENT_HELLO acknowledgement"
        case .timedOut: "Handshake timed out; resetting connection"
        case .refused(let reason): "Refused: \(reason)"
        }
    }
}

/// WHOOP's stored two-bit sleep classifier. Both explicit awake values remain
/// distinct because their finer meaning has not been independently verified.
enum SleepState: Sendable, Equatable, Hashable {
    case awakePrimary
    case awakeAlternate
    case asleep
    case up
    case unknown(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .awakePrimary
        case 1: self = .awakeAlternate
        case 2: self = .asleep
        case 3: self = .up
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .awakePrimary: 0
        case .awakeAlternate: 1
        case .asleep: 2
        case .up: 3
        case .unknown(let rawValue): rawValue
        }
    }

    var isExplicitlyAwake: Bool {
        self == .awakePrimary || self == .awakeAlternate
    }
}

/// Packet type byte carried at offset 8 of proprietary WHOOP frames.
enum FrameType: Sendable, Equatable, Hashable {
    case transport36
    case transport38
    case realtimeHeartRate
    case historicalSample
    case wristState
    case historicalMetadata
    case transport50
    case historicalMetadataAlternate
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 36: self = .transport36
        case 38: self = .transport38
        case 40: self = .realtimeHeartRate
        case 47: self = .historicalSample
        case 48: self = .wristState
        case 49: self = .historicalMetadata
        case 50: self = .transport50
        case 56: self = .historicalMetadataAlternate
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: UInt8 {
        switch self {
        case .transport36: 36
        case .transport38: 38
        case .realtimeHeartRate: 40
        case .historicalSample: 47
        case .wristState: 48
        case .historicalMetadata: 49
        case .transport50: 50
        case .historicalMetadataAlternate: 56
        case .unknown(let rawValue): rawValue
        }
    }

    var isHistoricalMetadata: Bool {
        self == .historicalMetadata || self == .historicalMetadataAlternate
    }

    var isReplayProne: Bool {
        switch self {
        case .transport36, .transport38, .historicalSample, .historicalMetadata,
            .transport50, .historicalMetadataAlternate:
            true
        default:
            false
        }
    }
}

/// Metadata subtype byte carried at offset 10 of history-control frames.
enum MetadataType: Sendable, Equatable, Hashable {
    case historyStart
    case chunkEnd
    case historyComplete
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 1: self = .historyStart
        case 2: self = .chunkEnd
        case 3: self = .historyComplete
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: UInt8 {
        switch self {
        case .historyStart: 1
        case .chunkEnd: 2
        case .historyComplete: 3
        case .unknown(let rawValue): rawValue
        }
    }
}

/// Charging is semantic state; unknown protocol values remain inspectable
/// instead of being collapsed into `false`.
enum BatteryStatus: Sendable, Equatable {
    case unavailable
    case charging
    case notCharging
    case unknown(rawValue: UInt16)

    var isCharging: Bool { self == .charging }
    var isExplicit: Bool {
        switch self {
        case .charging, .notCharging, .unknown: true
        case .unavailable: false
        }
    }
}
