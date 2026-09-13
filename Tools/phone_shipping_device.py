from __future__ import annotations

import time
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from phone_shipping_core import (
    BUNDLE_IDENTIFIER,
    BackupResult,
    DeploymentHealthReport,
    Device,
    FileStamp,
    ShippingError,
    atomic_write_json,
    backup_to_json,
    file_stamps_advanced,
    find_process_id,
    parse_file_stamps,
    parse_lock_state,
    validate_backup,
    validate_deployment_health_report,
)
from phone_shipping_environment import CommandRunner

# CoreDevice reports that a suspend signal was sent before the process and its
# SQLite connections are necessarily quiescent.  Starting a multi-gigabyte
# directory copy immediately can therefore capture the main database before a
# final WAL write.  A short settle interval produced coherent snapshots on the
# physical device where immediate copies did not.
BACKUP_SUSPEND_QUIESCE_SECONDS = 5
BACKUP_REQUIRED_FILES = ("sleep.sqlite3", "whoop-official-archive.sqlite3")
BACKUP_OPTIONAL_FILES = (
    "sleep.sqlite3-wal",
    "sleep.sqlite3-shm",
    "storage-telemetry-v1.json",
)


def wait_for_backup_quiescence() -> None:
    time.sleep(BACKUP_SUSPEND_QUIESCE_SECONDS)


