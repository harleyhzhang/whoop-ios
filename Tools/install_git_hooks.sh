#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$repo_dir" config core.hooksPath .githooks
echo "Installed repository hooks from .githooks/."
