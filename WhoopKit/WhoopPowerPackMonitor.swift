@preconcurrency import CoreBluetooth
import Foundation
import OSLog
import Observation

enum WhoopPowerPackPolicy {
    static let serviceUUID = "11500001-6215-11EE-8C99-0242AC120002"

    static func matchesAdvertisement(
        serviceUUIDs: Set<String>,
        advertisedName: String?,
        peripheralName: String?
    ) -> Bool {
        if serviceUUIDs.contains(where: { $0.caseInsensitiveCompare(serviceUUID) == .orderedSame }) {
            return true
        }
        let name = advertisedName ?? peripheralName ?? ""
        return name.uppercased().hasPrefix("WBB5BP")
    }

    static func batteryLevel(_ data: Data) -> Int? {
        guard let rawLevel = data.first, rawLevel <= 100 else { return nil }
        return Int(rawLevel)
    }

}

@MainActor
@Observable
final class WhoopPowerPackMonitor: NSObject {
    private var batteryState = WhoopBatteryState()
    var batteryLevel: Int? { batteryState.level }
    var isCharging: Bool { batteryState.status.isCharging }

    @ObservationIgnored private lazy var central = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [
            CBCentralManagerOptionRestoreIdentifierKey:
                "whoop.powerpack-central"
        ]
    )
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var batteryCharacteristic: CBCharacteristic?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    private let powerPackService = CBUUID(string: WhoopPowerPackPolicy.serviceUUID)
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let batteryLevelStatusUUID = CBUUID(string: "2BED")
    private let batteryPowerStateUUID = CBUUID(string: "2A1A")
    private let cachedBatteryLevelKey = "WhoopPowerPackMonitor.cachedBatteryLevel"
    private let cachedBatteryLevelDateKey = "WhoopPowerPackMonitor.cachedBatteryLevelDate"
    private static let logger = Logger(
        subsystem: "whoop",
        category: "WhoopPowerPack"
    )

    override init() {
        super.init()
        restoreCachedBatteryLevel()
        _ = central
    }

    deinit {
        pollingTask?.cancel()
        reconnectTask?.cancel()
    }

    func refresh() {
        batteryState.expireInference()
        guard central.state == .poweredOn else { return }
        if let peripheral {
            switch peripheral.state {
            case .connected:
                if batteryCharacteristic != nil {
                    WhoopBatteryGATT.refresh(peripheral)
                } else {
                    peripheral.discoverServices([batteryService])
                }
                return
            case .connecting:
                return
            case .disconnecting, .disconnected:
                self.peripheral = nil
                batteryCharacteristic = nil
            @unknown default:
                self.peripheral = nil
                batteryCharacteristic = nil
            }
        }
        discoverPowerPack()
    }

    private func restoreCachedBatteryLevel() {
        let defaults = UserDefaults.standard
        batteryState = WhoopBatteryState(
            cachedLevel: WhoopBluetoothPolicy.cachedBatteryLevel(defaults.object(forKey: cachedBatteryLevelKey))
        )
    }

    private func discoverPowerPack() {
        guard central.state == .poweredOn else { return }
        reconnectTask?.cancel()
        reconnectTask = nil

        if let connected = central.retrieveConnectedPeripherals(withServices: [powerPackService]).first {
            connect(connected)
            return
        }

        Self.logger.debug("Scanning for WHOOP Wireless PowerPack")
        central.stopScan()
        central.scanForPeripherals(withServices: [powerPackService])
    }

    private func connect(_ candidate: CBPeripheral) {
        guard peripheral == nil || peripheral?.identifier == candidate.identifier else { return }
        peripheral = candidate
        candidate.delegate = self
        central.stopScan()
        Self.logger.debug(
            "Connecting to PowerPack \(candidate.identifier.uuidString, privacy: .public)"
        )
        central.connect(candidate)
    }

    private func applyBatteryLevel(_ data: Data) {
        guard let level = WhoopPowerPackPolicy.batteryLevel(data) else {
            Self.logger.error("Ignoring invalid PowerPack battery payload")
            return
        }
        batteryState.observe(BatteryObservation(level: level, status: .unavailable))
        let defaults = UserDefaults.standard
        defaults.set(level, forKey: cachedBatteryLevelKey)
        defaults.set(Date(), forKey: cachedBatteryLevelDateKey)
        Self.logger.debug("PowerPack battery: \(level, privacy: .public)%")
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    private func resetChargingState() {
        pollingTask?.cancel()
        pollingTask = nil
        batteryState.resetConnection()
    }

    private func scheduleRediscovery() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.discoverPowerPack()
        }
    }
}

extension WhoopPowerPackMonitor: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            discoverPowerPack()
        } else {
            resetChargingState()
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard
            let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?
                .first
        else { return }
        peripheral = restored
        restored.delegate = self
        if restored.state == .connected {
            startPolling()
            restored.discoverServices([batteryService])
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
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard
            WhoopPowerPackPolicy.matchesAdvertisement(
                serviceUUIDs: Set(services.map(\.uuidString)),
                advertisedName: advertisedName,
                peripheralName: peripheral.name
            )
        else { return }
        Self.logger.debug(
            "Discovered PowerPack at RSSI \(RSSI.intValue, privacy: .public)"
        )
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        batteryState.resetConnection()
        startPolling()
        Self.logger.debug("Connected to PowerPack; discovering battery service")
        peripheral.discoverServices([batteryService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        Self.logger.error(
            "PowerPack connection failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)"
        )
        resetChargingState()
        self.peripheral = nil
        batteryCharacteristic = nil
        scheduleRediscovery()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        Self.logger.debug("PowerPack disconnected")
        resetChargingState()
        self.peripheral = nil
        batteryCharacteristic = nil
        scheduleRediscovery()
    }
}

extension WhoopPowerPackMonitor: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil,
            let service = peripheral.services?.first(where: { $0.uuid == batteryService })
        else {
            Self.logger.error("PowerPack battery service discovery failed")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [batteryLevelUUID, batteryLevelStatusUUID, batteryPowerStateUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
            service.uuid == batteryService,
            error == nil,
            let characteristic = service.characteristics?.first(where: {
                $0.uuid == batteryLevelUUID
            })
        else {
            Self.logger.error("PowerPack battery characteristic discovery failed")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        batteryCharacteristic = characteristic
        for characteristic in service.characteristics ?? []
        where WhoopBatteryGATT.characteristicUUIDs.contains(characteristic.uuid) {
            WhoopBatteryGATT.subscribe(characteristic, on: peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
            error == nil,
            let data = characteristic.value
        else { return }
        if characteristic.uuid == batteryLevelUUID {
            applyBatteryLevel(data)
        } else {
            let status: BatteryStatus?
            if characteristic.uuid == batteryLevelStatusUUID {
                status = WhoopBluetoothPolicy.batteryLevelStatus(data)
            } else if characteristic.uuid == batteryPowerStateUUID {
                status = WhoopBluetoothPolicy.legacyBatteryStatus(data)
            } else {
                return
            }
            if let status {
                batteryState.observe(BatteryObservation(level: nil, status: status))
            }
        }
    }
}
