#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

maximum_lines=600
violations=0

while IFS= read -r swift_file; do
  line_count="$(wc -l < "$swift_file" | tr -d ' ')"
  if [ "$line_count" -gt "$maximum_lines" ]; then
    echo "$swift_file has $line_count lines; split it below $maximum_lines lines." >&2
    violations=1
  fi
done < <(find SleepApp SleepTests -type f -name '*.swift' -print | sort)

if [ "$violations" -ne 0 ]; then
  exit 1
fi

echo "Swift presentation and test files stay below $maximum_lines lines."
