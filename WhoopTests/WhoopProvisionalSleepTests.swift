import SQLite3
import XCTest

@testable import Whoop

final class WhoopProvisionalSleepPolicyTests: XCTestCase {
    private let toronto = TimeZone(identifier: "America/Toronto") ?? .gmt

    private func instant(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) throws -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = toronto
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
        return date.timeIntervalSince1970
    }

    private func key(_ first: TimeInterval, _ last: TimeInterval) -> String {
        WhoopProvisionalSleepPolicy.projectedDateKey(firstAsleep: first, lastAsleep: last, timeZone: toronto)
    }

    func testProjectedDayNamesTheMorningTheNightWillEndOn() throws {
        XCTAssertEqual(key(try instant(17, 23, 30), try instant(17, 23, 40)), "2026-10-18", "Before midnight")
        XCTAssertEqual(key(try instant(18, 2), try instant(18, 2, 10)), "2026-10-18", "After midnight")
        XCTAssertEqual(key(try instant(17, 18, 30), try instant(17, 18, 40)), "2026-10-18", "Early evening")
        XCTAssertEqual(key(try instant(17, 15), try instant(17, 15, 40)), "2026-10-17", "Afternoon nap")
        XCTAssertEqual(key(try instant(17, 15), try instant(18, 1)), "2026-10-18", "Long sleep past midnight")
        XCTAssertEqual(
            key(try instant(31, 23), try instant(31, 23, 5)), "2026-11-01",
            "Six hours spans the fall-back transition")
    }

    func testProjectedDayAgreesWithPublicationOnceTheNightEnds() throws {
        // Publication keys a night by its last asleep sample's local day.
        for (onset, wake) in [(try instant(17, 23), try instant(18, 7)), (try instant(18, 2), try instant(18, 10))] {
            XCTAssertEqual(
                key(onset, wake),
                DayKey.string(from: Date(timeIntervalSince1970: wake), timeZone: toronto))
        }
    }

    func testRunningNightShowsUnlessADifferentSleepOwnsTheDay() throws {
        let night = WhoopProvisionalSleepCandidate(
            firstAsleep: try instant(18, 2), lastAsleep: try instant(18, 4), meetsEvidenceGates: false)
        func show(_ published: String?) -> Bool {
            WhoopProvisionalSleepPolicy.shouldShow(
                night, isSleeping: true, now: night.lastAsleep, publishedSleepID: published, timeZone: toronto)
        }
        XCTAssertTrue(show(nil))
        XCTAssertTrue(show("\(night.sessionPrefix)\(Int(night.lastAsleep) - 3_600)"), "Reopened night grows")
        XCTAssertFalse(show(night.sleepID), "Already published exactly")
        XCTAssertFalse(show("local-\(Int(night.firstAsleep) - 86_400)-1"), "Nap after a banked night")
        XCTAssertFalse(show(""), "Archived WHOOP day")
    }

    func testAwakeNightStaysWhileItCanContinueOrUntilPublished() throws {
        let short = WhoopProvisionalSleepCandidate(
            firstAsleep: try instant(18, 2), lastAsleep: try instant(18, 4), meetsEvidenceGates: false)
        func show(_ candidate: WhoopProvisionalSleepCandidate, minutesAwake: Double) -> Bool {
            WhoopProvisionalSleepPolicy.shouldShow(
                candidate, isSleeping: false, now: candidate.lastAsleep + minutesAwake * 60,
                publishedSleepID: nil, timeZone: toronto)
        }
        XCTAssertTrue(show(short, minutesAwake: 90))
        XCTAssertFalse(show(short, minutesAwake: 91), "A short sleep falls back after the reopen window")

        let night = WhoopProvisionalSleepCandidate(
            firstAsleep: try instant(18, 1), lastAsleep: try instant(18, 9), meetsEvidenceGates: true)
        XCTAssertTrue(show(night, minutesAwake: 8 * 60), "A banked-quality night waits for publication")
    }

    func testOverlayReplacesOnlyTheProvisionalDay() {
        let history = DashboardHistorySnapshot(
            healthRecords: [Self.health("2026-10-16", 80), Self.health("2026-10-17", 85)],
            stepRecords: [Self.steps("2026-10-16", 9_000), Self.steps("2026-10-17", 7_000)],
            recoveryRecords: [DailyRecoveryRecord(dateKey: "2026-10-17", score: 60, source: "stored")]
        )
        let night = WhoopProvisionalDay(
            health: Self.health("2026-10-18", 40), steps: Self.steps("2026-10-18", 0), recovery: nil)

        let overlaid = history.overlaying(night)

        XCTAssertEqual(overlaid.healthRecords.map(\.dateKey), ["2026-10-16", "2026-10-17", "2026-10-18"])
        XCTAssertEqual(overlaid.stepRecords.map(\.stepCount), [9_000, 7_000, 0])
        XCTAssertEqual(overlaid.recoveryRecords.map(\.dateKey), ["2026-10-17"])
        XCTAssertEqual(history.overlaying(nil).healthRecords, history.healthRecords)

        let reopened = WhoopProvisionalDay(
            health: Self.health("2026-10-17", 88), steps: nil, recovery: nil)
        let replaced = history.overlaying(reopened)
        XCTAssertEqual(replaced.healthRecords.map(\.sleepScore), [80, 88])
        XCTAssertEqual(replaced.recoveryRecords.count, 0, "A reopened night's stale Recovery is not shown")
    }

    func testRunningNightReplacesSleepDashesWithTheFamiliesItHas() {
        let night = WhoopProvisionalDay(
            health: Self.health("2026-10-18", 41), steps: Self.steps("2026-10-18", 0), recovery: nil)
        let history = DashboardHistorySnapshot(
            healthRecords: [Self.health("2026-10-17", 85)], stepRecords: [Self.steps("2026-10-17", 7_000)],
            recoveryRecords: [DailyRecoveryRecord(dateKey: "2026-10-17", score: 60, source: "stored")])

        let day = DashboardCurrentDayPolicy.displayedDay(
            snapshot: history, provisional: night, metricsArePending: true)

        XCTAssertEqual(day.health?.sleepScore, 41)
        XCTAssertEqual(day.steps?.stepCount, 0)
        XCTAssertNil(day.recovery)
        XCTAssertEqual(day.date, night.health.date)
        XCTAssertNil(
            DashboardCurrentDayPolicy.displayedDay(snapshot: history, metricsArePending: true).health,
            "Without a scored night, detected sleep still dashes the previous day")
    }

    static func health(_ key: String, _ score: Double) -> DailyHealthRecord {
        DailyHealthRecord(
            dateKey: key, sleepScore: score, sleepDurationMinutes: 400, hrvRMSSDMilliseconds: 60,
            restingHeartRateBPM: 50, sleepID: "synthetic-\(key)", cycleID: nil, source: "synthetic",
            sourceArchive: nil, sourceUpdatedAt: "\(key)T12:00:00Z")
    }

    static func steps(_ key: String, _ count: Int) -> DailyStepRecord {
        DailyStepRecord(
            dateKey: key, stepCount: count, sampleCount: 2, spanSeconds: 2, coverageFraction: 1, gapSeconds: 0,
            counterWrapCount: 0, rejectedDeltaCount: 0, firstSampleAt: nil, lastSampleAt: nil,
            source: "synthetic", algorithmVersion: WhoopStepDaySummary.algorithmVersion)
    }
}

