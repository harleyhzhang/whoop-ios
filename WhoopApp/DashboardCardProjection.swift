import Foundation

/// Disposable all-history projection over the coherent local store snapshot.
/// Empty dates stay empty, retaining an evenly spaced calendar axis.
struct DashboardCardProjection {
    let days: [HealthDay]
    let selected: HealthDay?

    init(snapshot: DashboardHistorySnapshot, published: PublishedDashboardDay, referenceDate: Date) {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: referenceDate)
        let health = Dictionary(snapshot.healthRecords.map { ($0.dateKey, $0) }, uniquingKeysWith: { _, last in last })
        let steps = Dictionary(snapshot.stepRecords.map { ($0.dateKey, $0) }, uniquingKeysWith: { _, last in last })
        let recovery = Dictionary(
            snapshot.recoveryRecords.map { ($0.dateKey, $0) }, uniquingKeysWith: { _, last in last })
        let strain = Dictionary(snapshot.strainRecords.map { ($0.dateKey, $0) }, uniquingKeysWith: { _, last in last })
        let keys = Set(health.keys).union(steps.keys).union(recovery.keys).union(strain.keys)
        let first =
            keys.compactMap { DayKey.date(from: $0, timeZone: calendar.timeZone) }
            .map { calendar.startOfDay(for: $0) }.filter { $0 <= end }.min() ?? end
        let dayCount = calendar.dateComponents([.day], from: first, to: end).day ?? 0
        days = (0...dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let key = DayKey(date: date, timeZone: calendar.timeZone).rawValue
            let record = health[key]
            return HealthDay(
                day: key, sleep: record?.sleepScore, recovery: recovery[key]?.score,
                strain: strain[key]?.score, steps: steps[key].map { Double($0.stepCount) },
                duration: record?.sleepDurationMinutes, hrv: record?.hrvRMSSDMilliseconds,
                rhr: record?.restingHeartRateBPM, localStrain: strain[key]?.estimate
            )
        }
        guard let date = published.date else {
            selected = nil
            return
        }
        let key = DayKey(date: date, timeZone: calendar.timeZone).rawValue
        selected = HealthDay(
            day: key, sleep: published.health?.sleepScore, recovery: published.recovery?.score,
            strain: strain[key]?.score, steps: published.steps.map { Double($0.stepCount) },
            duration: published.health?.sleepDurationMinutes,
            hrv: published.health?.hrvRMSSDMilliseconds,
            rhr: published.health?.restingHeartRateBPM, localStrain: strain[key]?.estimate
        )
    }
}
