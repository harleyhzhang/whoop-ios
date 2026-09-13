# Testing and CI

## Canonical gate

`Tools/verify_local.sh` is the single merge gate. It runs:

1. the exact `Tools/toolchain.json` Xcode/SDK/runtime/formula contract;
2. strict `swift-format`, presentation/test Swift file-size budgets, shellcheck,
   actionlint, Ruff, strict mypy, and Python tests;
3. generated Xcode/model-feature drift, documentation drift, and phone-policy tests;
4. tracked private-data checks plus gitleaks over history and the worktree;
5. Swift unit and UI tests with zero failures and zero skips;
6. a 58% whole-app line-coverage floor plus higher file-specific floors for
   scoring, protocol, persistence, and migration-critical modules;
7. a Release simulator build and Xcode static analysis.

The gate creates and deletes an isolated simulator per run, preventing an open
development simulator or another test process from making CI flaky.

Use the warm-cache inner loop while editing:

```bash
Tools/check_fast.sh
```

It reuses `DerivedData-fast` and one `WHOOP Fast Loop` simulator and runs the
unit target by default; pass an explicit Xcode `-only-testing:` selector to
narrow or switch the test layer. The exhaustive gate deliberately reuses
neither cache. Run it on the final clean commit:

```bash
Tools/verify_local.sh
```

The committed pre-push hook first looks for a successful gate attestation less
than 24 hours old whose exact HEAD, Git tree, and observed toolchain fingerprint
match. A miss runs the complete gate. CI always runs the gate and never trusts a
developer-machine attestation. Install the hook with `Tools/install_git_hooks.sh`.

## Test layers

- `SleepTests`: deterministic protocol, scoring, notification, storage,
  migration, and state-machine unit/integration tests using synthetic data.
- `SleepUITests`: critical dashboard behavior and diagnostic navigation under
  explicit mock launch environment values.
- `ToolsTests`: Python feature construction, build-gate, model-promotion, and
  private-seed projection logic.
- `SleepPrivateTests`: opt-in checks against local personal models. Run with
  `Tools/verify_private_models.sh`; missing private inputs are failures here, not
  skipped public tests. Its generated synthetic fixture is the same golden vector
  consumed by Python, which catches feature-order drift across languages.
- `Tools/verify_sanitizers.sh`: AddressSanitizer and ThreadSanitizer runs for
  risky memory, concurrency, persistence, or protocol changes.
- `ToolsTests/test_phone_shipping.py`: deterministic private-asset contracts,
  device/container parsing, backup integrity and preservation, atomic install
  state, and exact-merged-commit shipping policy.

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
