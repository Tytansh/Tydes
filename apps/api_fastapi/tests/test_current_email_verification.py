"""Current-account verification never changes identity or trusts client email."""
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-current-email-tests-"))

from app.core.current_email_verification import make_current_email_proof, matches_current_email_proof
from app.core.postgres_auth import PostgresAuthRepository
from app.core.rate_limit import api_rate_limiter
from app.core.store import DemoStore, store
from app.main import app

PREFIX = "/api/v1/auth/email-verification"


@pytest.fixture
def verification(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "")
    for name, value in {
        "state_file": tmp_path / "verification.json",
        "postgres_auth": None, "postgres_social": None, "postgres_planning": None,
        "auth_accounts": {}, "session_tokens": {}, "verified_emails": set(),
        "email_verification_codes": {}, "password_reset_codes": {},
        "_default_user": store._default_user.model_copy(deep=True),
    }.items():
        monkeypatch.setattr(store, name, value)
    api_rate_limiter.clear()
    users = {}
    headers = {}
    for name in ("alice", "bob"):
        user = store.user.model_copy(update={
            "id": f"verify-{name}", "email": f"{name}-verification@example.com",
            "handle": name, "email_verified": False, "banned": False,
            "premium": False, "admin_premium": False,
            "subscription_active": None, "ads_enabled": True,
        })
        users[name] = user
        store.auth_accounts[user.email] = {"password_hash": f"unchanged-{name}", "user": user.model_dump(mode="json")}
        headers[name] = {"Authorization": f"Bearer {store._create_session_token(user.email)}"}
    deliveries = []

    def deliver(email, code):
        deliveries.append((email, code))
        return SimpleNamespace(configured=True, sent=True)

    monkeypatch.setattr("app.core.store.send_verification_email", deliver)
    client = TestClient(app)
    yield SimpleNamespace(client=client, users=users, headers=headers, deliveries=deliveries)
    api_rate_limiter.clear()


def request_code(fixture, name="alice"):
    response = fixture.client.post(f"{PREFIX}/request", headers=fixture.headers[name], json={})
    assert response.status_code == 200
    return fixture.deliveries[-1][1]


def confirm(fixture, code, name="alice", **extra):
    return fixture.client.post(f"{PREFIX}/confirm", headers=fixture.headers[name], json={"code": code, **extra})


def test_auth_required_and_client_cannot_select_identity(verification):
    client = verification.client
    assert client.post(f"{PREFIX}/request", json={}).status_code == 401
    assert client.post(f"{PREFIX}/confirm", json={"code": "111111"}).status_code == 401
    for payload in ({"email": verification.users["bob"].email}, {"user_id": verification.users["bob"].id}):
        assert client.post(f"{PREFIX}/request", headers=verification.headers["alice"], json=payload).status_code == 422
    assert confirm(verification, "111111", email=verification.users["bob"].email).status_code == 422
    assert verification.deliveries == []


def test_delivery_and_confirmation_are_own_account_only_without_replacing_session(verification):
    before_sessions = dict(store.session_tokens)
    before_passwords = {email: account["password_hash"] for email, account in store.auth_accounts.items()}
    before_default = store._default_user.model_copy(deep=True)
    response = verification.client.post(f"{PREFIX}/request", headers=verification.headers["alice"])
    assert response.json() == {"sent": True, "verification_sent_to": verification.users["alice"].email}
    email, code = verification.deliveries[-1]
    assert email == verification.users["alice"].email
    stored = store.email_verification_codes[email]
    assert stored != code and code not in stored
    assert matches_current_email_proof(stored, verification.users["alice"].id, email, code)
    result = confirm(verification, code)
    assert result.status_code == 200
    assert result.json()["id"] == verification.users["alice"].id
    assert result.json()["email_verified"] is True
    assert "access_token" not in result.json() and "session" not in result.json()
    assert store.auth_accounts[verification.users["bob"].email]["user"]["email_verified"] is False
    assert store.session_tokens == before_sessions
    assert {email: account["password_hash"] for email, account in store.auth_accounts.items()} == before_passwords
    assert store._default_user == before_default
    assert email not in store.email_verification_codes
    profile = verification.client.get("/api/v1/users/me", headers=verification.headers["alice"]).json()
    assert profile["id"] == verification.users["alice"].id and profile["email_verified"] is True


