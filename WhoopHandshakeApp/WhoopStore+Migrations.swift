import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Versioned schema migrations.
extension WhoopStore {
    func migrateSchema() -> Bool {
        guard let database,
            let current = try? scalarInt(database, sql: "PRAGMA user_version"),
            current <= targetSchemaVersion
        else { return false }
        guard current < targetSchemaVersion else { return true }
        for version in (Int(current) + 1)...targetSchemaVersion {
            do {
                try withTransaction(.immediate) { database in
                    guard applyMigration(version), execute("PRAGMA user_version = \(version)") else {
                        throw StoreError.queryFailed(errorMessage(database))
                    }
                }
            } catch {
                return false
            }
        }
        return true
    }

    func applyMigration(_ version: Int) -> Bool {
        switch version {
        case 1:
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_raw_packet (
                    id TEXT PRIMARY KEY,
                    received_at REAL NOT NULL,
                    peripheral_id TEXT NOT NULL,
                    characteristic_uuid TEXT NOT NULL,
                    frame_type INTEGER,
                    payload BLOB NOT NULL
                )
                """)
                && execute("CREATE INDEX IF NOT EXISTS whoop_raw_packet_received_at ON whoop_raw_packet(received_at)")
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS heart_rate_sample (
                        id TEXT PRIMARY KEY,
                        source_packet_id TEXT NOT NULL,
                        received_at REAL NOT NULL,
                        device_timestamp INTEGER,
                        heart_rate INTEGER NOT NULL,
                        rr_intervals_json TEXT NOT NULL,
                        source TEXT NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute("CREATE INDEX IF NOT EXISTS heart_rate_sample_received_at ON heart_rate_sample(received_at)")
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_historical_sample (
                        sample_at REAL PRIMARY KEY,
                        source_packet_id TEXT NOT NULL,
                        heart_rate INTEGER NOT NULL,
                        rr_intervals_json TEXT NOT NULL,
                        sleep_state INTEGER NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_historical_sample_sleep_state ON whoop_historical_sample(sleep_state, sample_at)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_packet_replay (
                        signature BLOB PRIMARY KEY,
                        first_packet_id TEXT NOT NULL,
                        duplicate_count INTEGER NOT NULL DEFAULT 0,
                        last_received_at REAL NOT NULL
                    )
                    """)
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS daily_health_metric (
                        date_key TEXT PRIMARY KEY,
                        sleep_score REAL,
                        sleep_duration_minutes REAL,
                        hrv_rmssd_milliseconds REAL,
                        resting_heart_rate_bpm REAL,
                        sleep_id TEXT,
                        cycle_id INTEGER,
                        source TEXT NOT NULL,
                        source_archive TEXT,
                        source_updated_at TEXT NOT NULL,
                        imported_at REAL NOT NULL
                    )
                    """)
        case 2:
            return addColumnIfNeeded(
                table: "whoop_raw_packet",
                column: "delivery_sequence",
                declaration: "INTEGER"
            )
                && addColumnIfNeeded(
                    table: "whoop_raw_packet",
                    column: "protocol_version",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_raw_packet",
                    column: "crc_valid",
                    declaration: "INTEGER"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_raw_packet_delivery_sequence ON whoop_raw_packet(delivery_sequence)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_decode_result (
                        source_packet_id TEXT NOT NULL,
                        decoder_version INTEGER NOT NULL,
                        protocol_version INTEGER,
                        stream TEXT NOT NULL,
                        status TEXT NOT NULL,
                        error TEXT,
                        decoded_at REAL NOT NULL,
                        PRIMARY KEY(source_packet_id, decoder_version),
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_decode_result_status ON whoop_decode_result(decoder_version, status)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_ppg_packet (
                        source_packet_id TEXT PRIMARY KEY,
                        sample_at REAL NOT NULL,
                        channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 255),
                        sample_rate_hz REAL NOT NULL,
                        samples_i16_le BLOB NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_ppg_packet_sample_at ON whoop_ppg_packet(sample_at, channel)")
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_store_metadata (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                    """)
        case 3:
            return addColumnIfNeeded(
                table: "whoop_raw_packet",
                column: "offload_session_id",
                declaration: "TEXT"
            )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_offload_session (
                        id TEXT PRIMARY KEY,
                        peripheral_id TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        completed_at REAL,
                        first_sequence INTEGER,
                        last_sequence INTEGER,
                        completion_sequence INTEGER,
                        completion_packet_id TEXT,
                        status TEXT NOT NULL CHECK(status IN ('in_progress','complete','abandoned')),
                        failure_reason TEXT,
                        FOREIGN KEY(completion_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_offload_session_status ON whoop_offload_session(status, completed_at)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_raw_packet_offload_session ON whoop_raw_packet(offload_session_id, delivery_sequence)"
                )
                && execute(
                    """
                    UPDATE whoop_offload_session
                    SET status = 'abandoned', completed_at = strftime('%s','now'),
                        failure_reason = 'app relaunched before completion'
                    WHERE status = 'in_progress'
                    """)
        case 4:
            return execute(
                """
                CREATE TABLE whoop_historical_sample_v4 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sample_at REAL NOT NULL,
                    source_packet_id TEXT NOT NULL UNIQUE,
                    peripheral_id TEXT NOT NULL,
                    protocol_version INTEGER NOT NULL,
                    ordinal INTEGER NOT NULL DEFAULT 0,
                    heart_rate INTEGER NOT NULL CHECK(heart_rate BETWEEN 0 AND 255),
                    rr_intervals_json TEXT NOT NULL,
                    sleep_state INTEGER NOT NULL CHECK(sleep_state BETWEEN 0 AND 3),
                    decoder_version INTEGER NOT NULL,
                    UNIQUE(peripheral_id, protocol_version, sample_at, ordinal),
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                )
                """)
                && execute(
                    """
                    INSERT INTO whoop_historical_sample_v4
                    (sample_at, source_packet_id, peripheral_id, protocol_version,
                     ordinal, heart_rate, rr_intervals_json, sleep_state, decoder_version)
                    SELECT h.sample_at, h.source_packet_id,
                           COALESCE(p.peripheral_id, 'legacy-unknown'),
                           COALESCE(p.protocol_version, 18), 0,
                           h.heart_rate, h.rr_intervals_json, h.sleep_state, 1
                    FROM whoop_historical_sample h
                    LEFT JOIN whoop_raw_packet p ON p.id = h.source_packet_id
                    """)
                && execute("DROP TABLE whoop_historical_sample")
                && execute("ALTER TABLE whoop_historical_sample_v4 RENAME TO whoop_historical_sample")
                && execute(
                    "CREATE INDEX whoop_historical_sample_sleep_state ON whoop_historical_sample(peripheral_id, sleep_state, sample_at)"
                )
                && execute(
                    "CREATE INDEX whoop_historical_sample_sample_at ON whoop_historical_sample(peripheral_id, sample_at)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS heart_rate_sample_source_time ON heart_rate_sample(source, device_timestamp, received_at)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS heart_rate_sample_source_received ON heart_rate_sample(source, received_at)"
                )
        case 5:
            return addColumnIfNeeded(
                table: "daily_health_metric", column: "sleep_start_at", declaration: "TEXT"
            )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_end_at", declaration: "TEXT"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_start_minute", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_end_minute", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_need_minutes", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_consistency_percentage", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_efficiency_percentage", declaration: "REAL"
                )
                && addColumnIfNeeded(
                    table: "daily_health_metric", column: "sleep_sufficiency_percentage", declaration: "REAL"
                )
        case 6:
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_api_source_record (
                    date_key TEXT PRIMARY KEY,
                    sleep_payload_json TEXT NOT NULL,
                    recovery_payload_json TEXT,
                    source_archive TEXT,
                    imported_at REAL NOT NULL,
                    FOREIGN KEY(date_key) REFERENCES daily_health_metric(date_key)
                )
                """)
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_api_numeric_metric (
                        date_key TEXT NOT NULL,
                        source_kind TEXT NOT NULL CHECK(source_kind IN ('sleep','recovery')),
                        field_path TEXT NOT NULL,
                        value REAL NOT NULL,
                        PRIMARY KEY(date_key, source_kind, field_path),
                        FOREIGN KEY(date_key) REFERENCES whoop_api_source_record(date_key)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_api_numeric_metric_path ON whoop_api_numeric_metric(source_kind, field_path, date_key)"
                )
        case 7:
            // A travel-safe provenance timeline. Raw timestamps remain
            // absolute; this captures the local civil-time context needed to
            // reproduce timing consistency after the phone changes zones.
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_time_zone_observation (
                    observed_at REAL PRIMARY KEY,
                    time_zone_identifier TEXT NOT NULL,
                    utc_offset_seconds INTEGER NOT NULL
                )
                """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_time_zone_observation_zone ON whoop_time_zone_observation(time_zone_identifier, observed_at)"
                )
        case 8:
            // Version-18 packets already contain these candidate motion
            // fields. Materialize them without replacing their immutable raw
            // packet, then keep the UI-facing daily total in a separate table
            // with coverage and derivation provenance.
            return addColumnIfNeeded(
                table: "whoop_historical_sample",
                column: "step_motion_counter",
                declaration: "INTEGER"
            )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "step_cadence_raw",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "motion_class_raw",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "step_utc_offset_seconds",
                    declaration: "INTEGER"
                )
                && addColumnIfNeeded(
                    table: "whoop_historical_sample",
                    column: "step_date_key",
                    declaration: "TEXT"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_historical_sample_step_day ON whoop_historical_sample(step_date_key, peripheral_id, sample_at)"
                )
                && execute(
                    """
                        CREATE TABLE IF NOT EXISTS whoop_daily_step_metric (
                            date_key TEXT PRIMARY KEY,
                            peripheral_id TEXT NOT NULL,
                            step_count INTEGER NOT NULL CHECK(step_count >= 0),
                            sample_count INTEGER NOT NULL CHECK(sample_count >= 0),
                            span_seconds INTEGER NOT NULL CHECK(span_seconds >= 0),
                            coverage_fraction REAL NOT NULL CHECK(coverage_fraction BETWEEN 0 AND 1),
                            gap_seconds INTEGER NOT NULL CHECK(gap_seconds >= 0),
                            counter_wrap_count INTEGER NOT NULL CHECK(counter_wrap_count >= 0),
                            rejected_delta_count INTEGER NOT NULL CHECK(rejected_delta_count >= 0),
                            first_sample_at REAL,
                            last_sample_at REAL,
                            source TEXT NOT NULL,
                            algorithm_version INTEGER NOT NULL,
                            derived_at REAL NOT NULL
                        )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_daily_step_metric_last_sample ON whoop_daily_step_metric(last_sample_at)"
                )
        case 9:
            // WHOOP cloud targets remain independent of local predictions so
            // every model version can be backtested without overwriting its
            // answer key. The UI reads a COALESCE projection only at query time.
            return execute(
                """
                CREATE TABLE IF NOT EXISTS whoop_official_daily_metric (
                    date_key TEXT PRIMARY KEY,
                    official_recovery_score REAL,
                    official_steps INTEGER,
                    official_day_strain REAL,
                    day_strain_target REAL,
                    steps_baseline REAL,
                    hrv REAL,
                    hrv_baseline REAL,
                    rhr REAL,
                    rhr_baseline REAL,
                    respiratory_rate REAL,
                    respiratory_rate_baseline REAL,
                    sleep_performance REAL,
                    sleep_performance_baseline REAL,
                    source_recovery_sha256 TEXT,
                    source_strain_sha256 TEXT,
                    source_archive TEXT NOT NULL,
                    source_manifest_sha256 TEXT NOT NULL,
                    imported_at REAL NOT NULL
                )
                """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_official_daily_recovery ON whoop_official_daily_metric(official_recovery_score, date_key)"
                )
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_official_daily_steps ON whoop_official_daily_metric(official_steps, date_key)"
                )
                && execute(
                    """
                    CREATE TABLE IF NOT EXISTS whoop_daily_recovery_metric (
                        date_key TEXT PRIMARY KEY,
                        score REAL NOT NULL CHECK(score BETWEEN 0 AND 100),
                        confidence REAL NOT NULL CHECK(confidence BETWEEN 0 AND 1),
                        hrv_component REAL,
                        rhr_component REAL,
                        sleep_component REAL,
                        steps_component REAL,
                        hrv_baseline REAL,
                        rhr_baseline REAL,
                        sleep_baseline REAL,
                        steps_baseline REAL,
                        input_json TEXT NOT NULL,
                        model_version TEXT NOT NULL,
                        derived_at REAL NOT NULL,
                        FOREIGN KEY(date_key) REFERENCES daily_health_metric(date_key)
                    )
                    """)
                && execute(
                    "CREATE INDEX IF NOT EXISTS whoop_daily_recovery_model ON whoop_daily_recovery_metric(model_version, date_key)"
                )
        case 10:
            // The raw packet remains the lossless evidence layer. Realtime
            // rows without R-R intervals are only a cache of data already in
            // that packet, so retain one latest-value projection and keep the
            // full indexed history only where it can contribute to HRV.
            return execute(
                """
                CREATE TABLE whoop_latest_heart_rate (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    heart_rate INTEGER NOT NULL CHECK(heart_rate > 0),
                    received_at REAL NOT NULL
                )
                """)
                && execute(
                    """
                    INSERT INTO whoop_latest_heart_rate(singleton, heart_rate, received_at)
                    SELECT 1, heart_rate, received_at
                    FROM heart_rate_sample
                    WHERE heart_rate > 0
                    ORDER BY received_at DESC
                    LIMIT 1
                    """)
                && execute(
                    """
                    CREATE TABLE heart_rate_sample_v10 (
                        source_packet_id TEXT PRIMARY KEY,
                        received_at REAL NOT NULL,
                        device_timestamp INTEGER,
                        heart_rate INTEGER NOT NULL,
                        rr_intervals_json TEXT NOT NULL CHECK(rr_intervals_json != '[]'),
                        source TEXT NOT NULL,
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    """
                    INSERT INTO heart_rate_sample_v10
                    (source_packet_id, received_at, device_timestamp,
                     heart_rate, rr_intervals_json, source)
                    SELECT source_packet_id, received_at, device_timestamp,
                           heart_rate, rr_intervals_json, source
                    FROM heart_rate_sample
                    WHERE rr_intervals_json != '[]'
                    """)
                && execute("DROP TABLE heart_rate_sample")
                && execute("ALTER TABLE heart_rate_sample_v10 RENAME TO heart_rate_sample")
                && execute(
                    "CREATE INDEX heart_rate_sample_source_time ON heart_rate_sample(source, device_timestamp, received_at)"
                )
                && execute(
                    "CREATE INDEX heart_rate_sample_source_received ON heart_rate_sample(source, received_at)"
                )
                && addColumnIfNeeded(
                    table: "whoop_ppg_packet",
                    column: "decoder_version",
                    declaration: "INTEGER NOT NULL DEFAULT 2"
                )
                && execute(
                    """
                    CREATE TABLE whoop_decode_failure (
                        source_packet_id TEXT NOT NULL,
                        decoder_version INTEGER NOT NULL,
                        protocol_version INTEGER,
                        stream TEXT NOT NULL,
                        status TEXT NOT NULL CHECK(status IN ('unsupported','rejected')),
                        error TEXT,
                        decoded_at REAL NOT NULL,
                        PRIMARY KEY(source_packet_id, decoder_version),
                        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                    )
                    """)
                && execute(
                    """
                    INSERT INTO whoop_decode_failure
                    (source_packet_id, decoder_version, protocol_version,
                     stream, status, error, decoded_at)
                    SELECT source_packet_id, decoder_version, protocol_version,
                           stream, status, error, decoded_at
                    FROM whoop_decode_result
                    WHERE status != 'decoded'
                    """)
                && execute("DROP TABLE whoop_decode_result")
        default:
            return false
        }
    }
}
