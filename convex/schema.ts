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
  phoneReplicaChunks: defineTable({
    chunkId: v.string(),
    createdAt: v.number(),
    encryptedBytes: v.number(),
    storageId: v.id("_storage"),
  }).index("by_chunk_id", ["chunkId"]),
  phoneReplicaSnapshots: defineTable({
    chunkIds: v.array(v.string()),
    chunkPlainBytes: v.array(v.number()),
    chunkSize: v.number(),
    compression: v.literal("zlib"),
    createdAt: v.number(),
    encryption: v.literal("aes-gcm-v1"),
    format: v.literal(1),
    schemaVersion: v.number(),
    sourceBytes: v.number(),
    sourceFingerprint: v.string(),
  })
    .index("by_created_at", ["createdAt"])
    .index("by_source_fingerprint", ["sourceFingerprint"]),
});
