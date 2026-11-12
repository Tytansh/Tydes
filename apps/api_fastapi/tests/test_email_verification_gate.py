"""An unverified identity can recover its account, but cannot use private APIs."""
from copy import deepcopy
import hashlib
import hmac
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace

import pytest
from fastapi import HTTPException, Request
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-verification-gate-tests-"))

from app.core.auth import require_authenticated_user, require_signed_in_user
from app.core.rate_limit import api_rate_limiter
from app.core.store import store
from app.main import app


@pytest.fixture
def gate(tmp_path, monkeypatch):
    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", "")
    monkeypatch.setenv("DATABASE_URL", "")
    for name, value in {
        "state_file": tmp_path / "gate.json",
        "postgres_auth": None, "postgres_social": None, "postgres_planning": None,
        "auth_accounts": {}, "session_tokens": {}, "verified_emails": set(),
        "email_verification_codes": {}, "password_reset_codes": {},
        "_default_user": store._default_user.model_copy(deep=True),
    }.items():
        monkeypatch.setattr(store, name, value)
    user = store.user.model_copy(update={
        "id": "usr_unverified-gate", "email": "gate@example.com", "handle": "gate",
        "email_verified": False, "banned": False, "premium": False,
        "admin_premium": False, "subscription_active": None, "ads_enabled": True,
    })
    store.auth_accounts[user.email] = {"password_hash": "unchanged-password", "user": user.model_dump(mode="json")}
    token = store._create_session_token(user.email)
    deliveries = []

    def deliver(email, code):
        deliveries.append((email, code))
        return SimpleNamespace(configured=True, sent=True)

    monkeypatch.setattr("app.core.store.send_verification_email", deliver)
    api_rate_limiter.clear()
    yield SimpleNamespace(client=TestClient(app), user=user, token=token,
                          headers={"Authorization": f"Bearer {token}"}, deliveries=deliveries)
    api_rate_limiter.clear()


PRIVATE_REQUESTS = [
    ("GET", "/api/v1/users/dashboard"),
    ("PUT", "/api/v1/users/me"),
    ("GET", "/api/v1/users/favorites"),
    ("POST", "/api/v1/users/favorites"),
    ("POST", "/api/v1/users/free-live-spot"),
    ("GET", "/api/v1/spots"),  # No auth dependency: middleware must still gate maps.
    ("GET", "/api/v1/spots/uluwatu"),
    ("GET", "/api/v1/forecasts?spot_id=uluwatu"),
    ("GET", "/api/v1/forecasts/detail?spot_id=uluwatu"),
    ("GET", "/api/v1/forecasts/tides?spot_id=uluwatu"),
    ("GET", "/api/v1/forecasts/surf-window?spot_id=uluwatu"),
    ("GET", "/api/v1/forecasts/next-swell"),
    ("GET", "/api/v1/social/friends"),
    ("GET", "/api/v1/social/posts"),
    ("GET", "/api/v1/social/posts/deep-linked-post"),
    ("GET", "/api/v1/social/profiles?handle=gate"),
    ("GET", "/api/v1/social/events"),
    ("GET", "/api/v1/social/posts/deep-linked-event/chat"),
    ("POST", "/api/v1/social/posts"),
    ("POST", "/api/v1/social/posts/post/likes"),
    ("POST", "/api/v1/social/comments"),
    ("POST", "/api/v1/social/follows/other-user"),
    ("POST", "/api/v1/social/notifications/read"),
    ("POST", "/api/v1/social/media/uploads"),
    ("GET", "/api/v1/messages/threads"),
    ("POST", "/api/v1/messages/threads"),
    ("GET", "/api/v1/trips"),
    ("POST", "/api/v1/trips"),
    ("GET", "/api/v1/alerts"),
    ("POST", "/api/v1/alerts"),
    ("PATCH", "/api/v1/alerts/other-alert"),
    ("DELETE", "/api/v1/alerts/other-alert"),
    ("GET", "/api/v1/billing/plans"),
    ("GET", "/api/v1/billing/config"),
    ("GET", "/api/v1/billing/management"),
    ("POST", "/api/v1/billing/sync-revenuecat"),
    ("GET", "/api/v1/ads"),
    ("GET", "/api/v1/admin/users"),
    ("PATCH", "/api/v1/admin/dashboard/users/other-user"),
    ("POST", "/api/v1/auth/future-private-route"),
    ("GET", "/api/v1/billing/webhooks/revenuecat"),  # Exact method, not a prefix exemption.
    ("POST", "/api/v1/billing/webhooks/revenuecat/other"),
]


