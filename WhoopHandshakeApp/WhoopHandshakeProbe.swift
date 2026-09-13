@preconcurrency import CoreBluetooth
import Foundation
import OSLog

enum WhoopReconnectPolicy {
    static func delaySeconds(forAttempt attempt: Int) -> Double {
        let boundedAttempt = min(max(attempt, 0), 5)
        return min(60, pow(2, Double(boundedAttempt + 1)))
    }
}

@MainActor
final class WhoopHandshakeProbe: NSObject, ObservableObject {
    @Published private(set) var deviceName = "—"
    @Published private(set) var handshakeState = "Waiting for WHOOP 5"
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var isSleeping = false
    @Published private(set) var lastConnectedAt: Date?
    private var lastHeartRateReceivedAt: Date?
    private var canAttemptHandshake = false

    var isConnected: Bool {
        peripheral?.state == .connected && handshakeState.hasPrefix("Acknowledged")
    }

    nonisolated static func heartRateIsFresh(
        receivedAt: Date?,
        now: Date = .now,
        maxAge: TimeInterval = 90
    ) -> Bool {
        guard let receivedAt else { return false }
        let age = now.timeIntervalSince(receivedAt)
        return age >= 0 && age <= maxAge
    }

    nonisolated static func shouldDeduplicateTransportRetries(frameType: UInt8?) -> Bool {
        guard let frameType else { return false }
        return [36, 38, 47, 49, 50, 56].contains(frameType)
    }

    nonisolated static func batteryLevelStatusCharging(_ data: Data) -> Bool? {
        guard data.count >= 3 else { return nil }
        let powerState =
            UInt16(data[data.startIndex + 1])
            | (UInt16(data[data.startIndex + 2]) << 8)
        let wiredPower = (powerState >> 1) & 0b11
        let wirelessPower = (powerState >> 3) & 0b11
        let chargeState = (powerState >> 5) & 0b11
        let hasExternalPower = wiredPower == 1 || wirelessPower == 1

        if chargeState == 1 || hasExternalPower { return true }
        if chargeState == 2 || chargeState == 3 { return false }
        return nil
    }

    nonisolated static func legacyBatteryPowerStateCharging(_ data: Data) -> Bool? {
        guard let powerState = data.first else { return nil }
        switch (powerState >> 4) & 0b11 {
        case 3: return true
        case 1, 2: return false
        default: return nil
        }
    }

    nonisolated static func freshWhoop5WristState(
        _ data: Data,
        receivedAt: Date,
        freshnessWindow: TimeInterval = 45
    ) -> Bool? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20,
            bytes[8] == 48,
            WhoopFrameIntegrity.isValid(data)
        else { return nil }

