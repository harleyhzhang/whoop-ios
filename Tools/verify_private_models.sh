#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$(mktemp -d "${TMPDIR:-/tmp}/whoop-private-models.XXXXXX")"
simulator_udid=""

cleanup() {
    if [ -n "$simulator_udid" ]; then
        xcrun simctl delete "$simulator_udid" >/dev/null 2>&1 || true
    fi
    rm -rf "$derived_data_path"
}
trap cleanup EXIT

cd "$repo_dir"

private_root="${WHOOP_PRIVATE_SEED_ROOT:-${HOME}/Documents/personal/data/whoop/app-seeds}"
required_files=(
    whoop-history.json
    whoop-score-model.json
    whoop-recovery-model.json
    whoop-strain-model.json
    whoop-official-metrics.json
    whoop-official-archive.sqlite3
)
for filename in "${required_files[@]}"; do
    if [ ! -f "$private_root/$filename" ]; then
        echo "Missing private model fixture: $private_root/$filename" >&2
        exit 1
    fi
done

export WHOOP_HISTORY_SEED_PATH="$private_root/whoop-history.json"
export WHOOP_SCORE_MODEL_PATH="$private_root/whoop-score-model.json"
export WHOOP_STRAIN_MODEL_PATH="$private_root/whoop-strain-model.json"
export WHOOP_RECOVERY_MODEL_PATH="$private_root/whoop-recovery-model.json"
export WHOOP_OFFICIAL_METRICS_PATH="$private_root/whoop-official-metrics.json"
export WHOOP_OFFICIAL_ARCHIVE_PATH="$private_root/whoop-official-archive.sqlite3"

runtime_id="$(
    xcrun simctl list runtimes available -j \
        | jq -r '[.runtimes[] | select(.isAvailable and (.name | startswith("iOS ")))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier'
)"
if [ -z "$runtime_id" ] || [ "$runtime_id" = "null" ]; then
    echo "No available iOS Simulator runtime was found." >&2
    exit 1
fi
simulator_udid="$(
    xcrun simctl create \
        "WHOOP Private Models $$" \
        com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
        "$runtime_id"
)"
xcrun simctl boot "$simulator_udid"
xcrun simctl bootstatus "$simulator_udid" -b

xcodebuild test -quiet \
    -project Sleep.xcodeproj \
    -scheme SleepPrivateTests \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_udid" \
    -derivedDataPath "$derived_data_path" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO

echo "Private model integration tests passed."
