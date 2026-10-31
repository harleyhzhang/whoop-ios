import Foundation
import XCTest

@testable import Whoop

@MainActor
final class WhoopMotionCaptureControllerTests: XCTestCase {
    func testInterruptedRelaunchJournalsOFFBeforeWriteAndPreservesEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WhoopMotionCaptureJournal(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = try legacyMotionState(now: now)
        try journal.save(original)
        var date = now
        var commands: [WhoopCommand] = []
        var finished = 0
        let capture = WhoopMotionCapture(
            journal: journal,
            send: { command in
                XCTAssertTrue((try? journal.load())?.needsCleanup == true)
                commands.append(command)
                return UInt8(commands.count)
            }, didFinish: { finished += 1 }, clock: { date }, automaticTicks: false)
        capture.connected(UUID())
        XCTAssertTrue(commands.isEmpty)
        capture.connected(original.peripheralID)
        XCTAssertEqual(commands, [.stopRawMotion])
        capture.tick()
        XCTAssertEqual(commands.count, 1, "Pending stop cannot repeat")
        capture.persisted(
            [(original.peripheralID, .reply(.init(command: 82, origin: 1, result: 1, receivedAt: date)))], success: true
        )
        XCTAssertEqual(commands, [.stopRawMotion, .disableLiveIMU])
        capture.persisted(
            [(original.peripheralID, .reply(.init(command: 106, origin: 2, result: 1, receivedAt: date)))],
            success: true)
        date = date.addingTimeInterval(3)
        capture.tick()
        XCTAssertFalse(capture.blocksHistory)
        XCTAssertEqual(finished, 1)
        XCTAssertNil(try WhoopMotionCaptureJournal(directory: directory).load())
        let saved = try XCTUnwrap(journal.recentCompleted(now: date))
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.notes, original.notes)
        XCTAssertEqual(saved.startedAt, original.startedAt)
        XCTAssertEqual(saved.sourceCommit, original.sourceCommit)
        XCTAssertEqual(saved.rawBytesReceived, original.rawBytesReceived)
    }

    func testCompletedArchiveIsUntouchedAndPartialLIVEHeaderReopensOnlyCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let journal = WhoopMotionCaptureJournal(directory: directory)
        let original = try legacyMotionState(
            phase: .complete, now: now,
            extra: [
                "endedAt": now.timeIntervalSinceReferenceDate,
                "rawStopAccepted": true, "imuStopAccepted": true,
            ])
        try journal.save(original)
        let archiveURL = directory.appendingPathComponent("motion-calibration.json")
        let before = try Data(contentsOf: archiveURL)
        var commands: [WhoopCommand] = []
        let capture = WhoopMotionCapture(
            journal: journal,
            send: {
                commands.append($0)
                return UInt8(commands.count)
            }, didFinish: {}, clock: { now }, automaticTicks: false)
        capture.connected(original.peripheralID)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archiveURL), before)
        var frame = WhoopTestFrameFactory.frame(length: 1244, type: 43, version: 21)
        WhoopTestFrameFactory.finishChecksums(&frame)
        capture.persistedFragments(
            [
                .init(
                    packet: Data(frame.prefix(244)), peripheralID: original.peripheralID,
                    characteristicUUID: "synthetic", deliveredAt: now)
            ], success: true)
        XCTAssertTrue(capture.blocksHistory)
        XCTAssertEqual(commands, [.stopRawMotion])
        XCTAssertEqual(capture.state?.buffers.count, 0, "Retirement cannot add or relabel recordings")
    }

    func testDisconnectAndBackgroundRetainOFFOnlyRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = try legacyMotionState(now: now)
        let journal = WhoopMotionCaptureJournal(directory: directory)
        try journal.save(state)
        var commands: [WhoopCommand] = []
        let capture = WhoopMotionCapture(
            journal: journal,
            send: {
                commands.append($0)
                return UInt8(commands.count)
            }, didFinish: {}, clock: { now }, automaticTicks: false)
        capture.connected(state.peripheralID)
        capture.prepareForBackground()
        capture.disconnected()
        XCTAssertEqual(capture.state?.phase, .needsCleanup)
        capture.resumeCleanup(on: state.peripheralID)
        XCTAssertEqual(commands, [.stopRawMotion, .stopRawMotion])
        capture.persisted([], success: false)
        XCTAssertTrue(capture.blocksHistory)
        capture.disconnected()
    }

    func testCorruptArchiveIsPreservedAndCannotStartAnything() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("motion-calibration.json")
        let original = Data("invalid".utf8)
        try original.write(to: url)
        var commands: [WhoopCommand] = []
        let capture = WhoopMotionCapture(
            journal: .init(directory: directory),
            send: {
                commands.append($0)
                return 1
            }, didFinish: {}, automaticTicks: false)
        capture.connected(UUID())
        XCTAssertTrue(commands.isEmpty)
        XCTAssertNil(capture.state)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
