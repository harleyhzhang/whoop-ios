import { httpRouter } from "convex/server";

import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";

const http = httpRouter();

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function bytesToHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function authorized(request: Request): Promise<boolean> {
  const expectedHash = process.env.WHOOP_REPLICA_TOKEN_SHA256;
  const header = request.headers.get("authorization") ?? "";
  if (expectedHash === undefined || !header.startsWith("Bearer ")) {
    return false;
  }
  const token = header.slice("Bearer ".length);
  const actualHash = bytesToHex(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
  );
  return actualHash === expectedHash;
}

http.route({
  path: "/v1/archive/health",
  method: "GET",
  handler: httpAction(async () => json({ ok: true })),
});

http.route({
  path: "/v1/archive/upload-url",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    return json({ uploadUrl: await ctx.runMutation(internal.replica.generateUploadUrl, {}) });
  }),
});

http.route({
  path: "/v1/archive/commit",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    const body = (await request.json()) as {
      createdAt: number;
      encryptedBytes: number;
      encryptedSha256: string;
      idempotencyKey: string;
      schemaVersion: number;
      sourceBytes: number;
      sourceCommit?: string;
      sourceSha256: string;
      storageId: string;
    };
    const result = await ctx.runMutation(internal.replica.commit, {
      ...body,
      storageId: body.storageId as never,
    });
    return json(result);
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
  path: "/v1/archive/list",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    if (!(await authorized(request))) {
      return json({ error: "unauthorized" }, 401);
    }
    return json({ archives: await ctx.runQuery(internal.replica.list, {}) });
  }),
});

export default http;
