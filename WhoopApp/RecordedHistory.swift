import Foundation

/// Explicit browsing of stored measurements, independent of live publication.
/// Dates without records remain selectable and never inherit adjacent values.
struct RecordedHistory {
    let days: [HealthDay]

    init(snapshot: DashboardHistorySnapshot) {
        let keys =
            snapshot.healthRecords.map(\.dateKey) + snapshot.stepRecords.map(\.dateKey)
            + snapshot.recoveryRecords.map(\.dateKey) + snapshot.strainRecords.map(\.dateKey)
        guard let latest = keys.compactMap({ DayKey(rawValue: $0) }).max(),
            let end = latest.date(timeZone: .current)
        else {
            days = []
            return
        }
        days =
            DashboardCardProjection(
                snapshot: snapshot,
                published: PublishedDashboardDay(healthRecords: [], stepRecords: [], recoveryRecords: []),
                referenceDate: end
            ).days
    }

    func day(_ key: String) -> HealthDay? { days.first { $0.day == key } }

    func neighbor(of key: String, offset: Int) -> String? {
        guard let index = days.firstIndex(where: { $0.day == key }),
            days.indices.contains(index + offset)
        else { return nil }
        return days[index + offset].day
    }

    func window(endingAt key: String, count: Int) -> [HealthDay] {
        guard count > 0, let index = days.firstIndex(where: { $0.day == key }) else { return [] }
        return Array(days[max(0, index - count + 1)...index])
    }
}
