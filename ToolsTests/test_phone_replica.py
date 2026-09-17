from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from cryptography.exceptions import InvalidTag
from phone_replica import chunk_id, decrypt_chunk, describe, encrypt_chunk


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
