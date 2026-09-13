#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if grep -R -n --include='*.swift' 'XCTSkip' SleepTests SleepUITests SleepPrivateTests; then
  echo "Test fixtures must fail explicitly; XCTSkip is not allowed." >&2
  exit 1
fi

echo "Test sources contain no skip paths."
