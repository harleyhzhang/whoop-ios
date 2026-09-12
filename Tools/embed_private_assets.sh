#!/bin/bash

set -euo pipefail

private_root="${WHOOP_PRIVATE_SEED_ROOT:-${HOME}/Documents/personal/data/whoop/app-seeds}"
resource_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

asset_specs=(
  "WHOOP_HISTORY_SEED_PATH:whoop-history.json"
  "WHOOP_SCORE_MODEL_PATH:whoop-score-model.json"
  "WHOOP_RECOVERY_MODEL_PATH:whoop-recovery-model.json"
  "WHOOP_OFFICIAL_METRICS_PATH:whoop-official-metrics.json"
  "WHOOP_OFFICIAL_ARCHIVE_PATH:whoop-official-archive.sqlite3"
)

missing=()
for spec in "${asset_specs[@]}"; do
  environment_name="${spec%%:*}"
  filename="${spec#*:}"
  configured_path="${!environment_name:-}"
  source_path="${configured_path:-${private_root}/${filename}}"
  destination_path="${resource_root}/${filename}"

  if [ -f "$source_path" ]; then
    if ! /usr/bin/cmp -s "$source_path" "$destination_path"; then
      /bin/cp "$source_path" "$destination_path"
    fi
  else
    /bin/rm -f "$destination_path"
    missing+=("$filename")
  fi
done

if [ "${CONFIGURATION}" = "Release" ] && [ "${PLATFORM_NAME}" = "iphoneos" ] && [ "${#missing[@]}" -gt 0 ]; then
  printf 'error: Personal WHOOP device releases require private assets; missing: %s\n' "${missing[*]}" >&2
  exit 1
fi
