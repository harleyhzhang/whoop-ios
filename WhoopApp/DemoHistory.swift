import Foundation

/// Synthetic, clearly fake history for screenshots and first-run demos.
/// Enabled only in simulator Debug builds with `WHOOP_DEMO_DATA=1`.
enum DemoHistory {
    static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
            ProcessInfo.processInfo.environment["WHOOP_DEMO_DATA"] == "1"
        #else
            false
        #endif
    }

    /// Smooth deterministic variation so every launch renders the same charts.
    private static func wave(_ day: Int, _ period: Double, _ phase: Double) -> Double {
        sin(Double(day) / period * 2 * .pi + phase)
    }

    static func snapshot(days: Int = 120, endingAt end: Date = .now) -> DashboardHistorySnapshot {
        let calendar = Calendar.current
        var health: [DailyHealthRecord] = []
        var steps: [DailyStepRecord] = []
        var recovery: [DailyRecoveryRecord] = []
        var strain: [DailyStrainRecord] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            let key = DayKey(date: date, timeZone: .current).rawValue
            let day = days - offset
            let recoveryScore = min(max(62 + 26 * wave(day, 9, 0) + 8 * wave(day, 3.1, 1), 8), 98)
            health.append(
                DailyHealthRecord(
                    dateKey: key,
                    sleepScore: min(max(80 + 12 * wave(day, 11, 0.5), 40), 99),
                    sleepDurationMinutes: 450 + 40 * wave(day, 7, 2),
                    hrvRMSSDMilliseconds: 62 + 10 * wave(day, 13, 0.3),
                    restingHeartRateBPM: 54 - 3 * wave(day, 13, 0.3),
                    sleepID: nil, cycleID: nil, source: "demo", sourceArchive: nil,
                    sourceUpdatedAt: key
                ))
            steps.append(
                DailyStepRecord(
                    dateKey: key, stepCount: Int(9_000 + 3_000 * wave(day, 6, 1.2)), sampleCount: 0,
                    spanSeconds: 0, coverageFraction: 1, gapSeconds: 0, counterWrapCount: 0,
                    rejectedDeltaCount: 0, firstSampleAt: nil, lastSampleAt: nil, source: "demo",
                    algorithmVersion: 0
                ))
            recovery.append(DailyRecoveryRecord(dateKey: key, score: recoveryScore.rounded(), source: "demo"))
            strain.append(
                DailyStrainRecord(dateKey: key, score: 11 + 5 * wave(day, 5, 0.8), source: "demo", estimate: nil))
        }
        return DashboardHistorySnapshot(
            healthRecords: health, stepRecords: steps, recoveryRecords: recovery, strainRecords: strain)
    }
}
