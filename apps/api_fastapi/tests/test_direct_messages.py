"""Real two-account delivery and privacy without any external services."""
from copy import deepcopy
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

import pytest
from fastapi import HTTPException, Request
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-dm-tests-"))

from app.core.auth import require_authenticated_user
from app.core.direct_messages import (
    DirectMessageService, JsonDirectMessageRepository,
    PostgresDirectMessageRepository, get_direct_message_service,
)
from app.core.models import build_seed
from app.core.rate_limit import api_rate_limiter
from app.core.store import store
from app.main import app


class Accounts:
    postgres_social = None

    def __init__(self):
        original = build_seed()["user"]
        self.users = {
            name: original.model_copy(update={
                "id": name, "handle": name, "display_name": name.title(),
                "email": f"{name}@example.invalid", "email_verified": True,
                "banned": False,
            }) for name in ["alice", "bob", "carol"]
        }
        self.relationships = {name: {"followed_user_ids": [], "blocked_user_ids": []} for name in self.users}
        self.posts = {}

    def get_auth_user_by_id(self, user_id):
        return self.users.get(user_id)

    def relationships_for_user(self, user_id):
        return self.relationships[user_id]

    def get_visible_post(self, post_id, user_id):
        return self.posts.get((post_id, user_id))


@pytest.fixture
def fixture(tmp_path):
    accounts = Accounts()
    repository = JsonDirectMessageRepository(tmp_path / "messages.json")
    service = DirectMessageService(accounts, repository)
    api_rate_limiter.clear()
    yield accounts, repository, service
    api_rate_limiter.clear()


@pytest.fixture
def api(fixture, monkeypatch):
    accounts, _, service = fixture
    # The global private-route middleware resolves identity before dependency
    # overrides. These local fixture tokens represent explicitly verified users.
    monkeypatch.setattr(store, "resolve_session_user", accounts.users.get)
    previous = dict(app.dependency_overrides)

    def viewer(request: Request):
        name = request.headers.get("authorization", "").removeprefix("Bearer ")
        if name not in accounts.users:
            raise HTTPException(status_code=401, detail="Sign in required")
        return accounts.users[name]

    app.dependency_overrides[require_authenticated_user] = viewer
    app.dependency_overrides[get_direct_message_service] = lambda: service
    try:
        yield TestClient(app), accounts, service
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(previous)


def auth(name):
    return {"Authorization": f"Bearer {name}"}


def send(service, user, thread, number=1, text="Hello from another account"):
    return service.send(user, thread, text, f"client-{number}", None)


def test_two_accounts_deliver_to_recipient_and_persist_across_restart(fixture):
    accounts, repository, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)
    assert thread["request_accepted"] is True
    assert service.list_threads(bob)["threads"] == []  # Empty drafts are private.
    sent = send(service, alice, thread["id"])
    restarted = DirectMessageService(accounts, JsonDirectMessageRepository(repository.path))
    incoming = restarted.list_threads(bob)["threads"]
    assert len(incoming) == 1
    assert incoming[0]["peer_user_id"] == alice.id
    assert incoming[0]["request_accepted"] is False
    assert incoming[0]["unread_count"] == 1
    body = restarted.get_thread(bob, thread["id"])["messages"][0]
    assert body["id"] == sent["id"]
    assert body["sender_user_id"] == alice.id
    assert body["text"] == "Hello from another account"
    assert restarted.unread_count(alice) == {"user_id": "alice", "unread_count": 0}


def test_counts_are_messages_not_threads_and_read_marker_keeps_newer_arrival(fixture):
    accounts, _, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    messages = [send(service, alice, thread, i) for i in range(12)]
    assert service.unread_count(bob) == {"user_id": "bob", "unread_count": 12}
    assert service.mark_read(bob, thread, messages[0]["id"])["unread_count"] == 11
    latest = send(service, alice, thread, 13)
    assert service.mark_read(bob, thread, messages[-1]["id"])["unread_count"] == 1
    assert service.mark_read(bob, thread, messages[0]["id"])["unread_count"] == 1
    assert service.mark_read(bob, thread, latest["id"])["unread_count"] == 0
    assert service.unread_count(bob)["unread_count"] == 0


