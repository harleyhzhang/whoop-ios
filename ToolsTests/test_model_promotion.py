from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import promote_private_models as promotion
import pytest


def policy() -> dict[str, Any]:
    return {
        "modelVersion": "model-v1",
        "featureVersion": "features-v1",
        "featureCount": 2,
        "absoluteMaximum": {"mae": 2.0, "rmse": 3.0, "p90AbsoluteError": 4.0},
        "maximumRegression": {"mae": 0.1, "rmse": 0.1, "p90AbsoluteError": 0.1},
    }


def model(mae: float = 1.0, rmse: float = 2.0, p90: float = 3.0) -> dict[str, Any]:
    return {
        "version": "model-v1",
        "featureVersion": "features-v1",
        "featureCount": 2,
        "forwardValidation": {"mae": mae, "rmse": rmse, "p90AbsoluteError": p90},
    }


def test_candidate_policy_accepts_finite_nonregressing_metrics() -> None:
    report = promotion.validate_candidate("sleep", model(), model(1.05, 2.05, 3.05), policy())
    assert report == {"mae": 1.0, "rmse": 2.0, "p90AbsoluteError": 3.0}


@pytest.mark.parametrize(
    ("candidate", "message"),
    [
        (model(mae=2.1), "absolute limit"),
        (model(mae=1.2), "regressed"),
        ({**model(), "featureCount": 3}, "featureCount"),
        (model(mae=float("nan")), "non-finite"),
    ],
)
def test_candidate_policy_rejects_invalid_promotions(
    candidate: dict[str, Any], message: str
) -> None:
    with pytest.raises(promotion.PromotionError, match=message):
        promotion.validate_candidate("sleep", candidate, model(), policy())


def test_promote_replaces_both_models(tmp_path: Path) -> None:
    private_root = tmp_path / "private"
    candidate_root = tmp_path / "candidates"
    private_root.mkdir()
    candidate_root.mkdir()
    candidates: dict[str, Path] = {}
    for kind, filename in promotion.MODEL_FILENAMES.items():
        (private_root / filename).write_text(json.dumps({"version": "old"}), encoding="utf-8")
        candidate = candidate_root / filename
        candidate.write_text(json.dumps({"version": f"new-{kind}"}), encoding="utf-8")
        candidates[kind] = candidate

    promotion.promote(private_root, candidates)

    for kind, filename in promotion.MODEL_FILENAMES.items():
        assert json.loads((private_root / filename).read_text(encoding="utf-8"))["version"] == (
            f"new-{kind}"
        )
