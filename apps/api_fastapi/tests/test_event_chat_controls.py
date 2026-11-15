"""Per-account event room controls, without provider/network credentials."""
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from threading import Event

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-event-controls-"))

from app.core import chat_media, media_uploads
from app.core.models import ChatAttachment, EventChatMessage, SocialPost, build_seed
from app.core.postgres_social import PostgresSocialRepository
from app.core.rate_limit import api_rate_limiter
from app.core.store import DemoStore
from app.main import app
from test_event_repository_sql import LocalSqlConnection


@pytest.fixture
def room(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "")
    monkeypatch.setattr("app.core.store.state_file_path", lambda: tmp_path / "state.json")
    data = DemoStore()
    users = {
        name: build_seed()["user"].model_copy(update={
            "id": f"event-{name}", "email": f"{name}@example.com", "handle": name,
            "email_verified": True, "banned": False,
        }) for name in ("host", "guest", "other", "outsider")
    }
    data.user = users["host"]
    post = SocialPost(id="event-controls", user_id=users["host"].id, author_name="Host",
                      body="Surf together", post_type="surf_plan", visibility="public",
                      created_at=datetime.now(timezone.utc))
    data.posts = [post]
    data.comments = []
    data.event_chat_messages = []
    data.rsvp_user_ids_by_post = {post.id: {users[name].id for name in ("host", "guest", "other")}}
    data.rsvp_post_ids = {post.id}
    data.auth_accounts = {user.email: {"user": user.model_dump(mode="json")} for user in users.values()}
    blocks = {user.id: set() for user in users.values()}
    monkeypatch.setattr(data, "get_auth_user_by_id", lambda user_id: next((u for u in users.values() if u.id == user_id), None))
    monkeypatch.setattr(data, "_blocked_user_ids_for", lambda user_id: blocks[user_id])
    monkeypatch.setattr(data, "_save_current_account_user", lambda: None)
    monkeypatch.setattr(data, "resolve_session_user", lambda token: users.get(token))
    monkeypatch.setattr(importlib.import_module("app.core.store"), "store", data)
    monkeypatch.setattr(importlib.import_module("app.main"), "store", data)
    monkeypatch.setattr(importlib.import_module("app.modules.social.router"), "store", data)
    api_rate_limiter.clear()
    yield SimpleNamespace(store=data, users=users, post=post, blocks=blocks,
                          client=TestClient(app, raise_server_exceptions=False))
    api_rate_limiter.clear()


def _headers(name):
    return {"Authorization": f"Bearer {name}"}


def _path(room, suffix="settings"):
    return f"/api/v1/social/posts/{room.post.id}/chat/{suffix}"


def test_event_settings_defaults_are_authenticated_and_private(room):
    assert room.client.get(_path(room)).status_code == 401
    response = room.client.get(_path(room), headers=_headers("guest"))
    assert response.status_code == 200
    assert response.json() == {"user_id": room.users["guest"].id, "post_id": room.post.id,
                               "muted": False, "left": False}
    assert response.headers["cache-control"] == "private, no-store"
    room.users["guest"].email_verified = False
    assert room.client.get(_path(room), headers=_headers("guest")).status_code == 403


def test_mute_is_durable_account_scoped_and_does_not_change_event(room):
    response = room.client.patch(_path(room), headers=_headers("guest"), json={"muted": True})
    assert response.status_code == 200
    assert response.json()["muted"] is True
    assert response.headers["cache-control"] == "private, no-store"
    assert room.client.get(_path(room), headers=_headers("host")).json()["muted"] is False
    inbox = room.client.get("/api/v1/social/event-chats", headers=_headers("guest"))
    assert inbox.json()[0]["chat_muted"] is True
    assert inbox.json()[0]["chat_left"] is False
    assert "chat_muted" not in room.post.model_dump()
    room.store.event_chat_preferences = {}
    with room.store.request_user_context(room.users["guest"]):
        room.store._load_state()
        assert room.store.get_event_chat_settings(room.post.id)["muted"] is True
        assert room.store.can_access_event_chat(room.post.id)
    assert room.store.rsvp_user_ids_by_post[room.post.id] == {u.id for n, u in room.users.items() if n != "outsider"}


