#!/usr/bin/env python3
"""Interactive, account-owner login for the optional WHOOP private archive."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from collections.abc import Callable
from typing import Any

ENDPOINT = "https://api.prod.whoop.com/auth-service/v3/whoop/"
USER_AGENT = (
    "aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 "
    "os/ios#26.3.1 lang/swift#5.10 m/D,N,Z,b"
)
CHALLENGES = {
    "EMAIL_OTP": ("Email code: ", "EMAIL_OTP_CODE"),
    "SMS_MFA": ("SMS code: ", "SMS_MFA_CODE"),
    "SOFTWARE_TOKEN_MFA": ("Authenticator code: ", "SOFTWARE_TOKEN_MFA_CODE"),
}

# Security.framework receives the token record through stdin, never argv or a file.
KEYCHAIN_WRITER = r"""
import Foundation
import Security
let data = FileHandle.standardInput.readDataToEndOfFile()
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: CommandLine.arguments[1],
    kSecAttrAccount as String: "tokens"]
var status = SecItemUpdate(query as CFDictionary,
    [kSecValueData as String: data] as CFDictionary)
if status == errSecItemNotFound {
    var item = query
    item[kSecValueData as String] = data
    status = SecItemAdd(item as CFDictionary, nil)
}
if status != errSecSuccess { exit(1) }
"""


def call_cognito(target: str, body: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Content-Type": "application/x-amz-json-1.1",
            "X-Amz-Target": f"AWSCognitoIdentityProviderService.{target}",
            "amz-sdk-request": "attempt=1; max=1",
            "amz-sdk-invocation-id": str(uuid.uuid4()),
            "User-Agent": USER_AGENT,
            "Accept": "*/*",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        # Never print provider bodies: they may contain account/session details.
        raise RuntimeError(
            f"WHOOP login returned HTTP {error.code}; check your credentials. "
            "If access is refused, use the official export or local BLE collection."
        ) from None
    except (urllib.error.URLError, TimeoutError):
        raise RuntimeError("WHOOP login could not connect; try again later.") from None
    except (ValueError, UnicodeError):
        raise RuntimeError("WHOOP login returned an unreadable response.") from None
    if not isinstance(result, dict):
        raise RuntimeError("WHOOP login returned an unexpected response.")
    return result


def authenticate(
    email: str,
    password: str,
    prompt: Callable[[str], str],
    call: Callable[[str, dict[str, Any]], dict[str, Any]] = call_cognito,
) -> str:
    # Intentionally empty: WHOOP's proxy supplies ClientId and SECRET_HASH.
    # Protocol source: github.com/thebriangao/totem/blob/main/src/whoop/cognito.ts
    response = call(
        "InitiateAuth",
        {
            "AuthFlow": "USER_PASSWORD_AUTH",
            "AuthParameters": {"USERNAME": email, "PASSWORD": password},
            "ClientId": "",
        },
    )
    if not response.get("AuthenticationResult"):
        challenge = response.get("ChallengeName")
        if not isinstance(challenge, str) or challenge not in CHALLENGES:
            raise RuntimeError("WHOOP requires an unsupported challenge; use its official login.")
        session = response.get("Session")
        if not isinstance(session, str) or not session:
            raise RuntimeError("WHOOP challenge is missing its session; restart login.")
        label, code_key = CHALLENGES[challenge]
        code = prompt(label).strip()
        if not code:
            raise RuntimeError("No verification code entered; restart login.")
        parameters = response.get("ChallengeParameters", {})
        username = parameters.get("USERNAME", email) if isinstance(parameters, dict) else email
        response = call(
            "RespondToAuthChallenge",
            {
                "ClientId": "",
                "ChallengeName": challenge,
                "Session": session,
                "ChallengeResponses": {"USERNAME": username, code_key: code},
            },
        )
    result = response.get("AuthenticationResult", {})
    if not isinstance(result, dict):
        raise RuntimeError("WHOOP login did not return tokens; restart login.")
    access, refresh = result.get("AccessToken"), result.get("RefreshToken")
    if not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh:
        raise RuntimeError("WHOOP login did not return both tokens; restart login.")
    if any(c in access + refresh for c in "\r\n"):
        raise RuntimeError("WHOOP login returned invalid tokens.")
    return f"WHOOP_IOS_BEARER_TOKEN={access}\nWHOOP_COGNITO_REFRESH_TOKEN={refresh}\n"


def save_keychain(record: str, service: str) -> None:
    try:
        subprocess.run(
            ["/usr/bin/swift", "-e", KEYCHAIN_WRITER, service],
            input=record,
            text=True,
            capture_output=True,
            check=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("Could not store tokens in macOS Keychain; restart login.") from None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if sys.platform != "darwin" or not sys.stdin.isatty():
        raise RuntimeError("Run this helper yourself in an interactive macOS Terminal.")
    email = input("WHOOP email: ").strip()
    if not email:
        raise RuntimeError("No email entered.")
    # Refuse getpass's echoing fallback if a controlling terminal is unavailable.
    import warnings

    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        record = authenticate(email, getpass.getpass("WHOOP password: "), getpass.getpass)
    service = os.environ.get("WHOOP_PRIVATE_API_KEYCHAIN_SERVICE", "whoop.private-ios-api")
    save_keychain(record, service)
    print("WHOOP archive tokens saved in macOS Keychain. Password and codes were not saved.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, getpass.GetPassWarning) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print("\nLogin cancelled.", file=sys.stderr)
        sys.exit(1)
