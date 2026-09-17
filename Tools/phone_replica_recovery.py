#!/usr/bin/env python3
"""Transactionally stage the latest Convex phone replica onto the physical iPhone."""

from __future__ import annotations

import argparse
import sqlite3
import tempfile
import time
from pathlib import Path

from phone_replica import DEFAULT_SITE_URL, restore
from phone_shipping import DEFAULT_BACKUP_ROOT, DEFAULT_PRIVATE_ROOT, DEFAULT_STATE_PATH
from phone_shipping_core import (
    BUNDLE_IDENTIFIER,
    PRESERVED_TABLES,
    ShippingError,
    atomic_write_json,
    backup_to_json,
)
from phone_shipping_device import (
    fetch_deployment_health_report,
    suspended_application,
    take_backup,
)
from phone_shipping_environment import (
    CommandRunner,
    doctor,
    iso_now,
    project_schema_version,
    read_state,
    repository_root,
)


def table_counts(database: Path) -> dict[str, int]:
    uri = f"file:{database}?mode=ro&immutable=1"
    with sqlite3.connect(uri, uri=True) as connection:
        check = connection.execute("PRAGMA quick_check").fetchone()
        if check != ("ok",):
            raise ShippingError(f"Recovered database failed SQLite quick_check: {check}")
        violations = connection.execute("PRAGMA foreign_key_check").fetchall()
        if violations:
            raise ShippingError("Recovered database has foreign-key violations")
        tables = {
            str(row[0])
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        return {
            table: int(connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])
            for table in PRESERVED_TABLES
            if table in tables
        }


def stage_file(
    runner: CommandRunner,
    scratch: Path,
    device_identifier: str,
    database: Path,
) -> None:
    runner.devicectl_json(
        [
            "device",
            "copy",
            "to",
            "--device",
            device_identifier,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            BUNDLE_IDENTIFIER,
            "--source",
            str(database),
            "--destination",
            "Library/Application Support/Sleep/replica-restore.sqlite3",
            "--timeout",
            "1800",
        ],
        scratch,
        timeout=1810,
    )


def launch(runner: CommandRunner, scratch: Path, device_identifier: str) -> None:
    runner.devicectl_json(
        [
            "device",
            "process",
            "launch",
            "--device",
            device_identifier,
            "--terminate-existing",
            BUNDLE_IDENTIFIER,
            "--timeout",
            "60",
        ],
        scratch,
    )


def recover(args: argparse.Namespace) -> None:
    if not args.apply:
        raise ShippingError("Phone recovery requires --apply after reviewing the selected paths")
    repo_root = repository_root()
    private_root = Path(args.private_root).expanduser().resolve()
    state_path = Path(args.state).expanduser().resolve()
    backup_root = Path(args.backup_root).expanduser().resolve()
    runner = CommandRunner()
    expected_schema = project_schema_version(repo_root)
    state = read_state(state_path)
    installed_commit = state.get("installedCommit")
    if not isinstance(installed_commit, str) or len(installed_commit) != 40:
        raise ShippingError("Install state does not contain the exact installed commit")

    with tempfile.TemporaryDirectory(prefix="whoop-phone-recovery-") as temporary:
        scratch = Path(temporary)
        restore_root = scratch / "convex-restore"
        restore(restore_root, args.site_url)
        recovered_database = restore_root / "sleep.sqlite3"
        recovered_counts = table_counts(recovered_database)
        doctor_result = doctor(
            runner,
            repo_root,
            private_root,
            state_path,
            backup_root,
            "migration",
            args.device,
            scratch,
        )
        prebackup = take_backup(
            runner,
            scratch,
            doctor_result.device,
            backup_root,
            "pre-convex-recovery",
            installed_commit,
            expected_schema,
            True,
        )
        with suspended_application(runner, scratch, doctor_result.device):
            stage_file(runner, scratch, doctor_result.device.identifier, recovered_database)
        launch(runner, scratch, doctor_result.device.identifier)
        fetch_deployment_health_report(
            runner,
            scratch,
            doctor_result.device,
            installed_commit,
            expected_schema,
            doctor_result.assets.hashes["whoop-official-archive.sqlite3"],
            timeout_seconds=180,
        )
        postbackup = take_backup(
            runner,
            scratch,
            doctor_result.device,
            backup_root,
            "post-convex-recovery",
            installed_commit,
            expected_schema,
            True,
        )
        for table, recovered_count in recovered_counts.items():
            post_count = postbackup.table_counts.get(table)
            if post_count is None or post_count < recovered_count:
                raise ShippingError(
                    f"Phone recovery lost rows in {table}: {recovered_count} -> {post_count}"
                )
        record = (
            backup_root / f"convex-recovery-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}.json"
        )
        atomic_write_json(
            record,
            {
                "completedAt": iso_now(),
                "deviceIdentifier": doctor_result.device.identifier,
                "installedCommit": installed_commit,
                "postbackup": backup_to_json(postbackup),
                "prebackup": backup_to_json(prebackup),
                "recoveredCounts": recovered_counts,
                "schemaVersion": expected_schema,
            },
        )
        print(f"status=recovered\nrecord={record}\npostbackup={postbackup.path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--site-url", default=DEFAULT_SITE_URL)
    parser.add_argument("--private-root", default=str(DEFAULT_PRIVATE_ROOT))
    parser.add_argument("--state", default=str(DEFAULT_STATE_PATH))
    parser.add_argument("--backup-root", default=str(DEFAULT_BACKUP_ROOT))
    parser.add_argument("--device")
    args = parser.parse_args()
    try:
        recover(args)
    except ShippingError as error:
        print(f"error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
