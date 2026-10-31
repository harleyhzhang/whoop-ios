@preconcurrency import CoreBluetooth
import Foundation

/// Framework writes stay in a small adapter, independent of clock-reference and
/// historical-offload policy. The keepalive never enables high-rate motion.
@MainActor
enum WhoopLiveStream {
    static func arm(
        peripheral: CBPeripheral, characteristic: CBCharacteristic,
        sequence: inout UInt8, record: (String) -> Void
    ) {
        sequence &+= 1
        let sensorFrame = WhoopCommand.realtimeSensors(enabled: false).frame(sequence: sequence)
        record("Disabling battery-heavy SEND_R10_R11_REALTIME burst, seq \(sequence): \(hex(sensorFrame))")
        peripheral.writeValue(Data(sensorFrame), for: characteristic, type: .withoutResponse)
        sequence &+= 1
        let heartRateFrame = WhoopCommand.realtimeHeartRate(enabled: true).frame(sequence: sequence)
        record("Sending reversible TOGGLE_REALTIME_HR(1), seq \(sequence): \(hex(heartRateFrame))")
        peripheral.writeValue(Data(heartRateFrame), for: characteristic, type: .withoutResponse)
    }
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
