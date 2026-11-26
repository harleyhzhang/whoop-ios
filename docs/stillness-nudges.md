# Stillness nudges

Product scope: one brief triple buzz after a prolonged still stretch. The
nudge is complete after those three pulses. Movement re-arms the next still
stretch; a completed workout, step target or particular exercise is unnecessary.

Sleep suppression takes priority over delivering a reminder. Suppress during
known sleep, unresolved sleep/wake transitions, non-wear and stale or missing
input. A daytime clock window is an additional guard, not proof of wakefulness.
A transient `up` sample inside an unresolved night must not enable a nudge.

Sixty minutes and a 10:00–22:00 local window are starting candidates, not
validated stillness thresholds. The retrospective step-counter experiment
does not validate a motion-based stillness detector. Evaluate actual motion
and sleep-state inputs in receipt order; late history must not be treated as
information that was available before the decision.

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

## Current status

This document records the requested behavior. No runtime nudge, sensor change,
scheduled job or haptic command is enabled by this change. The motion-based
rule, physical triple pulse and locked-phone delivery remain to be validated.
