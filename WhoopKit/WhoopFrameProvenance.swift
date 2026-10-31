import Foundation
import SQLite3

/// Original notification IDs remain immutable; reconstructed frames point to
/// exact slices rather than pretending a BLE delivery contained a whole frame.
enum WhoopFrameProvenance: Sendable {
    case notification(packetID: String)
    case reconstructed([WhoopFrameSource])

    var notificationID: String? {
        if case .notification(let id) = self { return id }
        return nil
    }
    var isReconstructed: Bool {
        if case .reconstructed = self { return true }
        return false
    }
    static let schema = """
        CREATE TABLE whoop_frame_source (
            frame_packet_id TEXT NOT NULL REFERENCES whoop_raw_packet(id),
            source_packet_id TEXT NOT NULL REFERENCES whoop_raw_packet(id),
            source_sha256 TEXT NOT NULL,
            source_offset INTEGER NOT NULL CHECK(source_offset >= 0),
            source_length INTEGER NOT NULL CHECK(source_length > 0),
            connection_generation TEXT NOT NULL,
            PRIMARY KEY(frame_packet_id, source_packet_id, source_offset, source_length)
        );
        CREATE INDEX whoop_frame_source_notification ON whoop_frame_source(source_packet_id);
        """
    static func isInstalled(in database: OpaquePointer) -> Bool {
        (try? SQLiteRead.requiredInteger(
            database,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_frame_source'")) == 1
    }
}
