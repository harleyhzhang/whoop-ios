# WHOOP account-export seeds

`Tools/make_account_export_seed.py` accepts the ZIP from WHOOP's account data
export. It produces the existing history/official-metrics JSON files and a
checksum-linked SQLite sidecar. Keep the input and output outside this repository.

```sh
uv run python Tools/make_account_export_seed.py /private/path/export.zip \
  --output /private/path/new-app-seeds \
  --captured-at '2026-01-03T12:00:00Z'
```

Use the actual export capture timestamp, with a timezone. Existing output
folders are refused. Pass the resulting folder as `WHOOP_PRIVATE_SEED_ROOT`
when building a simulator app, and launch with `WHOOP_DEMO_DATA=0`.
This does not authorize a physical-phone installation; follow `docs/operator.md`.

The importer treats CSV times as local wall times with the recorded cycle UTC
offset, joins main sleeps to cycles by cycle start plus offset, and verifies their
shared values. Sleep/recovery dates use local wake dates. Cycles lacking sleep use
local cycle-start dates for official strain only. When dates collide, a main
sleep takes precedence, then the latest wake/start instant. Equal-time ambiguity
fails the import. `import-report.json` records each selected and unselected CSV
row. Metrics from different cycles are never mixed, and missing values stay null.
CSV exports have no sleep/cycle IDs, so these identifiers are left absent.

The sidecar's `export_file` table preserves the exact ZIP, CSVs and manifest with
SHA-256 hashes and zlib compression. `export_row` preserves every parsed CSV row,
including naps, workouts, journals and cycles not selected for the daily display.
This sidecar is an account export, not an HTTP response archive; the manifest and
history use `whoop_account_export` provenance. Dashboard official scores use the
generic `whoop_official` label because official data can come from either format.

Seeding imports existing WHOOP scores; it does not train models. The account
export supplies neither steps nor continuous heart rate. The current dashboard
requires steps, sleep and recovery on the same day to publish current headlines;
those can remain blank after a successful import. Raw naps/workouts/journals are
preserved but do not gain new UI screens. Recovery training requires adapting the
API-oriented trainer to these retained CSV fields. Full-day strain calibration
also needs aligned continuous heart-rate history.


## Browse recorded days

Tap the date at the top of the dashboard to open the read-only history browser.
Its date button opens a calendar; arrows move one calendar day at a time, including
dates without measurements. A metric opens 7/30/90-day daily bars and a selectable
date list. HRV is included in this browser. Missing steps and other measurements
stay missing; no values are carried over from neighboring dates.

Tap **Strain** to start or add an activity (Running and Weightlifting are pinned;
search for others such as Pickleball). Activities are never auto-detected. While
one runs, a live card on the dashboard opens the live screen (current, average
and max heart rate from the strap). To stop, open it and tap **End**, then
**Save** or **Discard**. Tap **Sleep** to add a past sleep or nap; sleep itself
is detected from the strap, so it cannot be started manually. Manual entries live
in a local `manual-log.json`, separate from imported data. No strain score is
computed for them, and they never feed the sleep gates. In the simulator, launch
with `WHOOP_MOCK_HEART_RATE=1` to feed the live screen a synthetic heart rate.

## Activity backfill

`Tools/make_activity_seed.py` reads the same export ZIP and writes
`whoop-activities.json` (workouts with strain and heart-rate summaries, main
sleeps and naps). Each workout also carries the export's "HR Zone 1-5 %"
columns as `zonePercents`, which the activity detail shows as a zone breakdown.
Write it to the private seed folder; `embed_private_assets.sh`
bundles it when present (or from `WHOOP_ACTIVITIES_PATH`). The app shows these
read-only next to manual entries. The export has no steps, so steps cannot be
backfilled.

```sh
uv run python Tools/make_activity_seed.py /private/path/export.zip \
  --output /private/path/app-seeds/whoop-activities.json
```

This browser reads stored history independently of the current-day summary.
It does not change sleep publication/completeness gates, edit records, or trigger
model training. The main dashboard's incomplete-day headlines can still be blank.
