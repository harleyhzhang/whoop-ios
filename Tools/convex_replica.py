#!/usr/bin/env python3
"""Upload and restore encrypted WHOOP SQLite snapshots through Convex.

Convex stores only an age-encrypted zstd archive. The API token and age identity
live in the macOS Keychain, never in Git or ordinary configuration files.
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
from pathlib import Path
from typing import Any, cast

KEYCHAIN_SERVICE = "com.clintonst.whoop.convex-replica"
DEFAULT_BACKUP_ROOT = Path("/Users/harleyzhang/Documents/personal/data/whoop/device-backups")
DEFAULT_SITE_URL = "https://greedy-avocet-164.convex.site"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def keychain_value(account: str) -> str:
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-a",
            account,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
        ],
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
        headers={
            "authorization": f"Bearer {token}",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
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
    manifest: dict[str, Any] = {
        "format": 1,
        "createdAt": int(time.time() * 1000),
        "database": {
            "path": "sleep.sqlite3",
            "bytes": source_bytes,
            "sha256": source_sha256,
            "schemaVersion": schema_version,
        },
    }
    if sidecar is not None:
        manifest["officialArchive"] = {
            "path": "whoop-official-archive.sqlite3",
            "bytes": sidecar.stat().st_size,
            "sha256": sha256_file(sidecar),
        }

    identity = age_identity()
    recipient = age_recipient(identity)
    with tempfile.TemporaryDirectory(prefix="whoop-convex-stage-") as temporary:
        staging = Path(temporary)
        os.link(database, staging / "sleep.sqlite3")
        names = ["manifest.json", "sleep.sqlite3"]
        if sidecar is not None:
            os.link(sidecar, staging / "whoop-official-archive.sqlite3")
            names.append("whoop-official-archive.sqlite3")
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        tar = subprocess.Popen(
            ["tar", "-C", str(staging), "-cf", "-", *names],
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


def upload_file(upload_url: str, archive: Path) -> str:
    result = subprocess.run(
        [
            "curl",
            "--fail-with-body",
            "--silent",
            "--show-error",
            "--request",
            "POST",
            "--header",
            "Content-Type: application/octet-stream",
            "--data-binary",
            f"@{archive}",
            upload_url,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    response = json.loads(result.stdout)
    return str(response["storageId"])


def upload(database: Path, site_url: str, token: str) -> None:
    schema_version, source_bytes = sqlite_metadata(database)
    source_sha256 = sha256_file(database)
    try:
        latest = request_json(site_url, "/v1/archive/latest", token)
        if latest["archive"]["sourceSha256"] == source_sha256:
            print(f"Already current: {database} ({source_sha256[:12]})")
            return
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise

    with tempfile.TemporaryDirectory(prefix="whoop-convex-upload-") as temporary:
        encrypted = Path(temporary) / "whoop-replica.tar.zst.age"
        manifest = create_archive(database, encrypted)
        upload_url = request_json(
            site_url,
            "/v1/archive/upload-url",
            token,
            method="POST",
            body={},
        )["uploadUrl"]
        storage_id = upload_file(upload_url, encrypted)
        commit = request_json(
            site_url,
            "/v1/archive/commit",
            token,
            method="POST",
            body={
                "createdAt": manifest["createdAt"],
                "encryptedBytes": manifest["encryptedBytes"],
                "encryptedSha256": manifest["encryptedSha256"],
                "idempotencyKey": source_sha256,
                "schemaVersion": schema_version,
                "sourceBytes": source_bytes,
                "sourceSha256": source_sha256,
                "storageId": storage_id,
            },
        )
    print(
        "Uploaded encrypted WHOOP replica "
        f"{source_sha256[:12]} ({manifest['encryptedBytes'] / 1024 / 1024:.1f} MiB); "
        f"reused={commit['reused']}"
    )


def restore(destination: Path, site_url: str, token: str) -> None:
    latest = request_json(site_url, "/v1/archive/latest", token)
    archive = latest["archive"]
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="whoop-convex-restore-") as temporary:
        temporary_path = Path(temporary)
        encrypted = temporary_path / "whoop-replica.tar.zst.age"
        subprocess.run(
            [
                "curl",
                "--fail-with-body",
                "--silent",
                "--show-error",
                "--location",
                "--output",
                str(encrypted),
                latest["downloadUrl"],
            ],
            check=True,
        )
        if sha256_file(encrypted) != archive["encryptedSha256"]:
            raise RuntimeError("Encrypted archive SHA-256 does not match Convex metadata")

        identity_path = temporary_path / "age-identity.txt"
        identity_path.write_text(age_identity() + "\n", encoding="utf-8")
        identity_path.chmod(0o600)
        age = subprocess.Popen(
            ["age", "-d", "-i", str(identity_path), str(encrypted)],
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

    manifest = json.loads((destination / "manifest.json").read_text(encoding="utf-8"))
    restored_database = destination / manifest["database"]["path"]
    sqlite_metadata(restored_database)
    if sha256_file(restored_database) != manifest["database"]["sha256"]:
        raise RuntimeError("Restored SQLite SHA-256 does not match its manifest")
    print(f"Restored and verified {restored_database}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--site-url")
    subparsers = parser.add_subparsers(dest="command", required=True)

    upload_parser = subparsers.add_parser("upload")
    upload_parser.add_argument("database", type=Path, nargs="?")
    upload_parser.add_argument("--backup-root", type=Path, default=DEFAULT_BACKUP_ROOT)

    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("destination", type=Path)

    args = parser.parse_args()
    if args.site_url is not None:
        site_url = args.site_url.rstrip("/")
    elif args.env_file is not None:
        site_url = load_site_url(args.env_file)
    else:
        site_url = DEFAULT_SITE_URL
    token = keychain_value("api-token")

    if args.command == "upload":
        database = args.database or latest_snapshot(args.backup_root)
        upload(database.resolve(), site_url, token)
    elif args.command == "restore":
        restore(args.destination.resolve(), site_url, token)


if __name__ == "__main__":
    main()
