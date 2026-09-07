#!/usr/bin/env python3
"""Backtest and export Harley's private WHOOP-compatible sleep score model.

Requires numpy and scikit-learn. The output contains fitted support vectors and
tree thresholds derived from private health history, so write it only to the
private app-seeds directory; never commit it to this repository.
"""

from __future__ import annotations

import argparse
import json
import math
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.ensemble import ExtraTreesRegressor
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVR

FEATURE_VERSION = "whoop_local_features_v1"
MODEL_VERSION = "whoop5_local_v5_score_staged_1"
FOREST_WEIGHT = 0.75
DIRECT_WEIGHT = 0.10
RECENCY_WEIGHTS = (0.52, 0.27, 0.14, 0.07)


def load_records(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as source:
        return json.load(source)["records"]


def parse_instant(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def local_zone(offset: str) -> timezone:
    if offset == "Z":
        return timezone.utc
    sign = 1 if offset[0] == "+" else -1
    hours, minutes = (int(part) for part in offset[1:].split(":"))
    return timezone(sign * timedelta(hours=hours, minutes=minutes))


def minute_of_day(value: datetime) -> float:
    return value.hour * 60 + value.minute + value.second / 60 + value.microsecond / 60_000_000


def circular_distance(lhs: float, rhs: float) -> float:
    difference = abs(lhs - rhs) % 1_440
    return min(difference, 1_440 - difference)


def extract_nights(archive: Path) -> list[dict[str, Any]]:
    nights: list[dict[str, Any]] = []
    for sleep in load_records(archive / "sleeps-combined.json"):
        if sleep.get("nap") or sleep.get("score_state") != "SCORED":
            continue
        score = sleep["score"]
        stages = score["stage_summary"]
        duration = sum(
            stages[key]
            for key in (
                "total_light_sleep_time_milli",
                "total_rem_sleep_time_milli",
                "total_slow_wave_sleep_time_milli",
            )
        ) / 60_000
        need = sum(score["sleep_needed"].values()) / 60_000
        zone = local_zone(sleep["timezone_offset"])
        start = parse_instant(sleep["start"]).astimezone(zone)
        end = parse_instant(sleep["end"]).astimezone(zone)
        nights.append(
            {
                "date": end.date(),
                "duration": duration,
                "efficiency": float(score["sleep_efficiency_percentage"]),
                "start_minute": minute_of_day(start),
                "end_minute": minute_of_day(end),
                "need": need,
                "sufficiency": min(100.0, duration / need * 100),
                "consistency": float(score["sleep_consistency_percentage"]),
                "target": float(score["sleep_performance_percentage"]),
            }
        )
    nights.sort(key=lambda night: night["date"])
    return nights


def local_features(nights: list[dict[str, Any]], index: int) -> list[float]:
    current = nights[index]
    values = [
        current["duration"],
        current["efficiency"],
        math.sin(2 * math.pi * current["start_minute"] / 1_440),
        math.cos(2 * math.pi * current["start_minute"] / 1_440),
        math.sin(2 * math.pi * current["end_minute"] / 1_440),
        math.cos(2 * math.pi * current["end_minute"] / 1_440),
    ]
    previous: list[dict[str, Any]] = []
    for lag in range(1, 8):
        candidate = nights[index - lag] if index >= lag else None
        gap = (current["date"] - candidate["date"]).days if candidate else None
        usable = candidate is not None and gap is not None and gap <= lag + 3
        night = candidate if usable else current
        previous.append(night)
        values.extend(
            [
                night["duration"],
                night["efficiency"],
                circular_distance(current["start_minute"], night["start_minute"]),
                circular_distance(current["end_minute"], night["end_minute"]),
                float(gap) if usable else 0.0,
            ]
        )

    first_four = previous[:4]
    durations = np.asarray([night["duration"] for night in first_four])
    efficiencies = np.asarray([night["efficiency"] for night in first_four])
    values.extend([durations.mean(), durations.std(), efficiencies.mean(), efficiencies.std()])
    agreements = [
        max(
            0.0,
            100
            * (
                1
                - (
                    circular_distance(current["start_minute"], night["start_minute"])
                    + circular_distance(current["end_minute"], night["end_minute"])
                )
                / 1_440
            ),
        )
        for night in first_four
    ]
    values.extend(agreements)
    values.append(sum(value * weight for value, weight in zip(agreements, RECENCY_WEIGHTS)))
    if len(values) != 50:
        raise RuntimeError(f"Feature contract changed unexpectedly: {len(values)}")
    return [float(value) for value in values]


def models() -> tuple[ExtraTreesRegressor, Any]:
    forest = ExtraTreesRegressor(
        n_estimators=300,
        min_samples_leaf=2,
        max_features=0.8,
        random_state=4,
        n_jobs=-1,
    )
    svr = make_pipeline(StandardScaler(), SVR(C=100, gamma=0.003, epsilon=0.05))
    return forest, svr


def need_model() -> GradientBoostingRegressor:
    return GradientBoostingRegressor(
        n_estimators=250,
        max_depth=2,
        min_samples_leaf=3,
        loss="squared_error",
        learning_rate=0.025,
        random_state=3,
    )


def consistency_model() -> GradientBoostingRegressor:
    return GradientBoostingRegressor(
        n_estimators=250,
        max_depth=2,
        min_samples_leaf=8,
        loss="huber",
        learning_rate=0.025,
        random_state=3,
    )


def pillar_model() -> Any:
    return make_pipeline(StandardScaler(), SVR(C=100, gamma=0.075, epsilon=0.05))


def chronological_predictions(
    inputs: np.ndarray, targets: np.ndarray, factory: Any
) -> tuple[np.ndarray, np.ndarray]:
    predicted: list[float] = []
    observed: list[float] = []
    starts = (180, 210, 240, 270)
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(targets)
        train = np.arange(start)
        test = np.arange(start, end)
        model = factory()
        model.fit(inputs[train], targets[train])
        predicted.extend(model.predict(inputs[test]))
        observed.extend(targets[test])
    return np.asarray(observed), np.asarray(predicted)


def metrics(observed: np.ndarray, predicted: np.ndarray) -> dict[str, float]:
    absolute = np.abs(observed - predicted)
    return {
        "mae": float(mean_absolute_error(observed, predicted)),
        "rmse": float(mean_squared_error(observed, predicted) ** 0.5),
        "r2": float(r2_score(observed, predicted)),
        "medianAbsoluteError": float(np.median(absolute)),
        "p90AbsoluteError": float(np.percentile(absolute, 90)),
        "withinTwoPoints": float(np.mean(absolute <= 2)),
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


def serialize_svr(pipeline: Any) -> dict[str, Any]:
    scaler = pipeline.named_steps["standardscaler"]
    svr = pipeline.named_steps["svr"]
    return {
        "means": scaler.mean_.tolist(),
        "scales": scaler.scale_.tolist(),
        "supportVectors": svr.support_vectors_.tolist(),
        "dualCoefficients": svr.dual_coef_[0].tolist(),
        "intercept": float(svr.intercept_[0]),
        "gamma": float(svr._gamma),
    }


def serialize_boosted(model: GradientBoostingRegressor) -> dict[str, Any]:
    return {
        "initialPrediction": float(np.asarray(model.init_.constant_).ravel()[0]),
        "learningRate": float(model.learning_rate),
        "trees": [serialize_tree(row[0]) for row in model.estimators_],
    }


def export_model(
    output: Path,
    nights: list[dict[str, Any]],
    inputs: np.ndarray,
    targets: np.ndarray,
    validation: dict[str, float],
) -> None:
    forest, pipeline = models()
    forest.fit(inputs, targets)
    pipeline.fit(inputs, targets)
    needs = np.asarray([night["need"] for night in nights])
    consistencies = np.asarray([night["consistency"] for night in nights])
    efficiencies = np.asarray([night["efficiency"] for night in nights])
    durations = inputs[:, 0]
    need_predictor = need_model().fit(inputs, needs)
    consistency_predictor = consistency_model().fit(inputs, consistencies)
    pillars = np.column_stack(
        (np.minimum(100, durations / needs * 100), consistencies, efficiencies)
    )
    pillar_predictor = pillar_model().fit(pillars, targets)
    payload = {
        "version": MODEL_VERSION,
        "featureVersion": FEATURE_VERSION,
        "trainedNightCount": len(nights),
        "trainedThrough": nights[-1]["date"].isoformat(),
        "forwardValidation": validation,
        "directWeight": DIRECT_WEIGHT,
        "extraTreesWeight": FOREST_WEIGHT,
        "trees": [serialize_tree(tree) for tree in forest.estimators_],
        "svr": serialize_svr(pipeline),
        "needModel": serialize_boosted(need_predictor),
        "consistencyModel": serialize_boosted(consistency_predictor),
        "pillarSVR": serialize_svr(pillar_predictor),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as destination:
        json.dump(payload, destination, separators=(",", ":"))
        destination.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--model-output", type=Path)
    args = parser.parse_args()

    nights = extract_nights(args.archive)
    inputs = np.asarray([local_features(nights, index) for index in range(len(nights))])
    targets = np.asarray([night["target"] for night in nights])

    current = np.minimum(99, inputs[:, 0] / 519 * 100)
    observed, local_forest = chronological_predictions(
        inputs, targets, lambda: models()[0]
    )
    _, local_svr = chronological_predictions(inputs, targets, lambda: models()[1])
    direct_prediction = FOREST_WEIGHT * local_forest + (1 - FOREST_WEIGHT) * local_svr

    pillars = np.asarray(
        [[night["sufficiency"], night["consistency"], night["efficiency"]] for night in nights]
    )
    _, exact_pillar_prediction = chronological_predictions(
        pillars,
        targets,
        lambda: make_pipeline(StandardScaler(), SVR(C=100, gamma=0.075, epsilon=0.05)),
    )

    predicted_need_observed, predicted_needs = chronological_predictions(
        inputs, np.asarray([night["need"] for night in nights]), need_model
    )
    predicted_consistency_observed, predicted_consistencies = chronological_predictions(
        inputs, np.asarray([night["consistency"] for night in nights]), consistency_model
    )
    if predicted_need_observed.shape != predicted_consistency_observed.shape:
        raise RuntimeError("Staged validation folds diverged")
    forward_durations = inputs[180:, 0]
    forward_efficiencies = np.asarray([night["efficiency"] for night in nights])[180:]
    predicted_pillars = np.column_stack(
        (
            np.minimum(100, forward_durations / predicted_needs * 100),
            predicted_consistencies,
            forward_efficiencies,
        )
    )
    # Re-run only the prediction part of each chronological pillar model with
    # the independently predicted need and consistency inputs.
    staged_prediction = []
    offset = 0
    starts = (180, 210, 240, 270)
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(targets)
        count = end - start
        trained = pillar_model().fit(pillars[:start], targets[:start])
        staged_prediction.extend(trained.predict(predicted_pillars[offset : offset + count]))
        offset += count
    staged_prediction = np.asarray(staged_prediction)
    local_ensemble = DIRECT_WEIGHT * direct_prediction + (1 - DIRECT_WEIGHT) * staged_prediction

    report = {
        "nights": len(nights),
        "dateRange": [nights[0]["date"].isoformat(), nights[-1]["date"].isoformat()],
        "currentFixed519AllNights": metrics(targets, current),
        "exactExportedPillarsForward": metrics(observed, exact_pillar_prediction),
        "locallyAvailableFeaturesForward": metrics(observed, local_ensemble),
    }
    print(json.dumps(report, indent=2))
    if args.model_output:
        export_model(
            args.model_output,
            nights,
            inputs,
            targets,
            report["locallyAvailableFeaturesForward"],
        )
        print(f"Wrote private model to {args.model_output}")


if __name__ == "__main__":
    main()
