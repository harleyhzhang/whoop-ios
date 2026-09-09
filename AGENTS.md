# Sleep iOS app

- Product north star: replace the official WHOOP app for Harley's personally
  owned WHOOP 5. The finished app directly manages the strap, preserves live
  and historical data locally, and derives transparent versioned sleep,
  recovery, and strain metrics without a membership or official-app dependency.
- Treat compatibility probes as temporary diagnostics feeding the production
  collector, not as the product boundary.
- Build the product as a native SwiftUI iPhone application.
- Keep the app fully useful without a hosted service or memory connection.
- Preserve privacy: no credentials, signing assets, or real health exports in
  Git. Sample fixtures must be synthetic and clearly recognizable as such.
- Preserve unique raw packet evidence, but compact exact byte-for-byte BLE
  transport retries on the same characteristic instead of multiplying raw and
  decoded rows. A retry must still count as durably handled before any history
  acknowledgement is sent.
- Prefer Apple frameworks and focused dependencies. The future WHOOP protocol
  layer may reuse compatible NOOP packages after license and integration review.
- Verify UI changes by building for an iPhone simulator and, when requested,
  installing on Harley's paired development iPhone.
- Run `Tools/verify_local.sh` before merging code changes. Hosted iOS CI is a
  manual fallback only; do not trigger it unless local verification is blocked
  or Harley explicitly requests a hosted run.
- Do not add an app-side manual sync control for the hosted replica or for
  memory. Memory reads are initiated from the Mac side. The dashboard's Process
  control is not a sync button: it finalizes a night already collected on the
  phone, waiving only the wake-timing gates and never the evidence gates. If a
  strap-history offload is in flight, Process must wait for its durable
  HISTORY_COMPLETE marker; it must never finalize the currently received prefix.
