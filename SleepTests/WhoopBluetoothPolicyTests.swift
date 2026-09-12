import Foundation
import XCTest

@testable import Sleep

final class WhoopBluetoothPolicyTests: XCTestCase {
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

    func testBatteryTrendInferenceNeverOverridesExplicitChargingState() {
        XCTAssertTrue(
            WhoopBluetoothPolicy.inferredCharging(
                previousLevel: 50,
                currentLevel: 49,
                hasExplicitChargingState: true,
                currentChargingState: true
            )
        )
        XCTAssertTrue(
            WhoopBluetoothPolicy.inferredCharging(
                previousLevel: 50,
                currentLevel: 51,
                hasExplicitChargingState: false,
                currentChargingState: false
            )
        )
        XCTAssertFalse(
            WhoopBluetoothPolicy.inferredCharging(
                previousLevel: 50,
                currentLevel: 49,
                hasExplicitChargingState: false,
                currentChargingState: true
            )
        )
        XCTAssertTrue(
            WhoopBluetoothPolicy.inferredCharging(
                previousLevel: 50,
                currentLevel: 50,
                hasExplicitChargingState: false,
                currentChargingState: true
            )
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

        let metadata = try XCTUnwrap(WhoopHistoricalMetadata(data: frame, frameType: 49))
        XCTAssertEqual(metadata.type, 2)
        XCTAssertEqual(metadata.chunkEndData, chunkEnd)
        XCTAssertFalse(metadata.shouldForcePresentation(historicalSyncActive: true))

        var corrupted = frame
        corrupted[12] ^= 0xFF
        XCTAssertNil(WhoopHistoricalMetadata(data: corrupted, frameType: 49))
        XCTAssertNil(WhoopHistoricalMetadata(data: frame, frameType: 40))
        XCTAssertNil(WhoopHistoricalMetadata(data: Data(repeating: 0, count: 12), frameType: 49))
        XCTAssertNil(
            WhoopHistoricalMetadata(
                data: WhoopTestFrameFactory.historicalMetadata(
                    type: 2,
                    chunkEnd: chunkEnd,
                    length: 32
                ),
                frameType: 49
            ))
    }

    func testHistoricalMetadataPresentationAndCompletionPolicies() throws {
        let start = try XCTUnwrap(
            WhoopHistoricalMetadata(
                data: WhoopTestFrameFactory.historicalMetadata(type: 1),
                frameType: 49
            ))
        let complete = try XCTUnwrap(
            WhoopHistoricalMetadata(
                data: WhoopTestFrameFactory.historicalMetadata(type: 3, frameType: 56),
                frameType: 56
            ))

        XCTAssertTrue(start.shouldForcePresentation(historicalSyncActive: false))
        XCTAssertFalse(complete.shouldForcePresentation(historicalSyncActive: false))
        XCTAssertTrue(complete.shouldForcePresentation(historicalSyncActive: true))

        XCTAssertEqual(
            WhoopBluetoothPolicy.historyCompletionAction(
                metadataType: 2,
                historicalSyncActive: true,
                hasPendingProcess: true
            ),
            .ignore
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.historyCompletionAction(
                metadataType: 3,
                historicalSyncActive: true,
                hasPendingProcess: false
            ),
            .analyzeAutomatically
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.historyCompletionAction(
                metadataType: 3,
                historicalSyncActive: false,
                hasPendingProcess: true
            ),
            .finalizeManualProcess
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.historyCompletionAction(
                metadataType: 3,
                historicalSyncActive: false,
                hasPendingProcess: false
            ),
            .ignore
        )
    }

}
