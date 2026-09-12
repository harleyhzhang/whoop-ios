# Sleep iOS app

- Product north star: replace the official WHOOP app for Harley's personally
  owned WHOOP 5. The finished app directly manages the strap, preserves live
  and historical data locally, and derives transparent versioned sleep,
  recovery, and strain metrics without a membership or official-app dependency.
- Treat compatibility probes as temporary diagnostics feeding the production
  collector, not as the product boundary.
- Build the product as a native SwiftUI iPhone application.
- Keep the app fully useful without a hosted service or memory connection.
- Preserve privacy: no credentials, signing assets, or real health exports in
  Git. Sample fixtures must be synthetic and clearly recognizable as such.
- Preserve unique raw packet evidence, but compact exact byte-for-byte BLE
  transport retries on the same characteristic instead of multiplying raw and
  decoded rows. A retry must still count as durably handled before any history
  acknowledgement is sent.
- Prefer Apple frameworks and focused dependencies. The future WHOOP protocol
  layer may reuse compatible NOOP packages after license and integration review.
- Verify UI changes by building for an iPhone simulator and, when requested,
  installing on Harley's paired development iPhone.
- Before every physical-phone install, run `Tools/phone_install_policy.sh`
  against the last installed commit recorded in the private install-state file.
  Follow its result; do not substitute an ad hoc full container copy:
  - `none`: do not reinstall.
  - `fast`: for presentation-only changes, verify a recent known-good full
    backup exists, install the exact merged build in place, confirm the data-
    container UUID is unchanged, launch it, and confirm the process plus
    database/WAL modification times advance. Do not transfer the 1+ GB database.
  - `full`: for storage, schema, migration, model, collector, lifecycle, bundle-
    identity, build-system, or unclassified production changes, take coherent
    suspended pre- and post-install snapshots and validate standalone SQLite
    images. Prefer a wired CoreDevice connection for these large transfers.
  The classifier fails closed to `full` when its baseline or classification is
  uncertain. After successful verification, update the private install-state
  file with the exact installed commit, data-container UUID, verification mode,
  and latest known-good full backup. Never commit that state file.
- Run `Tools/verify_local.sh` before merging code changes. Hosted iOS CI is a
  manual fallback only; do not trigger it unless local verification is blocked
  or Harley explicitly requests a hosted run.
- Treat `project.yml` as the source of truth for Xcode targets and build
  settings. Run `xcodegen generate` after changing it and commit the generated
  `Sleep.xcodeproj`; the local gate rejects drift.
- Format changed Swift with `xcrun swift-format format --configuration
  .swift-format --in-place <files>`. Do not add force unwraps, force tries, or
  implicitly unwrapped optionals. Swift and Clang warnings are errors, and Swift
  strict concurrency stays at `complete`.
- Every behavior change needs deterministic coverage at the lowest useful
  layer. Protocol/parsing/scoring/storage policy belongs in unit tests;
  user-visible critical paths belong in UI tests. Do not skip tests or make
  private fixtures silently optional in the public suite. Private model
  validation lives in `SleepPrivateTests` and runs explicitly through
  `Tools/verify_private_models.sh`.
- Keep framework callbacks and I/O adapters thin. Put deterministic decisions
  in focused pure types that can be tested without Bluetooth, notifications,
  the filesystem, or wall-clock time. Avoid adding more responsibilities to
  `WhoopStore`, `WhoopHandshakeProbe`, or `RootView`; extract a cohesive file
  when touching a separable concern. See `docs/architecture.md`.
- A change is done only when relevant tests are added, formatting and generated
  files are current, `Tools/verify_local.sh` passes without warnings/skips, and
  privacy boundaries are preserved. Run `Tools/verify_sanitizers.sh` for risky
  memory/concurrency/storage changes.
- Do not add an app-side manual sync control for the hosted replica or for
  memory. Memory reads are initiated from the Mac side. Sleep publication is
  automatic and has no routine Process/loading UI: explicit awake finalizes
  immediately, while ambiguous `up` finalizes after ten minutes. Every publish
  still requires a durable HISTORY_COMPLETE marker, and state-2 sleep returning
  within ninety minutes silently grows the same night instead of losing data.
