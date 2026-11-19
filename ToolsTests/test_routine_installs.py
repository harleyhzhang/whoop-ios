from __future__ import annotations

import json
import subprocess
from pathlib import Path
from types import SimpleNamespace
from typing import cast
from unittest.mock import patch

import phone_shipping
import phone_shipping_core as core
import phone_shipping_device as device_shipping
import phone_shipping_environment as environment
import pytest


def checkpoint(tmp_path: Path) -> dict[str, object]:
    root = tmp_path / "checkpoint"
    root.mkdir(mode=0o700)
    hashes = {}
    for name in ["sleep-standalone.sqlite3", "whoop-official-archive.sqlite3"]:
        path = root / name
        path.write_bytes(b"previously verified checkpoint")
        path.chmod(0o600)
        hashes[name] = "a" * 64
    core.atomic_write_json(root / "SHA256SUMS.json", hashes)
    return {
        "lastVerifiedBackup": {
            "path": str(root),
            "verifiedAt": "2020-01-01T00:00:00Z",
            "quickCheck": "ok",
            "foreignKeyViolations": 0,
            "schemaVersion": 12,
            "hashes": hashes,
        }
    }


def test_routine_checkpoint_check_does_not_read_growing_database(tmp_path: Path) -> None:
    state = checkpoint(tmp_path)
    # Deliberately not SQLite: the routine path must inspect fixed metadata,
    # not scan/hash the history. Deep validation remains a distinct operation.
    with (
        patch.object(core, "sha256", side_effect=AssertionError("full-file hash")),
        patch.object(core, "sqlite_checks", side_effect=AssertionError("full census")),
    ):
        assert (
            core.validate_recent_backup(state, maximum_age_days=None, verify_contents=False)
            == tmp_path / "checkpoint"
        )
    assert (
        core.object_dict(state["lastVerifiedBackup"], "checkpoint")["verifiedAt"]
        == "2020-01-01T00:00:00Z"
    )
    with pytest.raises(core.ShippingError, match="older than"):
        core.validate_recent_backup(state)


def test_routine_check_still_rejects_missing_checkpoint_bytes(tmp_path: Path) -> None:
    state = checkpoint(tmp_path)
    (tmp_path / "checkpoint/sleep-standalone.sqlite3").unlink()
    with pytest.raises(core.ShippingError, match="hash mismatch"):
        core.validate_recent_backup(state, maximum_age_days=None, verify_contents=False)


def test_routine_check_rejects_relabelled_or_escaped_manifest(tmp_path: Path) -> None:
    state = checkpoint(tmp_path)
    root = tmp_path / "checkpoint"
    core.atomic_write_json(root / "SHA256SUMS.json", {"../outside": "b" * 64})
    with pytest.raises(core.ShippingError, match="outside its root"):
        core.validate_recent_backup(state, maximum_age_days=None, verify_contents=False)
    core.atomic_write_json(root / "SHA256SUMS.json", {"sleep-standalone.sqlite3": "b" * 64})
    with pytest.raises(core.ShippingError, match="trusted install state"):
        core.validate_recent_backup(state, maximum_age_days=None, verify_contents=False)


def test_routine_state_does_not_advance_offphone_backup_date(tmp_path: Path) -> None:
    old = checkpoint(tmp_path)
    doctor = SimpleNamespace(
        device=SimpleNamespace(identifier="synthetic-device", udid="synthetic-udid")
    )
    app = core.AppInfo(core.BUNDLE_IDENTIFIER, "synthetic-container", "1.0", "2")
    state = phone_shipping.final_state(
        old, "a" * 40, "routine", cast(environment.DoctorResult, doctor), app, None, None, None
    )
    assert state["lastVerifiedBackup"] == old["lastVerifiedBackup"]
    assert "latestPostinstallBackup" not in state
    assert state["dataPreservationVerification"] == "in-place-same-storage-and-database-advance"


@pytest.mark.parametrize("deep", [False, True])
def test_only_deep_install_requests_full_storage_report(tmp_path: Path, deep: bool) -> None:
    class Runner(environment.CommandRunner):
        def __init__(self) -> None:
            self.arguments: list[str] = []

        def devicectl_json(
            self, arguments: list[str], scratch: Path, *, check: bool = True, timeout: int = 60
        ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
            self.arguments = arguments
            return {}, subprocess.CompletedProcess(arguments, 0, "", "")

    runner = Runner()
    device = core.Device("synthetic", "synthetic", "synthetic", "synthetic", "27", "synthetic", "")
    with (
        patch.object(device_shipping, "device_is_locked", return_value=False),
        patch.object(device_shipping, "process_payload", return_value={}),
        patch.object(device_shipping, "find_process_id", return_value=123),
        patch.object(device_shipping, "device_file_stamps", return_value={}),
        patch.object(device_shipping, "file_stamps_advanced", return_value=True),
    ):
        assert (
            device_shipping.launch_and_verify(
                runner,
                tmp_path,
                device,
                {},
                tmp_path / "manifest.json",
                force_storage_verification=deep,
            )
            == 123
        )
    if deep:
        index = runner.arguments.index("--environment-variables")
        assert json.loads(runner.arguments[index + 1]) == {"WHOOP_VERIFY_STORAGE": "1"}
        assert index < runner.arguments.index(core.BUNDLE_IDENTIFIER)
    else:
        assert "--environment-variables" not in runner.arguments
