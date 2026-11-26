# Stillness nudges

Product scope: one brief triple buzz after a prolonged still stretch. The
nudge is complete after those three pulses. Movement re-arms the next still
stretch; a completed workout, step target or particular exercise is unnecessary.

Sleep suppression takes priority over delivering a reminder. Suppress during
known sleep, unresolved sleep/wake transitions, non-wear and stale or missing
input. A daytime clock window is an additional guard, not proof of wakefulness.
A transient `up` sample inside an unresolved night must not enable a nudge.

The initial rule uses sixty minutes and a 10:00–22:00 local window. Only
minutes with at least 45 explicitly awake samples count. Twenty one-second
R18 motion summaries at or above 0.3 in a minute reset the still stretch;
this raw-summary threshold is a heuristic, not calibrated exercise or posture
recognition. Movement does not have to produce steps.

Any asleep sample suppresses nudges for ninety minutes. Ambiguous `up` and
alternate-awake minutes do not earn still time. A current explicitly awake
sample must be no older than five minutes, with a live heart-rate receipt
within sixty seconds and no explicit off-wrist indication. The app's sleep
state separately vetoes delivery. Cold starts and reconnects start a new
observation interval; preconnection backfill can only suppress sleep, not
earn an immediate reminder.

## Implementation constraints

- Keep detection and sleep gating pure and deterministic. Consume bounded,
  persisted observations from the existing collector; do not start a separate
  high-frequency sensor-recording session or change historical ACK behavior.
- Recheck connection, non-wear, input age and sleep status immediately before
  any haptic write. No delayed playback of a missed nudge after reconnecting.
- Generate one finite, short triple pattern on the strap. Do not implement it
  as three iPhone timers or use a repeating wake alarm.
- WHOOP 5 notification haptics use command 19 with a 12-byte revision-1 body.
  Legacy WHOOP 4 preset command 79 is not the WHOOP 5 path. See the upstream
  [haptics reference](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_ALARMS.md#whoop-5mg-alarms).
  An accepted command does not prove three short physical pulses; verify the
  waveform and correlated completion on the actual device.

## Verification and limits

The detector runs after successful persistence, and only a coherent completed
historical offload can request a nudge. All inputs are interpreted in packet
receipt order. Backfilled samples are never treated as current wake evidence.
The decision runs from Bluetooth events while backgrounded; there is no new
sensor mode, periodic iPhone timer, exercise UI or cloud dependency.

The command is WHOOP 5 revision 1 with three waveform-1 short clicks separated
by 100 ms waits, zero effect-loop control and zero overall repeats. A request
is not retried as a repeating alarm. Correlated completion is recorded in
the bounded lifecycle log. Physical feel still depends on the strap firmware
and motor; an acknowledgement is not wearer confirmation.

Deterministic tests cover sleep, naps, transient wake states, non-wear, stale
and future history, gaps, duplicate/out-of-order samples, reconnects, single
delivery, movement rearming, the transport decoder and finite command shape.
A bounded private replay uses actual motion, original receipt order and
completed-offload times; raw health data stays outside the repository. The
sleep labels are device-derived rather than independent ground truth, and
lying awake is unlabelled. Suppression reduces interruptions but cannot
guarantee that every future sleep will be identified correctly.
