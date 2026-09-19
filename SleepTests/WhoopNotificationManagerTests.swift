import UserNotifications
import XCTest

@testable import Sleep

@MainActor
final class WhoopNotificationManagerTests: XCTestCase {
    func testConfigureRequestsAuthorizationOnlyOnceWhenUndetermined() async throws {
        let fixture = try makeFixture()
        fixture.scheduler.authorizationStatusValue = .notDetermined

        fixture.manager.configure()
        fixture.manager.configure()

        await eventually { fixture.scheduler.authorizationRequestCount == 1 }
        XCTAssertEqual(fixture.scheduler.installCount, 1)
    }

    func testMorningSummaryIsLocalCurrentDayDeduplicatedAndReplacedAfterCorrection() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeFixture(now: now)
        let record = DailyHealthRecord(
            dateKey: Self.dateKey(for: now),
            sleepScore: 91,
            sleepDurationMinutes: 487,
            hrvRMSSDMilliseconds: 67,
            restingHeartRateBPM: 51,
            sleepID: "synthetic-current-night",
            cycleID: nil,
            source: "\(WhoopStore.localSourcePrefix)-test",
            sourceArchive: nil,
            sourceUpdatedAt: ISO8601DateFormatter().string(from: now)
        )

        fixture.manager.sendMorningSummary(for: record)
        await eventually { fixture.scheduler.requests.count == 1 }
        fixture.manager.sendMorningSummary(for: record)
        let correctedRecord = DailyHealthRecord(
            dateKey: record.dateKey,
            sleepScore: 93,
            sleepDurationMinutes: 505,
            hrvRMSSDMilliseconds: 70,
            restingHeartRateBPM: 50,
            sleepID: "synthetic-corrected-night",
            cycleID: nil,
            source: "\(WhoopStore.localSourcePrefix)-test",
            sourceArchive: nil,
            sourceUpdatedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        )
        fixture.manager.sendMorningSummary(for: correctedRecord)
        await eventually { fixture.scheduler.requests.count == 2 }
        fixture.manager.sendMorningSummary(for: correctedRecord)
        await Task.yield()

