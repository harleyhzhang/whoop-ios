from __future__ import annotations

import argparse
import shlex
import shutil
import sys
import tempfile
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path

from phone_shipping_core import (
    BUNDLE_IDENTIFIER,
    AppInfo,
    BackupResult,
    DeviceUnavailable,
    FileStamp,
    IntegrityError,
    ShippingError,
    assert_database_rows_preserved,
    assert_preserved,
    atomic_write_json,
    backup_to_json,
    exclusive_file_lock,
    load_json,
    object_dict,
    required_int,
    required_string,
    sha256,
    validate_backup_result,
    validate_private_assets,
)
from phone_shipping_device import (
    ResumeRequired,
    install_app,
    launch_and_verify,
    prepare_launch_baseline,
    take_backup,
)
from phone_shipping_device import (
    suspended_application as suspended_application,
)
from phone_shipping_environment import (
    BuildResult,
    DoctorResult,
    build_app,
    classify_install,
    doctor,
    installed_app,
    iso_now,
    project_schema_version,
    read_state,
    repository_root,
    validate_staged_app,
)
from phone_shipping_environment import (
    CommandRunner as CommandRunner,
)
from phone_shipping_environment import (
    assert_exact_merged_commit as assert_exact_merged_commit,
)

DEFAULT_PRIVATE_ROOT = Path.home() / "Documents/personal/data/whoop/app-seeds"
DEFAULT_STATE_PATH = Path.home() / "Documents/personal/data/whoop/device-install-state.json"
DEFAULT_BACKUP_ROOT = Path.home() / "Documents/personal/data/whoop/device-backups"
RESUME_EXIT_CODE = 75


def manifest_base(
    commit: str,
    mode: str,
    doctor_result: DoctorResult,
    build: BuildResult,
    before_stamps: dict[str, FileStamp],
    preinstall: BackupResult | None,
    private_root: Path,
    state_path: Path,
    backup_root: Path,
    staged_app_path: Path,
) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "phase": "ready-to-install",
        "commit": commit,
        "mode": mode,
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "device": asdict(doctor_result.device),
        "dataContainerUUIDBefore": doctor_result.app.data_container_uuid,
        "version": build.version,
        "build": build.build,
        "beforeFileStamps": {key: asdict(value) for key, value in before_stamps.items()},
        "preinstallBackup": backup_to_json(preinstall) if preinstall is not None else None,
        "privateRoot": str(private_root),
        "statePath": str(state_path),
        "backupRoot": str(backup_root),
        "stagedAppPath": str(staged_app_path),
        "assetHashes": doctor_result.assets.hashes,
        "createdAt": iso_now(),
    }


def stamps_from_manifest(value: object) -> dict[str, FileStamp]:
    mapping = object_dict(value, "shipping manifest.beforeFileStamps")
    result: dict[str, FileStamp] = {}
    for key, raw_stamp in mapping.items():
        stamp = object_dict(raw_stamp, f"shipping manifest.beforeFileStamps.{key}")
        result[key] = FileStamp(
            path=required_string(stamp, "path", "shipping file stamp"),
            modified_at=str(stamp.get("modified_at", "")),
            size=required_int(stamp, "size", "shipping file stamp"),
        )
    return result


def backup_from_manifest(value: object) -> BackupResult:
    backup = object_dict(value, "shipping manifest.preinstallBackup")
    table_counts_value = object_dict(backup.get("table_counts"), "backup table counts")
    hashes_value = object_dict(backup.get("hashes"), "backup hashes")
    return BackupResult(
        path=required_string(backup, "path", "preinstall backup"),
        standalone_database=required_string(backup, "standalone_database", "preinstall backup"),
        schema_version=required_int(backup, "schema_version", "preinstall backup"),
        quick_check=required_string(backup, "quick_check", "preinstall backup"),
        foreign_key_violations=required_int(backup, "foreign_key_violations", "preinstall backup"),
        table_counts={
            key: required_int(table_counts_value, key, "backup table counts")
            for key in table_counts_value
        },
        hashes={key: required_string(hashes_value, key, "backup hashes") for key in hashes_value},
    )


