import UserNotifications
import XCTest

@testable import Whoop

@MainActor
final class WhoopCollectionMonitorTests: XCTestCase {
    func testFirstStartSchedulesSystemDeadlineAndRepeatedStartDoesNotResetIt() async throws {
        let f = try fixture()
        f.monitor.start()
        await eventually { f.scheduler.requests.count == 1 }
        f.clock.date.addTimeInterval(600)
        f.monitor.start()
        await Task.yield()
        XCTAssertEqual(f.scheduler.requests.count, 1)
        XCTAssertEqual(try delay(f.scheduler.requests[0]), 3600)
        XCTAssertEqual(f.scheduler.requests[0].identifier, WhoopCollectionMonitor.identifier)
    }

    func testRestartRetainsOverdueDeadlineRatherThanHidingOutageForAnotherHour() async throws {
        let f = try fixture()
        f.defaults.set(f.clock.date.addingTimeInterval(-7200), forKey: WhoopCollectionMonitor.anchorKey)
        f.monitor.start()
        await eventually { f.scheduler.requests.count == 1 }
        XCTAssertEqual(try delay(f.scheduler.requests[0]), 1)
        XCTAssertTrue(f.scheduler.removedDelivered.isEmpty)
    }

    func testRecentDurableProgressRearmsAtMostEveryFiveMinutes() async throws {
        let f = try fixture()
        f.monitor.start()
        await eventually { f.scheduler.requests.count == 1 }
        f.clock.date.addTimeInterval(30)
        f.monitor.observePersistedSample(at: f.clock.date)
        await Task.yield()
        XCTAssertEqual(f.scheduler.requests.count, 1)
        f.clock.date.addTimeInterval(300)
        f.monitor.observePersistedSample(at: f.clock.date.addingTimeInterval(-10))
        await eventually { f.scheduler.requests.count == 2 }
        XCTAssertEqual(try delay(f.scheduler.requests[1]), 3590)
        XCTAssertEqual(f.scheduler.removedDelivered.last, [WhoopCollectionMonitor.identifier])
    }

    func testOldBackfillAndFutureClockDoNotHideStaleCollection() async throws {
        let f = try fixture()
        f.monitor.start()
        await eventually { f.scheduler.requests.count == 1 }
        let anchor = f.defaults.object(forKey: WhoopCollectionMonitor.anchorKey) as? Date
        f.clock.date.addTimeInterval(7200)
        f.monitor.observePersistedSample(at: f.clock.date.addingTimeInterval(-600))
        f.monitor.observePersistedSample(at: f.clock.date.addingTimeInterval(1))
        await Task.yield()
        XCTAssertEqual(f.scheduler.requests.count, 1)
        XCTAssertEqual(f.defaults.object(forKey: WhoopCollectionMonitor.anchorKey) as? Date, anchor)
    }

    func testFailedSchedulingRetriesWithBoundedRateOnFreshProgress() async throws {
        let f = try fixture()
        f.scheduler.fail = true
        f.monitor.start()
        await eventually { f.scheduler.attempts == 1 }
        f.scheduler.fail = false
        f.clock.date.addTimeInterval(10)
        f.monitor.observePersistedSample(at: f.clock.date)
        await Task.yield()
        XCTAssertEqual(f.scheduler.attempts, 1)
        f.clock.date.addTimeInterval(300)
        f.monitor.observePersistedSample(at: f.clock.date)
        await eventually { f.scheduler.requests.count == 1 }
        XCTAssertEqual(f.scheduler.attempts, 2)
    }

    func testReplacementAddsAreSerializedAcrossAwait() async throws {
        let f = try fixture()
        f.scheduler.hold = true
        f.monitor.start()
        await eventually { f.scheduler.attempts == 1 }
        f.clock.date.addTimeInterval(400)
        f.monitor.observePersistedSample(at: f.clock.date)
        await Task.yield()
        XCTAssertEqual(f.scheduler.attempts, 1)
        f.scheduler.hold = false
        f.scheduler.release()
        await eventually { f.scheduler.requests.count == 2 }
        XCTAssertEqual(try delay(f.scheduler.requests[1]), 3600)
        XCTAssertEqual(f.scheduler.maximumConcurrentAdds, 1)
    }

    func testFutureSavedClockIsDiscardedOnStart() async throws {
        let f = try fixture()
        f.defaults.set(f.clock.date.addingTimeInterval(86400), forKey: WhoopCollectionMonitor.anchorKey)
        f.monitor.start()
        await eventually { f.scheduler.requests.count == 1 }
        XCTAssertEqual(try delay(f.scheduler.requests[0]), 3600)
    }

    private func fixture() throws -> MonitorFixture {
        let name = "WhoopCollectionMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let scheduler = MonitorScheduler()
        let clock = MonitorClock()
        let monitor = WhoopCollectionMonitor(scheduler: scheduler, defaults: defaults, now: { clock.date })
        return MonitorFixture(monitor: monitor, scheduler: scheduler, defaults: defaults, clock: clock)
    }

    private func delay(_ request: UNNotificationRequest) throws -> TimeInterval {
        try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger).timeInterval
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Scheduled notification did not arrive")
    }
}

@MainActor
private struct MonitorFixture {
    let monitor: WhoopCollectionMonitor
    let scheduler: MonitorScheduler
    let defaults: UserDefaults
    let clock: MonitorClock
}

@MainActor
private final class MonitorClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class MonitorScheduler: WhoopNotificationScheduling {
    var fail = false
    var hold = false
    var attempts = 0
    var requests: [UNNotificationRequest] = []
    var removedDelivered: [[String]] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var concurrentAdds = 0
    var maximumConcurrentAdds = 0

    func install(delegate: UNUserNotificationCenterDelegate) {}
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removedDelivered.append(identifiers) }
    func release() {
        continuation?.resume()
        continuation = nil
    }

    func add(_ request: UNNotificationRequest) async throws {
        attempts += 1
        concurrentAdds += 1
        maximumConcurrentAdds = max(maximumConcurrentAdds, concurrentAdds)
        defer { concurrentAdds -= 1 }
        if hold { await withCheckedContinuation { continuation = $0 } }
        if fail { throw Failure.schedule }
        requests.append(request)
    }

    private enum Failure: Error { case schedule }
}
