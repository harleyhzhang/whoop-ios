# WHOOP iOS

[![Local CI](https://github.com/harleyhzhang/whoop-ios/actions/workflows/local-ci.yml/badge.svg)](https://github.com/harleyhzhang/whoop-ios/actions/workflows/local-ci.yml)

WHOOP iOS is an unofficial, native, offline-first personal iPhone client. It is
intended to operate a personally owned WHOOP 5 directly,
preserve the underlying data, and calculate transparent sleep and recovery
metrics locally without depending on a WHOOP membership.

## Local verification

Install the pinned tools and repository hook once, then run the canonical gate:

```bash
brew bundle --file Brewfile
Tools/install_git_hooks.sh
Tools/verify_local.sh
```

The gate enforces Swift formatting, Swift 6 strict concurrency, warnings as
errors, Ruff formatting/linting, strict mypy, shellcheck, secret and private-data
scans, generated-project drift, zero skipped tests, a 58% app coverage floor,
Release compilation, and Xcode static analysis. Pull requests and `main` use a
private self-hosted Mac runner, so normal CI consumes no GitHub-hosted macOS
minutes. `.github/workflows/ios-ci.yml` is a manual hosted fallback only.

See [testing and CI](docs/testing.md), [architecture](docs/architecture.md), and
[contributing](CONTRIBUTING.md) before making a behavioral change.

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
- The main dashboard no longer generates sample values. A refreshed read-only
  WHOOP API archive is reduced to one primary-sleep row per local date and
  imported idempotently into `daily_health_metric` in the existing SQLite
  database. The initial private seed contains 306 scored nights from 2025-10-16
  through 2026-09-01. Sleep uses WHOOP's archived sleep-performance percentage;
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
- Chart density is range-aware without altering the stored daily history or
  exact current value: 1W and 1M use daily points, 1Y uses weekly medians, and
  All widens adaptive median buckets from weekly toward monthly to stay near
  40–60 plotted points.
- The native segmented selector uses `Week`, `Month`, `Year`, and `All` labels
  with matching full VoiceOver names. Fixed ranges appear only when the stored
  history is long enough to support them. One-week and one-month
  charts retain compact start/midpoint/Today labels; one-year and all-history
  charts show at most four evenly distributed abbreviated month-and-year labels
  without vertical month gridlines or wasted footer space.
- The Trends selector persists the most recently used range and restores its
  selected highlight and charts when the app next opens.
- For 1Y and All, charts overlay independent contrasting average levels. The
  history is divided backward from the latest day into adaptive equal-time
  windows, with at most five levels. Each unconnected
  horizontal segment shows its formatted mean above the line. The underlying
  colored trend remains visible at reduced opacity; pressing or scrubbing hides
  the levels and restores the normal trend. The endpoint is one same-color dot,
  with no card-colored knockout, border, or halo separating it from the line.
- Aggregated trends keep their historical median buckets but anchor the final
  bucket to the exact latest observation, so the endpoint, dot, and current
  card value agree. Chart selection snaps to rendered points, and a fixed
  normalized x-domain with slight endpoint padding prevents the plot width from
  changing while scrubbing or clipping the final dot.
- Trend lines and area fills use a shape-preserving cubic sampler followed by
  restrained monotone rendering. Sparse Week values form one continuous curve
  instead of straight spans with rounded vertices, while extrema remain inside
  neighboring value intervals. Selection never splits or recomputes the trend:
  it overlays a translucent future region after the selected point, then adds
  the rule and dot, leaving line geometry, scales, and layout unchanged while
  scrubbing.
- Range changes resample both curves onto the same 48 horizontal anchors, then
  morph the values and y-domain together. Year/All average steps and passive
  translucency remain independent opacity layers. The headline and current-card
  numbers use a brief restrained digit pop while retaining the previous value
  underneath; Reduce Motion remains immediate and direct chart scrubbing does
  not replay the range transition.
- Haptics follow a restrained interaction vocabulary: selection ticks occur
  only when the range or exact selected night changes; lightweight impacts
  accompany diagnostic navigation and rescanning; handshake initiation is
  firmer; and success/warning patterns are limited to visible handshake
  outcomes. Passive collection and background Bluetooth events stay silent.
- The dashboard diagnostic control uses the compact circular WHOOP mark plus a
  small plain connection-status dot, green only while the encrypted strap link
  is active and gray otherwise.
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
- Sleep finalization is an explicit state machine. Before a new sleep begins,
  the dashboard continues showing the latest completed night. As soon as the
  band detects sleep, the compact card says only `Sleep detected`—never a
  provisional duration—and remains visible through waking and processing.
  From detection until manual or automatic processing atomically publishes the
  wake, every current-day value—Sleep, Duration, Steps, Recovery, RHR, and
  HRV—shows an em dash. One shared published-day projection owns all six values,
  so no card can independently fall back to a stale timeline point. Process
  remains available as the manual wake assertion until storage succeeds or
  automatic processing wins.
  The automatic path still requires at least three hours of detected sleep,
  50% observed-session coverage, thirty minutes of banked wake data, and thirty
  minutes since the last asleep sample. It additionally requires a persisted
  HISTORY_COMPLETE marker covering the newest sample. Score, duration, HRV,
  and RHR are derived first and committed only when all four are present, so a
  partial night can never replace the previous one in the UI. Pressing Process
  waives only the wake-timing gates; it never waives evidence or metric
  completeness. Every tap now joins an in-flight historical offload or starts
  a fresh one, then remains queued until its new durable HISTORY_COMPLETE
  marker arrives; it can never finalize from an older, stale completion marker.
  A failed process restores the control. Internal `up` intervals shorter than ninety
  minutes remain part of one detected night, preventing a mid-sleep state from
  splitting and prematurely storing the first portion. A later coherent
  reconstruction can grow an already-local row when it proves the night was
  materially longer, but partial evidence can never shrink a stored night.
- The grow-only repair is grounded in the 2026-09-06 failure capture: Process
  stored 230.4 minutes at 12:05 while the strap was actively offloading, then
  the completed local history showed 512 minutes for the same night. The manual
  path now rejects that in-flight prefix and the fuller candidate automatically
  repairs the premature row.
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
- Before upgrading any non-empty schema, the app now uses SQLite's online
  backup API to create and validate a standalone, WAL-consistent snapshot in
  `migration-backups`. The migration fails closed if that restorable copy
  cannot be made; Mac-side container transfer is no longer the safety boundary.
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
  minute is gone; while Process waits for HISTORY_COMPLETE, the current day
  remains in its pending state with an explicit `Finishing sleep…` indicator.
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
- Sustained worn live capture, foreground/background persistence, historical
  offload, conservative local sleep finalization, and local notifications work.
  Longer unattended overnight calibration, disconnect recovery, stage models,
  and backend replication remain.

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