def test_cross_account_code_cannot_verify_other_user(verification):
    code = request_code(verification)
    assert confirm(verification, code, "bob").status_code == 400
    assert store.auth_accounts[verification.users["bob"].email]["user"]["email_verified"] is False
    assert confirm(verification, code).status_code == 200


def test_raw_legacy_demo_code_and_missing_proof_are_rejected(verification):
    assert confirm(verification, "123456").status_code == 400
    store.email_verification_codes[verification.users["alice"].email] = "123456"
    assert confirm(verification, "123456").status_code == 400
    assert store.auth_accounts[verification.users["alice"].email]["user"]["email_verified"] is False


def test_wrong_expired_or_wrongly_bound_proof_is_not_consumed(verification):
    user = verification.users["alice"]
    code = request_code(verification)
    wrong_code = "000000" if code != "000000" else "999999"
    assert confirm(verification, wrong_code).status_code == 400
    assert user.email in store.email_verification_codes
    now = datetime.now(timezone.utc)
    for proof in (
        make_current_email_proof(user.id, user.email, code, now=now - timedelta(minutes=16)),
        make_current_email_proof("different-id", user.email, code),
        make_current_email_proof(user.id, "different@example.com", code),
    ):
        store.email_verification_codes[user.email] = proof
        assert confirm(verification, code).status_code == 400
        assert store.email_verification_codes[user.email] == proof


def test_resend_rotates_proof_and_only_latest_code_works(verification, monkeypatch):
    codes = iter(("111111", "222222"))
    monkeypatch.setattr("app.core.store._generate_verification_code", lambda: next(codes))
    first = request_code(verification)
    second = request_code(verification)
    assert confirm(verification, first).status_code == 400
    assert confirm(verification, second).status_code == 200


@pytest.mark.parametrize("configured,sent", [(False, False), (True, False), (False, True)])
def test_unconfigured_or_failed_mail_is_not_success_or_demo_hint(verification, monkeypatch, configured, sent):
    user = verification.users["alice"]
    previous = make_current_email_proof(user.id, user.email, "777777")
    store.email_verification_codes[user.email] = previous
    monkeypatch.setattr("app.core.store.send_verification_email", lambda *_: SimpleNamespace(configured=configured, sent=sent, error="private-provider-details"))
    result = verification.client.post(f"{PREFIX}/request", headers=verification.headers["alice"], json={})
    assert result.status_code == 503
    assert set(result.json()) == {"detail"}
    assert "private-provider-details" not in result.text and "hint" not in result.text
    assert store.email_verification_codes[user.email] == previous


def test_request_and_confirm_account_limits(verification):
    for _ in range(3):
        request_code(verification)
    blocked = verification.client.post(f"{PREFIX}/request", headers=verification.headers["alice"], json={})
    assert blocked.status_code == 429 and "retry-after" in blocked.headers
    assert len(verification.deliveries) == 3
    for _ in range(10):
        assert confirm(verification, "999999", "bob").status_code == 400
    assert confirm(verification, "999999", "bob").status_code == 429


def test_already_verified_is_idempotent_and_does_not_send_again(verification):
    code = request_code(verification)
    assert confirm(verification, code).status_code == 200
    request = verification.client.post(f"{PREFIX}/request", headers=verification.headers["alice"], json={})
    assert request.json() == {"sent": False, "already_verified": True, "verification_sent_to": verification.users["alice"].email}
    assert len(verification.deliveries) == 1
    assert confirm(verification, "000000").json()["id"] == verification.users["alice"].id
    assert verification.users["alice"].email not in store.email_verification_codes


def test_proof_is_durable_and_loaded_after_json_restart(verification):
    code = request_code(verification)
    user = verification.users["alice"]
    payload = json.loads(store.state_file.read_text())
    assert matches_current_email_proof(payload["email_verification_codes"][user.email], user.id, user.email, code)
    restored = DemoStore.__new__(DemoStore)
    restored.__dict__.update(store.__dict__)
    restored.email_verification_codes = {}
    restored._load_state()
    assert matches_current_email_proof(restored.email_verification_codes[user.email], user.id, user.email, code)


