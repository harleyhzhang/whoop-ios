# Architecture

## Invariants

- The phone is the source of operational truth and remains useful offline.
- Raw WHOOP evidence is durable before acknowledgement or derived publication.
- Exact transport retries may be compacted, but unique evidence is preserved.
- Derived metrics are deterministic, versioned, and traceable to their inputs.
- Private exports and fitted personal models remain outside Git.
- UI state never owns collection or storage lifetime.

## Boundaries

`SleepApp` is the composition and presentation layer. `SleepApp.swift` owns app
lifecycle and notification orchestration; `RootView.swift` is a small dashboard
coordinator. `DashboardHeader.swift`, `SummaryGrid.swift`, `RangePicker.swift`,
and `MetricTrendCard.swift` own their corresponding sections, while
`DashboardChartGeometry.swift` and `DashboardChartState.swift` separate pure
chart calculations from interaction state. `HealthHistoryModel.swift` uses
Observation and publishes one atomic `DashboardHistorySnapshot` per database
generation instead of exposing independently changing history families. Data
contracts remain in `SleepModels.swift`, while scoring features and model
bundles live in `ScoreModels.swift`.

SwiftUI owns presentation-time invalidation: the dashboard's current-day
reference comes from a periodic `TimelineView`, and diagnostic connection age
uses `Text(date, style: .relative)`. `HealthHistoryModel`,
`DashboardChartState`, and the probe's six view-facing state values use iOS 17
Observation; Bluetooth, persistence, and task internals are explicitly excluded
from observation tracking.

`Tools/model_features.json` is the single semantic feature-order manifest.
`Tools/generate_model_features.py` deterministically emits the Swift and Python
contracts plus one synthetic cross-language golden vector; the merge gate
rejects generated drift. Private fitted artifacts are promoted only through
`Tools/promote_private_models.sh`, which keeps chronological validation and
runtime decoding ahead of the external private-file replacement boundary.

`WhoopHandshakeApp` is the device and persistence layer:

- `WhoopHandshakeProbe.swift` adapts CoreBluetooth callbacks and coordinates a
  connection/offload session. `WhoopConnectionSession.swift` gives each
  selection/reset a generation token so superseded callbacks and delayed work
  are rejected, while `WhoopHistoricalSyncState.swift` owns the pure opening,
  active, progress, timeout, and reset transitions. Its main-actor callback only
  snapshots immutable delivery values and forwards them; it does not parse
  protocol frames.
- `WhoopPacketEnvelope.swift` is the typed immutable parse result. Proprietary
  frames are converted to bytes and CRC-checked once before storage.
- `WhoopTransportPipeline.swift` owns the dedicated serial protocol queue,
  bounded packet batching and persistence backlog, bounded transient retries,
  backpressure publication, idle flushing, and throttled UI snapshots.
- `WhoopBluetoothPolicy.swift` owns deterministic advertisement, framing,
  charging-inference, acknowledgement, and history-completion decisions. Its
  typed `WhoopCommand` values are the only production owners of wire opcodes and
  payloads.
- `WhoopProtocol.swift` owns frame integrity and pure protocol decoders.
- `WhoopStoreModels.swift` owns persistence, snapshot, and diagnostics contracts.
- `SQLiteDatabase.swift` is the single owner of the queue-confined SQLite C
  connection, prepared-statement cache, and persistence-working state. Its
  narrow `@unchecked Sendable` connection boundary exists because SQLite C
  pointers are explicitly non-Sendable; runtime queue preconditions guard every
  access.
- `DashboardRepository.swift` owns read-only dashboard SQL and result mapping.
- `WhoopStorageReliability.swift` owns typed SQLite failures, lifecycle states,
  initialization retry policy, readiness fan-out, and the injectable packet
  persistence boundary.
- `DashboardDatabaseReader.swift` runs repository snapshots through a separate
  read-only WAL connection so projection maintenance cannot stall the dashboard.
- `WhoopRuntimeDiagnostics.swift` records MetricKit payloads locally and exposes
  signposts for storage open, batch commits, and dashboard reads.
- `WhoopBackfillPlanner.swift` owns bounded recovery history and the single-pass
  sleep-range index used by model backfills.
- `WhoopStore.swift` remains the persistence façade while schema migration,
  seed import, ingestion, step/sleep/recovery materialization, and diagnostics
  move behind focused collaborators one vertical slice at a time.
- `HandshakeView.swift` is diagnostic presentation only; collection is owned by
  the app-lifetime probe.

The direction of dependency is presentation → orchestration → pure policy and
storage. Pure policy must not import SwiftUI, CoreBluetooth, or global clocks.
Framework APIs belong behind small adapters so decisions can be unit tested.

