"""Fresh authentication with one joined DB read; no live database or secrets."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import sys
import tempfile
from threading import Lock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-auth-join-"))

from app.core.postgres_auth import PostgresAuthRepository
from app.core.store import _hash_token, store


def _payload(identity="viewer", **updates):
    return {
        "id": identity, "email": f"{identity}@example.com",
        "display_name": identity, "handle": identity,
        "home_region": "Bali", "locale": "en", "surf_skill": "beginner",
        "email_verified": True, "banned": False, "premium": False,
        "ads_enabled": True, **updates,
    }


class _Rows:
    def __init__(self, row=None):
        self.row = row

    def fetchone(self):
        return self.row


class _Database:
    def __init__(self):
        self.accounts = {}
        self.sessions = {}
        self.connections = 0
        self.queries = []
        self.lock = Lock()

    def add(self, token="session", identity="viewer", **updates):
        user = _payload(identity, **updates)
        self.accounts[user["email"]] = {
            "email": user["email"], "password_hash": "synthetic-password-hash",
            "user_payload": user, "google_subject": None,
        }
        self.sessions[_hash_token(token)] = {
            "email": user["email"], "created_at": datetime.now(timezone.utc),
        }
        return user

    def connect(self):
        database = self

        class Connection:
            def __enter__(self):
                with database.lock:
                    database.connections += 1
                return self

            def __exit__(self, *_args):
                pass

            def execute(self, sql, params):
                normalized = " ".join(sql.split()).lower()
                with database.lock:
                    database.queries.append((normalized, params))
                    if normalized.startswith("select") and "from auth_session_tokens" in normalized:
                        token_hash, cutoff = params
                        session = database.sessions.get(token_hash)
                        if session is None or session["created_at"] < cutoff:
                            return _Rows()
                        if "join auth_accounts" not in normalized:
                            return _Rows({"email": session["email"]})
                        return _Rows(deepcopy(database.accounts.get(session["email"])))
                    if normalized.startswith("select") and "from auth_accounts" in normalized:
                        return _Rows(deepcopy(database.accounts.get(params[0])))
                    if normalized.startswith("delete from auth_session_tokens"):
                        session = database.sessions.get(params[0])
                        if session is not None and (len(params) == 1 or session["created_at"] < params[1]):
                            del database.sessions[params[0]]
                        return _Rows()
                    if normalized.startswith("update auth_accounts"):
                        user, email = params
                        database.accounts[email]["user_payload"] = deepcopy(user)
                        return _Rows()
                    raise AssertionError(f"Unexpected fixture SQL: {normalized}")

        return Connection()


def _repository(database):
    repository = PostgresAuthRepository.__new__(PostgresAuthRepository)
    repository._connect = database.connect
    repository._jsonb = lambda payload: payload
    return repository


@pytest.fixture
def joined_store(monkeypatch):
    database = _Database()
    repository = _repository(database)
    monkeypatch.setattr(store, "postgres_auth", repository)
    monkeypatch.setattr(store, "postgres_social", None)
    monkeypatch.setattr(store, "auth_accounts", {})
    monkeypatch.setattr(store, "session_tokens", {})
    monkeypatch.setattr(store, "_save_state", lambda: store._save_current_account_user())
    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", "")
    return database, repository


def test_valid_lookup_halves_database_connections_and_selects():
    database = _Database()
    database.add()
    repository = _repository(database)
    token_hash = _hash_token("session")
    email = repository.get_session_email(token_hash)
    baseline = repository.get_account(email)
    before = database.connections, len(database.queries)
    database.connections = 0
    database.queries.clear()
    email, account = repository.get_session_account(token_hash)
    after = database.connections, len(database.queries)
    assert account == baseline and email == "viewer@example.com"
    assert before == (2, 2) and after == (1, 1)
    sql, params = database.queries[0]
    assert "join auth_accounts as account on account.email = session.email" in sql
    assert "session.token_hash = %s and session.created_at >= %s" in sql
    assert params[0] == token_hash and params[1].tzinfo is timezone.utc
    assert abs((datetime.now(timezone.utc) - params[1]) - timedelta(days=180)) < timedelta(seconds=1)
    print("AUTH_DB_OPERATIONS before=2_connections/2_selects after=1_connection/1_select")


def test_store_uses_fresh_join_and_updates_snapshot_without_second_lookup(joined_store):
    database, _ = joined_store
    database.add()
    user = store.resolve_session_user("session")
    assert user.id == "viewer" and user.email_verified
    assert database.connections == 1 and len(database.queries) == 1
    snapshot = store.auth_accounts["viewer@example.com"]
    assert snapshot["password_hash"] == "synthetic-password-hash"
    assert snapshot["user"]["id"] == user.id
    user.favorite_spot_ids.append("must-not-mutate-account")
    assert not store.auth_accounts["viewer@example.com"]["user"].get("favorite_spot_ids")


@pytest.mark.parametrize("change", ["deleted_session", "deleted_account", "banned", "unverified"])
def test_every_resolution_rechecks_revocation_ban_and_verification(joined_store, change):
    database, _ = joined_store
    database.add()
    assert store.resolve_session_user("session").email_verified
    # Deliberately keep the old local snapshot to prove it is never authority.
    if change == "deleted_session":
        database.sessions.clear()
    elif change == "deleted_account":
        database.accounts.clear()
    else:
        database.accounts["viewer@example.com"]["user_payload"][
            "banned" if change == "banned" else "email_verified"
        ] = change == "banned"
    result = store.resolve_session_user("session")
    if change == "unverified":
        assert result is not None and not result.email_verified
    else:
        assert result is None


def test_expired_session_is_rejected_and_cleaned_on_same_connection(joined_store):
    database, _ = joined_store
    database.add()
    token_hash = _hash_token("session")
    database.sessions[token_hash]["created_at"] -= timedelta(days=181)
    assert store.resolve_session_user("session") is None
    assert token_hash not in database.sessions
    assert database.connections == 1 and len(database.queries) == 2
    sql, params = database.queries[-1]
    assert "created_at < %s" in sql and params[0] == token_hash


def test_expiry_cleanup_cannot_delete_a_concurrently_renewed_session(joined_store, monkeypatch):
    database, repository = joined_store
    database.add()
    token_hash = _hash_token("session")
    database.sessions[token_hash]["created_at"] -= timedelta(days=181)
    connect = database.connect
    renewed = False

    @contextmanager
    def renew_after_select():
        nonlocal renewed
        with connect() as connection:
            class Connection:
                def execute(self, sql, params):
                    nonlocal renewed
                    result = connection.execute(sql, params)
                    if not renewed and "JOIN auth_accounts" in sql:
                        database.sessions[token_hash]["created_at"] = datetime.now(timezone.utc)
                        renewed = True
                    return result
            yield Connection()

    monkeypatch.setattr(repository, "_connect", renew_after_select)
    assert store.resolve_session_user("session") is None
    assert token_hash in database.sessions
    assert store.resolve_session_user("session").id == "viewer"


def test_missing_session_does_not_fall_back_to_process_token_or_account(joined_store):
    database, _ = joined_store
    payload = database.add()
    assert store.resolve_session_user("session") is not None
    database.sessions.clear()
    store.session_tokens[_hash_token("session")] = payload["email"]
    assert store.resolve_session_user("session") is None


def test_current_entitlement_changes_are_applied_and_persisted_from_snapshot(joined_store):
    database, _ = joined_store
    database.add()
    assert store.resolve_session_user("session").premium is False
    payload = database.accounts["viewer@example.com"]["user_payload"]
    payload.update({
        "subscription_active": True,
        "subscription_expires_at": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(),
    })
    updated = store.resolve_session_user("session")
    assert updated.premium and not updated.ads_enabled
    assert database.accounts["viewer@example.com"]["user_payload"]["premium"] is True
    payload = database.accounts["viewer@example.com"]["user_payload"]
    payload["subscription_expires_at"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    expired = store.resolve_session_user("session")
    assert not expired.premium and expired.ads_enabled


def test_concurrent_joined_resolutions_keep_separate_users(joined_store):
    database, _ = joined_store
    for index in range(12):
        database.add(f"session-{index}", f"viewer-{index}")
    default_id = store._default_user.id
    with ThreadPoolExecutor(max_workers=6) as pool:
        users = list(pool.map(store.resolve_session_user, [f"session-{i}" for i in range(12)]))
    assert [user.id for user in users] == [f"viewer-{i}" for i in range(12)]
    assert store._default_user.id == default_id
    assert database.connections == 12 and len(database.queries) == 12


def test_database_errors_never_authorize_using_previous_snapshot(joined_store, monkeypatch):
    database, repository = joined_store
    database.add()
    assert store.resolve_session_user("session") is not None
    def unavailable():
        raise RuntimeError("fixture database offline")
    monkeypatch.setattr(repository, "_connect", unavailable)
    with pytest.raises(RuntimeError, match="database offline"):
        store.resolve_session_user("session")