@pytest.mark.parametrize("method,path", PRIVATE_REQUESTS)
def test_unverified_session_is_blocked_before_reads_validation_or_mutation(gate, method, path):
    before = deepcopy({name: getattr(store, name) for name in (
        "auth_accounts", "session_tokens", "posts", "comments", "trips", "alerts",
        "email_verification_codes", "social_notifications", "billing_webhook_receipts",
    )})
    response = gate.client.request(method, path, headers=gate.headers, json={})
    assert response.status_code == 403, response.text
    assert response.json()["detail"]["code"] == "email_verification_required"
    assert response.headers["cache-control"] == "private, no-store"
    assert "www-authenticate" not in response.headers
    assert {name: getattr(store, name) for name in before} == before
    assert gate.deliveries == []
    assert store.resolve_session_user(gate.token).id == gate.user.id


@pytest.mark.parametrize("method,path", PRIVATE_REQUESTS)
def test_stripping_or_invalidating_bearer_cannot_bypass_private_gate(gate, method, path):
    for headers in ({}, {"Authorization": "Bearer invalid"}):
        result = gate.client.request(method, path, headers=headers, json={})
        assert result.status_code == 401
        assert result.json() == {"detail": "Sign in required"}
    assert gate.deliveries == []


def test_bootstrap_and_current_email_proof_unlock_same_valid_session(gate, monkeypatch):
    async def no_billing_refresh(_user):
        pytest.fail("Unverified bootstrap must not refresh paid entitlements")

    monkeypatch.setattr("app.modules.users.router.refresh_subscription_if_stale", no_billing_refresh)
    response = gate.client.get("/api/v1/users/me", headers=gate.headers)
    assert response.status_code == 200
    assert response.json()["id"] == gate.user.id
    assert response.json()["email_verified"] is False
    before_sessions = dict(store.session_tokens)
    result = gate.client.post("/api/v1/auth/email-verification/request", headers=gate.headers, json={})
    assert result.status_code == 200
    assert len(gate.deliveries) == 1
    email, code = gate.deliveries[0]
    assert email == gate.user.email and len(code) == 6 and code.isdigit()
    confirmed = gate.client.post("/api/v1/auth/email-verification/confirm", headers=gate.headers, json={"code": code})
    assert confirmed.status_code == 200 and confirmed.json()["email_verified"] is True
    assert store.session_tokens == before_sessions
    assert gate.client.get("/api/v1/users/dashboard", headers=gate.headers).status_code == 200
    assert gate.client.get("/api/v1/spots", headers=gate.headers).status_code == 200
    assert len(gate.deliveries) == 1


def test_unverified_google_identity_can_bootstrap_and_verify(gate):
    store.auth_accounts[gate.user.email]["google_subject"] = "external-domain-google-subject"
    assert store.resolve_session_user(gate.token).email_verified is False
    assert gate.client.get("/api/v1/users/me", headers=gate.headers).status_code == 200
    assert gate.client.get("/api/v1/trips", headers=gate.headers).status_code == 403
    assert gate.client.post("/api/v1/auth/email-verification/request", headers=gate.headers, json={}).status_code == 200
    code = gate.deliveries[0][1]
    assert gate.client.post("/api/v1/auth/email-verification/confirm", headers=gate.headers, json={"code": code}).status_code == 200
    assert gate.client.get("/api/v1/trips", headers=gate.headers).status_code == 200


def test_premium_and_admin_flags_never_bypass_email_verification(gate, monkeypatch):
    monkeypatch.setenv("TYDES_ADMIN_EMAILS", gate.user.email)
    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", gate.user.email)
    store.auth_accounts[gate.user.email]["user"]["admin_premium"] = True
    for path in ("/api/v1/billing/config", "/api/v1/admin/users", "/api/v1/social/posts"):
        result = gate.client.get(path, headers=gate.headers)
        assert result.status_code == 403
        assert result.json()["detail"]["code"] == "email_verification_required"


def test_dependency_requires_verified_user_but_recovery_requires_only_identity(gate):
    request = Request({"type": "http", "state": {"user": gate.user}})
    assert require_signed_in_user(request).id == gate.user.id
    with pytest.raises(HTTPException) as failure:
        require_authenticated_user(request)
    assert failure.value.status_code == 403
    assert failure.value.detail["code"] == "email_verification_required"
    request.state.user = gate.user.model_copy(update={"email_verified": True})
    assert require_authenticated_user(request).email_verified is True
    request.state.user = None
    with pytest.raises(HTTPException) as missing:
        require_signed_in_user(request)
    assert missing.value.status_code == 401


