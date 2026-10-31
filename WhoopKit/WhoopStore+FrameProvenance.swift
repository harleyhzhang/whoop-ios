import CryptoKit
import Foundation
import SQLite3

extension WhoopStore {
    /// Called inside the raw/frame transaction, including exact frame retries.
    /// A missing source or bad range rolls back the entire batch before ACK.
    func insertFrameProvenance(
        _ envelope: WhoopPacketEnvelope, frameID: String, database: OpaquePointer
    ) -> Bool {
        guard case .reconstructed(let sources) = envelope.provenance else { return true }
        guard !sources.isEmpty, sources.count <= 256 else { return false }
        do {
            var reconstructed = Data()
            for source in sources {
                let rows: [Data] = try SQLiteRead.rows(
                    database,
                    sql:
                        "SELECT payload FROM whoop_raw_packet WHERE id=? AND peripheral_id=? AND characteristic_uuid=?",
                    bindings: [
                        .text(source.packetID), .text(envelope.peripheralID.uuidString),
                        .text(envelope.characteristicUUID),
                    ]
                ) { statement in
                    guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
                    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                }
                guard let packet = rows.first, rows.count == 1,
                    source.offset >= 0, source.length > 0,
                    source.offset <= packet.count, source.length <= packet.count - source.offset,
                    SHA256.hash(data: packet).map({ String(format: "%02x", $0) }).joined() == source.sha256
                else { return false }
                reconstructed.append(packet.subdata(in: source.offset..<source.offset + source.length))
            }
            guard reconstructed == envelope.packet else { return false }
            for source in sources {
                let sql = """
                    INSERT OR IGNORE INTO whoop_frame_source
                    (frame_packet_id,source_packet_id,source_sha256,source_offset,source_length,connection_generation)
                    VALUES (?,?,?,?,?,?)
                    """
                guard
                    withCachedStatement(
                        database: database, sql: sql,
                        { statement in
                            bind(frameID, to: 1, in: statement)
                            bind(source.packetID, to: 2, in: statement)
                            bind(source.sha256, to: 3, in: statement)
                            sqlite3_bind_int64(statement, 4, Int64(source.offset))
                            sqlite3_bind_int64(statement, 5, Int64(source.length))
                            bind(String(envelope.connectionToken?.generation ?? 0), to: 6, in: statement)
                            return sqlite3_step(statement) == SQLITE_DONE
                        }) == true
                else { return false }
            }
            return true
        } catch { return false }
    }
}
