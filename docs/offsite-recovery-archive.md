# Offsite recovery archive

The complete app database and immutable official-response sidecar are preserved
without competing with the direct phone replica for Convex file storage. The
archive is zstd-compressed, encrypted with the existing age identity, and must
complete a byte-identical offsite round trip before the legacy Convex copy can
be retired.

## Export and verify locally

Choose a private path outside Git. By default the tool selects the exact
`lastVerifiedBackup` from the private install state.

```bash
uv run --frozen python Tools/convex_replica.py export \
  /private/path/whoop-archive-<source-prefix>.tar.zst.age
```

The command fails closed if either SQLite file is missing or invalid, then
decrypts and verifies every recorded byte count, SHA-256, schema version, and
SQLite `quick_check` before returning.

## Prove the offsite copy

Upload only the `.age` ciphertext. Download that object into a separate local
path, then verify the round trip and record a non-secret receipt:

```bash
uv run --frozen python Tools/convex_replica.py verify-offsite \
  /private/path/whoop-archive-<source-prefix>.tar.zst.age \
  /private/path/downloaded-whoop-archive.tar.zst.age \
  --provider google-drive \
  --remote-path 'WHOOP Encrypted Backups/whoop-archive-<source-prefix>.tar.zst.age' \
  --receipt /private/path/whoop-archive-<source-prefix>.offsite.json
```

The downloaded ciphertext must match byte for byte and must decrypt into both
hash-valid SQLite files. Keep the receipt beside the local recovery inventory;
it contains hashes and a remote pointer, never health rows or credentials.

## Retire the legacy Convex archive

Deploy the reviewed backend first. Then run:

```bash
uv run --frozen python Tools/convex_replica.py retire-convex \
  /private/path/whoop-archive-<source-prefix>.tar.zst.age \
  --receipt /private/path/whoop-archive-<source-prefix>.offsite.json
```

Retirement is deliberately destructive and guarded on both sides. The client
revalidates the archive and receipt, requires the offsite source hash to match
the exact Convex archive, and requires one newer phone snapshot with a
nondecreasing schema and source size. The server pins the archive id,
ciphertext hash, and phone fingerprint in the deleting transaction. The client
then proves the archive is absent and the phone fingerprint is unchanged.

Restore the cold copy with:

```bash
uv run --frozen python Tools/convex_replica.py restore-file \
  /private/path/whoop-archive-<source-prefix>.tar.zst.age \
  /empty/private/restore-directory
```
