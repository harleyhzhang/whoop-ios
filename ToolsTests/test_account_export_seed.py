from __future__ import annotations

import csv
import io
import json
import sqlite3
import zipfile
import zlib
from datetime import UTC, datetime
from pathlib import Path

import make_account_export_seed as seed
import pytest


def cycle(start: str = "2026-01-01 23:00:00", wake: str = "2026-01-02 07:00:00") -> dict[str, str]:
    row = dict.fromkeys(set(seed.HEALTH_FIELDS.values()) | set(seed.OFFICIAL_FIELDS.values()), "50")
    row.update(
        {
            "Cycle start time": start,
            "Cycle timezone": "UTC-05:00",
            "Sleep onset": start,
            "Wake onset": wake,
            "Day Strain": "12.3",
            "Asleep duration (min)": "450",
            "Sleep need (min)": "480",
        }
    )
    return row


def dataset(cycles: list[dict[str, str]]) -> dict[str, list[dict[str, str]]]:
    return {
        seed.FILES[0]: cycles,
        seed.FILES[1]: [{**r, "Nap": "false"} for r in cycles if r["Wake onset"]],
        seed.FILES[2]: [{"Activity name": "Synthetic workout"}],
        seed.FILES[3]: [{"Notes": "Synthetic journal"}],
    }


def write_zip(path: Path, rows: dict[str, list[dict[str, str]]]) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for name, records in rows.items():
            stream = io.StringIO()
            writer = csv.DictWriter(stream, fieldnames=list(records[0]))
            writer.writeheader()
            writer.writerows(records)
            archive.writestr(name, stream.getvalue())


def test_wall_time_and_wake_day_do_not_follow_host_timezone() -> None:
    assert seed.instant("2026-01-02 00:30:00", "UTC+08:00").astimezone(UTC) == datetime(
        2026, 1, 1, 16, 30, tzinfo=UTC
    )
    assert seed.instant("2026-01-02 00:30:00", "UTCZ").utcoffset().total_seconds() == 0  # type: ignore[union-attr]
    r = cycle("2026-01-01 20:00:00", "2026-01-02 00:30:00")
    r["Cycle timezone"] = "UTC+08:00"
    history, _, _ = seed.project(dataset([r]), "synthetic", "2026-01-03T00:00:00Z")
    assert history[0]["dateKey"] == "2026-01-02"
    assert history[0]["sleepEndAt"] == "2026-01-01T16:30:00Z"
    with pytest.raises(ValueError):
        seed.instant("2026-01-02 00:30:00", "Toronto")


def test_collision_uses_one_coherent_cycle_and_preserves_missing_values() -> None:
    first = cycle()
    later = cycle("2026-01-02 09:00:00", "2026-01-02 13:00:00")
    later["Recovery score %"] = "0"
    later["Sleep consistency %"] = ""
    no_sleep = cycle("2026-01-02 23:00:00", "")
    no_sleep["Sleep onset"] = ""
    history, daily, collisions = seed.project(dataset([first, later, no_sleep]), "test", "test")
    assert len(history) == len(daily) == 1
    assert daily[0]["officialRecoveryScore"] == 0
    assert history[0]["sleepConsistencyPercentage"] is None
    assert history[0]["sleepEndAt"] == "2026-01-02T18:00:00Z"
    assert "officialSteps" not in daily[0]
    assert "cycleID" not in history[0] and "sleepID" not in history[0]
    assert collisions[0]["selectedCSVRow"] == 3
    assert set(collisions[0]["preservedOtherCSVRows"]) == {2, 4}


def test_archive_roundtrip_and_projection_hashes(tmp_path: Path) -> None:
    source = tmp_path / "source.zip"
    rows = dataset([cycle()])
    rows[seed.FILES[1]].append({**cycle(), "Nap": "true"})
    write_zip(source, rows)
    out = tmp_path / "seed"
    report = seed.build(source, out, "2026-01-03T00:00:00Z")
    assert report["napRowsPreserved"] == 1
    assert report["historyDays"] == 1
    metrics = json.loads((out / "whoop-official-metrics.json").read_text())
    sidecar = out / "whoop-official-archive.sqlite3"
    assert metrics["sourceDatabaseSHA256"] == seed.digest(sidecar.read_bytes())
    with sqlite3.connect(sidecar) as db:
        files = db.execute("SELECT name, sha256, raw_bytes, compressed_body FROM export_file")
        restored: dict[str, bytes] = {}
        for name, sha, size, body in files:
            restored[name] = zlib.decompress(body)
            assert seed.digest(restored[name]) == sha
            assert len(restored[name]) == size
        assert restored["original.zip"] == source.read_bytes()
        assert seed.digest(restored["manifest.json"]) == metrics["sourceManifestSHA256"]
        source_sha = metrics["daily"][0]["sourceRecoverySHA256"]
        payload = db.execute(
            "SELECT payload_json FROM export_row WHERE sha256=?", (source_sha,)
        ).fetchone()[0]
        assert json.loads(payload) == cycle()
        assert db.execute("SELECT COUNT(*) FROM export_row").fetchone()[0] == 5
    with pytest.raises(FileExistsError):
        seed.build(source, out, "2026-01-03T00:00:00Z")


@pytest.mark.parametrize("bad", ["nan", "inf", "-1", "22"])
def test_invalid_strain_rejected_even_in_unselected_cycle(bad: str) -> None:
    row = cycle()
    row["Day Strain"] = bad
    with pytest.raises(ValueError):
        seed.project(
            dataset([row, cycle("2026-01-02 09:00:00", "2026-01-02 13:00:00")]), "test", "test"
        )


def test_ambiguous_and_mismatched_sources_rejected() -> None:
    row = cycle()
    with pytest.raises(ValueError, match="Duplicate cycle"):
        seed.project(dataset([row, row]), "test", "test")
    rows = dataset([row])
    rows[seed.FILES[1]][0]["Wake onset"] = "2026-01-02 08:00:00"
    with pytest.raises(ValueError, match="disagree"):
        seed.project(rows, "test", "test")
    rows = dataset([row, cycle("2026-01-01 22:00:00")])
    with pytest.raises(ValueError, match="Ambiguous"):
        seed.project(rows, "test", "test")


def test_failed_projection_leaves_no_output(tmp_path: Path) -> None:
    source = tmp_path / "bad.zip"
    row = cycle()
    row["Day Strain"] = "nan"
    write_zip(source, dataset([row]))
    with pytest.raises(ValueError):
        seed.build(source, tmp_path / "output", "2026-01-03T00:00:00Z")
    assert not (tmp_path / "output").exists()
