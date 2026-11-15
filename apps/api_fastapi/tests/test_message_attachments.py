"""Private attachment message contracts; no object storage or external calls."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-chat-message-tests-"))

from app.core import media_uploads
from app.core.direct_messages import DirectMessageService, JsonDirectMessageRepository, PostgresDirectMessageRepository
from app.core.media_uploads import MediaUploadLedger, UploadLimits, UploadReservation
from app.core.models import EventChatMessage, SocialPost, build_seed
from app.core.postgres_social import PostgresSocialRepository
from app.core.store import store
from app.modules.messages.router import SendMessage
from app.modules.social.router import EventChatMessageCreateRequest
from app.modules.auth import router as auth_router
from test_direct_messages import Accounts


@pytest.fixture
def messages(tmp_path, monkeypatch):
    accounts = Accounts()
    for user in accounts.users.values():
        user.email = f"{user.id}@example.com"
    repository = JsonDirectMessageRepository(tmp_path / "messages.json")
    service = DirectMessageService(accounts, repository)
    ledger = MediaUploadLedger()
    monkeypatch.setattr(media_uploads, "upload_ledger", ledger)
    return accounts, repository, service, ledger


def _reserve(ledger, user, kind, scope, identifier="private-photo", media_type="photo", purpose="chat"):
    now = datetime.now(timezone.utc)
    row = UploadReservation(
        id=identifier, user_id=user.id, client_ip_hash="fixture",
        media_type=media_type, content_type="image/jpeg" if media_type == "photo" else "video/mp4",
        thumbnail_content_type=None, expected_bytes=100, expected_thumbnail_bytes=0,
        pending_name="private/pending", final_name="private/final",
        pending_thumbnail_name=None, final_thumbnail_name=None,
        public_url="", thumbnail_public_url="", status="complete",
        created_at=now, expires_at=now + timedelta(minutes=15),
        purpose=purpose, scope_type=kind, scope_id=scope,
        storage_provider="chat_bunny" if media_type == "video" else "chat_r2",
        chat_video_resolutions="240p,480p" if media_type == "video" else None,
        chat_video_mp4_resolution="480p" if media_type == "video" else None,
    )
    return ledger.reserve(row, UploadLimits.from_env())


def _accepted(accounts, service):
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    service.set_request(bob, thread, True, None)
    return alice, bob, thread


@pytest.mark.parametrize("media_type", ["photo", "video"])
def test_attachment_only_dm_persists_descriptor_and_idempotency(messages, media_type):
    accounts, repository, service, ledger = messages
    alice, bob, thread = _accepted(accounts, service)
    reservation = _reserve(ledger, alice, "direct", thread, media_type=media_type)
    sent = service.send(alice, thread, "", "client-photo", None, reservation.id)
    assert sent["attachment"] == {"id": reservation.id, "media_type": media_type}
    assert "url" not in json.dumps(sent)
    assert service.send(alice, thread, "", "client-photo", None, reservation.id) == sent
    assert ledger.get(reservation.id, alice.id).message_id == sent["id"]
    assert service.unread_count(bob)["unread_count"] == 1
    restarted = DirectMessageService(accounts, JsonDirectMessageRepository(repository.path))
    assert restarted.get_thread(bob, thread)["messages"][0]["attachment"] == sent["attachment"]
    assert restarted.list_threads(bob)["threads"][0]["preview"] == ("Photo" if media_type == "photo" else "Video")


def test_pending_or_declined_dm_never_claims_private_attachment(messages):
    accounts, _, service, ledger = messages
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    thread = service.create_thread(alice, bob.id)["id"]
    assert service.get_thread(alice, thread)["can_send_attachments"] is False
    row = _reserve(ledger, alice, "direct", thread)
    with pytest.raises(HTTPException) as denied:
        service.send(alice, thread, "caption", "pending", None, row.id)
    assert denied.value.status_code == 403
    assert ledger.get(row.id, alice.id).status == "complete"
    assert service.send(alice, thread, "A normal message request", "text", None)["text"]
    service.set_request(bob, thread, True, None)
    assert service.get_thread(alice, thread)["can_send_attachments"] is True
    service.set_request(bob, thread, None, True)
    assert service.get_thread(alice, thread)["can_send_attachments"] is False
    with pytest.raises(HTTPException):
        service.authorize_media(alice, thread)


def test_private_dm_attachment_rejects_wrong_owner_thread_purpose_or_reuse(messages):
    accounts, _, service, ledger = messages
    alice, bob, thread = _accepted(accounts, service)
    own = _reserve(ledger, alice, "direct", thread)
    other = _reserve(ledger, bob, "direct", thread, identifier="bob-photo")
    social = _reserve(ledger, alice, "direct", thread, identifier="public-post-photo", purpose="social")
    wrong = _reserve(ledger, alice, "event", "another-room", identifier="event-only-photo")
    for row in (other, social, wrong):
        with pytest.raises(HTTPException):
            service.send(alice, thread, "", row.id, None, row.id)
    service.send(alice, thread, "caption", "original", None, own.id)
    with pytest.raises(HTTPException) as reused:
        service.send(alice, thread, "caption", "another-message", None, own.id)
    assert reused.value.status_code == 409
    with pytest.raises(HTTPException) as changed:
        service.send(alice, thread, "changed caption", "original", None, own.id)
    assert changed.value.status_code == 409


def test_concurrent_private_dm_retry_claims_only_one_message(messages):
    accounts, repository, service, ledger = messages
    alice, bob, thread = _accepted(accounts, service)
    row = _reserve(ledger, alice, "direct", thread)
    services = [DirectMessageService(accounts, JsonDirectMessageRepository(repository.path)) for _ in range(6)]
    with ThreadPoolExecutor(max_workers=6) as pool:
        sent = list(pool.map(lambda current: current.send(alice, thread, "", "same-client", None, row.id), services))
    assert len({message["id"] for message in sent}) == 1
    assert len(service.get_thread(bob, thread)["messages"]) == 1


def test_attachment_access_requires_a_durable_message_not_only_a_claim(messages):
    accounts, _, service, ledger = messages
    alice, bob, thread = _accepted(accounts, service)
    row = _reserve(ledger, alice, "direct", thread)
    ledger.claim_chat_media(alice.id, "direct", thread, [row.id], "orphan-claim", "orphan-client")
    assert not service.attachment_message_exists(bob, thread, "orphan-claim", row.id)
    another = _reserve(ledger, alice, "direct", thread, identifier="delivered-photo")
    sent = service.send(alice, thread, "", "delivered-client", None, another.id)
    assert service.attachment_message_exists(bob, thread, sent["id"], another.id)
    assert not service.attachment_message_exists(bob, thread, sent["id"], row.id)


def test_deleting_direct_conversation_queues_both_participants_media(messages):
    accounts, repository, service, ledger = messages
    alice, bob, thread = _accepted(accounts, service)
    first = _reserve(ledger, alice, "direct", thread, identifier="alice-dm-photo")
    second = _reserve(ledger, bob, "direct", thread, identifier="bob-dm-photo")
    unrelated = _reserve(ledger, bob, "event", "another-room", identifier="other-event-photo")
    service.send(alice, thread, "", "first-photo", None, first.id)
    service.send(bob, thread, "", "second-photo", None, second.id)
    repository.delete_user(alice.id)
    assert ledger.get(first.id, alice.id).status == "deletion_pending"
    assert ledger.get(second.id, bob.id).status == "deletion_pending"
    assert ledger.get(unrelated.id, bob.id).status == "complete"
    assert repository.get_thread(thread, bob.id) is None


@pytest.mark.parametrize("fail_delete", [False, True])
def test_account_media_cleanup_only_queues_after_successful_account_delete(monkeypatch, fail_delete):
    queued = []
    user = SimpleNamespace(id="original-user")
    def delete_account():
        if fail_delete:
            raise OSError("Simulated account storage failure")
        user.id = "signed-out-user"
        return "signed-out-result"
    monkeypatch.setattr(auth_router, "store", SimpleNamespace(delete_current_account=delete_account))
    monkeypatch.setattr(auth_router, "queue_account_media_deletion", queued.append)
    if fail_delete:
        with pytest.raises(OSError):
            auth_router.delete_account(user)
        assert queued == []
    else:
        assert auth_router.delete_account(user) == "signed-out-result"
        assert queued == ["original-user"]


@pytest.mark.parametrize("blocker,peer", [("alice", "bob"), ("bob", "alice")])
def test_media_authorization_rechecks_blocks_and_bans(messages, blocker, peer):
    accounts, _, service, _ = messages
    alice, bob, thread = _accepted(accounts, service)
    accounts.relationships[blocker]["blocked_user_ids"].append(peer)
    with pytest.raises(HTTPException) as denied:
        service.authorize_media(alice, thread)
    assert denied.value.status_code == 404
    accounts.relationships[blocker]["blocked_user_ids"].clear()
    bob.banned = True
    with pytest.raises(HTTPException):
        service.authorize_media(alice, thread)


def test_message_requests_reject_untrusted_urls_and_empty_content():
    assert SendMessage(attachment_id="ready-private-upload", client_message_id="client").text == ""
    assert EventChatMessageCreateRequest(attachment_id="ready-private-upload", client_message_id="client").text == ""
    for model, payload in (
        (SendMessage, {"text": "", "client_message_id": "client"}),
        (SendMessage, {"text": "x", "client_message_id": "client", "url": "https://untrusted.invalid"}),
        (EventChatMessageCreateRequest, {"attachment_id": "missing-client"}),
        (EventChatMessageCreateRequest, {"text": "  "}),
        (EventChatMessageCreateRequest, {"text": "x", "attachment": {"url": "https://untrusted.invalid"}}),
    ):
        with pytest.raises(ValidationError):
            model(**payload)


@pytest.fixture
def event_room(messages, tmp_path, monkeypatch):
    accounts, _, _, ledger = messages
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    event = SocialPost(id="private-event", user_id=alice.id, author_name="Alice", post_type="surf_plan", body="Meet at the break", created_at=datetime.now(timezone.utc))
    monkeypatch.setattr(store, "postgres_social", None)
    monkeypatch.setattr(store, "postgres_auth", None)
    monkeypatch.setattr(store, "posts", [event])
    monkeypatch.setattr(store, "event_chat_messages", [])
    monkeypatch.setattr(store, "rsvp_user_ids_by_post", {event.id: {alice.id, bob.id}})
    monkeypatch.setattr(store, "auth_accounts", {user.email: {"user": user.model_dump(mode="json")} for user in accounts.users.values()})
    monkeypatch.setattr(store, "state_file", tmp_path / "event-state.json")
    monkeypatch.setattr(store, "get_auth_user_by_id", accounts.get_auth_user_by_id)
    monkeypatch.setattr(store, "_blocked_user_ids_for", lambda user_id: set(accounts.relationships[user_id]["blocked_user_ids"]))
    monkeypatch.setattr(store, "_save_current_account_user", lambda: None)
    return accounts, ledger, event


def test_event_private_attachment_caption_retry_and_local_restart(event_room):
    accounts, ledger, event = event_room
    bob = accounts.users["bob"]
    row = _reserve(ledger, bob, "event", event.id)
    with store.request_user_context(bob):
        first = store.add_event_chat_message(post_id=event.id, message_id="ignored", text="Photo from today", client_message_id="photo-client", attachment_id=row.id)
        retry = store.add_event_chat_message(post_id=event.id, message_id="different-server-id", text="Photo from today", client_message_id="photo-client", attachment_id=row.id)
        assert retry.id == first.id and len(store.event_chat_messages) == 1
        assert first.user_id == bob.id and first.attachment.id == row.id
        assert store.event_attachment_message_exists(event.id, first.id, row.id)
        assert not store.event_attachment_message_exists(event.id, "orphan-claim", row.id)
        store.event_chat_messages = []
        store._load_state()
        assert store.event_chat_messages[0].attachment.id == row.id
        with pytest.raises(HTTPException) as changed:
            store.add_event_chat_message(post_id=event.id, message_id="ignored", text="Changed", client_message_id="photo-client", attachment_id=row.id)
        assert changed.value.status_code == 409


def test_event_media_access_revokes_on_leave_host_block_and_sender_ban(event_room):
    accounts, _, event = event_room
    alice, bob, carol = [accounts.users[name] for name in ("alice", "bob", "carol")]
    with store.request_user_context(bob):
        assert store.can_access_event_chat(event.id, sender_user_id=alice.id)
        store.rsvp_user_ids_by_post[event.id].remove(bob.id)
        assert not store.can_access_event_chat(event.id)
        store.rsvp_user_ids_by_post[event.id].add(bob.id)
        accounts.relationships[alice.id]["blocked_user_ids"].append(bob.id)
        assert not store.can_access_event_chat(event.id)
        accounts.relationships[alice.id]["blocked_user_ids"].clear()
        carol.banned = True
        assert not store.can_access_event_chat(event.id, sender_user_id=carol.id)


def test_event_failed_persistence_does_not_expose_attachment_and_retry_saves(event_room, monkeypatch):
    accounts, ledger, event = event_room
    bob = accounts.users["bob"]
    row = _reserve(ledger, bob, "event", event.id)
    save_state = store._save_state
    def fail_save():
        raise OSError("Simulated unavailable disk")
    with store.request_user_context(bob):
        monkeypatch.setattr(store, "_save_state", fail_save)
        with pytest.raises(OSError):
            store.add_event_chat_message(post_id=event.id, message_id="ignored", text="", client_message_id="retry-after-disk-failure", attachment_id=row.id)
        assert store.event_chat_messages == []
        claimed = ledger.get(row.id, bob.id)
        assert claimed.status == "used"
        assert not store.event_attachment_message_exists(event.id, claimed.message_id, row.id)
        monkeypatch.setattr(store, "_save_state", save_state)
        message = store.add_event_chat_message(post_id=event.id, message_id="ignored", text="", client_message_id="retry-after-disk-failure", attachment_id=row.id)
        assert message.id == claimed.message_id
        assert store.event_attachment_message_exists(event.id, message.id, row.id)
        assert row.id in store.state_file.read_text()


def test_deleting_event_queues_every_members_media_but_leaving_does_not(event_room):
    accounts, ledger, event = event_room
    alice, bob = accounts.users["alice"], accounts.users["bob"]
    first = _reserve(ledger, alice, "event", event.id, identifier="host-photo")
    second = _reserve(ledger, bob, "event", event.id, identifier="guest-photo")
    with store.request_user_context(bob):
        store.add_event_chat_message(post_id=event.id, message_id="ignored", text="", client_message_id="guest-photo", attachment_id=second.id)
        store.rsvp_user_ids_by_post[event.id].remove(bob.id)
        assert ledger.get(second.id, bob.id).status == "used"
    with store.request_user_context(alice):
        assert store.delete_post(event.id, alice.id).id == event.id
        assert store.event_chat_messages == []
    assert ledger.get(first.id, alice.id).status == "deletion_pending"
    assert ledger.get(second.id, bob.id).status == "deletion_pending"


class _Result:
    def __init__(self, value=None):
        self.value = value
    def fetchone(self):
        return self.value
    def fetchall(self):
        return self.value if isinstance(self.value, list) else []


@pytest.mark.parametrize("scope_type", ["direct", "event"])
@pytest.mark.parametrize("fail_delete", [False, True])
def test_postgres_scope_cleanup_commits_or_rolls_back_with_message_deletion(scope_type, fail_delete):
    # Model the production social connection's autocommit=True behavior:
    # outside an explicit transaction each mutation would survive a later
    # failed DELETE. Use the real ledger UPDATE, not a mocked queue callback.
    calls = []
    class Connection:
        active = False
        transactions = 0
        attachment_status = "used"
        message_exists = True
        def __enter__(self):
            return self
        def __exit__(self, *_args):
            pass
        @contextmanager
        def transaction(self):
            before = self.attachment_status, self.message_exists
            self.active = True
            self.transactions += 1
            try:
                yield
            except Exception:
                self.attachment_status, self.message_exists = before
                raise
            finally:
                self.active = False
        def execute(self, query, params):
            calls.append(query)
            if "UPDATE media_upload_reservations" in query:
                assert self.active, "Private cleanup must not commit before conversation deletion"
                assert params == (scope_type, "thread-to-delete" if scope_type == "direct" else "event-to-delete")
                self.attachment_status = "deletion_pending"
            if "DELETE FROM direct_message_threads" in query or "DELETE FROM social_posts" in query:
                assert self.active
                if fail_delete:
                    raise OSError("Simulated SQL deletion failure")
                self.message_exists = False
            return _Result([{"id": "thread-to-delete"}] if "SELECT id FROM direct_message_threads" in query else [])
    connection = Connection()
    if scope_type == "direct":
        repository = object.__new__(PostgresDirectMessageRepository)
        repository.social = SimpleNamespace(_connect=lambda: connection)
        delete = lambda: repository.delete_user("alice")
    else:
        repository = object.__new__(PostgresSocialRepository)
        repository._connect = lambda: connection
        delete = lambda: repository.delete_post("event-to-delete")
    if fail_delete:
        with pytest.raises(OSError):
            delete()
        assert connection.attachment_status == "used"
        assert connection.message_exists
    else:
        delete()
        assert connection.attachment_status == "deletion_pending"
        assert not connection.message_exists
    assert connection.transactions == 1
    assert any("DELETE FROM" in query for query in calls)


def test_postgres_event_attachment_claim_uses_message_transaction():
    statements, claimed = [], []
    class Connection:
        active = False
        def __enter__(self):
            return self
        def __exit__(self, *_args):
            pass
        @contextmanager
        def transaction(self):
            self.active = True
            try:
                yield
            finally:
                self.active = False
        def execute(self, query, params):
            statements.append((query, params))
            return _Result()
    connection = Connection()
    repository = object.__new__(PostgresSocialRepository)
    repository._connect = lambda: connection
    repository._jsonb = lambda value: value
    message = EventChatMessage(id="stable-event-message", post_id="room", user_id="alice", author_name="Alice", created_at=datetime.now(timezone.utc), attachment={"id": "photo", "media_type": "photo"})
    def claim(identifier, conn):
        assert conn is connection and connection.active
        claimed.append(identifier)
    assert repository.save_event_message(message, claim_attachment=claim) == message
    assert claimed == [message.id]
    assert any("INSERT INTO social_event_messages" in query for query, _ in statements)


def test_postgres_direct_attachment_claim_and_insert_share_transaction():
    stored, claimed = {}, []
    class Connection:
        active = False
        def __enter__(self):
            return self
        def __exit__(self, *_args):
            pass
        @contextmanager
        def transaction(self):
            self.active = True
            try:
                yield
            finally:
                self.active = False
        def execute(self, query, params):
            if "SELECT t.id FROM direct_message_threads" in query:
                return _Result({"id": "thread"})
            if "SELECT * FROM direct_messages" in query:
                return _Result(stored.get("message"))
            if "COUNT(*) AS count" in query:
                return _Result({"count": 0, "minute_count": 0})
            if "INSERT INTO direct_messages" in query:
                assert self.active
                stored["message"] = dict(zip(("id", "thread_id", "sender_user_id", "text", "client_message_id", "shared_post_id", "attachment"), params))
                stored["message"]["created_at"] = datetime.now(timezone.utc)
                return _Result(stored["message"])
            return _Result()
    connection = Connection()
    repository = object.__new__(PostgresDirectMessageRepository)
    repository.social = SimpleNamespace(_connect=lambda: connection, _jsonb=lambda value: value)
    descriptor = {"id": "private-photo", "media_type": "photo"}
    def claim(identifier, conn):
        assert connection.active and conn is connection
        claimed.append(identifier)
    sent = repository.send("thread", "alice", "caption", "client", None, 100, attachment=descriptor, claim_attachment=claim)
    retry = repository.send("thread", "alice", "caption", "client", None, 100, attachment=descriptor, claim_attachment=claim)
    assert retry == sent and claimed == [sent["id"]]
