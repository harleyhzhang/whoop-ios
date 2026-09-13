#!/usr/bin/env python3
"""Build and validate an offline schema-v11 storage prototype.

The source is opened read-only and copied through SQLite's online-backup API.
Only the newly-created candidate is rewritten. The candidate is a benchmark
artifact, not a production migration: it lets us measure the schema shape and
the migration's conservative free-space envelope before putting that logic on
an iPhone.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import struct
import sys
import time
from collections.abc import Sequence
from contextlib import suppress
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from storage_v11_schema import (
    AFFECTED_TABLES,
    CANDIDATE_SCHEMA_VERSION,
    SEMANTIC_CANDIDATE_QUERIES,
    SEMANTIC_SOURCE_QUERIES,
    SOURCE_SCHEMA_VERSION,
    migration_sql,
    quote_identifier,
    representative_query_specs,
)

FORMAT_VERSION = 1


class PrototypeError(RuntimeError):
    """Raised when a safe or semantically equivalent prototype cannot be built."""


@dataclass(frozen=True)
class TableParity:
    rows: int
    source_sha256: str
    candidate_sha256: str


@dataclass(frozen=True)
class QueryParity:
    name: str
    rows: int
    source_sha256: str
    candidate_sha256: str
    source_plan: list[str]
    candidate_plan: list[str]


@dataclass(frozen=True)
class SizeReport:
    source_bytes: int
    copied_candidate_bytes: int
    pre_vacuum_candidate_bytes: int
    final_candidate_bytes: int
    final_savings_bytes: int
    final_savings_fraction: float
    rollback_snapshot_bytes: int
    rebuild_scratch_bytes: int
    vacuum_scratch_bytes: int
    estimated_peak_bytes: int
    estimated_temporary_free_space_bytes: int
    available_bytes_before: int


def connect_read_only(path: Path) -> sqlite3.Connection:
    uri = path.resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=30)
    connection.execute("PRAGMA query_only=ON")
    return connection


def scalar_int(connection: sqlite3.Connection, sql: str, parameters: Sequence[object] = ()) -> int:
    row = connection.execute(sql, parameters).fetchone()
    if row is None:
        raise PrototypeError(f"Query returned no value: {sql}")
    return int(row[0])


def database_file_bytes(path: Path) -> int:
    return sum(
        candidate.stat().st_size
        for candidate in (path, Path(str(path) + "-wal"), Path(str(path) + "-shm"))
        if candidate.exists()
    )


def require_clean_database(connection: sqlite3.Connection, label: str) -> None:
    quick = connection.execute("PRAGMA quick_check").fetchone()
    if quick is None or quick[0] != "ok":
        raise PrototypeError(f"{label} failed PRAGMA quick_check: {quick!r}")
    violations = connection.execute("PRAGMA foreign_key_check").fetchmany(20)
    if violations:
        raise PrototypeError(f"{label} has foreign-key violations: {violations!r}")


def require_integrity_check(connection: sqlite3.Connection, label: str) -> str:
    rows = connection.execute("PRAGMA integrity_check").fetchall()
    if rows != [("ok",)]:
        raise PrototypeError(f"{label} failed PRAGMA integrity_check: {rows[:20]!r}")
    return "ok"


def user_tables(connection: sqlite3.Connection) -> list[str]:
    return [
        str(row[0])
        for row in connection.execute(
            """
            SELECT name FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
    ]


