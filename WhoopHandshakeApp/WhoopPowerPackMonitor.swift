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

    static func cachedLevelIsFresh(
        observedAt: Date,
        now: Date,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60
    ) -> Bool {
        now.timeIntervalSince(observedAt) <= maximumAge
    }
}

@MainActor
@Observable
final class WhoopPowerPackMonitor: NSObject {
    private(set) var batteryLevel: Int?

    @ObservationIgnored private lazy var central = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [
            CBCentralManagerOptionRestoreIdentifierKey:
                "com.clintonst.sleep.powerpack-central"
        ]
    )
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var batteryCharacteristic: CBCharacteristic?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    private let powerPackService = CBUUID(string: WhoopPowerPackPolicy.serviceUUID)
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let cachedBatteryLevelKey = "WhoopPowerPackMonitor.cachedBatteryLevel"
    private let cachedBatteryLevelDateKey = "WhoopPowerPackMonitor.cachedBatteryLevelDate"
    private static let logger = Logger(
        subsystem: "com.clintonst.sleep",
        category: "WhoopPowerPack"
    )

    override init() {
        super.init()
        restoreCachedBatteryLevel()
        _ = central
    }

    deinit {
        reconnectTask?.cancel()
    }

    func refresh() {
        guard central.state == .poweredOn else { return }
        if let peripheral {
            switch peripheral.state {
            case .connected:
                if let batteryCharacteristic {
                    peripheral.readValue(for: batteryCharacteristic)
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
        guard defaults.object(forKey: cachedBatteryLevelKey) != nil,
            let observedAt = defaults.object(forKey: cachedBatteryLevelDateKey) as? Date,
            WhoopPowerPackPolicy.cachedLevelIsFresh(observedAt: observedAt, now: .now)
        else { return }
        batteryLevel = min(max(defaults.integer(forKey: cachedBatteryLevelKey), 0), 100)
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
        batteryLevel = level
        let defaults = UserDefaults.standard
        defaults.set(level, forKey: cachedBatteryLevelKey)
        defaults.set(Date(), forKey: cachedBatteryLevelDateKey)
        Self.logger.debug("PowerPack battery: \(level, privacy: .public)%")
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
        peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
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
        if characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
            characteristic.uuid == batteryLevelUUID,
            error == nil,
            let data = characteristic.value
        else { return }
        applyBatteryLevel(data)
    }
}
