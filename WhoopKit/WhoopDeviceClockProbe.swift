@preconcurrency import CoreBluetooth
import CryptoKit
import Foundation

/// Read-only acquisition is independent of retired motion calibration. At most
/// one small request per four minutes; failed/unsupported firmware retries no
/// faster than one minute. A reconnect invalidates all prior authority.
@MainActor
final class WhoopDeviceClockProbe {
    private var policy = WhoopDeviceClock()
    private var token: WhoopConnectionSession.Token?
    private var lastAttempt: TimeInterval?
    private var lastAccepted: TimeInterval?

    func reset(_ token: WhoopConnectionSession.Token?) {
        self.token = token
        policy.reset(token)
        lastAttempt = nil
        lastAccepted = nil
    }
    func requestIfDue(
        peripheral: CBPeripheral, characteristic: CBCharacteristic,
        token: WhoopConnectionSession.Token, sequence: inout UInt8,
        now: Date = .now, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if self.token != token { reset(token) }
        guard lastAttempt.map({ uptime - $0 >= 60 }) ?? true,
            lastAccepted.map({ uptime - $0 >= 240 }) ?? true
        else { return }
        sequence &+= 1
        policy.requested(token: token, origin: sequence, at: now, uptime: uptime)
        lastAttempt = uptime
        peripheral.writeValue(
            Data(WhoopCommand.readDeviceClock.frame(sequence: sequence)),
            for: characteristic, type: .withResponse)
    }
    func persisted(_ summary: WhoopTransportBatchSummary, store: WhoopStore) -> Bool? {
        guard let token = summary.connectionToken, token == self.token else { return nil }
        var state: Bool?
        // FIFO: a reference cannot retroactively bless an earlier wrist event.
        for envelope in summary.clockEnvelopes {
            guard let uptime = envelope.receivedUptime else { continue }
            if case .reply(let reply) = WhoopMotionProtocol.event(envelope),
                let reference = policy.receive(
                    reply, token: token, uptime: uptime,
                    sourceSHA256: SHA256.hash(data: envelope.packet).map({ String(format: "%02x", $0) }).joined())
            {
                lastAccepted = uptime
                store.recordDeviceClockReference(reference)
            }
            if let next = policy.wristState(
                packet: envelope.packet, token: token,
                receivedAt: envelope.deliveredAt, uptime: uptime)
            {
                state = next
            }
        }
        return state
    }
}
