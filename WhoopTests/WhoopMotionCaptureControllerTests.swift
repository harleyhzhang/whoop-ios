import Foundation
import XCTest

@testable import Whoop

@MainActor
final class WhoopMotionCaptureControllerTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testStartJournalsBeforeDeviceWriteAndInterruptedRelaunchOnlyCleansUp() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WhoopMotionCaptureJournal(directory: directory)
        let peripheralID = UUID()
        var commands: [WhoopCommand] = []
        var journalExistedAtWrite = false
        let capture = WhoopMotionCapture(
            journal: journal,
            send: { command in
                journalExistedAtWrite = (try? journal.load())?.needsCleanup == true
                commands.append(command)
                return 12
            }, ready: { peripheralID }, didFinish: {}, isForeground: { true }, automaticTicks: false
        )
        capture.start(label: .lifting, notes: "Synthetic", duration: 60)
        XCTAssertTrue(journalExistedAtWrite)
        XCTAssertEqual(commands, [.readMotionClock])
        capture.disconnected()
        commands = []
        let restored = WhoopMotionCapture(
            journal: journal,
            send: {
                commands.append($0)
                return 13
            }, ready: { peripheralID },
            didFinish: {}, automaticTicks: false
        )
        XCTAssertTrue(restored.blocksHistory)
        restored.connected(UUID())
        XCTAssertTrue(commands.isEmpty)
        restored.connected(peripheralID)
        XCTAssertEqual(commands, [.rawMotion(start: false)])
        XCTAssertFalse(restored.state?.isCollecting ?? true)
    }

    func testForegroundRetriesExpiredCleanupOnTheSameStillConnectedLinkWithoutRestartingCapture() {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let peripheralID = UUID()
        var commands: [WhoopCommand] = []
        let capture = WhoopMotionCapture(
            journal: .init(directory: directory),
            send: {
                commands.append($0)
                return UInt8(commands.count)
            },
            ready: { peripheralID }, didFinish: {}, isForeground: { true }, automaticTicks: false
        )
        capture.start(label: .rest, notes: "Synthetic", duration: 60)
        capture.resumeCleanup(on: peripheralID)
        XCTAssertEqual(commands, [.readMotionClock])
        // Background-task expiration marks cleanup uncertain even when the
        // actual CoreBluetooth link has remained connected.
        capture.disconnected()
        capture.resumeCleanup(on: peripheralID)
        XCTAssertEqual(commands, [.readMotionClock, .rawMotion(start: false)])
        XCTAssertFalse(capture.state?.isCollecting ?? true)
    }

    func testUnavailableOrCorruptStorageNeverStartsSensors() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("motion-calibration.json"))
        var writes = 0
        let capture = WhoopMotionCapture(
            journal: .init(directory: directory),
            send: { _ in
                writes += 1
                return 1
            }, ready: { UUID() },
            didFinish: {}, isForeground: { true }, automaticTicks: false
        )
        capture.start(label: .rest, notes: "", duration: 60)
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(capture.canStart)
        XCTAssertNotNil(capture.errorMessage)
        let unavailable = WhoopMotionCapture(
            journal: nil,
            send: { _ in
                writes += 1
                return 1
            },
            ready: { UUID() }, didFinish: {}, automaticTicks: false)
        XCTAssertFalse(unavailable.canStart)
    }

    func testCommandRefusalStillPerformsBothStopsAndResumesHistoryOnlyAfterQuiet() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let peripheralID = UUID()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var commands: [WhoopCommand] = []
        var finished = 0
        let capture = WhoopMotionCapture(
            journal: .init(directory: directory),
            send: {
                commands.append($0)
                return UInt8(commands.count)
            },
            ready: { peripheralID }, didFinish: { finished += 1 }, clock: { date },
            isForeground: { true }, automaticTicks: false
        )
        capture.start(label: .walking, notes: "", duration: 60)
        capture.persisted(
            [(peripheralID, .reply(.init(command: 147, origin: 1, result: 1, receivedAt: date, deviceClock: date)))],
            success: true)
        capture.persisted(
            [(peripheralID, .reply(.init(command: 81, origin: 2, result: 3, receivedAt: date)))], success: true)
        XCTAssertEqual(commands.last, .rawMotion(start: false))
        capture.persisted(
            [(peripheralID, .reply(.init(command: 82, origin: 3, result: 1, receivedAt: date)))], success: true)
        XCTAssertEqual(commands.last, .liveIMU(enabled: false))
        capture.persisted(
            [(peripheralID, .reply(.init(command: 106, origin: 4, result: 1, receivedAt: date)))], success: true)
        XCTAssertTrue(capture.blocksHistory)
        XCTAssertEqual(finished, 0)
        date = date.addingTimeInterval(3)
        capture.tick()
        XCTAssertFalse(capture.blocksHistory)
        XCTAssertEqual(finished, 1)
        XCTAssertNil(try WhoopMotionCaptureJournal(directory: directory).load())
    }

    func testBackgroundOrPacketStorageFailureNeverContinuesCapture() {
        for storageFailed in [false, true] {
            let directory = directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var commands: [WhoopCommand] = []
            let capture = WhoopMotionCapture(
                journal: .init(directory: directory),
                send: {
                    commands.append($0)
                    return UInt8(commands.count)
                },
                ready: { UUID() }, didFinish: {}, isForeground: { true }, automaticTicks: false
            )
            capture.start(label: .rest, notes: "", duration: 60)
            if storageFailed { capture.persisted([], success: false) } else { capture.prepareForBackground() }
            XCTAssertEqual(commands.last, .rawMotion(start: false))
            XCTAssertFalse(capture.state?.isCollecting ?? true)
            capture.disconnected()
        }
    }
    func testDurableFragmentsAndDelayedHistoryRetainHashesWithoutRestartingSensors() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let peripheralID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var date = base
        var commands: [WhoopCommand] = []
        let capture = WhoopMotionCapture(
            journal: .init(directory: directory),
            send: {
                commands.append($0)
                return UInt8(commands.count)
            }, ready: { peripheralID }, didFinish: {}, clock: { date }, isForeground: { true }, automaticTicks: false)
        capture.start(label: .rest, notes: "Synthetic", duration: 60)
        capture.persisted(
            [
                (
                    peripheralID,
                    .reply(
                        .init(
                            command: 147, origin: 1, result: 1,
                            receivedAt: date, deviceClock: base.addingTimeInterval(-120)))
                )
            ], success: true)
        capture.persisted(
            [
                (
                    peripheralID,
                    .reply(
                        .init(
                            command: 81, origin: 2, result: 1,
                            receivedAt: date))
                )
            ], success: true)
        capture.persisted(
            [
                (
                    peripheralID,
                    .reply(
                        .init(
                            command: 106, origin: 3, result: 1,
                            receivedAt: date))
                )
            ], success: true)
        func fragments(type: UInt8, sensorOffset: UInt32) -> [WhoopMotionFragment] {
            var bytes = WhoopTestFrameFactory.frame(length: 1244, type: type, version: 21)
            let seconds: UInt32 = 1_799_999_880 + sensorOffset
            for offset in 0..<4 { bytes[15 + offset] = UInt8(truncatingIfNeeded: seconds >> (8 * offset)) }
            bytes[24] = 100
            bytes[630] = 100
            WhoopTestFrameFactory.finishChecksums(&bytes)
            return stride(from: 0, to: bytes.count, by: 244).map { index in
                WhoopMotionFragment(
                    packet: Data(bytes[index..<min(index + 244, bytes.count)]),
                    peripheralID: peripheralID, characteristicUUID: "synthetic", deliveredAt: date)
            }
        }
        date = base.addingTimeInterval(2)
        capture.persistedFragments(fragments(type: 43, sensorOffset: 1), success: true)
        XCTAssertEqual(capture.state?.phase, .recording)
        XCTAssertEqual(capture.state?.buffers.first?.sourcePacketHashes?.count, 6)
        date = base.addingTimeInterval(5)
        capture.stop()
        capture.persisted(
            [
                (
                    peripheralID,
                    .reply(
                        .init(
                            command: 82, origin: 4, result: 1,
                            receivedAt: date))
                )
            ], success: true)
        capture.persisted(
            [
                (
                    peripheralID,
                    .reply(
                        .init(
                            command: 106, origin: 5, result: 1,
                            receivedAt: date))
                )
            ], success: true)
        date = base.addingTimeInterval(8)
        capture.tick()
        XCTAssertEqual(capture.state?.phase, .complete)
        date = base.addingTimeInterval(20)
        capture.persistedFragments(fragments(type: 47, sensorOffset: 2), success: true)
        XCTAssertEqual(capture.state?.buffers.count, 2)
        XCTAssertEqual(commands.count, 5)
        XCTAssertEqual(capture.state?.phase, .complete)
        // Even a fresh fragmented live header after a verified stop reopens
        // cleanup; partial framing cannot produce a false quiet result.
        let next = fragments(type: 43, sensorOffset: 20)
        capture.persistedFragments(Array(next.prefix(1)), success: true)
        XCTAssertEqual(commands.last, .rawMotion(start: false))
        XCTAssertTrue(capture.blocksHistory)
    }

}
