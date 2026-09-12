# Testing and CI

## Canonical gate

`Tools/verify_local.sh` is the single merge gate. It runs:

1. strict `swift-format`, shellcheck, actionlint, Ruff, strict mypy, and Python tests;
2. Xcode project-generation drift and phone-policy tests;
3. tracked private-data checks plus gitleaks over history and the worktree;
4. Swift unit and UI tests with zero failures and zero skips;
5. a 58% line-coverage floor for the private-data-free `WHOOP.app` build;
6. a Release simulator build and Xcode static analysis.

The gate creates and deletes an isolated simulator per run, preventing an open
development simulator or another test process from making CI flaky.

Run it before every push:

```bash
Tools/verify_local.sh
```

The committed pre-push hook invokes this command. Install it with
`Tools/install_git_hooks.sh`.

## Test layers

- `SleepTests`: deterministic protocol, scoring, notification, storage,
  migration, and state-machine unit/integration tests using synthetic data.
- `SleepUITests`: critical dashboard behavior and diagnostic navigation under
  explicit mock launch environment values.
- `ToolsTests`: Python feature construction and private-seed projection logic.
- `SleepPrivateTests`: opt-in checks against local personal models. Run with
  `Tools/verify_private_models.sh`; missing private inputs are failures here, not
  skipped public tests.
- `Tools/verify_sanitizers.sh`: AddressSanitizer and ThreadSanitizer runs for
  risky memory, concurrency, persistence, or protocol changes.

Tests may not depend on Bluetooth hardware, network access, local health data,
execution order, or the real wall clock. Inject these boundaries or use
synthetic fixtures.

## GitHub Actions cost policy

`.github/workflows/local-ci.yml` runs the canonical gate on the repository's
trusted, self-hosted Apple-silicon Mac for Harley's pull requests and `main`.
Pull requests use the workflow definition from the protected default branch,
then validate the initiating actor, original author, and same-repository head
before checking out the exact proposed commit. Dependabot may only replace
pinned `actions/checkout` revisions in allowlisted workflow files. Self-hosted
execution does not use GitHub-hosted macOS minutes.

`.github/workflows/ios-ci.yml` is deliberately `workflow_dispatch` only. It is
an emergency hosted fallback and must not gain `push`, `pull_request`, or a
schedule trigger. Keep every third-party action pinned to a full commit SHA.

Dependency updates are monthly and grouped to avoid noisy workflow churn.
Runner maintenance and security invariants are documented in
[self-hosted runner operations](self-hosted-runner.md).