def final_state(
    old_state: dict[str, object],
    commit: str,
    mode: str,
    doctor_result: DoctorResult,
    app: AppInfo,
    preinstall: BackupResult | None,
    postinstall: BackupResult | None,
) -> dict[str, object]:
    timestamp = iso_now()
    state = dict(old_state)
    state.update(
        {
            "bundleIdentifier": BUNDLE_IDENTIFIER,
            "dataContainerUUID": app.data_container_uuid,
            "deviceIdentifier": doctor_result.device.identifier,
            "deviceUDID": doctor_result.device.udid,
            "installedAt": timestamp,
            "installedBuild": app.build,
            "installedCommit": commit,
            "installedVersion": app.version,
            "verificationMode": mode,
            "verifiedAt": timestamp,
        }
    )
    if preinstall is not None and postinstall is not None:
        state["latestPreinstallBackup"] = {
            "path": preinstall.path,
            "quickCheck": preinstall.quick_check,
            "foreignKeyViolations": preinstall.foreign_key_violations,
            "schemaVersion": preinstall.schema_version,
            "verifiedAt": timestamp,
        }
        state["latestPostinstallBackup"] = {
            "path": postinstall.path,
            "quickCheck": postinstall.quick_check,
            "foreignKeyViolations": postinstall.foreign_key_violations,
            "schemaVersion": postinstall.schema_version,
            "hashes": postinstall.hashes,
            "verifiedAt": timestamp,
        }
        state["lastFullBackup"] = {
            "preinstall": preinstall.path,
            "postinstall": postinstall.path,
            "quickCheck": "ok",
            "foreignKeyViolations": 0,
            "schemaVersion": postinstall.schema_version,
            "hashes": postinstall.hashes,
            "verifiedAt": timestamp,
        }
    return state


def complete_after_install(
    runner: CommandRunner,
    repo_root: Path,
    private_root: Path,
    state_path: Path,
    backup_root: Path,
    scratch: Path,
    manifest_path: Path,
    manifest: dict[str, object],
    doctor_result: DoctorResult,
) -> None:
    commit = required_string(manifest, "commit", "shipping manifest")
    mode = required_string(manifest, "mode", "shipping manifest")
    before_stamps = stamps_from_manifest(manifest.get("beforeFileStamps"))
    app = installed_app(runner, scratch, doctor_result.device)
    expected_container = required_string(manifest, "dataContainerUUIDBefore", "shipping manifest")
    if app.data_container_uuid != expected_container:
        raise IntegrityError(
            f"Data container changed from {expected_container} to {app.data_container_uuid}; "
            "install state was not updated."
        )
    if app.version != str(manifest.get("version", "")) or app.build != str(
        manifest.get("build", "")
    ):
        raise IntegrityError(
            "Installed app version/build does not match the commit-bound shipping manifest."
        )
    pid = launch_and_verify(runner, scratch, doctor_result.device, before_stamps, manifest_path)
    preinstall: BackupResult | None = None
    postinstall: BackupResult | None = None
    if mode == "full":
        preinstall = backup_from_manifest(manifest.get("preinstallBackup"))
        validate_backup_result(preinstall)
        postinstall = take_backup(
            runner,
            scratch,
            doctor_result.device,
            backup_root,
            "postinstall",
            commit,
            project_schema_version(repo_root),
            True,
        )
        assert_preserved(preinstall, postinstall)
        assert_database_rows_preserved(preinstall, postinstall)
        installed_sidecar_candidates = list(
            Path(postinstall.path).rglob("whoop-official-archive.sqlite3")
        )
        expected_sidecar_hash = doctor_result.assets.hashes["whoop-official-archive.sqlite3"]
        if (
            len(installed_sidecar_candidates) != 1
            or sha256(installed_sidecar_candidates[0]) != expected_sidecar_hash
        ):
            raise IntegrityError("Installed official archive does not match the validated source.")
    state = final_state(
        read_state(state_path),
        commit,
        mode,
        doctor_result,
        app,
        preinstall,
        postinstall,
    )
    atomic_write_json(state_path, state)
    manifest["phase"] = "complete"
    manifest["completedAt"] = iso_now()
    manifest["processIdentifier"] = pid
    if postinstall is not None:
        manifest["postinstallBackup"] = backup_to_json(postinstall)
    atomic_write_json(manifest_path, manifest)
    print(f"status=installed\nmode={mode}\ncommit={commit}\nprocess={pid}")
    print(f"dataContainerUUID={app.data_container_uuid}\nstate={state_path}")


