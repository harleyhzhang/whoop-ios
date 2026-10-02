import SwiftUI
import UserNotifications

@MainActor
protocol WhoopNotificationScheduling: AnyObject {
    func install(delegate: UNUserNotificationCenterDelegate)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
final class SystemWhoopNotificationScheduler: WhoopNotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func install(delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

@main
struct WhoopApp: App {
    @State private var whoopCollector: WhoopCollector
    @State private var powerPackMonitor: WhoopPowerPackMonitor
    private let replicaCoordinator: WhoopReplicaCoordinator

    init() {
        WhoopReplicaRecovery.applyPending()
        let replicaCoordinator = WhoopReplicaCoordinator()
        self.replicaCoordinator = replicaCoordinator
        _whoopCollector = State(
            initialValue: WhoopCollector(replicaScheduler: replicaCoordinator)
        )
        _powerPackMonitor = State(initialValue: WhoopPowerPackMonitor())
        WhoopNotificationManager.shared.configure()
        WhoopRuntimeDiagnostics.shared.start()
        WhoopDeploymentHealthReporter.start()
        replicaCoordinator.requestSync(reason: .launch)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                whoopCollector: whoopCollector,
                powerPackMonitor: powerPackMonitor,
                replicaCoordinator: replicaCoordinator
            )
        }
    }
}

