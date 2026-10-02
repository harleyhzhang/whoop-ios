import Foundation

enum WhoopLaunchOverrides {
    /// Simulator design review reads a real retained day without changing storage.
    static var previewDay: String? {
        #if DEBUG && targetEnvironment(simulator)
            guard let key = value(for: "WHOOP_PREVIEW_DAY"), DayKey(rawValue: key) != nil else { return nil }
            return key
        #else
            return nil
        #endif
    }

    static var isConnected: Bool {
        value(for: "WHOOP_MOCK_CONNECTED") == "1"
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

    static var powerPackBatteryLevel: Int? {
        guard let rawValue = value(for: "WHOOP_MOCK_POWER_PACK_BATTERY"),
            let level = Int(rawValue)
        else {
            return nil
        }
        return min(max(level, 0), 100)
    }

    private static func value(for key: String) -> String? {
        #if DEBUG
            ProcessInfo.processInfo.environment[key]
        #else
            nil
        #endif
    }
}
