import { v } from "convex/values";

import { internalMutation, internalQuery } from "./_generated/server";
import {
  assertPhoneReplicaUploadBudget,
  isStaleReplicaArtifact,
  maximumPhoneReplicaChunkCount,
  summarizeChunkStorage,
  validateChunkCommit,
  validateChunkIds,
  validateSnapshotManifest,
  validateSnapshotProgress,
} from "./phoneReplicaPolicy";

// The independent full archive lives offsite. Convex retains one complete
// direct snapshot and only the chunks referenced by that snapshot.
const retainedSnapshotCount = 1;
const storageInventoryLimit = maximumPhoneReplicaChunkCount * 4;

export const missingChunks = internalMutation({
  args: { chunkIds: v.array(v.string()) },
  returns: v.array(v.string()),
  handler: async (ctx, args) => {
    validateChunkIds(args.chunkIds);
    const now = Date.now();
    const latest = await ctx.db
      .query("phoneReplicaSnapshots")
      .order("desc")
      .first();
    const retainedChunkIds = new Set(latest?.chunkIds ?? []);
    const archives = await ctx.db.query("replicaArchives").collect();
    let chunks = await ctx.db.query("phoneReplicaChunks").collect();
    for (const chunk of chunks) {
      if (
        !retainedChunkIds.has(chunk.chunkId) &&
        isStaleReplicaArtifact(chunk._creationTime, now)
      ) {
        await ctx.storage.delete(chunk.storageId);
        await ctx.db.delete(chunk._id);
      }
    }
    chunks = chunks.filter(
      (chunk) =>
        retainedChunkIds.has(chunk.chunkId) ||
        !isStaleReplicaArtifact(chunk._creationTime, now),
    );

    const storageInventory = await ctx.db.system
      .query("_storage")
      .take(storageInventoryLimit + 1);
    if (storageInventory.length <= storageInventoryLimit) {
      const liveStorageIds = new Set([
        ...chunks.map((chunk) => chunk.storageId),
        ...archives.map((archive) => archive.storageId),
      ]);
      for (const file of storageInventory) {
        if (
          !liveStorageIds.has(file._id) &&
          isStaleReplicaArtifact(file._creationTime, now)
        ) {
          await ctx.storage.delete(file._id);
        }
      }
    }

    const present = new Set(chunks.map((chunk) => chunk.chunkId));
    return args.chunkIds.filter((chunkId) => !present.has(chunkId));
  },
});

export const generateUploadUrl = internalMutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => {
    const storageInventory = await ctx.db.system
      .query("_storage")
      .take(storageInventoryLimit + 1);
    const inventoryTruncated = storageInventory.length > storageInventoryLimit;
    const storedBytes = storageInventory
      .slice(0, storageInventoryLimit)
      .reduce((total, file) => total + file.size, 0);
    assertPhoneReplicaUploadBudget(storedBytes, inventoryTruncated);
    return await ctx.storage.generateUploadUrl();
  },
});

export const commitChunk = internalMutation({
  args: {
    chunkId: v.string(),
    createdAt: v.number(),
    encryptedBytes: v.number(),
    storageId: v.id("_storage"),
  },
  returns: v.object({ reused: v.boolean() }),
  handler: async (ctx, args) => {
    const stored = await ctx.db.system.get("_storage", args.storageId);
    if (stored === null) {
      throw new Error("missing_storage_object");
    }
    validateChunkCommit({
      chunkId: args.chunkId,
      createdAt: args.createdAt,
      encryptedBytes: args.encryptedBytes,
      storedBytes: stored.size,
    });
    const existing = await ctx.db
      .query("phoneReplicaChunks")
      .withIndex("by_chunk_id", (query) => query.eq("chunkId", args.chunkId))
      .unique();
    if (existing !== null) {
      if (existing.storageId !== args.storageId) {
        await ctx.storage.delete(args.storageId);
      }
      return { reused: true };
    }
    await ctx.db.insert("phoneReplicaChunks", args);
    return { reused: false };
  },
});