def test_persistence_failure_does_not_claim_sent_or_verified(verification, monkeypatch):
    code = request_code(verification)
    user = verification.users["alice"]
    proof = store.email_verification_codes[user.email]
    before = deepcopy(store.auth_accounts)
    before_verified = set(store.verified_emails)

    def failed_save():
        raise OSError("private-storage-path")

    monkeypatch.setattr(store, "_save_state", failed_save)
    sent = verification.client.post(f"{PREFIX}/request", headers=verification.headers["alice"], json={})
    assert sent.status_code == 503 and "private-storage-path" not in sent.text
    assert store.email_verification_codes[user.email] == proof
    result = confirm(verification, code)
    assert result.status_code == 503 and "private-storage-path" not in result.text
    assert store.auth_accounts == before
    assert store.verified_emails == before_verified
    assert store.email_verification_codes[user.email] == proof


class VerificationSqlConnection:
    def __init__(self, user, proof):
        self.user = user
        self.proof = proof
        self.calls = []
        self.in_transaction = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    @contextmanager
    def transaction(self):
        self.in_transaction = True
        try:
            yield
        finally:
            self.in_transaction = False

    def execute(self, query, parameters=()):
        assert self.in_transaction
        self.calls.append((query, parameters))
        row = None
        if "SELECT user_payload" in query:
            row = {"user_payload": self.user.model_dump(mode="json")}
        elif "SELECT code" in query:
            row = {"code": self.proof} if self.proof is not None else None
        elif query.startswith("UPDATE auth_accounts"):
            self.user = self.user.model_validate(parameters[0])
        elif query.startswith("DELETE FROM auth_email_verification_codes"):
            self.proof = None
        return SimpleNamespace(fetchone=lambda: row)


def sql_repository(user, proof):
    connection = VerificationSqlConnection(user, proof)
    repository = PostgresAuthRepository.__new__(PostgresAuthRepository)
    repository._connect = lambda: connection
    repository._jsonb = lambda payload: payload
    return repository, connection


def test_postgres_confirmation_locks_consumes_and_verifies_same_account_atomically(verification):
    user = verification.users["alice"]
    repository, connection = sql_repository(user, make_current_email_proof(user.id, user.email, "111111"))
    result = repository.verify_current_account_email(user.id, user.email, "111111")
    assert result.id == user.id and result.email_verified is True
    queries = [query for query, _ in connection.calls]
    assert "FOR UPDATE" in queries[0] and "FOR UPDATE" in queries[1]
    assert connection.calls[0][1] == (user.email,)
    assert connection.calls[1][1] == (user.email,)
    assert connection.proof is None and connection.user.email_verified is True
    assert any("INSERT INTO auth_verified_emails" in query for query in queries)
    assert queries[-1].startswith("DELETE FROM auth_email_verification_codes")
    connection.calls.clear()
    assert repository.verify_current_account_email(user.id, user.email, "000000").email_verified is True
    assert len(connection.calls) == 1  # Already verified: no reusable proof or mutation.


def test_postgres_wrong_account_code_or_expiry_cannot_mutate_or_consume(verification):
    user = verification.users["alice"]
    for requested_id, proof, code in (
        ("different-id", make_current_email_proof(user.id, user.email, "111111"), "111111"),
        (user.id, make_current_email_proof(user.id, user.email, "111111"), "222222"),
        (user.id, make_current_email_proof(user.id, user.email, "111111", now=datetime.now(timezone.utc) - timedelta(minutes=16)), "111111"),
        (user.id, "123456", "123456"),
    ):
        repository, connection = sql_repository(user, proof)
        with pytest.raises(ValueError):
            repository.verify_current_account_email(requested_id, user.email, code)
        assert connection.proof == proof and connection.user.email_verified is False
        assert all(query.startswith("SELECT") for query, _ in connection.calls)
