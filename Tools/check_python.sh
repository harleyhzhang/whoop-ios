#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required. Run: brew bundle --file Brewfile" >&2
    exit 1
fi

uv sync --frozen --all-groups --quiet
uv run --frozen ruff check Tools ToolsTests
uv run --frozen ruff format --check Tools ToolsTests
uv run --frozen mypy
uv run --frozen pytest

echo "Python formatting, lint, type, and unit checks passed."
