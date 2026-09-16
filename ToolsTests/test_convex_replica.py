import os
from pathlib import Path

from convex_replica import latest_snapshot, load_site_url


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
