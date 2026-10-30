import Foundation

enum DashboardCurrentDayPolicy {
    /// The night in progress is the current day. Without one, detected sleep
    /// dashes the previous day rather than presenting it as current.
    static func displayedDay(
        snapshot: DashboardHistorySnapshot,
        provisional: WhoopProvisionalDay? = nil,
        metricsArePending: Bool
    ) -> PublishedDashboardDay {
        if let provisional { return PublishedDashboardDay(provisional: provisional) }
        return PublishedDashboardDay(
            healthRecords: metricsArePending ? [] : snapshot.healthRecords,
            stepRecords: metricsArePending ? [] : snapshot.stepRecords,
            recoveryRecords: metricsArePending ? [] : snapshot.recoveryRecords
        )
    }
}
