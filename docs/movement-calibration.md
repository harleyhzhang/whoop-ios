# Brief movement calibration

The current experimental Strain model uses heart rate, step counters and sleep
state. It has no validated accelerometer/gyroscope lifting model. This capture
path collects evidence for that repair; recording does not change Strain or
claim WHOOP-equivalent muscular load.

## Record a labeled sample

1. Long-press the Strain card and choose **Record movement calibration**.
2. Choose **Lifting**, **Walking**, or **Rest**, then the automatic stop time.
   For lifting, enter the actual exercise, reps and weight in the notes.
3. Keep WHOOP worn and the recording screen open. Start just before the activity,
   then stop when finished. Wait for **Recording saved · sensors stopped**.

Start with one representative lifting set including its rest interval, plus
one minute each of ordinary walking and seated rest. These are initial labeled
examples, not sufficient evidence of general accuracy. Repeat only where the
first recordings expose a specific missing distinction. Session times, activity
labels and actual exercise/reps/load are required to evaluate lifting detection
and any load estimate; daily gym checkmarks cannot identify individual sets.

The app waits for the existing history offload to finish before starting. Raw
packet persistence continues throughout. Leaving the screen, backgrounding,
loss of the connection, failed persistence, missing sensors or a stalled stream
ends collection. A read-only command-147 clock check precedes sensor writes;
an unsupported, invalid or slow clock reply prevents starting. Raw device times
remain unchanged; the label uses the measured offset and round-trip uncertainty.
No clock-setting command is sent. Capture never automatically resumes after reconnect.

## Bounds and cleanup

Sessions are limited to 10 minutes, 10 MiB of incoming packet bytes (plus the
bounded in-flight transport batch), and 1,200 distinct sensor-time buffers. The
local archive holds at most 32 sessions / 20 MiB and never silently deletes an
old recording. Raw frames use existing SQLite storage, retention and replica
policy; the session archive is included in canonical phone backups.

Only temporary commands are used: START_RAW_DATA 81 `[01]`, then live IMU 106
`[01,01]`; stopping always attempts STOP_RAW_DATA 82 `[01]` and 106 `[01,00]`.
No persistent IMU/optical saving policy or global gyro setting is changed.
A successful response is not proof of a live stream. Capture requires fresh,
CRC-valid R21 accel and gyro buffers; lack of either stops the probe within
30 seconds. Command timeouts are four seconds. Cleanup requires successful stop responses and at least three seconds without
fresh R21 traffic, with a bounded ten-second observation window. An explicit
unsupported start, with no observed R21 producer, establishes that the capture
did not enable it; both stop
controls are still attempted, but an unsupported optional feature does not
permanently defer ordinary history. Failure, timeout and unknown results never
supply that proof.

BLE notifications can split a frame or contain multiple frames. Capture-only
reassembly consumes already committed original notifications, keeps streams
separate by peripheral/characteristic, validates both CRCs and links source
notification hashes. It retains at most four 4 KiB stream buffers, clears them
on disconnect or gaps longer than two seconds and never changes raw rows or
ordinary metric decoding. Invalid partial notifications are never compacted as
whole-frame retries merely because an arbitrary continuation byte looks like a
packet type. Even a partial valid live-IMU header keeps cleanup
uncertain. Live producer traffic after completion reopens OFF-only cleanup.

After verified stopping, normal history can repair the latest recording for up
to ten minutes, including after relaunch. Only sensor times wholly inside the
clock-correlated labeled interval count; delayed arrival does not become a new
activity or restart sensors. Keep the app open briefly after stopping for its
normal history offload. The 1,200-buffer limit still applies. A missing clock
reference in an older recording does not authorize assigning delayed data a label.

The cleanup obligation is saved atomically before the first device command.
Interruption leaves it pending for the next connection to the same strap.
Background cleanup uses an iOS background task. A device-side timeout after a
process kill or lost Bluetooth link has **not** been established; the client
cannot guarantee firmware cleanup while disconnected. An unverified stop stays
visible and journaled rather than being reported as success.

R21 is roughly 1.2 kB per full buffer; accompanying optical traffic may increase
that substantially. Battery cost on the paired strap has not been measured.
There is no routine or all-day raw streaming.

## Evidence and export

The decoder accepts only the observed format-1 R21 shape (types 43/47, 1,244
bytes), with independent accel/gyro counts no larger than 100. It retains the
raw packet hash, device and receive timestamps, peripheral, configuration bytes,
activity label, notes, source commit and stop outcome. Duplicate sensor times,
stale history and clock-skewed packets do not increase captured coverage.
Other layouts remain raw evidence and are not interpreted as R21.

A verified standalone snapshot and `motion-calibration.json` can be exported
without changing either source:

```sh
uv run --frozen python Tools/motion_capture_report.py \
  /private/sleep-standalone.sqlite3 /private/motion-calibration.json \
  --session-id SESSION-UUID --output /private/new-motion-export.json
```

The exporter validates frame shape and both CRCs, reconstructs split frames and matches exact frame/source-notification hashes,
characteristic and peripheral, and preserves independent signed raw XYZ axes. It does not
invent per-sample timestamps, physical units, sample rate, exercise labels,
reps or load. Configuration, signal quality, sample cadence and actual device
start/stop behavior must be checked on the paired firmware before fitting or
promoting a replacement model. Keep private exports out of Git.

Protocol basis: the reference implementation's
[sensor layouts](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_SENSORS.md),
[raw-capture controls](https://github.com/ryanbr/noop/blob/main/docs/RAW_DATA_CAPTURE.md)
and [response correlation](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_TRANSPORT.md).
These observations are not a guarantee of identical behavior on every device.
