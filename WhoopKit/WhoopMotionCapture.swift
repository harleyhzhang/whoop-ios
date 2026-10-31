import Foundation
import OSLog
import Observation
import UIKit

/// Preserved legacy session metadata. No new recordings are created. Original
/// notifications remain in the durable raw-packet
/// store; reconstructed frames link their hashes, characteristic and source hashes.
final class WhoopMotionCaptureJournal {
    struct Document: Codable {
        var schemaVersion = 1
        var pendingSessionID: UUID?
        var sessions: [WhoopMotionCaptureState] = []
    }

    let directory: URL
    private var cached: Document?
    private var url: URL { directory.appendingPathComponent("motion-calibration.json") }

    init(directory: URL) { self.directory = directory }

    private func document() throws -> Document {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let decoded = try JSONDecoder().decode(Document.self, from: data)
        guard decoded.schemaVersion == 1, decoded.sessions.count <= 32,
            decoded.sessions.allSatisfy({ $0.buffers.count <= 1200 }),
            decoded.pendingSessionID == nil || decoded.sessions.contains(where: { $0.id == decoded.pendingSessionID })
        else { throw CocoaError(.fileReadCorruptFile) }
        cached = decoded
        return decoded
    }

    func load() throws -> WhoopMotionCaptureState? {
        let document = try document()
        return document.sessions.first { $0.id == document.pendingSessionID }
    }

    func recentCompleted(now: Date) throws -> WhoopMotionCaptureState? {
        guard let state = try document().sessions.last, state.phase == .complete,
            (0...600).contains(now.timeIntervalSince(state.endedAt ?? .distantPast))
        else { return nil }
        return state
    }

    func save(_ state: WhoopMotionCaptureState) throws {
        var document = try document()
        if let index = document.sessions.firstIndex(where: { $0.id == state.id }) {
            document.sessions[index] = state
        } else {
            // Bounded calibration, never a routine recording service. Keep all
            // evidence; reaching capacity requires export rather than deletion.
            guard document.sessions.count < 32 else { throw CocoaError(.fileWriteOutOfSpace) }
            document.sessions.append(state)
        }
        document.pendingSessionID = state.needsCleanup ? state.id : nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(document)
        guard data.count <= 20 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cached = document
    }
}

/// Retired calibration's OFF-only recovery. There is no recording entry point.
@MainActor
@Observable
final class WhoopMotionCapture {
    private(set) var state: WhoopMotionCaptureState?
    @ObservationIgnored private let journal: WhoopMotionCaptureJournal?
    @ObservationIgnored private let send: (WhoopCommand) -> UInt8?
    @ObservationIgnored private let didFinish: () -> Void
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let automaticTicks: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var connectedPeripheralID: UUID?
    @ObservationIgnored private var reassembler = WhoopMotionReassembler()

    var blocksHistory: Bool { state?.needsCleanup == true }
    init(
        journal: WhoopMotionCaptureJournal? = WhoopStore.databaseDirectory().map {
            WhoopMotionCaptureJournal(directory: $0)
        }, send: @escaping (WhoopCommand) -> UInt8?,
        didFinish: @escaping () -> Void, clock: @escaping () -> Date = { .now },
        automaticTicks: Bool = true
    ) {
        self.journal = journal
        self.send = send
        self.didFinish = didFinish
        self.clock = clock
        self.automaticTicks = automaticTicks
        do {
            state = try journal?.load() ?? journal?.recentCompleted(now: clock())
            if state?.needsCleanup == true { state?.disconnected(now: clock()) }
        } catch {
            Logger().error("Legacy motion journal cannot be read; original archive retained")
        }
    }

    deinit { timer?.cancel() }

    func stop(reason: String = "Stopped by user") {
        guard blocksHistory else { return }
        state?.stop(reason: reason, now: clock())
        startTimer()
        saveAndDrive()
    }

