#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

baseline="Tools/swift_file_size_baseline.json"
maximum_lines="$(jq -r '.maximumLines' "$baseline")"
violations=0

while IFS= read -r swift_file; do
  line_count="$(wc -l < "$swift_file" | tr -d ' ')"
  if [ "$line_count" -gt "$maximum_lines" ]; then
    legacy_limit="$(jq -r --arg path "$swift_file" '.legacyMaximumLines[$path] // empty' "$baseline")"
    if [ -z "$legacy_limit" ] || [ "$line_count" -gt "$legacy_limit" ]; then
      echo "$swift_file has $line_count lines; split it below $maximum_lines lines." >&2
      violations=1
    fi
  fi
done < <(find SleepApp WhoopHandshakeApp SleepTests -type f -name '*.swift' -print | sort)

if [ "$violations" -ne 0 ]; then
  exit 1
fi

echo "Swift files stay below $maximum_lines lines or their shrinking legacy baseline."
