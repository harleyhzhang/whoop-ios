# WHOOP data migration and preservation runbook

This guide describes how to seed WHOOP iOS from the richest available history,
then continue locally from a personally owned WHOOP 5. It is an architecture
and operations runbook, not a record of one person's migration.

The central rule is simple: source evidence is immutable, derived data is
rebuildable, and UI projections never become the only surviving copy of a
measurement.

The current implementation contract is schema 10 and automatic-only sleep
publication. There is no manual Process control or loading state: explicit
awake evidence finalizes immediately, ambiguous `up` evidence waits ten
minutes, and sleep returning within 90 minutes silently grows the same night.

## Data sources and authority

Use every source that is available, but do not pretend that the sources are
interchangeable:

| Source | Best use | Authority and limits |
| --- | --- | --- |
| Official account export | Portable CSV snapshot and independent cross-check | Supported by WHOOP, but its fields depend on product, membership, and export version. It is not a packet archive. |
| WHOOP Developer API v2 | Structured cycles, recoveries, sleeps, workouts, profile, and body measurements | Supported OAuth API. It does not expose continuous heart-rate data and does not currently expose every metric visible in the official app. |
| Optional official-iOS/private API capture | Exact official-app responses such as trend tiles, deep dives, stress, journals, and historical Steps | Unsupported and changeable. Use read-only requests against your own account only. Do not make this path a runtime dependency. |
| Direct WHOOP 5 BLE collector | Ongoing raw packets, decoded samples, Steps evidence, and locally derived sleep/recovery | The only source that continues without cloud access. It cannot reconstruct packets that were never collected and have already been trimmed from the strap. |

The corresponding capability and provenance matrix is:

| Evidence or metric | Account export | Developer API v2 | Optional private-iOS capture | Direct WHOOP 5 BLE |
| --- | --- | --- | --- | --- |
| Exact transport bytes | No | HTTP bodies only | HTTP bodies only | Yes, with characteristic, receipt time, peripheral, and delivery sequence |
| Cycles and day Strain | CSV snapshot | Supported, paginated | Official-app deep dives | Future local model input; not an exact cloud backfill |
| Recovery score | Exported target when present | Supported target | Exact official-app target and contributor tiles | Versioned local prediction only |
| Sleep score, timing, and stages | Exported summary | Supported scored sleeps | Deep dive and hypnogram when retained | Locally detected/derived; stages remain model-dependent |
| HRV and RHR | Daily summary | Recovery record | Value plus displayed baseline | Derived from retained R–R/HR evidence |
| Steps | Inspect delivered schema | Not exposed by current v2 collections | Exact daily total when retained | Wrap-aware projection from retained motion counters |
| Continuous HR/R–R | No continuous series | Not available | App-dependent summaries | Yes, from live/history packets actually collected |
| Stress, journals, calendars | Export-dependent | Not in current archive scopes | Richest historical source when retained | Only future derived/local evidence |
| Raw IMU/PPG | No | No | Not a raw device backfill | Only if explicitly captured; passive mode intentionally avoids battery-heavy IMU |

Every imported or derived record should identify its source archive, source
object or packet, source hash where available, importer/decoder version,
algorithm/model version, and derivation/import time. A value without provenance
is not suitable for later backtesting.

When sources overlap, retain both with provenance. For the displayed value,
prefer an exact official historical target over a local estimate. Never
overwrite official targets with model predictions.

## Prerequisites and private-data boundary

You need:

- the exact Xcode build, iPhoneOS SDK, simulator runtime, Python, and Homebrew
  formula versions recorded in `Tools/toolchain.json`; run
  `Tools/doctor.sh --toolchain-only` before building;
- an iPhone on which you can install a development-signed build;
- a WHOOP account and personally owned WHOOP 5;
- a WHOOP Developer app for the supported API path; and
- enough private disk space for immutable source captures and app build
  products. A full private-app capture can exceed a gigabyte before
  compression.

Define machine-local locations rather than putting personal data under the Git
checkout:

```sh
export WORKSPACE=/path/to/whoop-ios
export PRIVATE_DATA_ROOT=/private/path/whoop
export APP_SEED_ROOT="$PRIVATE_DATA_ROOT/app-seeds"
export ARCHIVE_TOOL_ROOT=/path/to/private/archive-tools
mkdir -p "$PRIVATE_DATA_ROOT" "$APP_SEED_ROOT"
chmod 700 "$PRIVATE_DATA_ROOT" "$APP_SEED_ROOT"
```

The following are private health or authentication artifacts and must never be
committed, attached to a pull request, pasted into a shell transcript, or
uploaded as CI artifacts:

- account-export ZIP/CSV files;
- raw Developer API and private-iOS API archives;
- `whoop-history.json`, `whoop-official-metrics.json`, and the compressed
  official response sidecar;
- fitted sleep and Recovery model files;
- the app's SQLite database and migration backups;
- OAuth client secrets, access/refresh tokens, passwords, and one-time codes.

The repository `.gitignore` covers the standard generated filenames, and CI
rejects them if they are accidentally staged. That is a backstop, not the
primary boundary. Keep the whole private data root outside Git, use restrictive
permissions, and store long-lived tokens in macOS Keychain. The iPhone app
contains no API client secret or refresh token.

Before every commit, check both filenames and object contents:

```sh
cd "$WORKSPACE"
git status --short
git ls-files | grep -E '(^|/)(sleep\.sqlite3|whoop-history\.json|whoop-score-model\.json|whoop-recovery-model\.json|whoop-official-metrics\.json|whoop-official-archive\.sqlite3)$' && exit 1 || true
```

