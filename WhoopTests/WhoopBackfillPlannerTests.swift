import XCTest

@testable import Whoop

final class WhoopBackfillPlannerTests: XCTestCase {
    func testRollingRecoveryHistoryMatchesAllPriorRecordFeatures() throws {
        let records = makeRecoveryRecords(count: 730)
        let stepsByDate = Dictionary(
            uniqueKeysWithValues: records.enumerated().map { index, record in
                (record.dateKey, Double(5_000 + index * 13))
            }
        )
        var rolling = WhoopRollingRecoveryHistory()

        for (index, current) in records.enumerated() {
            let legacy = try XCTUnwrap(
                RecoveryScoreFeatureBuilder.features(
                    current: current,
                    history: Array(records[..<index]),
                    stepsByDate: stepsByDate
                ))
            let optimized = try XCTUnwrap(
                RecoveryScoreFeatureBuilder.features(
                    current: current,
                    history: rolling.records,
                    stepsByDate: stepsByDate
                ))

            XCTAssertEqual(optimized, legacy, "Feature drift on \(current.dateKey)")
            rolling.append(current)
        }
    }

    func testRollingRecoveryHistoryKeepsOnlyLatestSixtyEligibleDays() {
        let records = makeRecoveryRecords(count: 100)
        var rolling = WhoopRollingRecoveryHistory()
        for record in records { rolling.append(record) }

        XCTAssertEqual(rolling.records.count, 60)
        XCTAssertEqual(rolling.records.first?.dateKey, records[40].dateKey)
        XCTAssertEqual(rolling.records.last?.dateKey, records[99].dateKey)

        rolling.append(makeRecoveryRecord(dateKey: "not-a-day", index: 101))
        XCTAssertEqual(rolling.records.count, 60)
        XCTAssertEqual(rolling.records.first?.dateKey, records[40].dateKey)
    }

    func testIndexedSleepRangesMatchLegacyFullCollectionFiltering() {
        var generator = DeterministicGenerator(state: 0x5EED_F00D)
        for _ in 0..<250 {
            var timestamp = 1_800_000_000.0
            var rows: [SyntheticSleepRow] = []
            for _ in 0..<1_000 {
                timestamp += Double(1 + generator.next() % 8_000)
                rows.append(
                    SyntheticSleepRow(
                        timestamp: timestamp,
                        isAsleep: generator.next() % 5 == 0
                    ))
            }

            let indexed = WhoopBackfillPlanner.indexedSleepRanges(
                in: rows,
                timestamp: { $0.timestamp },
                isAsleep: { $0.isAsleep }
            )

            XCTAssertEqual(indexed, legacySleepRanges(rows))
        }
    }

    func testSleepRangeBoundaryMatchesStandardReopenRule() {
        let reopen = WhoopAutomaticSleepPolicy.reopenWindow
        let rows = [
            SyntheticSleepRow(timestamp: 0, isAsleep: true),
            SyntheticSleepRow(timestamp: reopen, isAsleep: true),
            SyntheticSleepRow(timestamp: reopen + 1, isAsleep: true),
            SyntheticSleepRow(timestamp: 2 * reopen + 2, isAsleep: true),
        ]

        let ranges = WhoopBackfillPlanner.indexedSleepRanges(
            in: rows,
            timestamp: { $0.timestamp },
            isAsleep: { $0.isAsleep }
        )

        XCTAssertEqual(
            ranges,
            [
                WhoopIndexedSleepRange(sessionRange: 0..<3, asleepIndices: [0, 1, 2]),
                WhoopIndexedSleepRange(sessionRange: 3..<4, asleepIndices: [3]),
            ]
        )
    }

    func testBackfillMergesCompletedMainSleepReturningSameMorning() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let formatter = ISO8601DateFormatter()
        let first = try XCTUnwrap(formatter.date(from: "2026-09-15T05:05:00Z"))
        let last = try XCTUnwrap(formatter.date(from: "2026-09-15T10:41:59Z"))
        let resumed = try XCTUnwrap(formatter.date(from: "2026-09-15T12:23:00Z"))
        var rows: [SyntheticSleepRow] = []
        for timestamp in stride(
            from: first.timeIntervalSince1970,
            through: last.timeIntervalSince1970,
            by: 20 * 60
        ) {
            rows.append(SyntheticSleepRow(timestamp: timestamp, isAsleep: true))
        }
        rows.append(SyntheticSleepRow(timestamp: last.timeIntervalSince1970, isAsleep: true))
        rows.append(SyntheticSleepRow(timestamp: resumed.timeIntervalSince1970, isAsleep: true))

