from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import cast

REUSE_UNAVAILABLE = 75
QUALITY_GATE_NAME = "Local quality gate"


def reusable_pr_check(
    main_commit: dict[str, object],
    pull_requests: list[dict[str, object]],
    head_commit: dict[str, object],
    check_runs: list[dict[str, object]],
) -> bool:
    main_tree = main_commit.get("tree")
    head_tree = head_commit.get("tree")
    if not isinstance(main_tree, dict) or not isinstance(head_tree, dict):
        return False
    if main_tree.get("sha") != head_tree.get("sha"):
        return False
    if not any(
        pull.get("merged_at")
        and isinstance(pull.get("base"), dict)
        and cast(dict[str, object], pull["base"]).get("ref") == "main"
        for pull in pull_requests
    ):
        return False
    for check in check_runs:
        app = check.get("app")
        if (
            check.get("name") == QUALITY_GATE_NAME
            and check.get("status") == "completed"
            and check.get("conclusion") == "success"
            and isinstance(app, dict)
            and app.get("slug") == "github-actions"
        ):
            return True
    return False


def github_json(path: str, token: str) -> object:
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise RuntimeError(f"GitHub API request failed for {path}: {error}") from error


def main() -> int:
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    sha = os.environ.get("GITHUB_SHA", "")
    token = os.environ.get("GH_TOKEN", "")
    if not repository or not sha or not token:
        print("No reusable PR result: GitHub repository, SHA, and token are required.")
        return REUSE_UNAVAILABLE
    try:
        pull_value = github_json(f"/repos/{repository}/commits/{sha}/pulls", token)
        pulls = pull_value if isinstance(pull_value, list) else []
        normalized_pulls = [
            cast(dict[str, object], item) for item in pulls if isinstance(item, dict)
        ]
        merged = next(
            (
                pull
                for pull in normalized_pulls
                if pull.get("merged_at")
                and isinstance(pull.get("head"), dict)
                and isinstance(pull.get("base"), dict)
                and cast(dict[str, object], pull["base"]).get("ref") == "main"
            ),
            None,
        )
        if not isinstance(merged, dict):
            print("No reusable PR result: main commit has no associated merged PR.")
            return REUSE_UNAVAILABLE
        head = cast(dict[str, object], merged["head"]).get("sha")
        if not isinstance(head, str) or not head:
            return REUSE_UNAVAILABLE
        main_commit = github_json(f"/repos/{repository}/git/commits/{sha}", token)
        head_commit = github_json(f"/repos/{repository}/git/commits/{head}", token)
        checks_value = github_json(
            f"/repos/{repository}/commits/{head}/check-runs?per_page=100", token
        )
        checks_mapping = checks_value if isinstance(checks_value, dict) else {}
        checks = checks_mapping.get("check_runs", [])
        if not all(
            isinstance(value, expected)
            for value, expected in (
                (main_commit, dict),
                (head_commit, dict),
                (checks, list),
            )
        ):
            return REUSE_UNAVAILABLE
        if reusable_pr_check(
            cast(dict[str, object], main_commit),
            normalized_pulls,
            cast(dict[str, object], head_commit),
            [cast(dict[str, object], item) for item in checks if isinstance(item, dict)],
        ):
            print(f"Reusing successful PR quality gate for identical tree at {head}.")
            return 0
    except RuntimeError as error:
        print(f"No reusable PR result: {error}")
        return REUSE_UNAVAILABLE
    print("No reusable PR result: tree or trusted quality gate did not match.")
    return REUSE_UNAVAILABLE


if __name__ == "__main__":
    sys.exit(main())
