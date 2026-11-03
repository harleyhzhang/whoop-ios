@preconcurrency import CoreBluetooth

/// Refresh read-only charge characteristics even when a device omits notifications.
@MainActor
enum WhoopBatteryGATT {
    static let characteristicUUIDs = ["2A19", "2BED", "2A1A"].map { CBUUID(string: $0) }

    static func refresh(_ peripheral: CBPeripheral?) {
        guard let peripheral, peripheral.state == .connected else { return }
        for characteristic in peripheral.services?.flatMap({ $0.characteristics ?? [] }) ?? []
        where characteristicUUIDs.contains(characteristic.uuid) && characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
    }

    static func subscribe(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        if characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }
}
