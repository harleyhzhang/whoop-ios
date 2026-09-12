import Foundation

struct WhoopSleepSnapshot: Sendable {
    let isSleeping: Bool
    let sampleAt: Date?
    let finalizedRecord: DailyHealthRecord?
    /// A main sleep the strap has detected but has not atomically stored with
    /// all four primary metrics yet. Non-nil is exactly the condition the
    /// dashboard reports as "Sleep detected".
    let pendingSleep: WhoopPendingSleep?
}

struct WhoopPendingSleep: Sendable, Equatable {
    let sleepID: String
    let startedAt: Date
    let endedAt: Date
    let durationMinutes: Double
}

/// A factual account of what the strap actually banked and how each gate judged
/// it, so a night that produced no record can be explained instead of only
/// showing dashes.
struct WhoopSleepDiagnostics: Codable, Sendable {
    let generatedAt: String
    let windowHours: Int
    let sampleCount: Int
    let firstSampleAt: String?
    let lastSampleAt: String?
    let secondsSinceLastSample: Int?
    let observedCadenceSeconds: Double?
    let largestGapSeconds: Int?
    let sleepStateHistogram: [String: Int]
    let rawType47PacketTotal: Int
    let historicalSampleTotal: Int
    let recentType47Outcomes: [String: Int]
    let sessions: [WhoopSleepSessionDiagnostics]
    let outcome: String
}

struct WhoopSleepSessionDiagnostics: Codable, Sendable {
    let startedAt: String
    let endedAt: String
    let spanMinutes: Double
    let durationMinutes: Double
    let sampleCount: Int
    let coverage: Double
    let sampleDensity: Double
    let bankedWakeMinutes: Double
    let minutesSinceLastAsleep: Double
    let passesDurationGate: Bool
    let passesCoverageGate: Bool
    let passesWakeCoverageGate: Bool
    let passesWakeElapsedGate: Bool
    let dateKey: String
    let storedSleepID: String?
    let storedSummary: String?
    let verdict: String
}

enum WhoopSleepProcessError: Error, Sendable {
    case storeUnavailable
    case noRecentData
    case stillAsleep
    case noSleepDetected
    case insufficientEvidence
    case historyStillLoading
    case metricsStillLoading
    case writeFailed

    var message: String {
        switch self {
        case .storeUnavailable: return "Local store unavailable"
        case .noRecentData: return "No recent strap data"
        case .stillAsleep: return "Still asleep"
        case .noSleepDetected: return "No sleep detected"
        case .insufficientEvidence: return "Not enough data to score"
        case .historyStillLoading: return "Still receiving sleep history"
        case .metricsStillLoading: return "Still receiving sleep data"
        case .writeFailed: return "Could not save"
        }
    }
}

struct WhoopLatestHeartRateSample: Sendable {
    let heartRate: Int
    let receivedAt: Date
}

struct WhoopPacketPersistenceResult: Sendable {
    let success: Bool
    let deliverySequence: Int64?
}
