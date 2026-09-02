# WHOOP iOS

WHOOP iOS is an unofficial, native, offline-first personal iPhone client. It is
intended to operate a personally owned WHOOP 5 directly,
preserve the underlying data, and calculate transparent sleep and recovery
metrics locally without depending on a WHOOP membership.

## Product target

The app should eventually cover the complete personal loop:

1. Pair, reconnect, and maintain the WHOOP 5 Bluetooth session automatically.
2. Losslessly capture live and historical packets before decoding them.
3. Derive heart rate, R–R intervals, HRV, resting heart rate, sleep periods,
   sleep stages, disturbances, and supporting physiology with provenance.
4. Store a complete offline history on the phone and replicate it to a private
   backend without making the UI depend on that backend.
5. Show an interpretable, versioned Sleep Score plus the underlying measurements.

## Current state

- The SwiftUI dashboard and interaction design are installed on the paired iPhone.
- The app can reconnect to Harley's bonded WHOOP 5, establish its encrypted
  link, subscribe to all known live notification channels, and construct the
  reversible WHOOP 5 live-stream commands.
- The diagnostic path decodes standard Bluetooth heart-rate measurements and
  WHOOP 5 type-40 heart-rate/R–R frames.
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
  is the archived resting-heart-rate value. The dashboard shows missing data
  instead of extrapolating and keeps archive provenance out of the daily-use
  header.
- The top summary uses an untitled, borderless layout inspired by Apple
  Fitness: Sleep and Duration share the first row, while HRV, RHR, and Heart
  Rate share a compact three-column second row. It has no divider lines, uses
  compact metric icons, and gives all values stable semibold white typography
  under gray metric titles. Icons retain fixed metric colors; no phone-motion
  metrics or Motion & Fitness permission are part of this surface.
- Chart density is range-aware without altering the stored daily history or
  the exact current value: 1W and 1M use daily points, 3M uses three-day
  medians, 1Y uses weekly medians, and All widens adaptive median buckets from
  weekly toward monthly to stay near 40–60 plotted points.
- One-week and one-month charts retain compact start/midpoint/latest labels.
  Three-month, one-year, and all-history charts label every represented month
  without vertical month gridlines or tick marks; three months shows
  abbreviated months, while longer ranges use compact month initials with year
  markers at the start and each January.
- For 3M, 1Y, and All, charts overlay independent contrasting average levels.
  The history is divided backward from the latest day into adaptive equal-time
  windows—three levels for 3M and at most five for 1Y/All. Each unconnected
  horizontal segment shows its formatted mean above the line. The underlying
  colored trend remains visible at reduced opacity; pressing or scrubbing hides
  the levels and restores the normal trend.
- Aggregated trends keep their historical median buckets but anchor the final
  bucket to the exact latest observation, so the endpoint, dot, and current
  card value agree. Chart selection snaps to rendered points, and an explicit
  full-range x-domain prevents the plot width from changing while scrubbing.
- Trend lines and area fills use restrained monotone interpolation for slightly
  rounded corners without Catmull–Rom overshoot. Selection never splits or
  recomputes the trend: it overlays a translucent future region after the
  selected point, then adds the rule and dot, leaving line geometry, scales,
  and layout unchanged while scrubbing.
- Haptics follow a restrained interaction vocabulary: selection ticks occur
  only when the range or exact selected night changes; lightweight impacts
  accompany diagnostic navigation and rescanning; handshake initiation is
  firmer; and success/warning patterns are limited to visible handshake
  outcomes. Passive collection and background Bluetooth events stay silent.
- The dashboard diagnostic control uses the compact circular WHOOP mark plus a
  small plain connection-status dot, green only while the encrypted strap link
  is active and gray otherwise.
- The 2026-09-01 real-history build was installed in place and visibly launched
  on the paired iPhone; the dashboard rendered the imported history correctly.
- The generated seed remains in Harley's private data tree rather than the
  source tree. Local builds optionally copy the file selected by
  `WHOOP_HISTORY_SEED_PATH` (or the private local default) into the app bundle
  for first-launch import; the app contains no API client secret or refresh
  token. Clean clones build without the private seed and display missing data.
- Sustained worn live capture and foreground/background persistence work;
  longer disconnect, overnight, battery, historical-offload, sleep-inference,
  and backend tests remain.

## Immediate milestone

Run an overnight direct capture and validate gaps, battery impact, reconnect
behavior, and historical offload. Then create and validate a versioned local
sleep-window model so post-membership nights can replace the API-backed history
without inventing duration, stages, HRV, RHR, or Sleep Score values.

The protocol implementation uses independently implementable protocol facts.
NOOP is a valuable factual reference, but its PolyForm Noncommercial license
must be reviewed before copying implementation code or shipping beyond the
permitted personal/research use.

WHOOP is a trademark of WHOOP, Inc. This personal project is not affiliated
with or endorsed by WHOOP, Inc.
