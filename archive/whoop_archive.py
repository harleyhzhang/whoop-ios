#!/usr/bin/env python3
"""Authorize and archive every collection exposed by WHOOP's v2 API.

OAuth tokens live in the macOS Keychain. Each archive run is immutable and
keeps the exact response body for every API page plus a small integrity
manifest. The developer client secret is read from the existing restricted
configuration file and is never copied into the archive.
"""

from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


AUTH_URL = "https://api.prod.whoop.com/oauth/oauth2/auth"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"
API_ROOT = "https://api.prod.whoop.com/developer/v2"
SCOPES = (
    "offline",
    "read:recovery",
    "read:cycles",
    "read:workout",
    "read:sleep",
    "read:profile",
    "read:body_measurement",
)
COLLECTIONS = {
    "cycles": "/cycle",
    "recoveries": "/recovery",
    "sleeps": "/activity/sleep",
    "workouts": "/activity/workout",
}
SINGLETONS = {
    "profile": "/user/profile/basic",
    "body_measurement": "/user/measurement/body",
}
DEFAULT_CONFIG = Path(os.environ.get("WHOOP_API_CONFIG", Path.home() / ".config/whoop/env")).expanduser()
DEFAULT_ARCHIVE = Path(os.environ.get("WHOOP_DATA_ROOT", Path.home() / "whoop-data"))
KEYCHAIN_SERVICE = "whoop.whoop.oauth"
KEYCHAIN_ACCOUNT = "default"


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def config(path: Path) -> tuple[str, str, str]:
    values = load_env(path)
    missing = [
        key
        for key in ("WHOOP_CLIENT_ID", "WHOOP_CLIENT_SECRET", "WHOOP_REDIRECT_URI")
        if not values.get(key)
    ]
    if missing:
        raise RuntimeError(f"Missing configuration keys: {', '.join(missing)}")
    return (
        values["WHOOP_CLIENT_ID"],
        values["WHOOP_CLIENT_SECRET"],
        values["WHOOP_REDIRECT_URI"],
    )


def keychain_get() -> dict[str, Any] | None:
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def keychain_put(tokens: dict[str, Any]) -> None:
    payload = json.dumps(tokens, separators=(",", ":"))
    result = subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
            payload,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError("Could not save WHOOP OAuth tokens in macOS Keychain")


def request_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    form: dict[str, str] | None = None,
) -> tuple[dict[str, Any], bytes]:
    body = urllib.parse.urlencode(form).encode() if form else None
    request_headers = {
        "Accept": "application/json",
        "User-Agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        ),
        **(headers or {}),
    }
    request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"WHOOP returned HTTP {error.code}: {detail}") from error
    return json.loads(raw), raw


def stamp_token(token: dict[str, Any]) -> dict[str, Any]:
    stamped = dict(token)
    stamped["obtained_at"] = int(time.time())
    stamped["expires_at"] = int(time.time()) + int(token.get("expires_in", 0))
    return stamped


def refresh_token(config_path: Path, token: dict[str, Any]) -> dict[str, Any]:
    client_id, client_secret, _ = config(config_path)
    refresh = token.get("refresh_token")
    if not refresh:
        raise RuntimeError("No refresh token is available; authorize again")
    fresh, _ = request_json(
        TOKEN_URL,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        form={
            "grant_type": "refresh_token",
            "refresh_token": str(refresh),
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": " ".join(SCOPES),
        },
    )
    if "refresh_token" not in fresh:
        fresh["refresh_token"] = refresh
    fresh = stamp_token(fresh)
    keychain_put(fresh)
    return fresh


def access_token(config_path: Path) -> str:
    token = keychain_get()
    if not token:
        raise RuntimeError("No WHOOP OAuth token is stored; run authorize first")
    if int(token.get("expires_at", 0)) <= int(time.time()) + 60:
        token = refresh_token(config_path, token)
    access = token.get("access_token")
    if not access:
        raise RuntimeError("Stored WHOOP OAuth record has no access token")
    return str(access)


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    code: str | None = None
    returned_state: str | None = None
    oauth_error: str | None = None

    def do_GET(self) -> None:  # noqa: N802
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        type(self).code = query.get("code", [None])[0]
        type(self).returned_state = query.get("state", [None])[0]
        type(self).oauth_error = query.get("error", [None])[0]
        ok = type(self).code is not None
        message = (
            "WHOOP authorization received. You can close this tab."
            if ok
            else "WHOOP authorization was not completed. You can close this tab."
        )
        content = (
            "<!doctype html><meta charset=utf-8><title>WHOOP archive</title>"
            f"<body style='font:18px -apple-system;padding:48px;background:#111;color:#eee'>{message}</body>"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, _format: str, *_args: Any) -> None:
        return