@pytest.mark.parametrize("name", ["guest", "host"])
def test_leaving_chat_keeps_rsvp_messages_event_and_other_members_then_explicit_rejoin(room, name):
    member = room.users[name]
    saved = EventChatMessage(id="existing-message", post_id=room.post.id, user_id=room.users["other"].id,
                             author_name="Other", text="Existing", created_at=datetime.now(timezone.utc),
                             attachment=ChatAttachment(id="existing-private", media_type="photo"))
    room.store.event_chat_messages = [saved]
    members = set(room.store.rsvp_user_ids_by_post[room.post.id])
    response = room.client.post(_path(room, "leave"), headers=_headers(name))
    assert response.status_code == 200 and response.json()["left"] is True
    assert response.json()["user_id"] == member.id
    assert room.store.rsvp_user_ids_by_post[room.post.id] == members
    assert room.store.get_post(room.post.id) is not None
    assert room.store.event_chat_messages == [saved]
    assert room.client.get("/api/v1/social/event-chats", headers=_headers(name)).json() == []
    assert room.client.get(_path(room), headers=_headers(name)).json()["left"] is True
    history = room.client.get(_path(room, "").rstrip("/"), headers=_headers(name))
    assert history.status_code == 403
    assert history.json()["detail"]["code"] == "event_chat_left"
    sent = room.client.post(_path(room, "").rstrip("/"), headers=_headers(name), json={"text": "Denied"})
    assert sent.status_code == 403 and sent.json()["detail"]["code"] == "event_chat_left"
    with room.store.request_user_context(member):
        assert not room.store.event_attachment_message_exists(room.post.id, saved.id, "existing-private")
    with pytest.raises(HTTPException):
        chat_media.authorize_context(member, "event", room.post.id)
    with room.store.request_user_context(room.users["other"]):
        assert room.store.list_event_chat_messages(room.post.id) == [saved]
    response = room.client.post(_path(room, "join"), headers=_headers(name))
    assert response.status_code == 200 and response.json()["left"] is False
    assert room.store.rsvp_user_ids_by_post[room.post.id] == members
    with room.store.request_user_context(member):
        assert room.store.event_attachment_message_exists(room.post.id, saved.id, "existing-private")
        assert room.store.add_event_chat_message(post_id=room.post.id, message_id="new-message", text="Back") is not None


def test_rejoin_requires_current_rsvp_visibility_and_both_direction_block_guards(room):
    data, guest, host = room.store, room.users["guest"], room.users["host"]
    assert room.client.post(_path(room, "join"), headers=_headers("outsider")).status_code == 403
    room.client.post(_path(room, "leave"), headers=_headers("guest"))
    data.rsvp_user_ids_by_post[room.post.id].remove(guest.id)
    assert room.client.post(_path(room, "join"), headers=_headers("guest")).status_code == 403
    data.rsvp_user_ids_by_post[room.post.id].add(guest.id)
    for blocker, blocked in ((host, guest), (guest, host)):
        room.blocks[blocker.id].add(blocked.id)
        assert room.client.post(_path(room, "join"), headers=_headers("guest")).status_code == 403
        room.blocks[blocker.id].clear()
    host.banned = True
    assert room.client.post(_path(room, "join"), headers=_headers("guest")).status_code == 403
    host.banned = False
    room.post.visibility = "followers"
    assert room.client.post(_path(room, "join"), headers=_headers("guest")).status_code == 403
    data.followed_user_ids.add(host.id)
    assert room.client.post(_path(room, "join"), headers=_headers("guest")).status_code == 200


@pytest.mark.parametrize("payload", [{}, {"muted": "true"}, {"muted": 1}, {"muted": True, "left": True}, {"muted": True, "user_id": "other"}])
def test_settings_reject_unconfirmed_or_forged_fields(room, payload):
    assert room.client.patch(_path(room), headers=_headers("guest"), json=payload).status_code == 422
    assert room.store.event_chat_preferences == {}


@pytest.mark.parametrize("operation", ["mute", "leave", "join"])
def test_failed_json_persistence_never_acknowledges_or_changes_settings(room, monkeypatch, operation):
    with room.store.request_user_context(room.users["guest"]):
        room.store.set_event_chat_settings(room.post.id, muted=False, left=operation == "join")
    before = json.loads(json.dumps(room.store.event_chat_preferences))
    monkeypatch.setattr(room.store, "_save_state", lambda: (_ for _ in ()).throw(OSError("disk unavailable")))
    response = (room.client.patch(_path(room), headers=_headers("guest"), json={"muted": True})
                if operation == "mute" else room.client.post(_path(room, operation), headers=_headers("guest")))
    assert response.status_code == 500
    assert room.store.event_chat_preferences == before


def test_event_deletion_removes_preferences_for_all_users_but_leave_never_queues_media_cleanup(room, monkeypatch):
    cleaned = []
    monkeypatch.setattr(media_uploads, "upload_ledger", SimpleNamespace(queue_chat_scope_deletion=lambda *args, **kwargs: cleaned.append(args)))
    for name in ("host", "guest"):
        room.client.post(_path(room, "leave"), headers=_headers(name))
    assert cleaned == []
    with room.store.request_user_context(room.users["host"]):
        room.store.delete_post(room.post.id, room.users["host"].id)
    assert room.store.event_chat_preferences == {}
    assert cleaned == [("event", room.post.id)]


def test_account_deletion_cleans_only_own_room_preferences(room, monkeypatch):
    for name in ("host", "guest"):
        room.client.patch(_path(room), headers=_headers(name), json={"muted": True})
    monkeypatch.setattr("app.core.direct_messages.delete_direct_messages_for_user", lambda _: None)
    monkeypatch.setattr(room.store, "logout", lambda: room.store._save_state())
    with room.store.request_user_context(room.users["guest"]):
        room.store.delete_current_account()
    assert room.users["guest"].id not in room.store.event_chat_preferences
    assert room.users["host"].id in room.store.event_chat_preferences