@MainActor
final class WhoopProvisionalSleepModelTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "provisional-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private let night = WhoopProvisionalDay(
        health: WhoopProvisionalSleepPolicyTests.health("2026-10-18", 52),
        steps: WhoopProvisionalSleepPolicyTests.steps("2026-10-18", 0), recovery: nil)

    func testOnlyForegroundAnalysisReplacesTheNight() throws {
        let model = WhoopProvisionalSleepModel(defaults: try defaults())
        model.apply(
            WhoopSleepSnapshot(
                isSleeping: true, sampleAt: nil, finalizedRecord: nil, provisional: night, evaluatedProvisional: true))
        XCTAssertEqual(model.day, night)

        model.apply(WhoopSleepSnapshot(isSleeping: true, sampleAt: nil, finalizedRecord: nil))
        XCTAssertEqual(model.day, night, "Background analysis must not blank the dashboard")

        model.apply(
            WhoopSleepSnapshot(isSleeping: false, sampleAt: nil, finalizedRecord: nil, evaluatedProvisional: true))
        XCTAssertNil(model.day)
    }

    func testPublicationDropsTheNightEvenWhenAnalyzedInBackground() throws {
        let model = WhoopProvisionalSleepModel(defaults: try defaults())
        model.apply(
            WhoopSleepSnapshot(
                isSleeping: true, sampleAt: nil, finalizedRecord: nil, provisional: night, evaluatedProvisional: true))
        model.apply(WhoopSleepSnapshot(isSleeping: false, sampleAt: nil, finalizedRecord: night.health))
        XCTAssertNil(model.day)
    }

    func testColdStartRestoresOnlyARecentNight() throws {
        let store = try defaults()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = WhoopProvisionalSleepModel(defaults: store, now: { clock })
        writer.apply(
            WhoopSleepSnapshot(
                isSleeping: true, sampleAt: nil, finalizedRecord: nil, provisional: night, evaluatedProvisional: true))

        clock = clock.addingTimeInterval(WhoopProvisionalSleepModel.maximumCachedAge - 60)
        XCTAssertEqual(WhoopProvisionalSleepModel(defaults: store, now: { clock }).day, night)
        clock = clock.addingTimeInterval(120)
        XCTAssertNil(WhoopProvisionalSleepModel(defaults: store, now: { clock }).day)

        writer.apply(
            WhoopSleepSnapshot(isSleeping: false, sampleAt: nil, finalizedRecord: nil, evaluatedProvisional: true))
        XCTAssertNil(store.data(forKey: WhoopProvisionalSleepModel.cacheKey), "Clearing also clears the cache")
    }
}
