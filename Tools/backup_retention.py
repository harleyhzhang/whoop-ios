from __future__ import annotations

import argparse
import os
import shutil
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

from phone_shipping_core import (
    BackupResult,
    ShippingError,
    atomic_write_json,
    backup_to_json,
    load_json,
    object_dict,
    required_int,
    required_string,
    sha256,
    sqlite_checks,
    validate_backup_result,
)

DEFAULT_BACKUP_ROOT = Path.home() / "Documents/personal/data/whoop/device-backups"
DEFAULT_STATE_PATH = Path.home() / "Documents/personal/data/whoop/device-install-state.json"
RETIRED_DIRECTORY = ".retired"
RETIREMENT_RECORD = ".retirement.json"


@dataclass(frozen=True)
class RetentionPlan:
    keep: tuple[Path, ...]
    retire: tuple[Path, ...]
    retire_shipping_runs: tuple[Path, ...]
    retire_unusable: tuple[Path, ...]
    manual_review: tuple[Path, ...]
    invalid: tuple[Path, ...]


def backup_from_json(path: Path) -> BackupResult:
    value = object_dict(load_json(path, "backup result"), "backup result")
    counts = object_dict(value.get("table_counts"), "backup result.table_counts")
    hashes = object_dict(value.get("hashes"), "backup result.hashes")
    return BackupResult(
        path=required_string(value, "path", "backup result"),
        standalone_database=required_string(value, "standalone_database", "backup result"),
        schema_version=required_int(value, "schema_version", "backup result"),
        quick_check=required_string(value, "quick_check", "backup result"),
        foreign_key_violations=required_int(value, "foreign_key_violations", "backup result"),
        table_counts={key: required_int(counts, key, "backup counts") for key in counts},
        hashes={key: required_string(hashes, key, "backup hashes") for key in hashes},
    )


def protected_backup_paths(state_path: Path, backup_root: Path) -> set[Path]:
    if not state_path.is_file():
        return set()
    state = object_dict(load_json(state_path, "device install state"), "device install state")
    root = backup_root.resolve()
    protected: set[Path] = set()
    for key in (
        "latestPreinstallBackup",
        "latestPostinstallBackup",
        "lastVerifiedBackup",
        "lastFullBackup",
    ):
        raw = state.get(key)
        if not isinstance(raw, dict):
            continue
        for path_key in ("path", "preinstall", "postinstall"):
            candidate = raw.get(path_key)
            if not isinstance(candidate, str) or not candidate:
                continue
            resolved = Path(candidate).expanduser().resolve()
            try:
                resolved.relative_to(root)
            except ValueError:
                continue
            protected.add(resolved)
    return protected


