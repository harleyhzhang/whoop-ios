from __future__ import annotations

import json
import os
import plistlib
import sqlite3
import subprocess
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

import phone_shipping
import phone_shipping_core as core
import phone_shipping_device as device_shipping
import phone_shipping_environment as environment
import pytest


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value))


def tree(feature: int = 0) -> dict[str, object]:
    return {
        "childrenLeft": [1, -1, -1],
        "childrenRight": [2, -1, -1],
        "features": [feature, -2, -2],
        "thresholds": [0.5, -2.0, -2.0],
        "values": [0.0, 1.0, 2.0],
    }


def svr(feature_count: int) -> dict[str, object]:
    return {
        "means": [0.0] * feature_count,
        "scales": [1.0] * feature_count,
        "supportVectors": [[0.0] * feature_count],
        "dualCoefficients": [1.0],
        "intercept": 0.0,
        "gamma": 0.1,
    }


def boosted(feature_count: int) -> dict[str, object]:
    return {
        "initialPrediction": 0.0,
        "learningRate": 0.1,
        "trees": [tree(feature_count - 1)],
    }


def create_database(path: Path, schema: int, counts: dict[str, int] | None = None) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute(f"PRAGMA user_version = {schema}")
        for table_name, count in (counts or {}).items():
            connection.execute(f'CREATE TABLE "{table_name}" (value INTEGER PRIMARY KEY)')
            connection.executemany(
                f'INSERT INTO "{table_name}" (value) VALUES (?)',
                ((index,) for index in range(count)),
            )
        connection.commit()
    finally:
        connection.close()


def create_private_assets(root: Path) -> None:
    root.mkdir()
    write_json(
        root / "whoop-strain-model.json",
        {
            "calibration": {
                "version": "synthetic-v1",
                "exponent": 2.0,
                "loadScale": 1.0,
                "scoreScale": 4.0,
            },
            "maximumHeartRate": 190.0,
        },
    )
    write_json(
        root / "whoop-history.json",
        [{"dateKey": "2026-01-01", "sleepDurationMinutes": 480, "source": "synthetic"}],
    )
    write_json(
        root / "whoop-score-model.json",
        {
            "version": "synthetic-sleep-v1",
            "featureVersion": core.SLEEP_FEATURE_VERSION,
            "featureCount": core.SLEEP_FEATURE_COUNT,
            "directWeight": 0.5,
            "extraTreesWeight": 0.5,
            "trees": [tree()],
            "svr": svr(core.SLEEP_FEATURE_COUNT),
            "needModel": boosted(core.SLEEP_FEATURE_COUNT),
            "consistencyModel": boosted(core.SLEEP_FEATURE_COUNT),
            "pillarSVR": svr(3),
        },
    )
    write_json(
        root / "whoop-recovery-model.json",
        {
            "version": "synthetic-recovery-v1",
            "featureVersion": core.RECOVERY_FEATURE_VERSION,
            "featureCount": core.RECOVERY_FEATURE_COUNT,
            "boostedWeight": 0.5,
            "imputerMedians": [0.0] * core.RECOVERY_FEATURE_COUNT,
            "boostedModel": boosted(core.RECOVERY_FEATURE_COUNT),
            "ridgeModel": {
                "imputerMedians": [0.0] * core.RECOVERY_FEATURE_COUNT,
                "means": [0.0] * core.RECOVERY_FEATURE_COUNT,
                "scales": [1.0] * core.RECOVERY_FEATURE_COUNT,
                "coefficients": [0.0] * core.RECOVERY_FEATURE_COUNT,
                "intercept": 50.0,
            },
        },
    )
    archive = root / "whoop-official-archive.sqlite3"
    create_database(archive, 1)
    write_json(
        root / "whoop-official-metrics.json",
        {
            "formatVersion": 1,
            "sourceDatabaseSHA256": core.sha256(archive),
            "daily": [{"dateKey": "2026-01-01"}],
        },
    )


def test_private_assets_validate_versions_dimensions_and_archive_hash(tmp_path: Path) -> None:
    root = tmp_path / "assets"
    create_private_assets(root)

    manifest = core.validate_private_assets(root)

    assert manifest.sleep_model_version == "synthetic-sleep-v1"
    assert manifest.recovery_model_version == "synthetic-recovery-v1"
    assert manifest.archive_schema_version == 1
    assert set(manifest.hashes) == set(core.PRIVATE_ASSET_NAMES)


