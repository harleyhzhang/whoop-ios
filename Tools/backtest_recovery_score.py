#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.3.5", "scikit-learn==1.7.2"]
# ///
"""Backtest and export an account-specific WHOOP-compatible Recovery model.

The feature contract intentionally uses only fields the independent app can
continue producing: local sleep features, HRV, RHR, Steps, and past-only
history. The official WHOOP Recovery score is retained solely as the target.
Fitted parameters are private health data and must be written outside Git.
"""

from __future__ import annotations

import argparse
import json
from datetime import date
from pathlib import Path
from typing import Any, cast

import backtest_sleep_score as sleep_model
import numpy as np
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.impute import SimpleImputer
from sklearn.linear_model import Ridge
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

FEATURE_VERSION = "whoop_local_recovery_features_v1"
MODEL_VERSION = "whoop5_local_recovery_v1_gbt_ridge"
FEATURE_COUNT = 169
BOOSTED_WEIGHT = 0.70


def load_records(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as source:
        payload = cast(dict[str, Any], json.load(source))
    return cast(list[dict[str, Any]], payload["records"])


def target_rows(archive: Path) -> tuple[dict[date, float], dict[date, float], dict[date, float]]:
    sleeps = {
        int(row["cycle_id"]): row
        for row in load_records(archive / "sleeps-combined.json")
        if not row.get("nap") and row.get("score_state") == "SCORED"
    }
    targets: dict[date, float] = {}
    hrv: dict[date, float] = {}
    rhr: dict[date, float] = {}
    for recovery in load_records(archive / "recoveries-combined.json"):
        if recovery.get("score_state") != "SCORED":
            continue
        sleep = sleeps.get(int(recovery["cycle_id"]))
        if not sleep:
            continue
        day = (
            sleep_model.parse_instant(sleep["end"])
            .astimezone(sleep_model.local_zone(sleep["timezone_offset"]))
            .date()
        )
        score = recovery["score"]
        targets[day] = float(score["recovery_score"])
        hrv[day] = float(score["hrv_rmssd_milli"])
        rhr[day] = float(score["resting_heart_rate"])
    return targets, hrv, rhr


def official_steps(path: Path) -> dict[date, float]:
    with path.open(encoding="utf-8") as source:
        daily = json.load(source)["daily"]
    return {
        date.fromisoformat(row["dateKey"]): float(row["officialSteps"])
        for row in daily
        if row.get("officialSteps") is not None
    }


def recent_value(mapping: dict[date, float], day: date, fallback: float) -> float:
    return float(mapping.get(day, fallback))


def recovery_features(
    nights: list[dict[str, Any]],
    index: int,
    hrv: dict[date, float],
    rhr: dict[date, float],
    steps: dict[date, float],
) -> list[float]:
    current_night = nights[index]
    current_day = current_night["date"]
    values = sleep_model.local_features(nights, index)
    current = [
        hrv.get(current_day, np.nan),
        rhr.get(current_day, np.nan),
        steps.get(current_day, np.nan),
        float(current_night["target"]),
    ]
    values.extend(current)

    for lag in range(1, 8):
        prior = nights[index - lag] if index >= lag else current_night
        gap = (current_day - prior["date"]).days if index >= lag else 0
        values.extend(
            [
                recent_value(hrv, prior["date"], current[0]),
                recent_value(rhr, prior["date"], current[1]),
                recent_value(steps, prior["date"], current[2]),
                float(prior["target"]),
                float(gap),
            ]
        )

    for window in (7, 14, 30, 60):
        prior_nights = nights[max(0, index - window) : index]
        sleep_scores = {night["date"]: float(night["target"]) for night in prior_nights}
        for mapping, current_value in (
            (hrv, current[0]),
            (rhr, current[1]),
            (steps, current[2]),
            (sleep_scores, current[3]),
        ):
            history = np.asarray(
                [mapping.get(night["date"], np.nan) for night in prior_nights], dtype=float
            )
            history = history[np.isfinite(history)]
            mean = float(history.mean()) if len(history) else current_value
            standard_deviation = float(history.std()) if len(history) else 0.0
            values.extend(
                [
                    mean,
                    standard_deviation,
                    current_value - mean,
                    current_value / mean if mean else 1.0,
                    (current_value - mean) / standard_deviation if standard_deviation else 0.0,
                ]
            )
    if len(values) != FEATURE_COUNT:
        raise RuntimeError(f"Recovery feature contract changed unexpectedly: {len(values)}")
    return [float(value) for value in values]


def boosted_model() -> GradientBoostingRegressor:
    return GradientBoostingRegressor(
        n_estimators=350,
        max_depth=2,
        min_samples_leaf=6,
        learning_rate=0.02,
        loss="huber",
        random_state=3,
    )


def ridge_model() -> Any:
    return make_pipeline(SimpleImputer(strategy="median"), StandardScaler(), Ridge(alpha=1))


def chronological_validation(inputs: np.ndarray, targets: np.ndarray) -> dict[str, float]:
    observed: list[float] = []
    predicted: list[float] = []
    starts = (180, 210, 240, 270)
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(targets)
        train_inputs = inputs[:start]
        train_targets = targets[:start]
        test_inputs = inputs[start:end]
        imputer = SimpleImputer(strategy="median").fit(train_inputs)
        boosted = boosted_model().fit(imputer.transform(train_inputs), train_targets)
        ridge = ridge_model().fit(train_inputs, train_targets)
        fold_prediction = BOOSTED_WEIGHT * boosted.predict(imputer.transform(test_inputs))
        fold_prediction += (1 - BOOSTED_WEIGHT) * ridge.predict(test_inputs)
        observed.extend(targets[start:end])
        predicted.extend(np.clip(fold_prediction, 0, 100))

    actual = np.asarray(observed)
    estimate = np.asarray(predicted)
    absolute = np.abs(actual - estimate)
    return {
        "mae": float(mean_absolute_error(actual, estimate)),
        "rmse": float(mean_squared_error(actual, estimate) ** 0.5),
        "r2": float(r2_score(actual, estimate)),
        "medianAbsoluteError": float(np.median(absolute)),
        "p90AbsoluteError": float(np.percentile(absolute, 90)),
        "withinFivePoints": float(np.mean(absolute <= 5)),
        "validationNightCount": len(actual),
    }


def serialize_tree(estimator: Any) -> dict[str, Any]:
    tree = estimator.tree_
    return {
        "childrenLeft": tree.children_left.tolist(),
        "childrenRight": tree.children_right.tolist(),
        "features": tree.feature.tolist(),
        "thresholds": tree.threshold.tolist(),
        "values": tree.value[:, 0, 0].tolist(),
    }


def export_model(
    output: Path,
    inputs: np.ndarray,
    targets: np.ndarray,
    trained_through: date,
    validation: dict[str, float],
) -> None:
    imputer = SimpleImputer(strategy="median").fit(inputs)
    imputed = imputer.transform(inputs)
    boosted = boosted_model().fit(imputed, targets)
    ridge = ridge_model().fit(inputs, targets)
    ridge_imputer = ridge.named_steps["simpleimputer"]
    scaler = ridge.named_steps["standardscaler"]
    estimator = ridge.named_steps["ridge"]
    payload = {
        "version": MODEL_VERSION,
        "featureVersion": FEATURE_VERSION,
        "featureCount": FEATURE_COUNT,
        "trainedNightCount": len(targets),
        "trainedThrough": trained_through.isoformat(),
        "forwardValidation": validation,
        "boostedWeight": BOOSTED_WEIGHT,
        "imputerMedians": imputer.statistics_.tolist(),
        "boostedModel": {
            "initialPrediction": float(np.asarray(boosted.init_.constant_).ravel()[0]),
            "learningRate": float(boosted.learning_rate),
            "trees": [serialize_tree(row[0]) for row in boosted.estimators_],
        },
        "ridgeModel": {
            "imputerMedians": ridge_imputer.statistics_.tolist(),
            "means": scaler.mean_.tolist(),
            "scales": scaler.scale_.tolist(),
            "coefficients": estimator.coef_.tolist(),
            "intercept": float(estimator.intercept_),
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as destination:
        json.dump(payload, destination, separators=(",", ":"))
        destination.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("official_metrics", type=Path)
    parser.add_argument("--model-output", type=Path)
    args = parser.parse_args()

    targets, hrv, rhr = target_rows(args.archive)
    steps = official_steps(args.official_metrics)
    all_nights = sleep_model.extract_nights(args.archive)
    nights = [night for night in all_nights if night["date"] in targets]
    inputs = np.asarray(
        [recovery_features(nights, index, hrv, rhr, steps) for index in range(len(nights))]
    )
    inputs[~np.isfinite(inputs)] = np.nan
    target_values = np.asarray([targets[night["date"]] for night in nights])
    validation = chronological_validation(inputs, target_values)
    print(json.dumps(validation, indent=2, sort_keys=True))
    if args.model_output:
        export_model(args.model_output, inputs, target_values, nights[-1]["date"], validation)
        print(f"Wrote private Recovery model to {args.model_output}")


if __name__ == "__main__":
    main()
