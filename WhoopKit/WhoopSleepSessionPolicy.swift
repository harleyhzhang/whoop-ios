import Foundation

extension WhoopStore {
    /// A long `up` interval can occur inside a night and then return to the
    /// strap's explicit asleep state. Keep that as one sleep session. A
    /// completed main sleep also gets a narrow same-morning exception for a
    /// return between 90 minutes and two hours later.
    static func groupedAsleepRows(
        _ asleepRows: [HistoricalRow],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [[HistoricalRow]] {
        var groups: [[HistoricalRow]] = []
        for row in asleepRows {
            if let first = groups.last?.first, let last = groups.last?.last,
                WhoopAutomaticSleepPolicy.shouldMergeAsleepRuns(
                    firstAsleepTimestamp: first.timestamp,
                    lastAsleepTimestamp: last.timestamp,
                    nextAsleepTimestamp: row.timestamp,
                    timeZone: timeZone
                )
            {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups
    }
}
