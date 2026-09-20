import assert from "node:assert/strict";
import test from "node:test";

import {
  phoneWriteAuthorizationEnvironments,
  replicaReadAuthorizationEnvironments,
} from "../convex/authorizationPolicy.ts";

test("keeps read and write credentials least-privileged", () => {
  assert.deepEqual(replicaReadAuthorizationEnvironments, [
    "WHOOP_REPLICA_TOKEN_SHA256",
  ]);
  assert.deepEqual(phoneWriteAuthorizationEnvironments, [
    "WHOOP_PHONE_UPLOAD_TOKEN_SHA256",
  ]);
  assert.equal(
    new Set<string>(phoneWriteAuthorizationEnvironments).has(
      replicaReadAuthorizationEnvironments[0],
    ),
    false,
  );
});