export const commitSnapshot = internalMutation({
  args: {
    chunkIds: v.array(v.string()),
    chunkPlainBytes: v.array(v.number()),
    chunkSize: v.number(),
    createdAt: v.number(),
    schemaVersion: v.number(),
    seedOnly: v.optional(v.boolean()),
    sourceBytes: v.number(),
    sourceFingerprint: v.string(),
  },
  returns: v.object({ reused: v.boolean() }),
  handler: async (ctx, args) => {
    const { seedOnly, ...manifest } = args;
    validateSnapshotManifest(manifest);

    const existing = await ctx.db
      .query("phoneReplicaSnapshots")
      .withIndex("by_source_fingerprint", (query) =>
        query.eq("sourceFingerprint", args.sourceFingerprint),
      )
      .unique();
    const reused = existing !== null;
    const latest = await ctx.db
      .query("phoneReplicaSnapshots")
      .order("desc")
      .first();
    validateSnapshotProgress(manifest, latest, seedOnly);

    const chunks = await ctx.db.query("phoneReplicaChunks").collect();
    const present = new Set(chunks.map((chunk) => chunk.chunkId));
    if (args.chunkIds.some((chunkId) => !present.has(chunkId))) {
      throw new Error("snapshot_references_missing_chunk");
    }

    if (!reused) {
      await ctx.db.insert("phoneReplicaSnapshots", {
        ...manifest,
        compression: "zlib",
        encryption: "aes-gcm-v1",
        format: 1,
      });
    }
    const snapshots = await ctx.db
      .query("phoneReplicaSnapshots")
      .order("desc")
      .collect();
    const retained = snapshots.slice(0, retainedSnapshotCount);
    for (const stale of snapshots.slice(retainedSnapshotCount)) {
      await ctx.db.delete(stale._id);
    }

    const referenced = new Set(
      retained.flatMap((snapshot) => snapshot.chunkIds),
    );
    for (const chunk of chunks) {
      if (!referenced.has(chunk.chunkId)) {
        await ctx.storage.delete(chunk.storageId);
        await ctx.db.delete(chunk._id);
      }
    }
    return { reused };
  },
});

export const latestSnapshot = internalQuery({
  args: {},
  handler: async (ctx) =>
    await ctx.db.query("phoneReplicaSnapshots").order("desc").first(),
});

export const chunk = internalQuery({
  args: { chunkId: v.string() },
  handler: async (ctx, args) =>
    await ctx.db
      .query("phoneReplicaChunks")
      .withIndex("by_chunk_id", (query) => query.eq("chunkId", args.chunkId))
      .unique(),
});

export const status = internalQuery({
  args: {},
  handler: async (ctx) => {
    const snapshots = await ctx.db
      .query("phoneReplicaSnapshots")
      .order("desc")
      .take(retainedSnapshotCount);
    const chunks = await ctx.db.query("phoneReplicaChunks").collect();
    const archives = await ctx.db.query("replicaArchives").collect();
    const storageInventory = await ctx.db.system
      .query("_storage")
      .take(storageInventoryLimit + 1);
    const storageInventoryTruncated =
      storageInventory.length > storageInventoryLimit;
    const storedFiles = storageInventory.slice(0, storageInventoryLimit);
    const liveStorageIds = new Set([
      ...chunks.map((chunk) => chunk.storageId),
      ...archives.map((archive) => archive.storageId),
    ]);
    const orphanedFiles = storedFiles.filter(
      (file) => !liveStorageIds.has(file._id),
    );
    const retainedChunkIds = new Set(
      snapshots.flatMap((snapshot) => snapshot.chunkIds),
    );
    const chunkStorage = summarizeChunkStorage(chunks, retainedChunkIds);
    return {
      chunkCount: chunkStorage.retainedCount,
      encryptedBytes: chunkStorage.retainedBytes,
      orphanedStorageBytes: orphanedFiles.reduce(
        (total, file) => total + file.size,
        0,
      ),
      orphanedStorageCount: orphanedFiles.length,
      snapshots,
      stagedChunkBytes: chunkStorage.stagedBytes,
      stagedChunkCount: chunkStorage.stagedCount,
      storageBytes: storedFiles.reduce((total, file) => total + file.size, 0),
      storageInventoryTruncated,
      storageObjectCount: storedFiles.length,
    };
  },
});