def test_third_account_cannot_read_send_mutate_or_mark_other_conversation(fixture):
    accounts, _, service = fixture
    alice, bob, carol = [accounts.users[name] for name in ["alice", "bob", "carol"]]
    thread = service.create_thread(alice, bob.id)["id"]
    message = send(service, alice, thread)
    operations = [
        lambda: service.get_thread(carol, thread),
        lambda: service.send(carol, thread, "intrusion", "evil", None),
        lambda: service.mark_read(carol, thread, message["id"]),
        lambda: service.set_request(carol, thread, True, None),
    ]
    for operation in operations:
        with pytest.raises(HTTPException) as error:
            operation()
        assert error.value.status_code == 404
    assert service.list_threads(carol) == {"user_id": "carol", "threads": []}
    assert service.unread_count(carol)["unread_count"] == 0
    assert service.unread_count(bob)["unread_count"] == 1


@pytest.mark.parametrize("blocker,blocked", [("alice", "bob"), ("bob", "alice")])
def test_blocking_either_direction_hides_thread_count_and_prevents_send(fixture, blocker, blocked):
    accounts, _, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    send(service, alice, thread)
    accounts.relationships[blocker]["blocked_user_ids"].append(blocked)
    for user in [alice, bob]:
        assert service.list_threads(user)["threads"] == []
        assert service.unread_count(user)["unread_count"] == 0
        with pytest.raises(HTTPException):
            service.get_thread(user, thread)
        with pytest.raises(HTTPException):
            send(service, user, thread, 2)


def test_retry_is_idempotent_and_different_content_rejected(fixture):
    accounts, _, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    first = send(service, alice, thread)
    assert send(service, alice, thread) == first
    assert service.unread_count(bob)["unread_count"] == 1
    with pytest.raises(HTTPException) as error:
        send(service, alice, thread, text="Changed replay")
    assert error.value.status_code == 409


def test_concurrent_client_retry_only_persists_one_message(fixture):
    accounts, repository, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    services = [DirectMessageService(accounts, JsonDirectMessageRepository(repository.path)) for _ in range(8)]
    with ThreadPoolExecutor(max_workers=8) as executor:
        acknowledgements = list(executor.map(lambda current: send(current, alice, thread), services))
    assert len({message["id"] for message in acknowledgements}) == 1
    assert len(service.get_thread(bob, thread)["messages"]) == 1
    assert service.unread_count(bob)["unread_count"] == 1


def test_read_own_outbound_does_not_clear_newer_incoming_or_other_thread(fixture):
    accounts, _, service = fixture
    alice, bob, carol = [accounts.users[name] for name in ["alice", "bob", "carol"]]
    thread = service.create_thread(alice, bob.id)["id"]
    incoming = send(service, alice, thread)
    service.mark_read(bob, thread, incoming["id"])
    own_reply = send(service, bob, thread)
    send(service, alice, thread, 2)
    assert service.mark_read(bob, thread, own_reply["id"])["unread_count"] == 1
    other_thread = service.create_thread(alice, carol.id)["id"]
    other_message = send(service, alice, other_thread)
    with pytest.raises(HTTPException) as error:
        service.mark_read(bob, thread, other_message["id"])
    assert error.value.status_code == 404
    assert service.unread_count(bob)["unread_count"] == 1


def test_request_accept_decline_are_participant_scoped(fixture):
    accounts, _, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    send(service, alice, thread)
    assert service.set_request(bob, thread, True, None)["request_accepted"] is True
    assert service.get_thread(alice, thread)["request_accepted"] is True
    assert service.set_request(bob, thread, None, True)["request_declined"] is True
    assert service.list_threads(bob)["threads"] == []
    assert service.unread_count(bob)["unread_count"] == 0
    assert service.set_request(bob, thread, True, None)["request_declined"] is False