def test_failed_local_rejoin_is_never_visible_to_a_concurrent_reader(room, monkeypatch):
    guest = room.users["guest"]
    with room.store.request_user_context(guest):
        room.store.set_event_chat_settings(room.post.id, left=True)
    saving, release, reading = Event(), Event(), Event()
    def fail_save():
        saving.set()
        assert release.wait(2)
        raise OSError("write failed")
    monkeypatch.setattr(room.store, "_save_state", fail_save)
    def rejoin():
        with room.store.request_user_context(guest), pytest.raises(OSError):
            room.store.set_event_chat_settings(room.post.id, left=False)
    def read():
        reading.set()
        with room.store.request_user_context(guest):
            return room.store.get_event_chat_settings(room.post.id)
    with ThreadPoolExecutor(max_workers=2) as pool:
        write = pool.submit(rejoin)
        assert saving.wait(2)
        result = pool.submit(read)
        try:
            assert reading.wait(2)
            assert not result.done()
        finally:
            release.set()
        write.result(timeout=2)
        assert result.result(timeout=2)["left"] is True


@pytest.fixture
def sql(monkeypatch):
    connection = LocalSqlConnection()
    repository = object.__new__(PostgresSocialRepository)
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", json.dumps)
    yield repository, connection
    connection.db.close()


def test_postgres_preferences_preserve_independent_fields_users_and_filter_before_limit(sql):
    repository, connection = sql
    now = datetime.now(timezone.utc)
    for index in (1, 2):
        repository.save_post(SocialPost(id=f"event-{index}", user_id="owner", author_name="Host",
                             post_type="surf_plan", body="Surf", created_at=now + timedelta(seconds=index)))
        repository.set_rsvp("guest", f"event-{index}", True)
    assert repository.event_chat_preferences("guest", ["event-1"]) == {}
    assert repository.set_event_chat_preferences("guest", "event-2", muted=True) == {"muted": True, "left": False}
    assert repository.set_event_chat_preferences("guest", "event-2", left=True) == {"muted": True, "left": True}
    assert [p.id for p in repository.list_event_chat_posts("guest", 1)] == ["event-1"]
    assert set(repository.list_rsvp_user_ids("event-2")) == {"guest", "owner"}
    assert repository.event_chat_preferences("owner", ["event-2"]) == {}
    assert repository.set_event_chat_preferences("guest", "event-2", left=False) == {"muted": True, "left": False}
    assert [p.id for p in repository.list_event_chat_posts("guest", 1)] == ["event-2"]
    restarted = object.__new__(PostgresSocialRepository)
    restarted._connect = lambda: connection
    assert restarted.event_chat_preferences("guest", ["event-2"])["event-2"]["muted"] is True


def test_postgres_write_failure_propagates_and_keeps_previous_settings(sql, monkeypatch):
    repository, connection = sql
    repository.set_event_chat_preferences("guest", "event", muted=True)
    original = connection.execute
    def fail(query, parameters=()):
        if "INSERT INTO social_event_chat_preferences" in query:
            raise OSError("database unavailable")
        return original(query, parameters)
    monkeypatch.setattr(connection, "execute", fail)
    with pytest.raises(OSError):
        repository.set_event_chat_preferences("guest", "event", left=True)
    assert repository.event_chat_preferences("guest", ["event"]) == {"event": {"muted": True, "left": False}}


def test_postgres_event_and_account_deletion_clean_only_relevant_preferences(sql, monkeypatch):
    repository, connection = sql
    connection.db.executescript("""
        CREATE TABLE social_comments (id TEXT, post_id TEXT, user_id TEXT, payload TEXT);
        CREATE TABLE social_event_messages (id TEXT, post_id TEXT, user_id TEXT);
        CREATE TABLE social_comment_likes (user_id TEXT, comment_id TEXT);
        CREATE TABLE social_notifications (recipient_user_id TEXT, actor_user_id TEXT);
        CREATE TABLE social_reports (reporter_user_id TEXT);
    """)
    monkeypatch.setattr(media_uploads, "upload_ledger", SimpleNamespace(queue_chat_scope_deletion=lambda *args, **kwargs: None))
    for post_id in ("deleted", "retained"):
        repository.save_post(SocialPost(id=post_id, user_id="owner", author_name="Host", body="Surf",
                             post_type="surf_plan", created_at=datetime.now(timezone.utc)))
        for user_id in ("owner", "guest"):
            repository.set_event_chat_preferences(user_id, post_id, muted=True)
    repository.delete_post("deleted")
    assert repository.event_chat_preferences("owner", ["deleted"]) == {}
    assert repository.event_chat_preferences("guest", ["deleted"]) == {}
    repository.delete_user_social("guest")
    assert repository.event_chat_preferences("guest", ["retained"]) == {}
    assert repository.event_chat_preferences("owner", ["retained"])["retained"]["muted"] is True