def plan_retention(
    backup_root: Path,
    state_path: Path,
    *,
    keep_newest: int = 2,
    now: datetime | None = None,
) -> RetentionPlan:
    root = backup_root.resolve()
    protected = protected_backup_paths(state_path, root)
    valid: list[tuple[Path, BackupResult]] = []
    invalid: list[Path] = []
    manual: list[Path] = []
    for candidate in sorted(root.iterdir()) if root.is_dir() else []:
        if not candidate.is_dir() or candidate.name in {"shipping-runs", RETIRED_DIRECTORY}:
            continue
        manifest = candidate / "backup-result.json"
        if not manifest.is_file():
            manual.append(candidate)
            continue
        try:
            result = backup_from_json(manifest)
            if Path(result.path).resolve() != candidate.resolve():
                raise ShippingError("Backup manifest path does not match its directory.")
            validate_backup_result(result)
            valid.append((candidate, result))
        except (OSError, ShippingError):
            invalid.append(candidate)

    valid.sort(key=lambda item: item[0].stat().st_mtime, reverse=True)
    keep: set[Path] = set(protected)
    keep.update(path.resolve() for path, _ in valid[:keep_newest])
    newest_per_schema: dict[int, Path] = {}
    newest_per_month: dict[str, Path] = {}
    monthly_cutoff = (now or datetime.now(UTC)) - timedelta(days=365)
    for path, result in valid:
        newest_per_schema.setdefault(result.schema_version, path.resolve())
        modified = datetime.fromtimestamp(path.stat().st_mtime, UTC)
        if modified >= monthly_cutoff:
            newest_per_month.setdefault(modified.strftime("%Y-%m"), path.resolve())
    keep.update(newest_per_schema.values())
    keep.update(newest_per_month.values())
    retire = tuple(path for path, _ in valid if path.resolve() not in keep)
    existing_keep = tuple(path for path, _ in valid if path.resolve() in keep)
    shipping_runs = root / "shipping-runs"
    completed_runs: list[Path] = []
    if shipping_runs.is_dir():
        for run in shipping_runs.iterdir():
            manifest = run / "manifest.json"
            if not run.is_dir() or not manifest.is_file():
                continue
            try:
                value = object_dict(load_json(manifest, "shipping manifest"), "shipping manifest")
            except ShippingError:
                continue
            if value.get("phase") == "complete":
                completed_runs.append(run)
    completed_runs.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    retire_runs = tuple(completed_runs[2:])
    return RetentionPlan(existing_keep, retire, retire_runs, (), tuple(manual), tuple(invalid))


def apply_retention(plan: RetentionPlan, backup_root: Path, *, now: datetime | None = None) -> None:
    root = backup_root.resolve()
    retired_root = root / RETIRED_DIRECTORY
    retired_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    retired_root.chmod(0o700)
    retired_at = (now or datetime.now(UTC)).isoformat()
    for source in plan.retire:
        resolved = source.resolve()
        if resolved.parent != root or not resolved.is_dir():
            raise ShippingError(f"Refusing to retire path outside the backup root: {source}")
        destination = retired_root / source.name
        if destination.exists():
            raise ShippingError(f"Retirement destination already exists: {destination}")
        os.replace(resolved, destination)
        atomic_write_json(
            destination / RETIREMENT_RECORD,
            {"formatVersion": 1, "retiredAt": retired_at, "originalPath": str(resolved)},
        )
    shipping_root = root / "shipping-runs"
    for source in plan.retire_shipping_runs:
        resolved = source.resolve()
        if resolved.parent != shipping_root.resolve() or not resolved.is_dir():
            raise ShippingError(f"Refusing to retire shipping run outside its root: {source}")
        destination = retired_root / f"shipping-run--{source.name}"
        if destination.exists():
            raise ShippingError(f"Retirement destination already exists: {destination}")
        os.replace(resolved, destination)
        atomic_write_json(
            destination / RETIREMENT_RECORD,
            {"formatVersion": 1, "retiredAt": retired_at, "originalPath": str(resolved)},
        )
    for source in plan.retire_unusable:
        resolved = source.resolve()
        if resolved.parent != root or not resolved.is_dir():
            raise ShippingError(f"Refusing to retire unusable path outside backup root: {source}")
        destination = retired_root / f"unusable--{source.name}"
        if destination.exists():
            raise ShippingError(f"Retirement destination already exists: {destination}")
        os.replace(resolved, destination)
        atomic_write_json(
            destination / RETIREMENT_RECORD,
            {"formatVersion": 1, "retiredAt": retired_at, "originalPath": str(resolved)},
        )