## Data flow

1. CoreBluetooth delivers a packet to the probe, which snapshots its immutable
   data and identifiers onto the serial transport queue.
2. The transport pipeline performs one integrity check and constructs one typed
   packet envelope containing all decoded protocol state.
3. The store persists bounded FIFO envelope batches in one transaction while
   retaining every unique raw delivery and compacting only exact retries.
   Transient failures retry a bounded number of times. Buffer exhaustion is
   surfaced as backpressure and marks the active history session failed, so no
   later boundary can acknowledge missing evidence.
4. A chunk terminator closes its batch. Only that batch's successful persistence
   completion may publish an acknowledgement decision to the main actor.
5. A durable `HISTORY_COMPLETE` permits finalization and snapshot publication.
6. SwiftUI observes the published snapshot; it does not infer missing evidence.

Battery transport follows the same coherence rule: a typed `BatteryObservation`
carries level plus charging state from the serial transport snapshot through the
probe into notification policy. Low-battery reminders require an explicit
non-charging observation, so a charging strap cannot emit “Charge now.”

## Storage representation

SQLite separates immutable evidence from rebuildable query projections:

- `whoop_raw_packet` retains every unique transport payload and its provenance.
  Exact retries of the same characteristic/payload pair increment
  `whoop_packet_replay` through one atomic upsert.
- `whoop_latest_heart_rate` is a singleton freshness cache. Nonpositive readings
  never replace a valid latest value, but they also never block raw persistence.
- `heart_rate_sample` retains only packets with R-R intervals because those
  packet boundaries and timestamps are required for nightly HRV.
- Completed `whoop_historical_sample` rows provide the automatic nightly-HRV
  fallback when iOS suspends the live R-R stream; row timestamps and packet
  boundaries feed the same continuity and artifact filters as live packets.
- Versioned rows in `whoop_historical_sample` and `whoop_ppg_packet` are the
  success record for decoding. `whoop_decode_failure` is a sparse ledger for
  unsupported and rejected packets, preserving diagnosability without a second
  row for every successful decode.

Schema migrations run transactionally only after a validated online SQLite
backup. The store retains one app-created rollback snapshot and prunes only
older snapshots matching its own naming contract. Launch never runs `VACUUM`:
released pages remain on SQLite's freelist and are reused as collection
continues without needing temporary space equal to a phone-sized database.
Only opening, durability configuration, migration, interrupted-session cleanup,
and readiness publication block availability. Imports, projection rebuilds,
protocol backfills, and optimization run later on the writer queue; dashboard
reads become available immediately through their independent reader.

The store split is deliberately incremental. Each extracted collaborator uses
the same `SQLiteDatabase` owner and serial queue; no collaborator opens a second
writer. A slice keeps its existing façade API until deterministic parity tests
pass. Packet ingestion remains on the owner's queue, and the Bluetooth probe may
acknowledge a history chunk only from the successful persistence completion,
preserving persist-before-ACK ordering throughout the migration.

## Change rules

Do not add a second persistence owner, network dependency, or app-global mutable
singleton for new logic. Pass time, defaults, schedulers, and filesystem roots
into policy/orchestration code. When modifying a separable responsibility in
`WhoopStore`, `WhoopHandshakeProbe`, or `RootView`, prefer extracting a focused
type rather than growing the file. Database evolution must be transactional,
backed up according to the migration runbook, and covered from the oldest
supported schema to current.

Project structure and compiler policy live in `project.yml`; the checked-in
Xcode project is generated output for Xcode usability. Private build assets are
embedded through the data-driven `Tools/embed_private_assets.sh` helper, and
test protocol fixtures are constructed by `WhoopTestFrameFactory`.
The large store integration suite is partitioned by migrations, packet
persistence, sleep analysis, step materialization, recovery models, and
dashboard behavior; shared SQLite/frame helpers live in `WhoopTestFixtures.swift`.
`Tools/toolchain.json` is the exact accepted build environment. The warm-cache
inner loop is intentionally separate from the isolated final gate; only a clean
commit can cache a short-lived full-gate attestation, and pull-request CI ignores
it. After merge, main CI reuses GitHub's successful PR result only when the
protected check came from GitHub Actions and the main and PR commits have the
exact same tree; every mismatch or API failure falls back to the full gate.
SwiftLint's type-checked `unused_declaration` analyzer rejects new production
dead code against a reviewed baseline. The file-size gate scans both app source
trees and tests; inherited oversized coordinators may only shrink from their
explicit baselines.
