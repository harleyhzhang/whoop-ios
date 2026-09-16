import { v } from "convex/values";

import { internalMutation, internalQuery } from "./_generated/server";

const retainedArchiveCount = 2;

export const generateUploadUrl = internalMutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => await ctx.storage.generateUploadUrl(),
});

export const commit = internalMutation({
  args: {
    createdAt: v.number(),
    encryptedBytes: v.number(),
    encryptedSha256: v.string(),
    idempotencyKey: v.string(),
    schemaVersion: v.number(),
    sourceBytes: v.number(),
    sourceCommit: v.optional(v.string()),
    sourceSha256: v.string(),
    storageId: v.id("_storage"),
  },
  returns: v.object({ archiveId: v.id("replicaArchives"), reused: v.boolean() }),
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("replicaArchives")
      .withIndex("by_idempotency_key", (query) => query.eq("idempotencyKey", args.idempotencyKey))
      .unique();
    if (existing !== null) {
      if (existing.storageId !== args.storageId) {
        await ctx.storage.delete(args.storageId);
      }
      return { archiveId: existing._id, reused: true };
    }

    const archiveId = await ctx.db.insert("replicaArchives", args);
    const archives = await ctx.db
      .query("replicaArchives")
      .withIndex("by_created_at")
      .order("desc")
      .collect();
    for (const stale of archives.slice(retainedArchiveCount)) {
      await ctx.storage.delete(stale.storageId);
      await ctx.db.delete(stale._id);
    }
    return { archiveId, reused: false };
  },
});

export const latest = internalQuery({
  args: {},
  handler: async (ctx) =>
    await ctx.db.query("replicaArchives").withIndex("by_created_at").order("desc").first(),
});

export const list = internalQuery({
  args: {},
  handler: async (ctx) =>
    await ctx.db.query("replicaArchives").withIndex("by_created_at").order("desc").take(10),
});
