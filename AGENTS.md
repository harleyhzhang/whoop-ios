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
- Every physical-phone install must use
  `Tools/ship_phone.sh --commit <exact-merged-sha>`. It runs the doctor and
  classifier, builds that clean `origin/main` commit, signs with a matching
  device profile, verifies private model/seed contents and hashes, installs in
  place through CoreDevice, launches, proves database activity, and atomically
  records success. Do not substitute an ad hoc Xcode, `devicectl`, or iPhone
  Mirroring flow. The internal classifier selects:
  - `none`: do not reinstall.
  - `fast`: for presentation-only changes, verify a recent known-good compact
    backup exists, install the exact merged build in place, launch it, and
    confirm the process plus database/WAL modification times advance. Current
    CoreDevice inventory does not expose a physical data-container UUID, so
    preservation is proved from in-place installation and content checks. Do
    not transfer the 1+ GB database.
  - `protected`: for runtime, collector, or storage implementation changes that
    do not alter schema or app identity, take one coherent preinstall snapshot,
    then require the launched app's commit-bound database health attestation.
  - `migration`: for schema, migration, signing, entitlement, project identity,
    or uncertain changes, require USB and take coherent pre/post snapshots with
    exact preserved-row comparison.
  The classifier fails closed to `migration` when its baseline or classification
  is uncertain. Snapshots retain one standalone database and required sidecars,
  never the copied live database/WAL or recursive app migration backups. The
  shipping command owns suspension/resumption, coherent backup validation,
  manifest-driven retention, data preservation, and install-state updates. If it
  reports `needs-unlock` or `needs-verification`, rerun only its printed
  `--resume` command; never uninstall. Never commit its private state or backup
  manifests.
- Run `Tools/verify_local.sh` before merging code changes. Hosted iOS CI is a
  manual fallback only; do not trigger it unless local verification is blocked
  or Harley explicitly requests a hosted run.
- Use `Tools/ship_phone.sh --plan --commit <merged-sha>` to inspect pending
  commits and the required install tier without connecting a phone. Batch
  routine merged changes into one chosen checkpoint instead of reinstalling
  every commit.
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
