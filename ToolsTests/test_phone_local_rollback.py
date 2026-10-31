from __future__ import annotations

import copy
import json
from argparse import Namespace
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from typing import ClassVar, cast

import phone_local_rollback as local
import phone_shipping
import phone_shipping_core as core
import phone_shipping_environment as environment
import pytest


def device() -> core.Device:
    return core.Device("CORE-1", "UDID-1", "IP", "iPhone", "27.0", "24A1", "")


def receipt() -> dict[str, object]:
    return {
        "relativePath": "migration-backups/sleep-v11-before-v12.sqlite3",
        "schemaVersion": 11,
        "quickCheck": "ok",
        "fileBytes": 8192,
        "modifiedAt": "2026-10-31T18:00:01Z",
        "tableCounts": {"whoop_raw_packet": 10},
    }


def evidence() -> dict[str, object]:
    return {
        "sourceSchema": 11,
        "targetSchema": 12,
        "rollbackPath": "migration-backups/sleep-v11-before-v12.sqlite3",
    }


def report() -> core.DeploymentHealthReport:
    return core.DeploymentHealthReport(
        "a" * 40,
        "2026-10-31T18:01:00Z",
        12,
        "ok",
        0,
        {"whoop_raw_packet": 11},
        "b" * 64,
        (receipt(),),
    )


@pytest.mark.parametrize(
    "mutation",
    [
        {"schemaVersion": 10},
        {"quickCheck": "bad"},
        {"fileBytes": 0},
        {"modifiedAt": "2026-10-30T18:00:00Z"},
        {"modifiedAt": "invalid"},
        {"relativePath": "other.sqlite3"},
        {"tableCounts": {}},
        {"tableCounts": {"whoop_raw_packet": 12}},
        {"tableCounts": {"whoop_raw_packet": -1}},
    ],
)
def test_receipt_rejects_stale_invalid_or_lost_rows(mutation: dict[str, object]) -> None:
    bad = {**receipt(), **mutation}
    with pytest.raises(core.ShippingError):
        local.validate_receipt(
            evidence(), replace(report(), migration_rollbacks=(bad,)), "2026-10-31T18:00:00Z"
        )


def test_receipt_requires_one_fresh_expected_snapshot() -> None:
    assert local.validate_receipt(evidence(), report(), "2026-10-31T18:00:00Z") == receipt()
    for values in [(), (receipt(), receipt())]:
        with pytest.raises(core.IntegrityError):
            local.validate_receipt(
                evidence(), replace(report(), migration_rollbacks=values), "2026-10-31T18:00:00Z"
            )


class Container:
    archive: ClassVar[dict[str, object]] = {"schemaVersion": 1, "sessions": []}
    existing_rollback = False

    def __init__(self, _device: object):
        pass

    def __enter__(self) -> Container:
        return self

    def __exit__(self, *_args: object) -> None:
        pass

    def stat(self, name: str, *, required: bool) -> dict[str, str] | None:
        del required
        if name.startswith("migration-backups"):
            return {"st_size": "8192"} if self.existing_rollback else None
        return {"st_size": "8192"}

    def copy(self, _name: str, destination: Path, _metadata: object) -> None:
        destination.write_text(json.dumps(self.archive))


@pytest.mark.parametrize("pending", [True, False])
def test_archive_cleanup_must_be_complete(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, pending: bool
) -> None:
    archive: dict[str, object] = {
        "schemaVersion": 1,
        "sessions": [{"phase": "recording" if pending else "complete"}],
    }
    monkeypatch.setattr(Container, "archive", archive)
    monkeypatch.setattr(local, "AppContainer", Container)
    if pending:
        with pytest.raises(core.ShippingError, match="cleanup"):
            local.copy_small_archive(device(), tmp_path / "archive.json")
    else:
        assert local.copy_small_archive(device(), tmp_path / "archive.json") is not None


def test_prepare_requires_space_and_no_previous_target_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(local, "AppContainer", Container)
    monkeypatch.setattr(local, "validate_recent_backup", lambda _state: tmp_path)
    state: dict[str, object] = {
        "lastVerifiedBackup": {"schemaVersion": 11, "verifiedAt": "2026-10-31T03:57:58Z"}
    }
    with pytest.raises(core.ShippingError, match="space"):
        local.prepare(device(), state, tmp_path, "a" * 40, 12, 0)
    monkeypatch.setattr(Container, "existing_rollback", True)
    with pytest.raises(core.ShippingError, match="already exists"):
        local.prepare(device(), state, tmp_path, "a" * 40, 12, 20 * 1024**3)


