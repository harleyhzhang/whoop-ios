@preconcurrency import CoreBluetooth
import Foundation
import OSLog
import Observation
import UIKit

@MainActor
@Observable
final class WhoopCollector: NSObject {
    private(set) var deviceName = "—"
    private(set) var handshakePhase = HandshakePhase.waitingForDevice
    private(set) var batteryLevel: Int?
    private(set) var batteryStatus = BatteryStatus.unavailable
    private(set) var isSleeping = false
    private(set) var lastConnectedAt: Date?
    @ObservationIgnored private var lastHeartRateReceivedAt: Date?
    @ObservationIgnored private var canAttemptHandshake = false

    var isCharging: Bool { batteryStatus.isCharging }

    var isConnected: Bool {
        peripheral?.state == .connected && handshakePhase.isAcknowledged
    }

    @ObservationIgnored private lazy var central = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [CBCentralManagerOptionRestoreIdentifierKey: "whoop.whoop-central"]
    )
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var commandCharacteristic: CBCharacteristic?
    @ObservationIgnored private var heartRateCharacteristic: CBCharacteristic?
    @ObservationIgnored private var connectionSession = WhoopConnectionSession()
    @ObservationIgnored private var transportIsBackpressured = false
    @ObservationIgnored private var lastObservedWristState: Bool?
    @ObservationIgnored private var notifyCharacteristics: [CBCharacteristic] = []
    @ObservationIgnored private var helloOutstanding = false
    @ObservationIgnored private var helloAttemptID: UUID?
    @ObservationIgnored private var commandSequence: UInt8 = 1
    @ObservationIgnored private var lastTelemetryCacheWriteAt: Date?
    @ObservationIgnored private var realtimeKeepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var historicalRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var historicalWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?
    @ObservationIgnored private let connectionRecovery = WhoopConnectionRecovery()
    @ObservationIgnored private var backgroundDrainTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var historicalSync = WhoopHistoricalSyncState()
    @ObservationIgnored private var lastAcknowledgedHistoricalEndData: [UInt8]?
    @ObservationIgnored private var lastHistoricalAcknowledgementAt: Date?
    @ObservationIgnored private var lastSleepAnalysisAt: Date?
    @ObservationIgnored private var lastFinalizedSleepID: String?
    @ObservationIgnored private weak var replicaScheduler: WhoopReplicaScheduling?
    private let store = WhoopStore.shared
    @ObservationIgnored private lazy var transportPipeline = WhoopTransportPipeline(
        store: store,
        didPublishUI: { [weak self] snapshot in
            DispatchQueue.main.async { [weak self] in
                self?.applyTransportUISnapshot(snapshot)
            }
        },
        didPersist: { [weak self] result, summary in
            DispatchQueue.main.async { [weak self] in
                self?.handlePersistedTransportBatch(result, summary: summary)
            }
        },
        didChangePressure: { [weak self] pressure in
            DispatchQueue.main.async { [weak self] in
                self?.handleTransportPressure(pressure)
            }
        }
    )
    private let knownPeripheralKey = "WhoopCollector.knownPeripheralIdentifier"
    private let confirmedBondKey = "WhoopCollector.confirmedEncryptedBond"
    private let cachedHeartRateKey = "WhoopCollector.cachedHeartRateBPM"
    private let cachedHeartRateDateKey = "WhoopCollector.cachedHeartRateDate"
    private let cachedBatteryLevelKey = "WhoopCollector.cachedBatteryLevel"
    private let cachedBatteryLevelDateKey = "WhoopCollector.cachedBatteryLevelDate"

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
    private static let logger = Logger(subsystem: "whoop", category: "WhoopHandshake")

    init(replicaScheduler: WhoopReplicaScheduling? = nil) {
        self.replicaScheduler = replicaScheduler
        super.init()
        WhoopCollectorPreferences.migrateLegacyKeys(in: .standard)
        restoreCachedTelemetry()
        record("Probe initialized")
        _ = central
    }

    deinit {
        realtimeKeepaliveTask?.cancel()
        historicalRefreshTask?.cancel()
        historicalWatchdogTask?.cancel()
        handshakeTask?.cancel()
    }

    func prepareForBackground() {
        connectionRecovery.submitPending()
        WhoopRuntimeDiagnostics.shared.recordEvent("background")
        guard backgroundDrainTask == .invalid else { return }
        backgroundDrainTask = UIApplication.shared.beginBackgroundTask(
            withName: "Persist pending WHOOP packets"
        ) { [weak self] in
            Task { @MainActor in self?.finishBackgroundDrain() }
        }
        transportPipeline.flushAndWaitForPersistence { [weak self] in
            Task { @MainActor in self?.finishBackgroundDrain() }
        }
    }

    private func finishBackgroundDrain() {
        guard backgroundDrainTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundDrainTask)
        backgroundDrainTask = .invalid
    }

    private func record(_ message: String) {
        Self.logger.debug("\(message, privacy: .public)")
    }

    private func restoreCachedTelemetry() {
        let defaults = UserDefaults.standard
        batteryLevel = WhoopBluetoothPolicy.cachedBatteryLevel(
            defaults.object(forKey: cachedBatteryLevelKey)
        )
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
                    WhoopRuntimeDiagnostics.shared.recordEvent("sleep published")
                    WhoopNotificationManager.shared.sendMorningSummary(for: record)
                    WhoopHealthHistoryEvents.post(.dayPublished(record))
                    self.replicaScheduler?.requestSync(reason: .sleepPublished)
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

    private func applyBatteryObservation(_ observation: BatteryObservation) {
        let observedStatus = observation.status
        guard let level = observation.level else {
            batteryStatus = observedStatus
            return
        }
        let effectiveStatus = WhoopBluetoothPolicy.inferredBatteryStatus(
            previousLevel: batteryLevel,
            currentLevel: level,
            currentStatus: observedStatus.isExplicit ? observedStatus : batteryStatus
        )
        batteryLevel = level
        batteryStatus = effectiveStatus
        UserDefaults.standard.set(level, forKey: cachedBatteryLevelKey)
        UserDefaults.standard.set(Date(), forKey: cachedBatteryLevelDateKey)
        WhoopNotificationManager.shared.observeBattery(
            BatteryObservation(level: level, status: effectiveStatus)
        )
    }

    private func applyTransportUISnapshot(_ snapshot: WhoopTransportUISnapshot) {
        if let heartRate = snapshot.heartRate,
            let receivedAt = snapshot.heartRateReceivedAt
        {
            cacheHeartRate(heartRate, receivedAt: receivedAt)
        }
        if let observation = snapshot.batteryObservation {
            applyBatteryObservation(observation)
            record("Battery level: \(batteryLevel ?? 0)%")
            record("Battery charging: \(batteryStatus.isCharging ? "yes" : "no")")
        }
    }

    private func handlePersistedTransportBatch(
        _ result: WhoopPacketBatchPersistenceResult,
        summary: WhoopTransportBatchSummary
    ) {
        guard result.success else {
            if let failure = result.failure {
                record(failure.localizedDescription)
            }
            if let first = summary.firstProprietaryOrdinal,
                let last = summary.lastProprietaryOrdinal
            {
                record(
                    "Failed to persist WHOOP packet batch #\(first)...#\(last); history was not acknowledged"
                )
            } else {
                record("Failed to persist standard 2A37 heart-rate packet batch")
            }
            return
        }
        if let isWorn = summary.latestWristState,
            isWorn != lastObservedWristState
        {
            lastObservedWristState = isWorn
            WhoopNotificationManager.shared.observeWristState(isWorn: isWorn)
            record("Wrist state: \(isWorn ? "on" : "off")")
        }
        replicaScheduler?.requestSync(reason: .dataChanged)
        let belongsToCurrentOffload =
            summary.offloadSessionID == nil
            || summary.offloadSessionID == historicalSync.sessionID
        guard belongsToCurrentOffload else {
            record("Ignoring post-commit control events from a superseded historical session")
            return
        }
        if let sampleAt = summary.latestHistoricalSampleAt {
            historicalSync.observe(sampleAt: sampleAt, receivedAt: .now)
        }
        for event in summary.metadataEvents {
            let metadata = WhoopHistoricalMetadata(
                type: event.type,
                chunkEndData: event.chunkEndData
            )
            if metadata.shouldForcePresentation(historicalSyncActive: historicalSync.isActive) {
                record(event.diagnostic)
            }
            switch event.type {
            case .historyStart:
                historicalSync.observeHistoryStart(at: .now)
                lastAcknowledgedHistoricalEndData = nil
                lastHistoricalAcknowledgementAt = nil
                startHistoricalWatchdog()
            case .chunkEnd:
                if let chunkEndData = event.chunkEndData {
                    _ = acknowledgeHistoricalChunk(endData: chunkEndData)
                }
            case .historyComplete:
                completeHistoricalSyncIfActive()
            case .unknown:
                break
            }
        }
    }

    private func handleTransportPressure(_ pressure: WhoopTransportPressureSnapshot) {
        transportIsBackpressured = pressure.isBackpressured
        record(
            pressure.isBackpressured
                ? "Transport persistence backpressure: \(pressure.queuedEnvelopeCount)/\(pressure.capacity) envelopes"
                : "Transport persistence backlog recovered"
        )
        if !pressure.isBackpressured, isConnected {
            scheduleHistoricalSync(after: .seconds(2))
        }
    }

    private func completeHistoricalSyncIfActive() {
        guard
            WhoopBluetoothPolicy.shouldAnalyzeHistoryCompletion(
                metadataType: .historyComplete,
                historicalSyncActive: historicalSync.isActive
            )
        else { return }
        historicalSync.reset()
        lastAcknowledgedHistoricalEndData = nil
        lastHistoricalAcknowledgementAt = nil
        historicalWatchdogTask?.cancel()
        historicalWatchdogTask = nil
        refreshSleepSnapshot(force: true, allowAutomaticFinalization: true)
        scheduleHistoricalSync()
    }

    func startScan() {
        guard central.state == .poweredOn else {
            record("Scan requested while Bluetooth state was \(central.state.rawValue)")
            return
        }
        central.stopScan()
        connectionRecovery.reset()
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        connectionSession.clear()
        resetConnectionSession()
        commandSequence = 1
        canAttemptHandshake = false
        handshakePhase = .waitingForDevice
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
        _ = connectionSession.select(candidate.identifier)
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
        let expectedSession = connectionSession.token()
        helloAttemptID = attemptID
        canAttemptHandshake = false
        handshakePhase = .writingClientHello
        record("Writing 16-byte CLIENT_HELLO with response to \(commandCharacteristic.uuid.uuidString)")
        peripheral.writeValue(clientHello, for: commandCharacteristic, type: .withResponse)

        handshakeTask?.cancel()
        handshakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                let self,
                self.helloOutstanding,
                self.helloAttemptID == attemptID,
                expectedSession.map(self.connectionSession.accepts) ?? false
            else { return }
            self.helloOutstanding = false
            self.helloAttemptID = nil
            self.handshakeTask = nil
            self.handshakePhase = .timedOut
            self.record("CLIENT_HELLO had no write callback after 8 seconds; resetting the link")
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func resetConnectionSession() {
        if let historicalSessionID = historicalSync.reset() {
            transportPipeline.flushAndWaitForPersistence { [store] in
                store.abandonHistoricalOffload(
                    historicalSessionID,
                    reason: "Bluetooth connection session reset"
                )
            }
        } else {
            transportPipeline.flush()
        }
        commandCharacteristic = nil
        heartRateCharacteristic = nil
        _ = connectionSession.resetKeepingPeripheral()
        batteryStatus = .unavailable
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
        lastAcknowledgedHistoricalEndData = nil
        lastHistoricalAcknowledgementAt = nil
        canAttemptHandshake = false
    }

    private func scheduleReconnect(_ candidate: CBPeripheral, reason: String) {
        guard central.state == .poweredOn, let token = connectionSession.token() else { return }
        record("Requesting reconnect after \(reason)")
        connectionRecovery.schedule(afterFailure: reason == "connection failure") { [weak self, weak candidate] in
            guard let self, let candidate,
                self.connectionSession.accepts(token), self.central.state == .poweredOn,
                self.peripheral?.identifier == candidate.identifier, candidate.state == .disconnected
            else { return }
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
        guard !transportIsBackpressured,
            !historicalSync.isActive,
            let peripheral,
            peripheral.state == .connected,
            handshakePhase.isAcknowledged,
            commandCharacteristic != nil
        else { return }
        let expectedPeripheralID = peripheral.identifier
        guard let expectedSession = connectionSession.token(),
            historicalSync.begin(for: expectedSession, at: .now)
        else { return }
        store.beginHistoricalOffload(peripheralID: expectedPeripheralID) { [weak self] result in
            Task { @MainActor in
                let sessionID = try? result.get()
                guard let self,
                    self.historicalSync.isOpening(for: expectedSession),
                    let sessionID,
                    self.connectionSession.accepts(expectedSession),
                    self.peripheral?.identifier == expectedPeripheralID,
                    let peripheral = self.peripheral,
                    peripheral.state == .connected,
                    let commandCharacteristic = self.commandCharacteristic
                else {
                    if case .failure(let failure) = result {
                        self?.record(failure.localizedDescription)
                        self?.scheduleHistoricalSync(after: .seconds(5))
                    }
                    if let sessionID {
                        self?.store.abandonHistoricalOffload(
                            sessionID,
                            reason: "connection changed before offload command"
                        )
                    }
                    self?.historicalSync.reset()
                    return
                }
                guard self.historicalSync.activate(sessionID: sessionID, for: expectedSession) else {
                    self.store.abandonHistoricalOffload(
                        sessionID,
                        reason: "offload state changed before command"
                    )
                    return
                }
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
                guard self.historicalSync.isActive else {
                    self.historicalWatchdogTask = nil
                    return
                }
                let stalledFor = self.historicalSync.stalledDuration(at: .now) ?? 0
                guard stalledFor >= 90 else { continue }

                self.record(
                    "Historical offload stalled for \(Int(stalledFor)) seconds; resetting the session and retrying")
                if let historicalSessionID = self.historicalSync.reset() {
                    self.store.abandonHistoricalOffload(
                        historicalSessionID,
                        reason: "no forward history progress for \(Int(stalledFor)) seconds"
                    )
                }
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
                    self.handshakePhase.isAcknowledged
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
        let expectedSession = connectionSession.token()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self,
                let expectedSession,
                self.connectionSession.accepts(expectedSession),
                self.canAttemptHandshake,
                !self.helloOutstanding,
                self.handshakePhase.canAutomaticallyAttempt
            else { return }
            self.record("Automatically reopening the previously confirmed encrypted bond")
            self.attemptHandshake()
        }
    }

    private func resumeConnection() {
        let state = WhoopConnectionResumePolicy.State(peripheral?.state)
        switch WhoopConnectionResumePolicy.action(for: state, hasServices: commandCharacteristic != nil) {
        case .scan: startScan()
        case .connect:
            if let peripheral { central.connect(peripheral) }
        case .discover:
            peripheral?.discoverServices([whoop5Service, heartRateService, batteryService])
        case .wait: break
        }
    }

    private func applyState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            record("Bluetooth powered on")
            resumeConnection()
        case .poweredOff:
            connectionRecovery.reset()
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

}

extension WhoopCollector: @preconcurrency CBCentralManagerDelegate {
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
        _ = connectionSession.select(restored.identifier)
        restored.delegate = self
        deviceName = restored.name ?? "WHOOP"
        UserDefaults.standard.set(restored.identifier.uuidString, forKey: knownPeripheralKey)
        WhoopRuntimeDiagnostics.shared.recordEvent("bluetooth restored")
        record("CoreBluetooth restored WHOOP [\(restored.identifier.uuidString)] in state \(restored.state.rawValue)")
        // The powered-on callback resumes this adopted peripheral. Starting a
        // new scan there would cancel the connection Core Bluetooth restored.
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
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else {
            record("Ignoring connect callback from a superseded peripheral")
            return
        }
        connectionRecovery.reset()
        resetConnectionSession()
        lastConnectedAt = .now
        WhoopRuntimeDiagnostics.shared.recordEvent("bluetooth connected")
        record("Connected; discovering WHOOP 5 and Heart Rate services")
        peripheral.discoverServices([whoop5Service, heartRateService, batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else {
            record("Ignoring failed-connect callback from a superseded peripheral")
            return
        }
        let detail = error?.localizedDescription ?? "unknown error"
        record("Connection failed: \(detail)")
        resetConnectionSession()
        scheduleReconnect(peripheral, reason: "connection failure")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else {
            record("Ignoring disconnect callback from a superseded peripheral")
            return
        }
        if helloOutstanding { handshakePhase = .disconnectedBeforeAcknowledgement }
        let detail = error?.localizedDescription ?? "no error"
        record(
            helloOutstanding
                ? "Disconnected with CLIENT_HELLO outstanding: \(detail)"
                : "Disconnected: \(detail)")
        resetConnectionSession()
        WhoopRuntimeDiagnostics.shared.recordEvent("bluetooth disconnected")
        scheduleReconnect(peripheral, reason: "disconnect")
    }
}

extension WhoopCollector: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else { return }
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
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else { return }
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
                handshakePhase = canAttemptHandshake ? .ready : .confirmedWritesUnavailable
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
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if characteristic.uuid == batteryPowerStateUUID {
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
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else { return }
        guard characteristic.uuid == commandUUID, helloOutstanding else { return }
        helloOutstanding = false
        helloAttemptID = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        canAttemptHandshake = true
        if let error {
            handshakePhase = .refused(reason: error.localizedDescription)
            record("CLIENT_HELLO refused: \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
        } else {
            handshakePhase = .acknowledged
            UserDefaults.standard.set(true, forKey: confirmedBondKey)
            record("CLIENT_HELLO acknowledged; encrypted bond established")
            subscribeAfterHandshake()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else { return }
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
        guard connectionSession.accepts(peripheralID: peripheral.identifier) else { return }
        let deliveredAt = Date()
        let data = characteristic.value
        let characteristicUUID = characteristic.uuid.uuidString
        let peripheralID = peripheral.identifier
        let errorDescription = error?.localizedDescription
        guard errorDescription == nil, let data else {
            record(
                "Value update failed for \(characteristicUUID): "
                    + (errorDescription ?? "notification contained no value")
            )
            return
        }
        let uuid = CBUUID(string: characteristicUUID)
        if uuid == CBUUID(string: "2A37") {
            transportPipeline.submitStandardHeartRate(
                packet: data,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                deliveredAt: deliveredAt
            )
        } else if uuid == batteryLevelUUID {
            transportPipeline.submitBatteryLevel(data, deliveredAt: deliveredAt)
        } else if uuid == batteryLevelStatusUUID {
            transportPipeline.submitBatteryLevelStatus(data, deliveredAt: deliveredAt)
        } else if uuid == batteryPowerStateUUID {
            transportPipeline.submitLegacyBatteryStatus(data, deliveredAt: deliveredAt)
        } else if notifyUUIDs.contains(uuid) {
            transportPipeline.submitProprietary(
                packet: data,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                offloadSessionID: historicalSync.sessionID,
                deliveredAt: deliveredAt
            )
        }
    }
}
