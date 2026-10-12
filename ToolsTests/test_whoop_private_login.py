from typing import Any

import pytest
from whoop_private_login import CHALLENGES, authenticate, save_keychain


@pytest.mark.parametrize("challenge", list(CHALLENGES))
def test_login_preserves_session_and_uses_challenge_username(challenge: str) -> None:
    calls: list[tuple[str, dict[str, Any]]] = []

    def call(target: str, body: dict[str, Any]) -> dict[str, Any]:
        calls.append((target, body))
        if target == "InitiateAuth":
            return {
                "ChallengeName": challenge,
                "Session": "synthetic-session",
                "ChallengeParameters": {"USERNAME": "synthetic-canonical-user"},
            }
        return {
            "AuthenticationResult": {"AccessToken": "synthetic-a", "RefreshToken": "synthetic-r"}
        }

    record = authenticate("user@example.invalid", "synthetic-password#", lambda _: "123456", call)
    assert record == "WHOOP_IOS_BEARER_TOKEN=synthetic-a\nWHOOP_COGNITO_REFRESH_TOKEN=synthetic-r\n"
    assert calls[0][1]["AuthParameters"]["PASSWORD"] == "synthetic-password#"
    assert calls[1] == (
        "RespondToAuthChallenge",
        {
            "ClientId": "",
            "ChallengeName": challenge,
            "Session": "synthetic-session",
            "ChallengeResponses": {
                "USERNAME": "synthetic-canonical-user",
                CHALLENGES[challenge][1]: "123456",
            },
        },
    )
    assert calls[0][1]["ClientId"] == ""


def test_no_challenge_does_not_prompt() -> None:
    def prompt(_: str) -> str:
        pytest.fail("Unnecessary verification prompt")

    record = authenticate(
        "user@example.invalid",
        "synthetic-password",
        prompt,
        lambda *_: {
            "AuthenticationResult": {"AccessToken": "synthetic-a", "RefreshToken": "synthetic-r"}
        },
    )
    assert "synthetic-r" in record


@pytest.mark.parametrize(
    "response",
    [
        {"ChallengeName": "NEW_PASSWORD_REQUIRED"},
        {"ChallengeName": "EMAIL_OTP"},
        {"AuthenticationResult": {"AccessToken": "synthetic-a"}},
        {"AuthenticationResult": {"AccessToken": "synthetic-a\n", "RefreshToken": "synthetic-r"}},
        {"AuthenticationResult": "synthetic-invalid-secret"},
    ],
)
def test_failures_do_not_disclose_response(response: dict[str, Any]) -> None:
    with pytest.raises(RuntimeError) as error:
        authenticate(
            "user@example.invalid", "synthetic-password", lambda _: "123456", lambda *_: response
        )
    assert "synthetic" not in str(error.value)


def test_keychain_writer_passes_tokens_only_on_stdin(monkeypatch: pytest.MonkeyPatch) -> None:
    def run(args: list[str], **kwargs: Any) -> None:
        assert all("synthetic-secret" not in arg for arg in args)
        assert kwargs["input"] == "synthetic-secret"
        assert kwargs["capture_output"] is True
        assert kwargs["check"] is True

    monkeypatch.setattr("whoop_private_login.subprocess.run", run)
    save_keychain("synthetic-secret", "synthetic-test-service")
