@preconcurrency import CoreBluetooth
import CryptoKit
import Foundation

/// Correlated clock acquisition and factory-reset recovery, independent of
/// retired motion calibration. Healthy clocks are read every four minutes.
@MainActor
final class WhoopDeviceClockProbe {
    private var policy = WhoopDeviceClock()
    private var token: WhoopConnectionSession.Token?
    private var lastAttempt: TimeInterval?
    private var lastAccepted: TimeInterval?
    private var verifyingInitialization = false
    private var recoveryConfirmed = false
    private var awaitingFreshHistory = false

    var historyRefreshDelay: Duration { awaitingFreshHistory ? .seconds(90) : .seconds(15 * 60) }

    func reset(_ token: WhoopConnectionSession.Token?) {
        self.token = token
        policy.reset(token)
        lastAttempt = nil
        lastAccepted = nil
        verifyingInitialization = false
        recoveryConfirmed = false
    }
    func requestIfDue(
        peripheral: CBPeripheral, characteristic: CBCharacteristic,
        token: WhoopConnectionSession.Token, sequence: inout UInt8,
        now: Date = .now, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if self.token != token { reset(token) }
        if let command = policy.initializationCommand(now: now, uptime: uptime) {
            sequence &+= 1
            peripheral.writeValue(Data(command.frame(sequence: sequence)), for: characteristic, type: .withResponse)
            verifyingInitialization = true
            lastAttempt = nil
            lastAccepted = nil
            WhoopRuntimeDiagnostics.shared.recordEvent(
                "WHOOP factory clock initialization requested; awaiting readback")
        }
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
        if let sampleAt = summary.latestHistoricalSampleAt,
            (0...300).contains(Date.now.timeIntervalSince(sampleAt))
        {
            awaitingFreshHistory = false
        }
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
                if verifyingInitialization, abs(reference.offsetSeconds) <= 2 {
                    recoveryConfirmed = true
                    awaitingFreshHistory = true
                    verifyingInitialization = false
                    WhoopRuntimeDiagnostics.shared.recordEvent(
                        "WHOOP factory clock recovery verified by correlated readback")
                }
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

    func consumeRecoveryHistoryDelay() -> Duration? {
        guard recoveryConfirmed else { return nil }
        defer { recoveryConfirmed = false }
        // Give firmware time to commit its first fresh flash block.
        return historyRefreshDelay
    }
}