        let ranges = WhoopBackfillPlanner.indexedSleepRanges(
            in: rows,
            timeZone: timeZone,
            timestamp: { $0.timestamp },
            isAsleep: { $0.isAsleep }
        )

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].asleepIndices.count, rows.count)
    }

    func testSleepRangeIndexIncludesRowsSharingBoundaryTimestamps() {
        let rows = [
            SyntheticSleepRow(timestamp: 10, isAsleep: false),
            SyntheticSleepRow(timestamp: 10, isAsleep: true),
            SyntheticSleepRow(timestamp: 11, isAsleep: true),
            SyntheticSleepRow(timestamp: 11, isAsleep: false),
        ]

        let ranges = WhoopBackfillPlanner.indexedSleepRanges(
            in: rows,
            timestamp: { $0.timestamp },
            isAsleep: { $0.isAsleep }
        )

        XCTAssertEqual(
            ranges,
            [WhoopIndexedSleepRange(sessionRange: 0..<4, asleepIndices: [1, 2])]
        )
        XCTAssertEqual(ranges, legacySleepRanges(rows))
    }

    func testSleepRangeIndexerClassifiesEveryRowExactlyOnce() {
        let rows = (0..<100_000).map {
            SyntheticSleepRow(timestamp: Double($0 * 6), isAsleep: $0 % 4 == 0)
        }
        var classificationCount = 0
        var timestampCount = 0

        _ = WhoopBackfillPlanner.indexedSleepRanges(
            in: rows,
            timestamp: {
                timestampCount += 1
                return $0.timestamp
            },
            isAsleep: {
                classificationCount += 1
                return $0.isAsleep
            }
        )

        XCTAssertEqual(classificationCount, rows.count)
        XCTAssertEqual(timestampCount, rows.count)
    }

    func testSleepRangeIndexPerformanceAtLongHistoryScale() {
        let rows = (0..<250_000).map {
            SyntheticSleepRow(
                timestamp: Double($0 * 6),
                isAsleep: ($0 / 4_800) % 3 == 1
            )
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let ranges = WhoopBackfillPlanner.indexedSleepRanges(
                in: rows,
                timestamp: { $0.timestamp },
                isAsleep: { $0.isAsleep }
            )
            XCTAssertFalse(ranges.isEmpty)
        }
    }

    private func legacySleepRanges(
        _ rows: [SyntheticSleepRow]
    ) -> [WhoopIndexedSleepRange] {
        let asleepIndices = rows.indices.filter { rows[$0].isAsleep }
        var groups: [[Int]] = []
        for index in asleepIndices {
            if let first = groups.last?.first, let last = groups.last?.last,
                WhoopAutomaticSleepPolicy.shouldMergeAsleepRuns(
                    firstAsleepTimestamp: rows[first].timestamp,
                    lastAsleepTimestamp: rows[last].timestamp,
                    nextAsleepTimestamp: rows[index].timestamp,
                    timeZone: .autoupdatingCurrent
                )
            {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let matching = rows.indices.filter {
                rows[$0].timestamp >= rows[first].timestamp
                    && rows[$0].timestamp <= rows[last].timestamp
            }
            guard let sessionFirst = matching.first, let sessionLast = matching.last else {
                return nil
            }
            return WhoopIndexedSleepRange(
                sessionRange: sessionFirst..<(sessionLast + 1),
                asleepIndices: group
            )
        }
    }

    private func makeRecoveryRecords(count: Int) -> [DailyHealthRecord] {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        return (0..<count).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else {
                return nil
            }
            return makeRecoveryRecord(
                dateKey: DayKey.string(from: date, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt),
                index: index
            )
        }
    }

    private func makeRecoveryRecord(dateKey: String, index: Int) -> DailyHealthRecord {
        DailyHealthRecord(
            dateKey: dateKey,
            sleepScore: Double(70 + index % 29),
            sleepDurationMinutes: Double(360 + index % 180),
            hrvRMSSDMilliseconds: Double(40 + index % 60),
            restingHeartRateBPM: Double(45 + index % 25),
            sleepID: "synthetic-\(index)",
            cycleID: nil,
            source: "synthetic-backfill-parity",
            sourceArchive: nil,
            sourceUpdatedAt: "2026-01-01T00:00:00Z",
            sleepStartMinute: Double(1_200 + index % 180),
            sleepEndMinute: Double(360 + index % 120),
            sleepEfficiencyPercentage: Double(80 + index % 20)
        )
    }
}

private struct SyntheticSleepRow {
    let timestamp: TimeInterval
    let isAsleep: Bool
}

private struct DeterministicGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
