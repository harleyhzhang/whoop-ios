import XCTest

@testable import Whoop

final class WhoopHistoricalRecoveryTests: XCTestCase {
    func testRepeatedStallsEscalateInsteadOfRetryingTheSameChannelForever() {
        var recovery = WhoopHistoricalRecovery()
        XCTAssertFalse(recovery.shouldReconnectAfterStall())
        XCTAssertTrue(recovery.shouldReconnectAfterStall())
        XCTAssertTrue(recovery.shouldReconnectAfterStall())
    }

    func testOnlyNewDurableHistoryRestoresRetryBudget() {
        var recovery = WhoopHistoricalRecovery()
        let sample = Date(timeIntervalSince1970: 1_800_000_000)
        recovery.observeProgress(at: sample)
        XCTAssertFalse(recovery.shouldReconnectAfterStall())
        recovery.observeProgress(at: sample)
        recovery.observeProgress(at: sample.addingTimeInterval(-60))
        XCTAssertTrue(recovery.shouldReconnectAfterStall())
        recovery.observeProgress(at: sample.addingTimeInterval(60))
        XCTAssertFalse(recovery.shouldReconnectAfterStall())
        XCTAssertTrue(recovery.shouldReconnectAfterStall())
    }

    func testReconnectResetsStallsWithoutTreatingReplayAsProgress() {
        var recovery = WhoopHistoricalRecovery()
        let sample = Date(timeIntervalSince1970: 1_800_000_000)
        recovery.observeProgress(at: sample)
        XCTAssertFalse(recovery.shouldReconnectAfterStall())
        XCTAssertTrue(recovery.shouldReconnectAfterStall())
        recovery.resetStalls()
        XCTAssertFalse(recovery.shouldReconnectAfterStall())
        recovery.observeProgress(at: sample)
        XCTAssertTrue(recovery.shouldReconnectAfterStall())
    }
}
