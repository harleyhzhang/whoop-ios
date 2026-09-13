#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

guide="docs/whoop-data-migration.md"
rg -qi 'store currently targets schema 10' "$guide"
rg -qi 'there is no manual Process control or loading state' "$guide"

if rg -qi 'store currently targets schema 9|tap (the )?Process|manual Process control is available' "$guide"; then
  echo "Migration guide contains superseded schema-9 or manual-Process instructions." >&2
  exit 1
fi

echo "Migration guide matches schema 10 and automatic-only sleep publication."