class ResumeRequired(ShippingError):
    def __init__(self, status: str, message: str, manifest: Path | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.manifest = manifest


def process_payload(runner: CommandRunner, scratch: Path, device: Device) -> object:
    payload, _ = runner.devicectl_json(
        ["device", "info", "processes", "--device", device.identifier, "--timeout", "30"],
        scratch,
    )
    return payload if payload is not None else {}


def resume_or_relaunch_application(
    runner: CommandRunner, scratch: Path, device: Device, pid: int
) -> None:
    diagnostics: list[str] = []
    for _ in range(2):
        _, completed = runner.devicectl_json(
            [
                "device",
                "process",
                "resume",
                "--device",
                device.identifier,
                "--pid",
                str(pid),
                "--timeout",
                "30",
            ],
            scratch,
            check=False,
        )
        if completed.returncode == 0:
            return
        diagnostics.append(completed.stderr.strip() or completed.stdout.strip())
    _, launch = runner.devicectl_json(
        [
            "device",
            "process",
            "launch",
            "--device",
            device.identifier,
            "--terminate-existing",
            BUNDLE_IDENTIFIER,
            "--timeout",
            "60",
        ],
        scratch,
        check=False,
    )
    if launch.returncode != 0:
        diagnostics.append(launch.stderr.strip() or launch.stdout.strip())
        detail = "; ".join(item for item in diagnostics if item) or "no diagnostics"
        raise ShippingError(f"Could not resume or relaunch WHOOP after suspension: {detail}")


@contextmanager
def suspended_application(runner: CommandRunner, scratch: Path, device: Device) -> Iterator[None]:
    pid = find_process_id(process_payload(runner, scratch, device))
    suspended = False
    if pid is not None:
        runner.devicectl_json(
            [
                "device",
                "process",
                "suspend",
                "--device",
                device.identifier,
                "--pid",
                str(pid),
                "--timeout",
                "30",
            ],
            scratch,
        )
        suspended = True
        wait_for_backup_quiescence()
    try:
        yield
    finally:
        if suspended and pid is not None:
            resume_or_relaunch_application(runner, scratch, device, pid)


def device_file_stamps(
    runner: CommandRunner, scratch: Path, device: Device
) -> dict[str, FileStamp]:
    payload, _ = runner.devicectl_json(
        [
            "device",
            "info",
            "files",
            "--device",
            device.identifier,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            BUNDLE_IDENTIFIER,
            "--subdirectory",
            "Library/Application Support/Sleep",
            "--no-recurse",
            "--timeout",
            "60",
        ],
        scratch,
    )
    if payload is None:
        raise ShippingError("CoreDevice returned no application file metadata.")
    stamps = parse_file_stamps(payload)
    if not stamps:
        raise ShippingError("CoreDevice did not report sleep.sqlite3 or its WAL metadata.")
    return stamps


def prepare_launch_baseline(
    runner: CommandRunner, scratch: Path, device: Device
) -> dict[str, FileStamp]:
    pid = find_process_id(process_payload(runner, scratch, device))
    if pid is not None:
        runner.devicectl_json(
            [
                "device",
                "process",
                "terminate",
                "--device",
                device.identifier,
                "--pid",
                str(pid),
                "--timeout",
                "30",
            ],
            scratch,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if find_process_id(process_payload(runner, scratch, device)) is None:
                break
            time.sleep(1)
        else:
            raise ShippingError("WHOOP did not terminate before the launch baseline was captured.")
    return device_file_stamps(runner, scratch, device)


def take_backup(
    runner: CommandRunner,
    scratch: Path,
    device: Device,
    backup_root: Path,
    label: str,
    commit: str,
    expected_schema: int,
    exact_schema: bool,
) -> BackupResult:
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    commit_label = commit[:12]
    destination = backup_root / f"{label}-{commit_label}-{timestamp}"
    raw_root = destination / "raw"
    destination.mkdir(parents=True, mode=0o700)
    raw_root.mkdir(mode=0o700)
    for directory in (backup_root, destination, raw_root):
        directory.chmod(0o700)
    try:
        with suspended_application(runner, scratch, device):
            for name in BACKUP_REQUIRED_FILES:
                copy_app_file(runner, scratch, device, name, raw_root / name, required=True)
            for name in BACKUP_OPTIONAL_FILES:
                copy_app_file(runner, scratch, device, name, raw_root / name, required=False)
        result = validate_backup(raw_root, expected_schema, exact_schema)
        atomic_write_json(destination / "backup-result.json", backup_to_json(result))
        return result
    except Exception:
        quarantine = destination.with_name(destination.name + "-INCOMPLETE")
        if destination.exists() and not quarantine.exists():
            destination.rename(quarantine)
        raise


def copy_app_file(
    runner: CommandRunner,
    scratch: Path,
    device: Device,
    name: str,
    destination: Path,
    *,
    required: bool,
) -> None:
    _, completed = runner.devicectl_json(
        [
            "device",
            "copy",
            "from",
            "--device",
            device.identifier,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            BUNDLE_IDENTIFIER,
            "--source",
            f"Library/Application Support/Sleep/{name}",
            "--destination",
            str(destination),
            "--timeout",
            "1800",
        ],
        scratch,
        check=required,
        timeout=1810,
    )
    if required and (completed.returncode != 0 or not destination.is_file()):
        raise ShippingError(f"CoreDevice did not copy required backup file {name}.")


def fetch_deployment_health_report(
    runner: CommandRunner,
    scratch: Path,
    device: Device,
    expected_commit: str,
    expected_schema: int,
    expected_archive_hash: str,
    timeout_seconds: int = 120,
) -> DeploymentHealthReport:
    destination = scratch / "deployment-health-v1.json"
    deadline = time.monotonic() + timeout_seconds
    last_error: ShippingError | None = None
    while time.monotonic() < deadline:
        destination.unlink(missing_ok=True)
        copy_app_file(
            runner,
            scratch,
            device,
            "deployment-health-v1.json",
            destination,
            required=False,
        )
        if destination.is_file():
            try:
                return validate_deployment_health_report(
                    destination,
                    expected_commit,
                    expected_schema,
                    expected_archive_hash,
                )
            except ShippingError as error:
                last_error = error
        time.sleep(2)
    detail = f" Last report error: {last_error}" if last_error is not None else ""
    raise ShippingError(
        "The installed app did not publish a valid deployment health report before timeout."
        + detail
    )


def install_app(runner: CommandRunner, scratch: Path, device: Device, app_path: Path) -> None:
    runner.devicectl_json(
        [
            "device",
            "install",
            "app",
            "--device",
            device.identifier,
            str(app_path),
            "--timeout",
            "300",
        ],
        scratch,
        timeout=310,
    )


def device_is_locked(runner: CommandRunner, scratch: Path, device: Device) -> bool | None:
    payload, _ = runner.devicectl_json(
        ["device", "info", "lockState", "--device", device.identifier, "--timeout", "30"],
        scratch,
        check=False,
    )
    return parse_lock_state(payload) if payload is not None else None


def launch_and_verify(
    runner: CommandRunner,
    scratch: Path,
    device: Device,
    before_stamps: dict[str, FileStamp],
    manifest_path: Path,
) -> int:
    if device_is_locked(runner, scratch, device) is True:
        raise ResumeRequired(
            "needs-unlock",
            "The app is installed safely, but the iPhone must be unlocked before launch.",
            manifest_path,
        )
    _, launch = runner.devicectl_json(
        [
            "device",
            "process",
            "launch",
            "--device",
            device.identifier,
            "--terminate-existing",
            BUNDLE_IDENTIFIER,
            "--timeout",
            "60",
        ],
        scratch,
        check=False,
    )
    if launch.returncode != 0:
        diagnostics = f"{launch.stdout}\n{launch.stderr}".lower()
        if "lock" in diagnostics or device_is_locked(runner, scratch, device) is True:
            raise ResumeRequired(
                "needs-unlock",
                "The app is installed safely, but iOS denied launch while the phone is locked.",
                manifest_path,
            )
        raise ResumeRequired(
            "needs-verification",
            "The app was installed, but launch failed; rerun the printed resume command.",
            manifest_path,
        )
    deadline = time.monotonic() + 90
    latest_stamps: dict[str, FileStamp] = {}
    pid: int | None = None
    while time.monotonic() < deadline:
        try:
            pid = find_process_id(process_payload(runner, scratch, device))
            latest_stamps = device_file_stamps(runner, scratch, device)
        except ShippingError:
            time.sleep(5)
            continue
        if pid is not None and file_stamps_advanced(before_stamps, latest_stamps):
            return pid
        time.sleep(5)
    raise ResumeRequired(
        "needs-verification",
        "The app was installed and launched, but process/database advancement was not proven.",
        manifest_path,
    )
