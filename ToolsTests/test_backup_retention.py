from __future__ import annotations

import os
import sqlite3
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

import backup_retention
import phone_shipping_core as core


def make_backup(root: Path, name: str, schema: int, modified: datetime) -> Path:
    destination = root / name
    destination.mkdir(mode=0o700)
    database = destination / "sleep-standalone.sqlite3"
    archive = destination / "whoop-official-archive.sqlite3"
    for path, version in ((database, schema), (archive, 1)):
        connection = sqlite3.connect(path)
        connection.execute(f"PRAGMA user_version = {version}")
        connection.close()
        path.chmod(0o600)
    hashes = {path.name: core.sha256(path) for path in (database, archive)}
    core.atomic_write_json(destination / "SHA256SUMS.json", hashes)
    result = core.BackupResult(
        path=str(destination),
        standalone_database=str(database),
        schema_version=schema,
        quick_check="ok",
        foreign_key_violations=0,
        table_counts={},
        hashes=hashes,
    )
    core.atomic_write_json(destination / "backup-result.json", core.backup_to_json(result))
    timestamp = modified.timestamp()
    os.utime(destination, (timestamp, timestamp))
    return destination


def test_retention_keeps_state_newest_schema_and_month_then_purges(tmp_path: Path) -> None:
    root = tmp_path / "backups"
    root.mkdir()
    now = datetime(2026, 9, 13, tzinfo=UTC)
    oldest = make_backup(root, "old", 9, now - timedelta(days=70))
    monthly = make_backup(root, "monthly", 10, now - timedelta(days=40))
    protected = make_backup(root, "protected", 10, now - timedelta(days=3))
    newest = make_backup(root, "newest", 10, now - timedelta(days=1))
    manual = root / "legacy-no-manifest"
    manual.mkdir()
    state_path = tmp_path / "state.json"
    core.atomic_write_json(
        state_path,
        {
            "lastVerifiedBackup": {
                "path": str(protected),
                "quickCheck": "ok",
                "foreignKeyViolations": 0,
                "schemaVersion": 10,
                "hashes": {},
                "verifiedAt": now.isoformat(),
            }
        },
    )

    plan = backup_retention.plan_retention(root, state_path, keep_newest=1, now=now)

    assert set(plan.keep) == {oldest, monthly, protected, newest}
    assert plan.retire == ()
    assert plan.retire_shipping_runs == ()
    assert plan.retire_unusable == ()
    assert plan.manual_review == (manual,)

    redundant = make_backup(root, "redundant", 10, now - timedelta(days=2))
    plan = backup_retention.plan_retention(root, state_path, keep_newest=1, now=now)
    assert plan.retire == (redundant,)
    backup_retention.apply_retention(plan, root, now=now)
    retired = root / backup_retention.RETIRED_DIRECTORY / redundant.name
    assert retired.is_dir()
    assert not redundant.exists()
    assert backup_retention.purge_expired_retirements(root, now=now) == ()
    assert backup_retention.purge_expired_retirements(
        root,
        now=now + timedelta(days=8),
    ) == (retired,)
    assert not retired.exists()


def test_retention_refuses_unverified_and_outside_state_paths(tmp_path: Path) -> None:
    root = tmp_path / "backups"
    root.mkdir()
    broken = root / "broken"
    broken.mkdir()
    core.atomic_write_json(broken / "backup-result.json", {})
    state = tmp_path / "state.json"
    outside = tmp_path / "canonical-whoop-data"
    outside.mkdir()
    core.atomic_write_json(state, {"lastVerifiedBackup": {"path": str(outside)}})

    plan = backup_retention.plan_retention(root, state)

    assert plan.retire == ()
    assert plan.invalid == (broken,)
    assert outside.is_dir()

    backup_retention.apply_retention(replace(plan, retire_unusable=(broken,)), root)
    assert not broken.exists()
    assert (root / backup_retention.RETIRED_DIRECTORY / "unusable--broken").is_dir()


def test_retention_keeps_resumable_and_two_latest_completed_shipping_runs(
    tmp_path: Path,
) -> None:
    root = tmp_path / "backups"
    runs = root / "shipping-runs"
    runs.mkdir(parents=True)
    for index, phase in enumerate(("complete", "complete", "complete", "needs-verification")):
        run = runs / str(index)
        run.mkdir()
        core.atomic_write_json(run / "manifest.json", {"phase": phase})
        os.utime(run, (index, index))

    plan = backup_retention.plan_retention(root, tmp_path / "missing-state.json")

    assert plan.retire_shipping_runs == (runs / "0",)


def test_legacy_adoption_compacts_raw_tree_only_after_validation(tmp_path: Path) -> None:
    root = tmp_path / "legacy"
    raw = root / "raw"
    raw.mkdir(parents=True)
    standalone = root / "sleep-standalone.sqlite3"
    archive = raw / "whoop-official-archive.sqlite3"
    for path, version in ((standalone, 10), (archive, 1)):
        connection = sqlite3.connect(path)
        connection.execute(f"PRAGMA user_version = {version}")
        connection.close()
    (raw / "migration-backups").mkdir()
    (raw / "migration-backups/duplicate.sqlite3").write_bytes(b"large duplicate")

    result = backup_retention.adopt_legacy_backup(root)

    assert result.schema_version == 10
    assert not raw.exists()
    assert set(result.hashes) == {
        "sleep-standalone.sqlite3",
        "whoop-official-archive.sqlite3",
    }
    core.validate_backup_result(result)


def test_build_cache_pruning_keeps_active_and_newest(tmp_path: Path) -> None:
    root = tmp_path / "cache"
    root.mkdir()
    caches = [root / name for name in ("old", "recent", "active")]
    for index, cache in enumerate(caches):
        cache.mkdir()
        os.utime(cache, (index, index))

    purged = backup_retention.prune_build_caches(root, caches[2], keep=2)

    assert purged == (caches[0],)
    assert caches[1].is_dir()
    assert caches[2].is_dir()