def test_private_assets_reject_wrong_feature_contract_and_archive(tmp_path: Path) -> None:
    root = tmp_path / "assets"
    create_private_assets(root)
    sleep_model_path = root / "whoop-score-model.json"
    sleep_model = core.object_dict(core.load_json(sleep_model_path, "test model"), "test model")
    sleep_model["featureVersion"] = "wrong"
    write_json(sleep_model_path, sleep_model)

    with pytest.raises(core.ShippingError, match="featureVersion"):
        core.validate_private_assets(root)

    count_root = tmp_path / "count-assets"
    create_private_assets(count_root)
    count_model_path = count_root / "whoop-score-model.json"
    count_model = core.object_dict(core.load_json(count_model_path, "test model"), "test model")
    count_model["featureCount"] = core.SLEEP_FEATURE_COUNT + 1
    write_json(count_model_path, count_model)
    with pytest.raises(core.ShippingError, match="featureCount"):
        core.validate_private_assets(count_root)

    create_private_assets(tmp_path / "second-assets")
    archive = tmp_path / "second-assets/whoop-official-archive.sqlite3"
    with archive.open("ab") as output:
        output.write(b"tampered")
    with pytest.raises(core.ShippingError, match="archive hash"):
        core.validate_private_assets(tmp_path / "second-assets")


def device_payload(*, head_state: str = "connected", include_second: bool = False) -> object:
    devices: list[object] = [
        {
            "identifier": "CORE-1",
            "deviceProperties": {
                "developerModeStatus": "enabled",
                "name": "Primary iPhone",
                "osVersionNumber": "27.0",
                "osBuildUpdate": "24A1",
            },
            "hardwareProperties": {
                "deviceType": "iPhone",
                "reality": "physical",
                "udid": "UDID-1",
                "serialNumber": "SERIAL-1",
                "marketingName": "iPhone 17 Pro Max",
            },
            "connectionProperties": {
                "pairingState": "paired",
                "tunnelState": head_state,
                "lastConnectionDate": "2026-09-12T20:00:00Z",
                "transportType": "localNetwork",
            },
        }
    ]
    if include_second:
        devices.append(
            {
                "identifier": "CORE-2",
                "deviceProperties": {
                    "developerModeStatus": "enabled",
                    "name": "Second iPhone",
                },
                "hardwareProperties": {
                    "deviceType": "iPhone",
                    "reality": "physical",
                    "udid": "UDID-2",
                },
                "connectionProperties": {
                    "pairingState": "paired",
                    "tunnelState": "connected",
                    "lastConnectionDate": "2026-09-11T20:00:00Z",
                },
            }
        )
    return {"result": {"devices": devices}}


def test_device_selection_fails_closed_for_unavailable_or_ambiguous_devices() -> None:
    assert core.choose_device(device_payload()).udid == "UDID-1"
    assert core.choose_device(device_payload()).transport == "localNetwork"
    assert core.choose_device(device_payload(include_second=True), "UDID-2").identifier == "CORE-2"

    with pytest.raises(core.ShippingError, match="No paired"):
        core.choose_device(device_payload(head_state="unavailable"))
    with pytest.raises(core.ShippingError, match="Multiple iPhones"):
        core.choose_device(device_payload(include_second=True))


