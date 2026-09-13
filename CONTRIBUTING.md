# Contributing

This repository is an offline-first personal health application. Correctness,
data preservation, privacy, and reproducibility matter more than shortcutting a
check.

## Setup

`Tools/toolchain.json` is the exact tested Xcode build, iPhoneOS SDK, simulator
runtime, Python, and Homebrew-formula contract. The Brewfile bootstraps named
formulae but does not itself pin versions; the doctor fails closed on drift.

```bash
brew bundle --file Brewfile
Tools/doctor.sh --toolchain-only
Tools/install_git_hooks.sh
```

`project.yml` owns project structure and build settings. When it changes, run
`xcodegen generate` and commit both the spec and generated Xcode project.

## Definition of done

- Add or update deterministic tests for behavior changes and bug fixes.
- Keep the ordinary suite independent of Harley's private exports and models.
- Do not use force unwraps, force tries, implicitly unwrapped optionals, skipped
  tests, warning suppressions, or broad secret-scan exclusions as shortcuts.
- Format Swift with `swift-format`; format and type-check Python through
  `Tools/check_python.sh`.
- Use `Tools/check_fast.sh` for the warm-cache inner loop.
- Run `Tools/verify_local.sh` on the final clean commit and fix every failure
  before requesting review. The pre-push hook may reuse only a fresh attestation
  for the exact HEAD, tree, and tested toolchain; CI never reuses local evidence.
- For storage, concurrency, or unsafe-memory work, also run
  `Tools/verify_sanitizers.sh`.
- Use `Tools/ship_phone.sh --commit <exact-merged-sha>` for every physical
  install; follow the data-preservation and resume policy in `AGENTS.md`.

## Pull requests

Keep changes focused and explain the user-visible result, risks, tests, and any
data migration. The pull-request workflow runs the canonical gate on a
self-hosted Mac and does not spend GitHub-hosted macOS minutes. The main-branch
run reuses that result only when GitHub reports a successful trusted PR check
for an identical Git tree; otherwise it reruns the full gate. The hosted iOS
workflow must remain manual-only.

Private health exports, databases, signing material, credentials, `.env` files,
or fitted personal models never belong in Git. Synthetic fixtures must be
obviously synthetic.
