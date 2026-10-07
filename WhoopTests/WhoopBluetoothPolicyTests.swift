import Foundation
import XCTest

@testable import Whoop

final class WhoopBluetoothPolicyTests: XCTestCase {
    func testHandshakeBehaviorNeverDependsOnDisplayCopy() {
        XCTAssertTrue(HandshakePhase.acknowledged.isAcknowledged)
        XCTAssertFalse(HandshakePhase.ready.isAcknowledged)
        XCTAssertTrue(HandshakePhase.ready.canAutomaticallyAttempt)
        XCTAssertEqual(
            HandshakePhase.refused(reason: "future reason").displayText,
            "Refused: future reason"
        )
    }

    func testUnknownWireValuesRoundTripWithoutAcquiringKnownBehavior() {
        let frame = FrameType(rawValue: 0xFE)
        XCTAssertEqual(frame, .unknown(0xFE))
        XCTAssertEqual(frame.rawValue, 0xFE)
        XCTAssertFalse(frame.isReplayProne)

        let metadata = MetadataType(rawValue: 0xFD)
        XCTAssertEqual(metadata, .unknown(0xFD))
        XCTAssertEqual(metadata.rawValue, 0xFD)
        XCTAssertFalse(
            WhoopBluetoothPolicy.shouldAnalyzeHistoryCompletion(
                metadataType: metadata,
                historicalSyncActive: true
            )
        )
    }

    func testCommandFrameMatchesKnownClientHelloAndHasValidIntegrity() {
        let frame = WhoopCommand.clientHello.frame(sequence: 0x01)

        XCTAssertEqual(
            frame,
            [
                0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
                0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
            ]
        )
        XCTAssertTrue(WhoopFrameIntegrity.isValid(Data(frame)))
    }

    func testTypedCommandsOwnTheirWirePayloads() {
        XCTAssertEqual(WhoopCommand.requestHistory.opcode, 22)
        XCTAssertEqual(WhoopCommand.requestHistory.payload, [0x00])
        XCTAssertEqual(
            WhoopCommand.acknowledgeHistoryChunk([1, 2, 3, 4, 5, 6, 7, 8]).payload,
            [0x01, 1, 2, 3, 4, 5, 6, 7, 8]
        )
        XCTAssertEqual(WhoopCommand.realtimeSensors(enabled: false).payload, [0x00])
        XCTAssertEqual(WhoopCommand.realtimeHeartRate(enabled: true).payload, [0x01])
    }

    func testCommandFramePadsPayloadAndPreservesSequenceAndCommand() {
        let frame = WhoopBluetoothPolicy.commandFrame(
            command: 0x17,
            sequence: 0xFE,
            payload: [0x01, 0x02]
        )

        XCTAssertEqual(frame[8..<16], [0x23, 0xFE, 0x17, 0x01, 0x02, 0x00, 0x00, 0x00])
        XCTAssertTrue(WhoopFrameIntegrity.isValid(Data(frame)))
    }

    func testAdvertisementMatchingAcceptsServiceOrWhoopNamesOnly() {
        let service = "FD4B0001-CCE1-4033-93CE-002D5875F58A"

        XCTAssertTrue(
            WhoopBluetoothPolicy.matchesAdvertisement(
                serviceUUIDs: [service],
                advertisedName: nil,
                peripheralName: nil,
                whoopServiceUUID: service
            )
        )
        XCTAssertTrue(
            WhoopBluetoothPolicy.matchesAdvertisement(
                serviceUUIDs: [],
                advertisedName: "WHOOP 5.0",
                peripheralName: nil,
                whoopServiceUUID: service
            )
        )
        XCTAssertTrue(
            WhoopBluetoothPolicy.matchesAdvertisement(
                serviceUUIDs: [],
                advertisedName: nil,
                peripheralName: "Puffin",
                whoopServiceUUID: service
            )
        )
        XCTAssertFalse(
            WhoopBluetoothPolicy.matchesAdvertisement(
                serviceUUIDs: ["180D"],
                advertisedName: "Heart Rate Monitor",
                peripheralName: nil,
                whoopServiceUUID: service
            )
        )
    }

    func testPowerPackAdvertisementMatchingUsesItsServiceOrSerialName() {
        XCTAssertTrue(
            WhoopPowerPackPolicy.matchesAdvertisement(
                serviceUUIDs: [WhoopPowerPackPolicy.serviceUUID.lowercased()],
                advertisedName: nil,
                peripheralName: nil
            )
        )
        XCTAssertTrue(
            WhoopPowerPackPolicy.matchesAdvertisement(
                serviceUUIDs: [],
                advertisedName: "WBB5BP0229191",
                peripheralName: nil
            )
        )
        XCTAssertFalse(
            WhoopPowerPackPolicy.matchesAdvertisement(
                serviceUUIDs: ["180F"],
                advertisedName: "Battery",
                peripheralName: nil
            )
        )
    }

    func testPowerPackBatteryLevelUsesStandardGattPercentage() {
        XCTAssertEqual(WhoopPowerPackPolicy.batteryLevel(Data([0])), 0)
        XCTAssertEqual(WhoopPowerPackPolicy.batteryLevel(Data([97])), 97)
        XCTAssertEqual(WhoopPowerPackPolicy.batteryLevel(Data([100])), 100)
        XCTAssertNil(WhoopPowerPackPolicy.batteryLevel(Data()))
        XCTAssertNil(WhoopPowerPackPolicy.batteryLevel(Data([101])))
    }

