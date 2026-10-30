#!/usr/bin/env python3
"""Export a bounded, labeled IMU session from a verified standalone DB, read-only.

Axes stay signed raw counts. Sample rate, scaling and within-buffer timing are
not silently inferred from another firmware. Output contains private health data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sqlite3
import struct
import zlib
from pathlib import Path
from typing import cast

APPLE_REFERENCE_EPOCH = 978307200
MAXIMUM_JOURNAL_BYTES = 20 * 1024 * 1024


def decode_buffer(payload: bytes) -> dict[str, object]:
    if len(payload) != 1244 or payload[:2] != b"\xaa\x01":
        raise ValueError("Unsupported IMU envelope")
    if struct.unpack_from("<H", payload, 2)[0] != len(payload) - 8:
        raise ValueError("Invalid frame length")
    crc = 0xFFFF
    for byte in payload[:6]:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    if crc != struct.unpack_from("<H", payload, 6)[0]:
        raise ValueError("Invalid header CRC")
    if zlib.crc32(payload[8:-4]) != struct.unpack_from("<I", payload, len(payload) - 4)[0]:
        raise ValueError("Invalid payload CRC")
    if payload[8] not in (43, 47) or payload[9] != 21:
        raise ValueError("Unsupported IMU layout")
    fraction = struct.unpack_from("<H", payload, 19)[0]
    accel_count = struct.unpack_from("<H", payload, 24)[0]
    gyro_count = struct.unpack_from("<H", payload, 630)[0]
    if fraction > 32440 or accel_count > 100 or gyro_count > 100:
        raise ValueError("Invalid timestamp or sample count")

    def axes(offsets: tuple[int, int, int], count: int) -> list[list[int]]:
        return [
            [struct.unpack_from("<h", payload, offset + 2 * sample)[0] for offset in offsets]
            for sample in range(count)
        ]

    return {
        "sha256": hashlib.sha256(payload).hexdigest(),
        "sensor_at_unix": struct.unpack_from("<I", payload, 15)[0] + fraction / 32768,
        "configuration_bytes": [payload[i] for i in (21, 22, 26, 27, 628, 632, 633)],
        "accelerometer_raw_xyz": axes((28, 228, 428), accel_count),
        "gyroscope_raw_xyz": axes((640, 840, 1040), gyro_count),
        "sample_rate_hz": None,
        "physical_units_validated": False,
    }


def export_session(
    database: Path, journal: Path, session_id: str | None = None
) -> dict[str, object]:
    if journal.stat().st_size > MAXIMUM_JOURNAL_BYTES:
        raise ValueError("Capture journal exceeds bound")
    session = json.loads(journal.read_text())
    if not isinstance(session, dict):
        raise ValueError("Invalid capture journal")
    if "sessions" in session:
        sessions = session.get("sessions")
        if session.get("schemaVersion") != 1 or not isinstance(sessions, list) or not sessions:
            raise ValueError("Invalid calibration archive")
        if len(sessions) > 32:
            raise ValueError("Calibration archive exceeds session limit")
        matches = [
            item
            for item in sessions
            if isinstance(item, dict) and (session_id is None or item.get("id") == session_id)
        ]
        if not matches:
            raise ValueError("Requested capture session was not found")
        session = matches[-1]
    started = session.get("startedAt")
    deadline = session.get("deadline")
    if (
        isinstance(started, bool)
        or isinstance(deadline, bool)
        or not isinstance(started, (float, int))
        or not isinstance(deadline, (float, int))
        or not math.isfinite(started)
        or not math.isfinite(deadline)
        or not 30 <= deadline - started <= 600
    ):
        raise ValueError("Invalid capture interval")
    buffers = session.get("buffers")
    if not isinstance(buffers, list) or len(buffers) > 1200:
        raise ValueError("Invalid buffer references")
    references: dict[str, dict[str, object]] = {}
    for item in buffers:
        if not isinstance(item, dict) or not isinstance(item.get("sha256"), str):
            raise ValueError("Invalid buffer reference")
        references[item["sha256"]] = item
    result: dict[str, dict[str, object]] = {}
    connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
    try:
        rows = connection.execute(
            "SELECT received_at, characteristic_uuid, payload FROM whoop_raw_packet "
            "WHERE peripheral_id = ? AND received_at >= ? AND received_at <= ? "
            "AND length(payload) = 1244 ORDER BY received_at",
            (
                session["peripheralID"],
                started + APPLE_REFERENCE_EPOCH - 2,
                deadline + APPLE_REFERENCE_EPOCH + 15,
            ),
        )
        for received_at, characteristic, payload in rows:
            digest = hashlib.sha256(payload).hexdigest()
            if digest not in references or digest in result:
                continue
            decoded = decode_buffer(payload)
            decoded.update(received_at_unix=received_at, characteristic_uuid=characteristic)
            result[digest] = decoded
    finally:
        connection.close()
    if result.keys() != references.keys():
        raise ValueError("Referenced raw buffers are missing from this snapshot")
    return {
        "session": cast(dict[str, object], session),
        "buffers": [result[key] for key in references],
        "limitations": "Raw counts only; no strength score, sample timing or physical-unit claim",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path, help="Verified standalone SQLite snapshot")
    parser.add_argument("journal", type=Path, help="One motion-calibration session JSON")
    parser.add_argument("--session-id", help="Session UUID; defaults to latest session")
    parser.add_argument("--output", type=Path, required=True, help="Private export destination")
    args = parser.parse_args()
    report = export_session(args.database, args.journal, args.session_id)
    # Exclusive creation avoids overwriting a source snapshot or journal by mistake.
    descriptor = os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(report, stream)
        stream.write("\n")
    print("Motion export saved; no source data changed.")


if __name__ == "__main__":
    main()
