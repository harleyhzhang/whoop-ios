import Foundation

extension WhoopStore {
    func recordDeviceClockReference(_ reference: WhoopDeviceClock.Reference) {
        queue.async { [self] in
            guard let database, let data = try? JSONEncoder().encode(reference),
                let json = String(data: data, encoding: .utf8)
            else { return }
            _ = setMetadataValue(
                database: database,
                key: "device-clock.read147.v1.\(reference.peripheralID).\(reference.id)", value: json)
        }
    }
}
