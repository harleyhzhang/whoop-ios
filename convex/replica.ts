import { v } from "convex/values";

import { internalMutation, internalQuery } from "./_generated/server";

// Full age-encrypted archives now live in independent offsite cold storage.
// Convex retains only the current chunked phone replica. This mutation removes
// the legacy archive only when the caller pins both it and the newer surviving
// phone snapshot, so a stale maintenance command cannot delete the wrong copy.
export const retire = internalMutation({
  args: {
    expectedArchiveId: v.id("replicaArchives"),
    expectedEncryptedSha256: v.string(),
    expectedPhoneFingerprint: v.string(),
  },
  returns: v.object({ deletedEncryptedBytes: v.number() }),
  handler: async (ctx, args) => {
    const archive = await ctx.db.get(args.expectedArchiveId);
    if (archive === null || archive.encryptedSha256 !== args.expectedEncryptedSha256) {
      throw new Error("archive_changed");
    }
    const phone = await ctx.db
      .query("phoneReplicaSnapshots")
      .withIndex("by_created_at")
      .order("desc")
      .first();
    if (phone === null || phone.sourceFingerprint !== args.expectedPhoneFingerprint) {
      throw new Error("phone_snapshot_changed");
    }
    if (
      phone.createdAt < archive.createdAt ||
      phone.schemaVersion < archive.schemaVersion ||
      phone.sourceBytes < archive.sourceBytes
    ) {
      throw new Error("phone_snapshot_not_newer");
    }
    await ctx.storage.delete(archive.storageId);
    await ctx.db.delete(archive._id);
    return { deletedEncryptedBytes: archive.encryptedBytes };
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
