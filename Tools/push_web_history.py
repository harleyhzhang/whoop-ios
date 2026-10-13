#!/usr/bin/env python3
"""Upload the private seed history to the website's Convex copy.

Reads the same seed files the app bundles, sends compact daily rows and
activities to /v1/web/sync, and never prints the sync token.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

from whoop_config import setting

BATCH = 200


def keychain_token() -> str:
    return subprocess.run(
        ["security", "find-generic-password", "-s", "whoop.web", "-a", "web-sync-token", "-w"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def epoch_ms(value: str | None) -> int | None:
    if not value:
        return None
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)


def build_days(seeds: Path) -> list[dict[str, Any]]:
    days: dict[str, dict[str, Any]] = {}
    for row in json.loads((seeds / "whoop-history.json").read_text()):
        days[row["dateKey"]] = {
            "day": row["dateKey"],
            "sleep": row.get("sleepScore"),
            "duration": row.get("sleepDurationMinutes"),
            "hrv": row.get("hrvRMSSDMilliseconds"),
            "rhr": row.get("restingHeartRateBPM"),
        }
    metrics = json.loads((seeds / "whoop-official-metrics.json").read_text())["daily"]
    for row in metrics:
        day = days.setdefault(row["dateKey"], {"day": row["dateKey"]})
        day["recovery"] = row.get("officialRecoveryScore")
        day["strain"] = row.get("officialDayStrain")
        day["steps"] = row.get("officialSteps")
        day.setdefault("hrv", row.get("hrv"))
        day.setdefault("rhr", row.get("rhr"))
    return [days[key] for key in sorted(days)]


def build_activities(seeds: Path) -> list[dict[str, Any]]:
    path = seeds / "whoop-activities.json"
    if not path.exists():
        return []
    out = []
    for row in json.loads(path.read_text()):
        out.append({
            "entryId": row["id"],
            "kind": row["kind"],
            "title": row.get("name") or row["kind"].title(),
            "start": epoch_ms(row["start"]),
            "end": epoch_ms(row.get("end")),
            "strain": row.get("strain"),
            "averageHeartRate": row.get("averageHeartRate"),
            "maxHeartRate": row.get("maxHeartRate"),
            "calories": row.get("calories"),
            "sleepScore": row.get("sleepScore"),
            "zonePercents": row.get("zonePercents"),
        })
    return out


def post(site: str, token: str, body: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        site.rstrip("/") + "/v1/web/sync",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "authorization": f"Bearer {token}"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seeds", type=Path)
    parser.add_argument("--site", default=setting("WHOOP_CONVEX_SITE_URL", ""))
    args = parser.parse_args()
    if not args.site:
        raise SystemExit("WHOOP_CONVEX_SITE_URL is not configured")
    token = keychain_token()
    days, activities = build_days(args.seeds), build_activities(args.seeds)
    for start in range(0, max(len(days), len(activities)), BATCH):
        result = post(args.site, token, {
            "days": days[start:start + BATCH],
            "activities": activities[start:start + BATCH],
        })
        print(f"batch {start // BATCH + 1}: {result}")
    print(f"Uploaded {len(days)} days and {len(activities)} activities")


if __name__ == "__main__":
    main()
