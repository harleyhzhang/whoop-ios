import assert from "node:assert/strict";
import test from "node:test";

import {
  assertPhoneReplicaUploadBudget,
  isStaleReplicaArtifact,
  maximumPhoneReplicaCiphertextBytes,
  maximumPhoneReplicaStorageBytes,
  phoneReplicaChunkSize,
  phoneReplicaStagingGraceMilliseconds,
  summarizeChunkStorage,
  validateChunkCommit,
  validateChunkIds,
  validateSnapshotManifest,
  validateSnapshotProgress,
} from "../convex/phoneReplicaPolicy.ts";

const digest = (value: string): string => value.repeat(64);

function validManifest() {
  return {
    chunkIds: [digest("a"), digest("b")],
    chunkPlainBytes: [phoneReplicaChunkSize, 17],
    chunkSize: phoneReplicaChunkSize,
    createdAt: 2_000_000_000_000,
    schemaVersion: 10,
    sourceBytes: phoneReplicaChunkSize + 17,
    sourceFingerprint: digest("c"),
  };
}

test("accepts a complete position-bound snapshot manifest", () => {
  assert.doesNotThrow(() => validateSnapshotManifest(validManifest()));
});

test("rejects malformed, duplicate, and non-digest chunk identifiers", () => {
  assert.throws(() => validateChunkIds([]), /invalid_chunk_ids/);
  assert.throws(
    () => validateChunkIds([digest("a"), digest("a")]),
    /invalid_chunk_ids/,
  );
  assert.throws(
    () => validateChunkIds(["not-a-keyed-digest"]),
    /invalid_chunk_ids/,
  );
});

test("rejects manifests whose chunk geometry cannot reconstruct source bytes", () => {
  const cases = [
    { ...validManifest(), chunkSize: 1024 },
    { ...validManifest(), chunkPlainBytes: [phoneReplicaChunkSize - 1, 18] },
    { ...validManifest(), chunkPlainBytes: [phoneReplicaChunkSize, 18] },
    { ...validManifest(), sourceBytes: phoneReplicaChunkSize * 3 },
    { ...validManifest(), sourceFingerprint: "public-plaintext-hash" },
  ];
  for (const manifest of cases) {
    assert.throws(
      () => validateSnapshotManifest(manifest),
      /invalid_snapshot_manifest/,
    );
  }
});

test("requires authoritative storage size for committed ciphertext", () => {
  assert.doesNotThrow(() =>
    validateChunkCommit({
      chunkId: digest("d"),
      createdAt: 2_000_000_000_000,
      encryptedBytes: 1234,
      storedBytes: 1234,
    }),
  );
  assert.throws(
    () =>
      validateChunkCommit({
        chunkId: digest("d"),
        createdAt: 2_000_000_000_000,
        encryptedBytes: 1234,
        storedBytes: 1235,
      }),
    /invalid_chunk_metadata/,
  );
  assert.throws(
    () =>
      validateChunkCommit({
        chunkId: digest("d"),
        createdAt: 2_000_000_000_000,
        encryptedBytes: maximumPhoneReplicaCiphertextBytes + 1,
        storedBytes: maximumPhoneReplicaCiphertextBytes + 1,
      }),
    /invalid_chunk_metadata/,
  );
});

test("rejects source regression without trusting the client clock", () => {
  const latest = {
    schemaVersion: 10,
    sourceBytes: 100,
    sourceFingerprint: digest("a"),
  };
  assert.doesNotThrow(() => validateSnapshotProgress({ ...latest }, latest));
  assert.doesNotThrow(() =>
    validateSnapshotProgress(
      { schemaVersion: 10, sourceBytes: 101, sourceFingerprint: digest("b") },
      latest,
    ),
  );
  assert.doesNotThrow(() =>
    validateSnapshotProgress(
      { schemaVersion: 11, sourceBytes: 50, sourceFingerprint: digest("b") },
      latest,
    ),
  );
  assert.doesNotThrow(() =>
    validateSnapshotProgress(
      { schemaVersion: 10, sourceBytes: 50, sourceFingerprint: digest("b") },
      latest,
    ),
  );
  assert.throws(
    () =>
      validateSnapshotProgress(
        { schemaVersion: 9, sourceBytes: 200, sourceFingerprint: digest("b") },
        latest,
      ),
    /snapshot_regresses_source/,
  );
  assert.throws(
    () =>
      validateSnapshotProgress(
        { schemaVersion: 10, sourceBytes: 101, sourceFingerprint: digest("b") },
        latest,
        true,
      ),
    /snapshot_seed_requires_empty_replica/,
  );
});

test("reserves enough storage for one maximum-size encrypted chunk", () => {
  assert.doesNotThrow(() =>
    assertPhoneReplicaUploadBudget(
      maximumPhoneReplicaStorageBytes - maximumPhoneReplicaCiphertextBytes,
      false,
    ),
  );
  assert.throws(
    () =>
      assertPhoneReplicaUploadBudget(
        maximumPhoneReplicaStorageBytes -
          maximumPhoneReplicaCiphertextBytes +
          1,
        false,
      ),
    /phone_replica_storage_budget/,
  );
  assert.throws(
    () => assertPhoneReplicaUploadBudget(0, true),
    /phone_replica_storage_budget/,
  );
});

test("uses a full-day grace period before classifying staging as stale", () => {
  const now = 2_000_000_000_000;
  // The timestamp is Convex's server-owned document creation time, so client
  // clock skew cannot accelerate or prevent cleanup.
  assert.equal(
    isStaleReplicaArtifact(now - phoneReplicaStagingGraceMilliseconds + 1, now),
    false,
  );
  assert.equal(
    isStaleReplicaArtifact(now - phoneReplicaStagingGraceMilliseconds, now),
    true,
  );
});

test("separates retained chunks from interrupted staging", () => {
  assert.deepEqual(
    summarizeChunkStorage(
      [
        { chunkId: digest("a"), encryptedBytes: 10 },
        { chunkId: digest("b"), encryptedBytes: 20 },
      ],
      new Set([digest("a")]),
    ),
    { retainedBytes: 10, retainedCount: 1, stagedBytes: 20, stagedCount: 1 },
  );
});
