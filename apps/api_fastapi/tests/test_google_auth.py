import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-google-test-"))
from app.main import app
from app.core.rate_limit import api_rate_limiter
from app.core.store import store
from app.integrations import google_identity as google

CLIENT_ID = "123456-test.apps.googleusercontent.com"
ORIGIN = {"Origin": "https://tydes.io"}
client = TestClient(app)


@pytest.fixture(autouse=True)
def isolated_google_accounts(monkeypatch, tmp_path):
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", CLIENT_ID)
    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", "")
    monkeypatch.setattr(store, "postgres_auth", None)
    monkeypatch.setattr(store, "postgres_social", None)
    monkeypatch.setattr(store, "state_file", tmp_path / "auth.json")
    for name in ("auth_accounts", "session_tokens", "email_verification_codes", "password_reset_codes"):
        monkeypatch.setattr(store, name, {})
    monkeypatch.setattr(store, "verified_emails", set())
    monkeypatch.setattr(store, "_default_user", store._default_user.model_copy(deep=True))
    monkeypatch.setattr("app.core.store.send_verification_email", lambda *args: SimpleNamespace(configured=False, sent=False))
    google._challenges.clear()
    api_rate_limiter.clear()
    yield
    google._challenges.clear()
    api_rate_limiter.clear()


def begin():
    verifier = secrets.token_urlsafe(32)
    proof = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    result = client.post("/api/v1/auth/google/challenge", json={"verifier_hash": proof}, headers=ORIGIN)
    assert result.status_code == 200, result.text
    return result.json(), verifier


def claims(challenge, **updates):
    return {"iss": "https://accounts.google.com", "aud": CLIENT_ID, "sub": "google-subject-1",
            "email": "surfer@gmail.com", "email_verified": True,
            "nonce": challenge["nonce"], **updates}


def sign_in(monkeypatch, *, claim_updates=None, challenge=None, verifier=None, origin=ORIGIN, allow_signup=True):
    if challenge is None:
        challenge, verifier = begin()
    monkeypatch.setattr(google, "_verify_google_token", lambda *_: claims(challenge, **(claim_updates or {})))
    return client.post("/api/v1/auth/google", headers=origin, json={
        "credential": "synthetic-google-token-for-test-only", "challenge_id": challenge["challenge_id"],
        "verifier": verifier,
        "allow_signup": allow_signup,
    })


def test_google_config_is_public_identifier_only_and_disabled_by_default(monkeypatch):
    monkeypatch.delenv("GOOGLE_WEB_CLIENT_ID")
    assert client.get("/api/v1/auth/google/config").json() == {"enabled": False, "client_id": ""}
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", "sk_do-not-expose-a-secret")
    assert client.get("/api/v1/auth/google/config").json()["client_id"] == ""
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", CLIENT_ID)
    assert client.get("/api/v1/auth/google/config").json() == {"enabled": True, "client_id": CLIENT_ID}


def test_missing_signup_intent_cannot_create_an_account(monkeypatch):
    challenge, verifier = begin()
    monkeypatch.setattr(google, "_verify_google_token", lambda *_: claims(challenge))
    result = client.post("/api/v1/auth/google", headers=ORIGIN, json={
        "credential": "synthetic-google-token-for-test-only", "challenge_id": challenge["challenge_id"],
        "verifier": verifier,
    })
    assert result.status_code == 409 and not store.auth_accounts


def test_google_signup_is_verified_clean_and_passwordless(monkeypatch):
    store.user.cover_url = "https://private.example/another-users-cover"
    result = sign_in(monkeypatch)
    assert result.status_code == 200, result.text
    data = result.json()
    user = data["session"]["user"]
    assert user["email_verified"] and not user["premium"]
    assert user["cover_url"] is None and user["handle"] == "" and user["favorite_spot_ids"] == []
    assert not data["verification_required"]
    token = data["session"]["access_token"]
    assert client.get("/api/v1/users/me", headers={"Authorization": "Bearer " + token}).status_code == 200
    assert "synthetic-google-token" not in store.state_file.read_text()
    assert store.auth_accounts["surfer@gmail.com"]["password_hash"] == "!google-only"
    assert client.post("/api/v1/auth/login", json={"email": "surfer@gmail.com", "password": "!google-only"}).status_code == 400


