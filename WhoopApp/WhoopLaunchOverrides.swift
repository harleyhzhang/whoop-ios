import Foundation

enum WhoopLaunchOverrides {
    /// Simulator design review reads a real retained day without changing storage.
    static var previewDay: String? {
        #if DEBUG && targetEnvironment(simulator)
            guard let key = value(for: "WHOOP_PREVIEW_DAY"), DayKey(rawValue: key) != nil else { return nil }
            return key
        #else
            return nil
        #endif
    }

    static var isConnected: Bool {
        value(for: "WHOOP_MOCK_CONNECTED") == "1"
    }

    static var isCharging: Bool {
        value(for: "WHOOP_MOCK_CHARGING") == "1"
    }

    static var batteryLevel: Int? {
        guard let rawValue = value(for: "WHOOP_MOCK_BATTERY"), let level = Int(rawValue) else {
            return nil
        }
        return min(max(level, 0), 100)
    }

    static var powerPackBatteryLevel: Int? {
        guard let rawValue = value(for: "WHOOP_MOCK_POWER_PACK_BATTERY"),
            let level = Int(rawValue)
        else {
            return nil
        }
        return min(max(level, 0), 100)
    }

    /// A night in progress for design review: `minutes` or `minutes,sleep,recovery`.
    /// Scores stay hidden below the same evidence minimum as a real night.
    static var provisionalDay: WhoopProvisionalDay? {
        guard let values = value(for: "WHOOP_MOCK_PROVISIONAL")?.split(separator: ",").compactMap({ Double($0) }),
            let minutes = values.first
        else { return nil }
        let scored = WhoopProvisionalSleepPolicy.showsScores(sleepSeconds: minutes * 60)
        let dateKey = DayKey(date: .now, timeZone: .current).rawValue
        return WhoopProvisionalDay(
            health: DailyHealthRecord(
                dateKey: dateKey, sleepScore: scored && values.count > 1 ? values[1] : nil,
                sleepDurationMinutes: minutes, hrvRMSSDMilliseconds: 58, restingHeartRateBPM: 51,
                sleepID: "mock", cycleID: nil, source: "mock", sourceArchive: nil, sourceUpdatedAt: ""),
            steps: DailyStepRecord(
                dateKey: dateKey, stepCount: 0, sampleCount: 0, spanSeconds: 0, coverageFraction: 0,
                gapSeconds: 0, counterWrapCount: 0, rejectedDeltaCount: 0, firstSampleAt: nil,
                lastSampleAt: nil, source: "mock", algorithmVersion: WhoopStepDaySummary.algorithmVersion),
            recovery: scored && values.count > 2
                ? DailyRecoveryRecord(dateKey: dateKey, score: values[2], source: "mock") : nil
        )
    }

    private static func value(for key: String) -> String? {
        #if DEBUG
            ProcessInfo.processInfo.environment[key]
        #else
            nil
        #endif
    }
}
