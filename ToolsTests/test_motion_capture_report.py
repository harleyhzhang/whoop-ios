import hashlib
import json
import sqlite3
import struct
import zlib
from pathlib import Path
from typing import cast

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


def test_fragmented_notifications_export_exact_source_hashes_and_clock_alignment(
    tmp_path: Path,
) -> None:
    db = tmp_path / "fragmented.sqlite3"
    packet = frame()
    fragments = [packet[offset : offset + 244] for offset in range(0, len(packet), 244)]
    receipt = 1_800_000_114.0
    with sqlite3.connect(db) as connection:
        connection.execute(
            "CREATE TABLE whoop_raw_packet (received_at REAL, peripheral_id TEXT, characteristic_uuid TEXT, payload BLOB, delivery_sequence INTEGER)"
        )
        connection.executemany(
            "INSERT INTO whoop_raw_packet VALUES (?, ?, ?, ?, ?)",
            [
                (receipt + i * 0.01, "synthetic", "data", part, i)
                for i, part in enumerate(fragments)
            ],
        )
    source_hashes = [hashlib.sha256(part).hexdigest() for part in fragments]
    session = {
        "peripheralID": "synthetic",
        "startedAt": receipt - APPLE_REFERENCE_EPOCH - 1,
        "deadline": receipt - APPLE_REFERENCE_EPOCH + 59,
        "endedAt": receipt - APPLE_REFERENCE_EPOCH + 20,
        "clockReference": {
            "deviceAt": 1_800_000_000 - APPLE_REFERENCE_EPOCH,
            "sentAt": receipt - APPLE_REFERENCE_EPOCH - 0.1,
            "receivedAt": receipt - APPLE_REFERENCE_EPOCH + 0.1,
        },
        "buffers": [
            {
                "sha256": hashlib.sha256(packet).hexdigest(),
                "receivedAt": receipt - APPLE_REFERENCE_EPOCH + 0.05,
                "sourcePacketHashes": source_hashes,
                "characteristicUUID": "data",
            }
        ],
    }
    journal = tmp_path / "capture.json"
    journal.write_text(json.dumps(session))
    result = export_session(db, journal)
    buffers = cast(list[dict[str, object]], result["buffers"])
    assert buffers[0]["source_packet_sha256"] == source_hashes
    assert buffers[0]["aligned_sensor_at_unix"] == receipt
    assert buffers[0]["sensor_at_unix"] == 1_800_000_000
    references = cast(list[dict[str, object]], session["buffers"])
    references[0]["sourcePacketHashes"] = ["wrong"]
    journal.write_text(json.dumps(session))
    with pytest.raises(ValueError, match="provenance"):
        export_session(db, journal)


def test_fragment_streams_do_not_cross_channels_gaps_or_bad_crc() -> None:
    from motion_frames import NotificationFrames

    packet = frame()
    reader = NotificationFrames()
    assert reader.feed("a", packet[:244], 0) == []
    assert reader.feed("b", packet[244:], 0) == []
    assert reader.feed("a", packet[244:], 3) == []
    corrupt = bytearray(packet)
    corrupt[100] ^= 1
    assert reader.feed("a", bytes(corrupt) + packet, 4)[0][0] == packet
