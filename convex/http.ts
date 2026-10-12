import { httpRouter } from "convex/server";

import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";
import {
  phoneWriteAuthorizationEnvironments,
  replicaReadAuthorizationEnvironments,
  webReadAuthorizationEnvironments,
  webSyncAuthorizationEnvironments,
} from "./authorizationPolicy";

const http = httpRouter();

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function bytesToHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function authorized(request: Request): Promise<boolean> {
  return await authorizedFor(request, replicaReadAuthorizationEnvironments);
}

async function phoneWriteAuthorized(request: Request): Promise<boolean> {
  return await authorizedFor(request, phoneWriteAuthorizationEnvironments);
}

async function authorizedFor(
  request: Request,
  environmentNames: readonly string[],
): Promise<boolean> {
  const header = request.headers.get("authorization") ?? "";
  if (!header.startsWith("Bearer ")) {
    return false;
  }
  const token = header.slice("Bearer ".length);
  const actualHash = bytesToHex(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
  );
  return environmentNames.some((name) => process.env[name] === actualHash);
}

/** JSON null means "no value"; Convex optional fields expect the key to be absent. */
function withoutNulls(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutNulls);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, item]) => item !== null)
        .map(([key, item]) => [key, withoutNulls(item)]),
    );
  }
  return value;
}

http.route({
  path: "/v1/archive/health",
  method: "GET",
  handler: httpAction(async () => json({ ok: true })),
});

http.route({
  path: "/v1/phone/missing",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await phoneWriteAuthorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const body = (await request.json()) as { chunkIds?: unknown };
    if (
      !Array.isArray(body.chunkIds) ||
      !body.chunkIds.every((value) => typeof value === "string")
    ) {
      return json({ error: "invalid_chunk_ids" }, 400);
    }
    const missing = await ctx.runMutation(internal.phoneReplica.missingChunks, {
      chunkIds: body.chunkIds,
    });
    return json({ missing });
  }),
});

http.route({
  path: "/v1/phone/upload-url",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await phoneWriteAuthorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    return json({
      uploadUrl: await ctx.runMutation(
        internal.phoneReplica.generateUploadUrl,
        {},
      ),
    });
  }),
});

http.route({
  path: "/v1/phone/commit-chunk",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await phoneWriteAuthorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const body = (await request.json()) as {
      chunkId: string;
      createdAt: number;
      encryptedBytes: number;
      storageId: string;
    };
    const result = await ctx.runMutation(internal.phoneReplica.commitChunk, {
      ...body,
      storageId: body.storageId as never,
    });
    return json(result);
  }),
});

http.route({
  path: "/v1/phone/commit-snapshot",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await phoneWriteAuthorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const body = (await request.json()) as {
      chunkIds: string[];
      chunkPlainBytes: number[];
      chunkSize: number;
      createdAt: number;
      schemaVersion: number;
      seedOnly?: boolean;
      sourceBytes: number;
      sourceFingerprint: string;
    };
    return json(
      await ctx.runMutation(internal.phoneReplica.commitSnapshot, body),
    );
  }),
});

http.route({
  path: "/v1/phone/latest",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const snapshot = await ctx.runQuery(
      internal.phoneReplica.latestSnapshot,
      {},
    );
    return snapshot === null
      ? json({ error: "not_found" }, 404)
      : json({ snapshot });
  }),
});

http.route({
  path: "/v1/phone/chunk-url",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const body = (await request.json()) as { chunkId: string };
    const chunk = await ctx.runQuery(internal.phoneReplica.chunk, body);
    if (chunk === null) {
      return json({ error: "not_found" }, 404);
    }
    const downloadUrl = await ctx.storage.getUrl(chunk.storageId);
    return downloadUrl === null
      ? json({ error: "file_not_found" }, 404)
      : json({ downloadUrl });
  }),
});

http.route({
  path: "/v1/phone/status",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    return json(await ctx.runQuery(internal.phoneReplica.status, {}));
  }),
});

http.route({
  path: "/v1/archive/latest",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const archive = await ctx.runQuery(internal.replica.latest, {});
    if (archive === null) {
      return json({ error: "not_found" }, 404);
    }
    const downloadUrl = await ctx.storage.getUrl(archive.storageId);
    if (downloadUrl === null) {
      return json({ error: "file_not_found" }, 404);
    }
    return json({ archive, downloadUrl });
  }),
});

http.route({
  path: "/v1/archive/retire",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const body = (await request.json()) as {
      expectedArchiveId: string;
      expectedEncryptedSha256: string;
      expectedPhoneFingerprint: string;
    };
    return json(
      await ctx.runMutation(internal.replica.retire, {
        ...body,
        expectedArchiveId: body.expectedArchiveId as never,
      }),
    );
  }),
});

http.route({
  path: "/v1/archive/list",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    return json({ archives: await ctx.runQuery(internal.replica.list, {}) });
  }),
});

http.route({
  path: "/v1/web/sync",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorizedFor(request, webSyncAuthorizationEnvironments))) {
      return json({ error: "unauthorized" }, 401);
    }
    const body = withoutNulls(await request.json()) as {
      days?: never[];
      activities?: never[];
      removedActivityIds?: string[];
      status?: never;
    };
    try {
      return json(
        await ctx.runMutation(internal.web.ingest, {
          days: body.days ?? [],
          activities: body.activities ?? [],
          removedActivityIds: body.removedActivityIds,
          status: body.status,
        }),
      );
    } catch (error) {
      return json({ error: String(error) }, 400);
    }
  }),
});

http.route({
  path: "/v1/web/dashboard",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorizedFor(request, webReadAuthorizationEnvironments))) {
      return json({ error: "unauthorized" }, 401);
    }
    return json(await ctx.runQuery(internal.web.dashboard, {}));
  }),
});

http.route({
  path: "/v1/web/attempt",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorizedFor(request, webReadAuthorizationEnvironments))) {
      return json({ error: "unauthorized" }, 401);
    }
    const { key, release } = (await request.json()) as { key?: unknown; release?: unknown };
    if (typeof key !== "string" || key.length < 16 || key.length > 128) {
      return json({ error: "bad key" }, 400);
    }
    if (release === true) {
      await ctx.runMutation(internal.web.releaseAttempt, { key });
      return json({ ok: true });
    }
    return json(await ctx.runMutation(internal.web.reserveAttempt, { key }));
  }),
});

export default http;