        let timestamp =
            UInt32(bytes[12])
            | (UInt32(bytes[13]) << 8)
            | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)
        let eventDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        guard abs(receivedAt.timeIntervalSince(eventDate)) <= freshnessWindow else { return nil }

        switch bytes[10] {
        case 9: return true
        case 10: return false
        default: return nil
        }
    }

    private lazy var central = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [CBCentralManagerOptionRestoreIdentifierKey: "com.clintonst.sleep.whoop-central"]
    )
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryPowerStateCharacteristic: CBCharacteristic?
    private var batteryLevelStatusCharacteristic: CBCharacteristic?
    private var hasExplicitChargingState = false
    private var lastObservedWristState: Bool?
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var helloOutstanding = false
    private var helloAttemptID: UUID?
    private var commandSequence: UInt8 = 1
    private var lastTelemetryCacheWriteAt: Date?
    private var receivedProprietaryPacketCount = 0
    private var realtimeKeepaliveTask: Task<Void, Never>?
    private var historicalRefreshTask: Task<Void, Never>?
    private var historicalWatchdogTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var connectionRetryTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var historicalSyncActive = false
    private var historicalSessionID: String?
    private var lastHistoricalProgressAt: Date?
    private var newestHistoricalSampleAtInSync: Date?
    private var lastAcknowledgedHistoricalEndData: [UInt8]?
    private var lastHistoricalAcknowledgementAt: Date?
    private var lastSleepAnalysisAt: Date?
    private var lastFinalizedSleepID: String?
    private let store = WhoopStore.shared
    private let knownPeripheralKey = "WhoopHandshakeProbe.knownPeripheralIdentifier"
    private let confirmedBondKey = "WhoopHandshakeProbe.confirmedEncryptedBond"
    private let cachedHeartRateKey = "WhoopHandshakeProbe.cachedHeartRateBPM"
    private let cachedHeartRateDateKey = "WhoopHandshakeProbe.cachedHeartRateDate"
    private let cachedBatteryLevelKey = "WhoopHandshakeProbe.cachedBatteryLevel"
    private let cachedBatteryLevelDateKey = "WhoopHandshakeProbe.cachedBatteryLevelDate"

    private let whoop5Service = CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A")
    private let heartRateService = CBUUID(string: "180D")
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let batteryPowerStateUUID = CBUUID(string: "2A1A")
    private let batteryLevelStatusUUID = CBUUID(string: "2BED")
    private let commandUUID = CBUUID(string: "FD4B0002-CCE1-4033-93CE-002D5875F58A")
    private let notifyUUIDs = Set([
        CBUUID(string: "FD4B0003-CCE1-4033-93CE-002D5875F58A"),
        CBUUID(string: "FD4B0004-CCE1-4033-93CE-002D5875F58A"),
        CBUUID(string: "FD4B0005-CCE1-4033-93CE-002D5875F58A"),
        CBUUID(string: "FD4B0007-CCE1-4033-93CE-002D5875F58A"),
    ])
    private let clientHello = Data(WhoopCommand.clientHello.frame(sequence: 0x01))
    private static let logger = Logger(subsystem: "com.clintonst.sleep", category: "WhoopHandshake")

    override init() {
        super.init()
        restoreCachedTelemetry()
        record("Probe initialized")
        _ = central
    }

    deinit {
        realtimeKeepaliveTask?.cancel()
        historicalRefreshTask?.cancel()
        historicalWatchdogTask?.cancel()
        handshakeTask?.cancel()
        connectionRetryTask?.cancel()
    }

    private func record(_ message: String) {
        Self.logger.debug("\(message, privacy: .public)")
    }

    private func restoreCachedTelemetry() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: cachedBatteryLevelKey) != nil,
            let observedAt = defaults.object(forKey: cachedBatteryLevelDateKey) as? Date,
            Date().timeIntervalSince(observedAt) <= 24 * 60 * 60
        {
            batteryLevel = min(max(defaults.integer(forKey: cachedBatteryLevelKey), 0), 100)
        }
        if defaults.object(forKey: cachedHeartRateKey) != nil {
            let bpm = defaults.integer(forKey: cachedHeartRateKey)
            if bpm > 0 {
                lastHeartRateReceivedAt = defaults.object(forKey: cachedHeartRateDateKey) as? Date
            }
        }

        store.loadLatestHeartRateSample { [weak self] sample in
            guard let sample else { return }
            Task { @MainActor in
                guard let self else { return }
                let cachedDate = self.lastHeartRateReceivedAt ?? .distantPast
                guard sample.receivedAt > cachedDate else { return }
                self.cacheHeartRate(sample.heartRate, receivedAt: sample.receivedAt)
            }
        }
        // A completed offload already persisted before a relaunch is still a
        // coherent source. The store verifies that completion marker covers
        // the newest history row before it permits an automatic write.
        refreshSleepSnapshot(force: true, allowAutomaticFinalization: true)
    }

    private func refreshSleepSnapshot(
        force: Bool = false,
        allowAutomaticFinalization: Bool = false
    ) {
        let now = Date()
        guard force || lastSleepAnalysisAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else {
            return
        }
        lastSleepAnalysisAt = now
        store.refreshSleepSnapshot(
            allowAutomaticFinalization: allowAutomaticFinalization
        ) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.isSleeping = snapshot.isSleeping
                if let record = snapshot.finalizedRecord,
                    record.sleepID != self.lastFinalizedSleepID
                {
                    self.lastFinalizedSleepID = record.sleepID
                    WhoopNotificationManager.shared.sendMorningSummary(for: record)
                    WhoopHealthHistoryEvents.post(.dayPublished(record))
                }
            }
        }
        if force {
            // Queue this after the forced analysis so the small on-device
            // diagnostic always describes the state the dashboard just used.
            store.writeSleepDiagnostics(now: now)
        }
    }

    private func cacheHeartRate(_ bpm: Int, receivedAt: Date = .now) {
        guard bpm > 0 else { return }
        lastHeartRateReceivedAt = receivedAt
        guard lastTelemetryCacheWriteAt.map({ receivedAt.timeIntervalSince($0) >= 30 }) ?? true else {
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(bpm, forKey: cachedHeartRateKey)
        defaults.set(receivedAt, forKey: cachedHeartRateDateKey)
        lastTelemetryCacheWriteAt = receivedAt
    }

    private func recordProprietaryMetadataPacket(
        _ data: Data,
        characteristicUUID: String
    ) {
        let preview = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        record(
            "WHOOP metadata packet #\(receivedProprietaryPacketCount) on \(characteristicUUID), \(data.count) bytes: \(preview)\(data.count > 24 ? " …" : "")"
        )
    }

    private func cacheBatteryLevel(_ level: Int) {
        let clampedLevel = min(max(level, 0), 100)
        isCharging = WhoopBluetoothPolicy.inferredCharging(
            previousLevel: batteryLevel,
            currentLevel: clampedLevel,
            hasExplicitChargingState: hasExplicitChargingState,
            currentChargingState: isCharging
        )
        batteryLevel = clampedLevel
        UserDefaults.standard.set(clampedLevel, forKey: cachedBatteryLevelKey)
        UserDefaults.standard.set(Date(), forKey: cachedBatteryLevelDateKey)
        WhoopNotificationManager.shared.observeBatteryLevel(clampedLevel)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            record("Scan requested while Bluetooth state was \(central.state.rawValue)")
            return
        }
        central.stopScan()
        connectionRetryTask?.cancel()
        connectionRetryTask = nil
        reconnectAttempt = 0
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        resetConnectionSession()
        commandSequence = 1
        canAttemptHandshake = false
        handshakeState = "Waiting for WHOOP 5"
        if let savedIdentifier = UserDefaults.standard.string(forKey: knownPeripheralKey),
            let uuid = UUID(uuidString: savedIdentifier),
            let known = central.retrievePeripherals(withIdentifiers: [uuid]).first
        {
            record("Retrieved known WHOOP peripheral directly: \(savedIdentifier)")
            connect(known, description: "saved WHOOP")
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [whoop5Service])
        if let first = connected.first {
            record("Found an existing system connection: \(first.identifier.uuidString)")
            connect(first, description: "system-connected WHOOP")
            return
        }
        record("Scanning for WHOOP 5 advertisements")
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func connect(_ candidate: CBPeripheral, description: String) {
        guard peripheral == nil else { return }
        peripheral = candidate
        UserDefaults.standard.set(candidate.identifier.uuidString, forKey: knownPeripheralKey)
        central.stopScan()
        deviceName = candidate.name ?? "WHOOP"
        record("Connecting to \(deviceName) [\(candidate.identifier.uuidString)] (\(description))")
        candidate.delegate = self
        central.connect(candidate)
    }

    func attemptHandshake() {
        guard let peripheral,
            peripheral.state == .connected,
            let commandCharacteristic,
            !helloOutstanding
        else { return }
        helloOutstanding = true
        let attemptID = UUID()
        helloAttemptID = attemptID
        canAttemptHandshake = false
        handshakeState = "Writing CLIENT_HELLO"
        record("Writing 16-byte CLIENT_HELLO with response to \(commandCharacteristic.uuid.uuidString)")
        peripheral.writeValue(clientHello, for: commandCharacteristic, type: .withResponse)

        handshakeTask?.cancel()
        handshakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                let self,
                self.helloOutstanding,
                self.helloAttemptID == attemptID
            else { return }
            self.helloOutstanding = false
            self.helloAttemptID = nil
            self.handshakeTask = nil
            self.handshakeState = "Handshake timed out; resetting connection"
            self.record("CLIENT_HELLO had no write callback after 8 seconds; resetting the link")
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func resetConnectionSession() {
        if let historicalSessionID {
            store.abandonHistoricalOffload(
                historicalSessionID,
                reason: "Bluetooth connection session reset"
            )
        }
        historicalSessionID = nil
        commandCharacteristic = nil
        heartRateCharacteristic = nil
        batteryPowerStateCharacteristic = nil
        batteryLevelStatusCharacteristic = nil
        hasExplicitChargingState = false
        isCharging = false
        notifyCharacteristics.removeAll(keepingCapacity: true)
        helloOutstanding = false
        helloAttemptID = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        realtimeKeepaliveTask?.cancel()
        realtimeKeepaliveTask = nil
        historicalRefreshTask?.cancel()
        historicalRefreshTask = nil
        historicalWatchdogTask?.cancel()
        historicalWatchdogTask = nil
        historicalSyncActive = false
        lastHistoricalProgressAt = nil
        newestHistoricalSampleAtInSync = nil
        lastAcknowledgedHistoricalEndData = nil
        lastHistoricalAcknowledgementAt = nil
        canAttemptHandshake = false
    }

    private func scheduleReconnect(_ candidate: CBPeripheral, reason: String) {
        guard central.state == .poweredOn else { return }
        connectionRetryTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delay = WhoopReconnectPolicy.delaySeconds(forAttempt: attempt)
        record("Scheduling reconnect attempt \(attempt + 1) in \(Int(delay)) seconds after \(reason)")
        connectionRetryTask = Task { @MainActor [weak self, weak candidate] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                let self,
                let candidate,
                self.central.state == .poweredOn,
                self.peripheral?.identifier == candidate.identifier,
                candidate.state == .disconnected
            else { return }
            self.connectionRetryTask = nil
            self.record("Starting reconnect attempt \(attempt + 1)")
            self.central.connect(candidate)
        }
    }

    private func subscribeAfterHandshake() {
        guard let peripheral else { return }
        for characteristic in notifyCharacteristics
        where characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            record("Subscribing to WHOOP notification characteristic \(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(true, for: characteristic)
        }
        if let heartRateCharacteristic, !heartRateCharacteristic.isNotifying {
            record("Subscribing to standard Heart Rate Measurement 2A37")
            peripheral.setNotifyValue(true, for: heartRateCharacteristic)
        }
        armRealtimeHeartRate()
        scheduleHistoricalSync(after: .seconds(1.5))
    }

    func refreshHistoricalData() {
        guard isConnected else { return }
        beginHistoricalSync()
    }

    private func scheduleHistoricalSync(after delay: Duration = .seconds(15 * 60)) {
        historicalRefreshTask?.cancel()
        historicalRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.historicalRefreshTask = nil
            self.beginHistoricalSync()
        }
    }

    private func beginHistoricalSync() {
        guard !historicalSyncActive,
            let peripheral,
            peripheral.state == .connected,
            handshakeState.hasPrefix("Acknowledged"),
            commandCharacteristic != nil
        else { return }
        historicalSyncActive = true
        lastHistoricalProgressAt = .now
        newestHistoricalSampleAtInSync = nil
        let expectedPeripheralID = peripheral.identifier
        store.beginHistoricalOffload(peripheralID: expectedPeripheralID) { [weak self] sessionID in
            Task { @MainActor in
                guard let self,
                    self.historicalSyncActive,
                    let sessionID,
                    self.historicalSessionID == nil,
                    self.peripheral?.identifier == expectedPeripheralID,
                    let peripheral = self.peripheral,
                    peripheral.state == .connected,
                    let commandCharacteristic = self.commandCharacteristic
                else {
                    if let sessionID {
                        self?.store.abandonHistoricalOffload(
                            sessionID,
                            reason: "connection changed before offload command"
                        )
                    }
                    self?.historicalSyncActive = false
                    return
                }
                self.historicalSessionID = sessionID
                self.startHistoricalWatchdog()
                self.commandSequence &+= 1
                let frame = WhoopCommand.requestHistory.frame(sequence: self.commandSequence)
                self.record(
                    "Starting persisted WHOOP historical offload \(sessionID.prefix(8)), seq \(self.commandSequence)")
                peripheral.writeValue(Data(frame), for: commandCharacteristic, type: .withResponse)
            }
        }
    }

    @discardableResult
    private func acknowledgeHistoricalChunk(endData: [UInt8]) -> Bool {
        guard let peripheral,
            peripheral.state == .connected,
            let commandCharacteristic
        else { return false }

        // The band repeats an unacknowledged chunk terminator. Suppress the
        // immediate notification burst, but retry after a short interval. The
        // old permanent duplicate guard could lose one BLE write and leave the
        // offload marked active forever, blocking every future refresh.
        let now = Date()
        guard
            WhoopBluetoothPolicy.shouldAcknowledgeChunk(
                endData: endData,
                previousEndData: lastAcknowledgedHistoricalEndData,
                previousAcknowledgedAt: lastHistoricalAcknowledgementAt,
                now: now
            )
        else {
            return false
        }
        lastAcknowledgedHistoricalEndData = endData
        lastHistoricalAcknowledgementAt = now
        commandSequence &+= 1
        let frame = WhoopCommand.acknowledgeHistoryChunk(endData).frame(
            sequence: commandSequence
        )
        record("Acknowledging durably stored historical chunk, seq \(commandSequence)")
        peripheral.writeValue(Data(frame), for: commandCharacteristic, type: .withResponse)
        return true
    }

    private func startHistoricalWatchdog() {
        guard historicalWatchdogTask == nil else { return }
        historicalWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                guard self.historicalSyncActive else {
                    self.historicalWatchdogTask = nil
                    return
                }
                let stalledFor =
                    self.lastHistoricalProgressAt.map { Date().timeIntervalSince($0) }
                    ?? .infinity
                guard stalledFor >= 90 else { continue }

                self.record(
                    "Historical offload stalled for \(Int(stalledFor)) seconds; resetting the session and retrying")
                if let historicalSessionID = self.historicalSessionID {
                    self.store.abandonHistoricalOffload(
                        historicalSessionID,
                        reason: "no forward history progress for \(Int(stalledFor)) seconds"
                    )
                }
                self.historicalSessionID = nil
                self.historicalSyncActive = false
                self.lastHistoricalProgressAt = nil
                self.newestHistoricalSampleAtInSync = nil
                self.lastAcknowledgedHistoricalEndData = nil
                self.lastHistoricalAcknowledgementAt = nil
                self.historicalWatchdogTask = nil
                self.beginHistoricalSync()
                return
            }
        }
    }

    private func armRealtimeHeartRate() {
        guard let peripheral,
            peripheral.state == .connected,
            let commandCharacteristic
        else { return }
        commandSequence &+= 1
        let sensorFrame = WhoopCommand.realtimeSensors(enabled: false).frame(
            sequence: commandSequence
        )
        record(
            "Disabling battery-heavy SEND_R10_R11_REALTIME burst, seq \(commandSequence): \(sensorFrame.map { String(format: "%02X", $0) }.joined(separator: " "))"
        )
        peripheral.writeValue(Data(sensorFrame), for: commandCharacteristic, type: .withoutResponse)

        commandSequence &+= 1
        let heartRateFrame = WhoopCommand.realtimeHeartRate(enabled: true).frame(
            sequence: commandSequence
        )
        record(
            "Sending reversible TOGGLE_REALTIME_HR(1), seq \(commandSequence): \(heartRateFrame.map { String(format: "%02X", $0) }.joined(separator: " "))"
        )
        peripheral.writeValue(Data(heartRateFrame), for: commandCharacteristic, type: .withoutResponse)
        startRealtimeKeepalive()
    }

    private func startRealtimeKeepalive() {
        guard realtimeKeepaliveTask == nil else { return }
        realtimeKeepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled,
                    let self,
                    self.peripheral?.state == .connected,
                    self.handshakeState.hasPrefix("Acknowledged")
                else { continue }
                self.record("30-second live-stream keepalive")
                self.realtimeKeepaliveTask = nil
                self.armRealtimeHeartRate()
                return
            }
        }
    }

    private func scheduleAutomaticHandshakeIfTrusted() {
        guard UserDefaults.standard.bool(forKey: confirmedBondKey) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self,
                self.canAttemptHandshake,
                !self.helloOutstanding,
                self.handshakeState == "Ready"
            else { return }
            self.record("Automatically reopening the previously confirmed encrypted bond")
            self.attemptHandshake()
        }
    }

    private func applyState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            record("Bluetooth powered on")
            startScan()
        case .poweredOff:
            connectionRetryTask?.cancel()
            connectionRetryTask = nil
            record("Bluetooth powered off")
        case .unauthorized:
            record("Bluetooth permission denied")
        case .unsupported:
            record("Bluetooth unsupported")
        case .resetting:
            record("Bluetooth resetting")
        case .unknown:
            record("Bluetooth state unknown")
        @unknown default:
            record("Unrecognized Bluetooth state")
        }
    }

    @discardableResult
    private func parseHeartRate(_ data: Data) -> WhoopDecodedRealtime? {
        guard let measurement = WhoopDecodedRealtime.decodeStandardHeartRate(data) else { return nil }
        cacheHeartRate(measurement.heartRate)
        return measurement
    }

    @discardableResult
    private func parseWhoop5Packet(_ data: Data) -> WhoopDecodedRealtime? {
        guard let measurement = WhoopDecodedRealtime.decodeWhoop5Realtime(data) else { return nil }
        cacheHeartRate(measurement.heartRate)
        return measurement
    }

    private func parseWhoop5Historical(_ data: Data) -> WhoopDecodedHistorical? {
        WhoopDecodedHistorical.decode(data)
    }

}

