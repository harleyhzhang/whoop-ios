from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path

import pytest
import storage_v11_prototype as prototype

V10_SCHEMA = """
    PRAGMA foreign_keys=ON;
    CREATE TABLE whoop_raw_packet (
        id TEXT PRIMARY KEY,
        received_at REAL NOT NULL,
        peripheral_id TEXT NOT NULL,
        characteristic_uuid TEXT NOT NULL,
        frame_type INTEGER,
        payload BLOB NOT NULL,
        delivery_sequence INTEGER,
        protocol_version INTEGER,
        crc_valid INTEGER,
        offload_session_id TEXT
    );
    CREATE INDEX whoop_raw_packet_received_at ON whoop_raw_packet(received_at);
    CREATE INDEX whoop_raw_packet_delivery_sequence ON whoop_raw_packet(delivery_sequence);
    CREATE INDEX whoop_raw_packet_offload_session
        ON whoop_raw_packet(offload_session_id, delivery_sequence);
    CREATE TABLE whoop_offload_session (
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
    );
    CREATE INDEX whoop_offload_session_status
        ON whoop_offload_session(status, completed_at);
    CREATE TABLE heart_rate_sample (
        source_packet_id TEXT PRIMARY KEY,
        received_at REAL NOT NULL,
        device_timestamp INTEGER,
        heart_rate INTEGER NOT NULL,
        rr_intervals_json TEXT NOT NULL CHECK(rr_intervals_json != '[]'),
        source TEXT NOT NULL,
        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
    );
    CREATE INDEX heart_rate_sample_source_time
        ON heart_rate_sample(source, device_timestamp, received_at);
    CREATE INDEX heart_rate_sample_source_received
        ON heart_rate_sample(source, received_at);
    CREATE TABLE whoop_historical_sample (
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
        step_motion_counter INTEGER,
        step_cadence_raw INTEGER,
        motion_class_raw INTEGER,
        step_utc_offset_seconds INTEGER,
        step_date_key TEXT,
        UNIQUE(peripheral_id, protocol_version, sample_at, ordinal),
        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
    );
    CREATE INDEX whoop_historical_sample_sleep_state
        ON whoop_historical_sample(peripheral_id, sleep_state, sample_at);
    CREATE INDEX whoop_historical_sample_sample_at
        ON whoop_historical_sample(peripheral_id, sample_at);
    CREATE INDEX whoop_historical_sample_step_day
        ON whoop_historical_sample(step_date_key, peripheral_id, sample_at);
    CREATE TABLE whoop_packet_replay (
        signature BLOB PRIMARY KEY,
        first_packet_id TEXT NOT NULL,
        duplicate_count INTEGER NOT NULL DEFAULT 0,
        last_received_at REAL NOT NULL
    );
    CREATE TABLE whoop_ppg_packet (
        source_packet_id TEXT PRIMARY KEY,
        sample_at REAL NOT NULL,
        channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 255),
        sample_rate_hz REAL NOT NULL,
        samples_i16_le BLOB NOT NULL,
        decoder_version INTEGER NOT NULL DEFAULT 2,
        FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
    );
    CREATE INDEX whoop_ppg_packet_sample_at ON whoop_ppg_packet(sample_at, channel);
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
    );
    CREATE TABLE daily_health_metric (
        date_key TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        imported_at REAL NOT NULL
    );
    PRAGMA user_version=10;
"""


