#!/usr/bin/env python3
"""Export, verify, restore, and retire encrypted WHOOP recovery archives.

The current phone replica remains in Convex. Full age-encrypted archives live
in independent offsite cold storage so they do not compete with the phone
replica for Convex's 1 GB file-storage allowance. Secrets remain in macOS
Keychain and archive payloads remain ciphertext outside this process.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

from whoop_config import data_root, setting

KEYCHAIN_SERVICE = setting("WHOOP_REPLICA_KEYCHAIN_SERVICE", "whoop.convex-replica")
DEFAULT_BACKUP_ROOT = data_root() / "device-backups"
DEFAULT_SITE_URL = setting("WHOOP_CONVEX_SITE_URL", "")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def keychain_value(account: str) -> str:
    result = subprocess.run(
        ["security", "find-generic-password", "-a", account, "-s", KEYCHAIN_SERVICE, "-w"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def load_site_url(env_path: Path) -> str:
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        key, separator, value = raw_line.partition("=")
        if separator and key.strip() == "CONVEX_SITE_URL":
            return value.strip().strip('"').rstrip("/")
    raise RuntimeError(f"CONVEX_SITE_URL is missing from {env_path}")


def request_json(
    site_url: str,
    path: str,
    token: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    encoded = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    request = urllib.request.Request(
        f"{site_url}{path}",
        data=encoded,
        method=method,
        headers={"authorization": f"Bearer {token}", "content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        return cast(dict[str, Any], json.loads(response.read()))


def sqlite_metadata(database: Path) -> tuple[int, int]:
    uri = f"file:{database}?mode=ro&immutable=1"
    with sqlite3.connect(uri, uri=True) as connection:
        quick_check = connection.execute("PRAGMA quick_check").fetchone()
        if quick_check != ("ok",):
            raise RuntimeError(f"SQLite quick_check failed for {database}: {quick_check}")
        schema_version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    return schema_version, database.stat().st_size


def latest_snapshot(root: Path) -> Path:
    install_state = root.parent / "device-install-state.json"
    if install_state.is_file():
        state = json.loads(install_state.read_text(encoding="utf-8"))
        verified = state.get("lastVerifiedBackup", {})
        if isinstance(verified, dict) and isinstance(verified.get("path"), str):
            managed = Path(verified["path"]) / "sleep-standalone.sqlite3"
            if managed.is_file():
                return managed

    candidates = [
        candidate
        for candidate in root.glob("*/sleep-standalone.sqlite3")
        if not candidate.parent.name.startswith("legacy-schema-")
    ]
    if not candidates:
        raise RuntimeError(f"No managed WHOOP snapshots found under {root}")
    return max(candidates, key=lambda candidate: candidate.stat().st_mtime_ns)


def matching_sidecar(database: Path) -> Path | None:
    candidate = database.with_name("whoop-official-archive.sqlite3")
    return candidate if candidate.is_file() else None


def age_recipient(identity: str) -> str:
    result = subprocess.run(
        ["age-keygen", "-y"],
        input=identity,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def age_identity() -> str:
    encoded = keychain_value("age-identity-b64")
    return base64.b64decode(encoded, validate=True).decode("utf-8").strip()


def create_archive(database: Path, output: Path) -> dict[str, Any]:
    schema_version, source_bytes = sqlite_metadata(database)
    source_sha256 = sha256_file(database)
    sidecar = matching_sidecar(database)
    if sidecar is None:
        raise RuntimeError(f"Verified snapshot has no official-response sidecar: {database.parent}")
    sidecar_schema, sidecar_bytes = sqlite_metadata(sidecar)
    manifest: dict[str, Any] = {
        "format": 1,
        "createdAt": int(time.time() * 1000),
        "database": {
            "path": "sleep.sqlite3",
            "bytes": source_bytes,
            "sha256": source_sha256,
            "schemaVersion": schema_version,
        },
        "officialArchive": {
            "path": "whoop-official-archive.sqlite3",
            "bytes": sidecar_bytes,
            "sha256": sha256_file(sidecar),
            "schemaVersion": sidecar_schema,
        },
    }

    identity = age_identity()
    recipient = age_recipient(identity)
    with tempfile.TemporaryDirectory(prefix="whoop-offsite-stage-") as temporary:
        staging = Path(temporary)
        os.link(database, staging / "sleep.sqlite3")
        os.link(sidecar, staging / "whoop-official-archive.sqlite3")
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        tar = subprocess.Popen(
            [
                "tar",
                "-C",
                str(staging),
                "-cf",
                "-",
                "manifest.json",
                "sleep.sqlite3",
                "whoop-official-archive.sqlite3",
            ],
            stdout=subprocess.PIPE,
        )
        zstd = subprocess.Popen(
            ["zstd", "-T0", "-9", "--quiet"],
            stdin=tar.stdout,
            stdout=subprocess.PIPE,
        )
        assert tar.stdout is not None
        tar.stdout.close()
        assert zstd.stdout is not None
        age = subprocess.run(
            ["age", "-r", recipient, "-o", str(output)],
            stdin=zstd.stdout,
            check=False,
        )
        zstd.stdout.close()
        tar_status = tar.wait()
        zstd_status = zstd.wait()
        if age.returncode or zstd_status or tar_status:
            output.unlink(missing_ok=True)
            raise RuntimeError(
                f"Archive pipeline failed: tar={tar_status} zstd={zstd_status} age={age.returncode}"
            )

    manifest["encryptedBytes"] = output.stat().st_size
    manifest["encryptedSha256"] = sha256_file(output)
    return manifest


def manifest_entry(manifest: dict[str, Any], key: str) -> dict[str, Any]:
    entry = manifest.get(key)
    if not isinstance(entry, dict):
        raise RuntimeError(f"Archive manifest has no {key} entry")
    if not isinstance(entry.get("path"), str):
        raise RuntimeError(f"Archive manifest {key} path is invalid")
    if not isinstance(entry.get("bytes"), int) or not isinstance(entry.get("sha256"), str):
        raise RuntimeError(f"Archive manifest {key} integrity fields are invalid")
    return cast(dict[str, Any], entry)


def validate_extracted_archive(destination: Path) -> dict[str, Any]:
    manifest_path = destination / "manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError("Encrypted archive has no manifest")
    manifest = cast(dict[str, Any], json.loads(manifest_path.read_text(encoding="utf-8")))
    if manifest.get("format") != 1:
        raise RuntimeError("Unsupported encrypted archive format")

    for key in ("database", "officialArchive"):
        entry = manifest_entry(manifest, key)
        source = destination / cast(str, entry["path"])
        if not source.is_file() or source.stat().st_size != entry["bytes"]:
            raise RuntimeError(f"Restored {key} byte count does not match its manifest")
        if sha256_file(source) != entry["sha256"]:
            raise RuntimeError(f"Restored {key} SHA-256 does not match its manifest")
        schema, _ = sqlite_metadata(source)
        expected_schema = entry.get("schemaVersion")
        if isinstance(expected_schema, int) and schema != expected_schema:
            raise RuntimeError(f"Restored {key} schema does not match its manifest")
    return manifest


def extract_archive(archive: Path, destination: Path) -> dict[str, Any]:
    if destination.exists() and any(destination.iterdir()):
        raise RuntimeError(f"Restore destination must be empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="whoop-offsite-identity-") as temporary:
        identity_path = Path(temporary) / "age-identity.txt"
        identity_path.write_text(age_identity() + "\n", encoding="utf-8")
        identity_path.chmod(0o600)
        age = subprocess.Popen(
            ["age", "-d", "-i", str(identity_path), str(archive)],
            stdout=subprocess.PIPE,
        )
        zstd = subprocess.Popen(
            ["zstd", "-d", "--quiet"],
            stdin=age.stdout,
            stdout=subprocess.PIPE,
        )
        assert age.stdout is not None
        age.stdout.close()
        assert zstd.stdout is not None
        tar = subprocess.run(
            ["tar", "-xf", "-", "-C", str(destination)],
            stdin=zstd.stdout,
            check=False,
        )
        zstd.stdout.close()
        age_status = age.wait()
        zstd_status = zstd.wait()
        if tar.returncode or zstd_status or age_status:
            raise RuntimeError(
                f"Restore pipeline failed: age={age_status} zstd={zstd_status} tar={tar.returncode}"
            )
    return validate_extracted_archive(destination)


def verify_archive(archive: Path) -> dict[str, Any]:
    if not archive.is_file():
        raise RuntimeError(f"Encrypted archive does not exist: {archive}")
    with tempfile.TemporaryDirectory(prefix="whoop-offsite-verify-") as temporary:
        return extract_archive(archive, Path(temporary))


def export_archive(database: Path, output: Path) -> dict[str, Any]:
    if output.exists():
        raise RuntimeError(f"Refusing to overwrite encrypted archive: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="whoop-offsite-export-", dir=output.parent
    ) as temporary:
        candidate = Path(temporary) / output.name
        expected = create_archive(database, candidate)
        actual = verify_archive(candidate)
        if manifest_entry(expected, "database") != manifest_entry(actual, "database"):
            raise RuntimeError("Verified archive database manifest changed during export")
        if manifest_entry(expected, "officialArchive") != manifest_entry(actual, "officialArchive"):
            raise RuntimeError("Verified archive sidecar manifest changed during export")
        os.replace(candidate, output)
    output.chmod(0o600)
    print(
        f"Exported and verified {output} ({output.stat().st_size / 1024 / 1024:.1f} MiB); "
        f"source={manifest_entry(actual, 'database')['sha256'][:12]}"
    )
    return actual


def verify_offsite_round_trip(
    archive: Path,
    downloaded: Path,
    provider: str,
    remote_path: str,
    receipt_path: Path,
) -> dict[str, Any]:
    source_hash = sha256_file(archive)
    if archive.stat().st_size != downloaded.stat().st_size or source_hash != sha256_file(
        downloaded
    ):
        raise RuntimeError("Downloaded offsite archive does not byte-match the uploaded ciphertext")
    manifest = verify_archive(downloaded)
    receipt: dict[str, Any] = {
        "format": 1,
        "provider": provider,
        "remotePath": remote_path,
        "encryptedBytes": archive.stat().st_size,
        "encryptedSha256": source_hash,
        "sourceSha256": manifest_entry(manifest, "database")["sha256"],
        "verifiedAt": datetime.now(UTC).isoformat(),
    }
    if receipt_path.exists():
        raise RuntimeError(f"Refusing to overwrite offsite receipt: {receipt_path}")
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = receipt_path.with_suffix(receipt_path.suffix + ".tmp")
    temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, receipt_path)
    print(f"Verified offsite round trip and wrote {receipt_path}")
    return receipt


def validate_receipt(archive: Path, manifest: dict[str, Any], receipt_path: Path) -> dict[str, Any]:
    receipt = cast(dict[str, Any], json.loads(receipt_path.read_text(encoding="utf-8")))
    if receipt.get("format") != 1 or not receipt.get("provider") or not receipt.get("remotePath"):
        raise RuntimeError("Offsite receipt is incomplete")
    expected = {
        "encryptedBytes": archive.stat().st_size,
        "encryptedSha256": sha256_file(archive),
        "sourceSha256": manifest_entry(manifest, "database")["sha256"],
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise RuntimeError(f"Offsite receipt {key} does not match the verified archive")
    return receipt


def restore_convex(destination: Path, site_url: str, token: str) -> None:
    latest = request_json(site_url, "/v1/archive/latest", token)
    archive = cast(dict[str, Any], latest["archive"])
    with tempfile.TemporaryDirectory(prefix="whoop-convex-download-") as temporary:
        encrypted = Path(temporary) / "whoop-replica.tar.zst.age"
        subprocess.run(
            [
                "curl",
                "--fail-with-body",
                "--silent",
                "--show-error",
                "--location",
                "--output",
                str(encrypted),
                str(latest["downloadUrl"]),
            ],
            check=True,
        )
        if sha256_file(encrypted) != archive["encryptedSha256"]:
            raise RuntimeError("Encrypted archive SHA-256 does not match Convex metadata")
        extract_archive(encrypted, destination)
    print(f"Restored and verified {destination / 'sleep.sqlite3'}")


def retire_convex(archive: Path, receipt_path: Path, site_url: str, token: str) -> None:
    manifest = verify_archive(archive)
    validate_receipt(archive, manifest, receipt_path)
    latest = request_json(site_url, "/v1/archive/latest", token)
    remote = cast(dict[str, Any], latest["archive"])
    database = manifest_entry(manifest, "database")
    if remote.get("sourceSha256") != database["sha256"]:
        raise RuntimeError("Offsite archive source does not match the Convex archive")

    phone_status = request_json(site_url, "/v1/phone/status", token)
    snapshots = phone_status.get("snapshots")
    if not isinstance(snapshots, list) or len(snapshots) != 1 or not isinstance(snapshots[0], dict):
        raise RuntimeError("Convex does not have exactly one current phone snapshot")
    phone = cast(dict[str, Any], snapshots[0])
    if (
        not isinstance(phone.get("sourceFingerprint"), str)
        or phone.get("schemaVersion", -1) < remote.get("schemaVersion", 0)
        or phone.get("sourceBytes", -1) < remote.get("sourceBytes", 0)
        or phone.get("createdAt", -1) < remote.get("createdAt", 0)
    ):
        raise RuntimeError("Current phone snapshot does not safely supersede the Convex archive")

    result = request_json(
        site_url,
        "/v1/archive/retire",
        token,
        method="POST",
        body={
            "expectedArchiveId": remote["_id"],
            "expectedEncryptedSha256": remote["encryptedSha256"],
            "expectedPhoneFingerprint": phone["sourceFingerprint"],
        },
    )
    try:
        request_json(site_url, "/v1/archive/latest", token)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        raise RuntimeError("Convex archive still exists after retirement")
    current_phone = request_json(site_url, "/v1/phone/status", token)
    current_snapshots = current_phone.get("snapshots")
    if (
        not isinstance(current_snapshots, list)
        or len(current_snapshots) != 1
        or not isinstance(current_snapshots[0], dict)
        or current_snapshots[0].get("sourceFingerprint") != phone["sourceFingerprint"]
    ):
        raise RuntimeError("Phone replica changed during archive retirement")
    print(
        "Retired redundant Convex archive "
        f"({int(result['deletedEncryptedBytes']) / 1024 / 1024:.1f} MiB); "
        f"phone={str(phone['sourceFingerprint'])[:12]}"
    )


def status(site_url: str, token: str) -> None:
    phone = request_json(site_url, "/v1/phone/status", token)
    try:
        archive = request_json(site_url, "/v1/archive/latest", token)["archive"]
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        archive = None
    print(json.dumps({"archive": archive, "phone": phone}, indent=2, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--site-url")
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("destination", type=Path)
    export_parser.add_argument("database", type=Path, nargs="?")
    export_parser.add_argument("--backup-root", type=Path, default=DEFAULT_BACKUP_ROOT)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("archive", type=Path)

    offsite_parser = subparsers.add_parser("verify-offsite")
    offsite_parser.add_argument("archive", type=Path)
    offsite_parser.add_argument("downloaded", type=Path)
    offsite_parser.add_argument("--provider", required=True)
    offsite_parser.add_argument("--remote-path", required=True)
    offsite_parser.add_argument("--receipt", required=True, type=Path)

    restore_file_parser = subparsers.add_parser("restore-file")
    restore_file_parser.add_argument("archive", type=Path)
    restore_file_parser.add_argument("destination", type=Path)

    restore_convex_parser = subparsers.add_parser("restore-convex")
    restore_convex_parser.add_argument("destination", type=Path)

    retire_parser = subparsers.add_parser("retire-convex")
    retire_parser.add_argument("archive", type=Path)
    retire_parser.add_argument("--receipt", required=True, type=Path)

    subparsers.add_parser("status")
    args = parser.parse_args()
    if args.site_url is not None:
        site_url = args.site_url.rstrip("/")
    elif args.env_file is not None:
        site_url = load_site_url(args.env_file)
    else:
        site_url = DEFAULT_SITE_URL

    if args.command == "export":
        database = args.database or latest_snapshot(args.backup_root)
        export_archive(database.resolve(), args.destination.resolve())
    elif args.command == "verify":
        manifest = verify_archive(args.archive.resolve())
        print(json.dumps(manifest, indent=2, sort_keys=True))
    elif args.command == "verify-offsite":
        verify_offsite_round_trip(
            args.archive.resolve(),
            args.downloaded.resolve(),
            args.provider,
            args.remote_path,
            args.receipt.resolve(),
        )
    elif args.command == "restore-file":
        extract_archive(args.archive.resolve(), args.destination.resolve())
    else:
        token = keychain_value("api-token")
        if args.command == "restore-convex":
            restore_convex(args.destination.resolve(), site_url, token)
        elif args.command == "retire-convex":
            retire_convex(args.archive.resolve(), args.receipt.resolve(), site_url, token)
        elif args.command == "status":
            status(site_url, token)


if __name__ == "__main__":
    main()