def test_google_signin_does_not_recreate_a_deleted_account(monkeypatch):
    first = sign_in(monkeypatch).json()["session"]
    headers = {"Authorization": "Bearer " + first["access_token"]}
    monkeypatch.setattr("app.modules.auth.router.queue_account_media_deletion", lambda *_: None)
    monkeypatch.setattr(store, "postgres_planning", None)
    assert client.delete("/api/v1/auth/account", headers=headers).status_code == 200
    assert "surfer@gmail.com" not in store.auth_accounts
    assert client.get("/api/v1/users/me", headers=headers).status_code == 401
    missing = sign_in(monkeypatch, allow_signup=False)
    assert missing.status_code == 409 and "Choose Sign up" in missing.json()["detail"]
    assert "surfer@gmail.com" not in store.auth_accounts
    regular = client.post("/api/v1/auth/signup", json={
        "email": "surfer@gmail.com", "password": "replacement-long-password",
    })
    assert regular.status_code == 200, regular.text
    assert regular.json()["session"]["user"]["id"] != first["user"]["id"]


def test_explicit_google_signup_after_deletion_has_a_new_identity(monkeypatch):
    first = sign_in(monkeypatch).json()["session"]
    monkeypatch.setattr("app.modules.auth.router.queue_account_media_deletion", lambda *_: None)
    monkeypatch.setattr(store, "postgres_planning", None)
    assert client.delete("/api/v1/auth/account", headers={
        "Authorization": "Bearer " + first["access_token"],
    }).status_code == 200
    second = sign_in(monkeypatch, allow_signup=True).json()["session"]
    assert second["user"]["id"] != first["user"]["id"]
    assert not second["user"]["premium"] and second["user"]["handle"] == ""


def test_signin_mode_still_links_an_existing_verified_email(monkeypatch):
    signup = store.signup("surfer@gmail.com", "existing-long-password")
    store.verify_email("surfer@gmail.com", store.email_verification_codes["surfer@gmail.com"])
    result = sign_in(monkeypatch, allow_signup=False)
    assert result.status_code == 200, result.text
    assert result.json()["session"]["user"]["id"] == signup["session"].user.id


def test_existing_verified_account_preserves_id_password_profile_and_premium(monkeypatch):
    signup = store.signup("surfer@gmail.com", "existing-long-password")
    store.verify_email("surfer@gmail.com", store.email_verification_codes["surfer@gmail.com"])
    account = store.auth_accounts["surfer@gmail.com"]
    account["user"].update(display_name="Existing Surfer", handle="existing", admin_premium=True, premium=True)
    password_hash = account["password_hash"]
    result = sign_in(monkeypatch).json()["session"]["user"]
    assert result["id"] == signup["session"].user.id
    assert result["display_name"] == "Existing Surfer" and result["premium"]
    assert account["password_hash"] == password_hash
    assert store.login("surfer@gmail.com", password="existing-long-password").user.id == result["id"]
    assert len(store.auth_accounts) == 1


def test_unverified_existing_account_cannot_be_hijacked_or_silently_linked(monkeypatch):
    store.signup("surfer@gmail.com", "attacker-chosen-password")
    result = sign_in(monkeypatch)
    assert result.status_code == 409
    assert "google_subject" not in store.auth_accounts["surfer@gmail.com"]


def test_google_subject_survives_provider_email_change_without_changing_tydes_email(monkeypatch):
    first = sign_in(monkeypatch).json()["session"]["user"]
    second = sign_in(monkeypatch, claim_updates={"email": "different@gmail.com"}).json()["session"]["user"]
    assert second["id"] == first["id"] and second["email"] == first["email"]
    assert len(store.auth_accounts) == 1


def test_external_google_email_must_complete_tydes_verification(monkeypatch):
    result = sign_in(monkeypatch, claim_updates={"email": "surfer@example.com"}).json()
    assert result["verification_required"]
    token = result["session"]["access_token"]
    headers = {"Authorization": "Bearer " + token}
    assert client.get("/api/v1/users/me", headers=headers).status_code == 401
    code = store.email_verification_codes["surfer@example.com"]
    assert client.post("/api/v1/auth/verify-email", json={"email": "surfer@example.com", "code": code}).status_code == 200
    assert client.get("/api/v1/users/me", headers=headers).status_code == 200


