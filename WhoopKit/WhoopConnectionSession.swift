import Foundation

enum WhoopCollectorPreferences {
    /// Persisted keys outlive type renames. Preserve existing values and only
    /// carry device-specific state forward for the same saved peripheral.
    static func migrateLegacyKeys(in defaults: UserDefaults) {
        let oldPrefix = "WhoopHandshakeProbe."
        let newPrefix = "WhoopCollector."
        let identityKey = "knownPeripheralIdentifier"
        guard let legacyID = defaults.string(forKey: oldPrefix + identityKey),
            let legacyUUID = UUID(uuidString: legacyID)
        else { return }
        if let currentID = defaults.string(forKey: newPrefix + identityKey),
            UUID(uuidString: currentID) != legacyUUID
        {
            return
        }
        let suffixes = [
            identityKey, "confirmedEncryptedBond", "cachedHeartRateBPM",
            "cachedHeartRateDate", "cachedBatteryLevel", "cachedBatteryLevelDate",
        ]
        for suffix in suffixes where defaults.object(forKey: newPrefix + suffix) == nil {
            if let value = defaults.object(forKey: oldPrefix + suffix) {
                defaults.set(value, forKey: newPrefix + suffix)
            }
        }
    }
}

enum WhoopReconnectPolicy {
    static func delaySeconds(forAttempt attempt: Int) -> Double {
        let boundedAttempt = min(max(attempt, 0), 5)
        return min(60, pow(2, Double(boundedAttempt + 1)))
    }
}

struct WhoopConnectionSession: Equatable, Sendable {
    struct Token: Equatable, Sendable {
        let generation: UInt64
        let peripheralID: UUID
    }

    private(set) var generation: UInt64 = 0
    private(set) var peripheralID: UUID?

    mutating func select(_ peripheralID: UUID) -> Token {
        generation &+= 1
        self.peripheralID = peripheralID
        return Token(generation: generation, peripheralID: peripheralID)
    }

    mutating func resetKeepingPeripheral() -> Token? {
        generation &+= 1
        guard let peripheralID else { return nil }
        return Token(generation: generation, peripheralID: peripheralID)
    }

    mutating func clear() {
        generation &+= 1
        peripheralID = nil
    }

    func token() -> Token? {
        guard let peripheralID else { return nil }
        return Token(generation: generation, peripheralID: peripheralID)
    }

    func accepts(peripheralID: UUID) -> Bool {
        self.peripheralID == peripheralID
    }

    func accepts(_ token: Token) -> Bool {
        generation == token.generation && peripheralID == token.peripheralID
    }
}

/// Shared by restoration and powered-on callbacks. A pending connection belongs
/// to Core Bluetooth; duplicate state callbacks must not tear it down.
enum WhoopConnectionResumePolicy {
    enum State { case absent, disconnected, connecting, connected, disconnecting }
    enum Action: Equatable { case scan, connect, discover, wait }
    static func action(for state: State, hasServices: Bool) -> Action {
        switch state {
        case .absent: .scan
        case .disconnected: .connect
        case .connected: hasServices ? .wait : .discover
        case .connecting, .disconnecting: .wait
        }
    }
}
