from __future__ import annotations

import argparse
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from backup_retention import (
    DEFAULT_BACKUP_ROOT,
    RETIRED_DIRECTORY,
    RETIREMENT_RECORD,
    backup_from_json,
    purge_expired_retirements,
)
from phone_shipping_core import (
    BackupResult,
    ShippingError,
    atomic_write_json,
    backup_to_json,
    create_standalone_backup,
    sha256,
    sqlite_checks,
    validate_backup_result,
)

DEFAULT_LEGACY_ROOT = Path.home() / "Documents/personal/data/whoop/app-backups"
MIGRATION_DATABASE = re.compile(r"^sleep-v\d+-before-v\d+\.sqlite3$")
SNAPSHOT_TIMESTAMP = re.compile(r"(?P<stamp>\d{8}T\d{4}(?:\d{2})?)(?P<zone>Z|ET)")


def snapshot_time(snapshot: Path) -> datetime:
    match = SNAPSHOT_TIMESTAMP.search(snapshot.name)
    if match is None:
        return datetime.fromtimestamp(snapshot.stat().st_mtime, UTC)
    stamp = match.group("stamp")
    parsed = datetime.strptime(stamp, "%Y%m%dT%H%M%S" if len(stamp) == 15 else "%Y%m%dT%H%M")
    timezone = UTC if match.group("zone") == "Z" else ZoneInfo("America/Toronto")
    return parsed.replace(tzinfo=timezone).astimezone(UTC)


def snapshot_time_ns(snapshot: Path) -> int:
    if SNAPSHOT_TIMESTAMP.search(snapshot.name) is None:
        return snapshot.stat().st_mtime_ns
    value = snapshot_time(snapshot)
    return int(value.timestamp()) * 1_000_000_000 + value.microsecond * 1_000


@dataclass(frozen=True)
class LegacyCandidate:
    snapshot: Path
    database: Path
    schema_version: int
    quick_check: str
    foreign_key_violations: int
    table_counts: dict[str, int]

    @property
    def score(self) -> tuple[int, int, int]:
        return (
            sum(self.table_counts.values()),
            self.database.stat().st_size,
            snapshot_time_ns(self.snapshot),
        )


@dataclass(frozen=True)
class LegacyInventory:
    selected: tuple[LegacyCandidate, ...]
    usable_snapshots: tuple[Path, ...]
    unusable_snapshots: tuple[Path, ...]
    invalid_databases: tuple[Path, ...]


def candidate_databases(snapshot: Path) -> tuple[Path, ...]:
    standalone = sorted(snapshot.rglob("*standalone.sqlite3"))
    current = standalone or sorted(snapshot.rglob("sleep.sqlite3"))
    migrations = sorted(
        path for path in snapshot.rglob("*.sqlite3") if MIGRATION_DATABASE.fullmatch(path.name)
    )
    return tuple(dict.fromkeys([*current, *migrations]))


def inspect_legacy_root(source_root: Path) -> LegacyInventory:
    selected_by_schema: dict[int, LegacyCandidate] = {}
    usable: list[Path] = []
    unusable: list[Path] = []
    invalid: list[Path] = []
    if not source_root.is_dir():
        raise ShippingError(f"Legacy backup root does not exist: {source_root}")
    for snapshot in sorted(source_root.iterdir()):
        if not snapshot.is_dir() or snapshot.name == RETIRED_DIRECTORY:
            continue
        snapshot_valid = False
        for database in candidate_databases(snapshot):
            try:
                schema, quick_check, foreign_keys, table_counts = sqlite_checks(database)
            except ShippingError:
                invalid.append(database)
                continue
            if quick_check != "ok" or foreign_keys != 0:
                invalid.append(database)
                continue
            snapshot_valid = True
            candidate = LegacyCandidate(
                snapshot=snapshot,
                database=database,
                schema_version=schema,
                quick_check=quick_check,
                foreign_key_violations=foreign_keys,
                table_counts=table_counts,
            )
            previous = selected_by_schema.get(schema)
            if previous is None or candidate.score > previous.score:
                selected_by_schema[schema] = candidate
        (usable if snapshot_valid else unusable).append(snapshot)
    return LegacyInventory(
        selected=tuple(selected_by_schema[key] for key in sorted(selected_by_schema)),
        usable_snapshots=tuple(usable),
        unusable_snapshots=tuple(unusable),
        invalid_databases=tuple(invalid),
    )


