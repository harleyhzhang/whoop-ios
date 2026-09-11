#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$(mktemp -d "${TMPDIR:-/tmp}/whoop-local-verify.XXXXXX")"

cleanup() {
  rm -rf "$derived_data_path"
}
trap cleanup EXIT

cd "$repo_dir"

echo "Testing physical-phone install policy..."
Tools/test_phone_install_policy.sh

if git ls-files | grep -Eq '(^|/)(sleep\.sqlite3|whoop-history\.json|whoop-score-model\.json|whoop-recovery-model\.json|whoop-official-metrics\.json|whoop-official-archive\.sqlite3)$'; then
  echo "Private WHOOP runtime data must not be committed."
  exit 1
fi

echo "Running unit tests..."
xcodebuild test -quiet \
  -project Sleep.xcodeproj \
  -scheme Sleep \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -derivedDataPath "$derived_data_path" \
  CODE_SIGNING_ALLOWED=NO

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
