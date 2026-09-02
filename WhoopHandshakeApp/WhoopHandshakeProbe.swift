import CoreBluetooth
import Foundation

@MainActor
final class WhoopHandshakeProbe: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "Starting"
    @Published private(set) var status = "Waiting for Bluetooth"
    @Published private(set) var deviceName = "—"
    @Published private(set) var handshakeState = "Waiting for WHOOP 5"
    @Published private(set) var notificationState = "Not requested"
    @Published private(set) var heartRate = "—"
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isSleeping = false
    @Published private(set) var lastConnectedAt: Date?
    @Published private(set) var lastDataReceivedAt: Date?
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

    var diagnosticReport: String {
        (["WHOOP 5 handshake diagnostic", "Generated: \(Self.reportDateFormatter.string(from: .now))", ""] + diagnosticEvents)
            .joined(separator: "\n")
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryLevelCharacteristic: CBCharacteristic?
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var helloOutstanding = false
    private var helloAttemptID: UUID?
    private var commandSequence: UInt8 = 1
    private var lastTelemetryCacheWriteAt: Date?
    private var realtimeKeepaliveTask: Task<Void, Never>?
    private var historicalRefreshTask: Task<Void, Never>?
    private var historicalSyncActive = false
    private var lastAcknowledgedHistoricalEndData: [UInt8]?
    private var lastSleepAnalysisAt: Date?
    private var lastFinalizedSleepID: String?
    private let store = WhoopStore.shared
    private let knownPeripheralKey = "WhoopHandshakeProbe.knownPeripheralIdentifier"
    private let confirmedBondKey = "WhoopHandshakeProbe.confirmedEncryptedBond"
    private let cachedHeartRateKey = "WhoopHandshakeProbe.cachedHeartRateBPM"
    private let cachedHeartRateDateKey = "WhoopHandshakeProbe.cachedHeartRateDate"
    private let cachedBatteryLevelKey = "WhoopHandshakeProbe.cachedBatteryLevel"

    private let whoop5Service = CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A")
    private let heartRateService = CBUUID(string: "180D")
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
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
        if defaults.object(forKey: cachedBatteryLevelKey) != nil {
            batteryLevel = min(max(defaults.integer(forKey: cachedBatteryLevelKey), 0), 100)
        }
        if defaults.object(forKey: cachedHeartRateKey) != nil {
            let bpm = defaults.integer(forKey: cachedHeartRateKey)
            if bpm > 0 {
                heartRate = "\(bpm) bpm"
                lastDataReceivedAt = defaults.object(forKey: cachedHeartRateDateKey) as? Date
            }
        }

        store.loadLatestHeartRateSample { [weak self] sample in
            guard let sample else { return }
            Task { @MainActor in
                guard let self else { return }
                let cachedDate = self.lastDataReceivedAt ?? .distantPast
                guard sample.receivedAt > cachedDate else { return }
                self.cacheHeartRate(sample.heartRate, receivedAt: sample.receivedAt)
            }
        }
        refreshSleepSnapshot(force: true)
    }

    private func refreshSleepSnapshot(force: Bool = false) {
        let now = Date()
        guard force || lastSleepAnalysisAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else {
            return
        }
        lastSleepAnalysisAt = now
        store.refreshSleepSnapshot { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.isSleeping = snapshot.isSleeping
                if let record = snapshot.finalizedRecord,
                   record.sleepID != self.lastFinalizedSleepID {
                    self.lastFinalizedSleepID = record.sleepID
                    NotificationCenter.default.post(name: .whoopDailyHealthUpdated, object: nil)
                }
            }
        }
    }

    private func cacheHeartRate(_ bpm: Int, receivedAt: Date = .now) {
        guard bpm > 0 else { return }
        heartRate = "\(bpm) bpm"
        lastDataReceivedAt = receivedAt
        guard lastTelemetryCacheWriteAt.map({ receivedAt.timeIntervalSince($0) >= 30 }) ?? true else {
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(bpm, forKey: cachedHeartRateKey)
        defaults.set(receivedAt, forKey: cachedHeartRateDateKey)
        lastTelemetryCacheWriteAt = receivedAt
    }

    private func cacheBatteryLevel(_ level: Int) {
        let clampedLevel = min(max(level, 0), 100)
        batteryLevel = clampedLevel
        UserDefaults.standard.set(clampedLevel, forKey: cachedBatteryLevelKey)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "Bluetooth is not ready"
            record("Scan requested while Bluetooth was \(bluetoothState)")
            return
        }
        central.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        commandCharacteristic = nil
        heartRateCharacteristic = nil
        batteryLevelCharacteristic = nil
        notifyCharacteristics = []
        helloOutstanding = false
        helloAttemptID = nil
        realtimeKeepaliveTask?.cancel()
        realtimeKeepaliveTask = nil
        historicalRefreshTask?.cancel()
        historicalRefreshTask = nil
        historicalSyncActive = false
        lastAcknowledgedHistoricalEndData = nil
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

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self,
                  self.helloOutstanding,
                  self.helloAttemptID == attemptID else { return }
            self.handshakeState = "Pairing still in progress after 8 seconds"
            self.status = "Awaiting CoreBluetooth write result"
            self.record("CLIENT_HELLO has no write callback after 8 seconds; preserving the outstanding attempt for a late pairing result")
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
              let commandCharacteristic else { return }
        historicalSyncActive = true
        commandSequence &+= 1
        let frame = Self.puffinCommandFrame(cmd: 22, seq: commandSequence, payload: [0x00])
        record("Starting persisted WHOOP historical offload, seq \(commandSequence)")
        peripheral.writeValue(Data(frame), for: commandCharacteristic, type: .withResponse)
    }

    @discardableResult
    private func acknowledgeHistoricalChunk(endData: [UInt8]) -> Bool {
        guard endData.count == 8,
              endData != lastAcknowledgedHistoricalEndData,
              let peripheral,
              peripheral.state == .connected,
              let commandCharacteristic else { return false }
        lastAcknowledgedHistoricalEndData = endData
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

    private func parseHeartRate(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let flags = bytes[0]
        let isUInt16 = flags & 0x01 != 0
        var index = 1
        let bpm: Int
        if isUInt16, bytes.count >= 3 {
            bpm = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            index = 3
        } else {
            bpm = Int(bytes[1])
            index = 2
        }
        cacheHeartRate(bpm)
        if flags & 0x08 != 0 { index += 2 }
        guard flags & 0x10 != 0 else {
            rrSummary = "No R–R values"
            return
        }
        var values: [Double] = []
        while index + 1 < bytes.count {
            let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            values.append(Double(raw) / 1024 * 1000)
            index += 2
        }
        rrSummary = values.map { String(format: "%.0f ms", $0) }.joined(separator: ", ")
        record("Heart rate packet: \(heartRate), R–R \(rrSummary)")
    }

    @discardableResult
    private func parseWhoop5Packet(_ data: Data) -> WhoopDecodedRealtime? {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else {
            latestPacket = "Short frame (\(bytes.count) B)"
            return nil
        }
        let type = bytes[8]
        latestPacket = String(format: "Type 0x%02X · %d B", type, bytes.count)

        // WHOOP 5 type-40 REALTIME_DATA: timestamp@10, heart rate@16,
        // R–R count@17, then little-endian millisecond intervals@18+.
        guard type == 0x28, bytes.count >= 18 else { return nil }
        cacheHeartRate(Int(bytes[16]))
        let count = min(Int(bytes[17]), (bytes.count - 18) / 2)
        var values: [UInt16] = []
        for index in 0..<count {
            let offset = 18 + index * 2
            values.append(UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
        }
        rrSummary = values.isEmpty
            ? "No R–R values"
            : values.map { "\($0) ms" }.joined(separator: ", ")
        record("WHOOP 5 realtime decoded: \(heartRate), R–R \(rrSummary)")
        let timestamp = UInt32(bytes[10])
            | (UInt32(bytes[11]) << 8)
            | (UInt32(bytes[12]) << 16)
            | (UInt32(bytes[13]) << 24)
        return WhoopDecodedRealtime(
            deviceTimestamp: timestamp,
            heartRate: Int(bytes[16]),
            rrIntervals: values
        )
    }

    private func parseWhoop5Historical(_ data: Data) -> WhoopDecodedHistorical? {
        WhoopDecodedHistorical.decode(data)
    }

    private static func frameCRCIsValid(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12 else { return false }
        let payloadEnd = bytes.count - 4
        let expected = UInt32(bytes[payloadEnd])
            | (UInt32(bytes[payloadEnd + 1]) << 8)
            | (UInt32(bytes[payloadEnd + 2]) << 16)
            | (UInt32(bytes[payloadEnd + 3]) << 24)
        return crc32(Array(bytes[8..<payloadEnd])) == expected
    }
}

extension WhoopHandshakeProbe: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in applyState(central.state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        Task { @MainActor in
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
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
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
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            lastConnectedAt = .now
            status = "Connected; discovering services"
            record("Connected; discovering WHOOP 5 and Heart Rate services")
            peripheral.discoverServices([whoop5Service, heartRateService, batteryService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let detail = error?.localizedDescription ?? "unknown error"
            status = "Connection failed: \(detail)"
            record("Connection failed: \(detail)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if helloOutstanding { handshakeState = "Link dropped before CLIENT_HELLO acknowledgement" }
            let detail = error?.localizedDescription ?? "no error"
            record(helloOutstanding
                ? "Disconnected with CLIENT_HELLO outstanding: \(detail)"
                : "Disconnected: \(detail)")
            helloOutstanding = false
            helloAttemptID = nil
            realtimeKeepaliveTask?.cancel()
            realtimeKeepaliveTask = nil
            historicalRefreshTask?.cancel()
            historicalRefreshTask = nil
            historicalSyncActive = false
            lastAcknowledgedHistoricalEndData = nil
            canAttemptHandshake = false
            status = "Disconnected: \(detail)"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self,
                      self.central.state == .poweredOn,
                      self.peripheral?.identifier == peripheral.identifier,
                      peripheral.state == .disconnected else { return }
                self.status = "Reconnecting automatically"
                self.record("Reconnecting to saved WHOOP after disconnect")
                self.central.connect(peripheral)
            }
        }
    }
}

extension WhoopHandshakeProbe: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                status = "Service discovery failed: \(error.localizedDescription)"
                record("Service discovery failed: \(error.localizedDescription)")
                return
            }
            record("Discovered services: \((peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                status = "Characteristic discovery failed: \(error.localizedDescription)"
                record("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
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
                } else if notifyUUIDs.contains(characteristic.uuid) {
                    notifyCharacteristics.append(characteristic)
                }
            }
            if commandCharacteristic != nil { status = "Ready for approved handshake" }
            if commandCharacteristic != nil { scheduleAutomaticHandshakeIfTrusted() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == commandUUID, helloOutstanding else { return }
            helloOutstanding = false
            helloAttemptID = nil
            canAttemptHandshake = true
            if let error {
                handshakeState = "Refused: \(error.localizedDescription)"
                status = "Encrypted handshake failed"
                record("CLIENT_HELLO refused: \(error.localizedDescription)")
            } else {
                handshakeState = "Acknowledged — encrypted link established"
                status = "Encrypted link active"
                UserDefaults.standard.set(true, forKey: confirmedBondKey)
                record("CLIENT_HELLO acknowledged; encrypted bond established")
                subscribeAfterHandshake()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                notificationState = "Failed: \(error.localizedDescription)"
                record("Notification subscription failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            } else {
                let active = notifyCharacteristics.filter(\.isNotifying).count
                let hrActive = heartRateCharacteristic?.isNotifying == true
                notificationState = "WHOOP \(active)/\(notifyCharacteristics.count); HR \(hrActive ? "on" : "off")"
                record("Notification state \(characteristic.uuid.uuidString): \(characteristic.isNotifying ? "on" : "off")")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil, let data = characteristic.value else { return }
            if characteristic.uuid == CBUUID(string: "2A37") {
                parseHeartRate(data)
                lastDataReceivedAt = .now
            } else if characteristic.uuid == batteryLevelUUID, let level = data.first {
                cacheBatteryLevel(Int(level))
                record("Battery level: \(batteryLevel ?? 0)%")
            } else if notifyUUIDs.contains(characteristic.uuid) {
                proprietaryPacketCount += 1
                lastDataReceivedAt = .now
                let preview = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
                record("WHOOP packet #\(proprietaryPacketCount) on \(characteristic.uuid.uuidString), \(data.count) bytes: \(preview)\(data.count > 24 ? " …" : "")")
                let frameType = data.count > 8 ? data[8] : nil
                let realtime = parseWhoop5Packet(data)
                let historical = parseWhoop5Historical(data)
                let bytes = [UInt8](data)
                let metadataType = bytes.count > 10 && frameType == 49 && Self.frameCRCIsValid(bytes)
                    ? bytes[10]
                    : nil
                let historicalEndData = metadataType == 2 && bytes.count >= 29
                    ? Array(bytes[21..<29])
                    : nil
                if metadataType == 1 {
                    historicalSyncActive = true
                    lastAcknowledgedHistoricalEndData = nil
                }
                store.append(
                    packet: data,
                    peripheralID: peripheral.identifier,
                    characteristicUUID: characteristic.uuid.uuidString,
                    frameType: frameType,
                    realtime: realtime,
                    historical: historical
                ) { [weak self] success in
                    guard success else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        self.persistedPacketCount += 1
                        if let historicalEndData {
                            // The store queue is serial: reaching this completion proves every
                            // preceding raw and decoded sample in this chunk is durable.
                            if self.acknowledgeHistoricalChunk(endData: historicalEndData) {
                                self.refreshSleepSnapshot()
                            }
                        } else if metadataType == 3 {
                            self.historicalSyncActive = false
                            self.refreshSleepSnapshot(force: true)
                            self.scheduleHistoricalSync()
                        }
                    }
                }
            }
        }
    }
}