@MainActor
final class WhoopNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WhoopNotificationManager(
        scheduler: SystemWhoopNotificationScheduler(),
        defaults: .standard
    )

    private let scheduler: WhoopNotificationScheduling
    private let defaults: UserDefaults
    private let now: () -> Date
    private var isConfigured = false
    private var pendingIdentifiers: Set<String> = []
    private var wristStateGeneration = 0

    private static let notWornIdentifier = "whoop.not-worn.30-minutes"
    private static let notWornDelay: TimeInterval = 30 * 60

    enum Key {
        static let lastMorningSleepID = "WhoopNotifications.lastMorningSleepID"
        static let lastMorningDateKey = "WhoopNotifications.lastMorningDateKey"
        static let lastMorningSummaryBody = "WhoopNotifications.lastMorningSummaryBody"
        static let lastBatteryLevel = "WhoopNotifications.lastBatteryLevel"
        static let sentLow20 = "WhoopNotifications.sentLow20"
        static let sentLow10 = "WhoopNotifications.sentLow10"
        static let fullChargeNotified = "WhoopNotifications.fullChargeNotified"
        static let notWornSince = "WhoopNotifications.notWornSince"
        static let notWornReminderScheduled = "WhoopNotifications.notWornReminderScheduled"
    }

    init(
        scheduler: WhoopNotificationScheduling,
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
        self.now = now
        super.init()
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        scheduler.install(delegate: self)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await scheduler.authorizationStatus() == .notDetermined else { return }
            _ = try? await scheduler.requestAuthorization(options: [.alert, .sound])
        }

        #if DEBUG
            scheduleDebugNotificationIfRequested()
        #endif
    }

    func sendMorningSummary(for record: DailyHealthRecord) {
        guard record.source.hasPrefix(WhoopStore.localSourcePrefix),
            Calendar.current.isDate(record.date, inSameDayAs: now()),
            let sleepID = record.sleepID
        else { return }

        let score = record.sleepScore.map { "\(Int($0.rounded()))%" } ?? "—"
        let duration = record.sleepDurationMinutes.map(Self.formatDuration) ?? "—"
        let hrv = record.hrvRMSSDMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "—"
        let rhr = record.restingHeartRateBPM.map { "\(Int($0.rounded())) BPM" } ?? "—"
        let body = "\(score) · \(duration) · HRV \(hrv) · RHR \(rhr)"

        let previousDateKey = defaults.string(forKey: Key.lastMorningDateKey)
        let previousSleepID = defaults.string(forKey: Key.lastMorningSleepID)
        let previousBody = defaults.string(forKey: Key.lastMorningSummaryBody)
        let isSameSummary =
            previousDateKey == record.dateKey
            && previousSleepID == sleepID
            && (previousBody == nil || previousBody == body)
        guard !isSameSummary else { return }

        let identifier = "whoop.morning.\(record.dateKey)"
        guard !pendingIdentifiers.contains(identifier) else { return }
        let replacesExistingSummary = previousDateKey == record.dateKey
        deliver(
            identifier: identifier,
            title: "Sleep ready",
            body: body,
            removeDeliveredOnSuccess: replacesExistingSummary
        ) { [weak self] succeeded in
            guard succeeded, let self else { return }
            self.defaults.set(sleepID, forKey: Key.lastMorningSleepID)
            self.defaults.set(record.dateKey, forKey: Key.lastMorningDateKey)
            self.defaults.set(body, forKey: Key.lastMorningSummaryBody)
        }
    }

    func observeBattery(_ observation: BatteryObservation) {
        guard let level = observation.level else { return }
        let previous =
            defaults.object(forKey: Key.lastBatteryLevel) != nil
            ? defaults.integer(forKey: Key.lastBatteryLevel)
            : nil
        var sentLow20 = defaults.bool(forKey: Key.sentLow20)
        var sentLow10 = defaults.bool(forKey: Key.sentLow10)
        var fullChargeNotified = defaults.bool(forKey: Key.fullChargeNotified)

        // Hysteresis prevents 20/21 or 10/11 sensor jitter from starting a new
        // notification cycle before the strap has meaningfully recharged.
        if level >= 25 {
            sentLow20 = false
            sentLow10 = false
        } else if level >= 15 {
            sentLow10 = false
        }
        if level < 95 {
            fullChargeNotified = false
        }

        if level == 100,
            let previous,
            previous < 100,
            !fullChargeNotified
        {
            scheduleBatteryNotification(
                identifier: "whoop.battery.charged",
                title: "WHOOP fully charged",
                body: "Battery reached 100%.",
                successPreference: Key.fullChargeNotified
            )
        } else if level <= 10, observation.status == .notCharging, !sentLow10 {
            scheduleBatteryNotification(
                identifier: "whoop.battery.low.10",
                title: "WHOOP battery at \(level)%",
                body: "Charge now to avoid missing data.",
                successPreference: Key.sentLow10,
                additionalSuccessPreference: Key.sentLow20
            )
        } else if level <= 20, observation.status == .notCharging, !sentLow20 {
            scheduleBatteryNotification(
                identifier: "whoop.battery.low.20",
                title: "WHOOP battery at \(level)%",
                body: "Charge before tonight.",
                successPreference: Key.sentLow20
            )
        }

        defaults.set(level, forKey: Key.lastBatteryLevel)
        defaults.set(sentLow20, forKey: Key.sentLow20)
        defaults.set(sentLow10, forKey: Key.sentLow10)
        defaults.set(fullChargeNotified, forKey: Key.fullChargeNotified)
    }

    func observeWristState(isWorn: Bool, observedAt: Date = .now) {
        wristStateGeneration &+= 1
        let generation = wristStateGeneration

        if isWorn {
            defaults.removeObject(forKey: Key.notWornSince)
            defaults.set(false, forKey: Key.notWornReminderScheduled)
            scheduler.removePendingNotificationRequests(withIdentifiers: [Self.notWornIdentifier])
            scheduler.removeDeliveredNotifications(withIdentifiers: [Self.notWornIdentifier])
            return
        }

        guard !defaults.bool(forKey: Key.notWornReminderScheduled),
            !pendingIdentifiers.contains(Self.notWornIdentifier)
        else { return }

        let startedAt = defaults.object(forKey: Key.notWornSince) as? Date ?? observedAt
        defaults.set(startedAt, forKey: Key.notWornSince)
        let elapsed = max(0, now().timeIntervalSince(startedAt))
        let remainingDelay = max(1, Self.notWornDelay - elapsed)

        deliver(
            identifier: Self.notWornIdentifier,
            title: "Your WHOOP is off your wrist",
            body: "It’s been off for 30 minutes. Put it back on to keep collecting data.",
            after: remainingDelay
        ) { [weak self] succeeded in
            guard let self else { return }
            guard self.wristStateGeneration == generation else {
                self.scheduler.removePendingNotificationRequests(
                    withIdentifiers: [Self.notWornIdentifier]
                )
                return
            }
            if succeeded {
                self.defaults.set(true, forKey: Key.notWornReminderScheduled)
            }
        }
    }

    private func scheduleBatteryNotification(
        identifier: String,
        title: String,
        body: String,
        successPreference: String,
        additionalSuccessPreference: String? = nil
    ) {
        guard !pendingIdentifiers.contains(identifier) else { return }
        deliver(identifier: identifier, title: title, body: body) { [weak self] succeeded in
            guard succeeded, let self else { return }
            self.defaults.set(true, forKey: successPreference)
            if let additionalSuccessPreference {
                self.defaults.set(true, forKey: additionalSuccessPreference)
            }
        }
    }

    private func deliver(
        identifier: String,
        title: String,
        body: String,
        after delay: TimeInterval = 1,
        removeDeliveredOnSuccess: Bool = false,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        pendingIdentifiers.insert(identifier)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "whoop.local"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded: Bool
            do {
                try await scheduler.add(request)
                succeeded = true
            } catch {
                succeeded = false
            }
            pendingIdentifiers.remove(identifier)
            if succeeded, removeDeliveredOnSuccess {
                scheduler.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            completion(succeeded)
        }
    }

    private static func formatDuration(_ minutes: Double) -> String {
        let roundedMinutes = max(0, Int(minutes.rounded()))
        return "\(roundedMinutes / 60)h \(String(format: "%02d", roundedMinutes % 60))m"
    }

    private nonisolated func eventIdentifier(_ prefix: String) -> String {
        "\(prefix).\(UUID().uuidString)"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    #if DEBUG
        private func scheduleDebugNotificationIfRequested() {
            guard let kind = ProcessInfo.processInfo.environment["WHOOP_DEBUG_NOTIFICATION"] else { return }
            switch kind {
            case "morning":
                deliver(
                    identifier: eventIdentifier("whoop.debug.morning"),
                    title: "Sleep ready",
                    body: "86% · 7h 42m · HRV 57 ms · RHR 54 BPM"
                )
            case "low20":
                deliver(
                    identifier: eventIdentifier("whoop.debug.low20"),
                    title: "WHOOP battery at 20%",
                    body: "Charge before tonight."
                )
            case "low10":
                deliver(
                    identifier: eventIdentifier("whoop.debug.low10"),
                    title: "WHOOP battery at 10%",
                    body: "Charge now to avoid missing data."
                )
            case "charged":
                deliver(
                    identifier: eventIdentifier("whoop.debug.charged"),
                    title: "WHOOP fully charged",
                    body: "Battery reached 100%."
                )
            case "notWorn":
                deliver(
                    identifier: eventIdentifier("whoop.debug.not-worn"),
                    title: "Your WHOOP is off your wrist",
                    body: "It’s been off for 30 minutes. Put it back on to keep collecting data."
                )
            default:
                break
            }
        }
    #endif
}
