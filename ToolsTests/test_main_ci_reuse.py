from __future__ import annotations

import check_main_ci_reuse


def test_main_ci_reuse_requires_identical_tree_merged_pr_and_trusted_check() -> None:
    main: dict[str, object] = {"tree": {"sha": "tree-1"}}
    head: dict[str, object] = {"tree": {"sha": "tree-1"}}
    pulls: list[dict[str, object]] = [
        {"merged_at": "2026-09-13T12:00:00Z", "base": {"ref": "main"}}
    ]
    checks: list[dict[str, object]] = [
        {
            "name": "Local quality gate",
            "status": "completed",
            "conclusion": "success",
            "app": {"slug": "github-actions"},
        }
    ]

    assert check_main_ci_reuse.reusable_pr_check(main, pulls, head, checks)
    assert not check_main_ci_reuse.reusable_pr_check(
        main, pulls, {"tree": {"sha": "different"}}, checks
    )
    assert not check_main_ci_reuse.reusable_pr_check(
        main, pulls, head, [{**checks[0], "conclusion": "failure"}]
    )
    assert not check_main_ci_reuse.reusable_pr_check(
        main, pulls, head, [{**checks[0], "app": {"slug": "untrusted"}}]
    )
    assert not check_main_ci_reuse.reusable_pr_check(main, [], head, checks)
