#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

derived_data_path="${WHOOP_FAST_DERIVED_DATA:-$repo_dir/DerivedData-fast}"
runtime_id="$(jq -r '.simulatorRuntime.identifier' Tools/toolchain.json)"
simulator_name="WHOOP Fast Loop"
test_selection=("-only-testing:SleepTests")
if [ "$#" -gt 0 ]; then
  test_selection=("$@")
fi

Tools/doctor.sh --toolchain-only
uv run --frozen python Tools/generate_model_features.py --check
Tools/check_project_generation.sh
Tools/check_test_contract.sh
xcrun swift-format lint \
  --configuration .swift-format \
  --recursive \
  --strict \
  SleepApp WhoopHandshakeApp SleepTests SleepUITests SleepPrivateTests
Tools/check_python.sh

simulator_udid="$(
  xcrun simctl list devices -j \
    | jq -r --arg runtime "$runtime_id" --arg name "$simulator_name" \
      '[.devices[$runtime][]? | select(.name == $name and .isAvailable)] | first.udid // empty'
)"
if [ -z "$simulator_udid" ]; then
  simulator_udid="$(
    xcrun simctl create \
      "$simulator_name" \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
      "$runtime_id"
  )"
fi

xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_udid" -b

export WHOOP_HISTORY_SEED_PATH="$derived_data_path/missing-whoop-history.json"
export WHOOP_SCORE_MODEL_PATH="$derived_data_path/missing-whoop-score-model.json"
export WHOOP_RECOVERY_MODEL_PATH="$derived_data_path/missing-whoop-recovery-model.json"
export WHOOP_OFFICIAL_METRICS_PATH="$derived_data_path/missing-whoop-official-metrics.json"
export WHOOP_OFFICIAL_ARCHIVE_PATH="$derived_data_path/missing-whoop-official-archive.sqlite3"

echo "Running warm-cache tests on $simulator_name ($simulator_udid)..."
xcodebuild test -quiet \
  -project Sleep.xcodeproj \
  -scheme Sleep \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data_path" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  "${test_selection[@]}"

echo "Fast check passed; simulator and DerivedData were retained for the next run."