def test_public_guest_health_options_and_auth_entry_behavior_are_unchanged(gate):
    for path in ("/api/v1/public/spots", "/api/v1/public/events", "/health", "/health/ready", "/api/v1/auth/google/config"):
        anonymous = gate.client.get(path)
        signed_in = gate.client.get(path, headers=gate.headers)
        assert anonymous.status_code == signed_in.status_code == 200
        assert anonymous.json() == signed_in.json()
    assert gate.client.get("/api/v1/spots").status_code == 401
    assert gate.client.get("/api/v1/users/dashboard").status_code == 401
    assert gate.client.get("/api/v1/users/me", headers={"Authorization": "Bearer invalid"}).status_code == 401
    preflight = gate.client.options("/api/v1/trips", headers={**gate.headers, "Origin": "https://tydes.io", "Access-Control-Request-Method": "POST"})
    assert preflight.status_code == 200
    for path in ("/api/v1/auth/login", "/api/v1/auth/signup", "/api/v1/auth/google/challenge", "/api/v1/auth/google", "/api/v1/auth/verify-email", "/api/v1/auth/password-reset/request", "/api/v1/auth/password-reset/confirm", "/api/v1/auth/waitlist"):
        assert gate.client.post(path, headers=gate.headers, json={}).status_code == 422
    blocked = gate.client.get("/api/v1/trips", headers={**gate.headers, "Origin": "https://tydes.io"})
    assert blocked.status_code == 403 and "access-control-allow-origin" in blocked.headers
    assert blocked.headers["x-content-type-options"] == "nosniff"