def complete_or_request_resume(
    runner: CommandRunner,
    repo_root: Path,
    private_root: Path,
    state_path: Path,
    backup_root: Path,
    scratch: Path,
    manifest_path: Path,
    manifest: dict[str, object],
    doctor_result: DoctorResult,
) -> None:
    try:
        complete_after_install(
            runner,
            repo_root,
            private_root,
            state_path,
            backup_root,
            scratch,
            manifest_path,
            manifest,
            doctor_result,
        )
    except (ResumeRequired, IntegrityError):
        raise
    except ShippingError as error:
        manifest["phase"] = "needs-verification"
        manifest["lastVerificationError"] = str(error)
        atomic_write_json(manifest_path, manifest)
        raise ResumeRequired(
            "needs-verification",
            f"The app remains installed in place, but verification must resume: {error}",
            manifest_path,
        ) from error


def transition_after_install(
    runner: CommandRunner,
    scratch: Path,
    doctor_result: DoctorResult,
    manifest_path: Path,
    manifest: dict[str, object],
) -> None:
    try:
        before_stamps = prepare_launch_baseline(runner, scratch, doctor_result.device)
    except ShippingError as error:
        manifest["phase"] = "installing"
        manifest["lastBaselineError"] = str(error)
        atomic_write_json(manifest_path, manifest)
        raise ResumeRequired(
            "needs-verification",
            "The app is installed, but its launch baseline could not be captured; "
            "rerun the printed resume command.",
            manifest_path,
        ) from error
    manifest["beforeFileStamps"] = {key: asdict(value) for key, value in before_stamps.items()}
    manifest["phase"] = "installed-awaiting-launch"
    manifest["installedAt"] = iso_now()
    manifest.pop("lastBaselineError", None)
    atomic_write_json(manifest_path, manifest)


def install_and_transition(
    runner: CommandRunner,
    scratch: Path,
    doctor_result: DoctorResult,
    staged_app_path: Path,
    manifest_path: Path,
    manifest: dict[str, object],
) -> None:
    manifest["phase"] = "installing"
    atomic_write_json(manifest_path, manifest)
    try:
        install_app(runner, scratch, doctor_result.device, staged_app_path)
    except ShippingError as error:
        manifest["lastInstallError"] = str(error)
        atomic_write_json(manifest_path, manifest)
        raise ResumeRequired(
            "needs-verification",
            "The install outcome is indeterminate; rerun the printed resume command.",
            manifest_path,
        ) from error
    manifest.pop("lastInstallError", None)
    transition_after_install(runner, scratch, doctor_result, manifest_path, manifest)


