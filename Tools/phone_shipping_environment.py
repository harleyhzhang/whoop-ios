from __future__ import annotations

import os
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import cast

from phone_shipping_core import (
    BUNDLE_IDENTIFIER,
    AppInfo,
    AssetManifest,
    Device,
    ShippingError,
    SigningProfile,
    choose_device,
    load_json,
    object_dict,
    parse_app_info,
    parse_profile,
    required_string,
    sha256,
    validate_private_assets,
    validate_recent_full_backup,
)

MINIMUM_FREE_BYTES = {"fast": 3 * 1024**3, "full": 12 * 1024**3}
MINIMUM_DEVICE_FREE_BYTES = {"fast": 512 * 1024**2, "full": 4 * 1024**3}
GIT_REPOSITORY_ENVIRONMENT_KEYS = (
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
)


@dataclass(frozen=True)
class DoctorResult:
    device: Device
    app: AppInfo
    assets: AssetManifest
    signing_profile: SigningProfile
    development_team: str
    xcode_version: str
    iphoneos_sdk: str
    available_bytes: int
    device_available_bytes: int


@dataclass(frozen=True)
class BuildResult:
    app_path: Path
    version: str
    build: str


class CommandRunner:
    def __init__(self, verbose: bool = True) -> None:
        self.verbose = verbose

    def run(
        self,
        arguments: list[str],
        *,
        cwd: Path | None = None,
        environment: dict[str, str] | None = None,
        check: bool = True,
        timeout: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if self.verbose:
            print(f"+ {shlex.join(arguments)}")
        try:
            completed = subprocess.run(
                arguments,
                cwd=cwd,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise ShippingError(
                f"Command timed out after {timeout} seconds: {shlex.join(arguments)}"
            ) from error
        except OSError as error:
            raise ShippingError(f"Cannot run command {shlex.join(arguments)}: {error}") from error
        if completed.stdout and self.verbose:
            print(completed.stdout.rstrip())
        if completed.returncode != 0 and check:
            details = completed.stderr.strip() or completed.stdout.strip() or "no diagnostics"
            raise ShippingError(
                f"Command failed ({completed.returncode}): {shlex.join(arguments)}\n{details}"
            )
        return completed

    def devicectl_json(
        self,
        arguments: list[str],
        scratch: Path,
        *,
        check: bool = True,
        timeout: int = 60,
    ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
        scratch.mkdir(parents=True, exist_ok=True)
        descriptor, output_name = tempfile.mkstemp(prefix="devicectl-", suffix=".json", dir=scratch)
        os.close(descriptor)
        output_path = Path(output_name)
        try:
            completed = self.run(
                ["xcrun", "devicectl", *arguments, "--json-output", str(output_path)],
                check=False,
                timeout=timeout,
            )
            payload: object | None = None
            if output_path.stat().st_size > 0:
                payload = load_json(output_path, "CoreDevice output")
            if completed.returncode != 0 and check:
                details = completed.stderr.strip() or completed.stdout.strip() or "no diagnostics"
                raise ShippingError(f"CoreDevice command failed: {details}")
            return payload, completed
        finally:
            output_path.unlink(missing_ok=True)


def iso_now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def read_state(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    return object_dict(load_json(path, "device install state"), "device install state")


def isolated_git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for key in GIT_REPOSITORY_ENVIRONMENT_KEYS:
        environment.pop(key, None)
    return environment


def require_commands(names: tuple[str, ...]) -> None:
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        raise ShippingError(
            f"Missing required commands: {', '.join(missing)}. Run: brew bundle --file Brewfile"
        )


def repository_root() -> Path:
    completed = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise ShippingError("Run the phone shipping command from a WHOOP repository worktree.")
    return Path(completed.stdout.strip()).resolve()


def assert_exact_merged_commit(runner: CommandRunner, repo_root: Path, requested: str) -> str:
    git_environment = isolated_git_environment()
    status = runner.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=repo_root,
        environment=git_environment,
    ).stdout
    if status.strip():
        raise ShippingError(
            "The repository is dirty; commit or remove every change before shipping."
        )
    commit = runner.run(
        ["git", "rev-parse", "--verify", f"{requested}^{{commit}}"],
        cwd=repo_root,
        environment=git_environment,
    ).stdout.strip()
    head = runner.run(
        ["git", "rev-parse", "HEAD"], cwd=repo_root, environment=git_environment
    ).stdout.strip()
    if head != commit:
        raise ShippingError(
            f"HEAD is {head}; check out the requested commit {commit} before shipping."
        )
    runner.run(
        ["git", "fetch", "origin", "main", "--prune"],
        cwd=repo_root,
        environment=git_environment,
    )
    merged = runner.run(
        ["git", "merge-base", "--is-ancestor", commit, "origin/main"],
        cwd=repo_root,
        environment=git_environment,
        check=False,
    )
    if merged.returncode != 0:
        raise ShippingError(f"Commit {commit} is not merged into origin/main.")
    return commit


def classify_install(
    runner: CommandRunner, repo_root: Path, commit: str, state_path: Path
) -> dict[str, str]:
    completed = runner.run(
        [
            str(repo_root / "Tools/phone_install_policy.sh"),
            "--head",
            commit,
            "--state",
            str(state_path),
        ],
        cwd=repo_root,
    )
    result: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            result[key] = value
    if result.get("mode") not in {"none", "fast", "full"}:
        raise ShippingError("The phone install classifier returned no valid mode.")
    return result


def project_development_team(repo_root: Path) -> str:
    try:
        project = (repo_root / "project.yml").read_text()
    except OSError as error:
        raise ShippingError(f"Cannot read project.yml: {error}") from error
    match = re.search(r"^\s*DEVELOPMENT_TEAM:\s*([A-Z0-9]+)\s*$", project, re.MULTILINE)
    if match is None:
        raise ShippingError("project.yml does not declare DEVELOPMENT_TEAM.")
    return match.group(1)


def project_schema_version(repo_root: Path) -> int:
    try:
        source = (repo_root / "WhoopHandshakeApp/WhoopStore.swift").read_text()
    except OSError as error:
        raise ShippingError(f"Cannot read WhoopStore.swift: {error}") from error
    match = re.search(r"(?:currentSchemaVersion|schemaVersion)\s*=\s*([0-9]+)", source)
    if match is None:
        raise ShippingError("Cannot determine the expected WHOOP database schema version.")
    return int(match.group(1))


def list_devices(runner: CommandRunner, scratch: Path) -> object:
    payload, _ = runner.devicectl_json(["list", "devices", "--timeout", "15"], scratch)
    if payload is None:
        raise ShippingError("CoreDevice returned no device inventory.")
    return payload


def installed_app(
    runner: CommandRunner, scratch: Path, device: Device, bundle_identifier: str = BUNDLE_IDENTIFIER
) -> AppInfo:
    payload, _ = runner.devicectl_json(
        [
            "device",
            "info",
            "apps",
            "--device",
            device.identifier,
            "--bundle-id",
            bundle_identifier,
            "--timeout",
            "30",
        ],
        scratch,
    )
    if payload is None:
        raise ShippingError("CoreDevice returned no installed-app inventory.")
    return parse_app_info(payload, bundle_identifier)


def device_available_storage(runner: CommandRunner, scratch: Path, device: Device) -> int:
    del scratch
    completed = runner.run(
        [
            "ideviceinfo",
            "--network",
            "--udid",
            device.udid,
            "--domain",
            "com.apple.disk_usage",
            "--key",
            "AmountDataAvailable",
        ],
        timeout=30,
    )
    try:
        available = int(completed.stdout.strip())
    except ValueError as error:
        raise ShippingError("ideviceinfo returned no valid iPhone free-space value.") from error
    if available <= 0:
        raise ShippingError("ideviceinfo reported no available iPhone storage.")
    return available


def shipping_build_number(commit: str) -> str:
    if re.fullmatch(r"[0-9a-fA-F]{40}", commit) is None:
        raise ShippingError("The source commit must be a full 40-character Git SHA.")
    return str(int(commit[:12], 16))


def discover_signing_profile(
    runner: CommandRunner,
    device: Device,
    development_team: str,
    bundle_identifier: str = BUNDLE_IDENTIFIER,
) -> SigningProfile:
    identity_output = runner.run(["security", "find-identity", "-v", "-p", "codesigning"]).stdout
    if "Apple Development:" not in identity_output:
        raise ShippingError("No valid Apple Development signing identity is available in Keychain.")
    identities = {
        match.group(1).upper(): match.group(2)
        for match in re.finditer(r'\b([0-9A-F]{40})\s+"([^"]+)"', identity_output)
        if match.group(2).startswith("Apple Development:")
    }
    profile_root = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    if not profile_root.is_dir():
        raise ShippingError(f"Provisioning profile directory is missing: {profile_root}")
    matches: list[SigningProfile] = []
    for path in sorted(profile_root.glob("*.mobileprovision")):
        completed = subprocess.run(
            ["security", "cms", "-D", "-i", str(path)],
            check=False,
            capture_output=True,
        )
        if completed.returncode != 0:
            continue
        profile = parse_profile(completed.stdout, bundle_identifier, device.udid)
        if (
            profile is not None
            and profile.team_identifier == development_team
            and set(identities).intersection(profile.certificate_sha1s)
        ):
            matching_hash = next(
                certificate_hash
                for certificate_hash in profile.certificate_sha1s
                if certificate_hash in identities
            )
            matches.append(replace(profile, code_sign_identity=identities[matching_hash]))
    if not matches:
        raise ShippingError(
            f"No unexpired {development_team} development profile covers {bundle_identifier} "
            f"on device {device.udid}."
        )
    matches.sort(key=lambda profile: profile.expiration, reverse=True)
    return matches[0]


def doctor(
    runner: CommandRunner,
    repo_root: Path,
    private_root: Path,
    state_path: Path,
    backup_root: Path,
    mode: str,
    requested_device: str | None,
    scratch: Path,
) -> DoctorResult:
    require_commands(
        (
            "codesign",
            "git",
            "ideviceinfo",
            "jq",
            "security",
            "sqlite3",
            "xcodebuild",
            "xcodegen",
            "xcrun",
        )
    )
    if mode not in MINIMUM_FREE_BYTES:
        raise ShippingError(f"Unsupported doctor mode: {mode}")
    if repo_root in private_root.parents or private_root == repo_root:
        raise ShippingError("Private assets must remain outside the Git worktree.")
    if repo_root in state_path.parents or repo_root in backup_root.parents:
        raise ShippingError("Install state and backups must remain outside the Git worktree.")
    assets = validate_private_assets(private_root)
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup_root.chmod(0o700)
    available_bytes = shutil.disk_usage(backup_root).free
    required_bytes = MINIMUM_FREE_BYTES[mode]
    if available_bytes < required_bytes:
        raise ShippingError(
            f"Only {available_bytes / 1024**3:.1f} GiB is free; {mode} shipping requires "
            f"at least {required_bytes / 1024**3:.0f} GiB."
        )
    xcode_version = runner.run(["xcodebuild", "-version"]).stdout.strip().replace("\n", " ")
    iphoneos_sdk = runner.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]).stdout.strip()
    runner.run(["xcrun", "devicectl", "--version"])
    state = read_state(state_path)
    recorded_device = state.get("deviceIdentifier", state.get("deviceUDID"))
    effective_device = requested_device or (
        recorded_device if isinstance(recorded_device, str) and recorded_device else None
    )
    device = choose_device(list_devices(runner, scratch), effective_device)
    app = installed_app(runner, scratch, device)
    device_available_bytes = device_available_storage(runner, scratch, device)
    required_device_bytes = MINIMUM_DEVICE_FREE_BYTES[mode]
    if device_available_bytes < required_device_bytes:
        raise ShippingError(
            f"Only {device_available_bytes / 1024**3:.1f} GiB is free on the iPhone; "
            f"{mode} shipping requires at least {required_device_bytes / 1024**3:.1f} GiB."
        )
    if mode == "fast":
        validate_recent_full_backup(state)
    development_team = project_development_team(repo_root)
    profile = discover_signing_profile(runner, device, development_team)
    return DoctorResult(
        device=device,
        app=app,
        assets=assets,
        signing_profile=profile,
        development_team=development_team,
        xcode_version=xcode_version,
        iphoneos_sdk=iphoneos_sdk,
        available_bytes=available_bytes,
        device_available_bytes=device_available_bytes,
    )


def build_app(
    runner: CommandRunner,
    repo_root: Path,
    private_root: Path,
    doctor_result: DoctorResult,
    commit: str,
    derived_data: Path,
) -> BuildResult:
    runner.run([str(repo_root / "Tools/check_project_generation.sh")], cwd=repo_root)
    environment = os.environ.copy()
    environment.update(
        {
            "WHOOP_PRIVATE_SEED_ROOT": str(private_root),
            "WHOOP_HISTORY_SEED_PATH": str(private_root / "whoop-history.json"),
            "WHOOP_SCORE_MODEL_PATH": str(private_root / "whoop-score-model.json"),
            "WHOOP_RECOVERY_MODEL_PATH": str(private_root / "whoop-recovery-model.json"),
            "WHOOP_OFFICIAL_METRICS_PATH": str(private_root / "whoop-official-metrics.json"),
            "WHOOP_OFFICIAL_ARCHIVE_PATH": str(private_root / "whoop-official-archive.sqlite3"),
        }
    )
    build_number = shipping_build_number(commit)
    runner.run(
        [
            "xcodebuild",
            "build",
            "-quiet",
            "-project",
            "Sleep.xcodeproj",
            "-scheme",
            "Sleep",
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=iOS",
            "-derivedDataPath",
            str(derived_data),
            f"DEVELOPMENT_TEAM={doctor_result.development_team}",
            "CODE_SIGN_STYLE=Manual",
            f"PROVISIONING_PROFILE_SPECIFIER={doctor_result.signing_profile.name}",
            f"CODE_SIGN_IDENTITY={doctor_result.signing_profile.code_sign_identity}",
            f"WHOOP_SOURCE_COMMIT={commit}",
            f"CURRENT_PROJECT_VERSION={build_number}",
        ],
        cwd=repo_root,
        environment=environment,
        timeout=900,
    )
    app_path = derived_data / "Build/Products/Release-iphoneos/WHOOP.app"
    return validate_staged_app(
        runner,
        app_path,
        doctor_result,
        commit,
        expected_build=build_number,
    )


def validate_staged_app(
    runner: CommandRunner,
    app_path: Path,
    doctor_result: DoctorResult,
    commit: str,
    *,
    expected_version: str | None = None,
    expected_build: str | None = None,
) -> BuildResult:
    info_path = app_path / "Info.plist"
    if not info_path.is_file():
        raise ShippingError(f"Release app was not produced at {app_path}.")
    try:
        info = object_dict(cast(object, plistlib.loads(info_path.read_bytes())), "built Info.plist")
    except (OSError, plistlib.InvalidFileException) as error:
        raise ShippingError(f"Cannot inspect the built Info.plist: {error}") from error
    if info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER:
        raise ShippingError("The built app has the wrong bundle identifier.")
    if info.get("WHOOPSourceCommit") != commit:
        raise ShippingError("The built app does not identify the exact requested source commit.")
    version = required_string(info, "CFBundleShortVersionString", "built Info.plist")
    build = required_string(info, "CFBundleVersion", "built Info.plist")
    if expected_version is not None and version != expected_version:
        raise ShippingError("The staged app version differs from its transaction manifest.")
    if expected_build is not None and build != expected_build:
        raise ShippingError("The built app does not have the commit-bound build number.")
    runner.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)])
    embedded_profile = app_path / "embedded.mobileprovision"
    completed = subprocess.run(
        ["security", "cms", "-D", "-i", str(embedded_profile)],
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise ShippingError("The built app has no readable embedded provisioning profile.")
    signed_profile = parse_profile(completed.stdout, BUNDLE_IDENTIFIER, doctor_result.device.udid)
    if signed_profile is None or signed_profile.team_identifier != doctor_result.development_team:
        raise ShippingError("The embedded profile does not cover this bundle and device.")
    for name, expected_hash in doctor_result.assets.hashes.items():
        bundled_path = app_path / name
        if not bundled_path.is_file() or sha256(bundled_path) != expected_hash:
            raise ShippingError(
                f"Bundled private asset does not match its validated source: {name}"
            )
    return BuildResult(app_path=app_path, version=version, build=build)
