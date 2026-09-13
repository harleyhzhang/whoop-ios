from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import full_gate_attestation as attestation
import pytest
import toolchain
from check_critical_coverage import coverage_by_relative_path, violations


def test_attestation_is_keyed_by_head_tree_and_toolchain(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state = {"head": "a" * 40, "tree": "b" * 40, "toolchain": "c" * 64}
    monkeypatch.setattr(attestation, "repository_state", lambda _: state)
    monkeypatch.setattr(attestation, "cache_directory", lambda _: tmp_path)

    assert attestation.record(tmp_path)
    assert attestation.check(tmp_path, timedelta(hours=24))

    state = {**state, "tree": "d" * 40}
    monkeypatch.setattr(attestation, "repository_state", lambda _: state)
    assert not attestation.check(tmp_path, timedelta(hours=24))


def test_attestation_freshness_rejects_expired_or_unzoned_records() -> None:
    now = datetime.now(UTC)
    assert attestation.is_fresh(
        {"completedAt": (now - timedelta(minutes=5)).isoformat()},
        now,
        timedelta(hours=1),
    )
    assert not attestation.is_fresh(
        {"completedAt": (now - timedelta(hours=2)).isoformat()},
        now,
        timedelta(hours=1),
    )
    assert not attestation.is_fresh(
        {"completedAt": datetime.now().replace(tzinfo=None).isoformat()},
        now,
        timedelta(hours=1),
    )
    assert not attestation.is_fresh(
        {"completedAt": (now + timedelta(minutes=1)).isoformat()},
        now,
        timedelta(hours=1),
    )


def test_toolchain_mismatch_reports_every_contract_boundary() -> None:
    contract: dict[str, Any] = {
        "xcode": {"version": "1", "build": "2", "iphoneOSSDK": "3", "deviceCtl": "4"},
        "simulatorRuntime": {"version": "5", "build": "6", "identifier": "runtime"},
        "python": "7",
        "homebrew": {"jq": "8"},
    }
    observed: dict[str, Any] = {
        "xcode": {"version": "wrong", "build": "2", "iphoneOSSDK": "3", "deviceCtl": "4"},
        "simulatorRuntimes": [],
        "python": "wrong",
        "homebrew": {"jq": ["wrong"]},
    }

    problems = toolchain.mismatches(contract, observed)

    assert len(problems) == 4
    assert any("xcode.version" in problem for problem in problems)
    assert any("simulatorRuntime" in problem for problem in problems)
    assert any("python" in problem for problem in problems)
    assert any("homebrew.jq" in problem for problem in problems)


def test_critical_coverage_is_path_scoped_and_fails_closed(tmp_path: Path) -> None:
    source = tmp_path / "SleepApp/ScoreModels.swift"
    payload = [{"files": [{"path": str(source), "lineCoverage": 0.95}]}]

    actual = coverage_by_relative_path(payload, tmp_path)

    assert actual == {"SleepApp/ScoreModels.swift": 95.0}
    assert not violations(actual, {"SleepApp/ScoreModels.swift": 94.0})
    assert violations(actual, {"SleepApp/ScoreModels.swift": 96.0})
    assert violations(actual, {"WhoopHandshakeApp/WhoopStore.swift": 80.0})
