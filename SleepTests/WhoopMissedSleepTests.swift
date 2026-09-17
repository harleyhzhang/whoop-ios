import XCTest

@testable import Sleep

extension WhoopSleepStateTests {
    func testStepMigrationCapsOnlyTheLatestOpenDay() throws {
        let firstWake = Date(timeIntervalSince1970: 1_800_000_000)
        let nextWake = firstWake.addingTimeInterval(30 * 60 * 60)
        let firstKey = try XCTUnwrap(DayKey(rawValue: "2027-01-15"))
        let nextKey = try XCTUnwrap(DayKey(rawValue: "2027-01-16"))

        XCTAssertEqual(
            WhoopStepDayMigration.intervals(for: [
                WhoopWakeBoundary(dateKey: firstKey, wokeAt: firstWake),
                WhoopWakeBoundary(dateKey: nextKey, wokeAt: nextWake),
            ]),
            [
                WhoopStepDayInterval(
                    dateKey: firstKey.rawValue,
                    lowerBound: firstWake.timeIntervalSince1970,
                    upperBound: nextWake.timeIntervalSince1970
                ),
                WhoopStepDayInterval(
                    dateKey: nextKey.rawValue,
                    lowerBound: nextWake.timeIntervalSince1970,
                    upperBound: nextWake.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970
                ),
            ]
        )
    }

    func testPhysiologicalDayFallsBackAfterTwentyFourHoursWithoutSleep() throws {
        let wake = Date(timeIntervalSince1970: 1_800_000_000)
        let wakeKey = try XCTUnwrap(DayKey(rawValue: "2027-01-15"))
        let nextCivilKey = try XCTUnwrap(DayKey(rawValue: "2027-01-16"))
        let boundaries = [WhoopWakeBoundary(dateKey: wakeKey, wokeAt: wake)]

        XCTAssertEqual(
            WhoopPhysiologicalDay.dateKey(
                for: wake.addingTimeInterval(24 * 60 * 60 - 1),
                publishedWakes: boundaries,
                civilFallback: nextCivilKey
            ),
            wakeKey
        )
        XCTAssertEqual(
            WhoopPhysiologicalDay.dateKey(
                for: wake.addingTimeInterval(24 * 60 * 60),
                publishedWakes: boundaries,
                civilFallback: nextCivilKey
            ),
            nextCivilKey
        )
    }

    func testKnownLaterWakeRepairsTemporaryMissedSleepFallback() throws {
        let firstWake = Date(timeIntervalSince1970: 1_800_000_000)
        let nextWake = firstWake.addingTimeInterval(30 * 60 * 60)
        let firstKey = try XCTUnwrap(DayKey(rawValue: "2027-01-15"))
        let nextKey = try XCTUnwrap(DayKey(rawValue: "2027-01-16"))
        let boundaries = [
            WhoopWakeBoundary(dateKey: firstKey, wokeAt: firstWake),
            WhoopWakeBoundary(dateKey: nextKey, wokeAt: nextWake),
        ]

        XCTAssertEqual(
            WhoopPhysiologicalDay.dateKey(
                for: firstWake.addingTimeInterval(27 * 60 * 60),
                publishedWakes: boundaries,
                civilFallback: nextKey
            ),
            firstKey
        )
        XCTAssertEqual(
            WhoopStepDayMigration.fallbackRepair(
                before: nextWake,
                boundaries: boundaries
            ),
            WhoopStepFallbackRepair(
                dateKey: firstKey.rawValue,
                lowerBound: firstWake.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970
            )
        )
    }
}
