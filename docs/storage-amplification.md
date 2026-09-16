# Storage amplification measurement

The app measures schema-10 storage behavior before any production schema-11
migration. Telemetry is a bounded JSON sidecar at
`Library/Application Support/Sleep/storage-telemetry-v1.json`; measurement does
not add rows to the evidence database it is measuring.

## What is measured

- Every delivery: unique/retry/failure outcome, payload bytes, frame type,
  whether exact retry detection was enabled, transaction latency through
  `COMMIT`, and queue wait. Fixed arrays keep this path allocation-free.
- Every 15 minutes when packets arrive or the app backgrounds: physical main,
  WAL, and shared-memory file sizes plus the non-mutating WAL checkpoint
  sequence.
- Roughly daily: page size/count/freelist, allocated database bytes, unique raw
  packets and payload bytes, distinct source pairs, replay-ledger retry counts,
  derived-table row counts, a passive checkpoint, and total census duration.

The daily census uses a separate SQLite connection on a utility queue. Repeated
censuses of the current phone-sized database took about 2.5–6.1 seconds on the
Mac, so it
must never block the serialized ingestion queue. Telemetry is fail-open: a
write or census failure is counted, while raw packet durability remains the
only success criterion for ingestion. Pending and in-flight counters are
persisted so a crash during a census does not silently discard the interval.

The sidecar retains ten daily snapshots and eight days of 15-minute samples.
Full phone backups validate and hash it when present.

## Backup amplification

A restore point is one validated standalone database plus irreplaceable bounded
sidecars. The live database/WAL used for transport and the app's recursive
`migration-backups` directory are temporary inputs, not additional restore
points. `Tools/maintain_device_backups.sh --apply --adopt-legacy` normalizes
older managed layouts only after the standalone database and official archive
pass their checks; if the path is referenced by install state, the rewritten
hash set is synchronized before the maintenance run completes. A compaction error leaves any already-valid
manifested or protected backup active and ineligible for unusable cleanup.

The pre-pipeline `app-backups` tree needs global deduplication because the same
schema-transition image may appear in several later folders. Use
`Tools/consolidate_legacy_backups.sh`: it selects one fullest valid image for
each missing schema, materializes and revalidates a standalone copy, then moves
the old folders into recorded quarantine. This keeps recovery coverage without
multiplying copied historical databases.

## Collect and analyze

Analyze any copied sidecar:

```sh
Tools/storage_report.sh analyze path/to/storage-telemetry-v1.json
```

Copy the sidecar directly from the paired phone and analyze it without
reinstalling the app or opening iPhone Mirroring:

```sh
Tools/storage_report.sh collect-phone \
  --output /private/output/storage-telemetry-v1.json
Tools/storage_report.sh analyze /private/output/storage-telemetry-v1.json
```

The report uses endpoint deltas rather than dividing the current whole database
by a short interval. It reports marginal bytes per new unique packet, payload
amplification, retry ratios by frame from the live ingestion windows, latency
histograms, WAL/checkpoint behavior, census cost, and derived rows per new
packet. Cumulative retry figures use only replay-ledger-covered signatures in
their denominator; all historical raw packets are shown separately.

The analyzer refuses a confident slope before both 72 hours and four daily
snapshots. Three days is a provisional decision point; seven days is the
preferred final window. Every snapshot records the database schema and exact
source commit. Mixed builds/schemas are rejected; telemetry write failures or
poor reconciliation between exact ingestion counters and the database packet
delta downgrade the result. Counter decreases, duplicate timestamps, or zero
packet growth invalidate the corresponding conclusion instead of being silently
averaged.

## Current baseline and schema-11 prototype

The first read-only audit of a real schema-10 backup found:

- 956,559,360 database bytes for 2,101,409 unique raw packets;
- 154,904,823 raw payload bytes, or 6.175× whole-database/payload amplification;
- 43,074 suppressed retries among 734,418 replay-covered deliveries (5.865%);
- about 620 MB in raw storage/indexes, 78 MB in replay storage/indexes, 190 MB
  in historical samples/indexes, and 61 MB in heart-rate storage/indexes;
- one peripheral and four source pairs, while repeated peripheral and
  characteristic strings account for roughly 151 MB before index overhead.

These numbers justify an offline schema-11 prototype independently of the live
slope. Run it only against a disposable destination:

```sh
Tools/storage_v11_prototype.py \
  --source /private/backup/sleep-standalone.sqlite3 \
  --output /private/benchmark/schema11.sqlite3
```

The prototype opens the source read-only, refuses an existing destination, and
benchmarks integer packet keys, normalized source and offload references,
integer derived references, and a `WITHOUT ROWID` replay table. It validates
counts, semantic content, integrity, foreign keys, representative query results,
and query plans, then reports final size, elapsed time, and migration high-water
estimates. Private database contents and reports must stay outside the repo.

The checked-in harness converted the current 2.1-million-packet backup from
956,592,128 to 458,280,960 bytes, a 52.09% reduction. Its 123.75-second run
includes a full `integrity_check` of both source and candidate plus semantic
SHA-256 parity for all seven transformed and nine untouched tables. Two
production-unreferenced indexes consume another 78.5 MB, but they must be
removed only after a complete query inventory and plan-parity test.

## Production schema-11 gate

Schema 11 is intentionally not part of the app yet. Before enabling it on the
phone, require all of:

1. At least 72 hours/four snapshots of valid live telemetry, preferably seven
   days, with meaningful packet growth.
2. Semantic hashes and row-count parity for every migrated evidence and derived
   table, `integrity_check`, `foreign_key_check`, and production-query result and
   `EXPLAIN QUERY PLAN` parity.
3. Fault injection for interruption, restart, rollback, `SQLITE_FULL`, every
   table/index/copy phase, checkpoint, and compaction.
4. A schema-aware phone preservation verifier. The current shipping verifier
   intentionally expects schema-10 columns and text packet IDs.
5. On-device free-space gating that includes the old retained rollback image,
   the new pre-migration snapshot, copy/WAL growth, and compaction. The
   deliberately conservative harness estimates a 4.46 GB full high-water and
   3.51 GB of temporary free space before any additional safety margin.
6. An explicit lifecycle for the retained schema-10 rollback snapshot. Keeping
   that 956.6 MB image indefinitely would make post-migration phone storage
   larger even though the live database is half the size.

Until those gates pass, shipping telemetry is safer than shipping the migration:
it measures the real current policy without risking the canonical phone data.