def test_following_recipient_gets_primary_and_self_or_unknown_rejected(fixture):
    accounts, _, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    accounts.relationships["bob"]["followed_user_ids"].append("alice")
    thread = service.create_thread(alice, bob.id)["id"]
    assert service.get_thread(bob, thread)["request_accepted"] is True
    for target in [alice.id, "unknown"]:
        with pytest.raises(HTTPException):
            service.create_thread(alice, target)


def test_deleted_and_banned_accounts_cannot_receive_or_expose_messages(fixture):
    accounts, repository, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    send(service, alice, thread)
    accounts.users["alice"] = alice.model_copy(update={"banned": True})
    assert service.unread_count(bob)["unread_count"] == 0
    with pytest.raises(HTTPException):
        service.get_thread(bob, thread)
    repository.delete_user("alice")
    assert service.list_threads(bob)["threads"] == []
    assert repository.get_thread(thread, bob.id) is None
    assert "Hello from another account" not in repository.path.read_text()


def test_failed_disk_commit_never_acknowledges_or_retains_unsent_message(fixture, monkeypatch):
    accounts, repository, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    before = repository.path.read_bytes()
    with monkeypatch.context() as patch:
        patch.setattr("app.core.direct_messages.os.replace", lambda *_: (_ for _ in ()).throw(OSError("disk unavailable")))
        with pytest.raises(OSError):
            send(service, alice, thread)
    assert repository.path.read_bytes() == before
    assert service.unread_count(bob)["unread_count"] == 0
    assert service.get_thread(alice, thread)["messages"] == []


def test_durable_daily_and_minute_quotas_survive_new_repository_instance(fixture):
    accounts, repository, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    for i in range(20):
        send(service, alice, thread, i)
    restarted = DirectMessageService(accounts, JsonDirectMessageRepository(repository.path))
    with pytest.raises(HTTPException) as error:
        send(restarted, alice, thread, 21)
    assert error.value.status_code == 429
    # Keep daily rows but age them outside the per-minute burst window.
    with repository._state(True) as state:
        rows = state["threads"][thread]["messages"]
        for i in range(80):
            rows.append({**deepcopy(rows[0]), "id": f"older-{i}", "client_message_id": f"older-{i}", "sequence": 21+i})
        for row in rows:
            row["created_at"] = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    with pytest.raises(HTTPException) as error:
        send(restarted, alice, thread, 101)
    assert error.value.status_code == 429
    assert "100 messages per day" in error.value.detail


def test_unverified_sender_and_private_post_share_fail_explicitly(fixture):
    accounts, _, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    with pytest.raises(HTTPException) as error:
        send(service, alice.model_copy(update={"email_verified": False}), thread)
    assert error.value.status_code == 403
    with pytest.raises(HTTPException) as error:
        service.send(alice, thread, "", "share", "followers-private")
    assert error.value.status_code == 404
    assert service.unread_count(bob)["unread_count"] == 0


def test_unverified_account_cannot_persist_an_empty_conversation(fixture):
    accounts, repository, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    with pytest.raises(HTTPException) as error:
        service.create_thread(alice.model_copy(update={"email_verified": False}), bob.id)
    assert error.value.status_code == 403
    assert not repository.path.exists()


def test_daily_new_conversation_quota_is_durable_rolling_and_idempotent(fixture):
    accounts, repository, service = fixture
    alice = accounts.users["alice"]
    for index in range(32):
        identifier = f"recipient-{index}"
        accounts.users[identifier] = alice.model_copy(update={"id": identifier, "handle": identifier})
        accounts.relationships[identifier] = {"followed_user_ids": [], "blocked_user_ids": []}
    threads = [service.create_thread(alice, f"recipient-{index}") for index in range(30)]
    restarted = DirectMessageService(accounts, JsonDirectMessageRepository(repository.path))
    with pytest.raises(HTTPException) as error:
        restarted.create_thread(alice, "recipient-30")
    assert error.value.status_code == 429
    assert "30 new conversations" in error.value.detail
    assert restarted.create_thread(alice, "recipient-0")["id"] == threads[0]["id"]
    with repository._state(True) as state:
        assert len(state["threads"]) == 30
        first = state["threads"][threads[0]["id"]]
        assert first["created_by_user_id"] == alice.id
        first["created_at"] = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    assert restarted.create_thread(alice, "recipient-30")["peer_user_id"] == "recipient-30"


