#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
if [ "${1:-}" = "--plan" ]; then
    shift
    exec uv run --frozen python Tools/phone_shipping.py plan "$@"
fi
uv run --frozen python Tools/phone_shipping.py ship "$@"

if [ "${WHOOP_SKIP_CONVEX_REPLICA:-0}" = "1" ]; then
    echo "Skipping the Convex replica because WHOOP_SKIP_CONVEX_REPLICA=1."
elif security find-generic-password \
    -a api-token \
    -s com.clintonst.whoop.convex-replica >/dev/null 2>&1; then
    echo "Uploading the newly verified snapshot to the encrypted Convex replica..."
    uv run --frozen python Tools/convex_replica.py upload
else
    echo "Convex replica credentials are unavailable; the verified local backup remains intact." >&2
fi
