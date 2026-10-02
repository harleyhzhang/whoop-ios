from __future__ import annotations

import hashlib
import json
import math
import os
import plistlib
import re
import shutil
import sqlite3
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import cast

from generated_model_features import (
    RECOVERY_FEATURE_COUNT as RECOVERY_FEATURE_COUNT,
)
from generated_model_features import (
    RECOVERY_FEATURE_VERSION as RECOVERY_FEATURE_VERSION,
)
from generated_model_features import (
    SLEEP_FEATURE_COUNT as SLEEP_FEATURE_COUNT,
)
from generated_model_features import (
    SLEEP_FEATURE_VERSION as SLEEP_FEATURE_VERSION,
)
from whoop_config import setting

BUNDLE_IDENTIFIER = setting("WHOOP_BUNDLE_ID", "com.example.whoop")
PRIVATE_ASSET_NAMES = (
    "whoop-history.json",
    "whoop-score-model.json",
    "whoop-recovery-model.json",
    "whoop-strain-model.json",
    "whoop-official-metrics.json",
    "whoop-official-archive.sqlite3",
)
PRESERVED_TABLES = (
    "whoop_raw_packet",
    "whoop_historical_sample",
    "whoop_packet_replay",
    "whoop_ppg_packet",
    "whoop_offload_session",
    "whoop_api_source_record",
    "whoop_api_numeric_metric",
    "whoop_time_zone_observation",
    "daily_health_metric",
    "whoop_official_daily_metric",
    "whoop_daily_recovery_metric",
    "whoop_daily_step_metric",
)
IMMUTABLE_EVIDENCE_TABLES = (
    "whoop_raw_packet",
    "whoop_time_zone_observation",
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UUID_PATTERN = re.compile(r"(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")


class ShippingError(RuntimeError):
    pass


class IntegrityError(ShippingError):
    pass


class DeviceUnavailable(ShippingError):
    pass


@dataclass(frozen=True)
class Device:
    identifier: str
    udid: str
    name: str
    model: str
    os_version: str
    os_build: str
    last_connection: str
    transport: str = ""


@dataclass(frozen=True)
class AppInfo:
    bundle_identifier: str
    data_container_uuid: str
    version: str
    build: str


@dataclass(frozen=True)
class FileStamp:
    path: str
    modified_at: str
    size: int


@dataclass(frozen=True)
class AssetManifest:
    hashes: dict[str, str]
    sleep_model_version: str
    recovery_model_version: str
    archive_schema_version: int


@dataclass(frozen=True)
class BackupResult:
    path: str
    standalone_database: str
    schema_version: int
    quick_check: str
    foreign_key_violations: int
    table_counts: dict[str, int]
    hashes: dict[str, str]


@dataclass(frozen=True)
class DeploymentHealthReport:
    source_commit: str
    generated_at: str
    schema_version: int
    quick_check: str
    foreign_key_violations: int
    table_counts: dict[str, int]
    official_archive_sha256: str


@dataclass(frozen=True)
class SigningProfile:
    name: str
    uuid: str
    team_identifier: str
    expiration: datetime
    certificate_sha1s: tuple[str, ...]
    code_sign_identity: str = ""


def object_dict(value: object, description: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ShippingError(f"{description} must be a JSON object.")
    return cast(dict[str, object], value)


def object_list(value: object, description: str) -> list[object]:
    if not isinstance(value, list):
        raise ShippingError(f"{description} must be a JSON array.")
    return cast(list[object], value)


def required_string(mapping: dict[str, object], key: str, description: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        raise ShippingError(f"{description}.{key} must be a non-empty string.")
    return value


def required_int(mapping: dict[str, object], key: str, description: str) -> int:
    value = mapping.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        raise ShippingError(f"{description}.{key} must be an integer.")
    return value


def finite_number(value: object, description: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ShippingError(f"{description} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise ShippingError(f"{description} must be finite.")
    return result


def finite_number_list(value: object, description: str, expected: int | None = None) -> list[float]:
    raw = object_list(value, description)
    if expected is not None and len(raw) != expected:
        raise ShippingError(f"{description} must contain {expected} values; found {len(raw)}.")
    return [finite_number(item, f"{description}[{index}]") for index, item in enumerate(raw)]


def integer_list(value: object, description: str) -> list[int]:
    raw = object_list(value, description)
    result: list[int] = []
    for index, item in enumerate(raw):
        if not isinstance(item, int) or isinstance(item, bool):
            raise ShippingError(f"{description}[{index}] must be an integer.")
        result.append(item)
    return result


def load_json(path: Path, description: str) -> object:
    try:
        return cast(object, json.loads(path.read_text()))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ShippingError(f"Cannot decode {description} at {path}: {error}") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise ShippingError(f"Cannot hash {path}: {error}") from error
    return digest.hexdigest()


def atomic_write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise


@contextmanager
def exclusive_file_lock(path: Path) -> Iterator[None]:
    import fcntl

    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.chmod(path, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ShippingError(
                f"Another phone shipping process holds the exclusive lock at {path}."
            ) from error
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def backup_to_json(backup: BackupResult) -> dict[str, object]:
    return cast(dict[str, object], asdict(backup))


def assert_preserved(preinstall: BackupResult, postinstall: BackupResult) -> None:
    for table, before_count in preinstall.table_counts.items():
        after_count = postinstall.table_counts.get(table)
        if after_count is None:
            raise IntegrityError(f"Postinstall database lost required table {table}.")
        if after_count < before_count:
            raise IntegrityError(
                f"Postinstall {table} count decreased from {before_count} to {after_count}."
            )


def validate_deployment_health_report(
    path: Path,
    expected_commit: str,
    expected_schema: int,
    expected_archive_hash: str,
) -> DeploymentHealthReport:
    payload = object_dict(load_json(path, "deployment health report"), "deployment health report")
    if payload.get("formatVersion") != 1:
        raise IntegrityError("Deployment health report has an unsupported format version.")
    source_commit = required_string(payload, "sourceCommit", "deployment health report").lower()
    if (
        source_commit != expected_commit.lower()
        or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None
    ):
        raise IntegrityError("Deployment health report does not belong to the installed commit.")
    schema_version = required_int(payload, "schemaVersion", "deployment health report")
    if schema_version != expected_schema:
        raise IntegrityError(
            f"Installed schema is {schema_version}; expected exactly {expected_schema}."
        )
    quick_check = required_string(payload, "quickCheck", "deployment health report")
    foreign_keys = required_int(payload, "foreignKeyViolations", "deployment health report")
    if quick_check != "ok" or foreign_keys != 0:
        raise IntegrityError(
            f"Installed database failed health checks (quick={quick_check}, "
            f"foreignKeys={foreign_keys})."
        )
    archive_hash = required_string(
        payload, "officialArchiveSHA256", "deployment health report"
    ).lower()
    if (
        archive_hash != expected_archive_hash.lower()
        or SHA256_PATTERN.fullmatch(archive_hash) is None
    ):
        raise IntegrityError("Installed official archive does not match the validated source.")
    generated_at = required_string(payload, "generatedAt", "deployment health report")
    try:
        datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise IntegrityError("Deployment health report has an invalid generation time.") from error
    counts_value = object_dict(payload.get("tableCounts"), "deployment health report.tableCounts")
    counts = {
        key: required_int(counts_value, key, "deployment health table counts")
        for key in counts_value
    }
    return DeploymentHealthReport(
        source_commit=source_commit,
        generated_at=generated_at,
        schema_version=schema_version,
        quick_check=quick_check,
        foreign_key_violations=foreign_keys,
        table_counts=counts,
        official_archive_sha256=archive_hash,
    )


def assert_health_preserved(preinstall: BackupResult, report: DeploymentHealthReport) -> None:
    for table, before_count in preinstall.table_counts.items():
        after_count = report.table_counts.get(table)
        if after_count is None:
            raise IntegrityError(f"Deployment health report lost required table {table}.")
        if after_count < before_count:
            raise IntegrityError(
                f"Installed {table} count decreased from {before_count} to {after_count}."
            )


def assert_database_rows_preserved(preinstall: BackupResult, postinstall: BackupResult) -> None:
    pre_path = Path(preinstall.standalone_database).resolve()
    post_path = Path(postinstall.standalone_database).resolve()
    try:
        connection = sqlite3.connect(":memory:")
        try:
            connection.execute("ATTACH DATABASE ? AS preinstall", (str(pre_path),))
            connection.execute("ATTACH DATABASE ? AS postinstall", (str(post_path),))
            pre_tables = {
                str(row[0])
                for row in connection.execute(
                    "SELECT name FROM preinstall.sqlite_master WHERE type = 'table'"
                )
            }
            post_tables = {
                str(row[0])
                for row in connection.execute(
                    "SELECT name FROM postinstall.sqlite_master WHERE type = 'table'"
                )
            }
            for table in IMMUTABLE_EVIDENCE_TABLES:
                if table not in pre_tables:
                    continue
                if table not in post_tables:
                    raise IntegrityError(f"Postinstall database lost required table {table}.")
                quoted_table = table.replace('"', '""')
                pre_info = connection.execute(
                    f'PRAGMA preinstall.table_info("{quoted_table}")'
                ).fetchall()
                post_columns = {
                    str(row[1])
                    for row in connection.execute(
                        f'PRAGMA postinstall.table_info("{quoted_table}")'
                    )
                }
                columns = [str(row[1]) for row in pre_info]
                if not columns or not set(columns).issubset(post_columns):
                    raise IntegrityError(
                        f"Postinstall {table} no longer contains every preinstall column."
                    )
                primary_keys = [
                    str(row[1])
                    for row in sorted(pre_info, key=lambda row: int(row[5]))
                    if int(row[5]) > 0
                ]
                if not primary_keys:
                    raise IntegrityError(f"Preserved table {table} has no primary key.")
                join = " AND ".join(f'post."{column}" IS pre."{column}"' for column in primary_keys)
                unchanged = " AND ".join(f'post."{column}" IS pre."{column}"' for column in columns)
                missing = connection.execute(
                    f'SELECT 1 FROM preinstall."{quoted_table}" AS pre '
                    f'LEFT JOIN postinstall."{quoted_table}" AS post ON {join} '
                    f"WHERE NOT ({unchanged}) LIMIT 1"
                ).fetchone()
                if missing is not None:
                    raise IntegrityError(
                        f"Postinstall {table} deleted or changed preinstall evidence."
                    )
        finally:
            connection.close()
    except IntegrityError:
        raise
    except sqlite3.Error as error:
        raise ShippingError(f"Cannot compare pre/postinstall databases: {error}") from error


def validate_hash_manifest(root: Path) -> dict[str, str]:
    manifest_path = root / "SHA256SUMS.json"
    hashes = object_dict(load_json(manifest_path, "backup hash manifest"), "backup hash manifest")
    if not hashes:
        raise ShippingError(f"Backup hash manifest is empty: {manifest_path}")
    verified: dict[str, str] = {}
    resolved_root = root.resolve()
    for relative_name, raw_digest in hashes.items():
        if not isinstance(raw_digest, str) or SHA256_PATTERN.fullmatch(raw_digest) is None:
            raise ShippingError(f"Backup hash for {relative_name!r} is invalid.")
        candidate = (root / relative_name).resolve()
        try:
            candidate.relative_to(resolved_root)
        except ValueError as error:
            raise ShippingError("Backup hash manifest contains a path outside its root.") from error
        if not candidate.is_file() or sha256(candidate) != raw_digest:
            raise ShippingError(f"Backup hash mismatch: {candidate}")
        verified[relative_name] = raw_digest
    return verified


def validate_backup_result(backup: BackupResult) -> None:
    root = Path(backup.path)
    hashes = validate_hash_manifest(root)
    if hashes != backup.hashes:
        raise IntegrityError("Backup hashes no longer match the recorded transaction manifest.")
    standalone = Path(backup.standalone_database)
    try:
        standalone.resolve().relative_to(root.resolve())
    except ValueError as error:
        raise IntegrityError("Backup standalone database is outside its backup root.") from error
    schema, quick_check, foreign_keys, table_counts = sqlite_checks(standalone)
    if (
        schema != backup.schema_version
        or quick_check != backup.quick_check
        or foreign_keys != backup.foreign_key_violations
        or table_counts != backup.table_counts
    ):
        raise IntegrityError("Backup contents no longer match the recorded validation result.")


def validate_recent_backup(state: dict[str, object], maximum_age_days: int = 14) -> Path:
    value = state.get("lastVerifiedBackup")
    description = "install state.lastVerifiedBackup"
    path_key = "path"
    if value is None:
        value = state.get("lastFullBackup")
        description = "install state.lastFullBackup"
        path_key = "postinstall"
    backup = object_dict(value, description)
    if backup.get("quickCheck") != "ok" or backup.get("foreignKeyViolations", 0) != 0:
        raise ShippingError("The recorded backup did not pass SQLite validation.")
    verified_at = required_string(backup, "verifiedAt", description)
    try:
        verified = datetime.fromisoformat(verified_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise ShippingError("The recorded backup has an invalid verification time.") from error
    if verified.tzinfo is None:
        verified = verified.replace(tzinfo=UTC)
    if datetime.now(UTC) - verified.astimezone(UTC) > timedelta(days=maximum_age_days):
        raise ShippingError(
            f"The last verified backup is older than {maximum_age_days} days; "
            "use protected or migration verification."
        )
    postinstall = Path(required_string(backup, path_key, description))
    if not postinstall.is_dir():
        raise ShippingError(f"The recorded backup is missing: {postinstall}")
    if postinstall.stat().st_mode & 0o077:
        raise ShippingError("The recorded backup directory is readable by another user.")
    recorded_hashes_value = object_dict(backup.get("hashes"), f"{description}.hashes")
    recorded_hashes = {
        key: required_string(recorded_hashes_value, key, "install state backup hash")
        for key in recorded_hashes_value
    }
    verified_hashes = validate_hash_manifest(postinstall)
    if recorded_hashes != verified_hashes:
        raise ShippingError("The recorded backup hashes do not match trusted install state.")
    if not any(name.endswith("sleep-standalone.sqlite3") for name in recorded_hashes):
        raise ShippingError("The recorded backup does not hash its standalone database.")
    if not any(name.endswith("whoop-official-archive.sqlite3") for name in recorded_hashes):
        raise ShippingError("The recorded backup does not hash its official archive.")
    protected_paths = [postinstall / "SHA256SUMS.json"] + [
        postinstall / relative_name for relative_name in recorded_hashes
    ]
    if any(path.stat().st_mode & 0o077 for path in protected_paths):
        raise ShippingError("A recorded backup file is readable by another user.")
    standalone_candidates = sorted(postinstall.rglob("sleep-standalone.sqlite3"))
    if len(standalone_candidates) != 1:
        raise ShippingError(
            f"Expected one standalone database in the recorded backup; found "
            f"{len(standalone_candidates)}."
        )
    schema, quick_check, foreign_keys, _ = sqlite_checks(standalone_candidates[0])
    recorded_schema = backup.get("schemaVersion")
    if quick_check != "ok" or foreign_keys != 0 or schema != recorded_schema:
        raise ShippingError("The recorded backup no longer matches its validation state.")
    return postinstall


def validate_recent_full_backup(state: dict[str, object], maximum_age_days: int = 14) -> Path:
    """Compatibility adapter for older callers and install-state terminology."""
    return validate_recent_backup(state, maximum_age_days)


def validate_tree(value: object, feature_count: int, description: str) -> None:
    tree = object_dict(value, description)
    left = integer_list(tree.get("childrenLeft"), f"{description}.childrenLeft")
    right = integer_list(tree.get("childrenRight"), f"{description}.childrenRight")
    features = integer_list(tree.get("features"), f"{description}.features")
    thresholds = finite_number_list(tree.get("thresholds"), f"{description}.thresholds")
    values = finite_number_list(tree.get("values"), f"{description}.values")
    node_count = len(left)
    if node_count == 0 or any(
        len(items) != node_count for items in (right, features, thresholds, values)
    ):
        raise ShippingError(f"{description} arrays must have one value for every non-empty node.")
    for index, child in enumerate(left):
        sibling = right[index]
        if child == -1 and sibling == -1:
            continue
        if not (0 <= child < node_count and 0 <= sibling < node_count):
            raise ShippingError(f"{description} node {index} has an invalid child index.")
        if not 0 <= features[index] < feature_count:
            raise ShippingError(f"{description} node {index} has an invalid feature index.")


def validate_tree_list(value: object, feature_count: int, description: str) -> None:
    trees = object_list(value, description)
    if not trees:
        raise ShippingError(f"{description} must not be empty.")
    for index, tree in enumerate(trees):
        validate_tree(tree, feature_count, f"{description}[{index}]")


def validate_svr(value: object, feature_count: int, description: str) -> None:
    model = object_dict(value, description)
    finite_number_list(model.get("means"), f"{description}.means", feature_count)
    finite_number_list(model.get("scales"), f"{description}.scales", feature_count)
    vectors = object_list(model.get("supportVectors"), f"{description}.supportVectors")
    coefficients = finite_number_list(
        model.get("dualCoefficients"), f"{description}.dualCoefficients"
    )
    if not vectors or len(vectors) != len(coefficients):
        raise ShippingError(f"{description} support vectors and coefficients must align.")
    for index, vector in enumerate(vectors):
        finite_number_list(vector, f"{description}.supportVectors[{index}]", feature_count)
    finite_number(model.get("intercept"), f"{description}.intercept")
    if finite_number(model.get("gamma"), f"{description}.gamma") <= 0:
        raise ShippingError(f"{description}.gamma must be positive.")


def validate_boosted_model(value: object, feature_count: int, description: str) -> None:
    model = object_dict(value, description)
    finite_number(model.get("initialPrediction"), f"{description}.initialPrediction")
    if finite_number(model.get("learningRate"), f"{description}.learningRate") <= 0:
        raise ShippingError(f"{description}.learningRate must be positive.")
    validate_tree_list(model.get("trees"), feature_count, f"{description}.trees")


def validate_sleep_model(path: Path) -> str:
    model = object_dict(load_json(path, "sleep score model"), "sleep score model")
    version = required_string(model, "version", "sleep score model")
    feature_version = required_string(model, "featureVersion", "sleep score model")
    if feature_version != SLEEP_FEATURE_VERSION:
        raise ShippingError(
            f"Sleep model featureVersion is {feature_version!r}; expected {SLEEP_FEATURE_VERSION!r}."
        )
    feature_count = required_int(model, "featureCount", "sleep score model")
    if feature_count != SLEEP_FEATURE_COUNT:
        raise ShippingError(
            f"Sleep model featureCount is {feature_count}; expected {SLEEP_FEATURE_COUNT}."
        )
    for key in ("directWeight", "extraTreesWeight"):
        weight = finite_number(model.get(key), f"sleep score model.{key}")
        if not 0 <= weight <= 1:
            raise ShippingError(f"sleep score model.{key} must be between zero and one.")
    validate_tree_list(model.get("trees"), SLEEP_FEATURE_COUNT, "sleep score model.trees")
    validate_svr(model.get("svr"), SLEEP_FEATURE_COUNT, "sleep score model.svr")
    validate_boosted_model(
        model.get("needModel"), SLEEP_FEATURE_COUNT, "sleep score model.needModel"
    )
    validate_boosted_model(
        model.get("consistencyModel"),
        SLEEP_FEATURE_COUNT,
        "sleep score model.consistencyModel",
    )
    validate_svr(model.get("pillarSVR"), 3, "sleep score model.pillarSVR")
    return version


def validate_recovery_model(path: Path) -> str:
    model = object_dict(load_json(path, "recovery model"), "recovery model")
    version = required_string(model, "version", "recovery model")
    feature_version = required_string(model, "featureVersion", "recovery model")
    if feature_version != RECOVERY_FEATURE_VERSION:
        raise ShippingError(
            f"Recovery model featureVersion is {feature_version!r}; "
            f"expected {RECOVERY_FEATURE_VERSION!r}."
        )
    feature_count = required_int(model, "featureCount", "recovery model")
    if feature_count != RECOVERY_FEATURE_COUNT:
        raise ShippingError(
            f"Recovery model featureCount is {feature_count}; expected {RECOVERY_FEATURE_COUNT}."
        )
    weight = finite_number(model.get("boostedWeight"), "recovery model.boostedWeight")
    if not 0 <= weight <= 1:
        raise ShippingError("recovery model.boostedWeight must be between zero and one.")
    finite_number_list(model.get("imputerMedians"), "recovery model.imputerMedians", feature_count)
    validate_boosted_model(model.get("boostedModel"), feature_count, "recovery model.boostedModel")
    ridge = object_dict(model.get("ridgeModel"), "recovery model.ridgeModel")
    for key in ("imputerMedians", "means", "scales", "coefficients"):
        finite_number_list(ridge.get(key), f"recovery model.ridgeModel.{key}", feature_count)
    finite_number(ridge.get("intercept"), "recovery model.ridgeModel.intercept")
    return version


def sqlite_checks(path: Path) -> tuple[int, str, int, dict[str, int]]:
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            quick_rows = connection.execute("PRAGMA quick_check").fetchall()
            quick_check = ",".join(str(row[0]) for row in quick_rows)
            schema_version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            foreign_key_violations = len(connection.execute("PRAGMA foreign_key_check").fetchall())
            existing_tables = {
                str(row[0])
                for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
            }
            table_counts = {
                table: int(connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])
                for table in PRESERVED_TABLES
                if table in existing_tables
            }
        finally:
            connection.close()
    except (OSError, sqlite3.Error, TypeError, ValueError) as error:
        raise ShippingError(f"SQLite validation failed for {path}: {error}") from error
    return schema_version, quick_check, foreign_key_violations, table_counts


def validate_strain_model(path: Path) -> None:
    model = object_dict(load_json(path, "Strain model"), "Strain model")
    calibration = object_dict(model.get("calibration"), "Strain calibration")
    required_string(calibration, "version", "Strain calibration")
    bounds = {"exponent": (0.1, 10.0), "loadScale": (0.000001, 1e9), "scoreScale": (2.0, 15.0)}
    for key, (lower, upper) in bounds.items():
        value = calibration.get(key)
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or not lower <= value <= upper
        ):
            raise ShippingError(f"Invalid Strain calibration.{key}")
    maximum = model.get("maximumHeartRate")
    if (
        isinstance(maximum, bool)
        or not isinstance(maximum, (int, float))
        or not math.isfinite(maximum)
        or not 90 <= maximum <= 230
    ):
        raise ShippingError("Invalid Strain maximumHeartRate")


def validate_private_assets(private_root: Path) -> AssetManifest:
    missing = [name for name in PRIVATE_ASSET_NAMES if not (private_root / name).is_file()]
    if missing:
        raise ShippingError(f"Missing private WHOOP assets: {', '.join(missing)}")

    history = object_list(
        load_json(private_root / "whoop-history.json", "WHOOP history"), "WHOOP history"
    )
    if not history:
        raise ShippingError("WHOOP history must contain at least one record.")
    required_history_keys = {"dateKey", "sleepDurationMinutes", "source"}
    for index, item in enumerate(history):
        record = object_dict(item, f"WHOOP history[{index}]")
        if not required_history_keys.issubset(record):
            missing_keys = sorted(required_history_keys - record.keys())
            raise ShippingError(
                f"WHOOP history[{index}] is missing required keys: {', '.join(missing_keys)}"
            )

    metrics = object_dict(
        load_json(private_root / "whoop-official-metrics.json", "official metrics"),
        "official metrics",
    )
    source_database_hash = required_string(metrics, "sourceDatabaseSHA256", "official metrics")
    if not SHA256_PATTERN.fullmatch(source_database_hash):
        raise ShippingError("official metrics.sourceDatabaseSHA256 is not a SHA-256 digest.")
    daily = object_list(metrics.get("daily"), "official metrics.daily")
    if not daily:
        raise ShippingError("official metrics.daily must not be empty.")

    archive_path = private_root / "whoop-official-archive.sqlite3"
    archive_hash = sha256(archive_path)
    if archive_hash != source_database_hash:
        raise ShippingError("Official archive hash does not match the projection source hash.")
    archive_schema, quick_check, foreign_keys, _ = sqlite_checks(archive_path)
    if quick_check != "ok" or foreign_keys != 0:
        raise ShippingError(
            f"Official archive failed SQLite checks (quick={quick_check}, foreignKeys={foreign_keys})."
        )

    validate_strain_model(private_root / "whoop-strain-model.json")
    sleep_version = validate_sleep_model(private_root / "whoop-score-model.json")
    recovery_version = validate_recovery_model(private_root / "whoop-recovery-model.json")
    return AssetManifest(
        hashes={name: sha256(private_root / name) for name in PRIVATE_ASSET_NAMES},
        sleep_model_version=sleep_version,
        recovery_model_version=recovery_version,
        archive_schema_version=archive_schema,
    )


def nested_dicts(value: object) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    if isinstance(value, dict):
        mapping = cast(dict[str, object], value)
        result.append(mapping)
        for child in mapping.values():
            result.extend(nested_dicts(child))
    elif isinstance(value, list):
        for child in cast(list[object], value):
            result.extend(nested_dicts(child))
    return result


def string_value(mapping: dict[str, object], keys: tuple[str, ...]) -> str:
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, str) and value:
            return value
        if isinstance(value, dict):
            nested = cast(dict[str, object], value)
            for nested_key in ("path", "url", "absoluteString"):
                nested_value = nested.get(nested_key)
                if isinstance(nested_value, str) and nested_value:
                    return nested_value
    return ""


def parse_devices(payload: object, requested: str | None = None) -> list[Device]:
    candidates: list[Device] = []
    for mapping in nested_dicts(payload):
        hardware_value = mapping.get("hardwareProperties")
        properties_value = mapping.get("deviceProperties")
        connection_value = mapping.get("connectionProperties")
        if not all(
            isinstance(value, dict)
            for value in (hardware_value, properties_value, connection_value)
        ):
            continue
        hardware = cast(dict[str, object], hardware_value)
        properties = cast(dict[str, object], properties_value)
        connection = cast(dict[str, object], connection_value)
        if hardware.get("deviceType") != "iPhone" or hardware.get("reality") != "physical":
            continue
        if connection.get("pairingState") != "paired":
            continue
        if properties.get("developerModeStatus") != "enabled":
            continue
        if connection.get("tunnelState") == "unavailable":
            continue
        identifier = string_value(mapping, ("identifier",))
        udid = string_value(hardware, ("udid",))
        name = string_value(properties, ("name",))
        serial = string_value(hardware, ("serialNumber",))
        if requested and requested not in {identifier, udid, name, serial}:
            continue
        if not identifier or not udid:
            continue
        candidates.append(
            Device(
                identifier=identifier,
                udid=udid,
                name=name or "iPhone",
                model=string_value(hardware, ("marketingName", "productType")),
                os_version=string_value(properties, ("osVersionNumber",)),
                os_build=string_value(properties, ("osBuildUpdate",)),
                last_connection=string_value(connection, ("lastConnectionDate",)),
                transport=string_value(connection, ("transportType",)),
            )
        )
    candidates.sort(key=lambda device: device.last_connection, reverse=True)
    return candidates


def choose_device(payload: object, requested: str | None = None) -> Device:
    candidates = parse_devices(payload, requested)
    if not candidates:
        suffix = f" matching {requested!r}" if requested else ""
        raise DeviceUnavailable(
            f"No paired, available Developer Mode iPhone was found{suffix}. "
            "Keep the phone awake on the same network, then rerun the same command."
        )
    if len(candidates) > 1 and requested is None:
        descriptions = ", ".join(f"{item.name} ({item.udid})" for item in candidates)
        raise ShippingError(
            f"Multiple iPhones are available; pass --device explicitly: {descriptions}"
        )
    return candidates[0]


def parse_app_info(payload: object, bundle_identifier: str = BUNDLE_IDENTIFIER) -> AppInfo:
    for mapping in nested_dicts(payload):
        found_bundle = string_value(
            mapping, ("bundleIdentifier", "bundleID", "bundleId", "identifier")
        )
        if found_bundle != bundle_identifier:
            continue
        container_value = string_value(
            mapping,
            (
                "dataContainer",
                "dataContainerURL",
                "dataContainerPath",
                "containerURL",
            ),
        )
        container_match = UUID_PATTERN.search(container_value)
        if container_match is None:
            for nested in nested_dicts(mapping):
                for key, value in nested.items():
                    if "container" in key.lower() and isinstance(value, str):
                        container_match = UUID_PATTERN.search(value)
                        if container_match is not None:
                            break
                if container_match is not None:
                    break
        return AppInfo(
            bundle_identifier=found_bundle,
            data_container_uuid=(
                container_match.group(1).upper() if container_match is not None else ""
            ),
            version=string_value(
                mapping, ("shortVersion", "bundleShortVersion", "marketingVersion", "version")
            ),
            build=string_value(mapping, ("bundleVersion", "buildVersion", "build")),
        )
    raise ShippingError(f"{bundle_identifier} is not installed on the selected iPhone.")


def parse_file_stamps(payload: object) -> dict[str, FileStamp]:
    stamps: dict[str, FileStamp] = {}
    for mapping in nested_dicts(payload):
        path = string_value(mapping, ("path", "relativePath", "url", "fileURL", "name"))
        if not path or "sleep.sqlite3" not in path:
            continue
        metadata_value = mapping.get("metadata")
        metadata = metadata_value if isinstance(metadata_value, dict) else {}
        modified = string_value(
            {**metadata, **mapping},
            ("modifiedAt", "modificationDate", "lastModifiedDate", "fileModificationDate"),
        )
        if not modified:
            modified = string_value(metadata, ("lastModDate",))
        size_value = mapping.get(
            "size", mapping.get("fileSize", metadata.get("size", metadata.get("fileSize", 0)))
        )
        size = (
            int(size_value)
            if isinstance(size_value, int) and not isinstance(size_value, bool)
            else 0
        )
        stamps[path] = FileStamp(path=path, modified_at=modified, size=size)
    return stamps


def file_stamps_advanced(before: dict[str, FileStamp], after: dict[str, FileStamp]) -> bool:
    if not before or not after:
        return False
    for path, current in after.items():
        prior = before.get(path)
        if prior is None:
            return True
        if prior is not None and (current.modified_at, current.size) != (
            prior.modified_at,
            prior.size,
        ):
            return True
    return False


def find_process_id(payload: object, app_name: str = "WHOOP") -> int | None:
    for mapping in nested_dicts(payload):
        executable = string_value(
            mapping, ("executable", "executablePath", "path", "name", "processName")
        )
        if app_name not in executable and f"/{app_name}.app/" not in executable:
            continue
        for key in ("processIdentifier", "pid", "identifier"):
            value = mapping.get(key)
            if isinstance(value, int) and not isinstance(value, bool) and value > 0:
                return value
    return None


def parse_lock_state(payload: object) -> bool | None:
    for mapping in nested_dicts(payload):
        for key in ("locked", "isLocked", "passcodeLocked"):
            value = mapping.get(key)
            if isinstance(value, bool):
                return value
        state = string_value(mapping, ("lockState", "state"))
        if state.lower() in {"locked", "unlocked"}:
            return state.lower() == "locked"
    return None


def parse_profile(
    raw_plist: bytes, bundle_identifier: str, device_udid: str
) -> SigningProfile | None:
    try:
        value = plistlib.loads(raw_plist)
    except plistlib.InvalidFileException as error:
        raise ShippingError(f"Cannot decode provisioning profile: {error}") from error
    profile = object_dict(cast(object, value), "provisioning profile")
    expiration_value = profile.get("ExpirationDate")
    if not isinstance(expiration_value, datetime):
        return None
    expiration = expiration_value.replace(tzinfo=UTC)
    if expiration <= datetime.now(UTC):
        return None
    devices_value = profile.get("ProvisionedDevices")
    if not isinstance(devices_value, list) or device_udid not in devices_value:
        return None
    team_values = profile.get("TeamIdentifier")
    if not isinstance(team_values, list) or not team_values or not isinstance(team_values[0], str):
        return None
    team_identifier = team_values[0]
    entitlements = object_dict(profile.get("Entitlements"), "provisioning profile entitlements")
    application_identifier = entitlements.get("application-identifier")
    if application_identifier != f"{team_identifier}.{bundle_identifier}":
        return None
    name = profile.get("Name")
    uuid = profile.get("UUID")
    if not isinstance(name, str) or not name or not isinstance(uuid, str) or not uuid:
        return None
    certificates_value = profile.get("DeveloperCertificates")
    if not isinstance(certificates_value, list):
        return None
    certificate_sha1s = tuple(
        hashlib.sha1(certificate).hexdigest().upper()
        for certificate in certificates_value
        if isinstance(certificate, bytes)
    )
    if not certificate_sha1s:
        return None
    return SigningProfile(
        name=name,
        uuid=uuid,
        team_identifier=team_identifier,
        expiration=expiration,
        certificate_sha1s=certificate_sha1s,
    )


def create_standalone_backup(source_database: Path, destination: Path) -> None:
    try:
        source = sqlite3.connect(f"file:{source_database}?mode=ro", uri=True)
        destination_connection = sqlite3.connect(destination)
        try:
            source.backup(destination_connection)
        finally:
            destination_connection.close()
            source.close()
    except sqlite3.Error as error:
        raise ShippingError(f"Cannot create standalone SQLite backup: {error}") from error
    os.chmod(destination, 0o600)


def validate_backup(
    raw_root: Path, expected_schema: int | None, exact_schema: bool
) -> BackupResult:
    database_candidates = sorted(
        (path for path in raw_root.rglob("sleep.sqlite3") if "migration-backups" not in path.parts),
        key=lambda path: (len(path.parts), str(path)),
    )
    if len(database_candidates) != 1:
        raise ShippingError(
            f"Expected one main sleep.sqlite3 below {raw_root}; found {len(database_candidates)}."
        )
    source_database = database_candidates[0]
    standalone = raw_root.parent / "sleep-standalone.sqlite3"
    create_standalone_backup(source_database, standalone)
    schema_version, quick_check, foreign_keys, table_counts = sqlite_checks(standalone)
    if quick_check != "ok" or foreign_keys != 0:
        raise ShippingError(
            f"Backup failed SQLite checks (quick={quick_check}, foreignKeys={foreign_keys})."
        )
    if expected_schema is not None:
        schema_matches = (
            schema_version == expected_schema if exact_schema else schema_version <= expected_schema
        )
        if not schema_matches:
            comparison = "equal to" if exact_schema else "at most"
            raise ShippingError(
                f"Backup schema is {schema_version}; expected {comparison} {expected_schema}."
            )
    sidecars = list(raw_root.rglob("whoop-official-archive.sqlite3"))
    if len(sidecars) != 1:
        raise ShippingError(
            f"Expected one official archive below {raw_root}; found {len(sidecars)}."
        )
    sidecar_schema, sidecar_quick, sidecar_foreign_keys, _ = sqlite_checks(sidecars[0])
    if sidecar_quick != "ok" or sidecar_foreign_keys != 0 or sidecar_schema < 1:
        raise ShippingError("The backed-up official archive failed SQLite validation.")
    telemetry_sidecars = list(raw_root.rglob("storage-telemetry-v1.json"))
    if len(telemetry_sidecars) > 1:
        raise ShippingError(
            "Expected at most one storage telemetry sidecar below "
            f"{raw_root}; found {len(telemetry_sidecars)}."
        )
    if telemetry_sidecars:
        telemetry = object_dict(
            load_json(telemetry_sidecars[0], "storage telemetry sidecar"),
            "storage telemetry sidecar",
        )
        if telemetry.get("formatVersion") != 1 or not isinstance(telemetry.get("snapshots"), list):
            raise ShippingError("The backed-up storage telemetry sidecar is invalid.")
    # Keep one coherent standalone database and the irreplaceable sidecars.
    # The copied live database and WAL are transport intermediates; retaining
    # them duplicates roughly a gigabyte per snapshot and can recursively copy
    # app-side migration backups. Move sidecars instead of copying them again.
    archive = raw_root.parent / "whoop-official-archive.sqlite3"
    os.replace(sidecars[0], archive)
    retained_paths = [standalone, archive]
    if telemetry_sidecars:
        retained_telemetry = raw_root.parent / "storage-telemetry-v1.json"
        os.replace(telemetry_sidecars[0], retained_telemetry)
        retained_paths.append(retained_telemetry)
    hashes = {path.name: sha256(path) for path in retained_paths}
    checksum_path = raw_root.parent / "SHA256SUMS.json"
    atomic_write_json(checksum_path, hashes)
    for path in retained_paths:
        os.chmod(path, 0o600)
    os.chmod(raw_root.parent, 0o700)
    shutil.rmtree(raw_root)
    return BackupResult(
        path=str(raw_root.parent),
        standalone_database=str(standalone),
        schema_version=schema_version,
        quick_check=quick_check,
        foreign_key_violations=foreign_keys,
        table_counts=table_counts,
        hashes=hashes,
    )