def _run_ship_locked(
    args: argparse.Namespace,
    runner: CommandRunner,
    repo_root: Path,
    private_root: Path,
    state_path: Path,
    backup_root: Path,
) -> None:
    commit = assert_exact_merged_commit(runner, repo_root, args.commit)
    with tempfile.TemporaryDirectory(prefix="whoop-phone-shipping.") as scratch_name:
        scratch = Path(scratch_name)
        if args.resume:
            manifest_path = Path(args.resume).expanduser().resolve()
            manifest = object_dict(
                load_json(manifest_path, "shipping manifest"), "shipping manifest"
            )
            if manifest.get("commit") != commit:
                raise ShippingError("The resume manifest belongs to a different commit.")
            for key, expected in (
                ("privateRoot", private_root),
                ("statePath", state_path),
                ("backupRoot", backup_root),
            ):
                if manifest.get(key) != str(expected):
                    raise IntegrityError(
                        f"The resume {key} differs from the original shipping transaction."
                    )
            if manifest.get("phase") not in {
                "installing",
                "installed-awaiting-launch",
                "needs-verification",
            }:
                raise ShippingError("The shipping manifest is not awaiting verification.")
            mode = required_string(manifest, "mode", "shipping manifest")
            device_mapping = object_dict(manifest.get("device"), "shipping manifest.device")
            requested_device = required_string(
                device_mapping, "identifier", "shipping manifest.device"
            )
            doctor_result = doctor(
                runner,
                repo_root,
                private_root,
                state_path,
                backup_root,
                mode,
                requested_device,
                scratch,
            )
            asset_hashes = object_dict(manifest.get("assetHashes"), "shipping manifest.assetHashes")
            if asset_hashes != doctor_result.assets.hashes:
                raise IntegrityError(
                    "Private assets changed after the interrupted install; refusing ambiguous resume."
                )
            if manifest.get("phase") == "installing":
                staged_app_path = Path(
                    required_string(manifest, "stagedAppPath", "shipping manifest")
                )
                if not staged_app_path.is_dir():
                    raise IntegrityError(
                        f"The resumable signed app artifact is missing: {staged_app_path}"
                    )
                validate_staged_app(
                    runner,
                    staged_app_path,
                    doctor_result,
                    commit,
                    expected_version=required_string(manifest, "version", "shipping manifest"),
                    expected_build=required_string(manifest, "build", "shipping manifest"),
                )
                install_and_transition(
                    runner,
                    scratch,
                    doctor_result,
                    staged_app_path,
                    manifest_path,
                    manifest,
                )
            complete_or_request_resume(
                runner,
                repo_root,
                private_root,
                state_path,
                backup_root,
                scratch,
                manifest_path,
                manifest,
                doctor_result,
            )
            return

        classification = classify_install(runner, repo_root, commit, state_path)
        mode = classification["mode"]
        print(
            f"installMode={mode}\nbase={classification.get('base', 'unknown')}\n"
            f"reason={classification.get('reason', 'unknown')}"
        )
        if mode == "none":
            print(f"status=already-installed\ncommit={commit}")
            return
        doctor_result = doctor(
            runner,
            repo_root,
            private_root,
            state_path,
            backup_root,
            mode,
            args.device,
            scratch,
        )
        print(
            f"device={doctor_result.device.name} ({doctor_result.device.model}, "
            f"iOS {doctor_result.device.os_version})"
        )
        print(
            f"profile={doctor_result.signing_profile.name}\n"
            f"freeGiB={doctor_result.available_bytes / 1024**3:.1f}"
        )
        if args.dry_run:
            print(f"status=dry-run\nmode={mode}\ncommit={commit}")
            return
        if args.derived_data:
            derived_data_context: tempfile.TemporaryDirectory[str] | None = None
            derived_data = Path(args.derived_data).expanduser().resolve()
            derived_data.mkdir(parents=True, exist_ok=True)
        else:
            derived_data_context = tempfile.TemporaryDirectory(prefix="whoop-device-build.")
            derived_data = Path(derived_data_context.name)
        try:
            build = build_app(
                runner,
                repo_root,
                private_root,
                doctor_result,
                commit,
                derived_data,
            )
            preinstall: BackupResult | None = None
            if mode == "full":
                preinstall = take_backup(
                    runner,
                    scratch,
                    doctor_result.device,
                    backup_root,
                    "preinstall",
                    commit,
                    project_schema_version(repo_root),
                    False,
                )
            shipping_runs = backup_root / "shipping-runs"
            shipping_runs.mkdir(parents=True, exist_ok=True, mode=0o700)
            shipping_runs.chmod(0o700)
            run_root = shipping_runs / (f"{commit}-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}")
            run_root.mkdir(mode=0o700)
            staged_app_path = run_root / "WHOOP.app"
            shutil.copytree(build.app_path, staged_app_path, copy_function=shutil.copy2)
            validate_staged_app(
                runner,
                staged_app_path,
                doctor_result,
                commit,
                expected_version=build.version,
                expected_build=build.build,
            )
            manifest_path = run_root / "manifest.json"
            manifest = manifest_base(
                commit,
                mode,
                doctor_result,
                build,
                {},
                preinstall,
                private_root,
                state_path,
                backup_root,
                staged_app_path,
            )
            atomic_write_json(manifest_path, manifest)
            install_and_transition(
                runner,
                scratch,
                doctor_result,
                staged_app_path,
                manifest_path,
                manifest,
            )
            complete_or_request_resume(
                runner,
                repo_root,
                private_root,
                state_path,
                backup_root,
                scratch,
                manifest_path,
                manifest,
                doctor_result,
            )
        finally:
            if derived_data_context is not None:
                derived_data_context.cleanup()


def run_ship(args: argparse.Namespace, runner: CommandRunner) -> None:
    repo_root = repository_root()
    private_root = Path(args.private_root).expanduser().resolve()
    state_path = Path(args.state).expanduser().resolve()
    backup_root = Path(args.backup_root).expanduser().resolve()
    lock_path = state_path.parent / ".whoop-phone-shipping.lock"
    with exclusive_file_lock(lock_path):
        _run_ship_locked(
            args,
            runner,
            repo_root,
            private_root,
            state_path,
            backup_root,
        )


