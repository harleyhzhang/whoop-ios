#!/bin/sh

set -eu

repo_root=$(git rev-parse --show-toplevel)
policy="$repo_root/Tools/phone_install_policy.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/whoop-install-policy.XXXXXX")

# Git exports repository-local environment while hooks run. Clear it before
# creating the nested fixture so its commits cannot mutate the calling repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX

cleanup() {
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

mode_for() {
  "$policy" "$@" | awk -F= '$1 == "mode" { print $2; exit }'
}

assert_mode() {
  expected="$1"
  shift
  actual=$(mode_for "$@")
  if [ "$actual" != "$expected" ]; then
    echo "Expected mode $expected, got $actual for: $*" >&2
    exit 1
  fi
}

cd "$fixture"
git init -q
git config user.name "WHOOP policy test"
git config user.email "whoop-policy-test@example.invalid"
mkdir -p SleepApp/Assets.xcassets WhoopHandshakeApp docs
printf 'struct RootView {}\n' > SleepApp/RootView.swift
printf 'struct WhoopStore {}\n' > SleepApp/SleepModels.swift
printf '{}\n' > SleepApp/Assets.xcassets/Contents.json
printf 'struct HandshakeView {}\n' > WhoopHandshakeApp/HandshakeView.swift
printf 'struct WhoopHandshakeProbe {}\n' > WhoopHandshakeApp/WhoopHandshakeProbe.swift
printf 'struct WhoopPersistence {}\n' > WhoopHandshakeApp/WhoopStore.swift
printf 'baseline\n' > README.md
git add .
git commit -qm baseline
baseline=$(git rev-parse HEAD)

printf 'documentation only\n' >> README.md
git commit -qam docs
docs_commit=$(git rev-parse HEAD)
assert_mode none --base "$baseline" --head "$docs_commit"

printf '// chart color\n' >> SleepApp/RootView.swift
git commit -qam ui
ui_commit=$(git rev-parse HEAD)
assert_mode fast --base "$docs_commit" --head "$ui_commit"

printf '// schema migration\n' >> SleepApp/RootView.swift
git commit -qam risky_ui
risky_ui_commit=$(git rev-parse HEAD)
assert_mode full --base "$ui_commit" --head "$risky_ui_commit"

printf '// storage change\n' >> SleepApp/SleepModels.swift
git commit -qam storage
storage_commit=$(git rev-parse HEAD)
assert_mode full --base "$risky_ui_commit" --head "$storage_commit"

printf '// connection presentation\n' >> WhoopHandshakeApp/HandshakeView.swift
git commit -qam connection_ui
connection_ui_commit=$(git rev-parse HEAD)
assert_mode fast --base "$storage_commit" --head "$connection_ui_commit"

printf '// bluetooth lifecycle\n' >> WhoopHandshakeApp/WhoopHandshakeProbe.swift
git commit -qam bluetooth
bluetooth_commit=$(git rev-parse HEAD)
assert_mode full --base "$connection_ui_commit" --head "$bluetooth_commit"

printf '// schema migration\n' >> WhoopHandshakeApp/WhoopStore.swift
git commit -qam persistence
persistence_commit=$(git rev-parse HEAD)
assert_mode full --base "$bluetooth_commit" --head "$persistence_commit"

assert_mode full --head "$persistence_commit"

echo "Phone install policy tests passed."