    func prepareForBackground() {
        guard blocksHistory else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Stop motion capture") { [weak self] in
                Task { @MainActor in
                    self?.disconnected()
                    self?.endBackgroundTask()
                }
            }
        }
        stop(reason: "App left foreground")
    }

    func connected(_ peripheralID: UUID) {
        connectedPeripheralID = peripheralID
        guard state?.peripheralID == peripheralID, blocksHistory else { return }
        state?.reconnect(now: clock())
        startTimer()
        saveAndDrive()
    }

    func resumeCleanup(on peripheralID: UUID) {
        guard state?.phase == .needsCleanup else { return }
        connected(peripheralID)
    }

    func disconnected() {
        reassembler.reset()
        connectedPeripheralID = nil
        guard blocksHistory else { return }
        state?.disconnected(now: clock())
        persist()
        timer?.cancel()
        timer = nil
        endBackgroundTask()
    }

    func persisted(_ summary: WhoopTransportBatchSummary, success: Bool) {
        persistedFragments(summary.motionFragments, success: success)
    }

    /// Called only after the source notification transaction commits. No frame
    /// interpretation or history repair may outrun raw provenance durability.
    func persistedFragments(_ fragments: [WhoopMotionFragment], success: Bool) {
        guard let current = state,
            blocksHistory
                || (0...600).contains(clock().timeIntervalSince(current.endedAt ?? .distantPast))
        else { return }
        guard success else {
            if blocksHistory { stop(reason: "Packet storage failed") }
            reassembler.reset()
            return
        }
        var events: [(UUID, WhoopMotionProtocol.Event)] = []
        for fragment in fragments where fragment.peripheralID == current.peripheralID {
            let result = reassembler.ingest(fragment)
            if result.liveIMUHeader {
                state?.observeProducerTraffic(now: clock())
                if blocksHistory { startTimer() }
            }
            for frame in result.frames {
                let envelope = WhoopPacketEnvelope.proprietary(
                    packet: frame.packet,
                    peripheralID: fragment.peripheralID, characteristicUUID: fragment.characteristicUUID,
                    offloadSessionID: nil, deliveredAt: fragment.deliveredAt, proprietaryOrdinal: 0)
                guard var event = WhoopMotionProtocol.event(envelope) else { continue }
                if case .buffer(var buffer) = event {
                    buffer.sourcePacketHashes = frame.sourceHashes
                    event = .buffer(buffer)
                }
                events.append((fragment.peripheralID, event))
            }
        }
        if blocksHistory { persisted(events, success: true) }
    }

    func persisted(_ events: [(UUID, WhoopMotionProtocol.Event)], success: Bool) {
        guard blocksHistory else { return }
        guard success else {
            stop(reason: "Packet storage failed")
            return
        }
        for (peripheralID, event) in events where peripheralID == connectedPeripheralID {
            guard peripheralID == state?.peripheralID else { continue }
            switch event {
            case .reply(let reply): state?.reply(reply, now: clock())
            case .buffer(let buffer):
                if buffer.realtime == true { state?.observeProducerTraffic(now: clock()) }
            }
        }
        saveAndDrive()
    }

    private func startTimer() {
        guard automaticTicks, timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
                if self.state?.phase == .complete || self.state?.phase == .needsCleanup {
                    self.timer = nil
                    self.endBackgroundTask()
                    return
                }
            }
        }
    }

    func tick() {
        state?.tick(now: clock())
        saveAndDrive()
    }

    private func persist() {
        guard let state else { return }
        do { try journal?.save(state) } catch {
            Logger().error("Legacy cleanup state could not be saved; OFF attempts continue")
            self.state?.stop(reason: "Capture journal write failed", now: clock())
        }
    }

    private func saveAndDrive() {
        persist()
        drive()
    }

    private func drive() {
        guard let state else { return }
        if state.phase == .complete {
            endBackgroundTask()
            didFinish()
            return
        }
        guard connectedPeripheralID == state.peripheralID, let command = state.nextCommand else { return }
        guard let sequence = send(command) else {
            disconnected()
            return
        }
        self.state?.sent(command, sequence: sequence, now: clock())
        persist()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
