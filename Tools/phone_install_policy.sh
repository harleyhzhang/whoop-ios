#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: Tools/phone_install_policy.sh [--base REF] [--head REF] [--state PATH]

Classifies a physical-phone install as:
  none  No production app change; do not install.
  fast  Presentation-only change; install in place without copying the database.
  protected  Runtime, collector, or storage code without a format migration;
             take one verified preinstall snapshot and a post-launch health report.
  migration  Schema, identity, entitlement, or build-contract change; take
             verified pre- and post-install snapshots.

When --base is omitted, the script reads installedCommit from --state or from
WHOOP_DEVICE_INSTALL_STATE_PATH. The default --head is HEAD.
EOF
}

base_ref=""
head_ref="HEAD"
state_path="${WHOOP_DEVICE_INSTALL_STATE_PATH:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    --head)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      head_ref="$2"
      shift 2
      ;;
    --state)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      state_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 2; }
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [ -z "$base_ref" ] && [ -n "$state_path" ] && [ -f "$state_path" ]; then
  command -v jq >/dev/null 2>&1 || { echo "jq is required to read install state" >&2; exit 2; }
  base_ref=$(jq -r '.installedCommit // empty' "$state_path")
fi

head_commit=$(git rev-parse --verify "$head_ref^{commit}")

if [ -z "$base_ref" ]; then
  printf 'mode=migration\nbase=unknown\nhead=%s\nreason=no installed-commit baseline; fail closed\n' "$head_commit"
  exit 0
fi

base_commit=$(git rev-parse --verify "$base_ref^{commit}" 2>/dev/null || true)
if [ -z "$base_commit" ]; then
  printf 'mode=migration\nbase=%s\nhead=%s\nreason=installed baseline is not available locally; fetch or take full snapshots\n' "$base_ref" "$head_commit"
  exit 0
fi

if ! git merge-base --is-ancestor "$base_commit" "$head_commit"; then
  printf 'mode=migration\nbase=%s\nhead=%s\nreason=installed baseline is not an ancestor of the candidate; fail closed\n' "$base_commit" "$head_commit"
  exit 0
fi

changed_files=$(git diff --name-only "$base_commit..$head_commit")
if [ -z "$changed_files" ]; then
  printf 'mode=none\nbase=%s\nhead=%s\nreason=already installed\n' "$base_commit" "$head_commit"
  exit 0
fi

production_files=$(printf '%s\n' "$changed_files" | awk '
  /^WhoopApp\// || /^WhoopKit\// || /^project\.yml$/ || /^Whoop\.xcodeproj\// { print }
')

if [ -z "$production_files" ]; then
  printf 'mode=none\nbase=%s\nhead=%s\nreason=no production app files changed\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$(printf '%s' "$changed_files" | tr '\n' ',')"
  exit 0
fi

non_presentation_files=$(printf '%s\n' "$production_files" | awk '
  /^WhoopApp\/RootView\.swift$/ { next }
  /^WhoopApp\/DashboardComponents\.swift$/ { next }
  /^WhoopApp\/DashboardHeader\.swift$/ { next }
  /^WhoopApp\/DashboardChartState\.swift$/ { next }
  /^WhoopApp\/DashboardChartGeometry\.swift$/ { next }
  /^WhoopApp\/MetricTrendCard\.swift$/ { next }
  /^WhoopApp\/TrendSupport\.swift$/ { next }
  /^WhoopApp\/Assets\.xcassets\// { next }
  /^Whoop\.xcodeproj\// { next }
  { print }
')

# These views are normally presentation-only, but fail closed if a future edit
# puts persistence, migration, destructive SQL, or bundle-identity mechanics
# in either component.
if git diff -U0 "$base_commit..$head_commit" -- \
  WhoopApp/RootView.swift WhoopApp/DashboardComponents.swift WhoopApp/DashboardHeader.swift \
  WhoopApp/DashboardChartState.swift WhoopApp/DashboardChartGeometry.swift \
  WhoopApp/MetricTrendCard.swift WhoopApp/TrendSupport.swift | \
  grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' | \
  grep -Eiq 'SQLite|WhoopStore|schema|migrat|DELETE[[:space:]]+FROM|DROP[[:space:]]+TABLE|bundleIdentifier|FileManager.*remove'; then
  printf 'mode=migration\nbase=%s\nhead=%s\nreason=risk-sensitive storage or identity code appeared in a presentation component\n' \
    "$base_commit" "$head_commit"
  exit 0
fi

# Generated project churn follows source additions and is verified separately.
# Escalate only source-of-truth build settings or explicit data-format mechanics.
if printf '%s\n' "$production_files" | grep -Eq '^project\.yml$|\.entitlements$'; then
  printf 'mode=migration\nbase=%s\nhead=%s\nreason=build identity, signing, capability, or entitlement contract changed\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$(printf '%s' "$production_files" | tr '\n' ',')"
  exit 0
fi

schema_version_at() {
  git show "$1:WhoopKit/WhoopStore.swift" 2>/dev/null | \
    sed -nE 's/.*private static let (currentSchemaVersion|schemaVersion)[[:space:]]*=[[:space:]]*([0-9]+).*/\2/p' | \
    head -n 1
}

base_schema_version=$(schema_version_at "$base_commit")
head_schema_version=$(schema_version_at "$head_commit")
if [ -z "$base_schema_version" ] || [ -z "$head_schema_version" ]; then
  printf 'mode=migration\nbase=%s\nhead=%s\nreason=cannot prove the production schema version is unchanged; fail closed\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$(printf '%s' "$production_files" | tr '\n' ',')"
  exit 0
fi

if [ "$base_schema_version" != "$head_schema_version" ]; then
  printf 'mode=migration\nbase=%s\nhead=%s\nreason=production schema version changed from %s to %s\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$base_schema_version" "$head_schema_version" \
    "$(printf '%s' "$production_files" | tr '\n' ',')"
  exit 0
fi

# A read-only PRAGMA user_version query and a same-valued schema constant rename
# are observability/refactor changes, not migrations. Escalate SQL only when the
# diff adds a schema write or DDL operation.
if git diff -U0 "$base_commit..$head_commit" -- WhoopApp WhoopKit project.yml | \
  grep -E '^\+' | grep -Ev '^\+\+\+' | \
  grep -Eiq 'PRAGMA[[:space:]]+user_version[[:space:]]*=|CREATE[[:space:]]+TABLE|ALTER[[:space:]]+TABLE|DROP[[:space:]]+TABLE|PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN|\.entitlements'; then
  printf 'mode=migration\nbase=%s\nhead=%s\nreason=schema, identity, signing, or entitlement mechanics changed\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$(printf '%s' "$production_files" | tr '\n' ',')"
  exit 0
fi

if [ -n "$non_presentation_files" ]; then
  printf 'mode=protected\nbase=%s\nhead=%s\nreason=runtime or storage implementation changed without a schema or identity migration\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$(printf '%s' "$non_presentation_files" | tr '\n' ',')"
  exit 0
fi

printf 'mode=fast\nbase=%s\nhead=%s\nreason=presentation-only production change\nfiles=%s\n' \
  "$base_commit" "$head_commit" "$(printf '%s' "$production_files" | tr '\n' ',')"
