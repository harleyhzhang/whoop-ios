from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from phone_chunk_backup import changed_chunks, restore

SCHEMA = "CREATE TABLE t (id TEXT PRIMARY KEY, value INTEGER)"


def _chunk(path: Path, rows: list[tuple[int, str, int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    database = sqlite3.connect(path)
    database.execute("CREATE TABLE rows (_rowid INTEGER, id TEXT, value INTEGER)")
    database.executemany("INSERT INTO rows VALUES (?, ?, ?)", rows)
    database.commit()
    database.close()


def test_only_changed_or_missing_chunks_are_pulled_newest_first(tmp_path: Path) -> None:
    _chunk(tmp_path / "t/0.sqlite3", [])
    remote = {"chunks": {"t/0": {"version": 1}, "t/1": {"version": 3}, "t/2": {"version": 1}}}
    local = {"chunks": {"t/0": {"version": 1}, "t/1": {"version": 2}}}
    assert changed_chunks(remote, local, tmp_path) == ["t/2", "t/1"]


def test_restore_rebuilds_rows_and_checks_counts(tmp_path: Path) -> None:
    _chunk(tmp_path / "t/0.sqlite3", [(1, "a", 1), (2, "b", 2)])
    _chunk(tmp_path / "t/1.sqlite3", [(65537, "c", 3)])
    manifest = {
        "tables": {"t": SCHEMA},
        "chunks": {"t/0": {"version": 1, "rows": 2}, "t/1": {"version": 1, "rows": 1}},
    }
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    output = tmp_path / "restored.sqlite3"
    assert restore(tmp_path, output) == {"t": 3}
    database = sqlite3.connect(output)
    assert database.execute("SELECT rowid, id FROM t ORDER BY rowid").fetchall() == [
        (1, "a"),
        (2, "b"),
        (65537, "c"),
    ]
    database.close()
