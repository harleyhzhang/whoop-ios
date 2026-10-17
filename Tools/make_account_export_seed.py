#!/usr/bin/env python3
"""Seed app history from a WHOOP account-export ZIP, preserving every source byte.

CSV timestamps are local wall times in Cycle timezone. Daily projections use the
main sleep's local wake date; cycles without sleep use their local start date.
On collisions a main sleep wins, then the latest wake/start instant. Scores from
separate cycles are never combined. All rows, including unselected cycles and
naps, remain in a checksum-linked SQLite sidecar. Outputs must stay outside Git.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import re
import sqlite3
import tempfile
import zipfile
import zlib
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

SOURCE = "whoop_account_export"
FILES = ("physiological_cycles.csv", "sleeps.csv", "workouts.csv", "journal_entries.csv")
HEALTH_FIELDS = {
    "sleepScore": "Sleep performance %",
    "sleepDurationMinutes": "Asleep duration (min)",
    "hrvRMSSDMilliseconds": "Heart rate variability (ms)",
    "restingHeartRateBPM": "Resting heart rate (bpm)",
    "sleepNeedMinutes": "Sleep need (min)",
    "sleepConsistencyPercentage": "Sleep consistency %",
    "sleepEfficiencyPercentage": "Sleep efficiency %",
}
OFFICIAL_FIELDS = {
    "officialRecoveryScore": "Recovery score %",
    "officialDayStrain": "Day Strain",
    "hrv": "Heart rate variability (ms)",
    "rhr": "Resting heart rate (bpm)",
    "respiratoryRate": "Respiratory rate (rpm)",
    "sleepPerformance": "Sleep performance %",
}


def encoded(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    ).encode()


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def instant(value: str, zone: str) -> datetime:
    if not re.fullmatch(r"UTC(?:Z|[+-]\d{2}:\d{2})", zone):
        raise ValueError("Invalid or missing Cycle timezone")
    local = datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
    return datetime.fromisoformat(local.isoformat() + zone[3:].replace("Z", "+00:00"))


def number(row: dict[str, str], field: str) -> float | None:
    raw = row[field].strip()
    if not raw:
        return None
    value = float(raw)
    maximum = 21 if field == "Day Strain" else 100 if field.endswith("%") else math.inf
    if not math.isfinite(value) or not 0 <= value <= maximum:
        raise ValueError(f"Invalid numeric value in {field}")
    return value


def read_zip(path: Path) -> tuple[dict[str, bytes], dict[str, list[dict[str, str]]]]:
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("ZIP failed CRC verification")
        names = archive.namelist()
        if len(set(names)) != len(names) or set(names) != set(FILES):
            raise ValueError("Expected exactly the four WHOOP export CSV files")
        bodies = {name: archive.read(name) for name in FILES}
    rows = {}
    for name, body in bodies.items():
        reader = csv.DictReader(io.StringIO(body.decode("utf-8-sig")))
        if not reader.fieldnames or len(set(reader.fieldnames)) != len(reader.fieldnames):
            raise ValueError(f"Invalid CSV header: {name}")
        parsed = list(reader)
        if any(None in row or any(value is None for value in row.values()) for row in parsed):
            raise ValueError(f"Malformed CSV row: {name}")
        rows[name] = parsed
    return bodies, rows


def project(
    rows: dict[str, list[dict[str, str]]], archive_id: str, captured_at: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    cycles = rows[FILES[0]]
    required = (
        set(HEALTH_FIELDS.values())
        | set(OFFICIAL_FIELDS.values())
        | {"Cycle start time", "Cycle timezone", "Sleep onset", "Wake onset"}
    )
    if not cycles or not required <= cycles[0].keys():
        raise ValueError("Cycle CSV is empty or missing required columns")
    cycle_keys = [(r["Cycle start time"], r["Cycle timezone"]) for r in cycles]
    if len(set(cycle_keys)) != len(cycle_keys):
        raise ValueError("Duplicate cycle identity")
    main = {}
    for row in rows[FILES[1]]:
        if row["Nap"] not in ("true", "false"):
            raise ValueError("Invalid Nap flag")
        if row["Nap"] == "false":
            key = (row["Cycle start time"], row["Cycle timezone"])
            if key in main:
                raise ValueError("Multiple primary sleeps in one cycle")
            main[key] = row
    if not set(main) <= set(cycle_keys):
        raise ValueError("Primary sleep has no matching cycle")
    groups: dict[str, list[tuple[bool, datetime, int, dict[str, str]]]] = {}
    for index, row in enumerate(cycles, 2):
        # Validate every cycle, even rows that lose a date collision.
        for field in set(HEALTH_FIELDS.values()) | set(OFFICIAL_FIELDS.values()):
            number(row, field)
        start = instant(row["Cycle start time"], row["Cycle timezone"])
        has_sleep = bool(row["Wake onset"])
        if bool(row["Sleep onset"]) != has_sleep:
            raise ValueError("Incomplete sleep interval")
        key = (row["Cycle start time"], row["Cycle timezone"])
        sleep = main.get(key)
        if has_sleep != (sleep is not None):
            raise ValueError("Cycle and primary sleep disagree")
        if sleep is not None and any(row[k] != v for k, v in sleep.items() if k in row):
            raise ValueError("Cycle and sleep CSV values disagree")
        end = instant(row["Wake onset"], row["Cycle timezone"]) if has_sleep else start
        if has_sleep and instant(row["Sleep onset"], row["Cycle timezone"]) >= end:
            raise ValueError("Sleep end must follow start")
        groups.setdefault(end.date().isoformat(), []).append((has_sleep, end, index, row))
    history, daily, collisions = [], [], []
    for day, candidates in sorted(groups.items()):
        candidates.sort(key=lambda item: (item[0], item[1]))
        if len(candidates) > 1 and candidates[-1][:2] == candidates[-2][:2]:
            raise ValueError("Ambiguous equal-time daily candidates")
        has_sleep, end, row_number, row = candidates[-1]
        if len(candidates) > 1:
            collisions.append(
                {
                    "dateKey": day,
                    "selectedCSVRow": row_number,
                    "preservedOtherCSVRows": [c[2] for c in candidates[:-1]],
                }
            )
        row_sha = digest(encoded(row))
        daily.append(
            {
                "dateKey": day,
                **{k: number(row, v) for k, v in OFFICIAL_FIELDS.items()},
                "sourceRecoverySHA256": row_sha,
                "sourceStrainSHA256": row_sha,
            }
        )
        if not has_sleep:
            continue
        start = instant(row["Sleep onset"], row["Cycle timezone"])
        record: dict[str, Any] = {
            "dateKey": day,
            "source": SOURCE,
            "sourceArchive": archive_id,
            "sourceUpdatedAt": captured_at,
            **{k: number(row, v) for k, v in HEALTH_FIELDS.items()},
            "sleepStartAt": start.astimezone(UTC).isoformat().replace("+00:00", "Z"),
            "sleepEndAt": end.astimezone(UTC).isoformat().replace("+00:00", "Z"),
            "sleepStartMinute": start.hour * 60 + start.minute + start.second / 60,
            "sleepEndMinute": end.hour * 60 + end.minute + end.second / 60,
        }
        duration, need = record["sleepDurationMinutes"], record["sleepNeedMinutes"]
        record["sleepSufficiencyPercentage"] = (
            min(100, duration / need * 100) if duration is not None and need else None
        )
        history.append(record)
    return history, daily, collisions


def build(archive: Path, output: Path, captured_at: str) -> dict[str, Any]:
    captured = datetime.fromisoformat(captured_at.replace("Z", "+00:00"))
    if captured.tzinfo is None:
        raise ValueError("Capture timestamp must include a timezone")
    captured_at = captured.astimezone(UTC).isoformat().replace("+00:00", "Z")
    repo = Path(__file__).resolve().parents[1]
    if output.resolve().is_relative_to(repo):
        raise ValueError("Private seed output must be outside the repository")
    if output.exists():
        raise FileExistsError("Choose a new seed directory; existing seeds are never overwritten")
    bodies, rows = read_zip(archive)
    zip_body = archive.read_bytes()
    archive_id = f"{SOURCE}:{digest(zip_body)}"
    history, daily, collisions = project(rows, archive_id, captured_at)
    manifest = {
        "source": SOURCE,
        "zipSHA256": digest(zip_body),
        "capturedAt": captured_at,
        "files": [
            {"file": k, "sha256": digest(v), "rows": len(rows[k])} for k, v in bodies.items()
        ],
    }
    manifest_bytes = encoded(manifest)
    report = {
        "source": SOURCE,
        "sourceZIP_SHA256": digest(zip_body),
        "coverageStart": daily[0]["dateKey"],
        "coverageEnd": daily[-1]["dateKey"],
        "sourceRows": {k: len(v) for k, v in rows.items()},
        "historyDays": len(history),
        "officialDays": len(daily),
        "recoveryDays": sum(r["officialRecoveryScore"] is not None for r in daily),
        "strainDays": sum(r["officialDayStrain"] is not None for r in daily),
        "napRowsPreserved": sum(r["Nap"] == "true" for r in rows[FILES[1]]),
        "dailyCollisions": collisions,
        "selectionPolicy": "Prefer primary sleep, then latest wake/start; never combine cycles",
        "missingInputs": ["steps", "continuous heart rate"],
        "modelsTrained": False,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".account-seed-") as temporary:
        root = Path(temporary)
        db_path = root / "whoop-official-archive.sqlite3"
        connection = sqlite3.connect(db_path)
        try:
            connection.executescript("""
                CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE export_file(name TEXT PRIMARY KEY, sha256 TEXT NOT NULL,
                    raw_bytes INTEGER NOT NULL, compressed_body BLOB NOT NULL);
                CREATE TABLE export_row(file TEXT NOT NULL, csv_row INTEGER NOT NULL,
                    sha256 TEXT NOT NULL, payload_json TEXT NOT NULL,
                    PRIMARY KEY(file, csv_row));
                PRAGMA user_version=1;
            """)
            connection.executemany(
                "INSERT INTO archive_metadata VALUES (?, ?)",
                [
                    ("source", SOURCE),
                    ("source_archive", archive_id),
                    ("source_manifest_sha256", digest(manifest_bytes)),
                    ("compression", "zlib"),
                    ("captured_at", captured_at),
                ],
            )
            for name, body in {
                **bodies,
                "original.zip": zip_body,
                "manifest.json": manifest_bytes,
            }.items():
                connection.execute(
                    "INSERT INTO export_file VALUES (?, ?, ?, ?)",
                    (name, digest(body), len(body), zlib.compress(body)),
                )
            for name, records in rows.items():
                connection.executemany(
                    "INSERT INTO export_row VALUES (?, ?, ?, ?)",
                    [
                        (name, i, digest(encoded(r)), encoded(r).decode())
                        for i, r in enumerate(records, 2)
                    ],
                )
            connection.commit()
            if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise ValueError("Sidecar integrity failure")
        finally:
            connection.close()
        metrics = {
            "formatVersion": 1,
            "source": SOURCE,
            "sourceArchive": archive_id,
            "sourceManifestSHA256": digest(manifest_bytes),
            "sourceDatabaseSHA256": digest(db_path.read_bytes()),
            "coverageStart": report["coverageStart"],
            "coverageEnd": report["coverageEnd"],
            "daily": daily,
        }
        for name, value in [
            ("whoop-history.json", history),
            ("whoop-official-metrics.json", metrics),
            ("import-report.json", report),
        ]:
            (root / name).write_bytes(encoded(value))
        for file in root.iterdir():
            file.chmod(0o600)
        root.rename(output)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--captured-at", required=True, help="Export capture time, ISO8601 with zone"
    )
    args = parser.parse_args()
    print(json.dumps(build(args.archive, args.output, args.captured_at), indent=2))


if __name__ == "__main__":
    main()
