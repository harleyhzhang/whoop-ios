import Foundation
import SQLite3

/// Revisions are updated in the same transaction as samples, including imports,
/// corrections and deletes. UTC buckets also cover samples with unknown offsets.
/// They let the reader refresh only changed slices without rescanning the archive.
enum WhoopStrainInputIndex {
    static func isInstalled(in database: OpaquePointer) -> Bool {
        let sql = """
            SELECT COUNT(*) FROM sqlite_master
            WHERE (type='table' AND name='whoop_strain_input_revision')
               OR (type='trigger' AND name IN ('whoop_strain_input_insert',
                   'whoop_strain_input_update', 'whoop_strain_input_delete'))
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 4
    }

    static let latestPeripheralQuery = """
        SELECT peripheral_id FROM (
            SELECT peripheral_id,
                (SELECT MAX(sample_at) FROM whoop_historical_sample h
                 WHERE h.peripheral_id = r.peripheral_id) AS latest
            FROM whoop_strain_input_revision r GROUP BY peripheral_id
        ) WHERE latest IS NOT NULL ORDER BY latest DESC LIMIT 1
        """

    static let schema = """
        CREATE TABLE whoop_strain_input_revision (
            peripheral_id TEXT NOT NULL,
            utc_day INTEGER NOT NULL,
            revision INTEGER NOT NULL,
            sample_count INTEGER NOT NULL,
            PRIMARY KEY(peripheral_id, utc_day)
        ) WITHOUT ROWID;
        INSERT INTO whoop_strain_input_revision
        SELECT peripheral_id, CAST(sample_at / 86400 AS INTEGER), 1, COUNT(*)
        FROM whoop_historical_sample GROUP BY 1, 2;
        CREATE TRIGGER whoop_strain_input_insert AFTER INSERT ON whoop_historical_sample BEGIN
            INSERT INTO whoop_strain_input_revision VALUES
                (NEW.peripheral_id, CAST(NEW.sample_at / 86400 AS INTEGER), 1, 1)
            ON CONFLICT(peripheral_id, utc_day) DO UPDATE SET revision = revision + 1, sample_count = sample_count + excluded.sample_count;
        END;
        CREATE TRIGGER whoop_strain_input_delete AFTER DELETE ON whoop_historical_sample BEGIN
            INSERT INTO whoop_strain_input_revision VALUES
                (OLD.peripheral_id, CAST(OLD.sample_at / 86400 AS INTEGER), 1, -1)
            ON CONFLICT(peripheral_id, utc_day) DO UPDATE SET revision = revision + 1, sample_count = sample_count + excluded.sample_count;
        END;
        CREATE TRIGGER whoop_strain_input_update AFTER UPDATE ON whoop_historical_sample
        WHEN OLD.sample_at IS NOT NEW.sample_at OR OLD.peripheral_id IS NOT NEW.peripheral_id
          OR OLD.step_utc_offset_seconds IS NOT NEW.step_utc_offset_seconds
          OR OLD.heart_rate IS NOT NEW.heart_rate OR OLD.step_motion_counter IS NOT NEW.step_motion_counter
          OR OLD.sleep_state IS NOT NEW.sleep_state OR OLD.ordinal IS NOT NEW.ordinal
          OR OLD.id IS NOT NEW.id
        BEGIN
            INSERT INTO whoop_strain_input_revision VALUES
                (OLD.peripheral_id, CAST(OLD.sample_at / 86400 AS INTEGER), 1, -1)
            ON CONFLICT(peripheral_id, utc_day) DO UPDATE SET revision = revision + 1, sample_count = sample_count + excluded.sample_count;
            INSERT INTO whoop_strain_input_revision VALUES
                (NEW.peripheral_id, CAST(NEW.sample_at / 86400 AS INTEGER), 1, 1)
            ON CONFLICT(peripheral_id, utc_day) DO UPDATE SET revision = revision + 1, sample_count = sample_count + excluded.sample_count;
        END;
        """
}
