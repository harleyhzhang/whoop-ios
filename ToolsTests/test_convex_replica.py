import json
import os
import sqlite3
from pathlib import Path

import convex_replica
import pytest
from convex_replica import (
    latest_snapshot,
    load_site_url,
    retire_convex,
    validate_extracted_archive,
    validate_receipt,
    verify_offsite_round_trip,
)


def create_database(path: Path, schema: int, value: str) -> None:
    with sqlite3.connect(path) as connection:
        connection.execute(f"PRAGMA user_version = {schema}")
        connection.execute("CREATE TABLE evidence(value TEXT NOT NULL)")
        connection.execute("INSERT INTO evidence VALUES (?)", (value,))


def create_extracted_archive(root: Path) -> dict[str, object]:
    root.mkdir()
    database = root / "sleep.sqlite3"
    sidecar = root / "whoop-official-archive.sqlite3"
    create_database(database, 10, "raw packet evidence")
    create_database(sidecar, 1, "official response evidence")
    manifest: dict[str, object] = {
        "format": 1,
        "database": {
            "path": database.name,
            "bytes": database.stat().st_size,
            "sha256": convex_replica.sha256_file(database),
            "schemaVersion": 10,
        },
        "officialArchive": {
            "path": sidecar.name,
            "bytes": sidecar.stat().st_size,
            "sha256": convex_replica.sha256_file(sidecar),
            "schemaVersion": 1,
        },
    }
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return manifest


def test_load_site_url(tmp_path: Path) -> None:
    env_file = tmp_path / ".env.local"
    env_file.write_text(
        "CONVEX_DEPLOYMENT=dev:test\nCONVEX_SITE_URL=https://example.convex.site\n",
        encoding="utf-8",
    )
    assert load_site_url(env_file) == "https://example.convex.site"


def test_latest_snapshot_uses_mtime(tmp_path: Path) -> None:
    older = tmp_path / "older" / "sleep-standalone.sqlite3"
    newer = tmp_path / "newer" / "sleep-standalone.sqlite3"
    older.parent.mkdir()
    newer.parent.mkdir()
    older.write_bytes(b"old")
    newer.write_bytes(b"new")
    older_mtime = 1_700_000_000_000_000_000
    newer_mtime = older_mtime + 1
    os.utime(older, ns=(older_mtime, older_mtime))
    os.utime(newer, ns=(newer_mtime, newer_mtime))
    assert latest_snapshot(tmp_path) == newer


def test_latest_snapshot_prefers_install_state(tmp_path: Path) -> None:
    backups = tmp_path / "device-backups"
    current = backups / "current" / "sleep-standalone.sqlite3"
    misleading = backups / "legacy-schema-v8-example" / "sleep-standalone.sqlite3"
    current.parent.mkdir(parents=True)
    misleading.parent.mkdir(parents=True)
    current.write_bytes(b"current")
    misleading.write_bytes(b"legacy")
    os.utime(misleading, ns=(2_000_000_000_000_000_000,) * 2)
    (tmp_path / "device-install-state.json").write_text(
        '{"lastVerifiedBackup":{"path":"' + str(current.parent) + '"}}',
        encoding="utf-8",
    )
    assert latest_snapshot(backups) == current


def test_validate_extracted_archive_checks_database_and_sidecar(tmp_path: Path) -> None:
    extracted = tmp_path / "extracted"
    manifest = create_extracted_archive(extracted)

    assert validate_extracted_archive(extracted) == manifest

    with (extracted / "whoop-official-archive.sqlite3").open("ab") as handle:
        handle.write(b"tamper")
    with pytest.raises(RuntimeError, match="officialArchive byte count"):
        validate_extracted_archive(extracted)


def test_offsite_round_trip_requires_identical_ciphertext_and_writes_receipt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    archive = tmp_path / "whoop.age"
    downloaded = tmp_path / "downloaded.age"
    archive.write_bytes(b"encrypted-health-archive")
    downloaded.write_bytes(archive.read_bytes())
    manifest: dict[str, object] = {
        "database": {
            "path": "sleep.sqlite3",
            "bytes": 42,
            "sha256": "a" * 64,
        }
    }
    monkeypatch.setattr(convex_replica, "verify_archive", lambda _: manifest)
    receipt_path = tmp_path / "receipt.json"

    receipt = verify_offsite_round_trip(
        archive,
        downloaded,
        "google-drive",
        "WHOOP Encrypted Backups/whoop.age",
        receipt_path,
    )

    assert receipt["provider"] == "google-drive"
    assert receipt["encryptedSha256"] == convex_replica.sha256_file(archive)
    assert validate_receipt(archive, manifest, receipt_path) == receipt


def test_offsite_round_trip_rejects_changed_download(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    archive = tmp_path / "whoop.age"
    downloaded = tmp_path / "downloaded.age"
    archive.write_bytes(b"original")
    downloaded.write_bytes(b"modified")
    monkeypatch.setattr(convex_replica, "verify_archive", lambda _: {})

    with pytest.raises(RuntimeError, match="does not byte-match"):
        verify_offsite_round_trip(
            archive,
            downloaded,
            "google-drive",
            "WHOOP Encrypted Backups/whoop.age",
            tmp_path / "receipt.json",
        )


def test_retirement_rejects_phone_snapshot_older_than_archive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    archive = tmp_path / "whoop.age"
    archive.write_bytes(b"encrypted")
    manifest: dict[str, object] = {
        "database": {
            "path": "sleep.sqlite3",
            "bytes": 100,
            "sha256": "a" * 64,
        }
    }
    monkeypatch.setattr(convex_replica, "verify_archive", lambda _: manifest)
    monkeypatch.setattr(convex_replica, "validate_receipt", lambda *_: {})

    def fake_request(
        _site_url: str,
        path: str,
        _token: str,
        *,
        method: str = "GET",
        body: dict[str, object] | None = None,
    ) -> dict[str, object]:
        assert method == "GET"
        assert body is None
        if path == "/v1/archive/latest":
            return {
                "archive": {
                    "createdAt": 200,
                    "encryptedSha256": "b" * 64,
                    "schemaVersion": 10,
                    "sourceBytes": 100,
                    "sourceSha256": "a" * 64,
                    "_id": "archive-id",
                }
            }
        if path == "/v1/phone/status":
            return {
                "snapshots": [
                    {
                        "createdAt": 199,
                        "schemaVersion": 10,
                        "sourceBytes": 101,
                        "sourceFingerprint": "c" * 64,
                    }
                ]
            }
        raise AssertionError(path)

    monkeypatch.setattr(convex_replica, "request_json", fake_request)

    with pytest.raises(RuntimeError, match="does not safely supersede"):
        retire_convex(archive, tmp_path / "receipt.json", "https://example.test", "token")