def create_v10(path: Path) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.executescript(V10_SCHEMA)
        connection.execute(
            """
            INSERT INTO whoop_raw_packet
                (id, received_at, peripheral_id, characteristic_uuid, frame_type,
                 payload, delivery_sequence, protocol_version, crc_valid, offload_session_id)
            VALUES ('legacy-packet-1', 100, 'peripheral-a', 'characteristic-a', 47,
                    X'010203', 10, 18, 1, NULL)
            """
        )
        connection.execute(
            """
            INSERT INTO whoop_raw_packet
                (id, received_at, peripheral_id, characteristic_uuid, frame_type,
                 payload, delivery_sequence, protocol_version, crc_valid, offload_session_id)
            VALUES ('legacy-packet-2', 200, 'peripheral-a', 'characteristic-b', 40,
                    X'0405', 11, 26, 1, 'session-a')
            """
        )
        connection.execute(
            """
            INSERT INTO whoop_offload_session
                (id, peripheral_id, started_at, completed_at, first_sequence,
                 last_sequence, completion_sequence, completion_packet_id, status)
            VALUES ('session-a', 'peripheral-a', 90, 210, 10, 11, 11,
                    'legacy-packet-2', 'complete')
            """
        )
        connection.execute(
            """
            INSERT INTO heart_rate_sample
                (source_packet_id, received_at, device_timestamp, heart_rate,
                 rr_intervals_json, source)
            VALUES ('legacy-packet-2', 200, 123, 61, '[900]', 'whoop5_type40')
            """
        )
        connection.execute(
            """
            INSERT INTO whoop_historical_sample
                (sample_at, source_packet_id, peripheral_id, protocol_version,
                 ordinal, heart_rate, rr_intervals_json, sleep_state, decoder_version,
                 step_motion_counter, step_cadence_raw, motion_class_raw,
                 step_utc_offset_seconds, step_date_key)
            VALUES (100, 'legacy-packet-1', 'peripheral-a', 18,
                    0, 60, '[910]', 2, 3, 50, 1, 2, -14400, '2026-01-01')
            """
        )
        connection.execute(
            """
            INSERT INTO whoop_packet_replay
                (signature, first_packet_id, duplicate_count, last_received_at)
            VALUES (X'01020304', 'legacy-packet-1', 3, 150)
            """
        )
        connection.execute(
            """
            INSERT INTO whoop_ppg_packet
                (source_packet_id, sample_at, channel, sample_rate_hz,
                 samples_i16_le, decoder_version)
            VALUES ('legacy-packet-1', 100, 1, 24, X'0102', 3)
            """
        )
        connection.execute(
            """
            INSERT INTO whoop_decode_failure
                (source_packet_id, decoder_version, protocol_version, stream,
                 status, error, decoded_at)
            VALUES ('legacy-packet-2', 3, 99, 'unknown', 'unsupported', 'fixture', 200)
            """
        )
        connection.execute(
            "INSERT INTO daily_health_metric VALUES ('2026-01-01', 'synthetic', 300)"
        )
        connection.commit()
    finally:
        connection.close()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_prototype_normalizes_full_copy_and_proves_semantic_parity(tmp_path: Path) -> None:
    source = tmp_path / "source.sqlite3"
    output = tmp_path / "candidate.sqlite3"
    create_v10(source)
    source_before = sha256(source)

    report = prototype.prototype(source, output)

    assert sha256(source) == source_before
    assert report["sourceSchemaVersion"] == 10
    assert report["candidateSchemaVersion"] == 11
    assert report["validation"] == {
        "quickCheck": "ok",
        "sourceIntegrityCheck": "ok",
        "candidateIntegrityCheck": "ok",
        "foreignKeyCheckViolations": 0,
        "semanticHashesMatch": True,
        "representativeQueryResultsMatch": True,
    }
    parity = report["tableParity"]
    assert isinstance(parity, dict)
    assert parity["whoop_raw_packet"]["rows"] == 2
    assert parity["whoop_historical_sample"]["rows"] == 1
    unaffected = report["unaffectedTableParity"]
    assert isinstance(unaffected, dict)
    assert unaffected["daily_health_metric"]["rows"] == 1

    connection = sqlite3.connect(output)
    try:
        assert connection.execute("PRAGMA user_version").fetchone() == (11,)
        assert connection.execute("PRAGMA quick_check").fetchone() == ("ok",)
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
        assert connection.execute("SELECT COUNT(*) FROM whoop_peripheral").fetchone() == (1,)
        assert connection.execute("SELECT COUNT(*) FROM whoop_packet_source").fetchone() == (2,)
        assert connection.execute(
            "SELECT typeof(packet_sequence), typeof(source_id), typeof(offload_session_id) "
            "FROM whoop_raw_packet WHERE offload_session_id IS NOT NULL"
        ).fetchone() == ("integer", "integer", "integer")
        replay_schema = connection.execute(
            "SELECT sql FROM sqlite_master WHERE name='whoop_packet_replay'"
        ).fetchone()
        assert replay_schema is not None
        assert "WITHOUT ROWID" in replay_schema[0]
    finally:
        connection.close()


def test_prototype_refuses_overwrite_and_removes_failed_candidate(tmp_path: Path) -> None:
    source = tmp_path / "source.sqlite3"
    create_v10(source)
    existing = tmp_path / "existing.sqlite3"
    existing.write_text("keep me")

    with pytest.raises(prototype.PrototypeError, match="overwrite"):
        prototype.prototype(source, existing)
    assert existing.read_text() == "keep me"

    connection = sqlite3.connect(source)
    try:
        connection.execute(
            "UPDATE whoop_raw_packet SET offload_session_id='missing' WHERE id='legacy-packet-1'"
        )
        connection.commit()
    finally:
        connection.close()
    failed = tmp_path / "failed.sqlite3"
    with pytest.raises(prototype.PrototypeError, match="normalized safely"):
        prototype.prototype(source, failed)
    assert not failed.exists()