def test_incoming_conversations_do_not_consume_recipients_creation_quota(fixture):
    accounts, repository, service = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    for index in range(30):
        identifier = f"sender-{index}"
        accounts.users[identifier] = alice.model_copy(update={"id": identifier, "handle": identifier})
        accounts.relationships[identifier] = {"followed_user_ids": [], "blocked_user_ids": []}
        service.create_thread(accounts.users[identifier], bob.id)
    with repository._state() as state:
        assert sum(row.get("created_by_user_id") == bob.id for row in state["threads"].values()) == 0
    assert service.create_thread(bob, alice.id)["peer_user_id"] == alice.id


def test_concurrent_conversation_creation_cannot_exceed_daily_quota(fixture):
    accounts, repository, _ = fixture
    alice = accounts.users["alice"]
    for index in range(36):
        identifier = f"concurrent-recipient-{index}"
        accounts.users[identifier] = alice.model_copy(update={"id": identifier, "handle": identifier})
        accounts.relationships[identifier] = {"followed_user_ids": [], "blocked_user_ids": []}

    def create(index):
        service = DirectMessageService(accounts, JsonDirectMessageRepository(repository.path))
        try:
            return service.create_thread(alice, f"concurrent-recipient-{index}")["id"]
        except HTTPException as error:
            assert error.status_code == 429
            return None

    with ThreadPoolExecutor(max_workers=8) as executor:
        identifiers = list(executor.map(create, range(36)))
    assert len({identifier for identifier in identifiers if identifier is not None}) == 30
    with repository._state() as state:
        assert len(state["threads"]) == 30


def test_json_peer_block_rules_are_scoped_and_survive_reload(fixture):
    accounts, repository, _ = fixture
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    fallback_store = SimpleNamespace(
        postgres_social=None, user=alice,
        get_auth_user_by_id=accounts.get_auth_user_by_id,
        social_relationship_state=lambda: {"followed_user_ids": [], "blocked_user_ids": []},
    )
    service = DirectMessageService(fallback_store, repository)
    thread = service.create_thread(alice, bob.id)["id"]
    send(service, alice, thread)
    repository.set_block("bob", "alice", True)
    restarted = DirectMessageService(fallback_store, JsonDirectMessageRepository(repository.path))
    with pytest.raises(HTTPException):
        send(restarted, alice, thread, 2)
    assert restarted.unread_count(bob)["unread_count"] == 0
    repository.set_block("bob", "alice", False)
    assert restarted.unread_count(bob)["unread_count"] == 1


def test_configured_database_failure_never_creates_new_json_inbox(tmp_path, monkeypatch):
    from app.core.store import store
    monkeypatch.setenv("DATABASE_URL", "postgresql://configured-but-unavailable.invalid/db")
    monkeypatch.setattr(store, "postgres_social", None)
    monkeypatch.setattr(store, "state_file", tmp_path / "state.json")
    with pytest.raises(HTTPException) as error:
        get_direct_message_service()
    assert error.value.status_code == 503
    assert not (tmp_path / "direct_messages.json").exists()


