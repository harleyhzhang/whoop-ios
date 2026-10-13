import XCTest

@testable import Whoop

@MainActor
final class ManualLogTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("manual-log-\(UUID().uuidString).json")
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    func testSportsKeepRunningAndWeightliftingPinnedAndSearchable() {
        XCTAssertEqual(Array(Sport.matching("").prefix(2)), [.running, .weightlifting])
        XCTAssertEqual(Sport.others.dropLast().map(\.title), Sport.others.dropLast().map(\.title).sorted())
        XCTAssertEqual(Sport.others.last, .other)
        XCTAssertFalse(Sport.others.contains(.running))
        XCTAssertEqual(Sport.matching("pickle"), [.pickleball])
        XCTAssertEqual(Sport(exportName: "Mountain Biking"), .mountainBiking)
        XCTAssertEqual(Sport(exportName: "Commuting"), .other)
        XCTAssertEqual(DashboardSheet.forCard(.strain), .activity)
        XCTAssertEqual(DashboardSheet.forCard(.sleep), .sleep)
        XCTAssertEqual(DashboardSheet.forCard(.steps), .history(.steps))
    }

    func testOnlyOneLiveEntryAndStopPersistsAcrossReload() throws {
        let url = temporaryURL()
        let start = try date("2026-03-01T10:00:00Z")
        let log = ManualLogStore(url: url, importedURL: nil)
        XCTAssertTrue(log.start(.activity(.basketball), at: start))
        XCTAssertFalse(log.start(.activity(.soccer), at: start))
        log.record(heartRate: 120)
        log.record(heartRate: 160)
        XCTAssertEqual(log.heartRate, 160)
        log.stop(at: start.addingTimeInterval(1800))
        XCTAssertNil(log.live)

        let reloaded = ManualLogStore(url: url, importedURL: nil)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.kind, .activity(.basketball))
        XCTAssertEqual(reloaded.entries.first?.duration(at: .distantFuture), 1800)
        XCTAssertEqual(reloaded.entries.first?.averageHeartRate, 140)
        XCTAssertEqual(reloaded.entries.first?.maxHeartRate, 160)
    }

    func testSleepIsNeverStartedAndDiscardRemovesTheLiveEntry() throws {
        let log = ManualLogStore(url: temporaryURL(), importedURL: nil)
        XCTAssertFalse(log.start(.sleep))
        XCTAssertFalse(log.start(.nap))
        XCTAssertTrue(log.start(.activity(.running)))
        log.stop(keep: false)
        XCTAssertNil(log.live)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testZonesFollowMaxHeartRateAndAccumulateLiveTime() throws {
        XCTAssertNil(HeartRateZones.zone(for: 90, maximum: 200))
        XCTAssertEqual(HeartRateZones.zone(for: 130, maximum: 200), 1)
        XCTAssertEqual(HeartRateZones.zone(for: 185, maximum: 200), 4)
        XCTAssertEqual(HeartRateZones.zone(for: 240, maximum: 200), 4)

        let start = try date("2026-03-01T10:00:00Z")
        let log = ManualLogStore(url: temporaryURL(), importedURL: nil, maximumHeartRate: 200)
        XCTAssertTrue(log.start(.activity(.running), at: start))
        log.record(heartRate: 185, at: start)
        log.record(heartRate: 185, at: start.addingTimeInterval(4))
        log.record(heartRate: 130, at: start.addingTimeInterval(8))
        log.record(heartRate: 130, at: start.addingTimeInterval(60))
        XCTAssertEqual(log.currentZone, 1)
        log.stop(at: start.addingTimeInterval(60))
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.zoneSeconds, [0, 9, 0, 0, 4])
        let shares = try XCTUnwrap(entry.zoneShares(at: .distantFuture))
        XCTAssertEqual(shares[4], 4.0 / 60, accuracy: 0.0001)
    }

    func testAddedEntriesAreValidatedAndFiledOnTheRightDay() throws {
        let log = ManualLogStore(url: temporaryURL(), importedURL: nil)
        let now = try date("2026-03-02T12:00:00Z")
        let bedtime = try date("2026-03-01T23:00:00Z")
        let wake = try date("2026-03-02T07:00:00Z")
        XCTAssertFalse(log.add(.sleep, start: wake, end: bedtime, now: now))
        XCTAssertFalse(log.add(.nap, start: bedtime, end: now.addingTimeInterval(60), now: now))
        XCTAssertFalse(log.add(.sleep, start: bedtime.addingTimeInterval(-86_400), end: wake, now: now))
        XCTAssertTrue(log.add(.sleep, start: bedtime, end: wake, now: now))
        XCTAssertTrue(log.add(.activity(.running), start: bedtime, end: bedtime.addingTimeInterval(1800), now: now))

        XCTAssertEqual(log.entries(on: "2026-03-02", timeZone: utc).map(\.kind), [.sleep])
        XCTAssertEqual(log.entries(on: "2026-03-01", timeZone: utc).map(\.kind), [.activity(.running)])
    }

    func testImportedExportActivitiesAppearReadOnlyOnTheirDay() throws {
        let json = """
            [{"id":"19129e14-b654-4bc6-57a2-80f8389e6912","kind":"activity","name":"Running",
              "start":"2026-10-12T09:03:37-04:00","end":"2026-10-12T09:16:31-04:00","strain":11.5,
              "averageHeartRate":176,"maxHeartRate":202,"calories":224},
             {"id":"5964d8dc-cefa-5c9e-031a-5d537fe07064","kind":"nap","name":"Nap",
              "start":"2026-10-12T14:00:00-04:00","end":"2026-10-12T14:40:00-04:00","sleepScore":null},
             {"id":"6964d8dc-cefa-5c9e-031a-5d537fe07064","kind":"activity","name":"Commuting",
              "start":"2026-10-11T09:00:00-04:00","end":"2026-10-11T09:30:00-04:00"}]
            """
        let url = temporaryURL()
        try Data(json.utf8).write(to: url)
        let log = ManualLogStore(url: nil, importedURL: url)
        let zone = TimeZone(identifier: "America/Toronto") ?? .current
        let today = log.entries(on: "2026-10-12", timeZone: zone)
        XCTAssertEqual(today.map(\.kind), [.activity(.running), .nap])
        XCTAssertEqual(today.first?.strain, 11.5)
        XCTAssertEqual(today.first?.averageHeartRate, 176)
        XCTAssertTrue(today.allSatisfy(\.isImported))
        XCTAssertEqual(log.entries(on: "2026-10-11", timeZone: zone).first?.title, "Commuting")
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.strainFloor(on: "2026-10-12", timeZone: zone), 11.5)
        XCTAssertNil(log.strainFloor(on: "2026-10-11", timeZone: zone))
    }

    func testStrainFloorFillsOnlyTheMissingDayAndNeverOverridesRecordedStrain() {
        func day(_ key: String, strain: Double?) -> HealthDay {
            HealthDay(
                day: key, sleep: nil, recovery: nil, strain: strain, steps: nil, duration: nil, hrv: nil,
                rhr: nil, localStrain: nil)
        }
        var projection = DashboardCardProjection(
            snapshot: .empty, published: PublishedDashboardDay(healthRecords: [], stepRecords: [], recoveryRecords: []),
            referenceDate: .now)
        projection.days = [day("2026-10-11", strain: nil), day("2026-10-12", strain: nil)]
        projection.selected = day("2026-10-12", strain: nil)
        let filled = projection.withStrainFloor(11.5, on: "2026-10-12")
        XCTAssertEqual(filled.selected?.strain, 11.5)
        XCTAssertEqual(filled.days.map(\.strain), [nil, 11.5])

        projection.selected = day("2026-10-12", strain: 14.2)
        XCTAssertEqual(projection.withStrainFloor(11.5, on: "2026-10-12").selected?.strain, 14.2)
        XCTAssertEqual(projection.withStrainFloor(nil, on: "2026-10-12").days.map(\.strain), [nil, nil])
    }
}
