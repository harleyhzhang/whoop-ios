#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: Tools/phone_install_policy.sh [--base REF] [--head REF] [--state PATH]

Classifies a physical-phone install as:
  none  No production app change; do not install.
  fast  Presentation-only change; install in place without copying the database.
  full  Data, storage, model, app lifecycle, identity, or unknown change; take
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
  printf 'mode=full\nbase=unknown\nhead=%s\nreason=no installed-commit baseline; fail closed\n' "$head_commit"
  exit 0
fi

base_commit=$(git rev-parse --verify "$base_ref^{commit}" 2>/dev/null || true)
if [ -z "$base_commit" ]; then
  printf 'mode=full\nbase=%s\nhead=%s\nreason=installed baseline is not available locally; fetch or take a full snapshot\n' "$base_ref" "$head_commit"
  exit 0
fi

if ! git merge-base --is-ancestor "$base_commit" "$head_commit"; then
  printf 'mode=full\nbase=%s\nhead=%s\nreason=installed baseline is not an ancestor of the candidate; fail closed\n' "$base_commit" "$head_commit"
  exit 0
fi

changed_files=$(git diff --name-only "$base_commit..$head_commit")
if [ -z "$changed_files" ]; then
  printf 'mode=none\nbase=%s\nhead=%s\nreason=already installed\n' "$base_commit" "$head_commit"
  exit 0
fi

production_files=$(printf '%s\n' "$changed_files" | awk '
  /^SleepApp\// || /^WhoopHandshakeApp\// || /^project\.yml$/ || /^Sleep\.xcodeproj\// { print }
')

if [ -z "$production_files" ]; then
  printf 'mode=none\nbase=%s\nhead=%s\nreason=no production app files changed\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$(printf '%s' "$changed_files" | tr '\n' ',')"
  exit 0
fi

unsafe_files=$(printf '%s\n' "$production_files" | awk '
  /^SleepApp\/RootView\.swift$/ { next }
  /^SleepApp\/DashboardComponents\.swift$/ { next }
  /^SleepApp\/Assets\.xcassets\// { next }
  /^WhoopHandshakeApp\/HandshakeView\.swift$/ { next }
  { print }
')

if [ -n "$unsafe_files" ]; then
  printf 'mode=full\nbase=%s\nhead=%s\nreason=data, lifecycle, identity, build, or unclassified production files changed\nfiles=%s\n' \
    "$base_commit" "$head_commit" "$(printf '%s' "$unsafe_files" | tr '\n' ',')"
  exit 0
fi

# These views are normally presentation-only, but fail closed if a future edit
# puts persistence, migration, destructive SQL, or bundle-identity mechanics
# in either component.
if git diff -U0 "$base_commit..$head_commit" -- \
  SleepApp/RootView.swift SleepApp/DashboardComponents.swift | \
  grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' | \
  grep -Eiq 'SQLite|WhoopStore|schema|migrat|DELETE[[:space:]]+FROM|DROP[[:space:]]+TABLE|bundleIdentifier|FileManager.*remove'; then
  printf 'mode=full\nbase=%s\nhead=%s\nreason=risk-sensitive storage or identity code appeared in a presentation component\n' \
    "$base_commit" "$head_commit"
  exit 0
fi

printf 'mode=fast\nbase=%s\nhead=%s\nreason=presentation-only production change\nfiles=%s\n' \
  "$base_commit" "$head_commit" "$(printf '%s' "$production_files" | tr '\n' ',')"