    func testCachedBatteryLevelKeepsValidPercentagesIncludingZero() {
        XCTAssertEqual(WhoopBluetoothPolicy.cachedBatteryLevel(0), 0)
        XCTAssertEqual(WhoopBluetoothPolicy.cachedBatteryLevel(73), 73)
        XCTAssertEqual(WhoopBluetoothPolicy.cachedBatteryLevel(100), 100)
        XCTAssertEqual(WhoopBluetoothPolicy.cachedBatteryLevel(NSNumber(value: 58)), 58)
    }

    func testCachedBatteryLevelRejectsMissingAndInvalidValues() {
        XCTAssertNil(WhoopBluetoothPolicy.cachedBatteryLevel(nil))
        XCTAssertNil(WhoopBluetoothPolicy.cachedBatteryLevel(-1))
        XCTAssertNil(WhoopBluetoothPolicy.cachedBatteryLevel(101))
        XCTAssertNil(WhoopBluetoothPolicy.cachedBatteryLevel("unknown"))
    }

    func testBatteryTrendInferenceNeverOverridesExplicitChargingState() {
        XCTAssertEqual(
            WhoopBluetoothPolicy.inferredBatteryStatus(
                previousLevel: 50,
                currentLevel: 49,
                currentStatus: .charging
            ),
            .charging
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.inferredBatteryStatus(
                previousLevel: 50,
                currentLevel: 51,
                currentStatus: .unavailable
            ),
            .charging
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.inferredBatteryStatus(
                previousLevel: 50,
                currentLevel: 49,
                currentStatus: .unavailable
            ),
            .notCharging
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.inferredBatteryStatus(
                previousLevel: 50,
                currentLevel: 50,
                currentStatus: .charging
            ),
            .charging
        )
    }

    func testHistoricalChunkAcknowledgementSuppressesBurstButAllowsRetry() {
        let endData: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let acknowledgedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            WhoopBluetoothPolicy.shouldAcknowledgeChunk(
                endData: endData,
                previousEndData: nil,
                previousAcknowledgedAt: nil,
                now: acknowledgedAt
            )
        )
        XCTAssertFalse(
            WhoopBluetoothPolicy.shouldAcknowledgeChunk(
                endData: endData,
                previousEndData: endData,
                previousAcknowledgedAt: acknowledgedAt,
                now: acknowledgedAt.addingTimeInterval(1.99)
            )
        )
        XCTAssertTrue(
            WhoopBluetoothPolicy.shouldAcknowledgeChunk(
                endData: endData,
                previousEndData: endData,
                previousAcknowledgedAt: acknowledgedAt,
                now: acknowledgedAt.addingTimeInterval(2)
            )
        )
        XCTAssertFalse(
            WhoopBluetoothPolicy.shouldAcknowledgeChunk(
                endData: [0, 1],
                previousEndData: nil,
                previousAcknowledgedAt: nil,
                now: acknowledgedAt
            )
        )
    }

    func testHistoricalMetadataValidatesIntegrityAndExtractsChunkEnd() throws {
        let chunkEnd: [UInt8] = [8, 7, 6, 5, 4, 3, 2, 1]
        let frame = WhoopTestFrameFactory.historicalMetadata(type: 2, chunkEnd: chunkEnd)

        let metadata = try XCTUnwrap(
            WhoopHistoricalMetadata(data: frame, frameType: .historicalMetadata)
        )
        XCTAssertEqual(metadata.type, .chunkEnd)
        XCTAssertEqual(metadata.chunkEndData, chunkEnd)
        XCTAssertFalse(metadata.shouldForcePresentation(historicalSyncActive: true))

        var corrupted = frame
        corrupted[12] ^= 0xFF
        XCTAssertNil(WhoopHistoricalMetadata(data: corrupted, frameType: .historicalMetadata))
        XCTAssertNil(WhoopHistoricalMetadata(data: frame, frameType: .realtimeHeartRate))
        XCTAssertNil(
            WhoopHistoricalMetadata(
                data: Data(repeating: 0, count: 12), frameType: .historicalMetadata
            )
        )
        XCTAssertNil(
            WhoopHistoricalMetadata(
                data: WhoopTestFrameFactory.historicalMetadata(
                    type: 2,
                    chunkEnd: chunkEnd,
                    length: 32
                ),
                frameType: .historicalMetadata
            ))
    }

    func testHistoricalMetadataPresentationAndCompletionPolicies() throws {
        let start = try XCTUnwrap(
            WhoopHistoricalMetadata(
                data: WhoopTestFrameFactory.historicalMetadata(type: 1),
                frameType: .historicalMetadata
            ))
        let complete = try XCTUnwrap(
            WhoopHistoricalMetadata(
                data: WhoopTestFrameFactory.historicalMetadata(type: 3, frameType: 56),
                frameType: .historicalMetadataAlternate
            ))

        XCTAssertTrue(start.shouldForcePresentation(historicalSyncActive: false))
        XCTAssertFalse(complete.shouldForcePresentation(historicalSyncActive: false))
        XCTAssertTrue(complete.shouldForcePresentation(historicalSyncActive: true))

        XCTAssertFalse(
            WhoopBluetoothPolicy.shouldAnalyzeHistoryCompletion(
                metadataType: .chunkEnd,
                historicalSyncActive: true
            )
        )
        XCTAssertTrue(
            WhoopBluetoothPolicy.shouldAnalyzeHistoryCompletion(
                metadataType: .historyComplete,
                historicalSyncActive: true
            )
        )
        XCTAssertFalse(
            WhoopBluetoothPolicy.shouldAnalyzeHistoryCompletion(
                metadataType: .historyComplete,
                historicalSyncActive: false
            )
        )
    }

}
