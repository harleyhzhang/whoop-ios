import Combine
import Foundation

extension Notification.Name {
    static let whoopDailyHealthUpdated = Notification.Name("whoopDailyHealthUpdated")
}

enum WhoopHealthHistoryUpdate: Sendable {
    case dayPublished(DailyHealthRecord)
    case projectionsChanged
}

@MainActor
enum WhoopHealthHistoryEvents {
    static func post(_ update: WhoopHealthHistoryUpdate) {
        NotificationCenter.default.post(name: .whoopDailyHealthUpdated, object: update)
    }
}

struct DailyHealthRecord: Codable, Hashable, Identifiable, Sendable {
    let dateKey: String
    let sleepScore: Double?
    /// Display projection only. The store retains WHOOP's official target and
    /// our independently derived score in separate tables/columns.
    let recoveryScore: Double?
    let recoveryScoreSource: String?
    let sleepDurationMinutes: Double?
    let hrvRMSSDMilliseconds: Double?
    let restingHeartRateBPM: Double?
    let sleepID: String?
    let cycleID: Int64?
    let source: String
    let sourceArchive: String?
    let sourceUpdatedAt: String

    /// Retained score inputs. WHOOP API rows preserve the values WHOOP
    /// published; locally derived rows preserve the measurements used by the
    /// versioned replacement model. They intentionally remain optional so an
    /// older private seed can still be decoded during an in-place update.
    let sleepStartAt: String?
    let sleepEndAt: String?
    let sleepStartMinute: Double?
    let sleepEndMinute: Double?
    let sleepNeedMinutes: Double?
    let sleepConsistencyPercentage: Double?
    let sleepEfficiencyPercentage: Double?
    let sleepSufficiencyPercentage: Double?
    /// Complete source rows, retained outside the display projection so future
    /// models can recover fields this version does not yet materialize.
    let sourceSleepPayloadJSON: String?
    let sourceRecoveryPayloadJSON: String?

    init(
        dateKey: String,
        sleepScore: Double?,
        recoveryScore: Double? = nil,
        recoveryScoreSource: String? = nil,
        sleepDurationMinutes: Double?,
        hrvRMSSDMilliseconds: Double?,
        restingHeartRateBPM: Double?,
        sleepID: String?,
        cycleID: Int64?,
        source: String,
        sourceArchive: String?,
        sourceUpdatedAt: String,
        sleepStartAt: String? = nil,
        sleepEndAt: String? = nil,
        sleepStartMinute: Double? = nil,
        sleepEndMinute: Double? = nil,
        sleepNeedMinutes: Double? = nil,
        sleepConsistencyPercentage: Double? = nil,
        sleepEfficiencyPercentage: Double? = nil,
        sleepSufficiencyPercentage: Double? = nil,
        sourceSleepPayloadJSON: String? = nil,
        sourceRecoveryPayloadJSON: String? = nil
    ) {
        self.dateKey = dateKey
        self.sleepScore = sleepScore
        self.recoveryScore = recoveryScore
        self.recoveryScoreSource = recoveryScoreSource
        self.sleepDurationMinutes = sleepDurationMinutes
        self.hrvRMSSDMilliseconds = hrvRMSSDMilliseconds
        self.restingHeartRateBPM = restingHeartRateBPM
        self.sleepID = sleepID
        self.cycleID = cycleID
        self.source = source
        self.sourceArchive = sourceArchive
        self.sourceUpdatedAt = sourceUpdatedAt
        self.sleepStartAt = sleepStartAt
        self.sleepEndAt = sleepEndAt
        self.sleepStartMinute = sleepStartMinute
        self.sleepEndMinute = sleepEndMinute
        self.sleepNeedMinutes = sleepNeedMinutes
        self.sleepConsistencyPercentage = sleepConsistencyPercentage
        self.sleepEfficiencyPercentage = sleepEfficiencyPercentage
        self.sleepSufficiencyPercentage = sleepSufficiencyPercentage
        self.sourceSleepPayloadJSON = sourceSleepPayloadJSON
        self.sourceRecoveryPayloadJSON = sourceRecoveryPayloadJSON
    }

    var id: String { dateKey }

