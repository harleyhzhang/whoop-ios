import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Batched packet insertion, deduplication, and offload progress.
extension WhoopStore {
    func insertBatch(
        _ envelopes: [WhoopPacketEnvelope],
        queueWaitNanoseconds: UInt64
    ) -> WhoopPacketBatchPersistenceResult {
        let signpost = WhoopRuntimeDiagnostics.signposter.beginInterval("PacketBatchCommit")
        defer {
            WhoopRuntimeDiagnostics.signposter.endInterval("PacketBatchCommit", signpost)
        }
        let telemetryStartedAt = DispatchTime.now().uptimeNanoseconds
        guard let database else {
            recordBatchTelemetry(
                envelopes: envelopes,
                outcomes: Array(repeating: .failed, count: envelopes.count),
                transactionNanoseconds: DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                queueWaitNanoseconds: queueWaitNanoseconds
            )
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: .unavailable(
                    operation: .beginTransaction,
                    detail: "database connection is unavailable"
                )
            )
        }
        if let injected = faultInjector.failure(for: .beginTransaction) {
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: injected
            )
        }
        let beginResult = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
        guard beginResult == SQLITE_OK else {
            recordBatchTelemetry(
                envelopes: envelopes,
                outcomes: Array(repeating: .failed, count: envelopes.count),
                transactionNanoseconds: DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                queueWaitNanoseconds: queueWaitNanoseconds
            )
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: .sqlite(
                    operation: .beginTransaction,
                    database: database,
                    resultCode: beginResult
                )
            )
        }
        #if DEBUG
            sqlite.ingestionTransactionCount += 1
        #endif
        let pendingStepDaysBeforeTransaction = pendingStepDateKeys
        var outcomes: [WhoopIngestionTelemetryOutcome] = []
        outcomes.reserveCapacity(envelopes.count)
        var deliverySequences: [Int64] = []
        deliverySequences.reserveCapacity(envelopes.count)
        var materializedStepDays: Set<String> = []

        for envelope in envelopes {
            if let injected = faultInjector.failure(for: .insert) {
                _ = execute("ROLLBACK")
                pendingStepDateKeys = pendingStepDaysBeforeTransaction
                recordBatchTelemetry(
                    envelopes: envelopes,
                    outcomes: Array(repeating: .failed, count: envelopes.count),
                    transactionNanoseconds:
                        DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                    queueWaitNanoseconds: queueWaitNanoseconds
                )
                return WhoopPacketBatchPersistenceResult(
                    success: false,
                    deliverySequences: [],
                    failure: injected
                )
            }
            guard
                let insertion = insertInOpenTransaction(
                    envelope,
                    database: database
                )
            else {
                _ = execute("ROLLBACK")
                pendingStepDateKeys = pendingStepDaysBeforeTransaction
                recordBatchTelemetry(
                    envelopes: envelopes,
                    outcomes: Array(repeating: .failed, count: envelopes.count),
                    transactionNanoseconds:
                        DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                    queueWaitNanoseconds: queueWaitNanoseconds
                )
                return WhoopPacketBatchPersistenceResult(
                    success: false,
                    deliverySequences: [],
                    failure: .sqlite(
                        operation: .insert,
                        database: database,
                        resultCode: sqlite3_errcode(database)
                    )
                )
            }
            outcomes.append(insertion.outcome)
            deliverySequences.append(insertion.deliverySequence)
            materializedStepDays.formUnion(insertion.materializedStepDays)
        }
        if let injected = faultInjector.failure(for: .commit) {
            _ = execute("ROLLBACK")
            pendingStepDateKeys = pendingStepDaysBeforeTransaction
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: injected
            )
        }
        let commitResult = sqlite3_exec(database, "COMMIT", nil, nil, nil)
        guard commitResult == SQLITE_OK else {
            _ = execute("ROLLBACK")
            pendingStepDateKeys = pendingStepDaysBeforeTransaction
            recordBatchTelemetry(
                envelopes: envelopes,
                outcomes: Array(repeating: .failed, count: envelopes.count),
                transactionNanoseconds: DispatchTime.now().uptimeNanoseconds - telemetryStartedAt,
                queueWaitNanoseconds: queueWaitNanoseconds
            )
            return WhoopPacketBatchPersistenceResult(
                success: false,
                deliverySequences: [],
                failure: .sqlite(
                    operation: .commit,
                    database: database,
                    resultCode: commitResult
                )
            )
        }
        let telemetryFinishedAt = DispatchTime.now().uptimeNanoseconds
        finishCommittedStepMaterialization(materializedStepDays)
        recordBatchTelemetry(
            envelopes: envelopes,
            outcomes: outcomes,
            transactionNanoseconds: telemetryFinishedAt - telemetryStartedAt,
            queueWaitNanoseconds: queueWaitNanoseconds
        )
        return WhoopPacketBatchPersistenceResult(
            success: true,
            deliverySequences: deliverySequences
        )
    }

    func recordBatchTelemetry(
        envelopes: [WhoopPacketEnvelope],
        outcomes: [WhoopIngestionTelemetryOutcome],
        transactionNanoseconds: UInt64,
        queueWaitNanoseconds: UInt64
    ) {
        guard storageTelemetry != nil, !envelopes.isEmpty else { return }
        let perEnvelopeTransaction = transactionNanoseconds / UInt64(envelopes.count)
        for (envelope, outcome) in zip(envelopes, outcomes) {
            storageTelemetry?.recordIngestion(
                outcome: outcome,
                transactionNanoseconds: perEnvelopeTransaction,
                queueWaitNanoseconds: queueWaitNanoseconds,
                frameType: envelope.frameType,
                payloadBytes: envelope.packet.count,
                retryDetectionEnabled: envelope.deduplicateTransportRetries,
                now: envelope.deliveredAt
            )
        }
    }

    struct OpenTransactionInsertion {
        let deliverySequence: Int64
        let outcome: WhoopIngestionTelemetryOutcome
        let materializedStepDays: Set<String>
    }

    func insertInOpenTransaction(
        _ envelope: WhoopPacketEnvelope,
        database: OpaquePointer
    ) -> OpenTransactionInsertion? {
        let packet = envelope.packet
        let deliveredAt = envelope.deliveredAt
        let deliverySequence = nextDeliverySequence
        nextDeliverySequence += 1
        let packetID = "p" + String(deliverySequence, radix: 36)
        let receivedAt = deliveredAt.timeIntervalSince1970
        let registration: PacketSignatureRegistration =
            envelope.deduplicateTransportRetries
            ? registerPacketSignature(
                database: database,
                signature: Self.packetSignature(
                    peripheralID: envelope.peripheralID,
                    characteristicUUID: envelope.characteristicUUID,
                    payload: packet
                ),
                packetID: packetID,
                receivedAt: receivedAt
            )
            : .new
        switch registration {
        case .duplicate(let canonicalPacketID):
            if let realtime = envelope.realtime,
                !insertRealtime(
                    database: database,
                    packetID: canonicalPacketID,
                    receivedAt: receivedAt,
                    realtime: realtime
                )
            {
                return nil
            }
            guard
                updateOffloadProgress(
                    database: database,
                    sessionID: envelope.offloadSessionID,
                    deliverySequence: deliverySequence,
                    packetID: canonicalPacketID,
                    metadata: envelope.metadata,
                    completedAt: deliveredAt
                ),
                let materializedStepDays = materializePendingStepsIfNeeded(
                    metadata: envelope.metadata,
                    database: database
                )
            else { return nil }
            return OpenTransactionInsertion(
                deliverySequence: deliverySequence,
                outcome: .retry,
                materializedStepDays: materializedStepDays
            )
        case .new:
            break
        case .failed:
            return nil
        }
        guard
            insertPacket(
                database: database,
                id: packetID,
                receivedAt: receivedAt,
                deliverySequence: deliverySequence,
                offloadSessionID: envelope.offloadSessionID,
                peripheralID: envelope.peripheralID.uuidString,
                characteristicUUID: envelope.characteristicUUID,
                frameType: envelope.frameType,
                integrityIsValid: envelope.integrityIsValid,
                payload: packet
            )
        else { return nil }
        if let realtime = envelope.realtime,
            !insertRealtime(
                database: database,
                packetID: packetID,
                receivedAt: receivedAt,
                realtime: realtime
            )
        {
            return nil
        }
        guard
            decodePacketIfNeeded(
                database: database,
                packetID: packetID,
                packet: packet,
                historical: envelope.historical,
                ppg: envelope.ppg,
                integrityIsValid: envelope.integrityIsValid
            ),
            updateOffloadProgress(
                database: database,
                sessionID: envelope.offloadSessionID,
                deliverySequence: deliverySequence,
                packetID: packetID,
                metadata: envelope.metadata,
                completedAt: deliveredAt
            ),
            let materializedStepDays = materializePendingStepsIfNeeded(
                metadata: envelope.metadata,
                database: database
            )
        else { return nil }
        return OpenTransactionInsertion(
            deliverySequence: deliverySequence,
            outcome: .unique,
            materializedStepDays: materializedStepDays
        )
    }

    enum PacketSignatureRegistration {
        case new
        case duplicate(String)
        case failed
    }

    /// Exact BLE transport retries contain no new evidence. Keep the first raw
    /// frame losslessly and aggregate later identical deliveries so a stuck
    /// history acknowledgement cannot grow the database by hundreds of MB.
    func registerPacketSignature(
        database: OpaquePointer,
        signature: Data,
        packetID: String,
        receivedAt: TimeInterval
    ) -> PacketSignatureRegistration {
        let sql = """
            INSERT INTO whoop_packet_replay
            (signature, first_packet_id, duplicate_count, last_received_at)
            VALUES (?, ?, 0, ?)
            ON CONFLICT(signature) DO UPDATE SET
                duplicate_count = whoop_packet_replay.duplicate_count + 1,
                last_received_at = excluded.last_received_at
            RETURNING first_packet_id
            """
        let canonicalPacketID: String? =
            withCachedStatement(database: database, sql: sql) { statement in
                bind(signature, to: 1, in: statement)
                bind(packetID, to: 2, in: statement)
                sqlite3_bind_double(statement, 3, receivedAt)
                guard sqlite3_step(statement) == SQLITE_ROW,
                    let returnedPacketID = textColumn(statement, 0),
                    sqlite3_step(statement) == SQLITE_DONE
                else { return nil }
                return returnedPacketID
            } ?? nil
        guard let canonicalPacketID else { return .failed }
        return canonicalPacketID == packetID ? .new : .duplicate(canonicalPacketID)
    }

    static func packetSignature(
        peripheralID: UUID,
        characteristicUUID: String,
        payload: Data
    ) -> Data {
        var input = Data(peripheralID.uuidString.lowercased().utf8)
        input.append(0)
        input.append(contentsOf: characteristicUUID.uppercased().utf8)
        input.append(0)
        input.append(payload)
        return Data(SHA256.hash(data: input))
    }

    func insertPacket(
        database: OpaquePointer,
        id: String,
        receivedAt: TimeInterval,
        deliverySequence: Int64,
        offloadSessionID: String?,
        peripheralID: String,
        characteristicUUID: String,
        frameType: FrameType?,
        integrityIsValid: Bool,
        payload: Data
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_raw_packet
            (id, received_at, delivery_sequence, offload_session_id, peripheral_id,
             characteristic_uuid, frame_type, protocol_version, crc_valid, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(id, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, receivedAt)
            sqlite3_bind_int64(statement, 3, deliverySequence)
            bind(offloadSessionID, to: 4, in: statement)
            bind(peripheralID, to: 5, in: statement)
            bind(characteristicUUID, to: 6, in: statement)
            if let frameType {
                sqlite3_bind_int(statement, 7, Int32(frameType.rawValue))
            } else {
                sqlite3_bind_null(statement, 7)
            }
            if payload.count > 9 {
                sqlite3_bind_int(statement, 8, Int32(payload[9]))
            } else {
                sqlite3_bind_null(statement, 8)
            }
            sqlite3_bind_int(statement, 9, integrityIsValid ? 1 : 0)
            _ = payload.withUnsafeBytes {
                sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32($0.count), Self.transient)
            }
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    func updateOffloadProgress(
        database: OpaquePointer,
        sessionID: String?,
        deliverySequence: Int64,
        packetID: String,
        metadata: WhoopHistoricalMetadata?,
        completedAt: Date
    ) -> Bool {
        guard let sessionID else { return true }
        let isCompletion = metadata?.type == .historyComplete
        let sql: String
        if isCompletion {
            sql = """
                UPDATE whoop_offload_session
                SET first_sequence = COALESCE(first_sequence, ?),
                    last_sequence = ?, completion_sequence = ?,
                    completion_packet_id = ?, completed_at = ?,
                    status = 'complete', failure_reason = NULL
                WHERE id = ? AND status = 'in_progress'
                """
        } else {
            sql = """
                UPDATE whoop_offload_session
                SET first_sequence = COALESCE(first_sequence, ?), last_sequence = ?
                WHERE id = ? AND status = 'in_progress'
                """
        }
        return withCachedStatement(database: database, sql: sql) { statement in
            sqlite3_bind_int64(statement, 1, deliverySequence)
            sqlite3_bind_int64(statement, 2, deliverySequence)
            if isCompletion {
                sqlite3_bind_int64(statement, 3, deliverySequence)
                bind(packetID, to: 4, in: statement)
                sqlite3_bind_double(statement, 5, completedAt.timeIntervalSince1970)
                bind(sessionID, to: 6, in: statement)
            } else {
                bind(sessionID, to: 3, in: statement)
            }
            return sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(database) == 1
        } ?? false
    }

    func abandonInterruptedOffloads() {
        _ = execute(
            """
            UPDATE whoop_offload_session
            SET status = 'abandoned', completed_at = strftime('%s','now'),
                failure_reason = 'app relaunched before completion'
            WHERE status = 'in_progress'
            """)
    }
}
