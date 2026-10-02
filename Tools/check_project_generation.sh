#!/bin/bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/whoop-xcodegen-check.XXXXXX")"

cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required. Run: brew bundle --file Brewfile" >&2
    exit 1
fi

cp "$repo_dir/project.yml" "$scratch/project.yml"
ln -s "$repo_dir/Config" "$scratch/Config"
ln -s "$repo_dir/WhoopApp" "$scratch/WhoopApp"
ln -s "$repo_dir/WhoopTests" "$scratch/WhoopTests"
ln -s "$repo_dir/WhoopKit" "$scratch/WhoopKit"
if [ -d "$repo_dir/WhoopUITests" ]; then
    ln -s "$repo_dir/WhoopUITests" "$scratch/WhoopUITests"
fi
if [ -d "$repo_dir/WhoopPrivateTests" ]; then
    ln -s "$repo_dir/WhoopPrivateTests" "$scratch/WhoopPrivateTests"
fi

xcodegen generate --spec "$scratch/project.yml" --quiet

files=("project.pbxproj")
while IFS= read -r scheme; do
    files+=("xcshareddata/xcschemes/$(basename "$scheme")")
done < <(find "$repo_dir/Whoop.xcodeproj/xcshareddata/xcschemes" -type f -name '*.xcscheme' | sort)

for relative_path in "${files[@]}"; do
    committed="$repo_dir/Whoop.xcodeproj/$relative_path"
    generated="$scratch/Whoop.xcodeproj/$relative_path"
    if ! cmp -s "$committed" "$generated"; then
        echo "Whoop.xcodeproj is stale: $relative_path differs from project.yml." >&2
        echo "Run 'xcodegen generate' and commit the generated project." >&2
        diff -u "$committed" "$generated" || true
        exit 1
    fi
done

echo "Generated Xcode project matches project.yml."
