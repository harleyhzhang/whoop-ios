#!/bin/sh

set -eu

repo_root=$(git rev-parse --show-toplevel)
policy="$repo_root/Tools/phone_install_policy.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/whoop-install-policy.XXXXXX")

# Git exports repository-local environment while hooks run. Clear it before
# creating the nested fixture so its commits cannot mutate the calling repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX

cleanup() {
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

mode_for() {
  "$policy" "$@" | awk -F= '$1 == "mode" { print $2; exit }'
}

assert_mode() {
  expected="$1"
  shift
  actual=$(mode_for "$@")
  if [ "$actual" != "$expected" ]; then
    echo "Expected mode $expected, got $actual for: $*" >&2
    exit 1
  fi
}

cd "$fixture"
git init -q
git config user.name "WHOOP policy test"
git config user.email "whoop-policy-test@example.invalid"
mkdir -p WhoopApp/Assets.xcassets WhoopKit docs
printf 'struct RootView {}\n' > WhoopApp/RootView.swift
printf 'struct DashboardComponents {}\n' > WhoopApp/DashboardComponents.swift
printf 'struct DashboardHeader {}\n' > WhoopApp/DashboardHeader.swift
printf 'struct DashboardChartState {}\n' > WhoopApp/DashboardChartState.swift
printf 'struct DashboardChartGeometry {}\n' > WhoopApp/DashboardChartGeometry.swift
printf 'struct MetricTrendCard {}\n' > WhoopApp/MetricTrendCard.swift
printf 'struct TrendSupport {}\n' > WhoopApp/TrendSupport.swift
printf 'struct WhoopStore {}\n' > WhoopApp/SleepModels.swift
printf '{}\n' > WhoopApp/Assets.xcassets/Contents.json
printf 'struct WhoopCollector {}\n' > WhoopKit/WhoopCollector.swift
printf 'struct WhoopPersistence { private static let schemaVersion = 10 }\n' > WhoopKit/WhoopStore.swift
printf 'baseline\n' > README.md
git add .
git commit -qm baseline
baseline=$(git rev-parse HEAD)

printf 'documentation only\n' >> README.md
git commit -qam docs
docs_commit=$(git rev-parse HEAD)
assert_mode none --base "$baseline" --head "$docs_commit"

printf '// chart color\n' >> WhoopApp/RootView.swift
git commit -qam ui
ui_commit=$(git rev-parse HEAD)
assert_mode fast --base "$docs_commit" --head "$ui_commit"

printf '// battery color\n' >> WhoopApp/DashboardComponents.swift
git commit -qam dashboard_components_ui
dashboard_components_ui_commit=$(git rev-parse HEAD)
assert_mode fast --base "$ui_commit" --head "$dashboard_components_ui_commit"

printf '// transient chart interaction state\n' >> WhoopApp/DashboardChartState.swift
git commit -qam dashboard_chart_state_ui
dashboard_chart_state_ui_commit=$(git rev-parse HEAD)
assert_mode fast --base "$dashboard_components_ui_commit" --head "$dashboard_chart_state_ui_commit"

printf '// SQLite schema migration\n' >> WhoopApp/DashboardChartState.swift
git commit -qam risky_dashboard_chart_state
risky_dashboard_chart_state_commit=$(git rev-parse HEAD)
assert_mode migration --base "$dashboard_chart_state_ui_commit" --head "$risky_dashboard_chart_state_commit"

sed -i '' '$d' WhoopApp/DashboardChartState.swift
git commit -qam restore_dashboard_chart_state
dashboard_chart_state_restored_commit=$(git rev-parse HEAD)

printf '// chart curve sampler\n' >> WhoopApp/TrendSupport.swift
git commit -qam trend_support_ui
trend_support_ui_commit=$(git rev-parse HEAD)
assert_mode fast --base "$dashboard_chart_state_restored_commit" --head "$trend_support_ui_commit"

printf '// SQLite schema migration\n' >> WhoopApp/TrendSupport.swift
git commit -qam risky_trend_support
risky_trend_support_commit=$(git rev-parse HEAD)
assert_mode migration --base "$trend_support_ui_commit" --head "$risky_trend_support_commit"

sed -i '' '$d' WhoopApp/TrendSupport.swift
git commit -qam restore_trend_support
trend_support_restored_commit=$(git rev-parse HEAD)

printf '// SQLite schema migration\n' >> WhoopApp/DashboardComponents.swift
git commit -qam risky_dashboard_components
risky_dashboard_components_commit=$(git rev-parse HEAD)
assert_mode migration --base "$trend_support_restored_commit" --head "$risky_dashboard_components_commit"

printf '// schema migration\n' >> WhoopApp/RootView.swift
git commit -qam risky_ui
risky_ui_commit=$(git rev-parse HEAD)
assert_mode migration --base "$risky_dashboard_components_commit" --head "$risky_ui_commit"

printf '// storage change\n' >> WhoopApp/SleepModels.swift
git commit -qam storage
storage_commit=$(git rev-parse HEAD)
assert_mode protected --base "$risky_ui_commit" --head "$storage_commit"

printf '// connection presentation\n' >> WhoopApp/DashboardHeader.swift
printf '// chart geometry\n' >> WhoopApp/DashboardChartGeometry.swift
printf '// chart presentation\n' >> WhoopApp/MetricTrendCard.swift
git commit -qam dashboard_presentation
dashboard_presentation_commit=$(git rev-parse HEAD)
assert_mode fast --base "$storage_commit" --head "$dashboard_presentation_commit"

printf '// bluetooth lifecycle\n' >> WhoopKit/WhoopCollector.swift
git commit -qam bluetooth
bluetooth_commit=$(git rev-parse HEAD)
assert_mode protected --base "$dashboard_presentation_commit" --head "$bluetooth_commit"

sed -i '' 's/schemaVersion/currentSchemaVersion/' WhoopKit/WhoopStore.swift
printf 'struct HealthReporter { let sql = "PRAGMA user_version" }\n' > WhoopKit/WhoopDeploymentHealthReporter.swift
git add WhoopKit
git commit -qm schema_observability
schema_observability_commit=$(git rev-parse HEAD)
assert_mode protected --base "$bluetooth_commit" --head "$schema_observability_commit"

# The production store exposes its schema constant internally after refactoring.
sed -i '' 's/private static/static/' WhoopKit/WhoopStore.swift
git commit -qam schema_visibility
schema_visibility_commit=$(git rev-parse HEAD)
assert_mode protected --base "$schema_observability_commit" --head "$schema_visibility_commit"

printf '// narrower header spacing\n' >> WhoopApp/DashboardHeader.swift
git commit -qam internal_schema_presentation
internal_schema_presentation_commit=$(git rev-parse HEAD)
assert_mode fast --base "$schema_visibility_commit" --head "$internal_schema_presentation_commit"

sed -i '' 's/currentSchemaVersion = 10/currentSchemaVersion = 11/' WhoopKit/WhoopStore.swift
git commit -qam schema_version_change
schema_version_change_commit=$(git rev-parse HEAD)
assert_mode migration --base "$internal_schema_presentation_commit" --head "$schema_version_change_commit"

printf 'settings:\n  DEVELOPMENT_TEAM: CHANGED\n' > project.yml
git add project.yml
git commit -qm build_identity
build_identity_commit=$(git rev-parse HEAD)
assert_mode migration --base "$schema_version_change_commit" --head "$build_identity_commit"

assert_mode migration --head "$build_identity_commit"

echo "Phone install policy tests passed."
