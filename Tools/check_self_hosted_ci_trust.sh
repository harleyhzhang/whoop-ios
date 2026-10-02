#!/bin/bash

set -euo pipefail

trusted_actor="${TRUSTED_ACTOR:-${GITHUB_REPOSITORY_OWNER:-}}"
trusted_dependabot_actor="${TRUSTED_DEPENDABOT_ACTOR:-dependabot[bot]}"
event_name="${CI_EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
actor="${CI_ACTOR:-${GITHUB_ACTOR:-}}"
repository="${CI_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
pr_author="${CI_PR_AUTHOR:-}"
pr_head_repository="${CI_PR_HEAD_REPOSITORY:-}"
pr_changed_files="${CI_PR_CHANGED_FILES:-}"
pr_files_json="${1:-}"

fail() {
  echo "Refusing self-hosted execution: $1" >&2
  exit 1
}

is_trusted_identity() {
  [ "$1" = "$trusted_actor" ] || [ "$1" = "$trusted_dependabot_actor" ]
}

if [ -z "$trusted_actor" ]; then
  fail "TRUSTED_ACTOR or GITHUB_REPOSITORY_OWNER is required."
fi

if [ -z "$event_name" ] || [ -z "$actor" ]; then
  fail "the event name and initiating actor are required."
fi

if ! is_trusted_identity "$actor"; then
  fail "initiating actor '$actor' is not trusted."
fi

if [ "$event_name" != "pull_request_target" ]; then
  echo "Trusted $event_name execution initiated by $actor."
  exit 0
fi

if [ -z "$repository" ] || [ -z "$pr_author" ] || [ -z "$pr_head_repository" ]; then
  fail "pull-request repository, author, and head repository are required."
fi

if ! is_trusted_identity "$pr_author"; then
  fail "pull-request author '$pr_author' is not trusted."
fi

if [ "$pr_head_repository" != "$repository" ]; then
  fail "pull-request head '$pr_head_repository' is not the protected repository '$repository'."
fi

if [ "$pr_author" != "$trusted_dependabot_actor" ]; then
  echo "Trusted same-repository pull request authored by $pr_author and initiated by $actor."
  exit 0
fi

if ! [[ "$pr_changed_files" =~ ^[1-9][0-9]*$ ]]; then
  fail "Dependabot changed-file count is missing or invalid."
fi

if [ "$pr_changed_files" -gt 100 ]; then
  fail "Dependabot changed $pr_changed_files files; the policy only validates up to 100."
fi

if [ -z "$pr_files_json" ] || [ ! -f "$pr_files_json" ]; then
  fail "Dependabot changed-file metadata is required."
fi

if ! jq -e --argjson expected "$pr_changed_files" \
  'type == "array" and length == $expected' "$pr_files_json" >/dev/null; then
  fail "Dependabot changed-file metadata is incomplete or malformed."
fi

validated_lines=0
while IFS= read -r file_entry; do
  filename="$(jq -r '.filename // empty' <<<"$file_entry")"
  status="$(jq -r '.status // empty' <<<"$file_entry")"
  patch="$(jq -r '.patch // empty' <<<"$file_entry")"

  case "$filename" in
    .github/workflows/ios-ci.yml | .github/workflows/local-ci.yml) ;;
    *) fail "Dependabot changed disallowed path '$filename'." ;;
  esac

  if [ "$status" != "modified" ]; then
    fail "Dependabot may only modify an existing allowlisted workflow; '$filename' is '$status'."
  fi

  if [ -z "$patch" ]; then
    fail "Dependabot patch metadata is missing for '$filename'."
  fi

  added_lines=0
  removed_lines=0
  while IFS= read -r line; do
    case "$line" in
      "+++"* | "---"*) continue ;;
      "+"* | "-"*)
        if [[ ! "$line" =~ ^[+-][[:space:]]+uses:[[:space:]]+actions/checkout@[0-9a-f]{40}([[:space:]]+#[[:space:]]*v?[0-9]+([.][0-9]+){0,2})?[[:space:]]*$ ]]; then
          fail "Dependabot changed content outside the pinned actions/checkout reference in '$filename'."
        fi
        if [[ "$line" == "+"* ]]; then
          added_lines=$((added_lines + 1))
        else
          removed_lines=$((removed_lines + 1))
        fi
        validated_lines=$((validated_lines + 1))
        ;;
    esac
  done <<<"$patch"

  if [ "$added_lines" -eq 0 ] || [ "$added_lines" -ne "$removed_lines" ]; then
    fail "Dependabot must replace pinned actions/checkout references one-for-one in '$filename'."
  fi
done < <(jq -c '.[]' "$pr_files_json")

if [ "$validated_lines" -eq 0 ]; then
  fail "Dependabot supplied no allowlisted action-pin changes."
fi

echo "Trusted Dependabot action-pin update authored by $pr_author and initiated by $actor."