def test_coredevice_app_process_file_and_lock_parsers() -> None:
    container = "FC5EE6A0-684C-4909-AEA3-FFF637A92839"
    app = core.parse_app_info(
        {
            "result": {
                "apps": [
                    {
                        "bundleIdentifier": core.BUNDLE_IDENTIFIER,
                        "bundleVersion": "13",
                        "shortVersion": "0.7.1",
                        "dataContainer": f"file:///private/var/mobile/Containers/Data/{container}/",
                    }
                ]
            }
        }
    )
    assert app.data_container_uuid == container
    assert app.version == "0.7.1"
    assert app.build == "13"
    app_without_exposed_container = core.parse_app_info(
        {
            "result": {
                "apps": [
                    {
                        "bundleIdentifier": core.BUNDLE_IDENTIFIER,
                        "bundleVersion": "13",
                        "version": "0.7.1",
                        "url": "file:///private/var/containers/Bundle/Application/"
                        "AABB8339-88AB-4DED-B1C5-1A80433B6C7C/WHOOP.app/",
                    }
                ]
            }
        }
    )
    assert app_without_exposed_container.data_container_uuid == ""

    process = {"result": {"runningProcesses": [{"name": "WHOOP", "pid": 1234}]}}
    assert core.find_process_id(process) == 1234

    before = core.parse_file_stamps(
        {
            "result": {
                "files": [
                    {
                        "path": "Library/Application Support/Sleep/sleep.sqlite3-wal",
                        "modificationDate": "2026-09-12T20:00:00Z",
                        "size": 100,
                    }
                ]
            }
        }
    )
    after = {
        key: core.FileStamp(path=value.path, modified_at=value.modified_at, size=101)
        for key, value in before.items()
    }
    assert core.file_stamps_advanced(before, after)
    assert core.file_stamps_advanced(
        before,
        {
            **before,
            "sleep.sqlite3-wal": core.FileStamp("sleep.sqlite3-wal", "now", 1),
        },
    )
    actual_coredevice_shape = core.parse_file_stamps(
        {
            "result": {
                "files": [
                    {
                        "metadata": {
                            "lastModDate": "2026-09-12T20:01:00Z",
                            "size": 321,
                        },
                        "name": "sleep.sqlite3-wal",
                        "relativePath": "Library/Application Support/Sleep/sleep.sqlite3-wal",
                    }
                ]
            }
        }
    )
    assert actual_coredevice_shape[
        "Library/Application Support/Sleep/sleep.sqlite3-wal"
    ] == core.FileStamp(
        "Library/Application Support/Sleep/sleep.sqlite3-wal",
        "2026-09-12T20:01:00Z",
        321,
    )
    assert core.parse_lock_state({"result": {"lockState": "locked"}}) is True


def test_profile_requires_bundle_team_device_and_future_expiration() -> None:
    raw = plistlib.dumps(
        {
            "Name": "Synthetic WHOOP Profile",
            "UUID": "PROFILE-1",
            "ExpirationDate": datetime.now(UTC).replace(tzinfo=None) + timedelta(days=30),
            "TeamIdentifier": ["TEAM123"],
            "ProvisionedDevices": ["UDID-1"],
            "Entitlements": {"application-identifier": f"TEAM123.{core.BUNDLE_IDENTIFIER}"},
            "DeveloperCertificates": [b"synthetic certificate"],
        }
    )

    profile = core.parse_profile(raw, core.BUNDLE_IDENTIFIER, "UDID-1")

    assert profile is not None
    assert profile.name == "Synthetic WHOOP Profile"
    assert core.parse_profile(raw, core.BUNDLE_IDENTIFIER, "OTHER-UDID") is None


def test_backup_validation_hashes_sqlite_and_detects_data_loss(tmp_path: Path) -> None:
    raw = tmp_path / "preinstall/raw"
    raw.mkdir(parents=True)
    counts = {"daily_health_metric": 3, "whoop_daily_recovery_metric": 2}
    create_database(raw / "sleep.sqlite3", 10, counts)
    create_database(raw / "whoop-official-archive.sqlite3", 1)
    write_json(
        raw / "storage-telemetry-v1.json",
        {"formatVersion": 1, "snapshots": [], "pendingIngestion": {}},
    )

    preinstall = core.validate_backup(raw, expected_schema=10, exact_schema=True)
    assert preinstall.quick_check == "ok"
    assert preinstall.foreign_key_violations == 0
    assert preinstall.table_counts == counts
    assert "storage-telemetry-v1.json" in preinstall.hashes
    assert not raw.exists()
    assert not any("migration-backups" in name for name in preinstall.hashes)
    assert (tmp_path / "preinstall/SHA256SUMS.json").is_file()

    postinstall = core.BackupResult(
        path="postinstall",
        standalone_database="postinstall/sleep.sqlite3",
        schema_version=10,
        quick_check="ok",
        foreign_key_violations=0,
        table_counts={"daily_health_metric": 2, "whoop_daily_recovery_metric": 2},
        hashes={},
    )
    with pytest.raises(core.ShippingError, match="decreased"):
        core.assert_preserved(preinstall, postinstall)

    core.validate_backup_result(preinstall)
    with Path(preinstall.standalone_database).open("ab") as output:
        output.write(b"tampered")
    with pytest.raises(core.ShippingError, match="hash mismatch"):
        core.validate_backup_result(preinstall)


