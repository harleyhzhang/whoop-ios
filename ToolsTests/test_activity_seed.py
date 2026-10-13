from __future__ import annotations

import make_activity_seed as seed


def workout(**overrides: str) -> dict[str, str]:
    row = {
        "Cycle timezone": "UTC-04:00",
        "Workout start time": "2026-10-12 09:03:37",
        "Workout end time": "2026-10-12 09:16:31",
        "Activity name": "Running",
        "Activity Strain": "11.5",
        "Average HR (bpm)": "176",
        "Max HR (bpm)": "202",
        "Energy burned (cal)": "224.0",
        "HR Zone 1 %": "2",
        "HR Zone 2 %": "7",
        "HR Zone 3 %": "3",
        "HR Zone 4 %": "34",
        "HR Zone 5 %": "52",
    }
    row.update(overrides)
    return row


def sleep(nap: str) -> dict[str, str]:
    return {
        "Cycle timezone": "UTCZ",
        "Sleep onset": "2026-10-11 14:00:00",
        "Wake onset": "2026-10-11 14:40:00",
        "Sleep performance %": "",
        "Nap": nap,
    }


def test_workouts_keep_official_strain_heart_rate_and_local_offset() -> None:
    [record] = seed.activities([workout()], [])
    assert record["start"] == "2026-10-12T09:03:37-04:00"
    assert record["end"] == "2026-10-12T09:16:31-04:00"
    assert (record["name"], record["strain"], record["averageHeartRate"]) == ("Running", 11.5, 176)
    assert (record["maxHeartRate"], record["calories"]) == (202, 224)
    assert record["zonePercents"] == [2.0, 7.0, 3.0, 34.0, 52.0]
    bare = {k: v for k, v in workout().items() if not k.startswith("HR Zone")}
    assert seed.activities([bare], [])[0]["zonePercents"] is None


def test_naps_are_distinguished_and_invalid_spans_dropped() -> None:
    records = seed.activities(
        [workout(**{"Workout end time": "2026-10-12 09:00:00"})], [sleep("true"), sleep("false")]
    )
    assert [r["kind"] for r in records] == ["nap", "sleep"]
    assert records[0]["sleepScore"] is None
    assert records[0]["id"] != records[1]["id"]
    assert seed.activities([workout()], [])[0]["id"] == seed.activities([workout()], [])[0]["id"]
