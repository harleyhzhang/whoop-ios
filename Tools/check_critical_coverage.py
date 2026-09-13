#!/usr/bin/env python3
"""Enforce coverage floors for data, protocol, and scoring modules."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any, cast


def coverage_by_relative_path(payload: object, root: Path) -> dict[str, float]:
    if not isinstance(payload, list):
        raise ValueError("xccov payload must be a target list")
    result: dict[str, float] = {}
    for target in payload:
        if not isinstance(target, dict) or not isinstance(target.get("files"), list):
            continue
        for item in target["files"]:
            if not isinstance(item, dict):
                continue
            path = item.get("path")
            coverage = item.get("lineCoverage")
            if (
                not isinstance(path, str)
                or isinstance(coverage, bool)
                or not isinstance(coverage, (int, float))
            ):
                continue
            try:
                relative = str(Path(path).resolve().relative_to(root.resolve()))
            except ValueError:
                continue
            result[relative] = float(coverage) * 100
    return result


def violations(actual: dict[str, float], expected: dict[str, float]) -> list[str]:
    failures: list[str] = []
    for path, minimum in sorted(expected.items()):
        coverage = actual.get(path)
        if coverage is None:
            failures.append(f"{path}: missing from the coverage report")
        elif coverage < minimum:
            failures.append(f"{path}: {coverage:.2f}% is below {minimum:.2f}%")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with (root / "Tools/critical_coverage.json").open(encoding="utf-8") as source:
        contract = cast(dict[str, Any], json.load(source))
    target = str(contract["target"])
    completed = subprocess.run(
        [
            "xcrun",
            "xccov",
            "view",
            "--report",
            "--files-for-target",
            target,
            "--json",
            str(args.result_bundle),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        print(completed.stderr.strip() or "Could not read critical-module coverage.")
        return 1
    try:
        payload = json.loads(completed.stdout)
        actual = coverage_by_relative_path(payload, root)
    except (json.JSONDecodeError, ValueError) as error:
        print(f"Could not parse critical-module coverage: {error}")
        return 1
    expected = {
        key: float(value) for key, value in cast(dict[str, float], contract["files"]).items()
    }
    failures = violations(actual, expected)
    if failures:
        print("Critical-module coverage failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("Critical-module coverage:")
    for path, minimum in sorted(expected.items()):
        print(f"- {path}: {actual[path]:.2f}% (minimum {minimum:.2f}%)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
