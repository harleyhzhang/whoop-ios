#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
if [ "${1:-}" = "--plan" ]; then
    shift
    exec uv run --frozen python Tools/phone_shipping.py plan "$@"
fi
exec uv run --frozen python Tools/phone_shipping.py ship "$@"