        let request = try XCTUnwrap(fixture.scheduler.requests.last)
        XCTAssertEqual(request.identifier, "whoop.morning.\(record.dateKey)")
        XCTAssertEqual(request.content.title, "Sleep ready")
        XCTAssertEqual(request.content.body, "93% · 8h 25m · HRV 70 ms · RHR 50 BPM")
        XCTAssertEqual(fixture.scheduler.requests.count, 2)
        XCTAssertTrue(fixture.scheduler.removedPending.isEmpty)
        XCTAssertEqual(fixture.scheduler.removedDelivered, [[request.identifier]])
        XCTAssertEqual(
            fixture.defaults.string(forKey: WhoopNotificationManager.Key.lastMorningSleepID),
            correctedRecord.sleepID
        )
        XCTAssertEqual(
            fixture.defaults.string(forKey: WhoopNotificationManager.Key.lastMorningSummaryBody),
            request.content.body
        )
    }

    func testFailedMorningCorrectionKeepsPreviousSummaryState() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeFixture(now: now)
        let original = record(
            date: now,
            source: "\(WhoopStore.localSourcePrefix)-test",
            sleepID: "synthetic-original-night"
        )
        fixture.manager.sendMorningSummary(for: original)
        await eventually { fixture.scheduler.requests.count == 1 }

        fixture.scheduler.addError = SyntheticError.deliveryFailed
        let corrected = record(
            date: now,
            source: "\(WhoopStore.localSourcePrefix)-test",
            sleepID: "synthetic-corrected-night"
        )
        fixture.manager.sendMorningSummary(for: corrected)
        await eventually { fixture.scheduler.addAttemptCount == 2 }

        XCTAssertTrue(fixture.scheduler.removedDelivered.isEmpty)
        XCTAssertEqual(
            fixture.defaults.string(forKey: WhoopNotificationManager.Key.lastMorningSleepID),
            original.sleepID
        )
    }

    func testMorningSummaryRejectsOfficialAndOldRecords() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeFixture(now: now)
        let oldDate = now.addingTimeInterval(-86_400)

        fixture.manager.sendMorningSummary(for: record(date: now, source: "whoop_private_ios_api"))
        fixture.manager.sendMorningSummary(
            for: record(date: oldDate, source: "\(WhoopStore.localSourcePrefix)-test")
        )
        await Task.yield()

        XCTAssertTrue(fixture.scheduler.requests.isEmpty)
    }

    func testBatteryNotificationsRespectThresholdsHysteresisAndFullCharge() async throws {
        let fixture = try makeFixture()

        fixture.manager.observeBattery(.init(level: 20, status: .notCharging))
        await eventually { fixture.scheduler.requests.count == 1 }
        fixture.manager.observeBattery(.init(level: 19, status: .notCharging))
        await Task.yield()
        XCTAssertEqual(fixture.scheduler.requests.count, 1)

        fixture.manager.observeBattery(.init(level: 10, status: .notCharging))
        await eventually { fixture.scheduler.requests.count == 2 }
        fixture.manager.observeBattery(.init(level: 25, status: .notCharging))
        fixture.manager.observeBattery(.init(level: 20, status: .notCharging))
        await eventually { fixture.scheduler.requests.count == 3 }

        fixture.manager.observeBattery(.init(level: 99, status: .charging))
        fixture.manager.observeBattery(.init(level: 100, status: .charging))
        await eventually { fixture.scheduler.requests.count == 4 }

        XCTAssertEqual(
            fixture.scheduler.requests.map(\.identifier),
            [
                "whoop.battery.low.20",
                "whoop.battery.low.10",
                "whoop.battery.low.20",
                "whoop.battery.charged",
            ]
        )
    }

    func testLowBatteryNotificationsWaitUntilChargingStops() async throws {
        let fixture = try makeFixture()

        fixture.manager.observeBattery(.init(level: 20, status: .charging))
        fixture.manager.observeBattery(.init(level: 10, status: .charging))
        await Task.yield()
        XCTAssertTrue(fixture.scheduler.requests.isEmpty)

        fixture.manager.observeBattery(.init(level: 10, status: .notCharging))
        await eventually { fixture.scheduler.requests.count == 1 }

        XCTAssertEqual(fixture.scheduler.requests.first?.identifier, "whoop.battery.low.10")
        XCTAssertEqual(
            fixture.scheduler.requests.first?.content.body,
            "Charge now to avoid missing data."
        )
    }

    func testFailedNotificationCanRetryAndDoesNotPersistDeduplication() async throws {
        let fixture = try makeFixture()
        fixture.scheduler.addError = SyntheticError.deliveryFailed

        fixture.manager.observeBattery(.init(level: 20, status: .notCharging))
        await eventually { fixture.scheduler.addAttemptCount == 1 }
        fixture.scheduler.addError = nil
        fixture.manager.observeBattery(.init(level: 19, status: .notCharging))
        await eventually { fixture.scheduler.requests.count == 1 }

        XCTAssertEqual(fixture.scheduler.addAttemptCount, 2)
        XCTAssertEqual(fixture.scheduler.requests.first?.identifier, "whoop.battery.low.20")
    }

    func testWristOffSchedulesOnceAndWristOnCancelsBothForms() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try makeFixture(now: now)

        fixture.manager.observeWristState(isWorn: false, observedAt: now)
        await eventually { fixture.scheduler.requests.count == 1 }
        fixture.manager.observeWristState(isWorn: false, observedAt: now.addingTimeInterval(60))
        await Task.yield()
        XCTAssertEqual(fixture.scheduler.requests.count, 1)

        let request = try XCTUnwrap(fixture.scheduler.requests.first)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 30 * 60, accuracy: 0.01)

        fixture.manager.observeWristState(isWorn: true, observedAt: now.addingTimeInterval(120))
        XCTAssertEqual(fixture.scheduler.removedPending, [["whoop.not-worn.30-minutes"]])
        XCTAssertEqual(fixture.scheduler.removedDelivered, [["whoop.not-worn.30-minutes"]])
        XCTAssertNil(fixture.defaults.object(forKey: WhoopNotificationManager.Key.notWornSince))
    }

    private func makeFixture(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> Fixture {
        let suiteName = "WhoopNotificationManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let scheduler = FakeNotificationScheduler()
        let manager = WhoopNotificationManager(
            scheduler: scheduler,
            defaults: defaults,
            now: { now }
        )
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return Fixture(manager: manager, scheduler: scheduler, defaults: defaults)
    }

    private func record(date: Date, source: String, sleepID: String = UUID().uuidString)
        -> DailyHealthRecord
    {
        DailyHealthRecord(
            dateKey: Self.dateKey(for: date),
            sleepScore: 80,
            sleepDurationMinutes: 450,
            hrvRMSSDMilliseconds: 60,
            restingHeartRateBPM: 55,
            sleepID: sleepID,
            cycleID: nil,
            source: source,
            sourceArchive: nil,
            sourceUpdatedAt: ISO8601DateFormatter().string(from: date)
        )
    }

    private static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

@MainActor
private struct Fixture {
    let manager: WhoopNotificationManager
    let scheduler: FakeNotificationScheduler
    let defaults: UserDefaults
}

@MainActor
private final class FakeNotificationScheduler: WhoopNotificationScheduling {
    var authorizationStatusValue: UNAuthorizationStatus = .authorized
    var addError: Error?
    private(set) var installCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var addAttemptCount = 0
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removedPending: [[String]] = []
    private(set) var removedDelivered: [[String]] = []

    func install(delegate: UNUserNotificationCenterDelegate) {
        installCount += 1
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusValue
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequestCount += 1
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        addAttemptCount += 1
        if let addError { throw addError }
        requests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(identifiers)
    }
}

private enum SyntheticError: Error {
    case deliveryFailed
}