def test_api_delivery_ack_read_and_auth_payload_spoof_rejection(api):
    client, _, _ = api
    assert client.get("/api/v1/messages/threads").status_code == 401
    assert client.get("/api/v1/messages/unread-count").status_code == 401
    thread = client.post("/api/v1/messages/threads", headers=auth("alice"), json={"recipient_user_id": "bob"}).json()
    identifier = thread["id"]
    response = client.post(f"/api/v1/messages/threads/{identifier}/messages", headers=auth("alice"), json={"text": "Real account delivery", "client_message_id": "request-1"})
    assert response.status_code == 200
    assert response.json()["sender_user_id"] == "alice"
    assert client.get("/api/v1/messages/unread-count", headers=auth("bob")).json() == {"user_id": "bob", "unread_count": 1}
    incoming = client.get(f"/api/v1/messages/threads/{identifier}", headers=auth("bob")).json()
    assert incoming["messages"][0]["text"] == "Real account delivery"
    assert client.get(f"/api/v1/messages/threads/{identifier}", headers=auth("carol")).status_code == 404
    read = client.post(f"/api/v1/messages/threads/{identifier}/read", headers=auth("bob"), json={"last_message_id": incoming["messages"][0]["id"]})
    assert read.json()["unread_count"] == 0
    assert client.post(f"/api/v1/messages/threads/{identifier}/messages", headers=auth("alice"), json={"text": "spoof", "client_message_id": "request-2", "sender_user_id": "carol"}).status_code == 422
    assert client.post(f"/api/v1/messages/threads/{identifier}/messages", headers=auth("alice"), json={"text": " " * 4, "client_message_id": "request-3"}).status_code == 422
    assert client.post(f"/api/v1/messages/threads/{identifier}/messages", headers=auth("alice"), json={"text": "x" * 1601, "client_message_id": "request-4"}).status_code == 422


class _Rows:
    def __init__(self, value=None):
        self.value = value
    def fetchone(self):
        return self.value
    def fetchall(self):
        return self.value if isinstance(self.value, list) else []


class _Connection:
    def __init__(self):
        self.calls = []
    def __enter__(self):
        return self
    def __exit__(self, *_):
        return False
    def execute(self, query, parameters=()):
        self.calls.append((query, parameters))
        return _Rows({"count": 12})


def test_postgres_schema_cascades_delete_and_unread_count_is_unbounded_aggregate():
    connection = _Connection()
    class Social:
        def _connect(self):
            return connection
    repository = PostgresDirectMessageRepository(Social())
    assert any("ON DELETE CASCADE" in query for query, _ in connection.calls)
    assert any("UNIQUE(thread_id, sender_user_id, client_message_id)" in query for query, _ in connection.calls)
    connection.calls.clear()
    assert repository.unread_count("bob") == 12
    query, parameters = connection.calls[-1]
    assert "COUNT(*)" in query and "LIMIT" not in query
    assert "social_blocks" in query and "banned" in query
    assert parameters == ("bob",) * 5
    repository.delete_user("bob")
    assert connection.calls[-1][1] == ("bob", "bob")


def test_postgres_inbox_reads_only_one_preview_in_one_query(monkeypatch):
    connection = _Connection()
    class Social:
        def _connect(self):
            return connection
    repository = PostgresDirectMessageRepository(Social())
    connection.calls.clear()
    monkeypatch.setattr(repository, "_get", lambda *_: pytest.fail("Inbox must not load whole conversations"))
    assert repository.list_threads("alice") == []
    assert len(connection.calls) == 1
    query, parameters = connection.calls[0]
    assert "JOIN LATERAL" in query
    assert "ORDER BY m.sequence DESC LIMIT 1" in query
    assert "LIMIT 100" in query
    assert "peer_payload" in query
    assert "social_blocks" in query
    assert parameters == ("alice",) * 5


def test_postgres_migrates_only_legacy_pair_check_to_explicit_codepoint_collation(monkeypatch):
    connection = _Connection()
    repository = PostgresDirectMessageRepository(SimpleNamespace(_connect=lambda: connection))
    schema_sql = [query for query, _ in connection.calls]
    create = schema_sql[0]
    migration = schema_sql[1]
    assert 'CHECK(user_a COLLATE "C" < user_b COLLATE "C")' in create
    assert migration.startswith("DO $$ BEGIN") and "IF NOT EXISTS" in migration
    assert migration.index("pg_advisory_xact_lock") < migration.index("IF NOT EXISTS")
    assert "ADD CONSTRAINT direct_message_thread_pair_order_c" in migration
    assert 'CHECK(user_a COLLATE "C" < user_b COLLATE "C")' in migration
    assert "DROP CONSTRAINT IF EXISTS direct_message_threads_check" in migration
    assert migration.index("ADD CONSTRAINT") < migration.index("DROP CONSTRAINT")
    connection.calls.clear()
    repository._ensure_schema()
    assert [query for query, _ in connection.calls] == schema_sql


