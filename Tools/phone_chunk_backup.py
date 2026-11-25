#!/usr/bin/env python3
"""Pull and restore the phone's progressive chunk backup (`backup/`).

The app keeps `backup/<table>/<chunk>.sqlite3` plus `manifest.json`; each chunk
holds one 65,536-row rowid range and a version bumped by triggers on every
change. `pull` copies only chunks whose version changed since the last pull, so
a routine pull is the new data, never the whole multi-gigabyte history, and it
works over Wi-Fi. `restore` rebuilds a SQLite database from the local copy and
checks per-table row counts against the manifest.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any

from whoop_config import data_root, setting

DEVICE = setting("WHOOP_DEVICE_ID", "")
BUNDLE = setting("WHOOP_BUNDLE_ID", "com.clintonst.sideload.sleep")
REMOTE = "Library/Application Support/Sleep/backup"
DEFAULT_LOCAL = data_root() / "chunk-backup"


def _devicectl(device: str, *args: str, timeout: int = 300) -> subprocess.CompletedProcess[str]:
    command = [
        "xcrun",
        "devicectl",
        "device",
        *args,
        "--device",
        device,
        "--domain-type",
        "appDataContainer",
    ]
    command += ["--domain-identifier", BUNDLE]
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)


def _copy(device: str, remote: str, destination: Path) -> bool:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name("." + destination.name + ".partial")
    result = _devicectl(
        device, "copy", "from", "--source", f"{REMOTE}/{remote}", "--destination", str(partial)
    )
    if result.returncode != 0:
        return False
    partial.chmod(0o600)
    partial.replace(destination)
    return True


def changed_chunks(remote: dict[str, Any], local: dict[str, Any] | None, root: Path) -> list[str]:
    """Chunks whose version differs from the last pulled manifest, newest first."""
    old = (local or {}).get("chunks", {})
    keys = [
        key
        for key, entry in remote.get("chunks", {}).items()
        if old.get(key, {}).get("version") != entry["version"]
        or not (root / f"{key}.sqlite3").exists()
    ]
    return sorted(keys, key=lambda k: (-int(k.rsplit("/", 1)[1]), k))


def pull(device: str, root: Path) -> dict[str, Any]:
    root.mkdir(parents=True, exist_ok=True)
    fresh = root / ".manifest.remote.json"
    if not _copy(device, "manifest.json", fresh):
        sys.exit("phone unreachable or backup not started yet")
    remote = json.loads(fresh.read_text())
    local_path = root / "manifest.json"
    local = json.loads(local_path.read_text()) if local_path.exists() else None
    pulled, failed = [], []
    merged = dict(remote)
    merged["chunks"] = dict((local or {}).get("chunks", {}))
    for key in changed_chunks(remote, local, root):
        if _copy(device, f"{key}.sqlite3", root / f"{key}.sqlite3"):
            merged["chunks"][key] = remote["chunks"][key]
            pulled.append(key)
        else:
            failed.append(key)
    local_path.write_text(json.dumps(merged, indent=1, sort_keys=True))
    fresh.unlink()
    return {"pulled": len(pulled), "failed": failed, "phone_pending": remote.get("pending", 0)}


def restore(root: Path, output: Path) -> dict[str, int]:
    """Builds `output` from the chunk copy; returns rows per table."""
    manifest = json.loads((root / "manifest.json").read_text())
    if output.exists():
        sys.exit(f"{output} exists")
    database = sqlite3.connect(output)
    try:
        for sql in manifest["tables"].values():
            database.execute(sql)
        counts: dict[str, int] = {}
        for key in sorted(manifest["chunks"]):
            table = key.rsplit("/", 1)[0]
            database.execute("ATTACH DATABASE ? AS chunk", (str(root / f"{key}.sqlite3"),))
            columns = [row[1] for row in database.execute(f'PRAGMA table_info("{table}")')]
            names = ", ".join(f'"{c}"' for c in columns)
            database.execute(
                f'INSERT INTO "{table}"(rowid, {names}) SELECT _rowid, {names} FROM chunk.rows'
            )
            database.commit()
            database.execute("DETACH DATABASE chunk")
            counts[table] = counts.get(table, 0) + manifest["chunks"][key]["rows"]
        for table, expected in counts.items():
            actual = database.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            if actual != expected:
                sys.exit(f"{table}: restored {actual} rows, manifest says {expected}")
        return counts
    finally:
        database.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pull")
    p.add_argument("--device", default=DEVICE, required=not DEVICE)
    p.add_argument("--root", type=Path, default=DEFAULT_LOCAL)
    r = sub.add_parser("restore")
    r.add_argument("--root", type=Path, default=DEFAULT_LOCAL)
    r.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "pull":
        print(json.dumps(pull(args.device, args.root)))
    else:
        print(json.dumps(restore(args.root, args.output)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
