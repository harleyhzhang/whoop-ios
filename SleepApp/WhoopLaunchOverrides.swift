import Foundation

enum WhoopLaunchOverrides {
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
