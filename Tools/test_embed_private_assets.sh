#!/bin/bash

set -euo pipefail

fixture="$(mktemp -d "${TMPDIR:-/tmp}/whoop-private-assets.XXXXXX")"

cleanup() {
  rm -rf "$fixture"
}
trap cleanup EXIT

source_root="$fixture/source"
build_root="$fixture/build"
resource_folder="WHOOP.app"
mkdir -p "$source_root" "$build_root/$resource_folder"

assets=(
  whoop-history.json
  whoop-score-model.json
  whoop-recovery-model.json
  whoop-official-metrics.json
  whoop-official-archive.sqlite3
)

for asset in "${assets[@]}"; do
  printf 'synthetic %s\n' "$asset" > "$source_root/$asset"
done

run_embed() {
  CONFIGURATION="$1" \
    PLATFORM_NAME="$2" \
    TARGET_BUILD_DIR="$build_root" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="$resource_folder" \
    WHOOP_HISTORY_SEED_PATH="$source_root/whoop-history.json" \
    WHOOP_SCORE_MODEL_PATH="$source_root/whoop-score-model.json" \
    WHOOP_RECOVERY_MODEL_PATH="$source_root/whoop-recovery-model.json" \
    WHOOP_OFFICIAL_METRICS_PATH="$source_root/whoop-official-metrics.json" \
    WHOOP_OFFICIAL_ARCHIVE_PATH="$source_root/whoop-official-archive.sqlite3" \
    "$(git rev-parse --show-toplevel)/Tools/embed_private_assets.sh"
}

run_embed Debug iphonesimulator
for asset in "${assets[@]}"; do
  cmp "$source_root/$asset" "$build_root/$resource_folder/$asset"
done

rm "$source_root/whoop-score-model.json"
run_embed Debug iphonesimulator
if [ -e "$build_root/$resource_folder/whoop-score-model.json" ]; then
  echo "Missing source should remove a stale embedded asset." >&2
  exit 1
fi

if run_embed Release iphoneos >/dev/null 2>&1; then
  echo "A device Release must fail closed when a private asset is missing." >&2
  exit 1
fi

echo "Private asset embedding tests passed."
