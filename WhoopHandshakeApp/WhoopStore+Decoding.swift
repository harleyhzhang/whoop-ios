import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Packet decoding and versioned backfills.
extension WhoopStore {
    func decodePacketIfNeeded(
        database: OpaquePointer,
        packetID: String,
        packet: Data,
        historical: WhoopDecodedHistorical?,
        ppg: WhoopDecodedPPG? = nil,
        integrityIsValid: Bool? = nil
    ) -> Bool {
        guard packet.count > 9, packet[8] == 47 else { return true }
        let protocolVersion = Int(packet[9])

        if let historical {
            return insertHistorical(
                database: database,
                packetID: packetID,
                sample: historical
            )
        } else if integrityIsValid == nil,
            let historical = WhoopDecodedHistorical.decode(packet)
        {
            return insertHistorical(
                database: database,
                packetID: packetID,
                sample: historical
            )
        } else if let ppg {
            return insertPPG(database: database, packetID: packetID, packet: ppg)
        } else if integrityIsValid == nil,
            let ppg = WhoopDecodedPPG.decode(packet)
        {
            return insertPPG(database: database, packetID: packetID, packet: ppg)
        }

        let integrityIsValid = integrityIsValid ?? WhoopFrameIntegrity.isValid(packet)
        return insertDecodeFailure(
            database: database,
            packetID: packetID,
            protocolVersion: protocolVersion,
            status: integrityIsValid ? "unsupported" : "rejected",
            error: integrityIsValid
                ? "unsupported type-47 version \(protocolVersion), length \(packet.count)"
                : "CRC mismatch"
        )
    }

    func insertDecodeFailure(
        database: OpaquePointer,
        packetID: String,
        protocolVersion: Int,
        status: String,
        error: String
    ) -> Bool {
        let sql = """
            INSERT OR IGNORE INTO whoop_decode_failure
            (source_packet_id, decoder_version, protocol_version, stream, status, error, decoded_at)
            VALUES (?, ?, ?, 'historical_unknown', ?, ?, ?)
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(packetID, to: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(Self.decoderVersion))
            sqlite3_bind_int(statement, 3, Int32(protocolVersion))
            bind(status, to: 4, in: statement)
            bind(error, to: 5, in: statement)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    func insertPPG(
        database: OpaquePointer,
        packetID: String,
        packet: WhoopDecodedPPG
    ) -> Bool {
        var samples = Data(capacity: packet.samples.count * 2)
        for sample in packet.samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { samples.append(contentsOf: $0) }
        }
        let sql = """
            INSERT INTO whoop_ppg_packet
            (source_packet_id, sample_at, channel, sample_rate_hz, samples_i16_le, decoder_version)
            VALUES (?, ?, ?, 24, ?, ?)
            ON CONFLICT(source_packet_id) DO UPDATE SET
                sample_at = excluded.sample_at,
                channel = excluded.channel,
                sample_rate_hz = excluded.sample_rate_hz,
                samples_i16_le = excluded.samples_i16_le,
                decoder_version = excluded.decoder_version
            """
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(packetID, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, packet.sampleAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(packet.channel))
            bind(samples, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(Self.decoderVersion))
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    /// Decoder upgrades are replayed from immutable raw evidence. The legacy
    /// v18 summary table was already backfilled by schema v1; decoder v2 adds
    /// the previously ignored v26 optical stream in bounded transactions so a
    /// large phone database remains responsive during migration.
    func backfillVersion26PPG(cursor: Int64 = 0, batchSize: Int = 500) {
        guard let database,
            metadataValue(database: database, key: "decoder-2-v26-backfill") != "complete"
        else {
            return
        }
        let sql = """
            SELECT rowid, id, payload
            FROM whoop_raw_packet
            WHERE rowid > ?
              AND frame_type = \(FrameType.historicalSample.rawValue)
              AND length(payload) = 88
              AND hex(substr(payload, 10, 1)) = '1A'
            ORDER BY rowid
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int(statement, 2, Int32(batchSize))
        var rows: [(Int64, String, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = textColumn(statement, 1), let payload = dataColumn(statement, 2) {
                rows.append((sqlite3_column_int64(statement, 0), id, payload))
            }
        }
        sqlite3_finalize(statement)

        guard !rows.isEmpty else {
            _ = setMetadataValue(
                database: database,
                key: "decoder-2-v26-backfill",
                value: "complete"
            )
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for (_, packetID, payload) in rows {
            guard
                decodePacketIfNeeded(
                    database: database,
                    packetID: packetID,
                    packet: payload,
                    historical: nil
                )
            else {
                execute("ROLLBACK")
                return
            }
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
        guard let nextCursor = rows.last?.0 else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
            backfillVersion26PPG(cursor: nextCursor, batchSize: batchSize)
        }
    }

    /// Materializes the candidate counter/cadence/class bytes that older app
    /// versions preserved only inside immutable v18 packets. Work is bounded
    /// so upgrading a phone-sized store cannot monopolize the store queue.
    func backfillVersion18Motion(cursor: Int64 = 0, batchSize: Int = 1_000) {
        guard let database,
            metadataValue(database: database, key: "decoder-3-v18-motion-backfill") != "complete"
        else {
            return
        }
        let sql = """
            SELECT rowid, id, payload
            FROM whoop_raw_packet
            WHERE rowid > ?
              AND frame_type = \(FrameType.historicalSample.rawValue)
              AND length(payload) = 124
              AND hex(substr(payload, 10, 1)) = '12'
            ORDER BY rowid
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int(statement, 2, Int32(batchSize))
        var rows: [(Int64, String, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = textColumn(statement, 1), let payload = dataColumn(statement, 2) {
                rows.append((sqlite3_column_int64(statement, 0), id, payload))
            }
        }
        sqlite3_finalize(statement)

        guard !rows.isEmpty else {
            // Re-derive the durable set instead of trusting the in-memory set.
            // If the app was suspended mid-backfill, packets decoded before
            // that restart no longer appear in `pendingStepDateKeys`.
            guard let changedDays = allStoredStepDateKeys(database: database),
                execute("BEGIN IMMEDIATE")
            else { return }
            guard rebuildDailySteps(for: changedDays, database: database),
                setMetadataValue(
                    database: database,
                    key: "decoder-3-v18-motion-backfill",
                    value: "complete"
                ),
                execute("COMMIT")
            else {
                execute("ROLLBACK")
                return
            }
            pendingStepDateKeys.removeAll(keepingCapacity: true)
            if !changedDays.isEmpty { publishStepUpdate() }
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for (_, packetID, payload) in rows {
            guard
                decodePacketIfNeeded(
                    database: database,
                    packetID: packetID,
                    packet: payload,
                    historical: nil
                )
            else {
                execute("ROLLBACK")
                return
            }
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
        guard let nextCursor = rows.last?.0 else { return }
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
            backfillVersion18Motion(cursor: nextCursor, batchSize: batchSize)
        }
    }
}
