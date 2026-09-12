import Foundation

enum WhoopLaunchOverrides {
    static var isConnected: Bool {
        value(for: "WHOOP_MOCK_CONNECTED") == "1"
    }

    static var isSleeping: Bool {
        value(for: "WHOOP_MOCK_SLEEPING") == "1"
    }

    static var isCharging: Bool {
        value(for: "WHOOP_MOCK_CHARGING") == "1"
    }

    static var batteryLevel: Int? {
        guard let rawValue = value(for: "WHOOP_MOCK_BATTERY"), let level = Int(rawValue) else {
            return nil
        }
        return min(max(level, 0), 100)
    }

    static var pendingSleepMinutes: Double? {
        value(for: "WHOOP_MOCK_PENDING_SLEEP_MINUTES").flatMap(Double.init)
    }

    private static func value(for key: String) -> String? {
        #if DEBUG
            ProcessInfo.processInfo.environment[key]
        #else
            nil
        #endif
    }
}
