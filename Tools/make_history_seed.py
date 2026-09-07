#!/usr/bin/env python3
"""Build the app's private daily-history seed from an immutable WHOOP API archive."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


def load_records(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as source:
        return json.load(source)["records"]


def parse_instant(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def local_date_key(end: str, offset: str) -> str:
    if offset == "Z":
        zone = timezone.utc
    else:
        sign = 1 if offset[0] == "+" else -1
        hours, minutes = (int(part) for part in offset[1:].split(":"))
        zone = timezone(sign * timedelta(hours=hours, minutes=minutes))
    return parse_instant(end).astimezone(zone).date().isoformat()


def local_zone(offset: str) -> timezone:
    if offset == "Z":
        return timezone.utc
    sign = 1 if offset[0] == "+" else -1
    hours, minutes = (int(part) for part in offset[1:].split(":"))
    return timezone(sign * timedelta(hours=hours, minutes=minutes))


def minute_of_day(value: str, offset: str) -> float:
    local = parse_instant(value).astimezone(local_zone(offset))
    return local.hour * 60 + local.minute + local.second / 60 + local.microsecond / 60_000_000


def build_seed(archive: Path) -> list[dict[str, Any]]:
    sleeps = load_records(archive / "sleeps-combined.json")
    recoveries = {
        int(record["cycle_id"]): record
        for record in load_records(archive / "recoveries-combined.json")
        if record.get("score_state") == "SCORED"
    }

    result: list[dict[str, Any]] = []
    for sleep in sleeps:
        if sleep.get("nap") or sleep.get("score_state") != "SCORED":
            continue
        recovery = recoveries.get(int(sleep["cycle_id"]))
        sleep_score = sleep["score"]
        stages = sleep_score["stage_summary"]
        sleep_needed = sleep_score["sleep_needed"]
        total_sleep_milli = sum(
            stages[key]
            for key in (
                "total_light_sleep_time_milli",
                "total_rem_sleep_time_milli",
                "total_slow_wave_sleep_time_milli",
            )
        )
        recovery_score = recovery.get("score", {}) if recovery else {}
        need_milli = sum(
            sleep_needed[key]
            for key in (
                "baseline_milli",
                "need_from_sleep_debt_milli",
                "need_from_recent_strain_milli",
                "need_from_recent_nap_milli",
            )
        )
        source_updated = max(
            parse_instant(sleep["updated_at"]),
            parse_instant(recovery["updated_at"]) if recovery else parse_instant(sleep["updated_at"]),
        )
        result.append(
            {
                "dateKey": local_date_key(sleep["end"], sleep["timezone_offset"]),
                "sleepScore": float(sleep_score["sleep_performance_percentage"]),
                "sleepDurationMinutes": total_sleep_milli / 60_000,
                "hrvRMSSDMilliseconds": (
                    float(recovery_score["hrv_rmssd_milli"])
                    if "hrv_rmssd_milli" in recovery_score
                    else None
                ),
                "restingHeartRateBPM": (
                    float(recovery_score["resting_heart_rate"])
                    if "resting_heart_rate" in recovery_score
                    else None
                ),
                "sleepID": sleep["id"],
                "cycleID": int(sleep["cycle_id"]),
                "source": "whoop_api",
                "sourceArchive": archive.name,
                "sourceUpdatedAt": source_updated.isoformat().replace("+00:00", "Z"),
                "sleepStartAt": sleep["start"],
                "sleepEndAt": sleep["end"],
                "sleepStartMinute": minute_of_day(sleep["start"], sleep["timezone_offset"]),
                "sleepEndMinute": minute_of_day(sleep["end"], sleep["timezone_offset"]),
                "sleepNeedMinutes": need_milli / 60_000,
                "sleepConsistencyPercentage": float(
                    sleep_score["sleep_consistency_percentage"]
                ),
                "sleepEfficiencyPercentage": float(
                    sleep_score["sleep_efficiency_percentage"]
                ),
                "sleepSufficiencyPercentage": min(
                    100.0, total_sleep_milli / need_milli * 100
                ),
                "sourceSleepPayloadJSON": json.dumps(
                    sleep, separators=(",", ":"), sort_keys=True
                ),
                "sourceRecoveryPayloadJSON": (
                    json.dumps(recovery, separators=(",", ":"), sort_keys=True)
                    if recovery
                    else None
                ),
            }
        )

    result.sort(key=lambda record: record["dateKey"])
    date_keys = [record["dateKey"] for record in result]
    if len(date_keys) != len(set(date_keys)):
        raise RuntimeError("The archive contains more than one primary sleep on a local date")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    records = build_seed(args.archive)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as destination:
        json.dump(records, destination, indent=2, sort_keys=True)
        destination.write("\n")
    print(f"Wrote {len(records)} real nights: {records[0]['dateKey']} through {records[-1]['dateKey']}")


if __name__ == "__main__":
    main()
