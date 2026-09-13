# Contributing

This repository is an offline-first personal health application. Correctness,
data preservation, privacy, and reproducibility matter more than shortcutting a
check.

## Setup

Requirements are the current Xcode selected by `xcode-select`, Homebrew, and an
iOS Simulator. Install the remaining pinned tools and the local pre-push hook:

```bash
brew bundle --file Brewfile
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
- Run `Tools/verify_local.sh` and fix every failure before requesting review.
- For storage, concurrency, or unsafe-memory work, also run
  `Tools/verify_sanitizers.sh`.
- Use `Tools/ship_phone.sh --commit <exact-merged-sha>` for every physical
  install; follow the data-preservation and resume policy in `AGENTS.md`.

## Pull requests

Keep changes focused and explain the user-visible result, risks, tests, and any
data migration. The automatic workflow runs the same canonical gate on a
self-hosted Mac and does not spend GitHub-hosted macOS minutes. The hosted iOS
workflow must remain manual-only.

Private health exports, databases, signing material, credentials, `.env` files,
or fitted personal models never belong in Git. Synthetic fixtures must be
obviously synthetic.