def purge_expired_retirements(
    backup_root: Path,
    *,
    retention_days: int = 7,
    now: datetime | None = None,
) -> tuple[Path, ...]:
    retired_root = backup_root.resolve() / RETIRED_DIRECTORY
    if not retired_root.is_dir():
        return ()
    cutoff = (now or datetime.now(UTC)) - timedelta(days=retention_days)
    purged: list[Path] = []
    for candidate in sorted(retired_root.iterdir()):
        record_path = candidate / RETIREMENT_RECORD
        if not candidate.is_dir() or not record_path.is_file():
            continue
        record = object_dict(load_json(record_path, "retirement record"), "retirement record")
        try:
            retired_at = datetime.fromisoformat(
                required_string(record, "retiredAt", "retirement record").replace("Z", "+00:00")
            )
        except (ShippingError, ValueError):
            continue
        if retired_at.tzinfo is None:
            retired_at = retired_at.replace(tzinfo=UTC)
        if retired_at > cutoff:
            continue
        candidate.resolve().relative_to(retired_root.resolve())
        shutil.rmtree(candidate)
        purged.append(candidate)
    return tuple(purged)


def prune_build_caches(cache_root: Path, current: Path, *, keep: int = 2) -> tuple[Path, ...]:
    root = cache_root.resolve()
    active = current.resolve()
    if active.parent != root:
        raise ShippingError(f"Active build cache is outside its managed root: {active}")
    candidates = sorted(
        (path for path in root.iterdir() if path.is_dir()),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    retained = {active, *(path.resolve() for path in candidates[:keep])}
    purged: list[Path] = []
    for candidate in candidates:
        if candidate.resolve() in retained:
            continue
        shutil.rmtree(candidate)
        purged.append(candidate)
    return tuple(purged)


def adopt_legacy_backup(directory: Path) -> BackupResult:
    root = directory.resolve()
    original_times = (root.stat().st_atime_ns, root.stat().st_mtime_ns)
    standalone_candidates = sorted(root.rglob("sleep-standalone.sqlite3"))
    if len(standalone_candidates) != 1:
        raise ShippingError(
            f"Expected one standalone database in legacy backup {root}; "
            f"found {len(standalone_candidates)}."
        )
    standalone = standalone_candidates[0]
    schema, quick_check, foreign_keys, table_counts = sqlite_checks(standalone)
    if quick_check != "ok" or foreign_keys != 0:
        raise ShippingError(f"Legacy backup failed SQLite checks: {root}")
    archive_candidates = sorted(root.rglob("whoop-official-archive.sqlite3"))
    if not archive_candidates:
        raise ShippingError(f"Legacy backup has no official archive: {root}")
    canonical_archive = root / "whoop-official-archive.sqlite3"
    if canonical_archive in archive_candidates:
        archive = canonical_archive
    elif len(archive_candidates) == 1:
        archive = archive_candidates[0]
    else:
        raise ShippingError(f"Legacy backup has ambiguous official archives: {root}")
    archive_schema, archive_quick, archive_foreign_keys, _ = sqlite_checks(archive)
    if archive_schema < 1 or archive_quick != "ok" or archive_foreign_keys != 0:
        raise ShippingError(f"Legacy official archive failed SQLite checks: {root}")
    canonical_standalone = root / "sleep-standalone.sqlite3"
    if standalone != canonical_standalone:
        os.replace(standalone, canonical_standalone)
    if archive != canonical_archive:
        os.replace(archive, canonical_archive)
    retained = [canonical_standalone, canonical_archive]
    telemetry_candidates = sorted(root.rglob("storage-telemetry-v1.json"))
    if telemetry_candidates:
        canonical_telemetry = root / "storage-telemetry-v1.json"
        if canonical_telemetry in telemetry_candidates:
            telemetry = canonical_telemetry
        elif len(telemetry_candidates) == 1:
            telemetry = telemetry_candidates[0]
        else:
            raise ShippingError(f"Legacy backup has ambiguous storage telemetry: {root}")
        if telemetry != canonical_telemetry:
            os.replace(telemetry, canonical_telemetry)
        retained.append(canonical_telemetry)
    hashes = {path.name: sha256(path) for path in retained}
    atomic_write_json(root / "SHA256SUMS.json", hashes)
    result = BackupResult(
        path=str(root),
        standalone_database=str(canonical_standalone),
        schema_version=schema,
        quick_check=quick_check,
        foreign_key_violations=foreign_keys,
        table_counts=table_counts,
        hashes=hashes,
    )
    atomic_write_json(root / "backup-result.json", backup_to_json(result))
    for path in retained:
        path.chmod(0o600)
    root.chmod(0o700)
    validate_backup_result(result)
    raw = root / "raw"
    if raw.is_dir():
        shutil.rmtree(raw)
    validate_backup_result(result)
    os.utime(root, ns=original_times)
    return result


def print_plan(plan: RetentionPlan) -> None:
    print(
        f"keep={len(plan.keep)}\nretire={len(plan.retire)}\n"
        f"retireShippingRuns={len(plan.retire_shipping_runs)}\n"
        f"retireUnusable={len(plan.retire_unusable)}\n"
        f"manualReview={len(plan.manual_review)}\ninvalid={len(plan.invalid)}"
    )
    for label, paths in (
        ("KEEP", plan.keep),
        ("RETIRE", plan.retire),
        ("RETIRE-RUN", plan.retire_shipping_runs),
        ("RETIRE-UNUSABLE", plan.retire_unusable),
        ("MANUAL", plan.manual_review),
        ("INVALID", plan.invalid),
    ):
        for path in paths:
            print(f"{label}\t{path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Manifest-driven WHOOP backup retention")
    parser.add_argument("--backup-root", default=str(DEFAULT_BACKUP_ROOT))
    parser.add_argument("--state", default=str(DEFAULT_STATE_PATH))
    parser.add_argument("--keep-newest", type=int, default=2)
    parser.add_argument("--retention-days", type=int, default=7)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--purge-now",
        action="store_true",
        help="permanently remove only previously quarantined, recorded directories",
    )
    parser.add_argument(
        "--adopt-legacy",
        action="store_true",
        help="validate and compact legacy snapshots before planning retention",
    )
    parser.add_argument(
        "--retire-unusable",
        action="store_true",
        help="quarantine legacy directories that fail explicit adoption",
    )
    args = parser.parse_args()
    if args.keep_newest < 1 or args.retention_days < 1:
        raise SystemExit("Retention values must be positive integers.")
    if args.purge_now and not args.apply:
        raise SystemExit("--purge-now requires --apply.")
    backup_root = Path(args.backup_root).expanduser().resolve()
    state_path = Path(args.state).expanduser().resolve()
    unusable: list[Path] = []
    if args.retire_unusable and (not args.apply or not args.adopt_legacy):
        raise SystemExit("--retire-unusable requires --apply --adopt-legacy.")
    if args.adopt_legacy:
        if not args.apply:
            raise SystemExit("--adopt-legacy requires --apply because it rewrites snapshots.")
        protected = protected_backup_paths(state_path, backup_root)
        for candidate in sorted(backup_root.iterdir()):
            if not candidate.is_dir() or candidate.name in {"shipping-runs", RETIRED_DIRECTORY}:
                continue
            if candidate.resolve() in protected:
                print(f"PROTECTED\t{candidate}")
                continue
            if not (candidate / "raw").is_dir() and (candidate / "backup-result.json").is_file():
                continue
            try:
                adopt_legacy_backup(candidate)
                print(f"ADOPTED\t{candidate}")
            except (OSError, ShippingError) as error:
                print(f"UNADOPTED\t{candidate}\t{error}")
                unusable.append(candidate)
    plan = plan_retention(backup_root, state_path, keep_newest=args.keep_newest)
    if args.retire_unusable:
        if not plan.keep:
            raise SystemExit("Refusing unusable cleanup without a validated retained backup.")
        plan = replace(plan, retire_unusable=tuple(unusable))
    print_plan(plan)
    if args.apply:
        apply_retention(plan, backup_root)
        purged = purge_expired_retirements(
            backup_root,
            retention_days=0 if args.purge_now else args.retention_days,
        )
        print(f"status=applied\npurged={len(purged)}")
    else:
        print("status=dry-run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
