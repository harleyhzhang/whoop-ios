# WHOOP iOS

Native SwiftUI client that replaces the official WHOOP app for a personally
owned WHOOP 5: manages the strap, keeps raw data locally, and derives
versioned sleep, recovery, and strain metrics.

## Rules

- Fully useful offline. The hosted replica is optional; no app-side manual
  sync control.
- Privacy: no credentials, signing assets, or real health data in Git.
  Fixtures are synthetic. Demo data lives in `WhoopApp/DemoHistory.swift`.
- Keep raw packet evidence, but compact exact BLE retries on the same
  characteristic. A retry still counts as durably handled before any history
  acknowledgement.
- Never weaken evidence or complete-metric gates to publish sleep faster.

## UI

- All colors, fonts, spacing, and the card background come from
  `WhoopApp/Theme.swift`. No literal sizes or RGB values in views.
- One rounded type family at the sizes in `Theme.Typography`. Mostly greys,
  black, and white; accent colors only for metrics and status.
- Small components with minimal overrides. Pass models, not long prop lists.

## Code

- `project.yml` is the source of truth; run `xcodegen generate` and commit
  `Whoop.xcodeproj`.
- Format with `xcrun swift-format format --configuration .swift-format
  --in-place <files>`. No force unwraps, force tries, or IUOs. Warnings are
  errors; strict concurrency stays `complete`.
- Keep framework callbacks thin; put decisions in pure, testable types. Don't
  grow `WhoopStore`, `WhoopCollector`, or `RootView`; extract instead.
  See `docs/architecture.md`.
- Every behavior change gets deterministic tests at the lowest useful layer.
  Private model checks run via `Tools/verify_private_models.sh`.

## Done means

`Tools/verify_local.sh` passes with no warnings or skips, generated files are
current, and privacy holds. Use `Tools/check_fast.sh` while iterating and
`Tools/verify_sanitizers.sh` for risky storage or concurrency changes.

## Installing on the maintainer's phone

Only via `Tools/ship_phone.sh --commit <exact-merged-sha>`. Never uninstall,
and never use ad hoc Xcode or `devicectl` installs. Follow `docs/operator.md`.
