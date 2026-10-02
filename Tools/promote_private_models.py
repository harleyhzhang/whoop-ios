#!/usr/bin/env python3
"""Backtest, validate, Swift-check, and atomically promote private models."""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, cast

from phone_shipping_core import validate_recovery_model, validate_sleep_model

MODEL_FILENAMES = {
    "sleep": "whoop-score-model.json",
    "recovery": "whoop-recovery-model.json",
}
SUPPORTING_ASSETS = (
    "whoop-history.json",
    "whoop-official-metrics.json",
    "whoop-official-archive.sqlite3",
)


class PromotionError(RuntimeError):
    pass


def load_object(path: Path, description: str) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as source:
            value = json.load(source)
    except (OSError, json.JSONDecodeError) as error:
        raise PromotionError(f"Cannot read {description} at {path}: {error}") from error
    if not isinstance(value, dict):
        raise PromotionError(f"{description} must be a JSON object.")
    return cast(dict[str, Any], value)


def require_finite(value: object, description: str) -> None:
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return
    if isinstance(value, (int, float)):
        if not math.isfinite(float(value)):
            raise PromotionError(f"{description} contains a non-finite number.")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            require_finite(item, f"{description}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            require_finite(item, f"{description}.{key}")
        return
    raise PromotionError(f"{description} contains an unsupported JSON value.")


def finite_metric(payload: dict[str, Any], key: str, description: str) -> float:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PromotionError(f"{description}.{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise PromotionError(f"{description}.{key} must be finite.")
    return result


def validate_candidate(
    kind: str,
    candidate: dict[str, Any],
    baseline: dict[str, Any],
    policy: dict[str, Any],
) -> dict[str, float]:
    require_finite(candidate, f"{kind} candidate")
    for key in ("modelVersion", "featureVersion", "featureCount"):
        candidate_key = "version" if key == "modelVersion" else key
        if candidate.get(candidate_key) != policy.get(key):
            raise PromotionError(
                f"{kind} {candidate_key} is {candidate.get(candidate_key)!r}; "
                f"expected {policy.get(key)!r}."
            )
    validation = candidate.get("forwardValidation")
    baseline_validation = baseline.get("forwardValidation")
    if not isinstance(validation, dict) or not isinstance(baseline_validation, dict):
        raise PromotionError(f"{kind} model is missing chronological forwardValidation metrics.")
    results: dict[str, float] = {}
    absolute = cast(dict[str, float], policy["absoluteMaximum"])
    regression = cast(dict[str, float], policy["maximumRegression"])
    for metric, maximum in absolute.items():
        candidate_value = finite_metric(validation, metric, f"{kind}.forwardValidation")
        baseline_value = finite_metric(
            baseline_validation,
            metric,
            f"current {kind}.forwardValidation",
        )
        if candidate_value > float(maximum):
            raise PromotionError(
                f"{kind} {metric} {candidate_value:.6f} exceeds absolute limit {maximum:.6f}."
            )
        allowed = baseline_value + float(regression[metric])
        if candidate_value > allowed:
            raise PromotionError(
                f"{kind} {metric} regressed from {baseline_value:.6f} to "
                f"{candidate_value:.6f}; limit is {allowed:.6f}."
            )
        results[metric] = candidate_value
    return results


def execute(arguments: list[str], root: Path, environment: dict[str, str] | None = None) -> None:
    print(f"+ {' '.join(arguments)}")
    completed = subprocess.run(arguments, cwd=root, env=environment, check=False)
    if completed.returncode != 0:
        raise PromotionError(f"Command failed ({completed.returncode}): {' '.join(arguments)}")


def build_candidates(
    root: Path,
    archive: Path,
    official_metrics: Path,
    output: Path,
) -> dict[str, Path]:
    candidates = {kind: output / filename for kind, filename in MODEL_FILENAMES.items()}
    execute(
        [
            sys.executable,
            "Tools/backtest_sleep_score.py",
            str(archive),
            "--model-output",
            str(candidates["sleep"]),
        ],
        root,
    )
    execute(
        [
            sys.executable,
            "Tools/backtest_recovery_score.py",
            str(archive),
            str(official_metrics),
            "--model-output",
            str(candidates["recovery"]),
        ],
        root,
    )
    validate_sleep_model(candidates["sleep"])
    validate_recovery_model(candidates["recovery"])
    return candidates


def verify_swift_candidates(root: Path, private_root: Path, candidates: dict[str, Path]) -> None:
    with tempfile.TemporaryDirectory(prefix="whoop-model-stage.") as staging_name:
        staging = Path(staging_name)
        for filename in SUPPORTING_ASSETS:
            source = private_root / filename
            if not source.is_file():
                raise PromotionError(f"Missing required private asset: {source}")
            (staging / filename).symlink_to(source)
        for kind, filename in MODEL_FILENAMES.items():
            shutil.copy2(candidates[kind], staging / filename)
        environment = os.environ.copy()
        environment["WHOOP_PRIVATE_SEED_ROOT"] = str(staging)
        execute(["Tools/verify_private_models.sh"], root, environment)


def promote(private_root: Path, candidates: dict[str, Path]) -> None:
    originals: dict[Path, bytes] = {}
    staged: dict[Path, Path] = {}
    for kind, filename in MODEL_FILENAMES.items():
        destination = private_root / filename
        if not destination.is_file():
            raise PromotionError(f"Current private model is missing: {destination}")
        originals[destination] = destination.read_bytes()
        descriptor, name = tempfile.mkstemp(prefix=f".{filename}.", dir=private_root)
        os.close(descriptor)
        temporary = Path(name)
        shutil.copyfile(candidates[kind], temporary)
        staged[destination] = temporary
    replaced: list[Path] = []
    try:
        for destination, temporary in staged.items():
            os.replace(temporary, destination)
            replaced.append(destination)
    except OSError as error:
        for destination in replaced:
            destination.write_bytes(originals[destination])
        raise PromotionError(
            f"Could not promote the model pair; prior files restored: {error}"
        ) from error
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--private-root", required=True, type=Path)
    parser.add_argument("--official-metrics", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    archive = args.archive.expanduser().resolve()
    private_root = args.private_root.expanduser().resolve()
    official_metrics = (
        args.official_metrics.expanduser().resolve()
        if args.official_metrics
        else private_root / "whoop-official-metrics.json"
    )
    policy = load_object(root / "Tools/model_promotion_policy.json", "promotion policy")
    execute([sys.executable, "Tools/generate_model_features.py", "--check"], root)
    execute(
        [sys.executable, "-m", "pytest", "ToolsTests/test_model_features.py", "-q"],
        root,
    )
    with tempfile.TemporaryDirectory(prefix="whoop-model-promotion.") as output_name:
        candidates = build_candidates(root, archive, official_metrics, Path(output_name))
        reports: dict[str, dict[str, float]] = {}
        for kind, candidate_path in candidates.items():
            candidate = load_object(candidate_path, f"candidate {kind} model")
            baseline = load_object(private_root / MODEL_FILENAMES[kind], f"current {kind} model")
            reports[kind] = validate_candidate(
                kind,
                candidate,
                baseline,
                cast(dict[str, Any], policy[kind]),
            )
        verify_swift_candidates(root, private_root, candidates)
        if not args.dry_run:
            promote(private_root, candidates)
    status = "validated" if args.dry_run else "promoted"
    print(json.dumps({"status": status, "metrics": reports}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PromotionError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
