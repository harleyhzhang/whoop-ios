import Foundation

/// A read-only reference for this exact Bluetooth connection. Raw timestamps
/// are never changed. The bounds express reference confidence, not clock repair.
struct WhoopDeviceClock {
    struct Reference: Codable, Sendable {
        let id: UUID
        let peripheralID: UUID
        let generation: UInt64
        let origin: UInt8
        let sentAt: Date
        let receivedAt: Date
        let deviceAt: Date
        let receivedUptime: TimeInterval
        let roundTripSeconds: TimeInterval
        let offsetSeconds: TimeInterval
        let uncertaintySeconds: TimeInterval
        let sourceSHA256: String
    }
    private struct Pending {
        let token: WhoopConnectionSession.Token
        let origin: UInt8
        let sentAt: Date
        let uptime: TimeInterval
    }
    private var pending: Pending?
    private(set) var reference: Reference?
    private var token: WhoopConnectionSession.Token?
    private var lastEventAt: Date?
    static let maximumReferenceAge: TimeInterval = 300

    mutating func reset(_ token: WhoopConnectionSession.Token?) {
        self.token = token
        pending = nil
        reference = nil
        lastEventAt = nil
    }
    mutating func requested(token: WhoopConnectionSession.Token, origin: UInt8, at: Date, uptime: TimeInterval) {
        if self.token != token { reset(token) }
        pending = Pending(token: token, origin: origin, sentAt: at, uptime: uptime)
    }
    mutating func receive(
        _ reply: WhoopMotionProtocol.Reply, token: WhoopConnectionSession.Token,
        uptime: TimeInterval, sourceSHA256: String
    ) -> Reference? {
        guard self.token == token, let pending, pending.token == token,
            reply.command == 147, reply.origin == pending.origin
        else { return nil }
        let elapsed = uptime - pending.uptime
        let wallElapsed = reply.receivedAt.timeIntervalSince(pending.sentAt)
        guard (0...1).contains(elapsed), abs(elapsed - wallElapsed) <= 0.1 else {
            self.pending = nil
            return nil
        }
        if reply.result == 2 { return nil }
        self.pending = nil
        guard reply.result == 0, let deviceAt = reply.deviceClock else { return nil }
        let midpoint = pending.sentAt.addingTimeInterval(elapsed / 2)
        let offset = midpoint.timeIntervalSince(deviceAt)
        guard abs(offset) <= 24 * 3600 else { return nil }
        let accepted = Reference(
            id: UUID(), peripheralID: token.peripheralID, generation: token.generation,
            origin: reply.origin, sentAt: pending.sentAt, receivedAt: reply.receivedAt, deviceAt: deviceAt,
            receivedUptime: uptime, roundTripSeconds: elapsed, offsetSeconds: offset,
            uncertaintySeconds: elapsed / 2 + 1.0 / 32768, sourceSHA256: sourceSHA256)
        reference = accepted
        return accepted
    }
    mutating func wristState(
        packet: Data, token: WhoopConnectionSession.Token, receivedAt: Date,
        uptime: TimeInterval
    ) -> Bool? {
        let packet = Data(packet)
        guard self.token == token, let reference, packet.count >= 20,
            packet[8] == 48, WhoopFrameIntegrity.isValid(packet)
        else { return nil }
        let age = uptime - reference.receivedUptime
        let wallAge = receivedAt.timeIntervalSince(reference.receivedAt)
        guard (0...Self.maximumReferenceAge).contains(age), abs(age - wallAge) <= 0.1 else { return nil }
        let raw = UInt32(packet[12]) | UInt32(packet[13]) << 8 | UInt32(packet[14]) << 16 | UInt32(packet[15]) << 24
        let eventAt = Date(timeIntervalSince1970: Double(raw) + reference.offsetSeconds)
        // One-second event quantization plus a conservative 100ppm drift budget.
        let uncertainty = reference.uncertaintySeconds + 1 + age * 0.0001
        guard abs(receivedAt.timeIntervalSince(eventAt)) + uncertainty <= 45,
            lastEventAt.map({ eventAt >= $0 }) ?? true
        else { return nil }
        let state: Bool
        switch packet[10] {
        case 9: state = true
        case 10: state = false
        default: return nil
        }
        lastEventAt = eventAt
        return state
    }
}
