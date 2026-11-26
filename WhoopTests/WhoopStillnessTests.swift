import Foundation
import XCTest

@testable import Whoop

final class WhoopStillnessTests: XCTestCase {
    private func sample(
        _ time: TimeInterval, motion: Double = 0.008, state: Int = 0,
        receivedAt: TimeInterval? = nil
    ) -> WhoopStillnessSample {
        .init(timestamp: time, receivedAt: receivedAt ?? time, acceleration: motion, sleepState: state)
    }

    private func context(
        _ time: TimeInterval, hour: Int = 12, connected: Bool = true,
        worn: Bool = true, sleeping: Bool = false
    ) -> WhoopStillnessPolicy.Context {
        .init(now: time, localHour: hour, connected: connected, worn: worn, sleeping: sleeping)
    }

    private func feed(
        _ policy: inout WhoopStillnessPolicy, from: Int = 0, through: Int = 3600,
        motion: Double = 0.008, state: Int = 0, delay: TimeInterval = 0
    ) {
        for t in from...through {
            policy.observe(sample(Double(t), motion: motion, state: state, receivedAt: Double(t) + delay))
        }
    }

    func testOneFiniteNudgeAfterHourAndNoRepeatsWithoutMovement() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy, through: 3599)
        XCTAssertFalse(policy.takeNudge(context(3599)))
        policy.observe(sample(3600))
        XCTAssertTrue(policy.takeNudge(context(3600)))
        feed(&policy, from: 3601, through: 7200)
        XCTAssertFalse(policy.takeNudge(context(7200)))
    }

    func testSustainedMotionRearmsWithoutAnyStepsOrExerciseLabel() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy)
        XCTAssertTrue(policy.takeNudge(context(3600)))
        feed(&policy, from: 3601, through: 3620, motion: 0.5)
        feed(&policy, from: 3621, through: 7259)
        XCTAssertFalse(policy.takeNudge(context(7259)))
        policy.observe(sample(7260))
        XCTAssertTrue(policy.takeNudge(context(7260)))
    }

    func testFidgetDoesNotRearmAnAlreadyDeliveredNudge() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy)
        XCTAssertTrue(policy.takeNudge(context(3600)))
        feed(&policy, from: 3601, through: 3619, motion: 0.5)
        feed(&policy, from: 3620, through: 7300)
        XCTAssertFalse(policy.takeNudge(context(7300)))
    }

    func testCurrentMotionVetoesNudgeBeforeItsMinuteIsComplete() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy)
        feed(&policy, from: 3601, through: 3620, motion: 0.5)
        XCTAssertFalse(policy.takeNudge(context(3620)))
        feed(&policy, from: 3621, through: 7259)
        XCTAssertFalse(policy.takeNudge(context(7259)))
        policy.observe(sample(7260))
        XCTAssertTrue(policy.takeNudge(context(7260)))
    }

    func testSleepAndTransientUpNeverEarnAnHourOfStillness() {
        for state in [1, 2, 3] {
            var policy = WhoopStillnessPolicy(startedAt: 0)
            feed(&policy, through: 7200, state: state)
            XCTAssertFalse(policy.takeNudge(context(7200)))
        }
    }

    func testNapImmediatelyVetoesAReadyNudgeAndKeepsNinetyMinuteHold() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy)
        policy.observe(sample(3601, state: 2))
        XCTAssertFalse(policy.takeNudge(context(3601)))
        feed(&policy, from: 3602, through: 9001)
        XCTAssertFalse(policy.takeNudge(context(9001)))
        policy.observe(sample(9002))
        XCTAssertTrue(policy.takeNudge(context(9002)))
    }

    func testContextGuardsDoNotConsumeNudge() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy)
        XCTAssertFalse(policy.takeNudge(context(3600, hour: 9)))
        XCTAssertFalse(policy.takeNudge(context(3600, hour: 22)))
        XCTAssertFalse(policy.takeNudge(context(3600, connected: false)))
        XCTAssertFalse(policy.takeNudge(context(3600, worn: false)))
        XCTAssertFalse(policy.takeNudge(context(3600, sleeping: true)))
        XCTAssertTrue(policy.takeNudge(context(3600)))
    }

    func testStaleHistoryDoesNotBuzzAtReceiptButCanBuildObservedInterval() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy, delay: 900)
        XCTAssertFalse(policy.takeNudge(context(4500)))
        feed(&policy, from: 3601, through: 4500)
        XCTAssertTrue(policy.takeNudge(context(4500)))
    }

    func testPrelaunchHistoryCannotImmediatelyBuzzAfterReconnect() {
        var policy = WhoopStillnessPolicy(startedAt: 3600)
        feed(&policy)
        XCTAssertFalse(policy.takeNudge(context(3600)))
        feed(&policy, from: 3601, through: 7200)
        XCTAssertTrue(policy.takeNudge(context(7200)))
    }

    func testObservationGapAndSparseMinuteRestartInterval() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy, through: 3599)
        feed(&policy, from: 3800, through: 7300)
        XCTAssertFalse(policy.takeNudge(context(7300)))
        var sparse = WhoopStillnessPolicy(startedAt: 0)
        for t in stride(from: 0, through: 7200, by: 2) { sparse.observe(sample(Double(t))) }
        XCTAssertFalse(sparse.takeNudge(context(7200)))
    }

    func testFutureAndInvalidMotionInvalidateEarnedStillness() {
        for motion in [Double.nan, .infinity, -1, 33] {
            var policy = WhoopStillnessPolicy(startedAt: 0)
            feed(&policy)
            policy.observe(sample(3601, motion: motion))
            XCTAssertFalse(policy.takeNudge(context(3601)))
        }
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy)
        policy.observe(sample(4000, receivedAt: 3600))
        XCTAssertFalse(policy.takeNudge(context(3600)))
    }

    func testOlderWakeCannotOverwriteSleepAndDuplicateMovementDoesNotRearm() {
        var policy = WhoopStillnessPolicy(startedAt: 0)
        feed(&policy)
        policy.observe(sample(3601, state: 2))
        policy.observe(sample(3600, state: 0))
        XCTAssertFalse(policy.takeNudge(context(3601)))
        var duplicate = WhoopStillnessPolicy(startedAt: 0)
        feed(&duplicate)
        XCTAssertTrue(duplicate.takeNudge(context(3600)))
        for _ in 0..<60 { duplicate.observe(sample(3600, motion: 1)) }
        feed(&duplicate, from: 3601, through: 7300)
        XCTAssertFalse(duplicate.takeNudge(context(7300)))
    }

    func testTripleHapticUsesWhoopFiveFiniteWaveformAndValidFrame() {
        let command = WhoopCommand.stillnessNudge
        XCTAssertEqual(command.opcode, 19)
        XCTAssertEqual(command.payload, [1, 1, 138, 1, 138, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(command.payload.count, 12)
        XCTAssertTrue(WhoopFrameIntegrity.isValid(Data(command.frame(sequence: 31))))
    }
}
