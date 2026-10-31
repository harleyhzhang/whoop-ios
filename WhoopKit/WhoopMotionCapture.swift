import Foundation
import Observation
import UIKit

/// Session metadata only. Full sensor frames use the existing durable raw-packet
/// store and are linked by SHA256, peripheral, sensor time and receipt time.
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

@MainActor
@Observable
final class WhoopMotionCapture {
    private(set) var state: WhoopMotionCaptureState?
    private(set) var errorMessage: String?
    @ObservationIgnored private let journal: WhoopMotionCaptureJournal?
    @ObservationIgnored private let send: (WhoopCommand) -> UInt8?
    @ObservationIgnored private let ready: () -> UUID?
    @ObservationIgnored private let didFinish: () -> Void
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let isForeground: () -> Bool
    @ObservationIgnored private let automaticTicks: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var monotonicDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var connectedPeripheralID: UUID?

    var blocksHistory: Bool { state?.needsCleanup == true }
    var canStart: Bool { !blocksHistory && errorMessage == nil && ready() != nil }

    var status: String {
        if let errorMessage { return errorMessage }
        guard let state else {
            return ready() == nil ? "Waiting for WHOOP to connect and finish syncing" : "Ready for a brief recording"
        }
        switch state.phase {
        case .startingRaw, .enablingIMU, .awaitingSamples: return "Checking accel and gyro…"
        case .recording: return "Recording accel and gyro"
        case .stoppingRaw, .disablingIMU, .settling: return "Stopping sensors…"
        case .needsCleanup: return "Connect WHOOP to finish stopping sensors"
        case .complete: return state.hasBothSensors ? "Recording saved · sensors stopped" : state.reason
        }
    }

    init(
        journal: WhoopMotionCaptureJournal? = WhoopStore.databaseDirectory().map {
            WhoopMotionCaptureJournal(directory: $0)
        }, send: @escaping (WhoopCommand) -> UInt8?, ready: @escaping () -> UUID?,
        didFinish: @escaping () -> Void, clock: @escaping () -> Date = { .now },
        isForeground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
        automaticTicks: Bool = true
    ) {
        self.journal = journal
        self.send = send
        self.ready = ready
        self.didFinish = didFinish
        self.clock = clock
        self.isForeground = isForeground
        self.automaticTicks = automaticTicks
        do {
            state = try journal?.load()
            if state?.needsCleanup == true { state?.disconnected(now: clock()) }
        } catch {
            errorMessage = "Capture journal cannot be read; recording is unavailable"
        }
        if journal == nil { errorMessage = "Capture storage is unavailable" }
    }

    deinit { timer?.cancel() }

    func start(label: WhoopMotionCaptureState.Label, notes: String, duration: TimeInterval) {
        guard canStart, isForeground(),
            let peripheralID = ready(),
            let next = WhoopMotionCaptureState(
                peripheralID: peripheralID, label: label, notes: notes, duration: duration,
                sourceCommit: Bundle.main.object(forInfoDictionaryKey: "WHOOPSourceCommit") as? String ?? "unknown",
                now: clock()
            )
        else { return }
        // Journal the cleanup obligation BEFORE the first device write.
        do { try journal?.save(next) } catch {
            errorMessage = "Recording could not be saved; sensors were not started"
            return
        }
        state = next
        monotonicDeadline = ContinuousClock.now.advanced(by: .seconds(duration))
        connectedPeripheralID = peripheralID
        startTimer()
        drive()
    }

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
        connectedPeripheralID = nil
        guard blocksHistory else { return }
        state?.disconnected(now: clock())
        persist()
        timer?.cancel()
        timer = nil
        endBackgroundTask()
    }

    func persisted(_ events: [(UUID, WhoopMotionProtocol.Event)], success: Bool, byteCount: Int = 0) {
        guard blocksHistory else { return }
        guard success else {
            stop(reason: "Packet storage failed")
            return
        }
        state?.observeRawBytes(byteCount, now: clock())
        for (peripheralID, event) in events where peripheralID == connectedPeripheralID {
            guard peripheralID == state?.peripheralID else { continue }
            switch event {
            case .reply(let reply): state?.reply(reply, now: clock())
            case .buffer(let buffer): state?.observe(buffer, now: clock())
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
        if let monotonicDeadline, ContinuousClock.now >= monotonicDeadline, state?.isCollecting == true {
            state?.stop(reason: "Time limit reached", now: clock())
        }
        state?.tick(now: clock())
        saveAndDrive()
    }

    private func persist() {
        guard let state else { return }
        do { try journal?.save(state) } catch {
            errorMessage = "Capture storage failed; stopping sensors"
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
