#!/usr/bin/env python3
"""Extract WHOOP workouts, sleeps, and naps from an account-export ZIP.

Writes whoop-activities.json for the app's read-only activity history. Times
are converted from Cycle timezone wall time to ISO 8601 instants. Output must
stay outside Git.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import uuid
import zipfile
from pathlib import Path
from typing import Any

from make_account_export_seed import instant


def number(value: str | None) -> float | None:
    try:
        return float(value) if value not in (None, "") else None
    except ValueError:
        return None


def whole(value: str | None) -> int | None:
    parsed = number(value)
    return round(parsed) if parsed is not None else None


def stable_id(file: str, row: dict[str, str]) -> str:
    body = json.dumps([file, row], sort_keys=True).encode()
    return str(uuid.UUID(bytes=hashlib.sha256(body).digest()[:16]))


def zones(row: dict[str, str]) -> list[float] | None:
    values = [number(row.get(f"HR Zone {i} %")) for i in range(1, 6)]
    if all(v is None for v in values):
        return None
    return [v or 0.0 for v in values]


def span(row: dict[str, str], start: str, end: str) -> tuple[str, str] | None:
    zone = row.get("Cycle timezone", "")
    if not row.get(start) or not row.get(end):
        return None
    begin, finish = instant(row[start], zone), instant(row[end], zone)
    if finish <= begin:
        return None
    return begin.isoformat(), finish.isoformat()


def activities(workouts: list[dict[str, str]], sleeps: list[dict[str, str]]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for row in workouts:
        times = span(row, "Workout start time", "Workout end time")
        if times is None:
            continue
        records.append(
            {
                "id": stable_id("workouts.csv", row),
                "kind": "activity",
                "name": row.get("Activity name") or "Activity",
                "start": times[0],
                "end": times[1],
                "strain": number(row.get("Activity Strain")),
                "averageHeartRate": whole(row.get("Average HR (bpm)")),
                "maxHeartRate": whole(row.get("Max HR (bpm)")),
                "calories": whole(row.get("Energy burned (cal)")),
                "zonePercents": zones(row),
            }
        )
    for row in sleeps:
        times = span(row, "Sleep onset", "Wake onset")
        if times is None:
            continue
        nap = row.get("Nap", "").lower() == "true"
        records.append(
            {
                "id": stable_id("sleeps.csv", row),
                "kind": "nap" if nap else "sleep",
                "name": "Nap" if nap else "Sleep",
                "start": times[0],
                "end": times[1],
                "sleepScore": number(row.get("Sleep performance %")),
            }
        )
    return sorted(records, key=lambda r: r["start"])


def read(archive: Path, name: str) -> list[dict[str, str]]:
    with zipfile.ZipFile(archive) as bundle:
        member = next((n for n in bundle.namelist() if Path(n).name == name), None)
        if member is None:
            return []
        return list(csv.DictReader(io.StringIO(bundle.read(member).decode("utf-8-sig"))))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    if args.output.resolve().is_relative_to(repo):
        raise SystemExit("Private activity output must be outside the repository")
    records = activities(read(args.archive, "workouts.csv"), read(args.archive, "sleeps.csv"))
    args.output.write_text(json.dumps(records, separators=(",", ":")) + "\n")
    args.output.chmod(0o600)
    counts: dict[str, int] = {}
    for record in records:
        counts[record["kind"]] = counts.get(record["kind"], 0) + 1
    print(json.dumps(counts))


if __name__ == "__main__":
    main()
