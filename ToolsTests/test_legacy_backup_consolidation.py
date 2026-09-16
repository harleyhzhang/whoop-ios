from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path

import backup_retention
import legacy_backup_consolidation as legacy
import phone_shipping_core as core


def make_database(path: Path, schema: int, rows: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    connection.execute(f"PRAGMA user_version = {schema}")
    connection.execute("CREATE TABLE whoop_raw_packet(id TEXT PRIMARY KEY)")
    connection.executemany(
        "INSERT INTO whoop_raw_packet VALUES (?)",
        ((f"packet-{index}",) for index in range(rows)),
    )
    connection.commit()
    connection.close()


def make_managed_backup(root: Path, schema: int, rows: int) -> core.BackupResult:
    destination = root / f"existing-v{schema}"
    database = destination / "sleep-standalone.sqlite3"
    make_database(database, schema, rows)
    checked_schema, quick, foreign_keys, counts = core.sqlite_checks(database)
    hashes = {database.name: core.sha256(database)}
    core.atomic_write_json(destination / "SHA256SUMS.json", hashes)
    result = core.BackupResult(
        path=str(destination),
        standalone_database=str(database),
        schema_version=checked_schema,
        quick_check=quick,
        foreign_key_violations=foreign_keys,
        table_counts=counts,
        hashes=hashes,
    )
    core.atomic_write_json(destination / "backup-result.json", core.backup_to_json(result))
    return result


def test_snapshot_time_parses_legacy_utc_and_eastern_names(tmp_path: Path) -> None:
    utc = tmp_path / "app-pre-fix-20260908T202000Z"
    eastern = tmp_path / "app-pre-0.7.0-20260907T2209ET"

    assert legacy.snapshot_time(utc) == datetime(2026, 9, 8, 20, 20, tzinfo=UTC)
    assert legacy.snapshot_time(eastern) == datetime(2026, 9, 8, 2, 9, tzinfo=UTC)


def test_inventory_selects_fullest_database_per_schema_and_reuses_managed_schema(
    tmp_path: Path,
) -> None:
    source = tmp_path / "app-backups"
    make_database(source / "older" / "sleep.sqlite3", 4, 1)
    make_database(source / "newer" / "Sleep/sleep.sqlite3", 4, 3)
    make_database(source / "migration" / "sleep-v7-before-v8.sqlite3", 7, 2)
    broken = source / "broken"
    broken.mkdir(parents=True)
    (broken / "sleep.sqlite3").write_bytes(b"not sqlite")
    managed = tmp_path / "device-backups"
    existing = make_managed_backup(managed, 7, 4)

    inventory = legacy.inspect_legacy_root(source)
    selected = {candidate.schema_version: candidate for candidate in inventory.selected}

    assert set(selected) == {4, 7}
    assert selected[4].snapshot.name == "newer"
    assert broken in inventory.unusable_snapshots
    assert legacy.existing_backups_by_schema(managed)[7] == existing

    imported = legacy.create_normalized_backup(
        selected[4],
        source,
        managed,
        now=datetime(2026, 9, 15, tzinfo=UTC),
    )
    assert imported.schema_version == 4
    assert imported.table_counts["whoop_raw_packet"] == 3
    assert Path(imported.path).stat().st_mtime_ns == selected[4].snapshot.stat().st_mtime_ns
    core.validate_backup_result(imported)


def test_quarantine_and_purge_only_recorded_legacy_directories(tmp_path: Path) -> None:
    source = tmp_path / "app-backups"
    snapshots = tuple(source / name for name in ("one", "two"))
    for snapshot in snapshots:
        snapshot.mkdir(parents=True)
    loose_file = source / "diagnostics.json"
    loose_file.write_text("{}")
    now = datetime(2026, 9, 15, tzinfo=UTC)

    retired = legacy.quarantine_snapshots(source, snapshots, now=now)

    assert all(path.is_dir() for path in retired)
    assert loose_file.is_file()
    assert backup_retention.purge_expired_retirements(source, now=now) == ()
    purged = backup_retention.purge_expired_retirements(source, now=now + timedelta(days=8))
    assert purged == retired