def require_v10_shape(connection: sqlite3.Connection) -> None:
    version = scalar_int(connection, "PRAGMA user_version")
    if version != SOURCE_SCHEMA_VERSION:
        raise PrototypeError(
            f"Source schema is v{version}; this prototype requires v{SOURCE_SCHEMA_VERSION}."
        )
    missing = sorted(set(AFFECTED_TABLES) - set(user_tables(connection)))
    if missing:
        raise PrototypeError(f"Source is missing required v10 tables: {', '.join(missing)}")
    checks = {
        "raw packet -> offload session": """
            SELECT COUNT(*) FROM whoop_raw_packet r
            WHERE r.offload_session_id IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM whoop_offload_session s WHERE s.id=r.offload_session_id
              )
        """,
        "replay -> raw packet": """
            SELECT COUNT(*) FROM whoop_packet_replay x
            WHERE NOT EXISTS (
                SELECT 1 FROM whoop_raw_packet r WHERE r.id=x.first_packet_id
            )
        """,
        "duplicate raw delivery sequence": """
            SELECT COUNT(*) FROM (
                SELECT delivery_sequence FROM whoop_raw_packet
                WHERE delivery_sequence IS NOT NULL
                GROUP BY delivery_sequence HAVING COUNT(*) > 1
            )
        """,
        "duplicate offload rowid": """
            SELECT COUNT(*) FROM (
                SELECT rowid FROM whoop_offload_session GROUP BY rowid HAVING COUNT(*) > 1
            )
        """,
        "duplicate raw rowid": """
            SELECT COUNT(*) FROM (
                SELECT rowid FROM whoop_raw_packet GROUP BY rowid HAVING COUNT(*) > 1
            )
        """,
        "heart-rate -> raw packet": """
            SELECT COUNT(*) FROM heart_rate_sample h
            WHERE NOT EXISTS (
                SELECT 1 FROM whoop_raw_packet r WHERE r.id=h.source_packet_id
            )
        """,
        "historical -> raw packet": """
            SELECT COUNT(*) FROM whoop_historical_sample h
            WHERE NOT EXISTS (
                SELECT 1 FROM whoop_raw_packet r WHERE r.id=h.source_packet_id
            )
        """,
        "PPG -> raw packet": """
            SELECT COUNT(*) FROM whoop_ppg_packet p
            WHERE NOT EXISTS (
                SELECT 1 FROM whoop_raw_packet r WHERE r.id=p.source_packet_id
            )
        """,
        "decode failure -> raw packet": """
            SELECT COUNT(*) FROM whoop_decode_failure d
            WHERE NOT EXISTS (
                SELECT 1 FROM whoop_raw_packet r WHERE r.id=d.source_packet_id
            )
        """,
    }
    failures = [name for name, sql in checks.items() if scalar_int(connection, sql) != 0]
    if failures:
        raise PrototypeError("Source cannot be normalized safely: " + ", ".join(failures))


def update_hash(digest: Any, value: object) -> None:
    if value is None:
        digest.update(b"N")
    elif isinstance(value, bytes):
        digest.update(b"B" + len(value).to_bytes(8, "big") + value)
    elif isinstance(value, int):
        encoded = str(value).encode()
        digest.update(b"I" + len(encoded).to_bytes(8, "big") + encoded)
    elif isinstance(value, float):
        digest.update(b"F" + struct.pack(">d", value))
    elif isinstance(value, str):
        encoded = value.encode()
        digest.update(b"T" + len(encoded).to_bytes(8, "big") + encoded)
    else:
        raise PrototypeError(f"Unsupported SQLite value in semantic hash: {type(value)!r}")


def query_hash(
    connection: sqlite3.Connection,
    sql: str,
    parameters: Sequence[object] = (),
) -> tuple[int, str]:
    digest = hashlib.sha256()
    rows = 0
    cursor = connection.execute(sql, parameters)
    for row in cursor:
        digest.update(b"R" + len(row).to_bytes(4, "big"))
        for value in row:
            update_hash(digest, value)
        rows += 1
    return rows, digest.hexdigest()


def primary_key_columns(connection: sqlite3.Connection, table: str) -> list[str]:
    rows = connection.execute(f"PRAGMA table_info({quote_identifier(table)})").fetchall()
    keyed = sorted((int(row[5]), str(row[1])) for row in rows if int(row[5]) > 0)
    return [name for _, name in keyed]


def generic_table_hash(connection: sqlite3.Connection, table: str) -> tuple[int, str]:
    columns = [
        str(row[1]) for row in connection.execute(f"PRAGMA table_info({quote_identifier(table)})")
    ]
    if not columns:
        raise PrototypeError(f"Cannot inspect columns for {table}.")
    order = primary_key_columns(connection, table) or columns
    projection = ", ".join(quote_identifier(column) for column in columns)
    ordering = ", ".join(quote_identifier(column) for column in order)
    return query_hash(
        connection,
        f"SELECT {projection} FROM {quote_identifier(table)} ORDER BY {ordering}",
    )


def semantic_hashes(
    connection: sqlite3.Connection,
    queries: dict[str, str],
) -> dict[str, tuple[int, str]]:
    return {table: query_hash(connection, query) for table, query in queries.items()}


def explain(
    connection: sqlite3.Connection,
    sql: str,
    parameters: Sequence[object],
) -> list[str]:
    return [str(row[3]) for row in connection.execute("EXPLAIN QUERY PLAN " + sql, parameters)]


