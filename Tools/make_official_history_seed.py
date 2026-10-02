#!/usr/bin/env python3
"""Compact a raw WHOOP iOS-API archive and materialize app-facing history.

The compact SQLite sidecar keeps every response byte exactly recoverable after
zlib decompression and de-duplicates identical bodies by SHA-256. The small JSON
projection is what the app imports into its primary database. Both outputs are
private health artifacts and must remain outside Git.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import zlib
from collections.abc import Iterator
from pathlib import Path
from typing import Any

DAY_PATTERN = re.compile(r"(\d{4}-\d{2}-\d{2})-(recovery|strain)$")


def items(payload: dict[str, Any]) -> Iterator[tuple[str, dict[str, Any]]]:
    for section in payload.get("sections", []):
        for item in section.get("items", []):
            content = item.get("content")
            if isinstance(content, dict):
                yield str(item.get("type", "")), content


def number(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(str(value).replace(",", "").replace("%", ""))
    except ValueError:
        return None


def recovery_projection(payload: dict[str, Any]) -> dict[str, float | None]:
    result: dict[str, float | None] = {}
    ids = {
        "CONTRIBUTORS_TILE_HRV": "hrv",
        "CONTRIBUTORS_TILE_RHR": "rhr",
        "CONTRIBUTORS_TILE_RESPIRATORY_RATE": "respiratoryRate",
        "CONTRIBUTORS_TILE_SLEEP_PERFORMANCE": "sleepPerformance",
    }
    for item_type, content in items(payload):
        if item_type == "SCORE_GAUGE" and content.get("id") == "RECOVERY_SCORE_GAUGE":
            result["officialRecoveryScore"] = number(content.get("score_display"))
        elif item_type == "CONTRIBUTORS_TILE":
            for metric in content.get("metrics") or []:
                stem = ids.get(metric.get("id"))
                if stem:
                    result[stem] = number(metric.get("status"))
                    result[f"{stem}Baseline"] = number(metric.get("status_subtitle"))
    return result


def strain_projection(payload: dict[str, Any]) -> dict[str, float | int | None]:
    result: dict[str, float | int | None] = {}
    for item_type, content in items(payload):
        if item_type == "SCORE_GAUGE" and content.get("id") == "STRAIN_SCORE_GAUGE":
            result["officialDayStrain"] = number(content.get("score_display"))
            target = number(content.get("score_target"))
            result["dayStrainTarget"] = target * 21 if target is not None else None
        elif item_type == "CONTRIBUTORS_TILE":
            for metric in content.get("metrics") or []:
                if metric.get("id") == "CONTRIBUTORS_TILE_STEPS":
                    steps = number(metric.get("status"))
                    result["officialSteps"] = int(steps) if steps is not None else None
                    baseline = number(metric.get("status_subtitle"))
                    result["stepsBaseline"] = baseline
    return result


def archive_digest(manifest: dict[str, Any]) -> str:
    stable = json.dumps(manifest, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(stable).hexdigest()


def build(archive: Path, database_path: Path, metrics_path: Path) -> None:
    manifest = json.loads((archive / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("completed_at") is None:
        raise RuntimeError("Refusing an incomplete WHOOP private archive")
    digest = archive_digest(manifest)
    database_path.parent.mkdir(parents=True, exist_ok=True)
    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    if database_path.exists():
        database_path.unlink()

    daily: dict[str, dict[str, Any]] = {}
    connection = sqlite3.connect(database_path)
    try:
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.executescript(
            """
            CREATE TABLE archive_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE response_body (
                sha256 TEXT PRIMARY KEY,
                content_type TEXT,
                raw_bytes INTEGER NOT NULL,
                compression TEXT NOT NULL CHECK(compression = 'zlib'),
                compressed_body BLOB NOT NULL
            );
            CREATE TABLE request_record (
                sequence INTEGER PRIMARY KEY,
                category TEXT NOT NULL,
                name TEXT NOT NULL,
                method TEXT NOT NULL CHECK(method = 'GET'),
                path TEXT NOT NULL,
                query_json TEXT NOT NULL,
                status INTEGER NOT NULL,
                fetched_at TEXT NOT NULL,
                attempts INTEGER NOT NULL,
                content_type TEXT,
                raw_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL REFERENCES response_body(sha256)
            );
            CREATE INDEX request_record_path ON request_record(path, fetched_at);
            CREATE INDEX request_record_name ON request_record(category, name);
            PRAGMA user_version=1;
            """
        )
        metadata = {
            "format_version": "1",
            "source": str(manifest.get("source", "WHOOP private iOS API")),
            "source_archive": archive.name,
            "source_manifest_sha256": digest,
            "created_at": str(manifest.get("created_at")),
            "completed_at": str(manifest.get("completed_at")),
            "coverage_start": str(manifest["coverage_requested"]["start"]),
            "coverage_end": str(manifest["coverage_requested"]["end"]),
        }
        connection.executemany(
            "INSERT INTO archive_metadata(key, value) VALUES (?, ?)", metadata.items()
        )

        inserted_hashes: set[str] = set()
        for record in manifest["records"]:
            source = archive / record["file"]
            body = source.read_bytes()
            actual = hashlib.sha256(body).hexdigest()
            if actual != record["sha256"] or len(body) != record["bytes"]:
                raise RuntimeError(f"Archive integrity failure: {record['file']}")
            if actual not in inserted_hashes:
                connection.execute(
                    """
                    INSERT INTO response_body
                    (sha256, content_type, raw_bytes, compression, compressed_body)
                    VALUES (?, ?, ?, 'zlib', ?)
                    """,
                    (actual, record.get("content_type"), len(body), zlib.compress(body, 9)),
                )
                inserted_hashes.add(actual)
            connection.execute(
                """
                INSERT INTO request_record
                (sequence, category, name, method, path, query_json, status,
                 fetched_at, attempts, content_type, raw_bytes, sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record["sequence"],
                    record["category"],
                    record["name"],
                    record["method"],
                    record["path"],
                    json.dumps(record.get("query", {}), separators=(",", ":"), sort_keys=True),
                    record["status"],
                    record["fetched_at"],
                    record["attempts"],
                    record.get("content_type"),
                    record["bytes"],
                    actual,
                ),
            )

            match = DAY_PATTERN.fullmatch(record["name"])
            if not match or record["status"] != 200:
                continue
            payload = json.loads(body)
            day, kind = match.groups()
            projection = daily.setdefault(day, {"dateKey": day})
            projection.update(
                recovery_projection(payload) if kind == "recovery" else strain_projection(payload)
            )
            projection[f"source{kind.title()}SHA256"] = actual

        connection.commit()
        check = connection.execute("PRAGMA quick_check").fetchone()[0]
        if check != "ok":
            raise RuntimeError(f"Compact archive failed SQLite quick_check: {check}")
    finally:
        connection.close()

    database_sha = hashlib.sha256(database_path.read_bytes()).hexdigest()
    output = {
        "formatVersion": 1,
        "source": "whoop_private_ios_api",
        "sourceArchive": archive.name,
        "sourceManifestSHA256": digest,
        "sourceDatabaseSHA256": database_sha,
        "coverageStart": manifest["coverage_requested"]["start"],
        "coverageEnd": manifest["coverage_requested"]["end"],
        "daily": [daily[key] for key in sorted(daily)],
    }
    metrics_path.write_text(
        json.dumps(output, separators=(",", ":"), sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"Wrote {len(output['daily'])} daily projections and "
        f"{database_path.stat().st_size} compact archive bytes"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("database_output", type=Path)
    parser.add_argument("metrics_output", type=Path)
    args = parser.parse_args()
    build(args.archive, args.database_output, args.metrics_output)


if __name__ == "__main__":
    main()
