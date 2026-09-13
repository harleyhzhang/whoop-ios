import Foundation

/// The recovery model contains lag and summary features through 60 prior
/// eligible days and cannot observe anything older.
struct WhoopRollingRecoveryHistory {
    static let maximumRecordCount = 60

    private(set) var records: [DailyHealthRecord] = []

    mutating func append(_ record: DailyHealthRecord) {
        guard RecoveryScoreFeatureBuilder.isEligibleHistoryRecord(record) else { return }
        records.append(record)
        if records.count > Self.maximumRecordCount {
            records.removeFirst(records.count - Self.maximumRecordCount)
        }
    }
}

struct WhoopIndexedSleepRange: Sendable, Equatable {
    let sessionRange: Range<Int>
    let asleepIndices: [Int]
}

/// Builds non-overlapping sleep evidence ranges in one forward pass. Every row
/// is classified once; later scoring slices only its own indexed range rather
/// than filtering the complete historical collection again.
enum WhoopBackfillPlanner {
    static func indexedSleepRanges<Row>(
        in rows: [Row],
        maximumInterruptionSeconds: TimeInterval = WhoopAutomaticSleepPolicy.reopenWindow,
        timestamp: (Row) -> TimeInterval,
        isAsleep: (Row) -> Bool
    ) -> [WhoopIndexedSleepRange] {
        var ranges: [WhoopIndexedSleepRange] = []
        var firstAsleepIndex: Int?
        var lastIncludedIndex: Int?
        var lastAsleepTimestamp: TimeInterval?
        var previousRowTimestamp: TimeInterval?
        var timestampRunStartIndex = rows.startIndex
        var asleepIndices: [Int] = []

        func finishRange() {
            guard let firstAsleepIndex, let lastIncludedIndex else { return }
            ranges.append(
                WhoopIndexedSleepRange(
                    sessionRange: firstAsleepIndex..<(lastIncludedIndex + 1),
                    asleepIndices: asleepIndices
                ))
        }

        for index in rows.indices {
            let row = rows[index]
            let rowTimestamp = timestamp(row)
            if rowTimestamp != previousRowTimestamp {
                timestampRunStartIndex = index
                previousRowTimestamp = rowTimestamp
            }
            guard isAsleep(row) else {
                if rowTimestamp == lastAsleepTimestamp { lastIncludedIndex = index }
                continue
            }
            if let lastAsleepTimestamp,
                rowTimestamp - lastAsleepTimestamp > maximumInterruptionSeconds
            {
                finishRange()
                firstAsleepIndex = timestampRunStartIndex
                asleepIndices = [index]
            } else {
                if firstAsleepIndex == nil { firstAsleepIndex = timestampRunStartIndex }
                asleepIndices.append(index)
            }
            lastIncludedIndex = index
            lastAsleepTimestamp = rowTimestamp
        }
        finishRange()
        return ranges
    }
}
