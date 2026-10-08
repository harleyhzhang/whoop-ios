import CoreBluetooth
import Foundation

/// Keeps retry timing out of the Bluetooth delegate. A normal disconnect submits
/// a persistent system request immediately; failed attempts back off. If the app
/// backgrounds during that delay, submit the pending request before suspension.
@MainActor
final class WhoopConnectionRecovery {
    private var retryTask: Task<Void, Never>?
    private var pending: (() -> Void)?
    private var attempt = 0

    deinit { retryTask?.cancel() }

    func reset() {
        retryTask?.cancel()
        retryTask = nil
        pending = nil
        attempt = 0
    }

    func schedule(afterFailure: Bool, connect: @escaping () -> Void) {
        retryTask?.cancel()
        pending = connect
        guard afterFailure else {
            submitPending()
            return
        }
        let delay = WhoopReconnectPolicy.delaySeconds(forAttempt: attempt)
        attempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.submitPending()
        }
    }

    func submitPending() {
        retryTask?.cancel()
        retryTask = nil
        let connect = pending
        pending = nil
        connect?()
    }
}

extension WhoopConnectionResumePolicy.State {
    init(_ state: CBPeripheralState?) {
        switch state {
        case .none: self = .absent
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnecting: self = .disconnecting
        @unknown default: self = .disconnecting
        }
    }
}
