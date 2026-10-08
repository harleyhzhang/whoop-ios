# Operator runbook

Shipping, backup, and retention for an existing installation that holds real
data. New users should start with [setup](setup.md). The full verification
tiers live in the [migration runbook](whoop-data-migration.md#10-build-sign-install-and-preserve-migration-backups).

Set `WHOOP_DATA_ROOT` to your private data directory before running these tools.

The optional in-app cloud replica runs while the app is active. Keep the app
open long enough for a full replica when fresh offsite coverage is needed.
Backgrounding cancels that attempt without changing local data or the last
committed replica; a later active visit can retry. Strap collection and sleep
publication remain background operations and do not depend on cloud backup.

## Physical-phone shipping

From a clean worktree at the exact merged `origin/main` commit, run:

```bash
Tools/ship_phone.sh --commit "$(git rev-parse HEAD)"
```

This is the canonical build, signing, backup, in-place install, launch, and
verification path over Wi-Fi or USB, including migration installs. Keep the
paired phone reachable and unlocked; the verification tier controls backup and
integrity checks, not the connection transport.
`Tools/ship_phone.sh --plan --commit <merged-sha>` reports
the pending commit count and verification tier without requiring the phone, so
routine merges can ship as one intentional checkpoint. `Tools/doctor.sh --mode
migration` performs the strictest read-only preflight.
If shipping returns `needs-unlock` or `needs-verification`, run only the exact
`--resume` command it prints; never uninstall the app. See the
[migration runbook](whoop-data-migration.md#10-build-sign-install-and-preserve-migration-backups)
for the fail-closed verification tiers.

Device builds reuse `~/Library/Caches/whoop-ios/device-derived-data`. Verified
snapshots retain one standalone database plus required sidecars; automatic
manifest-driven retention keeps current rollback points, two newest snapshots,
and one snapshot per schema and recent month. Retired data stays recoverable for seven
days before a later successful shipping or maintenance run purges it. Run
`Tools/maintain_device_backups.sh` for a dry-run inventory or add `--apply
--adopt-legacy` to validate and compact old snapshots before retirement.
`--retire-unusable` may be added to quarantine only legacy directories that
failed that explicit adoption. This tool never manages canonical WHOOP
source/archive directories. `--apply --purge-now` permanently removes only
already-recorded quarantine entries and is reserved for an explicitly reviewed
cleanup after the retained restore points are revalidated.

Restore points created before the shipping pipeline live in the separate legacy
`app-backups` tree and require a cross-snapshot pass rather than per-directory
deletion. Run `Tools/consolidate_legacy_backups.sh` first as a dry run. With
`--apply`, it selects the fullest integrity-clean database for every schema not
already represented by a managed backup, creates a standalone normalized image,
checks exact preserved-table counts and hashes, and only then quarantines the
redundant folders. `--retire-unusable` includes malformed or empty legacy
folders after schema coverage succeeds; `--purge-now` removes only recorded
quarantine entries. Re-run `Tools/maintain_device_backups.sh` and review a clean
`invalid=0` inventory before an immediate purge.
