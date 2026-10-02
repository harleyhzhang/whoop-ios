#!/usr/bin/env node
/**
 * Read-only archive of the WHOOP iOS API surfaces used by the official app.
 *
 * Authentication is loaded from Totem's local 0600 .env. Tokens and request
 * headers are never written to the archive. Every response body is retained
 * byte-for-byte with a provenance/checksum record, including non-2xx bodies.
 */

import { createHash, randomUUID } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import { appendFile, chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const API_ROOT = "https://api.prod.whoop.com";
const AUTH_ROOT = `${API_ROOT}/auth-service/v3/whoop/`;
const KEYCHAIN_SERVICE = process.env.WHOOP_PRIVATE_API_KEYCHAIN_SERVICE ?? "whoop.private-ios-api";
const KEYCHAIN_ACCOUNT = "tokens";
const DEFAULT_OUTPUT_ROOT = process.env.WHOOP_DATA_ROOT ?? path.join(os.homedir(), "whoop-data");
const APP_VERSION = "5.68.2";
const APP_BUILD = "691464";
const TIME_ZONE = "America/New_York";
const INSTALLATION_ID = randomUUID().toUpperCase();
const REQUEST_GAP_MS = 180;
const MAX_ATTEMPTS = 5;

const TREND_METRICS = [
  "HRV", "RHR", "RECOVERY", "DAY_STRAIN", "CALORIES", "STEPS", "AVERAGE_HR",
  "HOURS_V_NEED", "HOURS_V_NEEDED_PERCENT", "TIME_IN_BED", "SLEEP_PERFORMANCE",
  "SLEEP_EFFICIENCY", "SLEEP_CONSISTENCY", "SLEEP_DEBT_POST", "RESTORATIVE_SLEEP",
  "HR_ZONES_1_3", "HR_ZONES_4_5", "RESPIRATORY_RATE", "STRENGTH_ACTIVITY_TIME",
  "STRESS", "STRESS_DURING_SLEEP", "STRESS_DURING_NON_STRAIN", "VO2_MAX",
  "BODY_COMPOSITION", "WEIGHT",
];

const SNAPSHOTS = [
  ["bootstrap", "/users-service/v2/bootstrap", {}],
  ["bootstrap-account", "/users-service/v2/bootstrap/account", {}],
  ["bootstrap-membership", "/users-service/v2/bootstrap/membership", {}],
  ["bootstrap-user", "/users-service/v2/bootstrap/user", {}],
  ["auth-user", "/auth-service/v2/user", {}],
  ["profile", "/profile-service/v1/profile/bff", {}],
  ["profile-edit-model", "/profile-service/v1/profile/bff/edit", {}],
  ["health-tab", "/health-tab-bff/v1/health-tab", {}],
  ["recovery-widget", "/widget-service/v1/statistics/recovery", {}],
  ["sleep-heart-rate-baseline", "/sleep-service/v1/heart-rate/baseline", {}],
  ["sleep-need", "/coaching-service/v2/sleepneed", {}],
  ["health-monitor", "/coaching-service/v1/health/bff/monitor", {}],
  ["health-report", "/coaching-service/v1/health/report", {}],
  ["activity-types", "/activities-service/v2/activity-types", {}],
  ["activity-state", "/activities-service/v1/user-state", {}],
  ["journal-legacy-behaviors", "/activities-service/v1/journals/behaviors/user", {}],
  ["journal-stats", "/activities-service/v1/journals/stats/user/0", {}],
  ["journal-preferences", "/journal-service/v1/journals/preferences", {}],
  ["journal-behaviors-v2", "/journal-service/v2/journals/behaviors", {}],
  ["journal-behaviors-v3", "/journal-service/v3/journals/behaviors", {}],
  ["behavior-impact", "/behavior-impact-service/v1/impact", {}],
  ["hr-zone-settings", "/hr-zones-service/v1/bff/settings", {}],
  ["hr-zones", "/hr-zones-service/v1/bff/zones", {}],
  ["hidden-body-composition", "/users-service/v1/hidden-metrics/BODY_COMP", {}],
  ["hidden-healthspan", "/users-service/v1/hidden-metrics/HEALTHSPAN", {}],
  ["straps", "/membership-service/v1/straps", {}],
  ["integrations", "/integrations-bff/v1/integrations/discovery", {}],
  ["smart-alarm-preferences", "/smart-alarm-service/v1/smartalarm/preferences", {}],
  ["smart-alarm-schedules", "/smart-alarm-bff/v1/schedule/all", {}],
  ["data-export-details", "/member-data-export-service/v1/member-data-export-details", {}],
  ["advanced-labs", "/advanced-labs-service/v1/advanced-labs", {}],
  ["research-campaigns", "/research-service/research-bff-service/v1/campaigns", {}],
  ["streaks", "/streaks-service/v1/bff/streaks/data-streak", {}],
  ["weekly-plan-settings", "/progression-service/v2/weekly-plan/setup", { screens: "STRENGTH_TRAINING_TIME", editing: "true" }],
  ["lift-library", "/weightlifting-service/v3/workout-library", {}],
  ["lift-prs", "/weightlifting-service/v3/prs", {}],
  ["lift-exercises", "/weightlifting-service/v2/exercise", {}],
];

const DAILY = [
  ["home", "/home-service/v1/home", "query"],
  ["recovery", "/home-service/v1/deep-dive/recovery", "query"],
  ["recovery-trends", "/home-service/v1/deep-dive/recovery/trends", "query"],
  ["sleep-last-night", "/home-service/v1/deep-dive/sleep/last-night", "query"],
  ["sleep", "/home-service/v1/deep-dive/sleep", "query"],
  ["sleep-trends", "/home-service/v1/deep-dive/sleep/trends", "query"],
  ["strain", "/home-service/v1/deep-dive/strain", "query"],
  ["strain-trends", "/home-service/v1/deep-dive/strain/trends", "query"],
  ["tilt-view", "/home-service/v1/tilt-view", "query"],
  ["stress", "/health-service/v2/stress-bff/{date}", "path"],
  ["journal-behaviors", "/journal-service/v2/journals/behaviors/user/{date}", "path"],
  ["journal-date-picker", "/journal-service/v3/journals/date-picker/{date}", "path"],
  ["journal-draft", "/journal-service/v3/journals/drafts/mobile/{date}", "path"],
  ["journal-home-tile", "/journal-service/v3/journals/home-tile", "query"],
  ["weekly-plan", "/progression-service/v2/weekly-plan/home-tile/{date}", "path"],
];

function parseArgs() {
  const values = { start: "2025-10-15", end: isoDay(new Date()), output: DEFAULT_OUTPUT_ROOT, tokenFile: null, daily: true };
  for (let i = 2; i < process.argv.length; i += 1) {
    const arg = process.argv[i];
    if (arg === "--start") values.start = process.argv[++i];
    else if (arg === "--end") values.end = process.argv[++i];
    else if (arg === "--output") values.output = process.argv[++i];
    else if (arg === "--token-file") values.tokenFile = process.argv[++i];
    else if (arg === "--no-daily") values.daily = false;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(values.start) || !/^\d{4}-\d{2}-\d{2}$/.test(values.end)) throw new Error("Dates must use YYYY-MM-DD");
  if (values.start > values.end) throw new Error("--start must be on or before --end");
  return values;
}

function isoDay(date) { return date.toISOString().slice(0, 10); }
function addDays(day, count) { const date = new Date(`${day}T12:00:00Z`); date.setUTCDate(date.getUTCDate() + count); return isoDay(date); }
function monthStarts(start, end) {
  const out = [];
  let d = new Date(`${start.slice(0, 7)}-01T12:00:00Z`);
  const last = new Date(`${end.slice(0, 7)}-01T12:00:00Z`);
  while (d <= last) { out.push(isoDay(d)); d.setUTCMonth(d.getUTCMonth() + 1); }
  return out;
}
function days(start, end) { const out = []; for (let d = start; d <= end; d = addDays(d, 1)) out.push(d); return out; }
function envFile(text) {
  return Object.fromEntries(text.split(/\r?\n/).filter((line) => line && !line.startsWith("#") && line.includes("=")).map((line) => { const i = line.indexOf("="); return [line.slice(0, i), line.slice(i + 1)]; }));
}
function jwtExpiry(token) {
  try { return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")).exp * 1000; } catch { return 0; }
}
function sha256(buffer) { return createHash("sha256").update(buffer).digest("hex"); }
function safeName(value) { return value.replace(/[^a-zA-Z0-9._-]+/g, "-"); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

const execFile = promisify(execFileCallback);

async function loadTokenText(tokenFile) {
  if (tokenFile) return readFile(tokenFile, "utf8");
  try {
    const { stdout } = await execFile("/usr/bin/security", [
      "find-generic-password", "-s", KEYCHAIN_SERVICE,
      "-a", KEYCHAIN_ACCOUNT, "-w",
    ], { encoding: "utf8", maxBuffer: 64 * 1024 });
    return stdout;
  } catch {
    throw new Error("Private WHOOP tokens are unavailable in macOS Keychain; authenticate first or pass --token-file");
  }
}

async function saveTokenText(tokenFile, text) {
  if (tokenFile) {
    const temp = `${tokenFile}.tmp-${process.pid}`;
    await writeFile(temp, text, { mode: 0o600 });
    await rename(temp, tokenFile);
    await chmod(tokenFile, 0o600);
    return;
  }
  await execFile("/usr/bin/security", [
    "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
    "-a", KEYCHAIN_ACCOUNT, "-w", text,
  ], { encoding: "utf8", maxBuffer: 64 * 1024 });
}

const args = parseArgs();
const envText = await loadTokenText(args.tokenFile);
const auth = envFile(envText);
let accessToken = auth.WHOOP_IOS_BEARER_TOKEN;
let refreshToken = auth.WHOOP_COGNITO_REFRESH_TOKEN;
if (!accessToken || !refreshToken) throw new Error("Private WHOOP tokens are unavailable; authenticate first");

const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
const runDir = path.join(args.output, `private-api-${stamp}`);
const rawDir = path.join(runDir, "raw");
const journalPath = path.join(runDir, "requests.jsonl");
await mkdir(rawDir, { recursive: true, mode: 0o700 });
await chmod(runDir, 0o700);

let sequence = 0;
let lastRequestAt = 0;
const records = [];
let refreshPromise = null;

async function persistTokens() {
  let next = envText.split(/\r?\n/);
  const put = (key, value) => {
    const index = next.findIndex((line) => line.startsWith(`${key}=`));
    if (index >= 0) next[index] = `${key}=${value}`; else next.push(`${key}=${value}`);
  };
  put("WHOOP_IOS_BEARER_TOKEN", accessToken);
  put("WHOOP_COGNITO_REFRESH_TOKEN", refreshToken);
  await saveTokenText(args.tokenFile, next.join("\n"));
}

async function refreshAccessToken() {
  if (refreshPromise) return refreshPromise;
  refreshPromise = (async () => {
    const response = await fetch(AUTH_ROOT, {
      method: "POST",
      headers: {
        "content-type": "application/x-amz-json-1.1",
        "x-amz-target": "AWSCognitoIdentityProviderService.InitiateAuth",
        "amz-sdk-request": "attempt=1; max=1",
        "amz-sdk-invocation-id": randomUUID(),
        "user-agent": `aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 os/ios#26.3.1 lang/swift#5.10 m/D,N,Z,b`,
      },
      body: JSON.stringify({ AuthFlow: "REFRESH_TOKEN_AUTH", AuthParameters: { REFRESH_TOKEN: refreshToken }, ClientId: "" }),
    });
    if (!response.ok) throw new Error(`WHOOP token refresh failed: HTTP ${response.status}`);
    const body = await response.json();
    if (!body.AuthenticationResult?.AccessToken) throw new Error("WHOOP token refresh did not return an access token");
    accessToken = body.AuthenticationResult.AccessToken;
    if (body.AuthenticationResult.RefreshToken) refreshToken = body.AuthenticationResult.RefreshToken;
    await persistTokens();
  })().finally(() => { refreshPromise = null; });
  return refreshPromise;
}

function deviceHeaders() {
  return {
    authorization: `Bearer ${accessToken}`,
    "user-agent": "iOS",
    "x-whoop-device-platform": "iOS",
    "x-whoop-ios-version": APP_VERSION,
    "x-whoop-ios-build-number": APP_BUILD,
    "x-whoop-bundle-name": "com.whoop.iphone",
    "x-whoop-installation-identifier": INSTALLATION_ID,
    "x-whoop-time-zone": TIME_ZONE,
    "x-whoop-clock-format": "TWELVE_HOUR",
    currency: "USD", locale: "en_US", "accept-language": "en", accept: "*/*", priority: "u=3",
  };
}

async function pace() {
  const wait = Math.max(0, REQUEST_GAP_MS - (Date.now() - lastRequestAt));
  if (wait) await sleep(wait);
  lastRequestAt = Date.now();
}

async function archiveRequest(category, name, endpoint, query = {}) {
  const url = new URL(API_ROOT + endpoint);
  url.searchParams.set("apiVersion", "7");
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, String(value));
  let response;
  let buffer;
  let attempt = 0;
  for (; attempt < MAX_ATTEMPTS; attempt += 1) {
    if (jwtExpiry(accessToken) <= Date.now() + 60_000) await refreshAccessToken();
    await pace();
    try {
      response = await fetch(url, { headers: deviceHeaders(), signal: AbortSignal.timeout(90_000) });
      buffer = Buffer.from(await response.arrayBuffer());
    } catch (error) {
      if (attempt + 1 >= MAX_ATTEMPTS) {
        response = { status: 0, headers: new Headers() };
        buffer = Buffer.from(String(error));
        break;
      }
      await sleep(750 * 2 ** attempt);
      continue;
    }
    if (response.status === 401 && attempt === 0) { await refreshAccessToken(); continue; }
    if ((response.status === 429 || response.status >= 500) && attempt + 1 < MAX_ATTEMPTS) {
      const retryAfter = Number(response.headers.get("retry-after"));
      await sleep(Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 750 * 2 ** attempt);
      continue;
    }
    break;
  }

  const index = String(++sequence).padStart(5, "0");
  const extension = (response.headers.get("content-type") ?? "").includes("json") ? "json" : "bin";
  const relative = path.join("raw", safeName(category), `${index}-${safeName(name)}.${extension}`);
  const absolute = path.join(runDir, relative);
  await mkdir(path.dirname(absolute), { recursive: true, mode: 0o700 });
  await writeFile(absolute, buffer, { mode: 0o600 });
  const record = {
    sequence, category, name, method: "GET", path: endpoint, query,
    status: response.status, fetched_at: new Date().toISOString(), attempts: attempt + 1,
    content_type: response.headers.get("content-type"), bytes: buffer.length,
    sha256: sha256(buffer), file: relative,
  };
  records.push(record);
  await appendFile(journalPath, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  return { response, buffer, record };
}

function json(buffer) { try { return JSON.parse(buffer.toString("utf8")); } catch { return null; } }

await writeFile(path.join(runDir, "catalog.json"), JSON.stringify({
  format_version: 1,
  source: "WHOOP private iOS API (read-only)",
  official_app_identity: { version: APP_VERSION, build: APP_BUILD, bundle: "com.whoop.iphone" },
  coverage_requested: { start: args.start, end: args.end },
  trend_metrics: TREND_METRICS,
  snapshots: SNAPSHOTS.map(([name, endpoint, query]) => ({ name, path: endpoint, query })),
  daily_endpoints: DAILY.map(([name, endpoint, date_style]) => ({ name, path: endpoint, date_style })),
}, null, 2) + "\n", { mode: 0o600 });

console.log(`run_dir=${runDir}`);
console.log(`phase=snapshots count=${SNAPSHOTS.length}`);
for (const [name, endpoint, query] of SNAPSHOTS) await archiveRequest("snapshots", name, endpoint, query);

console.log(`phase=trends metrics=${TREND_METRICS.length}`);
for (const metric of TREND_METRICS) {
  let endDate = args.end;
  const seen = new Set();
  for (let window = 0; window < 12 && !seen.has(endDate); window += 1) {
    seen.add(endDate);
    const result = await archiveRequest("trends", `${metric}-${endDate}`, `/progression-service/v3/trends/${metric}`, { endDate });
    if (result.response.status !== 200) break;
    const payload = json(result.buffer);
    const previous = payload?.six_month_time_segment?.date_picker?.previous_date_time?.slice(0, 10);
    if (!previous || previous >= endDate) break;
    endDate = previous;
    if (previous < addDays(args.start, -190)) break;
  }
  console.log(`trend=${metric} requests=${sequence}`);
}

const months = monthStarts(args.start, args.end);
console.log(`phase=calendars months=${months.length}`);
for (const date of months) {
  await archiveRequest("calendar", `overview-${date}`, "/home-service/v1/calendar/overview", { date });
  await archiveRequest("calendar", `recovery-${date}`, "/home-service/v1/calendar/recovery", { date });
  await archiveRequest("calendar", `stress-${date}`, `/health-service/v2/stress-bff/${date}/calendar`, {});
}

if (args.daily) {
  const allDays = days(args.start, args.end);
  const total = allDays.length * DAILY.length;
  console.log(`phase=daily days=${allDays.length} requests=${total}`);
  let done = 0;
  for (const date of allDays) {
    for (const [name, template, dateStyle] of DAILY) {
      const endpoint = dateStyle === "path" ? template.replace("{date}", date) : template;
      const query = dateStyle === "query" ? { date } : {};
      await archiveRequest("daily", `${date}-${name}`, endpoint, query);
      done += 1;
    }
    if (done % (DAILY.length * 10) === 0 || date === args.end) console.log(`daily=${done}/${total} through=${date}`);
  }
}

const statusCounts = Object.fromEntries([...new Set(records.map((r) => r.status))].sort((a, b) => a - b).map((status) => [status, records.filter((r) => r.status === status).length]));
const manifest = {
  format_version: 1,
  source: "WHOOP private iOS API (read-only)",
  created_at: records[0]?.fetched_at ?? new Date().toISOString(),
  completed_at: new Date().toISOString(),
  coverage_requested: { start: args.start, end: args.end },
  official_app_identity: { version: APP_VERSION, build: APP_BUILD, bundle: "com.whoop.iphone" },
  request_count: records.length,
  status_counts: statusCounts,
  total_bytes: records.reduce((sum, record) => sum + record.bytes, 0),
  records,
};
await writeFile(path.join(runDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n", { mode: 0o600 });
await chmod(journalPath, 0o600);
console.log(`complete requests=${records.length} bytes=${manifest.total_bytes} statuses=${JSON.stringify(statusCounts)}`);
