"""Participant-only chat mute/clear controls, with no live storage or users."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

import pytest
from fastapi import FastAPI, HTTPException, Request
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-chat-controls-"))

from app.core import direct_messages, media_uploads
from app.core.auth import require_authenticated_user
from app.core.direct_messages import DirectMessageService, JsonDirectMessageRepository, PostgresDirectMessageRepository, get_direct_message_service
from app.core.rate_limit import api_rate_limiter
from app.modules.messages.router import router
from test_direct_messages import Accounts


@pytest.fixture
def chat(tmp_path):
    accounts = Accounts()
    for user in accounts.users.values():
        user.email = f"{user.id}@example.com"
    repository = JsonDirectMessageRepository(tmp_path / "messages.json")
    service = DirectMessageService(accounts, repository)
    alice, bob, carol = [accounts.users[name] for name in ("alice", "bob", "carol")]
    thread = service.create_thread(alice, bob.id)["id"]
    service.set_request(bob, thread, True, None)
    return accounts, repository, service, alice, bob, carol, thread


def test_clear_is_durable_requester_only_and_new_messages_reappear(chat):
    accounts, repository, service, alice, bob, _, thread = chat
    old = [service.send(alice, thread, f"old {index}", f"old-{index}", None) for index in range(3)]
    peer_before = service.get_thread(alice, thread)
    assert peer_before["cleared"] is False
    assert service.unread_count(bob)["unread_count"] == 3
    assert service.clear_thread(bob, thread) == {"user_id": bob.id, "thread_id": thread, "deleted": True}
    assert service.clear_thread(bob, thread)["deleted"]  # Repeated clear is safe.
    assert service.get_thread(bob, thread)["messages"] == []
    assert service.get_thread(bob, thread)["cleared"] is True
    assert "cleared_sequence" not in service.get_thread(bob, thread)
    assert service.get_thread(bob, thread)["preview"] == ""
    assert service.list_threads(bob)["threads"] == []
    assert service.unread_count(bob)["unread_count"] == 0
    assert service.get_thread(alice, thread) == peer_before
    with pytest.raises(HTTPException):
        service.mark_read(bob, thread, old[0]["id"])
    restarted = DirectMessageService(accounts, JsonDirectMessageRepository(repository.path))
    assert restarted.get_thread(bob, thread)["messages"] == []
    assert restarted.get_thread(bob, thread)["cleared"] is True
    new = restarted.send(alice, thread, "new surf", "new", None)
    visible = restarted.get_thread(bob, thread)
    assert visible["cleared"] is False
    assert [item["id"] for item in visible["messages"]] == [new["id"]]
    assert restarted.list_threads(bob)["threads"][0]["preview"] == "new surf"
    assert restarted.unread_count(bob)["unread_count"] == 1
    assert len(restarted.get_thread(alice, thread)["messages"]) == 4
    # Clearing does not break sender idempotency or resend old content anew.
    assert restarted.send(alice, thread, "old 0", "old-0", None) == old[0]
    assert len(restarted.get_thread(bob, thread)["messages"]) == 1


def test_mute_is_account_scoped_persistent_and_suppresses_only_global_count(chat):
    accounts, repository, service, alice, bob, carol, thread = chat
    service.send(alice, thread, "first", "first", None)
    other = service.create_thread(carol, bob.id)["id"]
    service.send(carol, other, "another room", "second", None)
    assert service.get_thread(bob, thread)["muted"] is False
    ack = service.set_muted(bob, thread, True)
    assert ack["user_id"] == bob.id and ack["id"] == thread and ack["muted"] is True
    assert "messages" in ack and ack["can_send_attachments"] is True
    assert service.get_thread(alice, thread)["muted"] is False
    assert service.get_thread(bob, thread)["unread_count"] == 1
    assert service.unread_count(bob)["unread_count"] == 1  # Other room only.
    assert next(item for item in service.list_threads(bob)["threads"] if item["id"] == thread)["muted"] is True
    restarted = DirectMessageService(accounts, JsonDirectMessageRepository(repository.path))
    assert restarted.get_thread(bob, thread)["muted"] is True
    restarted.send(alice, thread, "still muted", "third", None)
    assert restarted.unread_count(bob)["unread_count"] == 1
    restarted.set_muted(bob, thread, False)
    assert restarted.unread_count(bob)["unread_count"] == 3
    restarted.set_muted(bob, thread, True)
    restarted.clear_thread(bob, thread)
    restarted.send(alice, thread, "new after clear", "fourth", None)
    assert restarted.get_thread(bob, thread)["muted"] is True
    assert restarted.get_thread(bob, thread)["unread_count"] == 1
    assert restarted.unread_count(bob)["unread_count"] == 1


def test_clear_denies_old_attachment_only_for_requester_without_deleting_media(chat, monkeypatch):
    _, repository, service, alice, bob, _, thread = chat
    def forbidden_cleanup(*args, **kwargs):
        pytest.fail("Clearing a chat must never delete either person's media")
    monkeypatch.setattr(media_uploads.upload_ledger, "queue_chat_scope_deletion", forbidden_cleanup)
    message = repository.send(thread, alice.id, "photo", "attachment", None, 100,
                              attachment={"id": "private-photo", "media_type": "photo"})
    assert service.attachment_message_exists(bob, thread, message["id"], "private-photo")
    service.clear_thread(bob, thread)
    assert not service.attachment_message_exists(bob, thread, message["id"], "private-photo")
    assert service.attachment_message_exists(alice, thread, message["id"], "private-photo")
    assert repository.get_thread(thread, alice.id)["messages"][0]["attachment"]["id"] == "private-photo"


@pytest.mark.parametrize("operation", ["clear", "mute"])
def test_controls_require_current_participant_and_preserve_block_ban_checks(chat, operation):
    accounts, _, service, alice, bob, carol, thread = chat
    act = lambda user: service.clear_thread(user, thread) if operation == "clear" else service.set_muted(user, thread, True)
    with pytest.raises(HTTPException) as outsider:
        act(carol)
    assert outsider.value.status_code == 404
    accounts.relationships[alice.id]["blocked_user_ids"].append(bob.id)
    with pytest.raises(HTTPException):
        act(bob)
    accounts.relationships[alice.id]["blocked_user_ids"].clear()
    alice.banned = True
    with pytest.raises(HTTPException):
        act(bob)


@pytest.mark.parametrize("operation", ["clear", "mute"])
def test_json_failed_durable_write_keeps_old_preferences_and_history(chat, monkeypatch, operation):
    _, repository, service, alice, bob, _, thread = chat
    service.send(alice, thread, "retain me", "persisted", None)
    before = repository.path.read_bytes()
    def fail_replace(*args):
        raise OSError("Simulated unavailable disk")
    monkeypatch.setattr(direct_messages.os, "replace", fail_replace)
    with pytest.raises(OSError):
        if operation == "clear":
            service.clear_thread(bob, thread)
        else:
            service.set_muted(bob, thread, True)
    assert repository.path.read_bytes() == before
    assert len(service.get_thread(bob, thread)["messages"]) == 1
    assert service.get_thread(bob, thread)["muted"] is False


def test_old_json_participants_default_unmuted_without_resetting_history(chat):
    _, repository, service, alice, bob, _, thread = chat
    service.send(alice, thread, "legacy history", "legacy", None)
    with repository._state(True) as data:
        for participant in data["threads"][thread]["participants"].values():
            participant.pop("muted")
            participant.pop("cleared_sequence")
    assert service.get_thread(bob, thread)["muted"] is False
    assert service.unread_count(bob)["unread_count"] == 1
    assert len(service.get_thread(bob, thread)["messages"]) == 1
    assert service.get_thread(bob, thread)["cleared"] is False


def test_new_empty_thread_is_not_reported_as_cleared(chat):
    _, _, service, _, bob, _, thread = chat
    result = service.get_thread(bob, thread)
    assert result["messages"] == [] and result["cleared"] is False


def test_concurrent_send_and_clear_leave_only_messages_after_atomic_cutoff(chat):
    _, repository, service, alice, bob, _, thread = chat
    service.send(alice, thread, "before", "before", None)
    with ThreadPoolExecutor(max_workers=2) as pool:
        sent = pool.submit(service.send, alice, thread, "racing", "racing", None)
        cleared = pool.submit(service.clear_thread, bob, thread)
        sent.result()
        cleared.result()
    raw = json.loads(repository.path.read_text())["threads"][thread]
    cutoff = raw["participants"][bob.id]["cleared_sequence"]
    assert raw["participants"][bob.id]["read_sequence"] >= cutoff
    assert [item["id"] for item in service.get_thread(bob, thread)["messages"]] == [
        item["id"] for item in raw["messages"] if item["sequence"] > cutoff]
    assert len(service.get_thread(alice, thread)["messages"]) == 2


def test_http_settings_and_delete_confirm_owner_and_reject_spoofed_fields(chat):
    accounts, _, service, alice, bob, _, thread = chat
    service.send(alice, thread, "hello", "hello", None)
    application = FastAPI()
    application.include_router(router)
    def viewer(request: Request):
        user = accounts.users.get(request.headers.get("authorization", "").removeprefix("Bearer "))
        if user is None:
            raise HTTPException(401, "Sign in required")
        return user
    application.dependency_overrides[require_authenticated_user] = viewer
    application.dependency_overrides[get_direct_message_service] = lambda: service
    api_rate_limiter.clear()
    with TestClient(application) as client:
        path = f"/messages/threads/{thread}"
        assert client.patch(path + "/settings", json={"muted": True}).status_code == 401
        assert client.delete(path).status_code == 401
        headers = {"Authorization": "Bearer bob"}
        for body in ({"muted": "true"}, {"muted": True, "user_id": "alice"}, {}):
            assert client.patch(path + "/settings", headers=headers, json=body).status_code == 422
        ack = client.patch(path + "/settings", headers=headers, json={"muted": True}).json()
        assert ack["user_id"] == bob.id and ack["id"] == thread and ack["muted"] is True
        assert ack["messages"][0]["text"] == "hello"
        assert client.delete(path, headers=headers).json() == {"user_id": bob.id, "thread_id": thread, "deleted": True}
        assert client.get(path, headers=headers).json()["messages"] == []
        assert len(client.get(path, headers={"Authorization": "Bearer alice"}).json()["messages"]) == 1
    api_rate_limiter.clear()


class _Rows:
    def __init__(self, row=None):
        self.row = row
    def fetchone(self):
        return self.row
    def fetchall(self):
        return self.row if isinstance(self.row, list) else []


@pytest.mark.parametrize("fail", [False, True])
def test_postgres_clear_locks_with_send_and_atomically_rolls_back_markers(fail):
    class Connection:
        active = False
        cleared = 0
        read = 2
        calls = []
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
        @contextmanager
        def transaction(self):
            before = self.cleared, self.read
            self.active = True
            try:
                yield
            except Exception:
                self.cleared, self.read = before
                raise
            finally:
                self.active = False
        def execute(self, query, params):
            assert self.active
            self.calls.append((query, params))
            if "FOR UPDATE OF t" in query:
                return _Rows({"id": "room"})
            assert "UPDATE direct_message_participants" in query
            assert "cleared_sequence=GREATEST" in query and "read_sequence=GREATEST" in query
            assert params == ("room", "room", "room", "bob")
            self.cleared = self.read = 7
            if fail:
                raise OSError("Simulated statement failure")
            return _Rows()
    connection = Connection()
    repository = object.__new__(PostgresDirectMessageRepository)
    repository.social = SimpleNamespace(_connect=lambda: connection)
    if fail:
        with pytest.raises(OSError):
            repository.clear_thread("room", "bob")
        assert (connection.cleared, connection.read) == (0, 2)
    else:
        repository.clear_thread("room", "bob")
        assert (connection.cleared, connection.read) == (7, 7)
    assert all("DELETE" not in query for query, _ in connection.calls)


def test_postgres_queries_and_additive_schema_filter_cleared_and_muted():
    class Connection:
        calls = []
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
        def execute(self, query, params=()):
            self.calls.append((query, params))
            if "AS present" in query:
                return _Rows({"present": False})
            if "COUNT(*) AS count" in query and "JOIN direct_message_threads" in query:
                return _Rows({"count": 0})
            return _Rows([])
    connection = Connection()
    repository = PostgresDirectMessageRepository(SimpleNamespace(_connect=lambda: connection))
    migrations = [query for query, _ in connection.calls]
    assert any("ADD COLUMN IF NOT EXISTS muted BOOLEAN NOT NULL DEFAULT FALSE" in query for query in migrations)
    assert any("ADD COLUMN IF NOT EXISTS cleared_sequence BIGINT NOT NULL DEFAULT 0" in query for query in migrations)
    assert not any("DELETE FROM" in query or "TRUNCATE" in query for query in migrations)
    connection.calls.clear()
    repository.list_threads("bob")
    inbox_sql = connection.calls[-1][0]
    assert "m.sequence>p.cleared_sequence" in inbox_sql
    assert "p.muted" in inbox_sql and "GREATEST(p.read_sequence,p.cleared_sequence)" in inbox_sql
    repository.unread_count("bob")
    assert "AND NOT p.muted" in connection.calls[-1][0]
    assert "GREATEST(p.read_sequence,p.cleared_sequence)" in connection.calls[-1][0]
    assert not repository.attachment_message_exists("room", "bob", "old-photo", "private-photo")
    assert "m.sequence>p.cleared_sequence" in connection.calls[-1][0]


def test_postgres_full_thread_reads_only_requesters_uncleared_messages():
    now = datetime.now(timezone.utc)
    participants = [
        {"user_id": "alice", "accepted": True, "declined": False, "read_sequence": 0, "cleared_sequence": 0, "muted": False},
        {"user_id": "bob", "accepted": True, "declined": False, "read_sequence": 4, "cleared_sequence": 4, "muted": True},
    ]
    class Connection:
        calls = []
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
        def execute(self, query, params=()):
            self.calls.append((query, params))
            if "SELECT t.*" in query:
                return _Rows({"id": "room", "user_a": "alice", "user_b": "bob", "created_at": now, "updated_at": now})
            if "SELECT * FROM direct_message_participants" in query:
                return _Rows(participants)
            if "COUNT(*)" in query:
                assert "GREATEST(p.read_sequence,p.cleared_sequence)" in query
                return _Rows({"count": 1})
            assert "AND sequence>%s ORDER BY sequence DESC LIMIT 100" in query
            assert params == ("room", 4)
            return _Rows([{"id": "new-message", "sequence": 5, "sender_user_id": "alice", "text": "new", "created_at": now}])
    connection = Connection()
    repository = object.__new__(PostgresDirectMessageRepository)
    repository.social = SimpleNamespace(_connect=lambda: connection)
    thread = repository.get_thread("room", "bob")
    assert [item["id"] for item in thread["messages"]] == ["new-message"]
    assert thread["participants"]["bob"]["muted"] is True
    assert thread["participants"]["alice"]["cleared_sequence"] == 0
    assert thread["unread_count"] == 1


@pytest.mark.parametrize("fail", [False, True])
def test_postgres_mute_is_transactional_and_returns_filtered_confirmed_thread(fail):
    class Connection:
        active = False
        muted = False
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
        @contextmanager
        def transaction(self):
            before = self.muted
            self.active = True
            try:
                yield
            except Exception:
                self.muted = before
                raise
            finally:
                self.active = False
        def execute(self, query, params):
            assert self.active and "UPDATE direct_message_participants SET muted=%s" in query
            assert params == (True, "room", "bob")
            self.muted = True
            return _Rows({"thread_id": "room"})
    connection = Connection()
    repository = object.__new__(PostgresDirectMessageRepository)
    repository.social = SimpleNamespace(_connect=lambda: connection)
    def confirmed(conn, thread_id, user_id):
        assert conn is connection and conn.active
        assert (thread_id, user_id) == ("room", "bob")
        if fail:
            raise OSError("Simulated confirmation failure")
        return {"messages": [], "muted": conn.muted}
    repository._get = confirmed
    if fail:
        with pytest.raises(OSError):
            repository.set_muted("room", "bob", True)
        assert connection.muted is False
    else:
        assert repository.set_muted("room", "bob", True) == {"messages": [], "muted": True}
