#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

private_name_pattern='(^|/)(sleep\.sqlite3([.-].*)?|whoop-history\.json|whoop-score-model\.json|whoop-recovery-model\.json|whoop-strain-model\.json|whoop-official-metrics\.json|whoop-official-archive\.sqlite3|.*\.(ipa|mobileprovision|p12|cer|pem|key)|\.env(\..*)?)$'

if git ls-files | grep -Eiq "$private_name_pattern"; then
    echo "Private WHOOP runtime, signing, or environment data must not be committed." >&2
    git ls-files | grep -Ei "$private_name_pattern" >&2
    exit 1
fi

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "gitleaks is required. Run: brew bundle --file Brewfile" >&2
    exit 1
fi

gitleaks git --no-banner --redact --log-opts="--all" "$repo_dir"
gitleaks dir --no-banner --redact "$repo_dir"

echo "Private-data and secret checks passed."