def test_actual_postgres_mixed_case_pair_and_v1_migration():
    """Optional real-Postgres integration; never uses the production DB URL."""
    database_url = os.getenv("TYDES_TEST_POSTGRES_URL", "").strip()
    if not database_url:
        pytest.skip("Set TYDES_TEST_POSTGRES_URL to an isolated local test database")
    import psycopg
    from psycopg import sql
    from psycopg.rows import dict_row
    from uuid import uuid4

    schema = "dm_pair_test_" + uuid4().hex
    with psycopg.connect(database_url, autocommit=True, row_factory=dict_row) as control:
        collation = control.execute("""SELECT collname FROM pg_collation
            WHERE collname IN ('en-US-x-icu','en_US.utf8','en_US.UTF-8')
            ORDER BY collname LIMIT 1""").fetchone()
        if collation is None:
            pytest.skip("A locale-aware English collation is required for this regression")
        control.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
        try:
            control.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(schema)))
            control.execute(sql.SQL("""CREATE TABLE direct_message_threads (
                id TEXT PRIMARY KEY,
                user_a TEXT COLLATE {} NOT NULL,
                user_b TEXT COLLATE {} NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE(user_a,user_b), CHECK(user_a < user_b))""").format(
                    sql.Identifier(collation["collname"]), sql.Identifier(collation["collname"])))
            with pytest.raises(psycopg.errors.CheckViolation):
                control.execute("INSERT INTO direct_message_threads(id,user_a,user_b) VALUES(%s,%s,%s)",
                    ("old-check-fails", "usr_ZZlwffVZ5ms", "usr_oD8ZUNTpHc"))

            @contextmanager
            def connect():
                with psycopg.connect(database_url, autocommit=True, row_factory=dict_row) as connection:
                    connection.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(schema)))
                    yield connection

            repository = PostgresDirectMessageRepository(SimpleNamespace(_connect=connect))
            repository._ensure_schema()  # Safe repeated migration of existing v1 schema.
            thread = repository.ensure_thread("usr_oD8ZUNTpHc", "usr_ZZlwffVZ5ms", False)
            assert thread["user_a"] == "usr_ZZlwffVZ5ms" and thread["user_b"] == "usr_oD8ZUNTpHc"
            assert repository.ensure_thread("usr_ZZlwffVZ5ms", "usr_oD8ZUNTpHc", False)["id"] == thread["id"]
            sent = repository.send(thread["id"], "usr_oD8ZUNTpHc", "Integration delivery", "real-pg-1", None, 100)
            assert sent["sender_user_id"] == "usr_oD8ZUNTpHc"
            assert repository.get_thread(thread["id"], "usr_ZZlwffVZ5ms")["unread_count"] == 1
            assert repository.mark_read(thread["id"], "usr_ZZlwffVZ5ms", sent["id"]) == 0
        finally:
            control.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))


class _MessageSqlConnection(_Connection):
    def __init__(self):
        super().__init__()
        self.previous = None
        self.member = True
        self.marker_sequence = 7
        self.active_transaction = False
        self.message = {
            "id": "server-id", "thread_id": "thread", "sender_user_id": "alice",
            "text": "hello", "client_message_id": "retry-key", "shared_post_id": None,
            "created_at": datetime.now(timezone.utc), "sequence": 8,
        }

    @contextmanager
    def transaction(self):
        self.active_transaction = True
        try:
            yield
        finally:
            self.active_transaction = False

    def execute(self, query, parameters=()):
        self.calls.append((query, parameters))
        if "CREATE " in query or query.startswith(("ALTER ", "DO $$")):
            return _Rows()
        assert self.active_transaction
        if "FOR UPDATE OF t" in query:
            return _Rows({"id": "thread"} if self.member else None)
        if "SELECT * FROM direct_messages" in query:
            return _Rows(self.previous)
        if "SELECT m.sequence" in query:
            return _Rows({"sequence": self.marker_sequence} if self.member else None)
        if "minute_count" in query:
            return _Rows({"count": 0, "minute_count": 0})
        if "INSERT INTO direct_messages" in query:
            return _Rows(self.message)
        if "COUNT(*)" in query:
            return _Rows({"count": 1})
        return _Rows()


