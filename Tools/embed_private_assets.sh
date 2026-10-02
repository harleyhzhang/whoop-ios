#!/bin/bash

set -euo pipefail

private_root="${WHOOP_PRIVATE_SEED_ROOT:-${WHOOP_DATA_ROOT:-${HOME}/whoop-data}/app-seeds}"
resource_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
replica_config="${resource_root}/whoop-replica-config.json"

asset_specs=(
  "WHOOP_HISTORY_SEED_PATH:whoop-history.json"
  "WHOOP_SCORE_MODEL_PATH:whoop-score-model.json"
  "WHOOP_RECOVERY_MODEL_PATH:whoop-recovery-model.json"
  "WHOOP_STRAIN_MODEL_PATH:whoop-strain-model.json"
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

if [ "${CONFIGURATION}" = "Release" ] && [ "${PLATFORM_NAME}" = "iphoneos" ] && [ -n "${WHOOP_CONVEX_SITE_URL:-}" ]; then
  replica_service="${WHOOP_REPLICA_KEYCHAIN_SERVICE:-whoop.convex-replica}"
  if ! replica_token="$(security find-generic-password -a phone-upload-token -s "$replica_service" -w 2>/dev/null)" ||
     ! replica_key="$(security find-generic-password -a phone-encryption-key-b64 -s "$replica_service" -w 2>/dev/null)"; then
    echo "error: Personal WHOOP device releases require the phone replica credentials in Keychain." >&2
    exit 1
  fi
  REPLICA_SITE_URL="$WHOOP_CONVEX_SITE_URL" \
  REPLICA_UPLOAD_TOKEN="$replica_token" \
  REPLICA_ENCRYPTION_KEY="$replica_key" \
    /usr/bin/python3 -c 'import json, os, sys; json.dump({"siteURL": os.environ["REPLICA_SITE_URL"], "uploadToken": os.environ["REPLICA_UPLOAD_TOKEN"], "encryptionKeyBase64": os.environ["REPLICA_ENCRYPTION_KEY"]}, sys.stdout, separators=(",", ":"))' \
    > "$replica_config"
  chmod 600 "$replica_config"
  unset replica_token replica_key
else
  /bin/rm -f "$replica_config"
fi

if [ "${WHOOP_REQUIRE_PRIVATE_ASSETS:-0}" = "1" ] && [ "${#missing[@]}" -gt 0 ]; then
  printf 'error: WHOOP_REQUIRE_PRIVATE_ASSETS=1 but private assets are; missing: %s\n' "${missing[*]}" >&2
  exit 1
fi