    var hasCompletePrimarySleepMetrics: Bool {
        sleepScore != nil
            && sleepDurationMinutes != nil
            && hrvRMSSDMilliseconds != nil
            && restingHeartRateBPM != nil
    }

    var date: Date {
        DayKey.date(from: dateKey, timeZone: .current) ?? .distantPast
    }
}

struct OfficialMetricsSeed: Decodable, Sendable {
    let formatVersion: Int
    let source: String
    let sourceArchive: String
    let sourceManifestSHA256: String
    let sourceDatabaseSHA256: String
    let coverageStart: String
    let coverageEnd: String
    let daily: [OfficialDailyMetricSeed]
}

struct OfficialDailyMetricSeed: Decodable, Sendable {
    let dateKey: String
    let officialRecoveryScore: Double?
    let officialSteps: Int?
    let officialDayStrain: Double?
    let dayStrainTarget: Double?
    let stepsBaseline: Double?
    let hrv: Double?
    let hrvBaseline: Double?
    let rhr: Double?
    let rhrBaseline: Double?
    let respiratoryRate: Double?
    let respiratoryRateBaseline: Double?
    let sleepPerformance: Double?
    let sleepPerformanceBaseline: Double?
    let sourceRecoverySHA256: String?
    let sourceStrainSHA256: String?
}

struct DailyStepRecord: Hashable, Identifiable, Sendable {
    let dateKey: String
    let stepCount: Int
    let sampleCount: Int
    let spanSeconds: Int
    let coverageFraction: Double
    let gapSeconds: Int
    let counterWrapCount: Int
    let rejectedDeltaCount: Int
    let firstSampleAt: Date?
    let lastSampleAt: Date?
    let source: String
    let algorithmVersion: Int

    var id: String { dateKey }

    var date: Date {
        DayKey.date(from: dateKey, timeZone: .current) ?? .distantPast
    }
}

struct DailyRecoveryRecord: Hashable, Identifiable, Sendable {
    let dateKey: String
    let score: Double
    let source: String

    var id: String { dateKey }

    var date: Date {
        DayKey.date(from: dateKey, timeZone: .current) ?? .distantPast
    }
}

/// One coherent, wake-published dashboard day. A later step-only day represents
/// an explicit missed-sleep fallback: movement remains visible while sleep and
/// recovery stay blank rather than being invented or carried forward.
struct PublishedDashboardDay: Sendable {
    let health: DailyHealthRecord?
    let steps: DailyStepRecord?
    let recovery: DailyRecoveryRecord?

    init(
        healthRecords: [DailyHealthRecord],
        stepRecords: [DailyStepRecord],
        recoveryRecords: [DailyRecoveryRecord]
    ) {
        if let latestSteps = stepRecords.last,
            let latestStepKey = DayKey(rawValue: latestSteps.dateKey)
        {
            let latestHealthKey = healthRecords.last.flatMap {
                DayKey(rawValue: $0.dateKey)
            }
            let displaysMissedSleepDay =
                latestHealthKey.map {
                    latestStepKey.rawValue > $0.rawValue
                } ?? true
            if displaysMissedSleepDay {
                self.health = nil
                self.steps = latestSteps
                self.recovery = nil
                return
            }
        }
        guard let health = healthRecords.last,
            let dayKey = DayKey(rawValue: health.dateKey),
            let steps = stepRecords.last(where: { DayKey(rawValue: $0.dateKey) == dayKey }),
            let recovery = recoveryRecords.last(where: { DayKey(rawValue: $0.dateKey) == dayKey })
        else {
            self.health = nil
            self.steps = nil
            self.recovery = nil
            return
        }

        self.health = health
        self.steps = steps
        self.recovery = recovery
    }

    var date: Date? { health?.date ?? steps?.date }
}

/// One database-generation of every history family consumed by the dashboard.
/// The store constructs this inside one SQLite read transaction so a write can
/// never land between the health, step, and recovery queries.
struct DashboardHistorySnapshot: Sendable {
    let healthRecords: [DailyHealthRecord]
    let stepRecords: [DailyStepRecord]
    let recoveryRecords: [DailyRecoveryRecord]

    static let empty = DashboardHistorySnapshot(
        healthRecords: [],
        stepRecords: [],
        recoveryRecords: []
    )
}
