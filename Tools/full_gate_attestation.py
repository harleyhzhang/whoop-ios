#!/usr/bin/env python3
"""Record or reuse a clean-tree full-gate result for one exact toolchain."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, cast

DEFAULT_MAX_AGE_HOURS = 24


def run(root: Path, arguments: list[str]) -> str:
    completed = subprocess.run(
        arguments,
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or "no diagnostics"
        raise RuntimeError(f"Cannot run {' '.join(arguments)}: {details}")
    return completed.stdout.strip()


def repository_state(root: Path) -> dict[str, str]:
    if run(root, ["git", "status", "--porcelain", "--untracked-files=all"]):
        raise RuntimeError("the worktree is dirty")
    return {
        "head": run(root, ["git", "rev-parse", "HEAD"]),
        "tree": run(root, ["git", "rev-parse", "HEAD^{tree}"]),
        "toolchain": run(
            root,
            ["uv", "run", "--frozen", "python", "Tools/toolchain.py", "--fingerprint"],
        ),
    }


def attestation_key(state: dict[str, str]) -> str:
    encoded = json.dumps(state, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def cache_directory(root: Path) -> Path:
    common = Path(run(root, ["git", "rev-parse", "--git-common-dir"]))
    if not common.is_absolute():
        common = (root / common).resolve()
    return common / "whoop-full-gate-attestations"


def attestation_path(root: Path, state: dict[str, str]) -> Path:
    return cache_directory(root) / f"{attestation_key(state)}.json"


def atomic_write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".attestation-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(payload, destination, sort_keys=True, separators=(",", ":"))
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def record(root: Path) -> bool:
    try:
        state = repository_state(root)
    except RuntimeError as error:
        print(f"Full-gate attestation not cached: {error}.")
        return False
    payload: dict[str, Any] = {
        "schemaVersion": 1,
        **state,
        "completedAt": datetime.now(UTC).isoformat(timespec="seconds"),
    }
    atomic_write(attestation_path(root, state), payload)
    print(f"Cached full-gate attestation for {state['head'][:12]}.")
    return True


def is_fresh(payload: dict[str, Any], now: datetime, maximum_age: timedelta) -> bool:
    try:
        completed = datetime.fromisoformat(str(payload["completedAt"]))
    except (KeyError, ValueError):
        return False
    if completed.tzinfo is None:
        return False
    age = now - completed
    return timedelta() <= age <= maximum_age


def check(root: Path, maximum_age: timedelta) -> bool:
    try:
        state = repository_state(root)
    except RuntimeError as error:
        print(f"No reusable full-gate attestation: {error}.")
        return False
    path = attestation_path(root, state)
    if not path.is_file():
        print(f"No reusable full-gate attestation for {state['head'][:12]}.")
        return False
    try:
        payload = cast(dict[str, Any], json.loads(path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError):
        print("No reusable full-gate attestation: cached record is unreadable.")
        return False
    expected = {"schemaVersion": 1, **state}
    if any(payload.get(key) != value for key, value in expected.items()):
        print("No reusable full-gate attestation: cached identity does not match.")
        return False
    if not is_fresh(payload, datetime.now(UTC), maximum_age):
        print("No reusable full-gate attestation: cached record expired.")
        return False
    print(f"Reusing full-gate attestation for {state['head'][:12]} ({state['toolchain'][:12]}).")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "record"))
    parser.add_argument(
        "--maximum-age-hours",
        type=int,
        default=int(os.environ.get("WHOOP_ATTESTATION_MAX_AGE_HOURS", DEFAULT_MAX_AGE_HOURS)),
    )
    args = parser.parse_args()
    root = Path(run(Path.cwd(), ["git", "rev-parse", "--show-toplevel"])).resolve()
    if args.command == "record":
        record(root)
        return 0
    return 0 if check(root, timedelta(hours=args.maximum_age_hours)) else 1


if __name__ == "__main__":
    raise SystemExit(main())