def test_workspace_identity_is_authoritative(monkeypatch):
    result = sign_in(monkeypatch, claim_updates={"email": "surfer@example.com", "hd": "example.com"}).json()
    assert not result["verification_required"] and result["session"]["user"]["email_verified"]


def test_non_authoritative_email_cannot_auto_link_existing_verified_account(monkeypatch):
    store.signup("surfer@example.com", "existing-long-password")
    store.verify_email("surfer@example.com", store.email_verification_codes["surfer@example.com"])
    assert sign_in(monkeypatch, claim_updates={"email": "surfer@example.com"}).status_code == 409


@pytest.mark.parametrize("updates", [{"aud": "other-client"}, {"iss": "https://attacker.example"},
    {"nonce": "wrong-nonce"}, {"email_verified": False}, {"sub": ""}, {"email": "invalid"}])
def test_invalid_identity_never_creates_account(monkeypatch, updates):
    assert sign_in(monkeypatch, claim_updates=updates).status_code == 401
    assert not store.auth_accounts


def test_challenge_expiry_verifier_binding_and_replay(monkeypatch):
    challenge, verifier = begin()
    assert sign_in(monkeypatch, challenge=challenge, verifier="a" * 43).status_code == 401
    assert sign_in(monkeypatch, challenge=challenge, verifier=verifier).status_code == 200
    assert sign_in(monkeypatch, challenge=challenge, verifier=verifier).status_code == 401
    challenge, verifier = begin()
    google._challenges[challenge["challenge_id"]]["expires_at"] = datetime.now(timezone.utc) - timedelta(seconds=1)
    assert sign_in(monkeypatch, challenge=challenge, verifier=verifier).status_code == 401


def test_cross_site_and_missing_origin_are_rejected(monkeypatch):
    assert sign_in(monkeypatch, origin={"Origin": "https://attacker.example"}).status_code == 403
    assert sign_in(monkeypatch, origin={}).status_code == 403


def test_banned_google_account_stays_banned(monkeypatch):
    sign_in(monkeypatch)
    store.auth_accounts["surfer@gmail.com"]["user"]["banned"] = True
    assert sign_in(monkeypatch).status_code == 409


def test_challenge_rate_limit_is_enforced():
    proof = base64.urlsafe_b64encode(hashlib.sha256(b"test").digest()).decode().rstrip("=")
    for _ in range(30):
        assert client.post("/api/v1/auth/google/challenge", json={"verifier_hash": proof}, headers=ORIGIN).status_code == 200
    assert client.post("/api/v1/auth/google/challenge", json={"verifier_hash": proof}, headers=ORIGIN).status_code == 429


def test_real_signature_validation_rejects_tampering_wrong_audience_and_expiry(monkeypatch):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    from google.auth import jwt
    from google.auth.crypt import RSASigner

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = datetime.now(timezone.utc)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test signing key")])
    cert = x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(1).not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=1)).sign(key, hashes.SHA256())
    pem = cert.public_bytes(serialization.Encoding.PEM).decode()
    signer = RSASigner.from_string(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()), key_id="test-key")
    monkeypatch.setattr(google, "_google_request", lambda *args, **kwargs: SimpleNamespace(status=200, data=json.dumps({"test-key": pem}).encode()))
    payload = {"iss": "https://accounts.google.com", "aud": CLIENT_ID, "iat": int(now.timestamp()), "exp": int(now.timestamp()) + 300, "sub": "signed-subject"}
    token = jwt.encode(signer, payload).decode()
    assert google._verify_google_token(token, CLIENT_ID)["sub"] == "signed-subject"
    with pytest.raises(google.GoogleIdentityError):
        google._verify_google_token(token, "wrong-client")
    expired = jwt.encode(signer, {**payload, "iat": int(now.timestamp()) - 1000, "exp": int(now.timestamp()) - 500}).decode()
    with pytest.raises(google.GoogleIdentityError):
        google._verify_google_token(expired, CLIENT_ID)
    header, body, signature = token.split(".")
    tampered = header + "." + base64.urlsafe_b64encode(json.dumps({**payload, "sub": "attacker"}).encode()).decode().rstrip("=") + "." + signature
    with pytest.raises(google.GoogleIdentityError):
        google._verify_google_token(tampered, CLIENT_ID)
