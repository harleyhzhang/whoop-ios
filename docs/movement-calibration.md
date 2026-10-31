# Retained movement calibration evidence

The experimental recording UI and sensor-start commands were retired October 31
at the user's request to finish from existing evidence without more experiments.
No lifting classifier or muscular-load number is promoted: walking and rest
controls establish motion capture, not a defensible lifting-load calibration.
Final local Strain is recorded cardiovascular exposure with missing HR zero.
Actual official scores keep precedence and their original source.

## Preservation and legacy cleanup

Existing `motion-calibration.json`, labels, notes, original timestamps, source
hashes and raw notification rows are retained. The app does not create new
sessions, repair old labels or add later buffers to those archives. Read-only
exports remain available. The archive remains bounded to its existing schema
limits (32 sessions, 1,200 buffers per session, 20 MiB) without deleting evidence.

A pending legacy recording recovers on the same strap using only STOP_RAW_DATA
82 `[01]` and live IMU OFF 106 `[01,00]`. No start, clock-setting, persistent
sensor policy or optical configuration is sent. Both stop attempts occur even
if one is rejected or times out. Cleanup requires accepted stops and three
seconds without live traffic, bounded by a ten-second observation window;
the prior explicit-unsupported/no-observed-producer exception is retained.
Unknown stops remain pending across backgrounding, disconnect and relaunch.
Normal history defers until cleanup finishes. Firmware timeout while disconnected
is not established. No new high-rate streaming is requested.

The existing R21 decoder/reassembler still accepts only CRC-valid format-1
1,244-byte buffers, with independent accel/gyro counts up to 100. Reassembly
uses already committed original notifications and preserves source hashes,
peripheral and characteristic. Even a partial live header invalidates a quiet
stop result. Streams are bounded and cleared on disconnect or long gaps. None
of these protocol observations validates exercise recognition, physical units,
per-sample timing, repetition count, external weight or a muscular-load score.

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
reps or load. The retained archive is evidence only; no further user experiment or model
promotion is pending. Keep private exports out of Git.

Protocol basis: the reference implementation's
[sensor layouts](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_SENSORS.md),
[raw-capture controls](https://github.com/ryanbr/noop/blob/main/docs/RAW_DATA_CAPTURE.md)
and [response correlation](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_TRANSPORT.md).
These observations are not a guarantee of identical behavior on every device.