def test_postgres_send_locks_sender_and_thread_before_durable_quota_and_insert():
    connection = _MessageSqlConnection()
    repository = PostgresDirectMessageRepository(SimpleNamespace(_connect=lambda: connection))
    connection.calls.clear()
    result = repository.send("thread", "alice", "hello", "retry-key", None, 100)
    assert result["id"] == "server-id"
    queries = [query for query, _ in connection.calls]
    assert "pg_advisory_xact_lock" in queries[0]
    assert "FOR UPDATE OF t" in queries[1]
    assert connection.calls[1][1] == ("thread", "alice")
    assert next(i for i, query in enumerate(queries) if "minute_count" in query) < next(i for i, query in enumerate(queries) if "INSERT INTO direct_messages" in query)
    connection.previous = connection.message
    connection.calls.clear()
    assert repository.send("thread", "alice", "hello", "retry-key", None, 100)["id"] == "server-id"
    assert not any("INSERT INTO direct_messages" in query or "minute_count" in query for query, _ in connection.calls)


def test_postgres_read_marker_is_membership_scoped_and_monotonic():
    connection = _MessageSqlConnection()
    repository = PostgresDirectMessageRepository(SimpleNamespace(_connect=lambda: connection))
    connection.calls.clear()
    assert repository.mark_read("thread", "bob", "message-marker") == 1
    assert connection.calls[0][1] == ("message-marker", "thread", "bob")
    assert "p.user_id=%s" in connection.calls[0][0]
    assert "GREATEST(read_sequence,%s)" in connection.calls[1][0]
    assert connection.calls[1][1] == (7, "thread", "bob")
    connection.member = False
    connection.calls.clear()
    with pytest.raises(HTTPException) as error:
        repository.mark_read("thread", "carol", "message-marker")
    assert error.value.status_code == 404
    assert len(connection.calls) == 1


def test_postgres_new_thread_quota_is_locked_initiator_only_and_retries_are_free(monkeypatch):
    class ThreadConnection(_MessageSqlConnection):
        existing = False
        quota = 0
        def execute(self, query, parameters=()):
            if "CREATE " in query or query.startswith(("ALTER ", "DO $$")):
                return super().execute(query, parameters)
            assert self.active_transaction
            self.calls.append((query, parameters))
            if "SELECT id FROM direct_message_threads WHERE id=" in query:
                return _Rows({"id": "existing"} if self.existing else None)
            if "created_by_user_id=%s" in query:
                return _Rows({"count": self.quota})
            return _Rows()
    connection = ThreadConnection()
    repository = PostgresDirectMessageRepository(SimpleNamespace(_connect=lambda: connection))
    monkeypatch.setattr(repository, "_get", lambda *_: {"id": "confirmed"})
    connection.calls.clear()
    assert repository.ensure_thread("alice", "bob", False) == {"id": "confirmed"}
    assert "pg_advisory_xact_lock" in connection.calls[0][0]
    assert connection.calls[0][1] == ("dm-sender:alice",)
    insert = next(call for call in connection.calls if "INSERT INTO direct_message_threads" in call[0])
    assert insert[1][-1] == "alice"
    assert next(call for call in connection.calls if "created_by_user_id=%s" in call[0])[1] == ("alice",)
    connection.quota = 30
    connection.calls.clear()
    with pytest.raises(HTTPException) as error:
        repository.ensure_thread("alice", "carol", False)
    assert error.value.status_code == 429
    assert not any("INSERT INTO direct_message_threads" in query for query, _ in connection.calls)
    connection.existing = True
    connection.calls.clear()
    assert repository.ensure_thread("alice", "bob", False) == {"id": "confirmed"}
    assert not any("created_by_user_id=%s" in query for query, _ in connection.calls)
