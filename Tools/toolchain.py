#!/usr/bin/env python3
"""Validate and fingerprint the exact locally tested WHOOP toolchain."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any, cast


class ToolchainError(RuntimeError):
    pass


def command(arguments: list[str], cwd: Path | None = None) -> str:
    completed = subprocess.run(
        arguments,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or "no diagnostics"
        raise ToolchainError(f"Cannot run {' '.join(arguments)}: {details}")
    return completed.stdout.strip()


def load_contract(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as source:
        return cast(dict[str, Any], json.load(source))


def observe(contract: dict[str, Any], root: Path | None = None) -> dict[str, Any]:
    xcode_lines = command(["xcodebuild", "-version"]).splitlines()
    if len(xcode_lines) != 2 or not xcode_lines[0].startswith("Xcode "):
        raise ToolchainError("Unexpected xcodebuild -version output.")
    formulas = sorted(cast(dict[str, str], contract["homebrew"]))
    brew_payload = cast(
        dict[str, Any],
        json.loads(command(["brew", "info", "--json=v2", *formulas])),
    )
    installed = {
        str(formula["name"]): [str(item["version"]) for item in formula.get("installed", [])]
        for formula in cast(list[dict[str, Any]], brew_payload["formulae"])
    }
    runtime_payload = cast(
        dict[str, Any],
        json.loads(command(["xcrun", "simctl", "list", "runtimes", "available", "-j"])),
    )
    runtimes = [
        {
            "version": str(runtime.get("version", "")),
            "build": str(runtime.get("buildversion", "")),
            "identifier": str(runtime.get("identifier", "")),
        }
        for runtime in cast(list[dict[str, Any]], runtime_payload["runtimes"])
        if runtime.get("isAvailable")
    ]
    python_version = command(
        ["uv", "run", "--frozen", "python", "--version"],
        cwd=root,
    )
    return {
        "xcode": {
            "version": xcode_lines[0].removeprefix("Xcode "),
            "build": xcode_lines[1].removeprefix("Build version "),
            "iphoneOSSDK": command(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]),
            "deviceCtl": command(["xcrun", "devicectl", "--version"]),
        },
        "simulatorRuntimes": runtimes,
        "python": python_version.removeprefix("Python "),
        "homebrew": installed,
    }


def mismatches(contract: dict[str, Any], observed: dict[str, Any]) -> list[str]:
    problems: list[str] = []
    expected_xcode = cast(dict[str, str], contract["xcode"])
    actual_xcode = cast(dict[str, str], observed["xcode"])
    for key, expected in expected_xcode.items():
        actual = actual_xcode.get(key)
        if actual != expected:
            problems.append(f"xcode.{key}: expected {expected}, found {actual or 'missing'}")
    expected_runtime = cast(dict[str, str], contract["simulatorRuntime"])
    runtimes = cast(list[dict[str, str]], observed["simulatorRuntimes"])
    if expected_runtime not in runtimes:
        problems.append(
            "simulatorRuntime: expected "
            f"{expected_runtime['version']} ({expected_runtime['build']}), not installed"
        )
    if observed["python"] != contract["python"]:
        problems.append(f"python: expected {contract['python']}, found {observed['python']}")
    actual_brew = cast(dict[str, list[str]], observed["homebrew"])
    for formula, expected in cast(dict[str, str], contract["homebrew"]).items():
        versions = actual_brew.get(formula, [])
        if expected not in versions:
            problems.append(
                f"homebrew.{formula}: expected installed version {expected}, "
                f"found {', '.join(versions) or 'missing'}"
            )
    return problems


def fingerprint(observed: dict[str, Any]) -> str:
    encoded = json.dumps(observed, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fingerprint", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    contract = load_contract(root / "Tools/toolchain.json")
    current = observe(contract, root)
    problems = mismatches(contract, current)
    if problems:
        print("Toolchain differs from Tools/toolchain.json:")
        for problem in problems:
            print(f"- {problem}")
        print("Install the recorded versions or intentionally refresh and verify the contract.")
        return 1
    if args.json:
        print(json.dumps(current, indent=2, sort_keys=True))
    elif args.fingerprint:
        print(fingerprint(current))
    else:
        print(
            "Toolchain matches: "
            f"Xcode {cast(dict[str, str], current['xcode'])['version']} "
            f"({cast(dict[str, str], current['xcode'])['build']}), "
            f"iPhoneOS SDK {cast(dict[str, str], current['xcode'])['iphoneOSSDK']}."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
