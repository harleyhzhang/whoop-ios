import SwiftUI
import UserNotifications

@main
struct SleepApp: App {
    init() {
        WhoopNotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

@MainActor
final class WhoopNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WhoopNotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var isConfigured = false
    private var pendingIdentifiers: Set<String> = []

    private enum Key {
        static let lastMorningSleepID = "WhoopNotifications.lastMorningSleepID"
        static let lastMorningDateKey = "WhoopNotifications.lastMorningDateKey"
        static let lastBatteryLevel = "WhoopNotifications.lastBatteryLevel"
        static let sentLow20 = "WhoopNotifications.sentLow20"
        static let sentLow10 = "WhoopNotifications.sentLow10"
        static let fullChargeNotified = "WhoopNotifications.fullChargeNotified"
    }

    private override init() {
        super.init()
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        #if DEBUG
        scheduleDebugNotificationIfRequested()
        #endif
    }

    func sendMorningSummary(for record: DailyHealthRecord) {
        guard record.source.hasPrefix(WhoopStore.localSourcePrefix),
              Calendar.current.isDateInToday(record.date),
              let sleepID = record.sleepID,
              defaults.string(forKey: Key.lastMorningDateKey) != record.dateKey,
              defaults.string(forKey: Key.lastMorningSleepID) != sleepID else { return }

        let score = record.sleepScore.map { "\(Int($0.rounded()))%" } ?? "—"
        let duration = record.sleepDurationMinutes.map(Self.formatDuration) ?? "—"
        let hrv = record.hrvRMSSDMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "—"
        let rhr = record.restingHeartRateBPM.map { "\(Int($0.rounded())) BPM" } ?? "—"

        let identifier = "whoop.morning.\(record.dateKey)"
        guard !pendingIdentifiers.contains(identifier) else { return }
        deliver(
            identifier: identifier,
            title: "Sleep ready",
            body: "\(score) · \(duration) · HRV \(hrv) · RHR \(rhr)"
        ) { [weak self] succeeded in
            guard succeeded, let self else { return }
            self.defaults.set(sleepID, forKey: Key.lastMorningSleepID)
            self.defaults.set(record.dateKey, forKey: Key.lastMorningDateKey)
        }
    }

    func observeBatteryLevel(_ rawLevel: Int) {
        let level = min(max(rawLevel, 0), 100)
        let previous = defaults.object(forKey: Key.lastBatteryLevel) != nil
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
           !fullChargeNotified {
            scheduleBatteryNotification(
                identifier: "whoop.battery.charged",
                title: "WHOOP fully charged",
                body: "Battery reached 100%.",
                successKey: Key.fullChargeNotified
            )
        } else if level <= 10, !sentLow10 {
            scheduleBatteryNotification(
                identifier: "whoop.battery.low.10",
                title: "WHOOP battery at \(level)%",
                body: "Charge now to avoid missing data.",
                successKey: Key.sentLow10,
                additionalSuccessKey: Key.sentLow20
            )
        } else if level <= 20, !sentLow20 {
            scheduleBatteryNotification(
                identifier: "whoop.battery.low.20",
                title: "WHOOP battery at \(level)%",
                body: "Charge before tonight.",
                successKey: Key.sentLow20
            )
        }

        defaults.set(level, forKey: Key.lastBatteryLevel)
        defaults.set(sentLow20, forKey: Key.sentLow20)
        defaults.set(sentLow10, forKey: Key.sentLow10)
        defaults.set(fullChargeNotified, forKey: Key.fullChargeNotified)
    }

    private func scheduleBatteryNotification(
        identifier: String,
        title: String,
        body: String,
        successKey: String,
        additionalSuccessKey: String? = nil
    ) {
        guard !pendingIdentifiers.contains(identifier) else { return }
        deliver(identifier: identifier, title: title, body: body) { [weak self] succeeded in
            guard succeeded, let self else { return }
            self.defaults.set(true, forKey: successKey)
            if let additionalSuccessKey {
                self.defaults.set(true, forKey: additionalSuccessKey)
            }
        }
    }

    private func deliver(
        identifier: String,
        title: String,
        body: String,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        pendingIdentifiers.insert(identifier)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "whoop.local"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded: Bool
            do {
                try await center.add(request)
                succeeded = true
            } catch {
                succeeded = false
            }
            pendingIdentifiers.remove(identifier)
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
        default:
            break
        }
    }
    #endif
}
