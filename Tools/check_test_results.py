#!/usr/bin/env python3
"""Reject empty, failed, skipped, or silently unmatched Xcode test selections."""

from __future__ import annotations

import json
import subprocess
import sys
from typing import Any


def passed_identifiers(payload: dict[str, Any]) -> set[str]:
    passed: set[str] = set()

    def visit(node: dict[str, Any], bundle: str = "") -> None:
        if node.get("nodeType") in {"Unit test bundle", "UI test bundle"}:
            bundle = str(node["name"]).removesuffix(".xctest")
        if node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
            identifier = str(node["nodeIdentifier"]).removesuffix("()")
            passed.add(f"{bundle}/{identifier}")
        for child in node.get("children", []):
            visit(child, bundle)

    for node in payload.get("testNodes", []):
        visit(node)
    return passed


def missing_selections(passed: set[str], selections: list[str]) -> list[str]:
    return [
        selection
        for selection in selections
        if not any(test == selection or test.startswith(selection + "/") for test in passed)
    ]


def main() -> int:
    path = sys.argv[1]

    def read(kind: str) -> dict[str, Any]:
        return dict(
            json.loads(
                subprocess.check_output(
                    ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", path],
                    text=True,
                )
            )
        )

    summary = read("summary")
    if summary.get("failedTests", 0) or summary.get("skippedTests", 0):
        raise SystemExit("Tests must finish with no failures or skips.")
    passed = passed_identifiers(read("tests"))
    if not passed:
        raise SystemExit("No passing test cases were executed.")
    selections = [
        arg.removeprefix("-only-testing:").removesuffix("()")
        for arg in sys.argv[2:]
        if arg.startswith("-only-testing:")
    ]
    missing = missing_selections(passed, selections)
    if missing:
        raise SystemExit("Requested tests did not execute successfully: " + ", ".join(missing))
    print(f"Verified {len(passed)} passing test cases and all requested selections.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
