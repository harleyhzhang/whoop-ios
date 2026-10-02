"""Schema and representative-query definitions for the v11 storage prototype."""

from __future__ import annotations

import sqlite3
from collections.abc import Sequence

SOURCE_SCHEMA_VERSION = 10
CANDIDATE_SCHEMA_VERSION = 11

AFFECTED_TABLES = (
    "heart_rate_sample",
    "whoop_decode_failure",
    "whoop_historical_sample",
    "whoop_offload_session",
    "whoop_packet_replay",
    "whoop_ppg_packet",
    "whoop_raw_packet",
)

SEMANTIC_SOURCE_QUERIES = {
    "whoop_raw_packet": """
        SELECT r.rowid, r.received_at, r.delivery_sequence, r.offload_session_id,
               r.peripheral_id, r.characteristic_uuid, r.frame_type,
               r.protocol_version, r.crc_valid, r.payload
        FROM whoop_raw_packet r ORDER BY r.rowid
    """,
    "whoop_offload_session": """
        SELECT s.rowid, s.id, s.peripheral_id, s.started_at, s.completed_at,
               s.first_sequence, s.last_sequence, s.completion_sequence,
               r.rowid, s.status, s.failure_reason
        FROM whoop_offload_session s
        LEFT JOIN whoop_raw_packet r ON r.id=s.completion_packet_id
        ORDER BY s.rowid
    """,
    "heart_rate_sample": """
        SELECT r.rowid, h.received_at, h.device_timestamp, h.heart_rate,
               h.rr_intervals_json, h.source
        FROM heart_rate_sample h
        JOIN whoop_raw_packet r ON r.id=h.source_packet_id
        ORDER BY r.rowid
    """,
    "whoop_historical_sample": """
        SELECT r.rowid, h.sample_at, h.peripheral_id, h.protocol_version, h.ordinal,
               h.heart_rate, h.rr_intervals_json, h.sleep_state, h.decoder_version,
               h.step_motion_counter, h.step_cadence_raw, h.motion_class_raw,
               h.step_utc_offset_seconds, h.step_date_key
        FROM whoop_historical_sample h
        JOIN whoop_raw_packet r ON r.id=h.source_packet_id
        ORDER BY r.rowid
    """,
    "whoop_packet_replay": """
        SELECT x.signature, r.rowid, x.duplicate_count, x.last_received_at
        FROM whoop_packet_replay x
        JOIN whoop_raw_packet r ON r.id=x.first_packet_id
        ORDER BY x.signature
    """,
    "whoop_ppg_packet": """
        SELECT r.rowid, p.sample_at, p.channel, p.sample_rate_hz,
               p.samples_i16_le, p.decoder_version
        FROM whoop_ppg_packet p
        JOIN whoop_raw_packet r ON r.id=p.source_packet_id
        ORDER BY r.rowid
    """,
    "whoop_decode_failure": """
        SELECT r.rowid, d.decoder_version, d.protocol_version, d.stream,
               d.status, d.error, d.decoded_at
        FROM whoop_decode_failure d
        JOIN whoop_raw_packet r ON r.id=d.source_packet_id
        ORDER BY r.rowid, d.decoder_version
    """,
}

SEMANTIC_CANDIDATE_QUERIES = {
    "whoop_raw_packet": """
        SELECT r.packet_sequence, r.received_at, r.delivery_sequence, s.legacy_id,
               p.uuid, q.characteristic_uuid, r.frame_type,
               r.protocol_version, r.crc_valid, r.payload
        FROM whoop_raw_packet r
        JOIN whoop_packet_source q ON q.id=r.source_id
        JOIN whoop_peripheral p ON p.id=q.peripheral_id
        LEFT JOIN whoop_offload_session s ON s.id=r.offload_session_id
        ORDER BY r.packet_sequence
    """,
    "whoop_offload_session": """
        SELECT s.id, s.legacy_id, p.uuid, s.started_at, s.completed_at,
               s.first_sequence, s.last_sequence, s.completion_sequence,
               s.completion_packet_sequence, s.status, s.failure_reason
        FROM whoop_offload_session s
        JOIN whoop_peripheral p ON p.id=s.peripheral_id
        ORDER BY s.id
    """,
    "heart_rate_sample": """
        SELECT packet_sequence, received_at, device_timestamp, heart_rate,
               rr_intervals_json, source
        FROM heart_rate_sample ORDER BY packet_sequence
    """,
    "whoop_historical_sample": """
        SELECT h.packet_sequence, h.sample_at, p.uuid, h.protocol_version, h.ordinal,
               h.heart_rate, h.rr_intervals_json, h.sleep_state, h.decoder_version,
               h.step_motion_counter, h.step_cadence_raw, h.motion_class_raw,
               h.step_utc_offset_seconds, h.step_date_key
        FROM whoop_historical_sample h
        JOIN whoop_peripheral p ON p.id=h.peripheral_id
        ORDER BY h.packet_sequence
    """,
    "whoop_packet_replay": """
        SELECT signature, first_packet_sequence, duplicate_count, last_received_at
        FROM whoop_packet_replay ORDER BY signature
    """,
    "whoop_ppg_packet": """
        SELECT packet_sequence, sample_at, channel, sample_rate_hz,
               samples_i16_le, decoder_version
        FROM whoop_ppg_packet ORDER BY packet_sequence
    """,
    "whoop_decode_failure": """
        SELECT packet_sequence, decoder_version, protocol_version, stream,
               status, error, decoded_at
        FROM whoop_decode_failure ORDER BY packet_sequence, decoder_version
    """,
}