def authorize(config_path: Path, launch_browser: bool) -> None:
    client_id, client_secret, redirect_uri = config(config_path)
    parsed = urllib.parse.urlparse(redirect_uri)
    if parsed.hostname not in {"localhost", "127.0.0.1"} or not parsed.port:
        raise RuntimeError("The configured redirect must be a localhost URL with an explicit port")

    state = secrets.token_hex(4)
    params = urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "scope": " ".join(SCOPES),
            "state": state,
        }
    )
    url = f"{AUTH_URL}?{params}"
    print("Open this WHOOP authorization page:")
    print(url)
    if launch_browser:
        subprocess.run(["open", url], check=True)

    server = http.server.HTTPServer((parsed.hostname, parsed.port), CallbackHandler)
    server.timeout = 180
    server.handle_request()
    server.server_close()
    if CallbackHandler.oauth_error:
        raise RuntimeError(f"WHOOP authorization failed: {CallbackHandler.oauth_error}")
    if not CallbackHandler.code:
        raise RuntimeError("Timed out waiting for WHOOP authorization")
    if CallbackHandler.returned_state != state:
        raise RuntimeError("WHOOP OAuth state mismatch; refusing the callback")

    exchange_code(config_path, CallbackHandler.code, redirect_uri)
    print("WHOOP authorization is stored in macOS Keychain.")


def exchange_code(config_path: Path, code: str, redirect_uri: str) -> None:
    client_id, client_secret, _ = config(config_path)
    token, _ = request_json(
        TOKEN_URL,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        form={
            "grant_type": "authorization_code",
            "code": code,
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": redirect_uri,
        },
    )
    keychain_put(stamp_token(token))


def api_response(config_path: Path, path: str, params: dict[str, str] | None = None) -> tuple[dict[str, Any], bytes]:
    query = f"?{urllib.parse.urlencode(params)}" if params else ""
    url = f"{API_ROOT}{path}{query}"
    return request_json(url, headers={"Authorization": f"Bearer {access_token(config_path)}"})


def write_raw(path: Path, raw: bytes) -> dict[str, Any]:
    path.write_bytes(raw)
    return {
        "path": str(path.name),
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def bounds(records: list[dict[str, Any]]) -> dict[str, str | None]:
    values = [
        str(record.get("start") or record.get("created_at"))
        for record in records
        if record.get("start") or record.get("created_at")
    ]
    return {"earliest": min(values) if values else None, "latest": max(values) if values else None}


def new_run_directory(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    stem = datetime.now(timezone.utc).strftime("api-%Y%m%dT%H%M%SZ")
    candidate = root / stem
    suffix = 1
    while candidate.exists():
        candidate = root / f"{stem}-{suffix}"
        suffix += 1
    candidate.mkdir(mode=0o700)
    return candidate


def archive(config_path: Path, archive_root: Path) -> Path:
    run = new_run_directory(archive_root)
    manifest: dict[str, Any] = {
        "format_version": 1,
        "source": "WHOOP Developer API v2",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "collections": {},
        "files": [],
    }

    for name, path in SINGLETONS.items():
        _parsed, raw = api_response(config_path, path)
        filename = run / f"{name}.json"
        manifest["files"].append(write_raw(filename, raw))
        print(f"{name}: saved")

    for name, path in COLLECTIONS.items():
        records: list[dict[str, Any]] = []
        token: str | None = None
        page = 0
        while True:
            page += 1
            params = {"limit": "25"}
            if token:
                params["nextToken"] = token
            parsed, raw = api_response(config_path, path, params)
            filename = run / f"{name}-page-{page:04d}.json"
            manifest["files"].append(write_raw(filename, raw))
            page_records = parsed.get("records", [])
            if not isinstance(page_records, list):
                raise RuntimeError(f"WHOOP returned an invalid {name} collection")
            records.extend(page_records)
            print(f"{name}: page {page}, {len(records)} records")
            token = parsed.get("next_token")
            if not token:
                break

        combined = json.dumps({"records": records}, indent=2, sort_keys=True).encode() + b"\n"
        combined_path = run / f"{name}-combined.json"
        manifest["files"].append(write_raw(combined_path, combined))
        manifest["collections"][name] = {
            "records": len(records),
            "pages": page,
            **bounds(records),
        }

    manifest_path = run / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(manifest_path, 0o600)
    print(f"Archive complete: {run}")
    return run


def status(config_path: Path) -> None:
    client_id, _secret, redirect = config(config_path)
    token = keychain_get()
    print(f"Config: ready ({config_path})")
    print(f"Client: {client_id[:8]}…")
    print(f"Redirect: {redirect}")
    print(f"OAuth token: {'stored' if token else 'not stored'}")
    if token:
        print(f"Offline refresh: {'available' if token.get('refresh_token') else 'missing'}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    subparsers = parser.add_subparsers(dest="command", required=True)

    auth = subparsers.add_parser("authorize", help="Authorize the existing WHOOP developer app")
    auth.add_argument("--no-browser", action="store_true")
    export = subparsers.add_parser("archive", help="Download every v2 collection page")
    export.add_argument("--output", type=Path, default=DEFAULT_ARCHIVE)
    exchange = subparsers.add_parser("exchange-code-file", help=argparse.SUPPRESS)
    exchange.add_argument("path", type=Path)
    subparsers.add_parser("status", help="Check config and Keychain state without exposing secrets")

    args = parser.parse_args()
    try:
        if args.command == "authorize":
            authorize(args.config, not args.no_browser)
        elif args.command == "archive":
            archive(args.config, args.output)
        elif args.command == "exchange-code-file":
            code = args.path.read_text(encoding="utf-8").strip()
            args.path.unlink()
            exchange_code(args.config, code, config(args.config)[2])
            print("WHOOP authorization is stored in macOS Keychain.")
        else:
            status(args.config)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
