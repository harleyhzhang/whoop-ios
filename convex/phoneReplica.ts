import { v } from "convex/values";

import { internalMutation, internalQuery } from "./_generated/server";

const retainedSnapshotCount = 2;
const maximumChunkCount = 512;

export const missingChunks = internalQuery({
  args: { chunkIds: v.array(v.string()) },
  returns: v.array(v.string()),
  handler: async (ctx, args) => {
    if (args.chunkIds.length > maximumChunkCount) {
      throw new Error("too_many_chunks");
    }
    const chunks = await ctx.db.query("phoneReplicaChunks").collect();
    const present = new Set(chunks.map((chunk) => chunk.chunkId));
    return args.chunkIds.filter((chunkId) => !present.has(chunkId));
  },
});

export const generateUploadUrl = internalMutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => await ctx.storage.generateUploadUrl(),
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
    sourceBytes: v.number(),
    sourceFingerprint: v.string(),
  },
  returns: v.object({ reused: v.boolean() }),
  handler: async (ctx, args) => {
    if (
      args.chunkIds.length === 0 ||
      args.chunkIds.length > maximumChunkCount ||
      args.chunkIds.length !== args.chunkPlainBytes.length ||
      new Set(args.chunkIds).size !== args.chunkIds.length
    ) {
      throw new Error("invalid_snapshot_manifest");
    }
    const chunks = await ctx.db.query("phoneReplicaChunks").collect();
    const present = new Set(chunks.map((chunk) => chunk.chunkId));
    if (args.chunkIds.some((chunkId) => !present.has(chunkId))) {
      throw new Error("snapshot_references_missing_chunk");
    }

    const existing = await ctx.db
      .query("phoneReplicaSnapshots")
      .withIndex("by_source_fingerprint", (query) =>
        query.eq("sourceFingerprint", args.sourceFingerprint),
      )
      .unique();
    if (existing !== null) {
      return { reused: true };
    }

    await ctx.db.insert("phoneReplicaSnapshots", {
      ...args,
      compression: "zlib",
      encryption: "aes-gcm-v1",
      format: 1,
    });
    const snapshots = await ctx.db
      .query("phoneReplicaSnapshots")
      .withIndex("by_created_at")
      .order("desc")
      .collect();
    const retained = snapshots.slice(0, retainedSnapshotCount);
    for (const stale of snapshots.slice(retainedSnapshotCount)) {
      await ctx.db.delete(stale._id);
    }

    const referenced = new Set(retained.flatMap((snapshot) => snapshot.chunkIds));
    for (const chunk of chunks) {
      if (!referenced.has(chunk.chunkId)) {
        await ctx.storage.delete(chunk.storageId);
        await ctx.db.delete(chunk._id);
      }
    }
    return { reused: false };
  },
});

export const latestSnapshot = internalQuery({
  args: {},
  handler: async (ctx) =>
    await ctx.db.query("phoneReplicaSnapshots").withIndex("by_created_at").order("desc").first(),
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
      .withIndex("by_created_at")
      .order("desc")
      .take(retainedSnapshotCount);
    const chunks = await ctx.db.query("phoneReplicaChunks").collect();
    return {
      chunkCount: chunks.length,
      encryptedBytes: chunks.reduce((total, chunk) => total + chunk.encryptedBytes, 0),
      snapshots,
    };
  },
});