def quote_identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def migration_sql() -> str:
    renamed = "\n".join(
        f"ALTER TABLE {quote_identifier(table)} RENAME TO {quote_identifier(table + '_v10')};"
        for table in AFFECTED_TABLES
    )
    return f"""
        BEGIN IMMEDIATE;
        {renamed}

        CREATE TABLE whoop_peripheral (
            id INTEGER PRIMARY KEY,
            uuid TEXT NOT NULL UNIQUE
        );
        CREATE TABLE whoop_packet_source (
            id INTEGER PRIMARY KEY,
            peripheral_id INTEGER NOT NULL REFERENCES whoop_peripheral(id),
            characteristic_uuid TEXT NOT NULL,
            UNIQUE(peripheral_id, characteristic_uuid)
        );
        CREATE TABLE whoop_raw_packet (
            packet_sequence INTEGER PRIMARY KEY,
            received_at REAL NOT NULL,
            delivery_sequence INTEGER,
            offload_session_id INTEGER REFERENCES whoop_offload_session(id),
            source_id INTEGER NOT NULL REFERENCES whoop_packet_source(id),
            frame_type INTEGER,
            protocol_version INTEGER,
            crc_valid INTEGER,
            payload BLOB NOT NULL
        );
        CREATE TABLE whoop_offload_session (
            id INTEGER PRIMARY KEY,
            legacy_id TEXT NOT NULL UNIQUE,
            peripheral_id INTEGER NOT NULL REFERENCES whoop_peripheral(id),
            started_at REAL NOT NULL,
            completed_at REAL,
            first_sequence INTEGER,
            last_sequence INTEGER,
            completion_sequence INTEGER,
            completion_packet_sequence INTEGER REFERENCES whoop_raw_packet(packet_sequence),
            status TEXT NOT NULL CHECK(status IN ('in_progress','complete','abandoned')),
            failure_reason TEXT
        );
        CREATE TABLE heart_rate_sample (
            packet_sequence INTEGER PRIMARY KEY REFERENCES whoop_raw_packet(packet_sequence),
            received_at REAL NOT NULL,
            device_timestamp INTEGER,
            heart_rate INTEGER NOT NULL,
            rr_intervals_json TEXT NOT NULL CHECK(rr_intervals_json != '[]'),
            source TEXT NOT NULL
        );
        CREATE TABLE whoop_historical_sample (
            packet_sequence INTEGER PRIMARY KEY REFERENCES whoop_raw_packet(packet_sequence),
            sample_at REAL NOT NULL,
            peripheral_id INTEGER NOT NULL REFERENCES whoop_peripheral(id),
            protocol_version INTEGER NOT NULL,
            ordinal INTEGER NOT NULL DEFAULT 0,
            heart_rate INTEGER NOT NULL CHECK(heart_rate BETWEEN 0 AND 255),
            rr_intervals_json TEXT NOT NULL,
            sleep_state INTEGER NOT NULL CHECK(sleep_state BETWEEN 0 AND 3),
            decoder_version INTEGER NOT NULL,
            step_motion_counter INTEGER,
            step_cadence_raw INTEGER,
            motion_class_raw INTEGER,
            step_utc_offset_seconds INTEGER,
            step_date_key TEXT,
            UNIQUE(peripheral_id, protocol_version, sample_at, ordinal)
        );
        CREATE TABLE whoop_packet_replay (
            signature BLOB PRIMARY KEY,
            first_packet_sequence INTEGER NOT NULL
                REFERENCES whoop_raw_packet(packet_sequence),
            duplicate_count INTEGER NOT NULL DEFAULT 0,
            last_received_at REAL NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE whoop_ppg_packet (
            packet_sequence INTEGER PRIMARY KEY REFERENCES whoop_raw_packet(packet_sequence),
            sample_at REAL NOT NULL,
            channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 255),
            sample_rate_hz REAL NOT NULL,
            samples_i16_le BLOB NOT NULL,
            decoder_version INTEGER NOT NULL DEFAULT 2
        );
        CREATE TABLE whoop_decode_failure (
            packet_sequence INTEGER NOT NULL REFERENCES whoop_raw_packet(packet_sequence),
            decoder_version INTEGER NOT NULL,
            protocol_version INTEGER,
            stream TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('unsupported','rejected')),
            error TEXT,
            decoded_at REAL NOT NULL,
            PRIMARY KEY(packet_sequence, decoder_version)
        ) WITHOUT ROWID;

        INSERT INTO whoop_peripheral(uuid)
        SELECT uuid FROM (
            SELECT peripheral_id AS uuid FROM whoop_raw_packet_v10
            UNION
            SELECT peripheral_id FROM whoop_offload_session_v10
            UNION
            SELECT peripheral_id FROM whoop_historical_sample_v10
        ) ORDER BY uuid;

        INSERT INTO whoop_packet_source(peripheral_id, characteristic_uuid)
        SELECT p.id, r.characteristic_uuid
        FROM whoop_raw_packet_v10 r
        JOIN whoop_peripheral p ON p.uuid=r.peripheral_id
        GROUP BY p.id, r.characteristic_uuid
        ORDER BY p.id, r.characteristic_uuid;

        INSERT INTO whoop_offload_session
            (id, legacy_id, peripheral_id, started_at, completed_at,
             first_sequence, last_sequence, completion_sequence,
             completion_packet_sequence, status, failure_reason)
        SELECT s.rowid, s.id, p.id, s.started_at, s.completed_at,
               s.first_sequence, s.last_sequence, s.completion_sequence,
               r.rowid, s.status, s.failure_reason
        FROM whoop_offload_session_v10 s
        JOIN whoop_peripheral p ON p.uuid=s.peripheral_id
        LEFT JOIN whoop_raw_packet_v10 r ON r.id=s.completion_packet_id
        ORDER BY s.rowid;

        INSERT INTO whoop_raw_packet
            (packet_sequence, received_at, delivery_sequence, offload_session_id,
             source_id, frame_type, protocol_version, crc_valid, payload)
        SELECT r.rowid, r.received_at, r.delivery_sequence, s.rowid,
               q.id, r.frame_type, r.protocol_version, r.crc_valid, r.payload
        FROM whoop_raw_packet_v10 r
        JOIN whoop_peripheral p ON p.uuid=r.peripheral_id
        JOIN whoop_packet_source q
          ON q.peripheral_id=p.id AND q.characteristic_uuid=r.characteristic_uuid
        LEFT JOIN whoop_offload_session_v10 s ON s.id=r.offload_session_id
        ORDER BY r.rowid;

        INSERT INTO heart_rate_sample
            (packet_sequence, received_at, device_timestamp, heart_rate,
             rr_intervals_json, source)
        SELECT r.rowid, h.received_at, h.device_timestamp, h.heart_rate,
               h.rr_intervals_json, h.source
        FROM heart_rate_sample_v10 h
        JOIN whoop_raw_packet_v10 r ON r.id=h.source_packet_id;

        INSERT INTO whoop_historical_sample
            (packet_sequence, sample_at, peripheral_id, protocol_version, ordinal,
             heart_rate, rr_intervals_json, sleep_state, decoder_version,
             step_motion_counter, step_cadence_raw, motion_class_raw,
             step_utc_offset_seconds, step_date_key)
        SELECT r.rowid, h.sample_at, p.id, h.protocol_version, h.ordinal,
               h.heart_rate, h.rr_intervals_json, h.sleep_state, h.decoder_version,
               h.step_motion_counter, h.step_cadence_raw, h.motion_class_raw,
               h.step_utc_offset_seconds, h.step_date_key
        FROM whoop_historical_sample_v10 h
        JOIN whoop_raw_packet_v10 r ON r.id=h.source_packet_id
        JOIN whoop_peripheral p ON p.uuid=h.peripheral_id;

        INSERT INTO whoop_packet_replay
            (signature, first_packet_sequence, duplicate_count, last_received_at)
        SELECT x.signature, r.rowid, x.duplicate_count, x.last_received_at
        FROM whoop_packet_replay_v10 x
        JOIN whoop_raw_packet_v10 r ON r.id=x.first_packet_id;

        INSERT INTO whoop_ppg_packet
            (packet_sequence, sample_at, channel, sample_rate_hz,
             samples_i16_le, decoder_version)
        SELECT r.rowid, x.sample_at, x.channel, x.sample_rate_hz,
               x.samples_i16_le, x.decoder_version
        FROM whoop_ppg_packet_v10 x
        JOIN whoop_raw_packet_v10 r ON r.id=x.source_packet_id;

        INSERT INTO whoop_decode_failure
            (packet_sequence, decoder_version, protocol_version, stream,
             status, error, decoded_at)
        SELECT r.rowid, x.decoder_version, x.protocol_version, x.stream,
               x.status, x.error, x.decoded_at
        FROM whoop_decode_failure_v10 x
        JOIN whoop_raw_packet_v10 r ON r.id=x.source_packet_id;

        DROP TABLE heart_rate_sample_v10;
        DROP TABLE whoop_decode_failure_v10;
        DROP TABLE whoop_historical_sample_v10;
        DROP TABLE whoop_packet_replay_v10;
        DROP TABLE whoop_ppg_packet_v10;
        DROP TABLE whoop_raw_packet_v10;
        DROP TABLE whoop_offload_session_v10;

        CREATE INDEX whoop_raw_packet_received_at
            ON whoop_raw_packet(received_at);
        CREATE INDEX whoop_raw_packet_delivery_sequence
            ON whoop_raw_packet(delivery_sequence);
        CREATE INDEX whoop_raw_packet_offload_session
            ON whoop_raw_packet(offload_session_id, delivery_sequence);
        CREATE INDEX whoop_offload_session_status
            ON whoop_offload_session(status, completed_at);
        CREATE INDEX whoop_historical_sample_sleep_state
            ON whoop_historical_sample(peripheral_id, sleep_state, sample_at);
        CREATE INDEX whoop_historical_sample_sample_at
            ON whoop_historical_sample(peripheral_id, sample_at);
        CREATE INDEX whoop_historical_sample_step_day
            ON whoop_historical_sample(step_date_key, peripheral_id, sample_at);
        CREATE INDEX whoop_ppg_packet_sample_at
            ON whoop_ppg_packet(sample_at, channel);
        CREATE INDEX heart_rate_sample_source_time
            ON heart_rate_sample(source, device_timestamp, received_at);
        CREATE INDEX heart_rate_sample_source_received
            ON heart_rate_sample(source, received_at);
        PRAGMA user_version={CANDIDATE_SCHEMA_VERSION};
        COMMIT;
    """


