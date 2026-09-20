# WHOOP iOS

[![Local CI](https://github.com/harleyhzhang/whoop-ios/actions/workflows/local-ci.yml/badge.svg)](https://github.com/harleyhzhang/whoop-ios/actions/workflows/local-ci.yml)

WHOOP iOS is an unofficial, native, offline-first personal iPhone client. It is
intended to operate a personally owned WHOOP 5 directly,
preserve the underlying data, and calculate transparent sleep and recovery
metrics locally without depending on a WHOOP membership.

## Local verification

Install the named Homebrew tools, verify their exact tested versions, and add
the repository hook once:

```bash
brew bundle --file Brewfile
Tools/doctor.sh --toolchain-only
Tools/install_git_hooks.sh
```

Use `Tools/check_fast.sh` while editing; it retains one simulator and DerivedData
cache. Run `Tools/verify_local.sh` on the final clean commit. That gate uses a
fresh simulator/build directory and enforces Swift formatting, Swift 6 strict
concurrency, warnings as errors, Ruff, strict mypy, shellcheck, private-data
scans, generated artifacts, zero skipped tests, global and critical-module
coverage, Release compilation, unused-declaration analysis, and Xcode static
analysis. A successful clean-commit
gate writes a 24-hour local attestation keyed by HEAD, tree, and exact toolchain,
so the pre-push hook can reuse it instead of immediately repeating the same run.
Pull-request CI always performs its own isolated gate. Main-branch CI reuses the
successful trusted PR result only for an identical Git tree and otherwise falls
back to the full gate.

See [testing and CI](docs/testing.md), [architecture](docs/architecture.md), and
[contributing](CONTRIBUTING.md) before making a behavioral change.

Database growth is measured by a bounded sidecar and direct phone-reporting
command. See [storage amplification measurement](docs/storage-amplification.md)
for collection, analysis, and the guarded offline schema-11 prototype.

## Physical-phone shipping

From a clean worktree at the exact merged `origin/main` commit, run:

```bash
Tools/ship_phone.sh --commit "$(git rev-parse HEAD)"
```

This is the canonical build, signing, backup, in-place install, launch, and
verification path. `Tools/ship_phone.sh --plan --commit <merged-sha>` reports
the pending commit count and verification tier without requiring the phone, so
routine merges can ship as one intentional checkpoint. `Tools/doctor.sh --mode
migration` performs the strictest read-only preflight.
If shipping returns `needs-unlock` or `needs-verification`, run only the exact
`--resume` command it prints; never uninstall the app. See the
[migration runbook](docs/whoop-data-migration.md#10-build-sign-install-and-preserve-migration-backups)
for the fail-closed verification tiers.

Device builds reuse `~/Library/Caches/whoop-ios/device-derived-data`. Verified
snapshots retain one standalone database plus required sidecars; automatic
manifest-driven retention keeps current rollback points, two newest snapshots,
and one snapshot per schema and recent month. Retired data stays recoverable for seven
days before a later successful shipping or maintenance run purges it. Run
`Tools/maintain_device_backups.sh` for a dry-run inventory or add `--apply
--adopt-legacy` to validate and compact old snapshots before retirement.
`--retire-unusable` may be added to quarantine only legacy directories that
failed that explicit adoption. This tool never manages canonical WHOOP
source/archive directories. `--apply --purge-now` permanently removes only
already-recorded quarantine entries and is reserved for an explicitly reviewed
cleanup after the retained restore points are revalidated.

Restore points created before the shipping pipeline live in the separate legacy
`app-backups` tree and require a cross-snapshot pass rather than per-directory
deletion. Run `Tools/consolidate_legacy_backups.sh` first as a dry run. With
`--apply`, it selects the fullest integrity-clean database for every schema not
already represented by a managed backup, creates a standalone normalized image,
checks exact preserved-table counts and hashes, and only then quarantines the
redundant folders. `--retire-unusable` includes malformed or empty legacy
folders after schema coverage succeeds; `--purge-now` removes only recorded
quarantine entries. Re-run `Tools/maintain_device_backups.sh` and review a clean
`invalid=0` inventory before an immediate purge.

## Product target

The app should eventually cover the complete personal loop:

1. Pair, reconnect, and maintain the WHOOP 5 Bluetooth session automatically.
2. Losslessly capture live and historical packets before decoding them.
3. Derive steps, heart rate, R–R intervals, HRV, resting heart rate, sleep
   periods, sleep stages, disturbances, and supporting physiology with provenance.
4. Store a complete offline history on the phone and replicate it to a private
   backend without making the UI depend on that backend.
5. Show an interpretable, versioned Sleep Score plus the underlying measurements.

## Migration and data preservation

The [WHOOP data migration runbook](docs/whoop-data-migration.md) explains how to
reproduce the complete private workflow: request the supported account export,
archive the public Developer API, optionally preserve read-only official-app
responses, continue with direct WHOOP 5 BLE collection, generate deterministic
private seeds and models, install without losing the phone database, and verify
the result. It also defines the evidence/projection boundary, secret handling,
idempotent rebuild rules, contributor handoff and experiment-recording
discipline, and the limits of historical recovery.

## Current state

- The SwiftUI dashboard and interaction design are installed on the paired iPhone.
- The app can reconnect to the paired WHOOP 5, establish its encrypted
  link, subscribe to all known live notification channels, and construct the
  reversible WHOOP 5 live-stream commands.
- The diagnostic path decodes standard Bluetooth heart-rate measurements and
  WHOOP 5 type-40 heart-rate/R–R frames.
- WHOOP 5 type-47/version-18 historical packets are decoded locally and each
  type-49 history chunk is acknowledged only after its raw and decoded records
  are durably stored. The local sleep finalizer uses the band's sleep-state
  signal plus coverage gates to derive duration, lowest five-minute mean RHR,
  cleaned five-minute RMSSD HRV, and a transparent sleep-performance score.
- The collector now lives for the lifetime of the app rather than the diagnostic
  sheet, automatically reopens a previously confirmed bond, re-arms the live
  streams every 30 seconds, reconnects after link loss, requests CoreBluetooth
  state restoration, and declares the `bluetooth-central` background mode.
- Passive collection explicitly disables the battery-heavy R10/R11 sensor burst
  and keeps only the lightweight type-40 HR/R–R stream armed. High-frequency
  sensor capture belongs in bounded diagnostics or historical offload, not the
  overnight keepalive loop.
- Append-only SQLite persistence is hardware-verified. With the physical phone
  locked and iPhone Mirroring quit, the database grew from 967 to 1,692 raw
  WHOOP frames in 43 seconds, proving real background collection with no visible
  app screen.
- A forced app-process relaunch on the locked phone also recovered automatically:
  the saved encrypted-bond latch reopened the session and SQLite added 48 frames
  in the first 17 seconds, then another 47 frames during the following 44-second
  locked interval. The recovered stream contained command responses and type-40
  heart-rate/R–R measurements without opening the collector controls.
- The main dashboard no longer generates sample values. As soon as the strap
  reports sleep, every current-day metric changes to an em dash and remains
  blank through a short provisional wake instead of flashing the previously
  published day; automatic wake processing publishes the next coherent day. A
  refreshed read-only WHOOP API archive is reduced to one primary-sleep row per
  local date and imported idempotently into `daily_health_metric` in the
  existing SQLite database. The initial private seed contains 306 scored nights
  from 2025-10-16 through 2026-09-01. Sleep uses WHOOP's archived
  sleep-performance percentage;
  duration is the sum of light, REM, and slow-wave sleep; HRV is RMSSD; and RHR
  is the archived resting-heart-rate value. The import also retains sleep start,
  end, dynamic need, sufficiency, consistency, and efficiency as underlying
  score evidence. Every complete sleep and recovery source object is retained as
  JSON, and every numeric or Boolean leaf is independently indexed by field path
  so a future model can query metrics this version does not yet understand. The
  dashboard shows missing data instead of extrapolating and keeps archive
  provenance out of the daily-use header.
- The top summary uses an untitled, borderless layout inspired by Apple
  Fitness: Sleep and Duration share the first row, while Steps, Recovery, and
  RHR share a compact three-column second row. It has no divider lines, uses
  compact metric icons, and gives all values stable semibold white typography
  under gray metric titles. Icons retain fixed metric colors; no phone-motion
  metrics or Motion & Fitness permission are part of this surface.
- `Steps` is the first trend card after the two sleep cards. It joins 317 exact
  official-app daily totals from 2025-10-16
  through 2026-08-31 to local WHOOP 5 cumulative-counter totals from Sep 1
  onward, preferring the official value on any overlapping day. Ongoing local
  collection does not enable the battery-heavy raw IMU stream or request phone
  motion access. The store retains the counter, cadence-like byte, motion-class
  byte, civil-date offset, source packet, sample/span coverage, missing seconds,
  wrap count, rejected deltas, source, and algorithm version. The UI title is
  simply `Steps`. Local days are wake-anchored rather than midnight-anchored:
  movement after midnight and before the next completed sleep remains part of
  the preceding day. Publishing the wake atomically opens the next day and
  re-buckets already-collected post-wake samples from retained counters.
- A `Recovery` trend card follows Steps. Historical points use 316 exact
  official scores. Future points use
  a versioned 70% gradient-boosting / 30% ridge model over independently
  available sleep, HRV, RHR, Steps, and past-only rolling history. Four forward
  chronological folds covering 126 unseen nights measure 4.79-point MAE,
  6.70-point RMSE, and R² 0.875. The store keeps WHOOP targets separate from
  local predictions and retains each prediction's 169 inputs, confidence,
  component counterfactuals, baselines, model version, and derivation time.
- RHR follows Recovery in the trend stack, and HRV appears last. Removing HRV
  and live Heart Rate from the compact summary does not stop their collection,
  storage, or use in local Recovery modeling.
- Every chart shows all stored history. At rest, adaptive median buckets widen
  from weekly toward monthly to keep the summary near 40–60 plotted points
  without altering the stored daily history or exact current value. The
  dashboard has no range selector or separate `Trends` heading. Charts show at
  most four evenly distributed abbreviated month-and-year labels without
  vertical month gridlines or wasted footer space.
- Charts overlay independent contrasting average levels. The
  history is divided backward from the latest day into adaptive equal-time
  windows, with at most five levels. Each unconnected
  horizontal segment shows its formatted mean above the line. The underlying
  colored trend remains visible at reduced opacity; pressing or scrubbing
  quickly eases every retained daily point into the line while the average
  levels fade away, then reverses the morph on release. The endpoint is one
  same-color dot, with no card-colored knockout, border, or halo separating it
  from the line.
- Aggregated trends keep their historical median buckets but anchor the final
  bucket to the exact latest observation, so the endpoint, dot, and current
  card value agree. Chart selection snaps to rendered points, and a fixed
  normalized x-domain with slight endpoint padding prevents the plot width from
  changing while scrubbing or clipping the final dot.
- Trend lines and area fills use a shape-preserving cubic sampler followed by
  restrained monotone rendering. The summary and daily line share one stable
  topology during the hold morph, and the complete-detail state lands on every
  retained daily value. Selection overlays a translucent future region after
  the selected point, then adds the rule and dot. On release, one shared
  frame-driven phase morphs the curve and advances the dot; every frame samples
  the dot's vertical coordinate from that exact current monotone curve so it
  stays glued to the line all the way to the latest endpoint. The selection
  overlay fades during the same 340 ms settle. The headline and current-card
  numbers use a brief restrained digit pop while retaining the previous value
  underneath; Reduce Motion makes the detail transition immediate and direct
  chart scrubbing does not replay the number animation.
- Haptics are limited to selection ticks when the exact selected night changes.
  Passive collection and background Bluetooth events stay silent.
- The dashboard keeps connection state passive and compact: a small decorative
  WHOOP-band image carries a plain status dot, green only while the encrypted
  strap link is active and gray otherwise, followed by the battery indicator.
  The cluster is not tappable and there is no dashboard status drawer.
- Local notifications require no hosted service. A completed local sleep emits
  one deduplicated morning summary containing Sleep %, duration, HRV, and RHR.
  Battery readings emit one warning per discharge cycle at 20% and 10%, with
  hysteresis to prevent threshold jitter, plus one completion alert when a
  subsequent reading reaches 100%. All three paths were exercised with
  debug-only simulator triggers that do not persist synthetic health data.
- A fresh checksum-valid WHOOP 5 wrist-off event schedules one local reminder
  after 30 minutes. A wrist-on event cancels the pending or delivered reminder
  and re-arms the next episode. Stale/replayed frames, corrupt frames, missing
  heart-rate data, and Bluetooth disconnects cannot trigger it.
- Every sleep derivation is expressed in elapsed time against the strap's own
  observed cadence. The WHOOP 5 historical record is not one hertz: it stores
  roughly one distinct sample every six seconds, and a given night can be
  sparser still. Three derivations had been written as if it were one hertz and
  all three were unreachable or wrong in practice. Duration counted distinct
  seconds carrying a sample, so an eight-hour night measured as minutes; the
  evidence gates required 10,800 such seconds and 50% of them, which no night
  could ever reach; and resting heart rate required 120 samples in a five-minute
  window, which no window ever held, so it was always nil. Duration now
  integrates elapsed time across consecutive asleep samples, matching WHOOP's
  total-sleep-time definition, with any gap beyond the outage cap contributing
  one sample rather than the whole gap. Coverage now measures the fraction of
  the session the strap gave evidence for, counting only gaps beyond that same
  cap; sampling density is deliberately excluded, because a night recorded every
  sixteen seconds is still fully observed. Resting heart rate scales its window
  requirement to what the observed cadence can deliver.
- Every finished night in the window is banked, not only the most recent. The
  strap trims history once a chunk is acknowledged, so a night that ended while
  the app was never opened would otherwise be lost permanently. A locally
  derived row missing a metric is re-derived so a fix to one derivation repairs
  the rows it already wrote; an archived WHOOP row is authoritative and is never
  overwritten.
- Calibrated against the 306 archived WHOOP nights rather than against synthetic
  fixtures. Two real nights derived locally on 2026-09-03 gave 7h41m and 8h01m
  with RHR 51 and 50 and HRV 74 and 66. WHOOP's own last thirty archived nights
  run a median HRV of 57.5 across 44-76 and a median RHR of 56 across 53-62, so
  local HRV sits slightly high and local RHR slightly low while both stay near
  WHOOP's distribution. The consistent direction suggests the local windows
  favour the calmest part of the night more than WHOOP's do; this is a known
  methodological difference, not a demonstrated defect.
- Sleep Score is fitted against all 306 archived WHOOP-scored nights. The old
  `duration / 519 minutes` formula had 5.73-point mean absolute error and caused
  the misleading run of 99s. WHOOP's exported sufficiency, consistency, and
  efficiency pillars reproduce its score with 0.83-point forward-held-out error,
  confirming those pillars carry almost the whole calculation. Because WHOOP
  will not supply its dynamic need or proprietary Sleep Stress after access
  ends, the production private model uses only signals this app can continue to
  calculate: duration, efficiency, circular sleep/wake timing, timing agreement,
  and seven nights of history. Gradient-boosted models first reconstruct WHOOP's
  dynamic need and consistency, then an RBF-SVR applies the learned pillar
  relationship. A 10% direct Extra Trees/SVR estimate stabilizes that staged
  result. This reaches 1.68-point forward-held-out error (RMSE 2.43, R² 0.920).
  Local rows retain the model's predicted need, consistency, sufficiency, and
  observed efficiency alongside the final score, keeping those materialized
  outputs available for future diagnostics and model comparisons.
  HRV, RHR, stages, respiration, and ad-hoc stress proxies were tested and
  rejected because they worsened unseen-night error. The reproducible trainer lives at
  `Tools/backtest_sleep_score.py`; fitted parameters stay in the account owner's private
  data tree because support vectors and tree thresholds derive from real health
  history.
- Derived rows carry a versioned source. A change to any derivation re-derives
  the nights the previous version wrote instead of leaving stale values in the
  history; archived WHOOP rows are authoritative and are never overwritten.
- The chart selection dot remains a solid continuation of the trend, and the
  translucent future region extends past the visible data extent so the round
  line cap overhanging the final point is dimmed with the rest of the line.
  The plot clips to its final y-domain and gives its x-domain endpoint padding,
  so range changes cannot stretch outside the card or shear the final dot.
- Sleep finalization is automatic and card-free. The first coherent
  finalization emits the morning notification. While a
  new sleep is unresolved, every current-day metric is masked with an em dash;
  there is no routine Process card or loading state. Explicit
  awake finalizes immediately, while a current ambiguous `up` state becomes an
  immediate provisional wake.
  Publication still requires at least three hours of detected sleep, 50%
  observed-session coverage, all four primary metrics, and a persisted
  HISTORY_COMPLETE marker covering the newest sample. State-2 sleep returning
  within ninety minutes reopens and grows the same night. The corrected morning
  summary replaces the earlier notification for that date. A completed
  main sleep gets a narrow extension to two hours when sleep resumes before
  noon on the same local morning, without folding afternoon naps or clusters of
  short sleeps into the preceding night. Both paths correct the wake-anchored
  step boundary. Partial evidence can never shrink a stored night.
- Nightly HRV prefers the live R-R stream, then automatically falls back to the
  timestamped R-R packets in a completed historical offload. This covers nights
  when iOS suspends live Bluetooth delivery without weakening the all-metrics or
  HISTORY_COMPLETE publication gates. The 2026-09-13 failure capture contained
  20,640 asleep R-R intervals across 80 valid five-minute windows and produced
  70.3 ms despite zero live overnight packets. Across the six dense local nights
  where both sources could score, five historical results matched the preferred
  live result within 0.1 ms; one differed by 10.2 ms (MAE 1.71 ms). The fallback
  is therefore reserved for nights the live stream cannot score.
- The grow-only repair is grounded in the 2026-09-06 failure capture: the former
  manual path stored 230.4 minutes at 12:05 while the strap was actively
  offloading, then the completed local history showed 512 minutes for the same
  night. That manual path no longer exists. Automatic publication waits for the
  durable completion marker, and a fuller candidate can still repair a
  premature row without shrinking one.
- Historical offload is self-healing. A missing final metadata packet no longer
  leaves the in-memory sync latch active forever: a watchdog resets and retries
  an offload after 90 seconds without history progress. Repeated chunk endings
  are still coalesced during their immediate notification burst, but the app
  retries their acknowledgement after two seconds instead of permanently
  suppressing it after the first BLE write.
- Exact BLE transport replays are now compacted at ingestion. The first raw
  frame remains losslessly stored, while later byte-identical deliveries on the
  same characteristic increment a replay ledger instead of duplicating the raw
  and decoded rows. This directly addresses the real six-day database, where
  304 MB and roughly 850,000 packets included 80–91% exact repeats for several
  historical frame classes. A physical-phone migration retained the existing
  data and immediately aggregated 34 retries during a short live validation.
- New evidence rows use compact sequence-derived IDs instead of repeated UUID
  text, and the hot ingestion path reuses prepared SQLite statements. Existing
  raw evidence is untouched, but future database and index growth is materially
  lower. Database opening, migration, and private-history materialization run
  off the main actor, so a large phone database no longer stalls launch.
- Schema v10 keeps raw packets as the complete evidence layer while making
  derived storage proportional to what the product actually queries. Heart-rate
  readings without R-R intervals update one latest-value row instead of growing
  an indexed history; R-R-bearing packets remain individually traceable for HRV.
  Successful historical and PPG decodes are proven by their versioned derived
  rows, while only unsupported or rejected packets need a separate failure
  ledger. Replay registration is one atomic SQLite upsert. On a disposable clone
  of a representative 1.0 GB store, the migration reduced realtime rows from
  761,411 to 328,003 and `VACUUM` reduced the database to 792 MB, with SQLite
  quick-check and foreign-key checks clean.
- Before upgrading any non-empty schema, the app now uses SQLite's online
  backup API to create and validate a standalone, WAL-consistent snapshot in
  `migration-backups`. The migration fails closed if that restorable copy
  cannot be made; Mac-side container transfer is no longer the safety boundary.
  After a successful upgrade, it retains the new validated rollback point,
  removes only older app-created migration snapshots, and best-effort compacts
  free pages. Failure to reclaim filesystem space does not invalidate the
  migrated database, which can reuse those pages for future writes.
- The app records an append-only local time-zone/UTC-offset timeline. Raw sensor
  timestamps remain absolute, while future timing-consistency models can
  reproduce the civil-time context of a sleep after travel instead of applying
  whatever time zone the phone happens to use later.
- High-rate packet traffic no longer invalidates the entire SwiftUI dashboard
  or appends a diagnostic line for every frame. Packet, R–R, and persistence
  counters are presented at bounded intervals while chunk acknowledgements and
  durable writes continue at full fidelity. Live heart rate has its own
  freshness clock, so an old cached BPM cannot look current merely because
  historical data is arriving.
- Range-filtering, date parsing, and long-range median buckets are cached by
  metric, range, reference day, and history revision. The Bluetooth collector
  is app-scoped, preventing multiple windows from creating competing central
  managers.
- Dashboard reads are generation-ordered: an older asynchronous reload cannot
  overwrite a newly processed night, and a transient SQLite read error keeps
  the last known-good charts visible. The unnecessary full-history reload every
  minute is gone; automatic processing waits silently for HISTORY_COMPLETE.
- SQLite schema setup, transactions, commits, and query completion are now
  checked instead of silently accepting partial reads or failed writes. Morning
  summaries are deduplicated by local date as well as sleep ID, so a grow-only
  repair cannot notify twice for the same morning.
- The 2026-09-01 real-history build was installed in place and visibly launched
  on the paired iPhone; the dashboard rendered the imported history correctly.
- The generated seed remains in the account owner's private data tree rather than the
  source tree. Local builds optionally copy the file selected by
  `WHOOP_HISTORY_SEED_PATH` (or the private local default) into the app bundle
  for first-launch import. The private fitted model follows the same rule via
  `WHOOP_SCORE_MODEL_PATH`. The complete official-app pull is also preserved as
  an immutable 1.03 GB source archive and a checksum-verified 61.5 MB SQLite
  sidecar containing all 5,043 request records and every exact compressed
  response body. A small daily projection feeds current charts without becoming
  the evidence layer. Physical Release builds fail closed if the private
  history, both fitted models, projection, or raw sidecar is absent; CI rejects
  their filenames if staged. The app contains no API client secret or refresh
  token.
- Full disaster-recovery archives are client-side age encrypted and stored in
  independent offsite cold storage rather than beside the phone replica in
  Convex. `Tools/convex_replica.py export <archive.age>` selects the exact
  `lastVerifiedBackup`, requires its immutable official-response sidecar,
  validates both SQLite files, packages and zstd-compresses them, encrypts only
  to the Keychain-backed age identity, then decrypts and verifies the completed
  ciphertext before publishing it locally. `verify-offsite` requires a
  byte-identical downloaded round trip and records a non-secret receipt;
  `restore-file` authenticates, decrypts, hash-checks, and reruns SQLite
  `quick_check`. The guarded one-time `retire-convex` command accepts only a
  verified offsite receipt and an exact archive/source match, and the backend
  additionally pins the newer surviving phone snapshot before deleting the
  legacy Convex object. Physical-phone shipment no longer uploads a second full
  database representation. The API token and age identity remain in macOS
  Keychain under `com.clintonst.whoop.convex-replica`; no ciphertext, receipt,
  credential, or private manifest enters Git.
- The iPhone also maintains a direct encrypted replica without making the
  backend part of collection or scoring. At launch, after a published sleep,
  and while new packets arrive, a throttled coordinator creates a consistent
  SQLite online-backup snapshot on a separate connection. It divides that
  snapshot into position-bound 8 MiB chunks, compresses each chunk with zlib,
  encrypts it with AES-GCM, and uploads only chunks the backend does not already
  have. The source fingerprint and chunk IDs are keyed HMACs, so Convex never
  receives raw health data or ordinary plaintext hashes. Routine sync is capped
  at once per six hours; a newly published sleep can advance it after one hour,
  and failures back off for fifteen minutes. The app remains fully useful when
  every network operation fails.
- The phone and the explicit Mac seeding tool use a separate write-only bearer
  token. The Mac seeder is initial/bootstrap-only once a distinct phone replica
  exists. Its token and encryption
  key are injected only into signed personal device builds from macOS Keychain;
  neither value is committed. The Mac API token alone can list and download
  snapshots and cannot call phone-upload endpoints. Convex retains the newest
  manifest, deletes encrypted chunks it no longer references, and reclaims
  interrupted uploads after a 24-hour grace period. A 950 MB fail-closed budget
  preserves headroom below the free storage ceiling. The independently
  encrypted full archive remains
  offsite, so Convex's free 1 GB file-storage allowance is reserved for the
  current phone replica and its safe commit-time overlap.
- `uv run --frozen python Tools/phone_replica.py status` inspects the bounded
  replica. `... seed [database]` seeds it from a verified Mac snapshot so the
  first phone run uploads only changed chunks. `... restore <empty-directory>`
  reconstructs the exact SQLite file, authenticates every chunk and the whole
  source, and reruns SQLite `quick_check`.
- `Tools/restore_phone_from_convex.sh --apply` is the guarded physical-device
  recovery path. It requires wired migration-grade checks, takes a verified
  pre-recovery device backup, downloads and verifies Convex, stages the database
  into the app container, launches the app's fail-safe atomic swap, waits for a
  fresh commit-bound health report, takes a post-recovery backup, and rejects
  any preserved table whose row count fell below the recovered snapshot. The
  app retains its on-device rollback until that health report succeeds.
- Sustained worn live capture, foreground/background persistence, historical
  offload, conservative local sleep finalization, local notifications, and
  direct encrypted phone replication work. Longer unattended overnight
  calibration, disconnect recovery, and stage models remain. Keep iCloud Backup
  enabled until the direct path has completed on the physical phone and the
  guarded phone recovery drill has passed there.

## Immediate milestone

Run an unattended overnight direct capture and validate gaps, battery impact,
reconnect behavior, automatic sleep finalization, and the morning notification
on physical hardware. Then expand the versioned local model toward independent
sleep detection and stages without inventing unavailable measurements.

The protocol implementation uses independently implementable protocol facts.
NOOP is a valuable factual reference, but its PolyForm Noncommercial license
must be reviewed before copying implementation code or shipping beyond the
permitted personal/research use.

WHOOP is a trademark of WHOOP, Inc. This personal project is not affiliated
with or endorsed by WHOOP, Inc.
