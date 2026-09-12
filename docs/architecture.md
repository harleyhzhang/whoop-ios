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
lifecycle and notification orchestration; `RootView.swift` renders snapshots and
forwards user intent. Presentation helpers live in `DashboardComponents.swift`,
`DashboardMetric.swift`, and `TrendSupport.swift`. `HealthHistoryModel.swift`
adapts store snapshots for charts. Data contracts remain in `SleepModels.swift`,
while scoring features and model bundles live in `ScoreModels.swift`.

`WhoopHandshakeApp` is the device and persistence layer:

- `WhoopHandshakeProbe.swift` adapts CoreBluetooth callbacks and coordinates a
  connection/offload session.
- `WhoopBluetoothPolicy.swift` owns deterministic advertisement, framing,
  charging-inference, acknowledgement, and history-completion decisions. Its
  typed `WhoopCommand` values are the only production owners of wire opcodes and
  payloads.
- `WhoopProtocol.swift` owns frame integrity and pure protocol decoders.
- `WhoopStoreModels.swift` owns persistence and process result contracts.
- `WhoopStore.swift` owns SQLite schema/migrations, evidence persistence,
  decoding, projections, and snapshot queries.
- `HandshakeView.swift` is diagnostic presentation only; collection is owned by
  the app-lifetime probe.

The direction of dependency is presentation → orchestration → pure policy and
storage. Pure policy must not import SwiftUI, CoreBluetooth, or global clocks.
Framework APIs belong behind small adapters so decisions can be unit tested.

## Data flow

1. CoreBluetooth delivers a packet to the probe.
2. Integrity and protocol policy classify it.
3. The store serially persists raw evidence and decoded observations.
4. Only the successful persistence completion may acknowledge a history chunk.
5. A durable `HISTORY_COMPLETE` permits finalization and snapshot publication.
6. SwiftUI observes the published snapshot; it does not infer missing evidence.

## Storage representation

SQLite separates immutable evidence from rebuildable query projections:

- `whoop_raw_packet` retains every unique transport payload and its provenance.
  Exact retries of the same characteristic/payload pair increment
  `whoop_packet_replay` through one atomic upsert.
- `whoop_latest_heart_rate` is a singleton freshness cache. Nonpositive readings
  never replace a valid latest value, but they also never block raw persistence.
- `heart_rate_sample` retains only packets with R-R intervals because those
  packet boundaries and timestamps are required for nightly HRV.
- Versioned rows in `whoop_historical_sample` and `whoop_ppg_packet` are the
  success record for decoding. `whoop_decode_failure` is a sparse ledger for
  unsupported and rejected packets, preserving diagnosability without a second
  row for every successful decode.

Schema migrations run transactionally only after a validated online SQLite
backup. The store retains one app-created rollback snapshot, prunes only older
snapshots matching its own naming contract, and attempts `VACUUM` after a
successful migration. A failed `VACUUM` is non-fatal: SQLite keeps the released
pages on its freelist and reuses them as collection continues.

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