def existing_backups_by_schema(backup_root: Path) -> dict[int, BackupResult]:
    existing: dict[int, BackupResult] = {}
    for directory in sorted(backup_root.iterdir()) if backup_root.is_dir() else []:
        manifest = directory / "backup-result.json"
        if not directory.is_dir() or not manifest.is_file():
            continue
        try:
            result = backup_from_json(manifest)
            validate_backup_result(result)
        except (OSError, ShippingError):
            continue
        previous = existing.get(result.schema_version)
        if previous is None or sum(result.table_counts.values()) > sum(
            previous.table_counts.values()
        ):
            existing[result.schema_version] = result
    return existing


def create_normalized_backup(
    candidate: LegacyCandidate,
    source_root: Path,
    backup_root: Path,
    *,
    now: datetime | None = None,
) -> BackupResult:
    source_time = snapshot_time(candidate.snapshot)
    source_time_ns = snapshot_time_ns(candidate.snapshot)
    snapshot_times = (source_time_ns, source_time_ns)
    source_digest = sha256(candidate.database)
    destination = backup_root / f"legacy-schema-v{candidate.schema_version}-{source_digest[:12]}"
    if destination.exists():
        result = backup_from_json(destination / "backup-result.json")
        validate_backup_result(result)
        os.utime(destination, ns=snapshot_times)
        return result
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = Path(tempfile.mkdtemp(prefix=".legacy-import-", dir=backup_root))
    try:
        standalone = temporary / "sleep-standalone.sqlite3"
        create_standalone_backup(candidate.database, standalone)
        schema, quick_check, foreign_keys, table_counts = sqlite_checks(standalone)
        if (
            schema != candidate.schema_version
            or quick_check != "ok"
            or foreign_keys != 0
            or table_counts != candidate.table_counts
        ):
            raise ShippingError(
                "Normalized legacy restore point does not match its source database."
            )
        provenance = temporary / "legacy-import.json"
        atomic_write_json(
            provenance,
            {
                "formatVersion": 1,
                "importedAt": (now or datetime.now(UTC)).isoformat(),
                "sourceCreatedAt": source_time.isoformat(),
                "sourceDatabase": str(candidate.database.relative_to(source_root)),
                "sourceSHA256": source_digest,
                "sourceSnapshot": candidate.snapshot.name,
            },
        )
        hashes = {path.name: sha256(path) for path in (standalone, provenance)}
        atomic_write_json(temporary / "SHA256SUMS.json", hashes)
        temporary_result = BackupResult(
            path=str(temporary),
            standalone_database=str(standalone),
            schema_version=schema,
            quick_check=quick_check,
            foreign_key_violations=foreign_keys,
            table_counts=table_counts,
            hashes=hashes,
        )
        atomic_write_json(temporary / "backup-result.json", backup_to_json(temporary_result))
        validate_backup_result(temporary_result)
        os.replace(temporary, destination)
        result = BackupResult(
            path=str(destination),
            standalone_database=str(destination / standalone.name),
            schema_version=schema,
            quick_check=quick_check,
            foreign_key_violations=foreign_keys,
            table_counts=table_counts,
            hashes=hashes,
        )
        atomic_write_json(destination / "backup-result.json", backup_to_json(result))
        destination.chmod(0o700)
        for path in (destination / standalone.name, destination / provenance.name):
            path.chmod(0o600)
        validate_backup_result(result)
        os.utime(destination, ns=snapshot_times)
        return result
    except Exception:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise


def quarantine_snapshots(
    source_root: Path,
    snapshots: tuple[Path, ...],
    *,
    now: datetime | None = None,
) -> tuple[Path, ...]:
    retired_root = source_root / RETIRED_DIRECTORY
    retired_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    retired_root.chmod(0o700)
    retired_at = (now or datetime.now(UTC)).isoformat()
    retired: list[Path] = []
    for snapshot in snapshots:
        resolved = snapshot.resolve()
        if resolved.parent != source_root.resolve() or not resolved.is_dir():
            raise ShippingError(f"Refusing to retire path outside the legacy root: {snapshot}")
        destination = retired_root / snapshot.name
        if destination.exists():
            raise ShippingError(f"Legacy retirement destination already exists: {destination}")
        os.replace(resolved, destination)
        atomic_write_json(
            destination / RETIREMENT_RECORD,
            {"formatVersion": 1, "retiredAt": retired_at, "originalPath": str(resolved)},
        )
        retired.append(destination)
    return tuple(retired)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Normalize old app restore points into one validated backup per schema"
    )
    parser.add_argument("--source-root", default=str(DEFAULT_LEGACY_ROOT))
    parser.add_argument("--backup-root", default=str(DEFAULT_BACKUP_ROOT))
    parser.add_argument("--retention-days", type=int, default=7)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--retire-unusable", action="store_true")
    parser.add_argument("--purge-now", action="store_true")
    args = parser.parse_args()
    if args.retention_days < 1:
        raise SystemExit("Retention days must be a positive integer.")
    if args.purge_now and not args.apply:
        raise SystemExit("--purge-now requires --apply.")
    if args.retire_unusable and not args.apply:
        raise SystemExit("--retire-unusable requires --apply.")
    source_root = Path(args.source_root).expanduser().resolve()
    backup_root = Path(args.backup_root).expanduser().resolve()
    if (
        source_root == backup_root
        or source_root in backup_root.parents
        or backup_root in source_root.parents
    ):
        raise SystemExit("Legacy and managed backup roots must be separate trees.")

    inventory = inspect_legacy_root(source_root)
    existing = existing_backups_by_schema(backup_root)
    print(
        f"schemas={len(inventory.selected)}\nusableSnapshots={len(inventory.usable_snapshots)}\n"
        f"unusableSnapshots={len(inventory.unusable_snapshots)}\n"
        f"invalidDatabases={len(inventory.invalid_databases)}"
    )
    imports = [item for item in inventory.selected if item.schema_version not in existing]
    for item in inventory.selected:
        if item.schema_version in existing:
            print(f"EXISTING\tv{item.schema_version}\t{existing[item.schema_version].path}")
        else:
            print(f"IMPORT\tv{item.schema_version}\t{item.database}")
    for path in inventory.unusable_snapshots:
        print(f"UNUSABLE\t{path}")
    if not args.apply:
        print("status=dry-run")
        return 0

    imported: list[BackupResult] = []
    for item in imports:
        result = create_normalized_backup(item, source_root, backup_root)
        imported.append(result)
        print(f"IMPORTED\tv{result.schema_version}\t{result.path}")
    coverage = existing_backups_by_schema(backup_root)
    missing = sorted(
        item.schema_version for item in inventory.selected if item.schema_version not in coverage
    )
    if missing:
        raise ShippingError(
            f"Refusing retirement because normalized schema coverage is missing: {missing}"
        )
    for result in imported:
        validate_backup_result(result)
    retire = inventory.usable_snapshots
    if args.retire_unusable:
        retire = (*retire, *inventory.unusable_snapshots)
    retired = quarantine_snapshots(source_root, tuple(sorted(retire)))
    purged = purge_expired_retirements(
        source_root,
        retention_days=0 if args.purge_now else args.retention_days,
    )
    print(f"status=applied\nretired={len(retired)}\npurged={len(purged)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
