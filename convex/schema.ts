import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  replicaArchives: defineTable({
    createdAt: v.number(),
    encryptedBytes: v.number(),
    encryptedSha256: v.string(),
    idempotencyKey: v.string(),
    schemaVersion: v.number(),
    sourceBytes: v.number(),
    sourceCommit: v.optional(v.string()),
    sourceSha256: v.string(),
    storageId: v.id("_storage"),
  })
    .index("by_created_at", ["createdAt"])
    .index("by_idempotency_key", ["idempotencyKey"]),
});