def representative_queries(
    source: sqlite3.Connection,
    candidate: sqlite3.Connection,
) -> list[QueryParity]:
    result: list[QueryParity] = []
    for name, source_sql, candidate_sql, parameters in representative_query_specs(source):
        source_rows, source_hash = query_hash(source, source_sql, parameters)
        candidate_rows, candidate_hash = query_hash(candidate, candidate_sql, parameters)
        if (source_rows, source_hash) != (candidate_rows, candidate_hash):
            raise PrototypeError(f"Representative query parity failed: {name}")
        candidate_plan = explain(candidate, candidate_sql, parameters)
        if not any("INDEX" in line or "PRIMARY KEY" in line for line in candidate_plan):
            raise PrototypeError(f"Candidate query lost indexed access: {name}: {candidate_plan}")
        result.append(
            QueryParity(
                name=name,
                rows=source_rows,
                source_sha256=source_hash,
                candidate_sha256=candidate_hash,
                source_plan=explain(source, source_sql, parameters),
                candidate_plan=candidate_plan,
            )
        )
    return result


def reserve_new_file(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise PrototypeError(f"Refusing to overwrite existing output: {path}") from error
    os.close(descriptor)


def remove_created_database(path: Path) -> None:
    for candidate in (
        path,
        Path(str(path) + "-wal"),
        Path(str(path) + "-shm"),
        Path(str(path) + "-journal"),
    ):
        with suppress(FileNotFoundError):
            candidate.unlink()


def prototype(source_path: Path, output_path: Path) -> dict[str, object]:
    source_path = source_path.expanduser().resolve()
    output_path = output_path.expanduser().resolve()
    if not source_path.is_file():
        raise PrototypeError(f"Source database does not exist: {source_path}")
    if source_path == output_path:
        raise PrototypeError("Source and output must be different paths.")
    reserve_new_file(output_path)
    started = time.perf_counter()
    created = True
    try:
        source_bytes = database_file_bytes(source_path)
        available = shutil.disk_usage(output_path.parent).free
        conservative_required = source_bytes * 4
        if available < conservative_required:
            raise PrototypeError(
                f"Only {available} bytes are free; the conservative preflight requires "
                f"{conservative_required} bytes (4x source)."
            )
        with connect_read_only(source_path) as source:
            require_clean_database(source, "Source")
            source_integrity = require_integrity_check(source, "Source")
            require_v10_shape(source)
            source_semantic = semantic_hashes(source, SEMANTIC_SOURCE_QUERIES)
            unaffected = sorted(set(user_tables(source)) - set(AFFECTED_TABLES))
            unaffected_before = {table: generic_table_hash(source, table) for table in unaffected}

            candidate = sqlite3.connect(output_path, timeout=120)
            try:
                source.backup(candidate)
                candidate.commit()
                copied_bytes = database_file_bytes(output_path)
                journal = candidate.execute("PRAGMA journal_mode=DELETE").fetchone()
                if journal is None or str(journal[0]).lower() != "delete":
                    raise PrototypeError("Could not configure the offline candidate journal.")
                candidate.execute("PRAGMA synchronous=FULL")
                candidate.execute("PRAGMA foreign_keys=OFF")
                try:
                    candidate.executescript(migration_sql())
                except Exception:
                    candidate.rollback()
                    raise
                candidate.execute("PRAGMA foreign_keys=ON")
                pre_vacuum_bytes = database_file_bytes(output_path)
                require_clean_database(candidate, "Pre-VACUUM candidate")
                if scalar_int(candidate, "PRAGMA user_version") != CANDIDATE_SCHEMA_VERSION:
                    raise PrototypeError("Candidate schema version was not advanced to 11.")

                candidate_semantic = semantic_hashes(candidate, SEMANTIC_CANDIDATE_QUERIES)
                table_parity: dict[str, TableParity] = {}
                for table in AFFECTED_TABLES:
                    source_rows, source_hash = source_semantic[table]
                    candidate_rows, candidate_hash = candidate_semantic[table]
                    if (source_rows, source_hash) != (candidate_rows, candidate_hash):
                        raise PrototypeError(f"Semantic parity failed for {table}.")
                    table_parity[table] = TableParity(
                        rows=source_rows,
                        source_sha256=source_hash,
                        candidate_sha256=candidate_hash,
                    )
                for table, source_value in unaffected_before.items():
                    candidate_value = generic_table_hash(candidate, table)
                    if candidate_value != source_value:
                        raise PrototypeError(f"Unaffected table changed: {table}.")

                query_parity = representative_queries(source, candidate)
                candidate.execute("ANALYZE")
                candidate.commit()
                candidate.execute("VACUUM")
                candidate.execute("PRAGMA optimize")
                candidate.commit()
                require_clean_database(candidate, "Final candidate")
                candidate_integrity = require_integrity_check(candidate, "Final candidate")
                final_bytes = database_file_bytes(output_path)
            finally:
                candidate.close()

        # Reopen both artifacts to catch close/checkpoint persistence issues.
        with connect_read_only(source_path) as source_reopened:
            if scalar_int(source_reopened, "PRAGMA user_version") != SOURCE_SCHEMA_VERSION:
                raise PrototypeError("Source changed while building the prototype.")
            require_clean_database(source_reopened, "Reopened source")
        with connect_read_only(output_path) as candidate_reopened:
            require_clean_database(candidate_reopened, "Reopened candidate")
            if scalar_int(candidate_reopened, "PRAGMA user_version") != CANDIDATE_SCHEMA_VERSION:
                raise PrototypeError("Reopened candidate is not schema v11.")

        rollback_bytes = source_bytes
        rebuild_scratch = max(source_bytes, pre_vacuum_bytes - copied_bytes)
        vacuum_scratch = pre_vacuum_bytes
        estimated_peak = source_bytes + rollback_bytes + pre_vacuum_bytes + vacuum_scratch
        temporary_free = rollback_bytes + pre_vacuum_bytes + vacuum_scratch
        duration = time.perf_counter() - started
        size = SizeReport(
            source_bytes=source_bytes,
            copied_candidate_bytes=copied_bytes,
            pre_vacuum_candidate_bytes=pre_vacuum_bytes,
            final_candidate_bytes=final_bytes,
            final_savings_bytes=source_bytes - final_bytes,
            final_savings_fraction=(source_bytes - final_bytes) / source_bytes,
            rollback_snapshot_bytes=rollback_bytes,
            rebuild_scratch_bytes=rebuild_scratch,
            vacuum_scratch_bytes=vacuum_scratch,
            estimated_peak_bytes=estimated_peak,
            estimated_temporary_free_space_bytes=temporary_free,
            available_bytes_before=available,
        )
        created = False
        return {
            "formatVersion": FORMAT_VERSION,
            "scope": {
                "kind": "full-database-copy-with-seven-core-tables-normalized",
                "affectedTables": list(AFFECTED_TABLES),
                "unaffectedTables": unaffected,
                "sourceNeverOpenedWritable": True,
            },
            "source": str(source_path),
            "candidate": str(output_path),
            "sourceSchemaVersion": SOURCE_SCHEMA_VERSION,
            "candidateSchemaVersion": CANDIDATE_SCHEMA_VERSION,
            "durationSeconds": duration,
            "sizes": asdict(size),
            "tableParity": {table: asdict(value) for table, value in table_parity.items()},
            "unaffectedTableParity": {
                table: {"rows": rows, "sha256": digest}
                for table, (rows, digest) in unaffected_before.items()
            },
            "queryParity": [asdict(value) for value in query_parity],
            "validation": {
                "quickCheck": "ok",
                "sourceIntegrityCheck": source_integrity,
                "candidateIntegrityCheck": candidate_integrity,
                "foreignKeyCheckViolations": 0,
                "semanticHashesMatch": True,
                "representativeQueryResultsMatch": True,
            },
        }
    except Exception:
        if created:
            remove_created_database(output_path)
        raise


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="read-only schema-v10 database")
    parser.add_argument("--output", required=True, type=Path, help="new schema-v11 candidate")
    parser.add_argument("--report", type=Path, help="optional new JSON report path")
    return parser.parse_args(arguments)


def write_new_report(path: Path, report: dict[str, object]) -> None:
    path = path.expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise PrototypeError(f"Refusing to overwrite existing report: {path}") from error
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        path.unlink(missing_ok=True)
        raise


def main(arguments: Sequence[str] | None = None) -> int:
    options = parse_arguments(arguments if arguments is not None else sys.argv[1:])
    try:
        report = prototype(options.source, options.output)
        if options.report is not None:
            write_new_report(options.report, report)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    except (OSError, sqlite3.Error, PrototypeError) as error:
        print(f"storage-v11-prototype: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
