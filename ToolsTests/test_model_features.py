from __future__ import annotations

from datetime import date, timedelta
from typing import Any

import backtest_recovery_score as recovery
import backtest_sleep_score as sleep
import numpy as np


def night(day: date, target: float = 80) -> dict[str, Any]:
    return {
        "date": day,
        "duration": 480.0,
        "efficiency": 95.0,
        "start_minute": 1_410.0,
        "end_minute": 450.0,
        "need": 500.0,
        "sufficiency": 96.0,
        "consistency": 85.0,
        "target": target,
    }


def test_time_helpers_cover_midnight_and_offsets() -> None:
    instant = sleep.parse_instant("2026-09-11T03:30:00Z")

    assert sleep.minute_of_day(instant.astimezone(sleep.local_zone("-04:00"))) == 23 * 60 + 30
    assert sleep.circular_distance(10, 1_430) == 20
    assert sleep.circular_distance(100, 140) == 40


def test_sleep_features_are_fixed_width_and_ignore_future_rows() -> None:
    start = date(2026, 1, 1)
    nights = [night(start + timedelta(days=index), 70 + index) for index in range(10)]

    baseline = sleep.local_features(nights[:9], 8)
    with_future = sleep.local_features(nights, 8)

    assert len(baseline) == 50
    assert baseline == with_future
    assert all(np.isfinite(value) for value in baseline)


def test_recovery_features_are_fixed_width_and_past_only() -> None:
    start = date(2026, 1, 1)
    nights = [night(start + timedelta(days=index), 70 + index) for index in range(12)]
    hrv = {item["date"]: 60.0 + index for index, item in enumerate(nights)}
    rhr = {item["date"]: 55.0 - index / 10 for index, item in enumerate(nights)}
    steps = {item["date"]: 8_000.0 + index * 100 for index, item in enumerate(nights)}

    baseline = recovery.recovery_features(nights[:10], 9, hrv, rhr, steps)
    hrv[nights[10]["date"]] = 999
    rhr[nights[10]["date"]] = 999
    steps[nights[10]["date"]] = 999_999
    with_future = recovery.recovery_features(nights, 9, hrv, rhr, steps)

    assert len(baseline) == recovery.FEATURE_COUNT
    assert np.allclose(baseline, with_future, equal_nan=True)


def test_metrics_report_exact_predictions() -> None:
    observed = np.asarray([10.0, 20.0, 30.0])
    measured = sleep.metrics(observed, observed.copy())

    assert measured["mae"] == 0
    assert measured["rmse"] == 0
    assert measured["r2"] == 1
    assert measured["withinTwoPoints"] == 1
