#!/usr/bin/env python3
"""Seed, inspect, and restore the encrypted chunked phone replica."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sqlite3
import subprocess
import time
import urllib.request
import zlib
from collections.abc import Iterator
from pathlib import Path
from typing import Any, cast

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from whoop_config import data_root, setting

KEYCHAIN_SERVICE = setting("WHOOP_REPLICA_KEYCHAIN_SERVICE", "whoop.convex-replica")
DEFAULT_SITE_URL = setting("WHOOP_CONVEX_SITE_URL", "")
DEFAULT_BACKUP_ROOT = data_root() / "device-backups"
DEFAULT_CHUNK_SIZE = 8 * 1024 * 1024


def keychain_value(account: str) -> str:
    result = subprocess.run(
        ["security", "find-generic-password", "-a", account, "-s", KEYCHAIN_SERVICE, "-w"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def encryption_key() -> bytes:
    decoded = base64.b64decode(keychain_value("phone-encryption-key-b64"), validate=True)
    if len(decoded) != 32:
        raise RuntimeError("Phone replica encryption key must contain exactly 32 bytes")
    return decoded


def latest_snapshot(root: Path) -> Path:
    state_path = root.parent / "device-install-state.json"
    if state_path.is_file():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        verified = state.get("lastVerifiedBackup", {})
        if isinstance(verified, dict) and isinstance(verified.get("path"), str):
            candidate = Path(verified["path"]) / "sleep-standalone.sqlite3"
            if candidate.is_file():
                return candidate
    candidates = list(root.glob("*/sleep-standalone.sqlite3"))
    if not candidates:
        raise RuntimeError(f"No verified WHOOP snapshots found under {root}")
    return max(candidates, key=lambda candidate: candidate.stat().st_mtime_ns)


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
        f"{site_url.rstrip('/')}{path}",
        data=encoded,
        method=method,
        headers={"authorization": f"Bearer {token}", "content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        return cast(dict[str, Any], json.loads(response.read()))


def upload_blob(upload_url: str, payload: bytes) -> str:
    request = urllib.request.Request(
        upload_url,
        data=payload,
        method="POST",
        headers={"content-type": "application/octet-stream"},
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        body = cast(dict[str, Any], json.loads(response.read()))
    return str(body["storageId"])


def database_metadata(database: Path) -> tuple[int, int]:
    uri = f"file:{database}?mode=ro&immutable=1"
    with sqlite3.connect(uri, uri=True) as connection:
        check = connection.execute("PRAGMA quick_check").fetchone()
        if check != ("ok",):
            raise RuntimeError(f"SQLite quick_check failed for {database}: {check}")
        schema = int(connection.execute("PRAGMA user_version").fetchone()[0])
    return schema, database.stat().st_size


def chunks(database: Path, chunk_size: int) -> Iterator[tuple[int, bytes]]:
    with database.open("rb") as handle:
        index = 0
        while block := handle.read(chunk_size):
            yield index, block
            index += 1


def chunk_id(key: bytes, index: int, plaintext: bytes) -> str:
    return hmac.new(key, index.to_bytes(8, "big") + plaintext, hashlib.sha256).hexdigest()


def describe(database: Path, key: bytes, chunk_size: int) -> dict[str, Any]:
    source_mac = hmac.new(key, digestmod=hashlib.sha256)
    chunk_ids: list[str] = []
    chunk_plain_bytes: list[int] = []
    for index, plaintext in chunks(database, chunk_size):
        source_mac.update(plaintext)
        chunk_ids.append(chunk_id(key, index, plaintext))
        chunk_plain_bytes.append(len(plaintext))
    schema_version, source_bytes = database_metadata(database)
    return {
        "chunkIds": chunk_ids,
        "chunkPlainBytes": chunk_plain_bytes,
        "chunkSize": chunk_size,
        "createdAt": int(time.time() * 1000),
        "schemaVersion": schema_version,
        "sourceBytes": source_bytes,
        "sourceFingerprint": source_mac.hexdigest(),
    }


def encrypt_chunk(key: bytes, identifier: str, plaintext: bytes) -> bytes:
    compressed = zlib.compress(plaintext, 9)
    nonce = os.urandom(12)
    return nonce + AESGCM(key).encrypt(nonce, compressed, identifier.encode())


def decrypt_chunk(key: bytes, identifier: str, encrypted: bytes) -> bytes:
    if len(encrypted) < 28:
        raise RuntimeError(f"Encrypted chunk {identifier[:12]} is truncated")
    compressed = AESGCM(key).decrypt(encrypted[:12], encrypted[12:], identifier.encode())
    return zlib.decompress(compressed)


def seed(database: Path, site_url: str, chunk_size: int) -> None:
    key = encryption_key()
    token = keychain_value("phone-upload-token")
    manifest = describe(database, key, chunk_size)
    missing_response = request_json(
        site_url,
        "/v1/phone/missing",
        token,
        method="POST",
        body={"chunkIds": manifest["chunkIds"]},
    )
    missing = set(cast(list[str], missing_response["missing"]))
    uploaded_bytes = 0
    uploaded_count = 0
    for index, plaintext in chunks(database, chunk_size):
        identifier = cast(list[str], manifest["chunkIds"])[index]
        if identifier not in missing:
            continue
        encrypted = encrypt_chunk(key, identifier, plaintext)
        upload_url = str(
            request_json(site_url, "/v1/phone/upload-url", token, method="POST", body={})[
                "uploadUrl"
            ]
        )
        storage_id = upload_blob(upload_url, encrypted)
        request_json(
            site_url,
            "/v1/phone/commit-chunk",
            token,
            method="POST",
            body={
                "chunkId": identifier,
                "createdAt": int(time.time() * 1000),
                "encryptedBytes": len(encrypted),
                "storageId": storage_id,
            },
        )
        uploaded_count += 1
        uploaded_bytes += len(encrypted)
        print(f"Uploaded chunk {index + 1}/{len(manifest['chunkIds'])}")
    result = request_json(
        site_url,
        "/v1/phone/commit-snapshot",
        token,
        method="POST",
        body={**manifest, "seedOnly": True},
    )
    print(
        f"Committed phone replica {manifest['sourceFingerprint'][:12]} with "
        f"{len(manifest['chunkIds'])} chunks; uploaded={uploaded_count} "
        f"({uploaded_bytes / 1024 / 1024:.1f} MiB), reused={result['reused']}"
    )


def restore(destination: Path, site_url: str) -> None:
    if destination.exists() and any(destination.iterdir()):
        raise RuntimeError(f"Restore destination must be empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    key = encryption_key()
    token = keychain_value("api-token")
    snapshot = request_json(site_url, "/v1/phone/latest", token)["snapshot"]
    partial = destination / "sleep.sqlite3.partial"
    restored = destination / "sleep.sqlite3"
    source_mac = hmac.new(key, digestmod=hashlib.sha256)
    try:
        with partial.open("wb") as output:
            chunk_ids = cast(list[str], snapshot["chunkIds"])
            sizes = cast(list[int], snapshot["chunkPlainBytes"])
            for index, (identifier, expected_size) in enumerate(zip(chunk_ids, sizes, strict=True)):
                response = request_json(
                    site_url,
                    "/v1/phone/chunk-url",
                    token,
                    method="POST",
                    body={"chunkId": identifier},
                )
                with urllib.request.urlopen(str(response["downloadUrl"]), timeout=180) as download:
                    encrypted = download.read()
                plaintext = decrypt_chunk(key, identifier, encrypted)
                if len(plaintext) != expected_size or chunk_id(key, index, plaintext) != identifier:
                    raise RuntimeError(f"Chunk integrity check failed at index {index}")
                source_mac.update(plaintext)
                output.write(plaintext)
                print(f"Restored chunk {index + 1}/{len(chunk_ids)}")
        if partial.stat().st_size != int(snapshot["sourceBytes"]):
            raise RuntimeError("Restored database size does not match the snapshot manifest")
        if not hmac.compare_digest(source_mac.hexdigest(), str(snapshot["sourceFingerprint"])):
            raise RuntimeError("Restored database fingerprint does not match the snapshot manifest")
        schema, source_bytes = database_metadata(partial)
        if schema != int(snapshot["schemaVersion"]):
            raise RuntimeError("Restored database schema does not match the snapshot manifest")
        os.replace(partial, restored)
    except Exception:
        partial.unlink(missing_ok=True)
        raise
    print(f"Restored and verified {restored} ({source_bytes} bytes, schema {schema})")


def status(site_url: str) -> None:
    token = keychain_value("api-token")
    response = request_json(site_url, "/v1/phone/status", token)
    snapshots = cast(list[dict[str, Any]], response["snapshots"])
    print(
        json.dumps(
            {
                "chunkCount": response["chunkCount"],
                "encryptedBytes": response["encryptedBytes"],
                "orphanedStorageBytes": response.get("orphanedStorageBytes"),
                "orphanedStorageCount": response.get("orphanedStorageCount"),
                "snapshots": [
                    {
                        "chunkCount": len(snapshot["chunkIds"]),
                        "createdAt": snapshot["createdAt"],
                        "schemaVersion": snapshot["schemaVersion"],
                        "sourceBytes": snapshot["sourceBytes"],
                        "sourceFingerprint": str(snapshot["sourceFingerprint"])[:12],
                    }
                    for snapshot in snapshots
                ],
                "stagedChunkBytes": response.get("stagedChunkBytes"),
                "stagedChunkCount": response.get("stagedChunkCount"),
                "storageBytes": response.get("storageBytes"),
                "storageInventoryTruncated": response.get("storageInventoryTruncated"),
                "storageObjectCount": response.get("storageObjectCount"),
            },
            indent=2,
            sort_keys=True,
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site-url", default=DEFAULT_SITE_URL)
    subparsers = parser.add_subparsers(dest="command", required=True)
    seed_parser = subparsers.add_parser("seed")
    seed_parser.add_argument("database", type=Path, nargs="?")
    seed_parser.add_argument("--backup-root", type=Path, default=DEFAULT_BACKUP_ROOT)
    seed_parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("destination", type=Path)
    subparsers.add_parser("status")
    args = parser.parse_args()
    if args.command == "seed":
        database = args.database or latest_snapshot(args.backup_root)
        seed(database.resolve(), args.site_url, args.chunk_size)
    elif args.command == "restore":
        restore(args.destination.resolve(), args.site_url)
    elif args.command == "status":
        status(args.site_url)


if __name__ == "__main__":
    main()
