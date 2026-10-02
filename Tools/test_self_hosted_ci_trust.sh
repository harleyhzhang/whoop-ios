#!/bin/bash

set -euo pipefail

export TRUSTED_ACTOR=owner

repo_root="$(git rev-parse --show-toplevel)"
policy="$repo_root/Tools/check_self_hosted_ci_trust.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/whoop-ci-trust.XXXXXX")"

cleanup() {
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

assert_passes() {
  description="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "Expected policy to allow: $description" >&2
    exit 1
  fi
}

assert_rejects() {
  description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "Expected policy to reject: $description" >&2
    exit 1
  fi
}

trusted_pr=(
  env
  CI_EVENT_NAME=pull_request_target
  CI_ACTOR=owner
  CI_REPOSITORY=owner/whoop-ios
  CI_PR_AUTHOR=owner
  CI_PR_HEAD_REPOSITORY=owner/whoop-ios
  "$policy"
)

assert_passes "trusted push" \
  env CI_EVENT_NAME=push CI_ACTOR=owner "$policy"
assert_rejects "untrusted workflow dispatch" \
  env CI_EVENT_NAME=workflow_dispatch CI_ACTOR=mallory "$policy"
assert_passes "trusted same-repository pull request" "${trusted_pr[@]}"
assert_rejects "trusted initiator rerunning an untrusted author's pull request" \
  env CI_EVENT_NAME=pull_request_target CI_ACTOR=owner \
  CI_REPOSITORY=owner/whoop-ios CI_PR_AUTHOR=mallory \
  CI_PR_HEAD_REPOSITORY=owner/whoop-ios "$policy"
assert_rejects "trusted author's fork pull request" \
  env CI_EVENT_NAME=pull_request_target CI_ACTOR=owner \
  CI_REPOSITORY=owner/whoop-ios CI_PR_AUTHOR=owner \
  CI_PR_HEAD_REPOSITORY=owner/whoop-ios-fork "$policy"
assert_rejects "untrusted initiator on a trusted pull request" \
  env CI_EVENT_NAME=pull_request_target CI_ACTOR=mallory \
  CI_REPOSITORY=owner/whoop-ios CI_PR_AUTHOR=owner \
  CI_PR_HEAD_REPOSITORY=owner/whoop-ios "$policy"

cat >"$fixture/allowed.json" <<'JSON'
[
  {
    "filename": ".github/workflows/local-ci.yml",
    "status": "modified",
    "patch": "@@ -1,1 +1,1 @@\n-        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v5\n+        uses: actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v6"
  }
]
JSON

dependabot_pr=(
  env
  CI_EVENT_NAME=pull_request_target
  CI_ACTOR=owner
  CI_REPOSITORY=owner/whoop-ios
  CI_PR_AUTHOR=dependabot[bot]
  CI_PR_HEAD_REPOSITORY=owner/whoop-ios
  CI_PR_CHANGED_FILES=1
  "$policy"
)

assert_passes "pinned actions/checkout Dependabot update" \
  "${dependabot_pr[@]}" "$fixture/allowed.json"

cat >"$fixture/disallowed-path.json" <<'JSON'
[
  {
    "filename": "Tools/verify_local.sh",
    "status": "modified",
    "patch": "@@ -1,1 +1,1 @@\n-old\n+new"
  }
]
JSON
assert_rejects "Dependabot change outside the workflow allowlist" \
  "${dependabot_pr[@]}" "$fixture/disallowed-path.json"

cat >"$fixture/disallowed-content.json" <<'JSON'
[
  {
    "filename": ".github/workflows/local-ci.yml",
    "status": "modified",
    "patch": "@@ -1,1 +1,1 @@\n-        run: Tools/verify_local.sh\n+        run: Tools/untrusted.sh"
  }
]
JSON
assert_rejects "Dependabot workflow code change" \
  "${dependabot_pr[@]}" "$fixture/disallowed-content.json"

cat >"$fixture/deletion-only.json" <<'JSON'
[
  {
    "filename": ".github/workflows/local-ci.yml",
    "status": "modified",
    "patch": "@@ -1,1 +1,0 @@\n-        uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v5"
  }
]
JSON
assert_rejects "Dependabot action deletion without a replacement" \
  "${dependabot_pr[@]}" "$fixture/deletion-only.json"
assert_rejects "incomplete Dependabot metadata" \
  env CI_EVENT_NAME=pull_request_target CI_ACTOR=dependabot[bot] \
  CI_REPOSITORY=owner/whoop-ios CI_PR_AUTHOR=dependabot[bot] \
  CI_PR_HEAD_REPOSITORY=owner/whoop-ios CI_PR_CHANGED_FILES=2 \
  "$policy" "$fixture/allowed.json"

echo "Self-hosted CI trust policy tests passed."
