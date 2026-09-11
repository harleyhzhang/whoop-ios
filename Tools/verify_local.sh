#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$(mktemp -d "${TMPDIR:-/tmp}/whoop-local-verify.XXXXXX")"
result_bundle_path="$derived_data_path/SleepTests.xcresult"
minimum_coverage="${WHOOP_MINIMUM_COVERAGE:-58}"
simulator_udid=""

cleanup() {
  if [ -n "$simulator_udid" ]; then
    xcrun simctl delete "$simulator_udid" >/dev/null 2>&1 || true
  fi
  rm -rf "$derived_data_path"
}
trap cleanup EXIT

cd "$repo_dir"

required_commands=(actionlint gitleaks jq shellcheck uv xcodebuild xcodegen)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required tool: $command_name. Run: brew bundle --file Brewfile" >&2
    exit 1
  fi
done

export WHOOP_HISTORY_SEED_PATH="$derived_data_path/missing-whoop-history.json"
export WHOOP_SCORE_MODEL_PATH="$derived_data_path/missing-whoop-score-model.json"
export WHOOP_RECOVERY_MODEL_PATH="$derived_data_path/missing-whoop-recovery-model.json"
export WHOOP_OFFICIAL_METRICS_PATH="$derived_data_path/missing-whoop-official-metrics.json"
export WHOOP_OFFICIAL_ARCHIVE_PATH="$derived_data_path/missing-whoop-official-archive.sqlite3"

echo "Checking Swift formatting..."
xcrun swift-format lint \
  --configuration .swift-format \
  --recursive \
  --strict \
  SleepApp WhoopHandshakeApp SleepTests SleepUITests SleepPrivateTests

echo "Checking shell scripts..."
shellcheck Tools/*.sh .githooks/*

echo "Checking GitHub Actions workflows..."
actionlint

echo "Checking Python tools..."
Tools/check_python.sh

echo "Checking generated Xcode project..."
Tools/check_project_generation.sh

echo "Testing physical-phone install policy..."
Tools/test_phone_install_policy.sh

echo "Checking private-data boundary and secrets..."
Tools/check_private_data.sh

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
    "WHOOP Local Verify $$" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
    "$runtime_id"
)"
xcrun simctl boot "$simulator_udid"
xcrun simctl bootstatus "$simulator_udid" -b

echo "Running tests with code coverage..."
xcodebuild test -quiet \
  -project Sleep.xcodeproj \
  -scheme Sleep \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data_path" \
  -resultBundlePath "$result_bundle_path" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage YES \
  CODE_SIGNING_ALLOWED=NO

test_summary="$(xcrun xcresulttool get test-results summary --path "$result_bundle_path")"
passed_tests="$(jq -r '.passedTests // 0' <<<"$test_summary")"
failed_tests="$(jq -r '.failedTests // 0' <<<"$test_summary")"
skipped_tests="$(jq -r '.skippedTests // 0' <<<"$test_summary")"
if [ "$failed_tests" -ne 0 ] || [ "$skipped_tests" -ne 0 ]; then
  echo "Tests must finish with no failures or skips (failed=$failed_tests, skipped=$skipped_tests)." >&2
  exit 1
fi
echo "Tests: $passed_tests passed, 0 failed, 0 skipped."

coverage="$(xcrun xccov view --report --only-targets "$result_bundle_path" | awk '$2 == "WHOOP.app" { gsub(/%/, "", $4); print $4 }')"
if [ -z "$coverage" ]; then
  echo "Could not read WHOOP.app coverage from the test result bundle." >&2
  exit 1
fi
if ! awk -v actual="$coverage" -v minimum="$minimum_coverage" 'BEGIN { exit !(actual >= minimum) }'; then
  echo "WHOOP.app coverage ${coverage}% is below the ${minimum_coverage}% floor." >&2
  exit 1
fi
echo "WHOOP.app coverage: ${coverage}% (minimum ${minimum_coverage}%)."

echo "Building Release for iOS Simulator..."
xcodebuild build -quiet \
  -project Sleep.xcodeproj \
  -scheme Sleep \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data_path" \
  CODE_SIGNING_ALLOWED=NO

echo "Running Xcode static analysis..."
xcodebuild analyze -quiet \
  -project Sleep.xcodeproj \
  -scheme Sleep \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data_path" \
  CODE_SIGNING_ALLOWED=NO

echo "Local verification passed."