def run_doctor(args: argparse.Namespace, runner: CommandRunner) -> None:
    repo_root = repository_root()
    with tempfile.TemporaryDirectory(prefix="whoop-phone-doctor.") as scratch_name:
        result = doctor(
            runner,
            repo_root,
            Path(args.private_root).expanduser().resolve(),
            Path(args.state).expanduser().resolve(),
            Path(args.backup_root).expanduser().resolve(),
            args.mode,
            args.device,
            Path(scratch_name),
        )
    print(
        f"status=ready\ndevice={result.device.identifier}\nudid={result.device.udid}\n"
        f"model={result.device.model}\nios={result.device.os_version} ({result.device.os_build})\n"
        f"bundle={result.app.bundle_identifier}\ncontainer={result.app.data_container_uuid}\n"
        f"profile={result.signing_profile.name}\nteam={result.development_team}\n"
        f"identity={result.signing_profile.code_sign_identity}\n"
        f"xcode={result.xcode_version}\niphoneosSDK={result.iphoneos_sdk}\n"
        f"sleepModel={result.assets.sleep_model_version}\n"
        f"recoveryModel={result.assets.recovery_model_version}\n"
        f"macFreeGiB={result.available_bytes / 1024**3:.1f}\n"
        f"phoneFreeGiB={result.device_available_bytes / 1024**3:.1f}"
    )


def run_validate_assets(args: argparse.Namespace) -> None:
    result = validate_private_assets(Path(args.private_root).expanduser().resolve())
    print(
        f"status=valid\nsleepModel={result.sleep_model_version}\n"
        f"recoveryModel={result.recovery_model_version}\n"
        f"archiveSchema={result.archive_schema_version}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Transactional WHOOP physical-phone shipping")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_paths(target: argparse.ArgumentParser) -> None:
        target.add_argument("--private-root", default=str(DEFAULT_PRIVATE_ROOT))
        target.add_argument("--state", default=str(DEFAULT_STATE_PATH))
        target.add_argument("--backup-root", default=str(DEFAULT_BACKUP_ROOT))

    doctor_parser = subparsers.add_parser("doctor", help="verify phone shipping prerequisites")
    add_paths(doctor_parser)
    doctor_parser.add_argument("--mode", choices=("fast", "full"), default="full")
    doctor_parser.add_argument("--device")

    ship_parser = subparsers.add_parser("ship", help="build, install, launch, and verify")
    add_paths(ship_parser)
    ship_parser.add_argument("--commit", required=True)
    ship_parser.add_argument("--device")
    ship_parser.add_argument("--derived-data")
    ship_parser.add_argument("--dry-run", action="store_true")
    ship_parser.add_argument("--resume")

    assets_parser = subparsers.add_parser("validate-assets", help="validate private inputs")
    assets_parser.add_argument("--private-root", default=str(DEFAULT_PRIVATE_ROOT))
    return parser


def main() -> int:
    args = build_parser().parse_args()
    runner = CommandRunner()
    try:
        if args.command == "doctor":
            run_doctor(args, runner)
        elif args.command == "ship":
            run_ship(args, runner)
        else:
            run_validate_assets(args)
    except ResumeRequired as error:
        print(f"status={error.status}", file=sys.stderr)
        print(str(error), file=sys.stderr)
        if error.manifest is not None:
            resume_arguments = [
                "Tools/ship_phone.sh",
                "--commit",
                getattr(args, "commit", ""),
                "--private-root",
                getattr(args, "private_root", str(DEFAULT_PRIVATE_ROOT)),
                "--state",
                getattr(args, "state", str(DEFAULT_STATE_PATH)),
                "--backup-root",
                getattr(args, "backup_root", str(DEFAULT_BACKUP_ROOT)),
                "--resume",
                str(error.manifest),
            ]
            print(f"Resume with: {shlex.join(resume_arguments)}", file=sys.stderr)
        return RESUME_EXIT_CODE
    except DeviceUnavailable as error:
        print("status=needs-device", file=sys.stderr)
        print(str(error), file=sys.stderr)
        return RESUME_EXIT_CODE
    except ShippingError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
