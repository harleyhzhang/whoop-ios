from __future__ import annotations

from datetime import UTC, datetime

import make_history_seed as history
import make_official_history_seed as official


def test_local_date_and_minute_respect_recorded_offset() -> None:
    instant = "2026-09-11T03:30:00Z"

    assert history.local_date_key(instant, "-04:00") == "2026-09-10"
    assert history.minute_of_day(instant, "-04:00") == 23 * 60 + 30
    assert history.parse_instant(instant) == datetime(2026, 9, 11, 3, 30, tzinfo=UTC)


def test_number_normalizes_display_values_and_rejects_text() -> None:
    assert official.number("12,345") == 12_345
    assert official.number("87%") == 87
    assert official.number(None) is None
    assert official.number("unavailable") is None


def test_recovery_projection_extracts_score_and_baselines() -> None:
    payload = {
        "sections": [
            {
                "items": [
                    {
                        "type": "SCORE_GAUGE",
                        "content": {"id": "RECOVERY_SCORE_GAUGE", "score_display": "91%"},
                    },
                    {
                        "type": "CONTRIBUTORS_TILE",
                        "content": {
                            "metrics": [
                                {
                                    "id": "CONTRIBUTORS_TILE_HRV",
                                    "status": "67",
                                    "status_subtitle": "61",
                                },
                                {
                                    "id": "CONTRIBUTORS_TILE_RHR",
                                    "status": "51",
                                    "status_subtitle": "55",
                                },
                            ]
                        },
                    },
                ]
            }
        ]
    }

    assert official.recovery_projection(payload) == {
        "officialRecoveryScore": 91,
        "hrv": 67,
        "hrvBaseline": 61,
        "rhr": 51,
        "rhrBaseline": 55,
    }


def test_strain_projection_scales_target_and_normalizes_steps() -> None:
    payload = {
        "sections": [
            {
                "items": [
                    {
                        "type": "SCORE_GAUGE",
                        "content": {
                            "id": "STRAIN_SCORE_GAUGE",
                            "score_display": "12.4",
                            "score_target": "0.8",
                        },
                    },
                    {
                        "type": "CONTRIBUTORS_TILE",
                        "content": {
                            "metrics": [
                                {
                                    "id": "CONTRIBUTORS_TILE_STEPS",
                                    "status": "12,345",
                                    "status_subtitle": "9,000",
                                }
                            ]
                        },
                    },
                ]
            }
        ]
    }

    assert official.strain_projection(payload) == {
        "officialDayStrain": 12.4,
        "dayStrainTarget": 16.8,
        "officialSteps": 12_345,
        "stepsBaseline": 9_000,
    }