def test_exact_provider_webhook_keeps_its_own_authentication(gate, monkeypatch):
    monkeypatch.setenv("REVENUECAT_WEBHOOK_AUTHORIZATION", "")
    monkeypatch.setenv("REVENUECAT_WEBHOOK_SIGNING_SECRET", "unit-test-webhook-signing-secret")
    body = json.dumps({"event": {"id": "gate-webhook", "type": "TEST"}}).encode()
    timestamp = str(int(time.time()))
    signature = hmac.new(b"unit-test-webhook-signing-secret", timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    path = "/api/v1/billing/webhooks/revenuecat"
    # An unverified session cannot substitute for provider authentication.
    assert gate.client.post(path, headers=gate.headers, content=body).status_code == 401
    signed = {"X-RevenueCat-Webhook-Signature": f"t={timestamp},v1={signature}"}
    for headers in (signed, {**signed, **gate.headers}):
        result = gate.client.post(path, headers=headers, content=body)
        assert result.status_code == 200 and result.json() == {"status": "test_received"}


@pytest.mark.parametrize("method,path", [("POST", "/api/v1/auth/logout"), ("DELETE", "/api/v1/auth/account")])
def test_unverified_user_can_leave_or_delete_account(gate, monkeypatch, method, path):
    queued = []
    monkeypatch.setattr("app.modules.auth.router.queue_account_media_deletion", queued.append)
    result = gate.client.request(method, path, headers=gate.headers)
    assert result.status_code == 200, result.text
    assert gate.deliveries == []
    if method == "DELETE":
        assert queued == [gate.user.id]
        assert store.resolve_session_user(gate.token) is None


def test_initial_signup_email_is_usable_by_current_user_confirm_without_resend(gate):
    email = "initial-signup@example.com"
    result = gate.client.post("/api/v1/auth/signup", json={"email": email, "password": "longboard123"})
    assert result.status_code == 200, result.text
    payload = result.json()
    assert payload["verification_required"] is True and payload["verification_hint"] is None
    assert len(gate.deliveries) == 1
    delivered_email, code = gate.deliveries[0]
    assert delivered_email == email and len(code) == 6 and code.isdigit()
    assert code not in result.text and store.email_verification_codes[email] != code
    token = payload["session"]["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    assert gate.client.get("/api/v1/users/me", headers=headers).json()["email_verified"] is False
    assert gate.client.get("/api/v1/trips", headers=headers).status_code == 403
    before_sessions = dict(store.session_tokens)
    confirmed = gate.client.post("/api/v1/auth/email-verification/confirm", headers=headers, json={"code": code})
    assert confirmed.status_code == 200
    assert confirmed.json()["id"] == payload["session"]["user"]["id"]
    assert confirmed.json()["email_verified"] is True
    assert store.session_tokens == before_sessions and len(gate.deliveries) == 1
    assert gate.client.get("/api/v1/trips", headers=headers).status_code == 200


def test_initial_external_google_email_uses_same_current_account_proof(gate, monkeypatch):
    monkeypatch.setattr("app.modules.auth.router.verify_google_login", lambda *_: SimpleNamespace(
        email="initial-google@example.com", subject="initial-google-subject", authoritative_email=False,
    ))
    result = gate.client.post("/api/v1/auth/google", headers={"Origin": "https://tydes.io"}, json={
        "credential": "synthetic-google-credential", "challenge_id": "c" * 43,
        "verifier": "v" * 43, "allow_signup": True,
    })
    assert result.status_code == 200, result.text
    payload = result.json()
    assert payload["verification_required"] and payload["verification_hint"] is None
    assert len(gate.deliveries) == 1
    code = gate.deliveries[0][1]
    headers = {"Authorization": f"Bearer {payload['session']['access_token']}"}
    assert gate.client.get("/api/v1/users/me", headers=headers).json()["email_verified"] is False
    assert gate.client.get("/api/v1/social/posts", headers=headers).status_code == 403
    confirmed = gate.client.post("/api/v1/auth/email-verification/confirm", headers=headers, json={"code": code})
    assert confirmed.status_code == 200 and confirmed.json()["email_verified"] is True
    assert gate.client.get("/api/v1/social/posts", headers=headers).status_code == 200
    assert len(gate.deliveries) == 1


def test_authoritative_google_email_needs_no_additional_tydes_email(gate, monkeypatch):
    monkeypatch.setattr("app.modules.auth.router.verify_google_login", lambda *_: SimpleNamespace(
        email="already-verified@gmail.com", subject="authoritative-google-subject", authoritative_email=True,
    ))
    result = gate.client.post("/api/v1/auth/google", headers={"Origin": "https://tydes.io"}, json={
        "credential": "synthetic-google-credential", "challenge_id": "c" * 43,
        "verifier": "v" * 43, "allow_signup": True,
    })
    assert result.status_code == 200, result.text
    payload = result.json()
    assert payload["verification_required"] is False
    assert payload["session"]["user"]["email_verified"] is True
    headers = {"Authorization": f"Bearer {payload['session']['access_token']}"}
    assert gate.client.get("/api/v1/spots", headers=headers).status_code == 200
    assert gate.deliveries == []
    assert "already-verified@gmail.com" not in store.email_verification_codes


@pytest.mark.parametrize("email", ["missing@example.com", "demo@surftravel.app", "premium@example.com"])
@pytest.mark.parametrize("password", [None, "wrongpassword"])
def test_unknown_accounts_never_receive_demo_or_premium_verified_sessions(gate, monkeypatch, email, password):
    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", "premium@example.com")
    before_sessions = dict(store.session_tokens)
    result = gate.client.post("/api/v1/auth/login", json={"email": email, "password": password})
    assert result.status_code == 400
    assert "access_token" not in result.text
    assert store.session_tokens == before_sessions


@pytest.mark.parametrize("configured,sent", [(False, False), (False, True), (True, False)])
def test_auth_email_delivery_fails_closed_without_disclosing_codes(gate, monkeypatch, configured, sent):
    failed = lambda *_: SimpleNamespace(configured=configured, sent=sent, error="private-provider-details")
    monkeypatch.setattr("app.core.store.send_verification_email", failed)
    monkeypatch.setattr("app.core.store.send_password_reset_email", failed)
    before_sessions = dict(store.session_tokens)
    for path, payload in (
        ("/api/v1/auth/signup", {"email": "delivery-failure@example.com", "password": "longboard123"}),
        ("/api/v1/auth/password-reset/request", {"email": gate.user.email}),
    ):
        result = gate.client.post(path, json=payload)
        assert result.status_code == 502
        assert "hint" not in result.text and "private-provider-details" not in result.text
    assert "delivery-failure@example.com" not in store.auth_accounts
    assert store.session_tokens == before_sessions
    assert gate.user.email not in store.password_reset_codes


def test_legacy_verification_rejects_missing_raw_and_expired_codes(gate):
    from datetime import datetime, timedelta, timezone
    from app.core.current_email_verification import make_current_email_proof
    email = gate.user.email
    for stored in (None, "123456", make_current_email_proof(gate.user.id, email, "123456", now=datetime.now(timezone.utc) - timedelta(minutes=16))):
        if stored is None:
            store.email_verification_codes.pop(email, None)
        else:
            store.email_verification_codes[email] = stored
        result = gate.client.post("/api/v1/auth/verify-email", json={"email": email, "code": "123456"})
        assert result.status_code == 400
        assert not store.auth_accounts[email]["user"]["email_verified"]
    assert gate.client.post("/api/v1/auth/email-verification/request", headers=gate.headers, json={}).status_code == 200
    code = gate.deliveries[0][1]
    result = gate.client.post("/api/v1/auth/verify-email", json={"email": email, "code": code})
    assert result.status_code == 200 and result.json()["email_verified"] is True
    for replay in (code, "000000"):
        result = gate.client.post("/api/v1/auth/verify-email", json={"email": email, "code": replay})
        assert result.status_code == 400 and gate.user.id not in result.text


@pytest.mark.parametrize("path", [
    "/api/v1/spots", "/api/v1/spots?region=Bali", "/api/v1/social/posts",
    "/api/v1/trips", "/api/v1/alerts", "/api/v1/billing/plans",
])
def test_verified_private_successes_are_never_shared_cacheable(gate, path):
    store.auth_accounts[gate.user.email]["user"]["email_verified"] = True
    for candidate in (path, f"/api/v1/spots/{store.spots[0].id}"):
        result = gate.client.get(candidate, headers=gate.headers)
        assert result.status_code == 200, result.text
        assert result.headers["cache-control"] == "private, no-store"
        assert "etag" not in result.headers


def test_private_cache_override_removes_validators_and_proxy_cache_directives(gate, monkeypatch):
    from fastapi.responses import JSONResponse
    store.auth_accounts[gate.user.email]["user"]["email_verified"] = True
    route = next(route for route in app.routes if getattr(route, "path", None) == "/api/v1/spots")

    async def cacheable_endpoint(scope, receive, send):
        await JSONResponse({"private": "verified content"}, headers={
            "Cache-Control": "public, max-age=31536000",
            "ETag": '"private-response"', "Last-Modified": "Thu, 01 Jan 2026 00:00:00 GMT",
            "Expires": "Thu, 01 Jan 2027 00:00:00 GMT",
            "CDN-Cache-Control": "public, max-age=31536000",
            "Cloudflare-CDN-Cache-Control": "public, max-age=31536000",
            "Surrogate-Control": "max-age=31536000",
        })(scope, receive, send)

    monkeypatch.setattr(route, "app", cacheable_endpoint)
    response = gate.client.get("/api/v1/spots", headers=gate.headers)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "private, no-store"
    for header in ("ETag", "Last-Modified", "Expires", "CDN-Cache-Control", "Cloudflare-CDN-Cache-Control", "Surrogate-Control"):
        assert header not in response.headers


@pytest.mark.parametrize("verified", [False, True])
def test_bootstrap_successes_and_failures_are_private_no_store(gate, monkeypatch, verified):
    async def unchanged_user(user):
        return user

    monkeypatch.setattr("app.modules.users.router.refresh_subscription_if_stale", unchanged_user)
    store.auth_accounts[gate.user.email]["user"]["email_verified"] = verified
    for headers, status in ((gate.headers, 200), ({}, 401)):
        result = gate.client.get("/api/v1/users/me", headers=headers)
        assert result.status_code == status
        assert result.headers["cache-control"] == "private, no-store"


def test_auth_token_profile_and_error_responses_are_private_no_store(gate, monkeypatch):
    monkeypatch.setattr("app.core.store.send_password_reset_email", lambda *_: SimpleNamespace(configured=True, sent=True))
    email = "uncacheable-auth@example.com"
    signup = gate.client.post("/api/v1/auth/signup", json={"email": email, "password": "longboard123"})
    assert signup.status_code == 200
    headers = {"Authorization": f"Bearer {signup.json()['session']['access_token']}"}
    confirm = gate.client.post("/api/v1/auth/email-verification/confirm", headers=headers, json={"code": gate.deliveries[0][1]})
    login = gate.client.post("/api/v1/auth/login", json={"email": email, "password": "longboard123"})
    reset = gate.client.post("/api/v1/auth/password-reset/request", json={"email": email})
    google_config = gate.client.get("/api/v1/auth/google/config")
    invalid = gate.client.post("/api/v1/auth/login", json={})
    for response in (signup, confirm, login, reset, google_config, invalid):
        assert response.status_code in {200, 422}, response.text
        assert response.headers["cache-control"] == "private, no-store"
        assert "etag" not in response.headers


def test_sanitized_public_guides_keep_their_intended_shared_cache(gate):
    for path in ("/api/v1/public/spots", f"/api/v1/public/spots/{store.spots[0].id}"):
        for headers in ({}, gate.headers):
            result = gate.client.get(path, headers=headers)
            assert result.status_code == 200
            assert result.headers["cache-control"] == "public, max-age=3600"
    assert gate.client.get("/api/v1/public/events").headers["cache-control"] == "no-store"