def test_prepare_keeps_offphone_coverage_time_explicit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(local, "AppContainer", Container)
    monkeypatch.setattr(local, "validate_recent_backup", lambda _state: tmp_path)
    state: dict[str, object] = {
        "lastVerifiedBackup": {"schemaVersion": 11, "verifiedAt": "2026-10-31T03:57:58Z"}
    }
    before = copy.deepcopy(state)
    proof = local.prepare(device(), state, tmp_path, "a" * 40, 12, 20 * 1024**3)
    assert proof["offphoneVerifiedAt"] == "2026-10-31T03:57:58Z"
    assert "on-phone rollback only" in str(proof["coverage"])
    assert state == before


def test_resume_cannot_switch_original_backup_policy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    commit = "a" * 40
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "commit": commit,
                "privateRoot": str(tmp_path),
                "statePath": str(tmp_path),
                "backupRoot": str(tmp_path),
                "phase": "needs-verification",
                "mode": "migration",
                "backupPolicy": local.POLICY,
            }
        )
    )
    monkeypatch.setattr(phone_shipping, "assert_exact_merged_commit", lambda *_args: commit)
    args = Namespace(commit=commit, resume=str(manifest), backup_policy=local.FULL_POLICY)
    with pytest.raises(core.ShippingError, match="policy differs"):
        phone_shipping._run_ship_locked(
            args,
            phone_shipping.CommandRunner(verbose=False),
            tmp_path,
            tmp_path,
            tmp_path,
            tmp_path,
        )


def test_finish_preserves_exact_journal(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(local, "AppContainer", Container)
    digest = local.copy_small_archive(device(), tmp_path / local.ARCHIVE)
    proof: dict[str, object] = {"capsulePath": str(tmp_path), "calibrationSHA256": digest}
    local.finish(device(), proof)
    monkeypatch.setattr(
        Container, "archive", {"schemaVersion": 1, "sessions": [{"phase": "complete"}]}
    )
    with pytest.raises(core.IntegrityError, match="changed or lost"):
        local.finish(device(), proof)


def test_policy_is_opt_in_and_local_route_never_takes_full_copy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    args = phone_shipping.build_parser().parse_args(["ship", "--commit", "a" * 40])
    assert args.backup_policy is None
    app = core.AppInfo(core.BUNDLE_IDENTIFIER, "container", "1", "2")
    doctor = SimpleNamespace(
        device=device(),
        assets=SimpleNamespace(hashes={"whoop-official-archive.sqlite3": "b" * 64}),
    )
    monkeypatch.setattr(phone_shipping, "installed_app", lambda *_args: app)
    monkeypatch.setattr(phone_shipping, "launch_and_verify", lambda *_args: 123)
    monkeypatch.setattr(phone_shipping, "fetch_deployment_health_report", lambda *_args: report())
    monkeypatch.setattr(phone_shipping, "project_schema_version", lambda *_args: 12)
    monkeypatch.setattr(phone_shipping, "read_state", lambda *_args: {})
    monkeypatch.setattr(
        phone_shipping,
        "final_state",
        lambda *_args: {"lastVerifiedBackup": {"path": "old-offphone"}},
    )
    monkeypatch.setattr(phone_shipping, "plan_retention", lambda *_args: [])
    monkeypatch.setattr(phone_shipping, "apply_retention", lambda *_args: None)
    monkeypatch.setattr(phone_shipping, "purge_expired_retirements", lambda *_args: None)
    monkeypatch.setattr(local, "finish", lambda *_args: None)

    def forbidden(*_args: object) -> None:
        raise AssertionError("No full or suspended copy in explicitly selected local route")

    monkeypatch.setattr(phone_shipping, "take_backup", forbidden)
    manifest: dict[str, object] = {
        "commit": "a" * 40,
        "mode": "migration",
        "version": "1",
        "build": "2",
        "beforeFileStamps": {},
        "backupPolicy": local.POLICY,
        "localRollback": copy.deepcopy(evidence()),
        "createdAt": "2026-10-31T18:00:00Z",
    }
    state = tmp_path / "state.json"
    phone_shipping.complete_after_install(
        phone_shipping.CommandRunner(verbose=False),
        tmp_path,
        tmp_path,
        state,
        tmp_path,
        tmp_path,
        tmp_path / "manifest.json",
        manifest,
        cast(environment.DoctorResult, doctor),
    )
    saved = json.loads(state.read_text())
    assert saved["lastVerifiedBackup"] == {"path": "old-offphone"}
    assert saved["backupPolicy"] == local.POLICY
    assert "on-phone" in saved["dataPreservationVerification"]
    assert manifest["phase"] == "complete"
