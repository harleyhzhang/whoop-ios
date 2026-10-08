#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

guide="docs/whoop-data-migration.md"
schema="$(sed -nE 's/.*static let currentSchemaVersion = ([0-9]+).*/\1/p' WhoopKit/WhoopStore.swift)"
[ -n "$schema" ]
grep -Eqi "store currently targets schema $schema" "$guide"
grep -Eqi 'there is no manual Process control or loading state' "$guide"

if grep -Eqi 'tap (the )?Process|manual Process control is available' "$guide"; then
  echo "Migration guide contains superseded manual-Process instructions." >&2
  exit 1
fi

echo "Migration guide matches schema $schema and automatic-only sleep publication."
