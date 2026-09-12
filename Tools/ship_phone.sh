#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
exec uv run --frozen python Tools/phone_shipping.py ship "$@"
