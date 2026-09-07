@preconcurrency import CoreBluetooth
import Foundation

enum WhoopReconnectPolicy {
    static func delaySeconds(forAttempt attempt: Int) -> Double {
        let boundedAttempt = min(max(attempt, 0), 5)
        return min(60, pow(2, Double(boundedAttempt + 1)))
    }
}

@MainActor
final class WhoopHandshakeProbe: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var status = "Waiting for Bluetooth"
    @Published private(set) var deviceName = "—"
    @Published private(set) var handshakeState = "Waiting for WHOOP 5"
    @Published private(set) var notificationState = "Not requested"
    @Published private(set) var heartRate = "—"
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var isSleeping = false
    /// A detected main sleep that is not stored yet. The dashboard shows its
    /// "Sleep detected" row exactly while this is non-nil.
    @Published private(set) var pendingSleep: WhoopPendingSleep?
    @Published private(set) var isProcessingSleep = false
    @Published private(set) var sleepProcessFailure: String?
    @Published private(set) var lastConnectedAt: Date?
    @Published private(set) var lastDataReceivedAt: Date?
    @Published private(set) var lastHeartRateReceivedAt: Date?
    @Published private(set) var rrSummary = "—"
    @Published private(set) var realtimeState = "Not armed"
    @Published private(set) var proprietaryPacketCount = 0
    @Published private(set) var persistedPacketCount = 0
    @Published private(set) var latestPacket = "—"
    @Published private(set) var canAttemptHandshake = false
    @Published private(set) var diagnosticEvents: [String] = []

    var bluetoothReady: Bool { central?.state == .poweredOn }
    var isConnected: Bool {
        peripheral?.state == .connected && handshakeState.hasPrefix("Acknowledged")
    }

    var hasFreshHeartRate: Bool {
        Self.heartRateIsFresh(receivedAt: lastHeartRateReceivedAt)
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
        let powerState = UInt16(data[data.startIndex + 1])
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
              WhoopFrameIntegrity.isValid(data) else { return nil }

        let timestamp = UInt32(bytes[12])
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

    var diagnosticReport: String {
        (["WHOOP 5 handshake diagnostic", "Generated: \(Self.reportDateFormatter.string(from: .now))", ""] + diagnosticEvents)
            .joined(separator: "\n")
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryLevelCharacteristic: CBCharacteristic?
    private var batteryPowerStateCharacteristic: CBCharacteristic?
    private var batteryLevelStatusCharacteristic: CBCharacteristic?
    private var hasExplicitChargingState = false
    private var lastObservedWristState: Bool?
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var helloOutstanding = false
    private var helloAttemptID: UUID?
    private var commandSequence: UInt8 = 1
    private var lastTelemetryCacheWriteAt: Date?
    private var lastHeartRatePresentationAt: Date?
    private var lastPacketPresentationAt: Date?
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
    /// Suppresses the pending row between an optimistic tap and the refresh that
    /// observes the stored night, so it cannot flicker back in mid-animation.
    private var optimisticallyProcessedSleepID: String?
    /// A Process tap waiting for the in-flight historical offload to become a
    /// coherent whole. It is retried exactly when HISTORY_COMPLETE is durable.
    private var pendingProcessRequest: WhoopPendingSleep?
    private var processFinalizationInFlight = false
    private var processFailureResetTask: Task<Void, Never>?
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
    private let clientHello = Data([
        0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
        0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
    ])
    private static let reportDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override init() {
        super.init()
        assert(Self.puffinCommandFrame(cmd: 0x91, seq: 0x01, payload: [0x01]) == [UInt8](clientHello))
        restoreCachedTelemetry()
        record("Probe initialized")
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.clintonst.sleep.whoop-central"]
        )
    }

    deinit {
        realtimeKeepaliveTask?.cancel()
        historicalRefreshTask?.cancel()
        historicalWatchdogTask?.cancel()
        handshakeTask?.cancel()
        connectionRetryTask?.cancel()
    }

    private func record(_ message: String) {
        let timestamp = Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        diagnosticEvents.append("\(timestamp)  \(message)")
        if diagnosticEvents.count > 200 {
            diagnosticEvents.removeFirst(diagnosticEvents.count - 200)
        }
    }

    private func restoreCachedTelemetry() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: cachedBatteryLevelKey) != nil,
           let observedAt = defaults.object(forKey: cachedBatteryLevelDateKey) as? Date,
           Date().timeIntervalSince(observedAt) <= 24 * 60 * 60 {
            batteryLevel = min(max(defaults.integer(forKey: cachedBatteryLevelKey), 0), 100)
        }
        if defaults.object(forKey: cachedHeartRateKey) != nil {
            let bpm = defaults.integer(forKey: cachedHeartRateKey)
            if bpm > 0 {
                heartRate = "\(bpm) bpm"
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
                self.applyPendingSleep(snapshot.pendingSleep)
                if let record = snapshot.finalizedRecord,
                   record.sleepID != self.lastFinalizedSleepID {
                    self.lastFinalizedSleepID = record.sleepID
                    WhoopNotificationManager.shared.sendMorningSummary(for: record)
                    NotificationCenter.default.post(name: .whoopDailyHealthUpdated, object: record)
                }
            }
        }
        if force {
            // Queue this after the forced analysis so the small on-device
            // diagnostic always describes the state the dashboard just used.
            store.writeSleepDiagnostics(now: now)
        }
    }

    private func applyPendingSleep(_ pending: WhoopPendingSleep?) {
        // A night that has just been processed optimistically stays hidden until
        // the store stops reporting it, which is what actually settles the row.
        if let optimisticallyProcessedSleepID {
            guard pending?.sleepID != optimisticallyProcessedSleepID else {
                pendingSleep = nil
                return
            }
            self.optimisticallyProcessedSleepID = nil
        }
        pendingSleep = pending
    }

    /// Finishes the detected night from coherent data already collected on the
    /// phone. If a history offload is in flight, the tap remains pending until
    /// its completion marker is durable rather than banking the partial prefix.
    func processPendingSleep() {
        guard !isProcessingSleep, let pending = pendingSleep else { return }
        isProcessingSleep = true
        sleepProcessFailure = nil
        processFailureResetTask?.cancel()
        optimisticallyProcessedSleepID = pending.sleepID
        pendingProcessRequest = pending
        pendingSleep = nil
        AppHaptics.softImpact()

        // An in-flight offload is definitionally incomplete even during the
        // short interval before its first historical sample is persisted.
        guard !historicalSyncActive else { return }
        finalizeProcessRequest()
    }

    private func finalizeProcessRequest() {
        guard !processFinalizationInFlight,
              let pending = pendingProcessRequest else { return }
        processFinalizationInFlight = true
        store.finalizePendingSleep { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.processFinalizationInFlight = false
                switch result {
                case .success(let record):
                    self.pendingProcessRequest = nil
                    self.lastFinalizedSleepID = record.sleepID
                    self.optimisticallyProcessedSleepID = record.sleepID
                    self.pendingSleep = nil
                    self.isProcessingSleep = false
                    AppHaptics.success()
                    NotificationCenter.default.post(name: .whoopDailyHealthUpdated, object: record)
                    self.refreshSleepSnapshot(force: true)

                case .failure(.historyStillLoading):
                    // Keep the tap pending. The existing collector/offload will
                    // call us again only after its completion packet is stored.
                    guard self.isConnected else {
                        self.pendingProcessRequest = nil
                        self.isProcessingSleep = false
                        self.optimisticallyProcessedSleepID = nil
                        self.pendingSleep = pending
                        self.sleepProcessFailure = "Reconnect WHOOP to finish"
                        AppHaptics.warning()
                        self.scheduleProcessFailureReset()
                        return
                    }
                    self.refreshHistoricalData()

                case .failure(let error):
                    self.pendingProcessRequest = nil
                    self.isProcessingSleep = false
                    self.optimisticallyProcessedSleepID = nil
                    self.pendingSleep = pending
                    self.sleepProcessFailure = error.message
                    AppHaptics.warning()
                    self.scheduleProcessFailureReset()
                }
            }
        }
    }

    private func scheduleProcessFailureReset() {
        processFailureResetTask?.cancel()
        processFailureResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.sleepProcessFailure = nil
        }
    }

    @discardableResult
    private func cacheHeartRate(_ bpm: Int, receivedAt: Date = .now) -> Bool {
        guard bpm > 0 else { return false }
        let shouldPresent = lastHeartRatePresentationAt.map {
            receivedAt.timeIntervalSince($0) >= 2
        } ?? true
        if shouldPresent {
            heartRate = "\(bpm) bpm"
            lastHeartRateReceivedAt = receivedAt
            lastHeartRatePresentationAt = receivedAt
        }
        presentDataReceived(at: receivedAt)
        guard lastTelemetryCacheWriteAt.map({ receivedAt.timeIntervalSince($0) >= 30 }) ?? true else {
            return shouldPresent
        }
        let defaults = UserDefaults.standard
        defaults.set(bpm, forKey: cachedHeartRateKey)
        defaults.set(receivedAt, forKey: cachedHeartRateDateKey)
        lastTelemetryCacheWriteAt = receivedAt
        return shouldPresent
    }

    private func presentDataReceived(at receivedAt: Date = .now, force: Bool = false) {
        guard force || lastDataReceivedAt.map({ receivedAt.timeIntervalSince($0) >= 2 }) ?? true else {
            return
        }
        lastDataReceivedAt = receivedAt
    }

    private func presentProprietaryPacket(
        _ data: Data,
        characteristicUUID: String,
        force: Bool
    ) {
        let now = Date()
        guard force || lastPacketPresentationAt.map({ now.timeIntervalSince($0) >= 2 }) ?? true else {
            return
        }
        lastPacketPresentationAt = now
        proprietaryPacketCount = receivedProprietaryPacketCount
        presentDataReceived(at: now, force: force)
        let frameType = data.count > 8 ? data[8] : nil
        latestPacket = frameType.map { String(format: "Type 0x%02X · %d B", $0, data.count) }
            ?? "Short frame (\(data.count) B)"
        if force {
            let preview = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            record("WHOOP metadata packet #\(receivedProprietaryPacketCount) on \(characteristicUUID), \(data.count) bytes: \(preview)\(data.count > 24 ? " …" : "")")
        }
    }

    private func cacheBatteryLevel(_ level: Int) {
        let clampedLevel = min(max(level, 0), 100)
        if !hasExplicitChargingState, let previousLevel = batteryLevel {
            if clampedLevel > previousLevel {
                isCharging = true
            } else if clampedLevel < previousLevel {
                isCharging = false
            }
        }
        batteryLevel = clampedLevel
        UserDefaults.standard.set(clampedLevel, forKey: cachedBatteryLevelKey)
        UserDefaults.standard.set(Date(), forKey: cachedBatteryLevelDateKey)
        WhoopNotificationManager.shared.observeBatteryLevel(clampedLevel)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "Bluetooth is not ready"
            record("Scan requested while Bluetooth was \(bluetoothState)")
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
        realtimeState = "Not armed"
        latestPacket = "—"
        canAttemptHandshake = false
        handshakeState = "Waiting for WHOOP 5"
        if let savedIdentifier = UserDefaults.standard.string(forKey: knownPeripheralKey),
           let uuid = UUID(uuidString: savedIdentifier),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
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
        status = "Scanning all nearby advertisements"
        record("Scanning for WHOOP 5 advertisements")
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func connect(_ candidate: CBPeripheral, description: String) {
        guard peripheral == nil else { return }
        peripheral = candidate
        UserDefaults.standard.set(candidate.identifier.uuidString, forKey: knownPeripheralKey)
        central.stopScan()
        deviceName = candidate.name ?? "WHOOP"
        status = "Found \(description); connecting"
        record("Connecting to \(deviceName) [\(candidate.identifier.uuidString)] (\(description))")
        candidate.delegate = self
        central.connect(candidate)
    }

    func attemptHandshake() {
        guard let peripheral,
              peripheral.state == .connected,
              let commandCharacteristic,
              !helloOutstanding else { return }
        helloOutstanding = true
        let attemptID = UUID()
        helloAttemptID = attemptID
        canAttemptHandshake = false
        handshakeState = "Writing CLIENT_HELLO"
        status = "Attempting encrypted WHOOP 5 handshake"
        record("Writing 16-byte CLIENT_HELLO with response to \(commandCharacteristic.uuid.uuidString)")
        peripheral.writeValue(clientHello, for: commandCharacteristic, type: .withResponse)

        handshakeTask?.cancel()
        handshakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  self.helloOutstanding,
                  self.helloAttemptID == attemptID else { return }
            self.helloOutstanding = false
            self.helloAttemptID = nil
            self.handshakeTask = nil
            self.handshakeState = "Handshake timed out; resetting connection"
            self.status = "Reconnecting after handshake timeout"
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
        batteryLevelCharacteristic = nil
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
        status = "Reconnecting in \(Int(delay))s"
        record("Scheduling reconnect attempt \(attempt + 1) in \(Int(delay)) seconds after \(reason)")
        connectionRetryTask = Task { @MainActor [weak self, weak candidate] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  let candidate,
                  self.central.state == .poweredOn,
                  self.peripheral?.identifier == candidate.identifier,
                  candidate.state == .disconnected else { return }
            self.connectionRetryTask = nil
            self.status = "Reconnecting automatically"
            self.record("Starting reconnect attempt \(attempt + 1)")
            self.central.connect(candidate)
        }
    }

    private func subscribeAfterHandshake() {
        guard let peripheral else { return }
        for characteristic in notifyCharacteristics where characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
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
              commandCharacteristic != nil else { return }
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
                      let commandCharacteristic = self.commandCharacteristic else {
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
                let frame = Self.puffinCommandFrame(
                    cmd: 22,
                    seq: self.commandSequence,
                    payload: [0x00]
                )
                self.record("Starting persisted WHOOP historical offload \(sessionID.prefix(8)), seq \(self.commandSequence)")
                peripheral.writeValue(Data(frame), for: commandCharacteristic, type: .withResponse)
            }
        }
    }

    @discardableResult
    private func acknowledgeHistoricalChunk(endData: [UInt8]) -> Bool {
        guard endData.count == 8,
              let peripheral,
              peripheral.state == .connected,
              let commandCharacteristic else { return false }

        // The band repeats an unacknowledged chunk terminator. Suppress the
        // immediate notification burst, but retry after a short interval. The
        // old permanent duplicate guard could lose one BLE write and leave the
        // offload marked active forever, blocking every future refresh.
        let now = Date()
        if endData == lastAcknowledgedHistoricalEndData,
           let lastHistoricalAcknowledgementAt,
           now.timeIntervalSince(lastHistoricalAcknowledgementAt) < 2 {
            return false
        }
        lastAcknowledgedHistoricalEndData = endData
        lastHistoricalAcknowledgementAt = now
        commandSequence &+= 1
        let frame = Self.puffinCommandFrame(
            cmd: 23,
            seq: commandSequence,
            payload: [0x01] + endData
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
                let stalledFor = self.lastHistoricalProgressAt.map { Date().timeIntervalSince($0) }
                    ?? .infinity
                guard stalledFor >= 90 else { continue }

                self.record("Historical offload stalled for \(Int(stalledFor)) seconds; resetting the session and retrying")
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
              let commandCharacteristic else { return }
        commandSequence &+= 1
        let sensorFrame = Self.puffinCommandFrame(cmd: 0x3F, seq: commandSequence, payload: [0x00])
        record("Disabling battery-heavy SEND_R10_R11_REALTIME burst, seq \(commandSequence): \(sensorFrame.map { String(format: "%02X", $0) }.joined(separator: " "))")
        peripheral.writeValue(Data(sensorFrame), for: commandCharacteristic, type: .withoutResponse)

        commandSequence &+= 1
        let heartRateFrame = Self.puffinCommandFrame(cmd: 0x03, seq: commandSequence, payload: [0x01])
        realtimeState = "Lightweight HR armed"
        status = "Encrypted link active; lightweight HR armed"
        record("Sending reversible TOGGLE_REALTIME_HR(1), seq \(commandSequence): \(heartRateFrame.map { String(format: "%02X", $0) }.joined(separator: " "))")
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
                      self.handshakeState.hasPrefix("Acknowledged") else { continue }
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
                  self.handshakeState == "Ready" else { return }
            self.record("Automatically reopening the previously confirmed encrypted bond")
            self.attemptHandshake()
        }
    }

    private static func puffinCommandFrame(cmd: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        var inner = [UInt8(0x23), seq, cmd] + payload
        let padding = (4 - inner.count % 4) % 4
        if padding > 0 {
            inner += [UInt8](repeating: 0, count: padding)
        }

        let declaredLength = inner.count + 4
        var frame: [UInt8] = [
            0xAA, 0x01,
            UInt8(declaredLength & 0xFF), UInt8((declaredLength >> 8) & 0xFF),
            0x00, 0x01,
        ]
        let headerCRC = crc16Modbus(frame)
        frame += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]
        frame += inner
        let trailer = crc32(inner)
        frame += [
            UInt8(trailer & 0xFF),
            UInt8((trailer >> 8) & 0xFF),
            UInt8((trailer >> 16) & 0xFF),
            UInt8((trailer >> 24) & 0xFF),
        ]
        return frame
    }

    private static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func applyState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothState = "On"
            record("Bluetooth powered on")
            startScan()
        case .poweredOff:
            connectionRetryTask?.cancel()
            connectionRetryTask = nil
            bluetoothState = "Off"
            status = "Turn Bluetooth on"
            record("Bluetooth powered off")
        case .unauthorized:
            bluetoothState = "Permission denied"
            status = "Bluetooth permission is required"
        case .unsupported:
            bluetoothState = "Unsupported"
        case .resetting:
            bluetoothState = "Resetting"
        case .unknown:
            bluetoothState = "Starting"
        @unknown default:
            bluetoothState = "Unknown"
        }
    }

    @discardableResult
    private func parseHeartRate(_ data: Data) -> WhoopDecodedRealtime? {
        guard let measurement = WhoopDecodedRealtime.decodeStandardHeartRate(data) else { return nil }
        let shouldPresent = cacheHeartRate(measurement.heartRate)
        if shouldPresent {
            rrSummary = measurement.rrIntervals.isEmpty
                ? "No R–R values"
                : measurement.rrIntervals.map { "\($0) ms" }.joined(separator: ", ")
        }
        return measurement
    }

    @discardableResult
    private func parseWhoop5Packet(_ data: Data) -> WhoopDecodedRealtime? {
        guard let measurement = WhoopDecodedRealtime.decodeWhoop5Realtime(data) else { return nil }
        let shouldPresent = cacheHeartRate(measurement.heartRate)
        if shouldPresent {
            rrSummary = measurement.rrIntervals.isEmpty
                ? "No R–R values"
                : measurement.rrIntervals.map { "\($0) ms" }.joined(separator: ", ")
        }
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
            status = "Restored connection; discovering services"
            restored.discoverServices([whoop5Service, heartRateService, batteryService])
        } else {
            status = "Restoring WHOOP connection"
            central.connect(restored)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (advertisedName ?? peripheral.name ?? "").lowercased()
        guard advertised.contains(whoop5Service)
                || name == "w"
                || name.contains("whoop")
                || name.contains("puffin") else { return }
        deviceName = advertisedName ?? peripheral.name ?? "WHOOP"
        record("Discovered \(deviceName), RSSI \(RSSI), services \(advertised.map(\.uuidString).joined(separator: ", "))")
        connect(peripheral, description: "WHOOP at RSSI \(RSSI)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionRetryTask?.cancel()
        connectionRetryTask = nil
        reconnectAttempt = 0
        resetConnectionSession()
        lastConnectedAt = .now
        status = "Connected; discovering services"
        record("Connected; discovering WHOOP 5 and Heart Rate services")
        peripheral.discoverServices([whoop5Service, heartRateService, batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let detail = error?.localizedDescription ?? "unknown error"
        status = "Connection failed: \(detail)"
        record("Connection failed: \(detail)")
        resetConnectionSession()
        scheduleReconnect(peripheral, reason: "connection failure")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if helloOutstanding { handshakeState = "Link dropped before CLIENT_HELLO acknowledgement" }
        let detail = error?.localizedDescription ?? "no error"
        record(helloOutstanding
            ? "Disconnected with CLIENT_HELLO outstanding: \(detail)"
            : "Disconnected: \(detail)")
        resetConnectionSession()
        status = "Disconnected: \(detail)"
        scheduleReconnect(peripheral, reason: "disconnect")
    }
}

extension WhoopHandshakeProbe: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Service discovery failed: \(error.localizedDescription)"
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
            status = "Characteristic discovery failed: \(error.localizedDescription)"
            record("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        record("Characteristics for \(service.uuid.uuidString): \((service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")
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
                batteryLevelCharacteristic = characteristic
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
        if commandCharacteristic != nil { status = "Ready for approved handshake" }
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
            status = "Encrypted handshake failed"
            record("CLIENT_HELLO refused: \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
        } else {
            handshakeState = "Acknowledged — encrypted link established"
            status = "Encrypted link active"
            UserDefaults.standard.set(true, forKey: confirmedBondKey)
            record("CLIENT_HELLO acknowledged; encrypted bond established")
            subscribeAfterHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            notificationState = "Failed: \(error.localizedDescription)"
            record("Notification subscription failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            if notifyUUIDs.contains(characteristic.uuid) {
                central.cancelPeripheralConnection(peripheral)
            }
        } else {
            let active = notifyCharacteristics.filter(\.isNotifying).count
            let hrActive = heartRateCharacteristic?.isNotifying == true
            notificationState = "WHOOP \(active)/\(notifyCharacteristics.count); HR \(hrActive ? "on" : "off")"
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
                      let charging = Self.batteryLevelStatusCharging(data) {
                hasExplicitChargingState = true
                isCharging = charging
                record("Battery charging: \(charging ? "yes" : "no") (Battery Level Status)")
            } else if uuid == batteryPowerStateUUID,
                      let charging = Self.legacyBatteryPowerStateCharging(data) {
                hasExplicitChargingState = true
                isCharging = charging
                record("Battery charging: \(charging ? "yes" : "no") (Battery Power State)")
            } else if notifyUUIDs.contains(uuid) {
                receivedProprietaryPacketCount += 1
                let packetOrdinal = receivedProprietaryPacketCount
                let frameType = data.count > 8 ? data[8] : nil
                if let isWorn = Self.freshWhoop5WristState(data, receivedAt: deliveredAt),
                   isWorn != lastObservedWristState {
                    lastObservedWristState = isWorn
                    WhoopNotificationManager.shared.observeWristState(isWorn: isWorn)
                    record("Wrist state: \(isWorn ? "on" : "off")")
                }
                let realtime = parseWhoop5Packet(data)
                let historical = parseWhoop5Historical(data)
                let bytes = [UInt8](data)
                let metadataType = bytes.count > 10
                    && (frameType == 49 || frameType == 56)
                    && WhoopFrameIntegrity.isValid(data)
                    ? bytes[10]
                    : nil
                let historicalEndData = metadataType == 2 && bytes.count >= 29
                    ? Array(bytes[21..<29])
                    : nil
                presentProprietaryPacket(
                    data,
                    characteristicUUID: characteristicUUID,
                    force: metadataType == 1 || (metadataType == 3 && historicalSyncActive)
                )
                // Count only forward movement through decoded history. The
                // band may replay the same packet or chunk ending thousands of
                // times while waiting for an acknowledgement; treating those
                // duplicates as progress would defeat the stall watchdog.
                if let sampleAt = historical?.sampleAt,
                   newestHistoricalSampleAtInSync.map({ sampleAt > $0 }) ?? true {
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
                    let needsMainActor = !result.success
                        || packetOrdinal.isMultiple(of: 250)
                        || historicalEndData != nil
                        || metadataType == 3
                    guard needsMainActor else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        guard result.success else {
                            self.record("Failed to persist WHOOP packet #\(packetOrdinal); history was not acknowledged")
                            return
                        }
                        if packetOrdinal.isMultiple(of: 250) {
                            self.persistedPacketCount = max(self.persistedPacketCount, packetOrdinal)
                        }
                        if let historicalEndData {
                            // The store queue is serial: reaching this completion proves every
                            // preceding raw and decoded sample in this chunk is durable.
                            if self.acknowledgeHistoricalChunk(endData: historicalEndData) {
                                self.refreshSleepSnapshot()
                            }
                        } else if metadataType == 3 {
                            guard self.historicalSyncActive || self.pendingProcessRequest != nil else {
                                return
                            }
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
                            if self.pendingProcessRequest != nil {
                                self.finalizeProcessRequest()
                            } else {
                                self.refreshSleepSnapshot(
                                    force: true,
                                    allowAutomaticFinalization: true
                                )
                            }
                            self.scheduleHistoricalSync()
                        }
                    }
                }
            }
    }
}