## 1. Request the supported WHOOP account export

In the WHOOP iPhone app, open **More → App Settings → Data Export**, confirm the
email address, and choose **Create Export**. WHOOP says the download link should
arrive by email within 24 hours and expires after seven days. Download the ZIP
into a new read-only directory under the private data root and retain the
original ZIP as received. See WHOOP's current
[data-export instructions](https://support.whoop.com/s/article/How-to-Export-Your-Data).

Immediately record checksums without rewriting the source:

```sh
export ACCOUNT_EXPORT="$PRIVATE_DATA_ROOT/account-export-YYYYMMDD"
mkdir -m 700 "$ACCOUNT_EXPORT"
cp /path/to/downloaded-export.zip "$ACCOUNT_EXPORT/original.zip"
shasum -a 256 "$ACCOUNT_EXPORT/original.zip" > "$ACCOUNT_EXPORT/SHA256SUMS"
unzip -l "$ACCOUNT_EXPORT/original.zip" > "$ACCOUNT_EXPORT/file-list.txt"
chmod -R go-rwx "$ACCOUNT_EXPORT"
```

Extract into a sibling working directory, not over the original ZIP. Record the
file list, column headers, row counts, time bounds, and a checksum for every
file. Treat the export as a separate evidence source even when values duplicate
the API. Do not assume a present-day export can recover historical Steps or raw
sensor packets; inspect the delivered schema.

## 2. Archive the supported WHOOP Developer API

Create a client in the [WHOOP Developer Dashboard](https://developer.whoop.com/)
with an exact localhost redirect URI. Request only the scopes needed by the
archive: `offline`, `read:recovery`, `read:cycles`, `read:workout`,
`read:sleep`, `read:profile`, and `read:body_measurement`. WHOOP's current
[OAuth guide](https://developer.whoop.com/docs/developing/oauth) and
[API reference](https://developer.whoop.com/api/) are the source of truth.

Keep the client secret in a restricted configuration file and tokens in
Keychain. The companion archiver used by this project exposes the following
interface:

```sh
chmod 600 /private/path/whoop-oauth.env
"$ARCHIVE_TOOL_ROOT/whoop_archive.py" --config /private/path/whoop-oauth.env status
"$ARCHIVE_TOOL_ROOT/whoop_archive.py" --config /private/path/whoop-oauth.env authorize
"$ARCHIVE_TOOL_ROOT/whoop_archive.py" --config /private/path/whoop-oauth.env archive \
  --output "$PRIVATE_DATA_ROOT"
```

The authorization flow must validate OAuth `state`; request `offline` so the
refresh token is available; and rotate the stored token record after refresh.
Never print the client secret or token response. A run writes a new
`api-<UTC timestamp>` directory containing:

- every raw paginated response from cycles, recoveries, sleeps, and workouts;
- raw profile and body-measurement responses;
- combined collection JSON files for deterministic downstream processing; and
- a manifest containing file size, SHA-256, record count, page count, and time
  bounds.

Do not mutate a completed run. A refresh produces a new archive directory.
This preserves what the server returned at each point in time and lets later
code changes be replayed against the original evidence.

Build the app-facing sleep-history projection:

```sh
export PUBLIC_ARCHIVE="$PRIVATE_DATA_ROOT/api-YYYYMMDDTHHMMSSZ"
python3 "$WORKSPACE/Tools/make_history_seed.py" \
  "$PUBLIC_ARCHIVE" "$APP_SEED_ROOT/whoop-history.json"
```

The generator reduces scored, non-nap sleeps to one primary sleep per local
date. It keeps the full sleep and Recovery source objects alongside indexed
numeric/Boolean leaves in the phone database; the five-number dashboard is only
a view over that richer store.

## 3. Optionally archive official-iOS/private API responses

This path is useful because the official app can expose fields absent from the
public Developer API, including exact historical Steps and richer day-level
tiles. It is not a supported WHOOP interface. Endpoints, payloads,
authentication, rate limits, or access controls may change without notice.

Use this path only for your own account, issue only `GET` requests, pace calls,
honor rate limits, and preserve non-success responses for diagnosis. Do not
bypass CAPTCHA, device attestation, account controls, or a service refusal. If
the path stops working, retain the last good immutable archive and continue
with the supported export/API plus local BLE collection.

### Authentication and email OTP handling

Use a current official-app-compatible authentication helper in an interactive
terminal. Initiate login in the official app, a browser, or iPhone Mirroring.
The observed challenge can be `EMAIL_OTP`; do not assume it is SMS.

Handle credentials and the one-time code through a non-logging input channel:

1. Read the password from a password manager without copying it into the shell
   command line.
2. Retrieve the email OTP in the mail UI.
3. Submit it directly to the waiting authentication process through masked
   stdin or another secure IPC path.
4. Do not `echo` it, put it in a command argument, save an OTP screenshot, add
   it to shell history, or include it in automation logs.
5. Store only the resulting access/refresh token record in macOS Keychain.
   Delete any temporary token file immediately after Keychain import.

The archive must exclude authorization headers, cookies, passwords, OTPs, and
tokens. A safe request record contains only method, path, non-secret query,
status, fetch time, attempt count, content type, byte length, response SHA-256,
and the relative body filename.

With a token record already in Keychain, the companion read-only archiver is:

```sh
"$ARCHIVE_TOOL_ROOT/whoop_private_archive.mjs" \
  --start YYYY-MM-DD \
  --end YYYY-MM-DD \
  --output "$PRIVATE_DATA_ROOT"
```

It walks the official trend catalog in six-month windows, month calendars,
account snapshots, and daily deep-dive surfaces. The implemented catalog
contains 25 trend types: HRV, RHR, Recovery, day Strain, calories, Steps,
average HR, sleep need and duration measures, sleep performance/efficiency/
consistency/debt/restorative sleep, HR-zone time, respiration, strength time,
stress variants, VO2 max, body composition, and weight. Daily responses also
cover sleep hypnograms, Recovery/Strain deep dives, stress, journals, calendars,
and home/tilt surfaces when the account has them.

A completed run contains `catalog.json`, exact response bodies, an append-only
request journal, and `manifest.json`. The manifest's `completed_at` is the
commit marker. A run without it is incomplete and must not feed production
seeds. Retry transient failures with bounded exponential backoff and start a
new immutable run if the process cannot finish; do not silently splice two
captures together.

One complete reference migration covering 2025-10-15 through 2026-09-07 made
5,043 GET requests: 5,042 returned HTTP 200 and one optional health-report
surface returned 404. It retained 1,033,973,775 exact response bytes. Those
numbers are a regression fixture for this version of the catalog, not a promise
about another account or a future official app.

## 4. Verify the raw private archive

Before materializing anything, independently check every manifest entry:

```sh
export PRIVATE_ARCHIVE="$PRIVATE_DATA_ROOT/private-api-YYYYMMDDTHHMMSSZ"
python3 - "$PRIVATE_ARCHIVE" <<'PY'
import hashlib, json, pathlib, sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
assert manifest.get("completed_at"), "archive is incomplete"
for record in manifest["records"]:
    body = (root / record["file"]).read_bytes()
    assert len(body) == record["bytes"], record["file"]
    assert hashlib.sha256(body).hexdigest() == record["sha256"], record["file"]
print(f"verified {len(manifest['records'])} responses")
PY
```

Also inspect status counts, coverage dates, and unexpectedly empty bodies. A
404 for a genuinely optional endpoint is not equivalent to a corrupt archive;
a missing required day or checksum mismatch is.

## 5. Build the deterministic evidence sidecar and projections

Do not ship a gigabyte of duplicated raw responses directly. Generate two
private artifacts from the verified archive:

```sh
python3 "$WORKSPACE/Tools/make_official_history_seed.py" \
  "$PRIVATE_ARCHIVE" \
  "$APP_SEED_ROOT/whoop-official-archive.sqlite3" \
  "$APP_SEED_ROOT/whoop-official-metrics.json"
```

The SQLite sidecar is the evidence layer:

- `response_body` de-duplicates identical bodies by SHA-256 and zlib-compresses
  them at level 9;
- `request_record` retains the method, endpoint, query, status, timing,
  attempts, content type, raw length, and body hash for every request; and
- `archive_metadata` pins coverage and the source-manifest hash.

Decompression reproduces every retained response byte exactly. The JSON file
is only a small daily projection of official Steps, Recovery, Strain, and
baseline fields plus source hashes. The app refuses to import this projection
unless the checksum-matching full sidecar is present.

Generate into new staging filenames when replacing a production seed, run the
same command twice, and compare hashes to test determinism:

```sh
mkdir -p "$APP_SEED_ROOT/check"
python3 "$WORKSPACE/Tools/make_official_history_seed.py" \
  "$PRIVATE_ARCHIVE" "$APP_SEED_ROOT/check/archive.sqlite3" \
  "$APP_SEED_ROOT/check/metrics.json"
shasum -a 256 \
  "$APP_SEED_ROOT/whoop-official-archive.sqlite3" \
  "$APP_SEED_ROOT/check/archive.sqlite3"
cmp "$APP_SEED_ROOT/whoop-official-metrics.json" \
  "$APP_SEED_ROOT/check/metrics.json"
sqlite3 "$APP_SEED_ROOT/check/archive.sqlite3" 'PRAGMA quick_check;'
```

The reference capture compacted to a checksum-verified 61.5 MB sidecar with
5,043 request records and 4,692 unique response bodies. Keep the 1.03 GB raw
directory too: compression is a distribution optimization, not permission to
discard the acquisition source.

## 6. Join historical and ongoing Steps

Official trend summaries alone may not contain the oldest daily values. In the
reference migration, each historical Strain deep dive exposed its exact daily
Steps total, yielding 317 official days from 2025-10-16 through 2026-08-31.
The official app then showed missing values while it was unpaired, and local BLE
collection began on 2026-09-01. That produced a clean boundary without
fabricating pre-collection Steps.

The join is a precedence rule, not a destructive merge:

```sql
SELECT date_key, step_count, source
FROM (
    SELECT date_key, official_steps AS step_count,
           'whoop_private_ios_api' AS source
    FROM whoop_official_daily_metric
    WHERE official_steps IS NOT NULL
    UNION ALL
    SELECT local.date_key, local.step_count, local.source
    FROM whoop_daily_step_metric AS local
    WHERE NOT EXISTS (
        SELECT 1
        FROM whoop_official_daily_metric AS official
        WHERE official.date_key = local.date_key
          AND official.official_steps IS NOT NULL
    )
)
ORDER BY date_key;
```

The local value is derived from the WHOOP 5 version-18 cumulative motion
counter with wrap-aware deltas and implausible-delta rejection. Preserve every
underlying counter, cadence-like byte, motion-class byte, sample timestamp,
civil-date offset, and source packet. `whoop_daily_step_metric` is a rebuildable
projection containing coverage, gap seconds, wraps, rejected deltas, source,
and algorithm version. It does not enable the battery-heavy raw IMU stream and
does not use the phone's Motion & Fitness data.

Never fill a gap by carrying a cumulative counter across an unobserved reset or
by inventing an average. If no official total and no adequate local evidence
exist, the honest displayed value is missing.

Steps are not a trained regression target in the current app. Validate the
counter interpretation separately with hand-counted walks, ordinary worn days,
counter-wrap fixtures, known resets, and coverage gaps. In the original decoder
validation, a continuous day-scale retained sample produced a plausible total
with no implausible accepted jumps. That establishes plausibility, not ground
truth or equality with WHOOP's accelerometer/ML production algorithm. Keep both
the exact official totals and the local evidence so later calibration can
measure bias without rewriting history.

## 7. Continue with direct WHOOP 5 BLE collection

Only one app should actively own the strap connection during setup. Complete
the official export/cloud capture first, then close the official app before
pairing the local client. Charge the strap, enable Bluetooth, install the app,
open its diagnostic surface, scan, select the intended device, and complete the
encrypted handshake. Confirm that the saved bond reconnects after relaunch
before trusting unattended collection.

The collector's durability boundary is the history acknowledgement:

1. save the original notification bytes in `whoop_raw_packet`;
2. save decoder status and decoded samples with their source-packet IDs;
3. commit the SQLite transaction;
4. persist a `HISTORY_COMPLETE` record for the offload; and only then
5. acknowledge the history chunk to the strap.

The strap may trim history after acknowledgement. Never acknowledge an
in-memory prefix, a failed transaction, or a chunk whose completion marker is
not durable. Exact transport replays on the same characteristic retain their
first payload and increment a replay ledger so retry traffic cannot multiply
the database while still counting as durably handled.

Passive operation keeps lightweight heart-rate/R–R streaming and historical
offload active, but disables the high-rate R10/R11 raw sensor burst. Record a
time-zone/UTC-offset timeline alongside absolute sensor timestamps so later
consistency models can reconstruct local civil time after travel.

After pairing, verify all of these on real hardware:

- foreground collection and decoded heart-rate/R–R samples;
- background growth while the phone is locked;
- reconnect after force-quit/relaunch and Bluetooth interruption;
- historical offload completion and acknowledgement ordering;
- no duplicate raw growth from repeated transport frames; and
- a completed local sleep only after evidence, automatic wake, metric-completeness,
  and HISTORY_COMPLETE gates pass; resumed sleep within ninety minutes repairs it.

## 8. Backtest Sleep Score and Recovery without leakage

### Sleep Score

Use the public API archive to train the independent Sleep Score model:

```sh
python3 -m venv /private/path/whoop-model-venv
/private/path/whoop-model-venv/bin/pip install \
  numpy==2.3.5 scikit-learn==1.7.2
/private/path/whoop-model-venv/bin/python \
  "$WORKSPACE/Tools/backtest_sleep_score.py" \
  "$PUBLIC_ARCHIVE" \
  --model-output /private/path/candidates/whoop-score-model.json
```

The production feature contract uses only values available after cloud access
ends: sleep duration, efficiency, circular sleep/wake timing, timing agreement,
and seven nights of history. It first predicts dynamic sleep need and
consistency, maps predicted sufficiency/consistency/efficiency through an RBF
SVR, and blends 10% of a direct Extra Trees/SVR estimate for stability.

On the 306-night reference archive, the discarded fixed
`duration / 519 minutes` score had 5.73-point all-night MAE and caused a
misleading run of 99s. Exact exported sufficiency, consistency, and efficiency
reproduced WHOOP's score with 0.83-point forward-held-out MAE. The deployable
local-input model reached 1.68-point forward-held-out MAE, 2.43 RMSE, and R²
0.920. HRV, RHR, stages, respiration, and ad-hoc stress proxies were evaluated
and rejected because they worsened unseen-night error. Preserve the rejected
experiment results as model-development evidence rather than quietly adding
features that only improve training fit.

Local sleep rows store the predicted need, consistency, sufficiency, and
observed efficiency in addition to the final score. These are rebuildable
materializations; complete public API source objects remain the evidence.

### Recovery

Historical official Recovery scores are labels, not production inputs. Keep
them in `whoop_official_daily_metric`. Local estimates live independently in
`whoop_daily_recovery_metric`; the UI may prefer the official target at read
time, but storage never coalesces the two.

Train the current model from the public API sleep/Recovery archive plus the
official daily Steps projection:

```sh
/private/path/whoop-model-venv/bin/python \
  "$WORKSPACE/Tools/backtest_recovery_score.py" \
  "$PUBLIC_ARCHIVE" \
  "$APP_SEED_ROOT/whoop-official-metrics.json" \
  --model-output /private/path/candidates/whoop-recovery-model.json
```

The v1 feature contract has 169 values built only from signals the independent
app can continue producing: local sleep features, HRV, RHR, Steps, seven lags,
and past-only rolling statistics over 7, 14, 30, and 60 days. For a score on
day *D*, no feature may read an official Recovery target for *D* or any data
after *D*. Missing Steps remain missing and are imputed from training data; do
not replace them with the official answer or a future daily total.

Validation must be chronological. Random train/test splits leak temporal
baselines and overstate performance. The current trainer uses four expanding
forward folds with training cutoffs at 180, 210, 240, and 270 nights, then fits
the final 70% gradient-boosting / 30% ridge blend only after recording the
forward metrics. The reference 306-night dataset produced 126 unseen
validation nights with:

- mean absolute error: 4.79 points;
- root mean squared error: 6.70 points;
- R²: 0.875;
- median absolute error: 3.46 points;
- 90th-percentile absolute error: 10.59 points; and
- 63.49% of estimates within five points.

These figures are an honest backtest on one history, not official-WHOOP parity
or a guarantee for another person. The fitted model is private because its
tree thresholds, imputers, coefficients, and baselines are derived from health
history. Store model version, feature version, training count/date, validation
metrics, every prediction input, confidence, component counterfactuals,
baselines, and derivation time. A changed feature contract requires a new model
version and a full rebuild; never silently reinterpret old rows.

### Canonical model promotion

The standalone trainers above are for experiments and candidate inspection;
they must not overwrite the active private bundle. Promote the sleep/Recovery
pair together with:

```sh
Tools/promote_private_models.sh \
  --archive "$PUBLIC_ARCHIVE" \
  --private-root "$APP_SEED_ROOT"
```

Add `--dry-run` to exercise every gate without replacing either file. The
command reruns both chronological backtests, validates all numeric parameters
for finiteness, enforces the exact model/feature versions and 50/169 feature
counts, rejects MAE/RMSE/p90 error above the absolute or current-model
regression limits in `Tools/model_promotion_policy.json`, checks the generated
feature contract, runs the same synthetic Python/Swift golden vectors, and
loads/predicts with the candidate bundles in `SleepPrivateTests`. Only after
all checks pass does it replace the model pair, with rollback if the second
replacement fails.

## 9. Rebuild, retry, and idempotency rules

The workflow is safe to rerun because identity travels with the data:

- acquisition always writes a new immutable timestamped directory;
- raw file SHA-256 and byte count detect truncation or mutation;
- an incomplete private archive has no `completed_at`, and the compactor
  refuses it;
- duplicate official response bodies are keyed by SHA-256;
- the public-history and official-projection imports record their bundle hashes
  in `whoop_store_metadata` and skip an already imported seed;
- official daily rows upsert by civil date but retain source archive and
  response/manifest hashes;
- local Steps rebuild only from stored historical samples and carry an
  algorithm version; version 2 assigns samples to wake-anchored days, so
  movement after midnight but before the next completed sleep remains on the
  preceding day and existing civil-day projections rebuild from raw counters;
- local Recovery rows rebuild when the model version changes and retain their
  complete input vector; and
- a failed SQLite transaction rolls back instead of marking the import or
  derivation complete.

For a network failure, preserve the incomplete run for diagnosis and start a
new run. For a deterministic materialization failure, fix the generator and
replay it against the same verified archive. For an app import failure, verify
the bundled sidecar hash and projection source hash before retrying; do not edit
the projection by hand.

### Troubleshooting and safe restart

| Symptom | Check | Safe action |
| --- | --- | --- |
| OAuth callback times out | Registered redirect host/port and exact URI match | Correct the developer-client redirect and rerun authorization; do not reuse a code from a failed state check. |
| Public API returns 401 | Token expiry and presence of an offline refresh token | Refresh through OAuth; if refresh is unavailable, authorize again. Do not paste a token into logs. |
| Private capture receives 401 | JWT expiry and Keychain token record | Let the helper refresh once; if official auth now differs, reauthenticate interactively. |
| Private capture receives 429/5xx | Request pacing, `Retry-After`, and attempt count | Use bounded backoff. Preserve the incomplete run and begin a fresh immutable run if it cannot finish. |
| Manifest verification fails | Named file's byte count and SHA-256 | Quarantine that run and reacquire it. Never materialize a partially repaired archive. |
| Sidecar projection import is skipped | Bundle contains both artifacts and `sourceDatabaseSHA256` matches | Regenerate both from the same manifest and rebuild the app; never edit one independently. |
| Historical Steps stop early | Official deep-dive retention and account pairing dates | Join the exact retained prefix to local evidence. Leave the uncovered interval missing. |
| Local Steps look discontinuous | Coverage, rejected deltas, wraps, timezone offsets, and counter resets | Inspect source samples and rerun the versioned materializer; do not hand-correct totals. |
| Recovery rows are stale | `model_version`, feature version, metadata backfill marker, and bundle hash | Bump the model version, rebuild from past-only inputs, and preserve official targets. |
| BLE history stalls | Latest delivery sequence, offload status, and durable completion marker | Let the watchdog reconnect/retry. Never acknowledge an incomplete prefix. |
| App migration does not open | Pre-migration backup, `PRAGMA quick_check`, and device free space | Stop, retain both containers, diagnose off-device, and reinstall only after the database is proven restorable. |

The current private archiver does not append a second process onto an incomplete
run. Its request journal supports diagnosis, not silent resume. A future resume
implementation must verify the catalog, date range, account identity without
persisting identifiers, and every retained body hash before continuing; until
then, a new run is the correct retry unit.

## 10. Build, sign, install, and preserve migration backups

### Canonical one-command workflow

Do not perform the build, signing, backup, or CoreDevice steps below by hand in
normal operation. From a clean worktree checked out at the exact merged commit,
run:

```sh
Tools/ship_phone.sh --commit "$(git rev-parse HEAD)"
```

`ship_phone.sh` is the only supported routine installation path. It:

1. requires a clean HEAD that is already reachable from the current
   `origin/main`;
2. runs the install classifier and a `Tools/doctor.sh` preflight for Xcode,
   iPhoneOS SDK, CoreDevice, pairing, Developer Mode, free space, signing
   identity/profile, the existing app container, and all five private assets;
3. validates model feature versions and dimensions, archive/projection hashes,
   and SQLite integrity before building;
4. builds and signs the exact commit, embeds that SHA in `WHOOPSourceCommit`,
   verifies the signature/profile and byte-matches every bundled private asset;
5. uses CoreDevice directly, without iPhone Mirroring, and installs in place;
6. for `full`, suspends the app with guaranteed resume cleanup while taking
   coherent pre/post copies, creates standalone SQLite images, validates schema,
   `quick_check`, foreign keys, hashes, and nondecreasing durable health rows;
7. launches the app, proves the process is alive and the database or WAL
   advanced, then atomically updates the private install-state file.

The defaults point to Harley's canonical private seed, backup, and install-state
locations outside Git. Override `--private-root`, `--backup-root`, `--state`, or
`--device` only for a deliberate recovery or test. `Tools/doctor.sh --mode full`
is a read-only preflight, and `Tools/ship_phone.sh ... --dry-run` resolves and
prints the complete plan without building or installing.

If installation completes while the phone is locked, the command exits 75 with
`status=needs-unlock` and prints one exact `--resume <manifest>` command. Unlock
the phone and run that command. The same mechanism reports
`needs-verification` if a post-install connection is interrupted. Resume never
reinstalls the app, and neither state is permission to uninstall it.
`status=needs-device` means CoreDevice cannot currently reach the paired phone;
keep it awake on the same network and rerun the unchanged command.

### Verification tiers

The shipping command invokes `Tools/phone_install_policy.sh` internally. The
classifier compares the requested commit with `installedCommit` in the private
state file.

- `none` means no production app code changed, so there is nothing to install.
- `fast` is restricted to presentation-only changes in `RootView.swift` or the
  asset catalog. Reuse a recent integrity-checked full backup, install in place,
  launch, confirm the process remains alive, and confirm the database or WAL
  modification time advances. Do not copy the complete database before or after
  this tier.
- `full` covers any data store, schema, migration, model, collector, lifecycle,
  app identity, project configuration, or unclassified production change. Use
  the coherent pre/post snapshot procedure below. Connect the iPhone by USB
  when practical because CoreDevice otherwise transfers the entire database
  over Wi-Fi without delta compression.

Current CoreDevice app inventory does not expose a physical data-container UUID.
The command therefore proves preservation from the in-place install plus pre/post
database, schema, integrity, foreign-key, file-hash, and raw-row checks; it does
not depend on a private path identifier that iOS may rotate.

The policy intentionally fails closed to `full` if the installed baseline is
missing, unavailable, divergent, or ambiguous. A fast install is a verification
optimization, not permission to skip exact-commit building, signing checks,
private-asset hash checks, in-place installation, launch, or runtime validation.

The remaining commands in this section document what the orchestrator enforces
for diagnosis and recovery. They are not a parallel routine install procedure.

Generate the Xcode project after changing `project.yml`:

```sh
cd "$WORKSPACE"
xcodegen generate
```

Run tests without private assets to prove a public checkout still builds:

```sh
WHOOP_HISTORY_SEED_PATH=/tmp/missing-whoop-history.json \
WHOOP_SCORE_MODEL_PATH=/tmp/missing-whoop-score-model.json \
WHOOP_RECOVERY_MODEL_PATH=/tmp/missing-whoop-recovery-model.json \
WHOOP_OFFICIAL_METRICS_PATH=/tmp/missing-whoop-official-metrics.json \
WHOOP_OFFICIAL_ARCHIVE_PATH=/tmp/missing-whoop-official-archive.sqlite3 \
xcodebuild test -quiet \
  -project Sleep.xcodeproj -scheme Sleep -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -derivedDataPath /tmp/WhoopDerivedData CODE_SIGNING_ALLOWED=NO
```

This is also the expected clean-clone behavior. Simulator/CI builds deliberately
run with all private paths missing, import no real history, and show missing
values instead of synthetic health data. They still compile and exercise the
database, feature builders, chart logic, and synthetic fixtures. In contrast,
a `Release` build for `iphoneos` fails closed when any required personal
history, model, projection, or sidecar is missing. Never weaken that distinction
to make CI look more like the private device build.

For the personal device build, supply every private artifact explicitly. A
physical Release build fails closed when one is absent:

```sh
export WHOOP_HISTORY_SEED_PATH="$APP_SEED_ROOT/whoop-history.json"
export WHOOP_SCORE_MODEL_PATH="$APP_SEED_ROOT/whoop-score-model.json"
export WHOOP_RECOVERY_MODEL_PATH="$APP_SEED_ROOT/whoop-recovery-model.json"
export WHOOP_OFFICIAL_METRICS_PATH="$APP_SEED_ROOT/whoop-official-metrics.json"
export WHOOP_OFFICIAL_ARCHIVE_PATH="$APP_SEED_ROOT/whoop-official-archive.sqlite3"
export DERIVED_DATA=/private/path/WhoopDeviceBuild
export DEVELOPMENT_TEAM_ID=YOUR_APPLE_DEVELOPMENT_TEAM_ID

xcodebuild build -quiet \
  -project Sleep.xcodeproj -scheme Sleep -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic
```

Before replacing an installed app, close it and pull its Application Support
directory to private storage. Copying the entire app-data container with
`--source .` can fail on Apple's protected
`.com.apple.mobile_container_manager.metadata.plist` even though the app's own
files are accessible; that metadata file is not needed for a WHOOP database
rollback.

```sh
export DEVICE_ID="YOUR DEVICE UDID OR NAME"
export BUNDLE_ID=org.example.whoop
export PREINSTALL_BACKUP="$PRIVATE_DATA_ROOT/device-backups/preinstall-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$PREINSTALL_BACKUP/Sleep"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source 'Library/Application Support/Sleep' \
  --destination "$PREINSTALL_BACKUP/Sleep"

export PREINSTALL_DB="$PREINSTALL_BACKUP/Sleep/sleep.sqlite3"
export STANDALONE_DB="$PREINSTALL_BACKUP/Sleep/sleep-preinstall-standalone.sqlite3"
sqlite3 "$PREINSTALL_DB" "PRAGMA quick_check; PRAGMA user_version;"
sqlite3 "$PREINSTALL_DB" ".backup '$STANDALONE_DB'"
sqlite3 "$STANDALONE_DB" 'PRAGMA quick_check;'
shasum -a 256 "$PREINSTALL_DB" "$STANDALONE_DB" \
  > "$PREINSTALL_BACKUP/SHA256SUMS"
```

Retain the original pulled directory as evidence even after making the
standalone image. If the source directory contains `sleep.sqlite3-wal` or
`sleep.sqlite3-shm`, keep them beside the database; do not checksum or move the
database alone and assume it represents all committed pages. Stop and diagnose
the backup before installing if either integrity check fails.

Install in place so the data container is migrated rather than erased:

```sh
export APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/WHOOP.app"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
xcrun devicectl device process launch \
  --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID"
```

Installation can finish while the phone remains locked, but iOS will deny the
launch until the device is unlocked. Unlock the phone, rerun only the launch or
printed shipping-resume command, and then continue with post-install
verification; do not uninstall/reinstall in response to this harmless launch
denial because uninstalling would erase the retained container. iPhone
Mirroring is not part of the shipping path.

If command-line automatic signing reports that Xcode has no configured account
but an appropriate development certificate and provisioning profile already
exist locally, either add the account in Xcode or select that matching profile
explicitly with `CODE_SIGN_STYLE=Manual`, `PROVISIONING_PROFILE_SPECIFIER`, and
`CODE_SIGN_IDENTITY`. Verify the resulting bundle identifier, version,
signature, embedded profile, and private-asset hashes before installation.

The store currently targets schema 10. Before any non-empty schema upgrade, it
uses SQLite's online backup API to create a WAL-consistent standalone database
under Application Support's `migration-backups` directory, then runs
`PRAGMA quick_check`. Migration fails closed if that snapshot cannot be made.
Keep the Mac-side preinstall container copy too; the two backups protect
different failure boundaries.

## 11. Verification checklist

Pull the post-install app container to a new private directory and locate the
main SQLite file plus the official response sidecar. Run:

```sh
export APP_DB=/private/path/postinstall/sleep.sqlite3
export SIDECAR=/private/path/postinstall/whoop-official-archive.sqlite3

sqlite3 "$APP_DB" 'PRAGMA quick_check; PRAGMA user_version;'
sqlite3 "$SIDECAR" 'PRAGMA quick_check; PRAGMA user_version;'

sqlite3 -header -column "$APP_DB" <<'SQL'
SELECT source, COUNT(*) AS nights, MIN(date_key), MAX(date_key)
FROM daily_health_metric
GROUP BY source
ORDER BY source;

SELECT COUNT(*) AS official_recovery_days,
       MIN(CASE WHEN official_recovery_score IS NOT NULL THEN date_key END) AS first_recovery,
       MAX(CASE WHEN official_recovery_score IS NOT NULL THEN date_key END) AS last_recovery,
       SUM(official_steps IS NOT NULL) AS official_step_days,
       MIN(CASE WHEN official_steps IS NOT NULL THEN date_key END) AS first_steps,
       MAX(CASE WHEN official_steps IS NOT NULL THEN date_key END) AS last_steps
FROM whoop_official_daily_metric;

SELECT model_version, COUNT(*) AS predictions, MIN(date_key), MAX(date_key)
FROM whoop_daily_recovery_metric
GROUP BY model_version;

SELECT source, algorithm_version, COUNT(*) AS local_step_days,
       SUM(step_count) AS steps, MIN(date_key), MAX(date_key)
FROM whoop_daily_step_metric
GROUP BY source, algorithm_version;

SELECT status, COUNT(*)
FROM whoop_offload_session
GROUP BY status;

SELECT COUNT(*) AS raw_packets,
       MIN(received_at) AS first_packet,
       MAX(received_at) AS last_packet
FROM whoop_raw_packet;

SELECT COUNT(*) AS migration_backfill_markers
FROM whoop_store_metadata
WHERE key IN ('bundled-history-sha256',
              'bundled-official-metrics-sha256',
              'bundled-official-archive-sha256',
              'local-recovery-score-backfill');
SQL

sqlite3 -header -column "$SIDECAR" <<'SQL'
SELECT COUNT(*) AS requests FROM request_record;
SELECT COUNT(*) AS unique_bodies,
       SUM(raw_bytes) AS unique_raw_bytes,
       SUM(length(compressed_body)) AS compressed_bytes
FROM response_body;
SELECT key, value FROM archive_metadata ORDER BY key;
SQL
```

Then verify behavior, not only row counts:

- the app launches without a sample-data fallback;
- the compact summary reads Sleep, Duration, Steps, Recovery, and RHR;
- an unresolved sleep leaves the latest coherent published day visible until
  the completed history is automatically finalized; there is no manual Process
  control or loading state;
- Steps appears as `Steps`, with no `Beta` label, and spans the official/local
  boundary without duplicate days;
- Recovery follows Steps, historical dates show exact official targets, and
  locally derived dates show versioned predictions;
- the trend cards read Sleep, Duration, Steps, Recovery, RHR, and HRV in that
  order, while hidden summary metrics remain collected and stored;
- selecting Week, Month, Year, and All never lets the line or endpoint escape
  the plot; range changes morph shape-preserving curves over one fixed set of
  horizontal anchors while their domains animate in lockstep;
- the installed sidecar hash matches `sourceDatabaseSHA256` in the official
  projection;
- a pre-migration SQLite snapshot exists and passes `PRAGMA quick_check`;
- raw-packet counts continue to grow while the phone is locked; and
- the collector reconnects and resumes after app relaunch.

Do not declare migration complete until the source archive, projection, app
database, installed UI, and live continuation all agree.

## Improvement discipline and contributor handoff

Maintain this project as a reproducible system, not a chronological diary.
Someone new should be able to determine the current contract, rebuild every
projection, understand what has and has not been validated, and continue an
experiment without reading old conversations.

Keep each kind of knowledge in one durable place:

| Knowledge | Canonical owner | What to retain |
| --- | --- | --- |
| What WHOOP or the strap returned | Immutable source archive plus manifest | Exact bytes, request/packet identity, timestamps, status, hashes, coverage, and acquisition-tool version |
| What a payload means | Decoder source and focused fixtures/tests | Field offsets, units, wrap/reset rules, checksums, accepted/rejected examples, and known unknown bytes |
| What the phone stores | Current schema and migration tests | Constraints, indexes, provenance links, rebuild markers, backup boundary, and forward migration behavior |
| How a displayed metric is chosen | Current read/materialization code and this runbook | Source precedence, missing-data behavior, coverage gates, algorithm/model version, and UI abstraction |
| How a model was selected | Reproducible trainer, private fitted artifact, and concise model card/metrics | Feature contract, past-only cutoff rules, cohort/time bounds, folds, error distribution, baselines, confidence, and rejected alternatives that materially informed the design |
| What still needs evidence | Focused issue or validation checklist | Exact unanswered claim, required ground truth, acceptance threshold, and the retained source needed to answer it |

Do not preserve a stream-of-consciousness record of commands. Promote the
useful result of an investigation into the relevant owner: a fixture, parser
contract, schema migration, model evaluation, decision rule, troubleshooting
row, or open validation item. Preserve failed approaches only when they teach a
reusable boundary—for example, a feature family that worsened chronological
test error, a private endpoint with shorter retention, or whole-container copy
behavior that fails on protected iOS metadata.

For every decoder or derived metric change:

1. freeze the source cohort by manifest hash and coverage dates;
2. state the production feature contract using only signals available at the
   score's derivation time;
3. add fixtures for successful, missing, corrupt, wrap/reset, duplicate, and
   boundary cases;
4. compare the candidate with the shipped baseline on chronological unseen
   data, including median and tail error rather than only training fit;
5. record materially worse alternatives and why they were rejected;
6. bump the decoder, feature, algorithm, or model version when semantics
   change;
7. rebuild projections from immutable evidence instead of editing rows;
8. prove the independent Swift evaluator agrees with the trainer on golden
   inputs; and
9. perform a clean-clone test, a private Release build, and an in-place device
   migration with pre/post integrity checks.

A new person's minimum handoff packet is therefore small but complete: this
runbook, the Git repository, their own private source manifests/archives, the
current schema version, fitted private models and model cards, the last verified
device backup, and the unresolved validation checklist. It must not require the
original account holder's identifiers, credentials, tokens, private health
records, filesystem paths, or undocumented oral knowledge.

When WHOOP, firmware, iOS, or the local model changes, update the current
contract in place and keep old evidence addressable by hash/version. Do not
silently rewrite historical predictions under new semantics, delete unmodeled
fields, or let a dashboard choice decide what data survives.

## Known limits and non-recoverable data

- The public Developer API does not provide continuous heart-rate data. WHOOP
  documents BLE heart-rate broadcast as the alternative, but that is not an
  historical backfill.
- The official account export and public API expose only their documented
  fields. A metric visible in the app may be absent or have shorter retention.
- The private-iOS API is unsupported. It may disappear, require new official
  app behavior, return different fields, or refuse automated access.
- Historical raw BLE packets, raw IMU, cadence, motion class, and local coverage
  cannot be recreated after the strap or official app has discarded them.
- A cumulative motion counter cannot honestly fill a day whose reset/wrap
  boundary and observation coverage were not captured.
- Missing, deleted, unscored, or never-recorded WHOOP days remain missing.
- Official Recovery, Sleep, Strain, and Steps algorithms are proprietary. A
  local model can be measured against retained targets but cannot claim exact
  parity, and performance can drift as physiology, firmware, or WHOOP's model
  changes.
- The reference model's validation numbers describe its one historical cohort.
  A different account needs its own chronological backtest and fitted model.
- Installing a build without its private seeds cannot enrich old history later
  unless those source archives still exist off-device.

The practical consequence is to archive early, keep exact bytes and checksums,
continue collecting locally, and treat every display metric as a replaceable
projection over preserved evidence.
