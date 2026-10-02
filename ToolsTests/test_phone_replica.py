from __future__ import annotations

import hashlib
import hmac
import sqlite3
import urllib.request
from pathlib import Path
from typing import Any

import phone_replica
import pytest
from cryptography.exceptions import InvalidTag
from phone_replica import chunk_id, decrypt_chunk, describe, encrypt_chunk, restore, seed


def test_chunk_encryption_round_trip_and_authentication() -> None:
    key = bytes(range(32))
    plaintext = (b"private-whoop-data\0" * 4096) + b"tail"
    identifier = chunk_id(key, 7, plaintext)

    encrypted = encrypt_chunk(key, identifier, plaintext)

    assert plaintext not in encrypted
    assert decrypt_chunk(key, identifier, encrypted) == plaintext
    with pytest.raises(InvalidTag):
        decrypt_chunk(key, "0" * 64, encrypted)


def test_chunk_identity_is_bound_to_position() -> None:
    key = bytes(range(32))
    plaintext = b"same bytes"

    assert chunk_id(key, 0, plaintext) != chunk_id(key, 1, plaintext)


def test_descriptor_covers_exact_sqlite_bytes(tmp_path: Path) -> None:
    database = tmp_path / "sleep.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.execute("PRAGMA user_version = 10")
        connection.execute("CREATE TABLE sample(value TEXT NOT NULL)")
        connection.execute("INSERT INTO sample VALUES ('health history')")

    manifest = describe(database, bytes(range(32)), 1024)

    assert manifest["schemaVersion"] == 10
    assert manifest["sourceBytes"] == database.stat().st_size
    assert len(manifest["chunkIds"]) == len(manifest["chunkPlainBytes"])
    assert sum(manifest["chunkPlainBytes"]) == manifest["sourceBytes"]


def test_seed_uses_dedicated_phone_upload_token(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = tmp_path / "sleep.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.execute("PRAGMA user_version = 10")
        connection.execute("CREATE TABLE sample(value TEXT NOT NULL)")
    requested_accounts: list[str] = []
    requested_paths: list[str] = []

    def fake_keychain_value(account: str) -> str:
        requested_accounts.append(account)
        return "write-token"

    def fake_request(
        _site_url: str,
        path: str,
        token: str,
        *,
        method: str = "GET",
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        assert token == "write-token"
        assert method == "POST"
        assert body is not None
        requested_paths.append(path)
        if path == "/v1/phone/missing":
            return {"missing": []}
        if path == "/v1/phone/commit-snapshot":
            assert body["seedOnly"] is True
            return {"reused": True}
        raise AssertionError(path)

    monkeypatch.setattr(phone_replica, "encryption_key", lambda: bytes(range(32)))
    monkeypatch.setattr(phone_replica, "keychain_value", fake_keychain_value)
    monkeypatch.setattr(phone_replica, "request_json", fake_request)

    seed(database, "https://example.test", 8 * 1024 * 1024)

    assert requested_accounts == ["phone-upload-token"]
    assert requested_paths == ["/v1/phone/missing", "/v1/phone/commit-snapshot"]


class MemoryDownload:
    def __init__(self, payload: bytes) -> None:
        self.payload = payload

    def __enter__(self) -> MemoryDownload:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self) -> bytes:
        return self.payload


def remote_snapshot(payload: bytes, key: bytes, schema: int) -> tuple[dict[str, Any], bytes]:
    identifier = chunk_id(key, 0, payload)
    source_mac = hmac.new(key, payload, hashlib.sha256).hexdigest()
    return (
        {
            "chunkIds": [identifier],
            "chunkPlainBytes": [len(payload)],
            "chunkSize": 8 * 1024 * 1024,
            "createdAt": 2_000_000_000_000,
            "schemaVersion": schema,
            "sourceBytes": len(payload),
            "sourceFingerprint": source_mac,
        },
        encrypt_chunk(key, identifier, payload),
    )


def install_remote(
    monkeypatch: pytest.MonkeyPatch,
    snapshot: dict[str, Any],
    encrypted: bytes,
    key: bytes,
) -> None:
    identifier = str(snapshot["chunkIds"][0])

    def fake_request(
        _site_url: str,
        path: str,
        _token: str,
        *,
        method: str = "GET",
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if path == "/v1/phone/latest":
            return {"snapshot": snapshot}
        if path == "/v1/phone/chunk-url":
            assert method == "POST"
            assert body == {"chunkId": identifier}
            return {"downloadUrl": f"memory://{identifier}"}
        raise AssertionError(path)

    def fake_urlopen(url: str, *, timeout: int) -> MemoryDownload:
        assert url == f"memory://{identifier}"
        assert timeout == 180
        return MemoryDownload(encrypted)

    monkeypatch.setattr(phone_replica, "encryption_key", lambda: key)
    monkeypatch.setattr(phone_replica, "keychain_value", lambda _: "token")
    monkeypatch.setattr(phone_replica, "request_json", fake_request)
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)


def test_restore_validates_before_promoting_database(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source.sqlite3"
    with sqlite3.connect(source) as connection:
        connection.execute("PRAGMA user_version = 10")
        connection.execute("CREATE TABLE sample(value TEXT NOT NULL)")
        connection.execute("INSERT INTO sample VALUES ('complete history')")
    key = bytes(range(32))
    snapshot, encrypted = remote_snapshot(source.read_bytes(), key, 10)
    install_remote(monkeypatch, snapshot, encrypted, key)
    destination = tmp_path / "restore"

    restore(destination, "https://example.test")

    restored = destination / "sleep.sqlite3"
    assert restored.is_file()
    assert not (destination / "sleep.sqlite3.partial").exists()
    with sqlite3.connect(restored) as connection:
        assert connection.execute("PRAGMA quick_check").fetchone() == ("ok",)
        assert connection.execute("SELECT value FROM sample").fetchone() == ("complete history",)


def test_restore_rejects_schema_mismatch_without_promoting_partial(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source.sqlite3"
    with sqlite3.connect(source) as connection:
        connection.execute("PRAGMA user_version = 9")
        connection.execute("CREATE TABLE sample(value TEXT NOT NULL)")
    key = bytes(range(32))
    snapshot, encrypted = remote_snapshot(source.read_bytes(), key, 10)
    install_remote(monkeypatch, snapshot, encrypted, key)
    destination = tmp_path / "restore"

    with pytest.raises(RuntimeError, match="schema does not match"):
        restore(destination, "https://example.test")

    assert not (destination / "sleep.sqlite3").exists()
    assert not (destination / "sleep.sqlite3.partial").exists()


def test_restore_rejects_invalid_sqlite_without_promoting_partial(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    key = bytes(range(32))
    snapshot, encrypted = remote_snapshot(b"authenticated but not sqlite", key, 10)
    install_remote(monkeypatch, snapshot, encrypted, key)
    destination = tmp_path / "restore"

    with pytest.raises(sqlite3.DatabaseError):
        restore(destination, "https://example.test")

    assert not (destination / "sleep.sqlite3").exists()
    assert not (destination / "sleep.sqlite3.partial").exists()