def test_backup_validation_rejects_malformed_storage_telemetry(tmp_path: Path) -> None:
    raw = tmp_path / "preinstall/raw"
    raw.mkdir(parents=True)
    create_database(raw / "sleep.sqlite3", 10)
    create_database(raw / "whoop-official-archive.sqlite3", 1)
    write_json(raw / "storage-telemetry-v1.json", {"formatVersion": 2, "snapshots": []})

    with pytest.raises(core.ShippingError, match="storage telemetry"):
        core.validate_backup(raw, expected_schema=10, exact_schema=True)


def test_deployment_health_report_is_commit_bound_and_detects_row_loss(tmp_path: Path) -> None:
    report_path = tmp_path / "deployment-health-v1.json"
    commit = "a" * 40
    archive_hash = "b" * 64
    write_json(
        report_path,
        {
            "formatVersion": 1,
            "sourceCommit": commit,
            "generatedAt": "2026-09-13T12:00:00Z",
            "schemaVersion": 10,
            "quickCheck": "ok",
            "foreignKeyViolations": 0,
            "tableCounts": {"whoop_raw_packet": 2},
            "officialArchiveSHA256": archive_hash,
        },
    )

    report = core.validate_deployment_health_report(report_path, commit, 10, archive_hash)
    before = core.BackupResult(
        str(tmp_path),
        str(tmp_path / "sleep.sqlite3"),
        10,
        "ok",
        0,
        {"whoop_raw_packet": 3},
        {},
    )
    with pytest.raises(core.IntegrityError, match="count decreased"):
        core.assert_health_preserved(before, report)
    with pytest.raises(core.IntegrityError, match="installed commit"):
        core.validate_deployment_health_report(report_path, "c" * 40, 10, archive_hash)


def test_raw_evidence_replacement_is_detected_even_when_count_is_unchanged(
    tmp_path: Path,
) -> None:
    before_path = tmp_path / "before.sqlite3"
    after_path = tmp_path / "after.sqlite3"
    for path, payload in ((before_path, b"original"), (after_path, b"replacement")):
        connection = sqlite3.connect(path)
        try:
            connection.execute(
                "CREATE TABLE whoop_raw_packet (id TEXT PRIMARY KEY, payload BLOB NOT NULL)"
            )
            connection.execute(
                "INSERT INTO whoop_raw_packet(id, payload) VALUES ('same-id', ?)",
                (payload,),
            )
            connection.commit()
        finally:
            connection.close()
    before = core.BackupResult(
        str(tmp_path), str(before_path), 10, "ok", 0, {"whoop_raw_packet": 1}, {}
    )
    after = core.BackupResult(
        str(tmp_path), str(after_path), 10, "ok", 0, {"whoop_raw_packet": 1}, {}
    )

    with pytest.raises(core.IntegrityError, match="changed preinstall evidence"):
        core.assert_database_rows_preserved(before, after)


def test_atomic_state_and_recent_backup_are_revalidated(tmp_path: Path) -> None:
    backup_root = tmp_path / "postinstall"
    backup_root.mkdir(mode=0o700)
    standalone = backup_root / "sleep-standalone.sqlite3"
    create_database(standalone, 10)
    archive = backup_root / "whoop-official-archive.sqlite3"
    create_database(archive, 1)
    standalone.chmod(0o600)
    archive.chmod(0o600)
    hashes = {
        "sleep-standalone.sqlite3": core.sha256(standalone),
        "whoop-official-archive.sqlite3": core.sha256(archive),
    }
    core.atomic_write_json(
        backup_root / "SHA256SUMS.json",
        hashes,
    )
    state: dict[str, object] = {
        "lastFullBackup": {
            "preinstall": str(tmp_path / "preinstall"),
            "postinstall": str(backup_root),
            "quickCheck": "ok",
            "foreignKeyViolations": 0,
            "schemaVersion": 10,
            "hashes": hashes,
            "verifiedAt": datetime.now(UTC).isoformat(),
        }
    }
    state_path = tmp_path / "private/state.json"

    core.atomic_write_json(state_path, state)

    assert core.validate_recent_full_backup(state) == backup_root
    assert oct(os.stat(state_path).st_mode & 0o777) == "0o600"
    assert core.load_json(state_path, "state") == state

    backup_root.chmod(0o755)
    with pytest.raises(core.ShippingError, match="readable by another user"):
        core.validate_recent_full_backup(state)
    backup_root.chmod(0o700)

    standalone.unlink()
    create_database(standalone, 10, {"daily_health_metric": 1})
    replacement_hashes = {**hashes, "sleep-standalone.sqlite3": core.sha256(standalone)}
    core.atomic_write_json(backup_root / "SHA256SUMS.json", replacement_hashes)
    standalone.chmod(0o600)
    with pytest.raises(core.ShippingError, match="trusted install state"):
        core.validate_recent_full_backup(state)


