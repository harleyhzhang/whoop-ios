import hashlib
import json
import sqlite3
import struct
import zlib
from pathlib import Path

import pytest
from motion_capture_report import APPLE_REFERENCE_EPOCH, decode_buffer, export_session


def frame() -> bytes:
    payload = bytearray(1244)
    payload[:2] = b"\xaa\x01"
    struct.pack_into("<H", payload, 2, 1236)
    crc = 0xFFFF
    for byte in payload[:6]:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    struct.pack_into("<H", payload, 6, crc)
    payload[8:10] = bytes((43, 21))
    struct.pack_into("<I", payload, 15, 1_800_000_000)
    struct.pack_into("<H", payload, 24, 1)
    struct.pack_into("<H", payload, 630, 2)
    for offset, value in [(28, -32768), (228, 0), (428, 32767), (640, -12), (842, 34)]:
        struct.pack_into("<h", payload, offset, value)
    struct.pack_into("<I", payload, 1240, zlib.crc32(payload[8:1240]))
    return bytes(payload)


def test_axes_are_signed_independent_and_not_resampled() -> None:
    result = decode_buffer(frame())
    assert result["accelerometer_raw_xyz"] == [[-32768, 0, 32767]]
    assert result["gyroscope_raw_xyz"] == [[-12, 0, 0], [0, 34, 0]]
    assert result["sample_rate_hz"] is None
    assert result["physical_units_validated"] is False


def test_bad_crc_and_layout_are_rejected() -> None:
    corrupt = bytearray(frame())
    corrupt[30] ^= 1
    with pytest.raises(ValueError, match="payload CRC"):
        decode_buffer(bytes(corrupt))
    with pytest.raises(ValueError, match="envelope"):
        decode_buffer(frame()[:100])


def test_export_requires_exact_private_provenance_and_never_changes_database(
    tmp_path: Path,
) -> None:
    db = tmp_path / "synthetic.sqlite3"
    packet = frame()
    digest = hashlib.sha256(packet).hexdigest()
    with sqlite3.connect(db) as connection:
        connection.execute(
            "CREATE TABLE whoop_raw_packet (received_at REAL, peripheral_id TEXT, "
            "characteristic_uuid TEXT, payload BLOB)"
        )
        connection.execute(
            "INSERT INTO whoop_raw_packet VALUES (?, ?, ?, ?)",
            (1_800_000_000, "synthetic", "test", packet),
        )
    journal = tmp_path / "session.json"
    session = {
        "startedAt": 1_800_000_000 - APPLE_REFERENCE_EPOCH,
        "deadline": 1_800_000_060 - APPLE_REFERENCE_EPOCH,
        "peripheralID": "synthetic",
        "buffers": [{"sha256": digest}],
    }
    journal.write_text(json.dumps(session))
    before = hashlib.sha256(db.read_bytes()).hexdigest()
    report = export_session(db, journal)
    assert len(report["buffers"]) == 1  # type: ignore[arg-type]
    assert hashlib.sha256(db.read_bytes()).hexdigest() == before
    session["peripheralID"] = "other"
    journal.write_text(json.dumps(session))
    with pytest.raises(ValueError, match="missing"):
        export_session(db, journal)