extension WhoopHandshakeProbe: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        applyState(central.state)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        guard let restored else {
            record("CoreBluetooth restoration contained no peripheral")
            return
        }
        peripheral = restored
        restored.delegate = self
        deviceName = restored.name ?? "WHOOP"
        UserDefaults.standard.set(restored.identifier.uuidString, forKey: knownPeripheralKey)
        record("CoreBluetooth restored WHOOP [\(restored.identifier.uuidString)] in state \(restored.state.rawValue)")
        if restored.state == .connected {
            restored.discoverServices([whoop5Service, heartRateService, batteryService])
        } else {
            central.connect(restored)
        }
    }

    // swift-format-ignore: AlwaysUseLowerCamelCase
    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard
            WhoopBluetoothPolicy.matchesAdvertisement(
                serviceUUIDs: Set(advertised.map { $0.uuidString.uppercased() }),
                advertisedName: advertisedName,
                peripheralName: peripheral.name,
                whoopServiceUUID: whoop5Service.uuidString
            )
        else { return }
        deviceName = advertisedName ?? peripheral.name ?? "WHOOP"
        record(
            "Discovered \(deviceName), RSSI \(RSSI), services \(advertised.map(\.uuidString).joined(separator: ", "))")
        connect(peripheral, description: "WHOOP at RSSI \(RSSI)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionRetryTask?.cancel()
        connectionRetryTask = nil
        reconnectAttempt = 0
        resetConnectionSession()
        lastConnectedAt = .now
        record("Connected; discovering WHOOP 5 and Heart Rate services")
        peripheral.discoverServices([whoop5Service, heartRateService, batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let detail = error?.localizedDescription ?? "unknown error"
        record("Connection failed: \(detail)")
        resetConnectionSession()
        scheduleReconnect(peripheral, reason: "connection failure")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if helloOutstanding { handshakeState = "Link dropped before CLIENT_HELLO acknowledgement" }
        let detail = error?.localizedDescription ?? "no error"
        record(
            helloOutstanding
                ? "Disconnected with CLIENT_HELLO outstanding: \(detail)"
                : "Disconnected: \(detail)")
        resetConnectionSession()
        scheduleReconnect(peripheral, reason: "disconnect")
    }
}

extension WhoopHandshakeProbe: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            record("Service discovery failed: \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        record("Discovered services: \((peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            record("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        record(
            "Characteristics for \(service.uuid.uuidString): \((service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))"
        )
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == commandUUID {
                commandCharacteristic = characteristic
                canAttemptHandshake = characteristic.properties.contains(.write)
                handshakeState = canAttemptHandshake ? "Ready" : "Confirmed writes unavailable"
            } else if characteristic.uuid == CBUUID(string: "2A37") {
                heartRateCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    record("Subscribing to bond-free standard Heart Rate Measurement 2A37 before handshake")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if characteristic.uuid == batteryLevelUUID {
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if characteristic.uuid == batteryLevelStatusUUID {
                batteryLevelStatusCharacteristic = characteristic
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if characteristic.uuid == batteryPowerStateUUID {
                batteryPowerStateCharacteristic = characteristic
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if notifyUUIDs.contains(characteristic.uuid) {
                if !notifyCharacteristics.contains(where: { $0.uuid == characteristic.uuid }) {
                    notifyCharacteristics.append(characteristic)
                }
            }
        }
        if commandCharacteristic != nil { scheduleAutomaticHandshakeIfTrusted() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == commandUUID, helloOutstanding else { return }
        helloOutstanding = false
        helloAttemptID = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        canAttemptHandshake = true
        if let error {
            handshakeState = "Refused: \(error.localizedDescription)"
            record("CLIENT_HELLO refused: \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
        } else {
            handshakeState = "Acknowledged — encrypted link established"
            UserDefaults.standard.set(true, forKey: confirmedBondKey)
            record("CLIENT_HELLO acknowledged; encrypted bond established")
            subscribeAfterHandshake()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            record(
                "Notification subscription failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            if notifyUUIDs.contains(characteristic.uuid) {
                central.cancelPeripheralConnection(peripheral)
            }
        } else {
            record("Notification state \(characteristic.uuid.uuidString): \(characteristic.isNotifying ? "on" : "off")")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let deliveredAt = Date()
        let data = characteristic.value
        let characteristicUUID = characteristic.uuid.uuidString
        let peripheralID = peripheral.identifier
        let errorDescription = error?.localizedDescription
        guard errorDescription == nil, let data else { return }
        let uuid = CBUUID(string: characteristicUUID)
        if uuid == CBUUID(string: "2A37") {
            guard let measurement = parseHeartRate(data) else { return }
            store.append(
                packet: data,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                frameType: nil,
                realtime: measurement,
                historical: nil,
                deduplicateTransportRetries: false,
                deliveredAt: deliveredAt
            ) { [weak self] result in
                guard !result.success else { return }
                Task { @MainActor in
                    self?.record("Failed to persist standard 2A37 heart-rate packet")
                }
            }
        } else if uuid == batteryLevelUUID, let level = data.first {
            cacheBatteryLevel(Int(level))
            record("Battery level: \(batteryLevel ?? 0)%")
        } else if uuid == batteryLevelStatusUUID,
            let charging = Self.batteryLevelStatusCharging(data)
        {
            hasExplicitChargingState = true
            isCharging = charging
            record("Battery charging: \(charging ? "yes" : "no") (Battery Level Status)")
        } else if uuid == batteryPowerStateUUID,
            let charging = Self.legacyBatteryPowerStateCharging(data)
        {
            hasExplicitChargingState = true
            isCharging = charging
            record("Battery charging: \(charging ? "yes" : "no") (Battery Power State)")
        } else if notifyUUIDs.contains(uuid) {
            receivedProprietaryPacketCount += 1
            let packetOrdinal = receivedProprietaryPacketCount
            let frameType = data.count > 8 ? data[8] : nil
            if let isWorn = Self.freshWhoop5WristState(data, receivedAt: deliveredAt),
                isWorn != lastObservedWristState
            {
                lastObservedWristState = isWorn
                WhoopNotificationManager.shared.observeWristState(isWorn: isWorn)
                record("Wrist state: \(isWorn ? "on" : "off")")
            }
            let realtime = parseWhoop5Packet(data)
            let historical = parseWhoop5Historical(data)
            let metadata = WhoopHistoricalMetadata(data: data, frameType: frameType)
            let metadataType = metadata?.type
            let historicalEndData = metadata?.chunkEndData
            if metadata?.shouldForcePresentation(historicalSyncActive: historicalSyncActive) == true {
                recordProprietaryMetadataPacket(data, characteristicUUID: characteristicUUID)
            }
            // Count only forward movement through decoded history. The
            // band may replay the same packet or chunk ending thousands of
            // times while waiting for an acknowledgement; treating those
            // duplicates as progress would defeat the stall watchdog.
            if let sampleAt = historical?.sampleAt,
                newestHistoricalSampleAtInSync.map({ sampleAt > $0 }) ?? true
            {
                newestHistoricalSampleAtInSync = sampleAt
                lastHistoricalProgressAt = .now
            }
            if metadataType == 1 {
                historicalSyncActive = true
                newestHistoricalSampleAtInSync = nil
                lastAcknowledgedHistoricalEndData = nil
                lastHistoricalAcknowledgementAt = nil
                startHistoricalWatchdog()
            }
            store.append(
                packet: data,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                frameType: frameType,
                realtime: realtime,
                historical: historical,
                offloadSessionID: historicalSessionID,
                deduplicateTransportRetries: Self.shouldDeduplicateTransportRetries(
                    frameType: frameType
                ),
                deliveredAt: deliveredAt
            ) { [weak self] result in
                let needsMainActor =
                    !result.success
                    || historicalEndData != nil
                    || metadataType == 3
                guard needsMainActor else { return }
                Task { @MainActor in
                    guard let self else { return }
                    guard result.success else {
                        self.record("Failed to persist WHOOP packet #\(packetOrdinal); history was not acknowledged")
                        return
                    }
                    if let historicalEndData {
                        // The store queue is serial: reaching this completion proves every
                        // preceding raw and decoded sample in this chunk is durable.
                        _ = self.acknowledgeHistoricalChunk(endData: historicalEndData)
                    } else {
                        guard
                            WhoopBluetoothPolicy.shouldAnalyzeHistoryCompletion(
                                metadataType: metadataType,
                                historicalSyncActive: self.historicalSyncActive
                            )
                        else { return }
                        self.historicalSyncActive = false
                        self.historicalSessionID = nil
                        self.lastHistoricalProgressAt = nil
                        self.newestHistoricalSampleAtInSync = nil
                        self.lastAcknowledgedHistoricalEndData = nil
                        self.lastHistoricalAcknowledgementAt = nil
                        self.historicalWatchdogTask?.cancel()
                        self.historicalWatchdogTask = nil
                        // HISTORY_COMPLETE is the only point where the
                        // offload is a coherent whole. Automatic processing
                        // is forbidden at chunk boundaries because that can
                        // publish duration before the rest of the night,
                        // HRV, and RHR have arrived.
                        self.refreshSleepSnapshot(
                            force: true,
                            allowAutomaticFinalization: true
                        )
                        self.scheduleHistoricalSync()
                    }
                }
            }
        }
    }
}