def representative_query_specs(
    source: sqlite3.Connection,
) -> list[tuple[str, str, str, Sequence[object]]]:
    received = source.execute(
        "SELECT COALESCE(MIN(received_at),0), COALESCE(MAX(received_at),0) FROM whoop_raw_packet"
    ).fetchone()
    if received is None:
        raise ValueError("Cannot determine raw packet time bounds.")
    lower = float(received[0])
    upper = min(float(received[1]), lower + 86_400)
    peripheral_row = source.execute(
        "SELECT peripheral_id FROM whoop_raw_packet ORDER BY rowid LIMIT 1"
    ).fetchone()
    peripheral = str(peripheral_row[0]) if peripheral_row else ""
    return [
        (
            "raw-received-window",
            """
                SELECT r.rowid, r.received_at, r.frame_type, r.payload
                FROM whoop_raw_packet r
                WHERE r.received_at BETWEEN ? AND ?
                ORDER BY r.received_at, r.rowid LIMIT 10000
            """,
            """
                SELECT packet_sequence, received_at, frame_type, payload
                FROM whoop_raw_packet
                WHERE received_at BETWEEN ? AND ?
                ORDER BY received_at, packet_sequence LIMIT 10000
            """,
            (lower, upper),
        ),
        (
            "historical-peripheral-window",
            """
                SELECT r.rowid, h.sample_at, h.heart_rate, h.sleep_state
                FROM whoop_historical_sample h
                JOIN whoop_raw_packet r ON r.id=h.source_packet_id
                WHERE h.peripheral_id=? AND h.sample_at BETWEEN ? AND ?
                ORDER BY h.sample_at, h.ordinal LIMIT 10000
            """,
            """
                SELECT h.packet_sequence, h.sample_at, h.heart_rate, h.sleep_state
                FROM whoop_historical_sample h
                JOIN whoop_peripheral p ON p.id=h.peripheral_id
                WHERE p.uuid=? AND h.sample_at BETWEEN ? AND ?
                ORDER BY h.sample_at, h.ordinal LIMIT 10000
            """,
            (peripheral, lower, upper),
        ),
        (
            "replay-signature-lookup",
            """
                SELECT r.rowid, x.duplicate_count, x.last_received_at
                FROM whoop_packet_replay x
                JOIN whoop_raw_packet r ON r.id=x.first_packet_id
                WHERE x.signature=(SELECT MIN(signature) FROM whoop_packet_replay)
            """,
            """
                SELECT first_packet_sequence, duplicate_count, last_received_at
                FROM whoop_packet_replay
                WHERE signature=(SELECT MIN(signature) FROM whoop_packet_replay)
            """,
            (),
        ),
    ]