def git(arguments: list[str], cwd: Path) -> str:
    git_environment = environment.isolated_git_environment()
    return subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        env=git_environment,
    ).stdout.strip()


def test_exact_commit_must_be_clean_checked_out_and_merged(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("GIT_DIR", "/tmp/inherited-hook-git-dir")
    monkeypatch.setenv("GIT_WORK_TREE", "/tmp/inherited-hook-work-tree")
    fixture_root = Path(tempfile.mkdtemp(prefix="merged-commit-", dir=tmp_path))
    remote = fixture_root / "remote.git"
    worktree = fixture_root / "worktree"
    git(["init", "--bare", str(remote)], fixture_root)
    git(["init", "-b", "main", str(worktree)], fixture_root)
    git(["config", "user.name", "WHOOP Shipping Test"], worktree)
    git(["config", "user.email", "whoop-shipping@example.invalid"], worktree)
    (worktree / "README.md").write_text("trusted\n")
    git(["add", "README.md"], worktree)
    git(["commit", "-m", "trusted"], worktree)
    git(["remote", "add", "origin", str(remote)], worktree)
    git(["push", "-u", "origin", "main"], worktree)
    commit = git(["rev-parse", "HEAD"], worktree)
    runner = phone_shipping.CommandRunner(verbose=False)

    assert phone_shipping.assert_exact_merged_commit(runner, worktree, commit) == commit

    (worktree / "README.md").write_text("dirty\n")
    with pytest.raises(core.ShippingError, match="dirty"):
        phone_shipping.assert_exact_merged_commit(runner, worktree, commit)


def test_real_schema_constant_and_commit_bound_build_number() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    assert environment.project_schema_version(repo_root) == 10
    assert environment.shipping_build_number("a" * 40) == str(int("a" * 12, 16))


class StorageRunner(phone_shipping.CommandRunner):
    def __init__(self, returncode: int = 0, output: str = "97051308032\n") -> None:
        super().__init__(verbose=False)
        self.arguments: list[str] = []
        self.returncode = returncode
        self.output = output

    def run(
        self,
        arguments: list[str],
        *,
        cwd: Path | None = None,
        environment: dict[str, str] | None = None,
        check: bool = True,
        timeout: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        del cwd, environment, timeout
        self.arguments = arguments
        assert check is False
        return subprocess.CompletedProcess(arguments, self.returncode, self.output, "unavailable")


def test_phone_storage_uses_direct_network_disk_usage_query(tmp_path: Path) -> None:
    runner = StorageRunner()
    device = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")

    available = environment.device_available_storage(runner, tmp_path, device)

    assert available == 97_051_308_032
    assert runner.arguments == [
        "ideviceinfo",
        "--network",
        "--udid",
        "UDID-1",
        "--domain",
        "com.apple.disk_usage",
        "--key",
        "AmountDataAvailable",
    ]


def test_phone_storage_is_optional_when_legacy_network_query_is_unavailable(
    tmp_path: Path,
) -> None:
    runner = StorageRunner(returncode=255, output="")
    device = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "localNetwork")

    assert environment.device_available_storage(runner, tmp_path, device) is None


class RecordingRunner(phone_shipping.CommandRunner):
    def __init__(self) -> None:
        super().__init__(verbose=False)
        self.device_calls: list[list[str]] = []

    def devicectl_json(
        self,
        arguments: list[str],
        scratch: Path,
        *,
        check: bool = True,
        timeout: int = 60,
    ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
        del scratch, check, timeout
        self.device_calls.append(arguments)
        payload: object = {}
        if "processes" in arguments:
            payload = {"result": {"runningProcesses": [{"name": "WHOOP", "pid": 4321}]}}
        return payload, subprocess.CompletedProcess(arguments, 0, "", "")


class BackupCopyRunner(RecordingRunner):
    def devicectl_json(
        self,
        arguments: list[str],
        scratch: Path,
        *,
        check: bool = True,
        timeout: int = 60,
    ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
        if arguments[:3] == ["device", "copy", "from"]:
            self.device_calls.append(arguments)
            source = arguments[arguments.index("--source") + 1]
            destination = Path(arguments[arguments.index("--destination") + 1])
            name = Path(source).name
            if name == "sleep.sqlite3":
                create_database(destination, 10, {"whoop_raw_packet": 2})
            elif name == "whoop-official-archive.sqlite3":
                create_database(destination, 1)
            elif name == "storage-telemetry-v1.json":
                write_json(destination, {"formatVersion": 1, "snapshots": []})
            return {}, subprocess.CompletedProcess(arguments, 0, "", "")
        return super().devicectl_json(arguments, scratch, check=check, timeout=timeout)


def test_device_backup_copies_only_allowlisted_files_and_compacts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = BackupCopyRunner()
    selected = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")
    monkeypatch.setattr(device_shipping, "wait_for_backup_quiescence", lambda: None)

    backup = device_shipping.take_backup(
        runner,
        tmp_path / "scratch",
        selected,
        tmp_path / "backups",
        "preinstall",
        "a" * 40,
        10,
        True,
    )

    copied_sources = [
        call[call.index("--source") + 1]
        for call in runner.device_calls
        if call[:3] == ["device", "copy", "from"]
    ]
    assert copied_sources == [
        f"Library/Application Support/Sleep/{name}"
        for name in (*device_shipping.BACKUP_REQUIRED_FILES, *device_shipping.BACKUP_OPTIONAL_FILES)
    ]
    assert Path(backup.path, "sleep-standalone.sqlite3").is_file()
    assert Path(backup.path, "whoop-official-archive.sqlite3").is_file()
    assert not Path(backup.path, "raw").exists()


def test_suspension_quiesces_then_always_resumes_after_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = RecordingRunner()
    device = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")
    waits: list[bool] = []
    monkeypatch.setattr(device_shipping, "wait_for_backup_quiescence", lambda: waits.append(True))

    with (
        pytest.raises(RuntimeError, match="copy failed"),
        phone_shipping.suspended_application(runner, tmp_path, device),
    ):
        raise RuntimeError("copy failed")

    actions = [call[2] for call in runner.device_calls if call[:2] == ["device", "process"]]
    assert actions == ["suspend", "resume"]
    assert waits == [True]


class ResumeFailureRunner(RecordingRunner):
    def devicectl_json(
        self,
        arguments: list[str],
        scratch: Path,
        *,
        check: bool = True,
        timeout: int = 60,
    ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
        payload, completed = super().devicectl_json(
            arguments, scratch, check=check, timeout=timeout
        )
        if arguments[:3] == ["device", "process", "resume"]:
            return payload, subprocess.CompletedProcess(arguments, 1, "", "resume failed")
        return payload, completed


def test_suspension_retries_resume_then_relaunches(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = ResumeFailureRunner()
    device = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")
    monkeypatch.setattr(device_shipping, "wait_for_backup_quiescence", lambda: None)

    with phone_shipping.suspended_application(runner, tmp_path, device):
        pass

    actions = [call[2] for call in runner.device_calls if call[:2] == ["device", "process"]]
    assert actions == ["suspend", "resume", "resume", "launch"]


class BaselineRunner(RecordingRunner):
    def __init__(self) -> None:
        super().__init__()
        self.process_reads = 0

    def devicectl_json(
        self,
        arguments: list[str],
        scratch: Path,
        *,
        check: bool = True,
        timeout: int = 60,
    ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
        self.device_calls.append(arguments)
        payload: object = {}
        if "processes" in arguments:
            self.process_reads += 1
            running = [{"name": "WHOOP", "pid": 4321}] if self.process_reads == 1 else []
            payload = {"result": {"runningProcesses": running}}
        elif "files" in arguments:
            payload = {
                "result": {
                    "files": [
                        {
                            "path": "Library/Application Support/Sleep/sleep.sqlite3",
                            "modificationDate": "2026-09-12T20:00:00Z",
                            "size": 100,
                        }
                    ]
                }
            }
        return payload, subprocess.CompletedProcess(arguments, 0, "", "")


def test_launch_baseline_terminates_existing_process_before_reading_files(
    tmp_path: Path,
) -> None:
    runner = BaselineRunner()
    device = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")

    stamps = device_shipping.prepare_launch_baseline(runner, tmp_path, device)

    assert stamps
    terminate_index = next(
        index for index, call in enumerate(runner.device_calls) if "terminate" in call
    )
    files_index = next(index for index, call in enumerate(runner.device_calls) if "files" in call)
    assert terminate_index < files_index


class BaselineFailureRunner(RecordingRunner):
    def devicectl_json(
        self,
        arguments: list[str],
        scratch: Path,
        *,
        check: bool = True,
        timeout: int = 60,
    ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
        del scratch, check, timeout
        self.device_calls.append(arguments)
        payload: object = {"result": {"runningProcesses": []}}
        return payload, subprocess.CompletedProcess(arguments, 0, "", "")


def test_postinstall_baseline_failure_is_resumable(tmp_path: Path) -> None:
    runner = BaselineFailureRunner()
    device = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")
    doctor_result = environment.DoctorResult(
        device=device,
        app=core.AppInfo(core.BUNDLE_IDENTIFIER, "CONTAINER", "1", "1"),
        assets=core.AssetManifest({}, "sleep", "recovery", 1),
        signing_profile=core.SigningProfile(
            "profile", "uuid", "team", datetime.now(UTC) + timedelta(days=1), ("hash",)
        ),
        development_team="team",
        xcode_version="Xcode",
        iphoneos_sdk="27.0",
        available_bytes=20 * 1024**3,
        device_available_bytes=20 * 1024**3,
    )
    manifest_path = tmp_path / "manifest.json"
    manifest: dict[str, object] = {"phase": "installing"}

    with pytest.raises(device_shipping.ResumeRequired) as captured:
        phone_shipping.transition_after_install(
            runner, tmp_path, doctor_result, manifest_path, manifest
        )

    assert captured.value.status == "needs-verification"
    persisted = core.object_dict(core.load_json(manifest_path, "manifest"), "manifest")
    assert persisted["phase"] == "installing"
    assert "lastBaselineError" in persisted


def test_install_timeout_is_converted_to_resumable_manifest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def time_out(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        del args, kwargs
        raise subprocess.TimeoutExpired(["xcrun", "devicectl"], 310)

    monkeypatch.setattr(subprocess, "run", time_out)
    runner = phone_shipping.CommandRunner(verbose=False)
    device = core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")
    doctor_result = environment.DoctorResult(
        device=device,
        app=core.AppInfo(core.BUNDLE_IDENTIFIER, "CONTAINER", "1", "1"),
        assets=core.AssetManifest({}, "sleep", "recovery", 1),
        signing_profile=core.SigningProfile(
            "profile", "uuid", "team", datetime.now(UTC) + timedelta(days=1), ("hash",)
        ),
        development_team="team",
        xcode_version="Xcode",
        iphoneos_sdk="27.0",
        available_bytes=20 * 1024**3,
        device_available_bytes=20 * 1024**3,
    )
    manifest_path = tmp_path / "manifest.json"
    staged_app = tmp_path / "WHOOP.app"
    staged_app.mkdir()
    manifest: dict[str, object] = {"phase": "ready-to-install"}

    with pytest.raises(device_shipping.ResumeRequired) as captured:
        phone_shipping.install_and_transition(
            runner,
            tmp_path,
            doctor_result,
            staged_app,
            manifest_path,
            manifest,
        )

    assert captured.value.status == "needs-verification"
    persisted = core.object_dict(core.load_json(manifest_path, "manifest"), "manifest")
    assert persisted["phase"] == "installing"
    assert "timed out" in str(persisted["lastInstallError"])


def test_shipping_lock_rejects_concurrent_invocation(tmp_path: Path) -> None:
    lock_path = tmp_path / "ship.lock"
    with (
        core.exclusive_file_lock(lock_path),
        pytest.raises(core.ShippingError, match="exclusive lock"),
        core.exclusive_file_lock(lock_path),
    ):
        pass
    assert lock_path.stat().st_mode & 0o777 == 0o600
