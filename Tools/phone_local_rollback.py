"""Explicit local-only coverage option; never represents a fresh off-phone backup."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

from phone_backup_afc import AppContainer
from phone_shipping_core import (
    DeploymentHealthReport,
    Device,
    IntegrityError,
    ShippingError,
    load_json,
    object_dict,
    required_int,
    required_string,
    sha256,
    validate_recent_backup,
)

POLICY = "on-device-migration"
FULL_POLICY = "full-offphone"
ARCHIVE = "motion-calibration.json"


def copy_small_archive(device: Device, destination: Path) -> str | None:
    with AppContainer(device) as container:
        before = container.stat(ARCHIVE, required=False)
        if before is None:
            return None
        if int(before["st_size"]) > 20 * 1024**2:
            raise ShippingError("Calibration journal exceeds the bounded local-rollback export.")
        container.copy(ARCHIVE, destination, before)
        if container.stat(ARCHIVE, required=True) != before:
            raise ShippingError("Calibration journal changed during its small export.")
    journal = object_dict(load_json(destination, ARCHIVE), ARCHIVE)
    sessions = journal.get("sessions")
    if journal.get("schemaVersion") != 1 or not isinstance(sessions, list):
        raise IntegrityError("Calibration journal is invalid.")
    if journal.get("pendingSessionID") is not None or any(
        not isinstance(session, dict) or session.get("phase") != "complete" for session in sessions
    ):
        raise ShippingError("Sensor cleanup is pending; do not retire recording controls yet.")
    return sha256(destination)


def prepare(
    device: Device,
    state: dict[str, object],
    backup_root: Path,
    commit: str,
    target_schema: int,
    available_device_bytes: int | None,
) -> dict[str, object]:
    previous = validate_recent_backup(state)
    trusted = object_dict(state.get("lastVerifiedBackup"), "last verified off-phone backup")
    source_schema = required_int(trusted, "schemaVersion", "last verified off-phone backup")
    if not 0 < source_schema < target_schema:
        raise ShippingError("On-device migration requires a known older-schema off-phone rollback.")
    rollback_path = f"migration-backups/sleep-v{source_schema}-before-v{target_schema}.sqlite3"
    with AppContainer(device) as container:
        if container.stat(rollback_path, required=False) is not None:
            raise ShippingError(
                "A target migration rollback already exists; cannot prove a fresh capture."
            )
        source = container.stat("sleep.sqlite3", required=True)
        assert source is not None
        required_bytes = int(source["st_size"]) + 1024**3
    if available_device_bytes is None or available_device_bytes < required_bytes:
        raise ShippingError(
            "Not enough verified phone space for a complete local migration rollback."
        )
    root = (
        backup_root / f"local-rollback-{commit[:12]}-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}"
    )
    root.mkdir(mode=0o700)
    digest = copy_small_archive(device, root / ARCHIVE)
    return {
        "offphoneBackup": str(previous),
        "offphoneVerifiedAt": required_string(trusted, "verifiedAt", "off-phone backup"),
        "sourceSchema": source_schema,
        "targetSchema": target_schema,
        "rollbackPath": rollback_path,
        "capsulePath": str(root),
        "calibrationSHA256": digest,
        "coverage": "Newest observations have on-phone rollback only until a later off-phone/replica refresh.",
    }


def validate_receipt(
    evidence: dict[str, object],
    report: DeploymentHealthReport,
    started_at: str,
) -> dict[str, object]:
    source = required_int(evidence, "sourceSchema", "local rollback evidence")
    target = required_int(evidence, "targetSchema", "local rollback evidence")
    expected = required_string(evidence, "rollbackPath", "local rollback evidence")
    matches = [item for item in report.migration_rollbacks if item.get("relativePath") == expected]
    if len(matches) != 1:
        raise IntegrityError("Installed app did not attest the expected local migration rollback.")
    receipt = matches[0]
    if (
        receipt.get("schemaVersion") != source
        or report.schema_version != target
        or receipt.get("quickCheck") != "ok"
    ):
        raise IntegrityError("Local migration rollback schema/integrity attestation is invalid.")
    if required_int(receipt, "fileBytes", "rollback receipt") < 512:
        raise IntegrityError("Local migration rollback is empty.")
    try:
        modified = datetime.fromisoformat(
            required_string(receipt, "modifiedAt", "rollback receipt").replace("Z", "+00:00")
        )
        began = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        if modified.timestamp() + 2 < began.timestamp():
            raise IntegrityError("Local migration rollback predates this install transaction.")
    except ValueError as error:
        raise IntegrityError("Invalid local rollback time.") from error
    counts = object_dict(receipt.get("tableCounts"), "rollback table counts")
    if not counts:
        raise IntegrityError("Local rollback has no preserved-table inventory.")
    for table in counts:
        before = required_int(counts, table, "rollback table counts")
        if before < 0 or report.table_counts.get(table, -1) < before:
            raise IntegrityError(
                f"Installed database lost rows relative to local rollback: {table}"
            )
    return receipt


def finish(device: Device, evidence: dict[str, object]) -> None:
    root = Path(required_string(evidence, "capsulePath", "local rollback evidence"))
    destination = root / "postinstall-motion-calibration.json"
    destination.unlink(missing_ok=True)
    after = copy_small_archive(device, destination)
    if after != evidence.get("calibrationSHA256"):
        raise IntegrityError("Installed app changed or lost the saved calibration journal.")
    # A small retained report records the explicit protection difference.
    (root / "coverage.json").write_text(json.dumps(evidence, indent=2) + "\n")
    (root / "coverage.json").chmod(0o600)
