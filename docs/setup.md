# Setup

From a fresh clone to the app running on your phone with your history.

## 1. Tools

You need a Mac, Xcode (exact version in `Tools/toolchain.json`), an Apple
Developer account (a free account works, but installs expire after 7 days), an
iPhone, and a WHOOP 5 you own.

```bash
brew bundle --file Brewfile
Tools/doctor.sh --toolchain-only
Tools/install_git_hooks.sh
```

## 2. Sign with your own team

Copy the example config and fill in your bundle ID and Team ID
(Xcode → Settings → Accounts):

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
xcodegen generate
```

`Config/Local.xcconfig` is gitignored. The tools also read
`~/.config/whoop/local.xcconfig`, which is handy across worktrees. Optional keys:
`WHOOP_DATA_ROOT`, `WHOOP_CONVEX_SITE_URL`, and the `*_KEYCHAIN_SERVICE` names.

## 3. Try it in the simulator

Run the `Whoop` scheme. To see a populated dashboard without a strap, add
`WHOOP_DEMO_DATA=1` under *Edit Scheme → Run → Arguments → Environment*.
Demo data only works in Debug simulator builds.

## 4. Install on your phone

1. Turn on Developer Mode (Settings → Privacy & Security).
2. Pick your phone as the run destination in Xcode and press Run.
3. If prompted, trust your developer certificate
   (Settings → General → VPN & Device Management).
4. Open the app, allow Bluetooth, and wear the strap. Quit the official WHOOP
   app first; only one app can hold the connection.

Collection starts immediately. Sleep and recovery appear after your first full
night.

## 5. Import your history (optional)

Without this step, charts start on install day. Pick any of these:

| Source | Effort | What you get |
| --- | --- | --- |
| Account export | Request in the WHOOP app; arrives by email | CSV snapshot |
| Developer API | Create a client at developer.whoop.com | Sleeps, recoveries, cycles |
| Official-app API | Log in with your WHOOP account | Adds historical steps and trends |

Keep everything outside the repo:

```bash
export WHOOP_DATA_ROOT=~/whoop-data
mkdir -p -m 700 "$WHOOP_DATA_ROOT"
```

**Developer API.** Create a client with a `http://localhost` redirect URI and
the scopes `offline read:recovery read:cycles read:workout read:sleep
read:profile read:body_measurement`. Put the client ID and secret in a
`chmod 600` env file, then:

```bash
archive/whoop_archive.py --config ~/.config/whoop/env authorize
archive/whoop_archive.py --config ~/.config/whoop/env archive
```

**Official-app API** (unsupported, read-only, may break):

```bash
archive/whoop_private_archive.mjs --start 2025-01-01 --end 2025-12-31
```

Tokens live in the macOS Keychain, never in the archive.

**Build the seed the app imports:**

```bash
uv run --frozen python Tools/make_history_seed.py \
  "$WHOOP_DATA_ROOT/api-<timestamp>" "$WHOOP_DATA_ROOT/app-seeds/whoop-history.json"
```

Rebuild and reinstall. The build embeds the seed and the app imports it on
first launch. For official-app metrics, recovery models, and verification, see
the [data migration guide](whoop-data-migration.md).

## 6. Backups (optional)

The app can push an encrypted replica to your own Convex deployment. See
[offsite recovery](offsite-recovery-archive.md). The app works fully without it.

## Troubleshooting

- **No strap found:** quit the official WHOOP app, toggle Bluetooth, keep the
  strap on your wrist.
- **App won't open after a week:** free developer accounts expire installs
  after 7 days. Reinstall from Xcode.
- **Signing errors:** recheck `Config/Local.xcconfig`, then rerun `xcodegen generate`.
