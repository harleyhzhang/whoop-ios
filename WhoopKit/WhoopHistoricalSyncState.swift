import Foundation

/// Pure state machine for one persisted historical offload. Keeping these
/// transitions outside CoreBluetooth makes reconnect and timeout behavior
/// deterministic and directly testable.
struct WhoopHistoricalSyncState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case opening(WhoopConnectionSession.Token)
        case active(WhoopConnectionSession.Token, sessionID: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastProgressAt: Date?
    private(set) var newestSampleAt: Date?

    var isActive: Bool {
        phase != .idle
    }

    var sessionID: String? {
        guard case .active(_, let sessionID) = phase else { return nil }
        return sessionID
    }

    mutating func begin(for token: WhoopConnectionSession.Token, at date: Date) -> Bool {
        guard phase == .idle else { return false }
        phase = .opening(token)
        lastProgressAt = date
        newestSampleAt = nil
        return true
    }

    func isOpening(for token: WhoopConnectionSession.Token) -> Bool {
        phase == .opening(token)
    }

    mutating func activate(sessionID: String, for token: WhoopConnectionSession.Token) -> Bool {
        guard phase == .opening(token) else { return false }
        phase = .active(token, sessionID: sessionID)
        return true
    }

    mutating func observeHistoryStart(at date: Date) {
        guard isActive else { return }
        lastProgressAt = date
        newestSampleAt = nil
    }

    mutating func observe(sampleAt: Date, receivedAt: Date) {
        guard isActive, newestSampleAt.map({ sampleAt > $0 }) ?? true else { return }
        newestSampleAt = sampleAt
        lastProgressAt = receivedAt
    }

    func stalledDuration(at date: Date) -> TimeInterval? {
        guard isActive else { return nil }
        return lastProgressAt.map { date.timeIntervalSince($0) } ?? .infinity
    }

    @discardableResult
    mutating func reset() -> String? {
        let abandonedSessionID = sessionID
        phase = .idle
        lastProgressAt = nil
        newestSampleAt = nil
        return abandonedSessionID
    }
}
