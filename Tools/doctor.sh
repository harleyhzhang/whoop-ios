#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if [ "${1:-}" = "--toolchain-only" ]; then
    if [ "$#" -ne 1 ]; then
        echo "--toolchain-only does not accept phone-shipping arguments." >&2
        exit 2
    fi
    exec uv run --frozen python Tools/toolchain.py
fi

exec uv run --frozen python Tools/phone_shipping.py doctor "$@"
