#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_root="$(mktemp -d "${TMPDIR:-/tmp}/whoop-sanitizers.XXXXXX")"
simulator_udid=""

cleanup() {
    if [ -n "$simulator_udid" ]; then
        xcrun simctl delete "$simulator_udid" >/dev/null 2>&1 || true
    fi
    rm -rf "$derived_root"
}
trap cleanup EXIT

cd "$repo_dir"
export WHOOP_HISTORY_SEED_PATH="$derived_root/missing-whoop-history.json"
export WHOOP_SCORE_MODEL_PATH="$derived_root/missing-whoop-score-model.json"
export WHOOP_RECOVERY_MODEL_PATH="$derived_root/missing-whoop-recovery-model.json"
export WHOOP_OFFICIAL_METRICS_PATH="$derived_root/missing-whoop-official-metrics.json"
export WHOOP_OFFICIAL_ARCHIVE_PATH="$derived_root/missing-whoop-official-archive.sqlite3"

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
        "WHOOP Sanitizers $$" \
        com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
        "$runtime_id"
)"
xcrun simctl boot "$simulator_udid"
xcrun simctl bootstatus "$simulator_udid" -b

common=(
    -quiet
    -project Sleep.xcodeproj
    -scheme Sleep
    -configuration Debug
    -destination "platform=iOS Simulator,id=$simulator_udid"
    -parallel-testing-enabled NO
    -skip-testing:SleepUITests
    CODE_SIGNING_ALLOWED=NO
)

echo "Running Address Sanitizer tests..."
xcodebuild test "${common[@]}" \
    -derivedDataPath "$derived_root/address" \
    -enableAddressSanitizer YES

echo "Running Thread Sanitizer tests..."
xcodebuild test "${common[@]}" \
    -derivedDataPath "$derived_root/thread" \
    -enableThreadSanitizer YES

echo "Sanitizer verification passed."
