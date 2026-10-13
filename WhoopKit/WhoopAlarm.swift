import Foundation

/// Daily wake time kept armed on the strap. The strap stores a single one-shot
/// alarm, so the next occurrence is re-sent on every connect. When disabled the
/// strap alarm is cleared instead, which also silences alarms left behind by
/// the official app.
struct WhoopAlarm: Codable, Equatable {
    var isEnabled: Bool
    var hour: Int
    var minute: Int

    static let `default` = WhoopAlarm(isEnabled: false, hour: 7, minute: 0)

    func nextFire(after now: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        return calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime
        )
    }

    func command(after now: Date, calendar: Calendar = .current) -> WhoopCommand {
        guard let fire = nextFire(after: now, calendar: calendar) else { return .disableAlarm }
        return .setAlarm(unix: UInt32(fire.timeIntervalSince1970))
    }
}

enum WhoopAlarmStore {
    private static let key = "WhoopCollector.alarm"

    static func load(from defaults: UserDefaults = .standard) -> WhoopAlarm {
        guard let data = defaults.data(forKey: key),
            let alarm = try? JSONDecoder().decode(WhoopAlarm.self, from: data)
        else { return .default }
        return alarm
    }

    static func save(_ alarm: WhoopAlarm, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(alarm), forKey: key)
    }
}
