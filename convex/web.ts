import { v } from "convex/values";

import { internalMutation, internalQuery } from "./_generated/server";

// Compact dashboard copy for the website. One row per day, one per activity,
// and a single strap-status row; raw sensor data never leaves the phone.
const optionalNumber = v.optional(v.number());

export const webDay = v.object({
  day: v.string(),
  sleep: optionalNumber,
  recovery: optionalNumber,
  strain: optionalNumber,
  steps: optionalNumber,
  duration: optionalNumber,
  hrv: optionalNumber,
  rhr: optionalNumber,
});

export const webActivity = v.object({
  entryId: v.string(),
  kind: v.string(),
  title: v.string(),
  start: v.number(),
  end: optionalNumber,
  strain: optionalNumber,
  averageHeartRate: optionalNumber,
  maxHeartRate: optionalNumber,
  calories: optionalNumber,
  sleepScore: optionalNumber,
  zonePercents: v.optional(v.array(v.number())),
});

export const webStatus = v.object({
  heartRate: optionalNumber,
  heartRateAt: optionalNumber,
  battery: optionalNumber,
  powerPackBattery: optionalNumber,
  connected: v.optional(v.boolean()),
});

const maximumDays = 800;
const maximumActivities = 2000;

export const ingest = internalMutation({
  args: {
    days: v.array(webDay),
    activities: v.array(webActivity),
    removedActivityIds: v.optional(v.array(v.string())),
    status: v.optional(webStatus),
  },
  returns: v.object({ days: v.number(), activities: v.number() }),
  handler: async (ctx, args) => {
    if (args.days.length > maximumDays || args.activities.length > maximumActivities) {
      throw new Error("web sync batch too large");
    }
    const now = Date.now();
    for (const day of args.days) {
      const existing = await ctx.db
        .query("webDays")
        .withIndex("by_day", (q) => q.eq("day", day.day))
        .unique();
      if (existing) await ctx.db.replace(existing._id, { ...day, updatedAt: now });
      else await ctx.db.insert("webDays", { ...day, updatedAt: now });
    }
    for (const activity of args.activities) {
      const existing = await ctx.db
        .query("webActivities")
        .withIndex("by_entry_id", (q) => q.eq("entryId", activity.entryId))
        .unique();
      if (existing) await ctx.db.replace(existing._id, { ...activity, updatedAt: now });
      else await ctx.db.insert("webActivities", { ...activity, updatedAt: now });
    }
    for (const entryId of args.removedActivityIds ?? []) {
      const existing = await ctx.db
        .query("webActivities")
        .withIndex("by_entry_id", (q) => q.eq("entryId", entryId))
        .unique();
      if (existing) await ctx.db.delete(existing._id);
    }
    if (args.status) {
      const existing = await ctx.db.query("webStatus").first();
      const row = { ...args.status, syncedAt: now };
      if (existing) await ctx.db.replace(existing._id, row);
      else await ctx.db.insert("webStatus", row);
    }
    return { days: args.days.length, activities: args.activities.length };
  },
});

export const dashboard = internalQuery({
  args: {},
  handler: async (ctx) => {
    const days = await ctx.db.query("webDays").withIndex("by_day").take(maximumDays);
    const activities = await ctx.db
      .query("webActivities")
      .withIndex("by_start")
      .order("desc")
      .take(maximumActivities);
    const status = await ctx.db.query("webStatus").first();
    const strip = <T extends { _id: unknown; _creationTime: number }>({
      _id,
      _creationTime,
      ...rest
    }: T) => rest;
    return {
      days: days.map(strip),
      activities: activities.map(strip),
      status: status ? strip(status) : null,
    };
  },
});

// Passcode attempts: two per client per UTC day, and ten across all clients,
// so rotating IPs cannot brute-force a 4-digit code either.
const attemptsPerClient = 2;
const attemptsOverall = 10;
const overallKey = "*";

function utcDay(): string {
  return new Date().toISOString().slice(0, 10);
}

export const reserveAttempt = internalMutation({
  args: { key: v.string() },
  handler: async (ctx, { key }) => {
    const day = utcDay();
    for (const stale of await ctx.db.query("webLoginAttempts").withIndex("by_day", (q) => q.lt("day", day)).take(20)) {
      await ctx.db.delete(stale._id);
    }
    const row = (k: string) =>
      ctx.db.query("webLoginAttempts").withIndex("by_key_day", (q) => q.eq("key", k).eq("day", day)).unique();
    const client = await row(key);
    const overall = await row(overallKey);
    if ((client?.count ?? 0) >= attemptsPerClient || (overall?.count ?? 0) >= attemptsOverall) {
      return { allowed: false };
    }
    if (client) await ctx.db.patch(client._id, { count: client.count + 1 });
    else await ctx.db.insert("webLoginAttempts", { key, day, count: 1 });
    if (overall) await ctx.db.patch(overall._id, { count: overall.count + 1 });
    else await ctx.db.insert("webLoginAttempts", { key: overallKey, day, count: 1 });
    return { allowed: true };
  },
});

/** A correct passcode gives the attempt back. */
export const releaseAttempt = internalMutation({
  args: { key: v.string() },
  handler: async (ctx, { key }) => {
    const day = utcDay();
    for (const k of [key, overallKey]) {
      const row = await ctx.db
        .query("webLoginAttempts")
        .withIndex("by_key_day", (q) => q.eq("key", k).eq("day", day))
        .unique();
      if (row) await ctx.db.patch(row._id, { count: Math.max(0, row.count - 1) });
    }
  },
});
