export const phoneReplicaChunkSize = 8 * 1024 * 1024;
export const maximumPhoneReplicaChunkCount = 512;
export const maximumPhoneReplicaStorageBytes = 950_000_000;
export const phoneReplicaStagingGraceMilliseconds = 24 * 60 * 60 * 1_000;

export const maximumPhoneReplicaCiphertextBytes =
  phoneReplicaChunkSize + Math.floor(phoneReplicaChunkSize / 1_000) + 128 + 28;

const digestPattern = /^[0-9a-f]{64}$/;

export type PhoneReplicaManifest = {
  chunkIds: string[];
  chunkPlainBytes: number[];
  chunkSize: number;
  createdAt: number;
  schemaVersion: number;
  sourceBytes: number;
  sourceFingerprint: string;
};

export type PhoneReplicaSnapshotIdentity = {
  schemaVersion: number;
  sourceBytes: number;
  sourceFingerprint: string;
};

type PhoneReplicaChunkStorage = {
  chunkId: string;
  encryptedBytes: number;
};

function positiveSafeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

export function validateChunkIds(chunkIds: string[]): void {
  if (
    chunkIds.length === 0 ||
    chunkIds.length > maximumPhoneReplicaChunkCount ||
    new Set(chunkIds).size !== chunkIds.length ||
    chunkIds.some((chunkId) => !digestPattern.test(chunkId))
  ) {
    throw new Error("invalid_chunk_ids");
  }
}

export function validateChunkCommit(args: {
  chunkId: string;
  createdAt: number;
  encryptedBytes: number;
  storedBytes: number;
}): void {
  if (
    !digestPattern.test(args.chunkId) ||
    !positiveSafeInteger(args.createdAt) ||
    !positiveSafeInteger(args.encryptedBytes) ||
    args.encryptedBytes > maximumPhoneReplicaCiphertextBytes ||
    args.encryptedBytes !== args.storedBytes
  ) {
    throw new Error("invalid_chunk_metadata");
  }
}

export function validateSnapshotManifest(args: PhoneReplicaManifest): void {
  validateChunkIds(args.chunkIds);
  if (
    args.chunkIds.length !== args.chunkPlainBytes.length ||
    args.chunkSize !== phoneReplicaChunkSize ||
    !positiveSafeInteger(args.createdAt) ||
    !positiveSafeInteger(args.schemaVersion) ||
    !positiveSafeInteger(args.sourceBytes) ||
    !digestPattern.test(args.sourceFingerprint)
  ) {
    throw new Error("invalid_snapshot_manifest");
  }

  const expectedChunkCount = Math.ceil(args.sourceBytes / args.chunkSize);
  if (args.chunkIds.length !== expectedChunkCount) {
    throw new Error("invalid_snapshot_manifest");
  }

  let describedBytes = 0;
  for (const [index, plainBytes] of args.chunkPlainBytes.entries()) {
    const isFinal = index === args.chunkPlainBytes.length - 1;
    if (
      !positiveSafeInteger(plainBytes) ||
      plainBytes > args.chunkSize ||
      (!isFinal && plainBytes !== args.chunkSize)
    ) {
      throw new Error("invalid_snapshot_manifest");
    }
    describedBytes += plainBytes;
  }
  if (
    !Number.isSafeInteger(describedBytes) ||
    describedBytes !== args.sourceBytes
  ) {
    throw new Error("invalid_snapshot_manifest");
  }
}

export function validateSnapshotProgress(
  candidate: PhoneReplicaSnapshotIdentity,
  latest: PhoneReplicaSnapshotIdentity | null,
  seedOnly = false,
): void {
  if (
    latest === null ||
    candidate.sourceFingerprint === latest.sourceFingerprint
  ) {
    return;
  }
  if (seedOnly) {
    throw new Error("snapshot_seed_requires_empty_replica");
  }
  if (candidate.schemaVersion < latest.schemaVersion) {
    throw new Error("snapshot_regresses_source");
  }
}

export function assertPhoneReplicaUploadBudget(
  storedBytes: number,
  inventoryTruncated: boolean,
): void {
  if (
    inventoryTruncated ||
    !Number.isSafeInteger(storedBytes) ||
    storedBytes < 0 ||
    storedBytes + maximumPhoneReplicaCiphertextBytes >
      maximumPhoneReplicaStorageBytes
  ) {
    throw new Error("phone_replica_storage_budget");
  }
}

export function isStaleReplicaArtifact(
  serverCreatedAt: number,
  now: number,
): boolean {
  return serverCreatedAt <= now - phoneReplicaStagingGraceMilliseconds;
}

export function summarizeChunkStorage(
  chunks: PhoneReplicaChunkStorage[],
  retainedChunkIds: ReadonlySet<string>,
): {
  retainedBytes: number;
  retainedCount: number;
  stagedBytes: number;
  stagedCount: number;
} {
  let retainedBytes = 0;
  let retainedCount = 0;
  let stagedBytes = 0;
  let stagedCount = 0;
  for (const chunk of chunks) {
    if (retainedChunkIds.has(chunk.chunkId)) {
      retainedBytes += chunk.encryptedBytes;
      retainedCount += 1;
    } else {
      stagedBytes += chunk.encryptedBytes;
      stagedCount += 1;
    }
  }
  return { retainedBytes, retainedCount, stagedBytes, stagedCount };
}
