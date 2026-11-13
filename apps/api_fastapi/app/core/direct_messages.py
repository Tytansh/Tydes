"""Account-scoped direct messages. No local-client payload is trusted as delivery."""
from __future__ import annotations

from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile
from threading import RLock
from typing import Any
from uuid import uuid4

from fastapi import HTTPException

from app.core.models import User


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime | str) -> str:
    return value.isoformat() if isinstance(value, datetime) else value


def _thread_id(first: str, second: str) -> str:
    pair = "\0".join(sorted((first, second)))
    return "dm_" + hashlib.sha256(pair.encode()).hexdigest()[:32]


class JsonDirectMessageRepository:
    """Durable single-host fallback; file locking also covers multiple workers."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = RLock()

    @contextmanager
    def _state(self, write: bool = False):
        import fcntl
        with self._lock, self.path.with_suffix(".lock").open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                state = json.loads(self.path.read_text()) if self.path.exists() else {"threads": {}}
                if not isinstance(state, dict) or not isinstance(state.get("threads"), dict):
                    raise ValueError("Invalid message storage.")
                yield state
                if write:
                    name = None
                    try:
                        with tempfile.NamedTemporaryFile(mode="w", dir=self.path.parent, prefix=".messages-", delete=False) as temporary:
                            name = temporary.name
                            json.dump(state, temporary)
                            temporary.flush()
                            os.fsync(temporary.fileno())
                        os.replace(name, self.path)
                    finally:
                        if name is not None and os.path.exists(name):
                            os.unlink(name)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def ensure_thread(self, user_id: str, peer_id: str, recipient_accepts: bool) -> dict:
        identifier = _thread_id(user_id, peer_id)
        with self._state(True) as state:
            threads = state["threads"]
            if identifier not in threads:
                cutoff = (_now() - timedelta(days=1)).isoformat()
                created = sum(thread.get("created_by_user_id") == user_id and thread["created_at"] >= cutoff
                              for thread in threads.values())
                if created >= 30:
                    raise HTTPException(status_code=429, detail="You can start up to 30 new conversations per day.", headers={"Retry-After": "3600"})
                threads[identifier] = {
                    "id": identifier, "user_a": min(user_id, peer_id), "user_b": max(user_id, peer_id),
                    "created_by_user_id": user_id,
                    "created_at": _now().isoformat(), "updated_at": _now().isoformat(), "messages": [],
                    "participants": {
                        user_id: {"accepted": True, "declined": False, "read_sequence": 0},
                        peer_id: {"accepted": recipient_accepts, "declined": False, "read_sequence": 0},
                    },
                }
            thread = threads[identifier]
            thread["participants"][user_id].update(accepted=True, declined=False)
            return deepcopy(thread)

    def get_thread(self, thread_id: str, user_id: str) -> dict | None:
        with self._state() as state:
            thread = state["threads"].get(thread_id)
            if thread is None or user_id not in thread["participants"]:
                return None
            return deepcopy(thread)

    def list_threads(self, user_id: str) -> list[dict]:
        with self._state() as state:
            return deepcopy(sorted(
                (thread for thread in state["threads"].values()
                 if user_id in thread["participants"] and not thread["participants"][user_id]["declined"] and thread["messages"]),
                key=lambda item: item["updated_at"], reverse=True,
            ))

    def unread_threads(self, user_id: str) -> list[dict]:
        return self.list_threads(user_id)

    def send(self, thread_id: str, user_id: str, text: str, client_id: str, shared_post_id: str | None, daily_limit: int) -> dict:
        with self._state(True) as state:
            thread = state["threads"].get(thread_id)
            if thread is None or user_id not in thread["participants"]:
                raise HTTPException(status_code=404, detail="Conversation not found.")
            for message in thread["messages"]:
                if message["sender_user_id"] == user_id and message["client_message_id"] == client_id:
                    if message["text"] != text or message.get("shared_post_id") != shared_post_id:
                        raise HTTPException(status_code=409, detail="This message retry has different content.")
                    return deepcopy(message)
            cutoff = (_now() - timedelta(days=1)).isoformat()
            sent = sum(message["sender_user_id"] == user_id and message["created_at"] >= cutoff
                       for item in state["threads"].values() for message in item["messages"])
            if sent >= daily_limit:
                raise HTTPException(status_code=429, detail=f"You can send up to {daily_limit} messages per day.", headers={"Retry-After": "3600"})
            minute_cutoff = (_now() - timedelta(minutes=1)).isoformat()
            minute_count = sum(message["sender_user_id"] == user_id and message["created_at"] >= minute_cutoff
                               for item in state["threads"].values() for message in item["messages"])
            if minute_count >= 20:
                raise HTTPException(status_code=429, detail="Please wait a moment before sending more messages.", headers={"Retry-After": "60"})
            message = {
                "id": "message_" + uuid4().hex, "sender_user_id": user_id,
                "text": text, "client_message_id": client_id,
                "created_at": _now().isoformat(), "shared_post_id": shared_post_id,
                "sequence": len(thread["messages"]) + 1,
            }
            thread["messages"].append(message)
            thread["updated_at"] = message["created_at"]
            thread["participants"][user_id].update(accepted=True, declined=False)
            return deepcopy(message)

    def mark_read(self, thread_id: str, user_id: str, last_message_id: str) -> int:
        with self._state(True) as state:
            thread = state["threads"].get(thread_id)
            if thread is None or user_id not in thread["participants"]:
                raise HTTPException(status_code=404, detail="Conversation not found.")
            marker = next((item for item in thread["messages"] if item["id"] == last_message_id), None)
            if marker is None:
                raise HTTPException(status_code=404, detail="Message not found in this conversation.")
            participant = thread["participants"][user_id]
            participant["read_sequence"] = max(participant["read_sequence"], marker["sequence"])
            return _unread(thread, user_id)

    def set_request(self, thread_id: str, user_id: str, accepted: bool | None, declined: bool | None) -> dict:
        with self._state(True) as state:
            thread = state["threads"].get(thread_id)
            if thread is None or user_id not in thread["participants"]:
                raise HTTPException(status_code=404, detail="Conversation not found.")
            participant = thread["participants"][user_id]
            if accepted is not None:
                participant["accepted"] = accepted
                if accepted:
                    participant["declined"] = False
            if declined is not None:
                participant["declined"] = declined
            return deepcopy(thread)

    def delete_user(self, user_id: str) -> None:
        with self._state(True) as state:
            state["threads"] = {key: thread for key, thread in state["threads"].items() if user_id not in thread["participants"]}
            state["blocks"] = {owner: [peer for peer in peers if peer != user_id]
                               for owner, peers in state.get("blocks", {}).items() if owner != user_id}

    def set_block(self, user_id: str, peer_id: str, blocked: bool) -> None:
        with self._state(True) as state:
            owners = state.setdefault("blocks", {})
            peers = set(owners.get(user_id, []))
            if blocked:
                peers.add(peer_id)
            else:
                peers.discard(peer_id)
            owners[user_id] = sorted(peers)

    def blocked_users(self, user_id: str) -> list[str]:
        with self._state() as state:
            return list(state.get("blocks", {}).get(user_id, []))

    def blocked_users_either_direction(self, user_id: str) -> set[str]:
        with self._state() as state:
            blocks = state.get("blocks", {})
            return set(blocks.get(user_id, [])) | {
                owner for owner, peers in blocks.items() if user_id in peers
            }


def _unread(thread: dict, user_id: str) -> int:
    participant = thread["participants"][user_id]
    if participant["declined"]:
        return 0
    return sum(message["sender_user_id"] != user_id and message["sequence"] > participant["read_sequence"] for message in thread["messages"])


class PostgresDirectMessageRepository:
    def __init__(self, social_repository) -> None:
        self.social = social_repository
        self._ensure_schema()

    def _ensure_schema(self) -> None:
        with self.social._connect() as connection:
            connection.execute("""CREATE TABLE IF NOT EXISTS direct_message_threads (
                id TEXT PRIMARY KEY, user_a TEXT NOT NULL, user_b TEXT NOT NULL,
                created_by_user_id TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE(user_a, user_b),
                CONSTRAINT direct_message_thread_pair_order_c
                    CHECK(user_a COLLATE "C" < user_b COLLATE "C"))""")
            # IDs are sorted by Python's case-sensitive codepoint order. The
            # database's default locale may sort mixed-case IDs differently,
            # so its old implicit CHECK rejected otherwise valid new pairs.
            # Add/validate the replacement before dropping only our v1 check;
            # this block is atomic and safe to repeat after deployments.
            connection.execute('''DO $$ BEGIN
                PERFORM pg_advisory_xact_lock(hashtext('dm-pair-collation-v2'));
                IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid='direct_message_threads'::regclass
                    AND conname='direct_message_thread_pair_order_c') THEN
                    ALTER TABLE direct_message_threads
                        ADD CONSTRAINT direct_message_thread_pair_order_c
                        CHECK(user_a COLLATE "C" < user_b COLLATE "C");
                END IF;
                ALTER TABLE direct_message_threads
                    DROP CONSTRAINT IF EXISTS direct_message_threads_check;
            END; $$''')
            connection.execute("ALTER TABLE direct_message_threads ADD COLUMN IF NOT EXISTS created_by_user_id TEXT")
            connection.execute("CREATE INDEX IF NOT EXISTS direct_message_thread_creation_idx ON direct_message_threads(created_by_user_id, created_at DESC)")
            connection.execute("""CREATE TABLE IF NOT EXISTS direct_message_participants (
                thread_id TEXT NOT NULL REFERENCES direct_message_threads(id) ON DELETE CASCADE,
                user_id TEXT NOT NULL, accepted BOOLEAN NOT NULL DEFAULT FALSE,
                declined BOOLEAN NOT NULL DEFAULT FALSE, read_sequence BIGINT NOT NULL DEFAULT 0,
                PRIMARY KEY(thread_id, user_id))""")
            connection.execute("""CREATE TABLE IF NOT EXISTS direct_messages (
                id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES direct_message_threads(id) ON DELETE CASCADE,
                sequence BIGSERIAL UNIQUE, sender_user_id TEXT NOT NULL, text TEXT NOT NULL,
                client_message_id TEXT NOT NULL, shared_post_id TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE(thread_id, sender_user_id, client_message_id))""")
            connection.execute("CREATE INDEX IF NOT EXISTS direct_message_inbox_idx ON direct_message_participants(user_id, thread_id)")
            connection.execute("CREATE INDEX IF NOT EXISTS direct_message_thread_sequence_idx ON direct_messages(thread_id, sequence DESC)")
            connection.execute("CREATE INDEX IF NOT EXISTS direct_message_daily_idx ON direct_messages(sender_user_id, created_at DESC)")

    def _get(self, connection, thread_id: str, user_id: str, *, all_messages: bool = False) -> dict | None:
        row = connection.execute("""SELECT t.* FROM direct_message_threads t
            JOIN direct_message_participants p ON p.thread_id=t.id
            WHERE t.id=%s AND p.user_id=%s""", (thread_id, user_id)).fetchone()
        if row is None:
            return None
        participants = connection.execute("SELECT * FROM direct_message_participants WHERE thread_id=%s", (thread_id,)).fetchall()
        # The aggregate count is exact even when only the newest messages are loaded.
        unread = connection.execute("""SELECT COUNT(*) AS count FROM direct_messages m
            JOIN direct_message_participants p ON p.thread_id=m.thread_id AND p.user_id=%s
            WHERE m.thread_id=%s AND m.sender_user_id<>%s AND m.sequence>p.read_sequence AND NOT p.declined""", (user_id, thread_id, user_id)).fetchone()
        limit = "" if all_messages else " LIMIT 100"
        messages = connection.execute("SELECT * FROM direct_messages WHERE thread_id=%s ORDER BY sequence DESC" + limit, (thread_id,)).fetchall()
        return {
            **dict(row), "created_at": _iso(row["created_at"]), "updated_at": _iso(row["updated_at"]),
            "participants": {item["user_id"]: {"accepted": item["accepted"], "declined": item["declined"], "read_sequence": item["read_sequence"]} for item in participants},
            "messages": [{**dict(item), "created_at": _iso(item["created_at"])} for item in reversed(messages)],
            "unread_count": int(unread["count"]),
        }

    def ensure_thread(self, user_id: str, peer_id: str, recipient_accepts: bool) -> dict:
        identifier = _thread_id(user_id, peer_id)
        with self.social._connect() as connection, connection.transaction():
            connection.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("dm-sender:" + user_id,))
            existing = connection.execute("SELECT id FROM direct_message_threads WHERE id=%s", (identifier,)).fetchone()
            if existing is None:
                created = connection.execute("""SELECT COUNT(*) AS count FROM direct_message_threads
                    WHERE created_by_user_id=%s AND created_at>NOW()-INTERVAL '24 hours'""", (user_id,)).fetchone()
                if created["count"] >= 30:
                    raise HTTPException(status_code=429, detail="You can start up to 30 new conversations per day.", headers={"Retry-After": "3600"})
                connection.execute("INSERT INTO direct_message_threads(id,user_a,user_b,created_by_user_id) VALUES(%s,%s,%s,%s) ON CONFLICT DO NOTHING", (identifier, min(user_id, peer_id), max(user_id, peer_id), user_id))
            for participant, accepted in [(user_id, True), (peer_id, recipient_accepts)]:
                connection.execute("INSERT INTO direct_message_participants(thread_id,user_id,accepted) VALUES(%s,%s,%s) ON CONFLICT DO NOTHING", (identifier, participant, accepted))
            connection.execute("UPDATE direct_message_participants SET accepted=TRUE,declined=FALSE WHERE thread_id=%s AND user_id=%s", (identifier, user_id))
            return self._get(connection, identifier, user_id)

    def get_thread(self, thread_id: str, user_id: str) -> dict | None:
        with self.social._connect() as connection:
            return self._get(connection, thread_id, user_id)

    def list_threads(self, user_id: str) -> list[dict]:
        # One bounded query loads only the last preview per thread. Never fetch
        # a hundred message bodies per inbox row, or perform N+1 user lookups.
        with self.social._connect() as connection:
            rows = connection.execute("""SELECT t.*, p.accepted, p.declined, p.read_sequence,
                peer.user_payload AS peer_payload,
                latest.id AS last_id, latest.sender_user_id AS last_sender,
                latest.text AS last_text, latest.client_message_id AS last_client_id,
                latest.created_at AS last_created_at, latest.sequence AS last_sequence,
                latest.shared_post_id AS last_shared_post_id,
                unread.count AS unread_count
                FROM direct_message_threads t
                JOIN direct_message_participants p ON p.thread_id=t.id
                JOIN auth_accounts peer ON peer.user_payload->>'id'=CASE WHEN t.user_a=%s THEN t.user_b ELSE t.user_a END
                JOIN LATERAL (SELECT * FROM direct_messages m WHERE m.thread_id=t.id
                    ORDER BY m.sequence DESC LIMIT 1) latest ON TRUE
                JOIN LATERAL (SELECT COUNT(*) AS count FROM direct_messages m
                    WHERE m.thread_id=t.id AND m.sender_user_id<>%s
                    AND m.sequence>p.read_sequence) unread ON TRUE
                WHERE p.user_id=%s AND NOT p.declined
                AND NOT COALESCE((peer.user_payload->>'banned')::boolean,FALSE)
                AND NOT EXISTS(SELECT 1 FROM social_blocks b
                    WHERE (b.user_id=%s AND b.blocked_user_id=peer.user_payload->>'id')
                       OR (b.blocked_user_id=%s AND b.user_id=peer.user_payload->>'id'))
                ORDER BY t.updated_at DESC LIMIT 100""", (user_id,) * 5).fetchall()
            return [{
                "id": row["id"], "user_a": row["user_a"], "user_b": row["user_b"],
                "created_at": _iso(row["created_at"]), "updated_at": _iso(row["updated_at"]),
                "participants": {user_id: {"accepted": row["accepted"], "declined": row["declined"], "read_sequence": row["read_sequence"]}},
                "unread_count": int(row["unread_count"]),
                "_peer": User.model_validate(row["peer_payload"]),
                "messages": [{"id": row["last_id"], "sender_user_id": row["last_sender"],
                    "text": row["last_text"], "client_message_id": row["last_client_id"],
                    "created_at": _iso(row["last_created_at"]), "sequence": row["last_sequence"],
                    "shared_post_id": row["last_shared_post_id"]}],
            } for row in rows]

    def unread_count(self, user_id: str) -> int:
        # Count every unread inbound message, not just the inbox's first page.
        # Peer eligibility is evaluated in one bounded-shape query: no message
        # bodies or N+1 profile requests are needed for polling badges.
        with self.social._connect() as connection:
            row = connection.execute("""SELECT COUNT(*) AS count
                FROM direct_messages m
                JOIN direct_message_participants p ON p.thread_id=m.thread_id AND p.user_id=%s
                JOIN direct_message_threads t ON t.id=m.thread_id
                JOIN auth_accounts peer ON peer.user_payload->>'id'=CASE WHEN t.user_a=%s THEN t.user_b ELSE t.user_a END
                WHERE m.sender_user_id<>%s AND m.sequence>p.read_sequence AND NOT p.declined
                AND NOT COALESCE((peer.user_payload->>'banned')::boolean,FALSE)
                AND NOT EXISTS(SELECT 1 FROM social_blocks b
                    WHERE (b.user_id=%s AND b.blocked_user_id=peer.user_payload->>'id')
                       OR (b.blocked_user_id=%s AND b.user_id=peer.user_payload->>'id'))""",
                (user_id, user_id, user_id, user_id, user_id)).fetchone()
            return int(row["count"])

    def send(self, thread_id: str, user_id: str, text: str, client_id: str, shared_post_id: str | None, daily_limit: int) -> dict:
        with self.social._connect() as connection, connection.transaction():
            # This lock serializes each sender's daily quota across all threads.
            connection.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("dm-sender:" + user_id,))
            row = connection.execute("""SELECT t.id FROM direct_message_threads t
                JOIN direct_message_participants p ON p.thread_id=t.id
                WHERE t.id=%s AND p.user_id=%s FOR UPDATE OF t""", (thread_id, user_id)).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Conversation not found.")
            previous = connection.execute("SELECT * FROM direct_messages WHERE thread_id=%s AND sender_user_id=%s AND client_message_id=%s", (thread_id, user_id, client_id)).fetchone()
            if previous is not None:
                if previous["text"] != text or previous["shared_post_id"] != shared_post_id:
                    raise HTTPException(status_code=409, detail="This message retry has different content.")
                return {**dict(previous), "created_at": _iso(previous["created_at"])}
            count = connection.execute("""SELECT COUNT(*) AS count,
                COUNT(*) FILTER (WHERE created_at>NOW()-INTERVAL '1 minute') AS minute_count
                FROM direct_messages WHERE sender_user_id=%s AND created_at>NOW()-INTERVAL '24 hours'""", (user_id,)).fetchone()
            if count["count"] >= daily_limit:
                raise HTTPException(status_code=429, detail=f"You can send up to {daily_limit} messages per day.", headers={"Retry-After": "3600"})
            if count["minute_count"] >= 20:
                raise HTTPException(status_code=429, detail="Please wait a moment before sending more messages.", headers={"Retry-After": "60"})
            message = connection.execute("""INSERT INTO direct_messages(id,thread_id,sender_user_id,text,client_message_id,shared_post_id)
                VALUES(%s,%s,%s,%s,%s,%s) RETURNING *""", ("message_" + uuid4().hex, thread_id, user_id, text, client_id, shared_post_id)).fetchone()
            connection.execute("UPDATE direct_message_threads SET updated_at=%s WHERE id=%s", (message["created_at"], thread_id))
            connection.execute("UPDATE direct_message_participants SET accepted=TRUE,declined=FALSE WHERE thread_id=%s AND user_id=%s", (thread_id, user_id))
            return {**dict(message), "created_at": _iso(message["created_at"])}

    def mark_read(self, thread_id: str, user_id: str, last_message_id: str) -> int:
        with self.social._connect() as connection, connection.transaction():
            marker = connection.execute("""SELECT m.sequence FROM direct_messages m
                JOIN direct_message_participants p ON p.thread_id=m.thread_id
                WHERE m.id=%s AND m.thread_id=%s AND p.user_id=%s""", (last_message_id, thread_id, user_id)).fetchone()
            if marker is None:
                raise HTTPException(status_code=404, detail="Message not found in this conversation.")
            connection.execute("UPDATE direct_message_participants SET read_sequence=GREATEST(read_sequence,%s) WHERE thread_id=%s AND user_id=%s", (marker["sequence"], thread_id, user_id))
            row = connection.execute("""SELECT COUNT(*) AS count FROM direct_messages m
                JOIN direct_message_participants p ON p.thread_id=m.thread_id AND p.user_id=%s
                WHERE m.thread_id=%s AND m.sender_user_id<>%s AND m.sequence>p.read_sequence AND NOT p.declined""", (user_id, thread_id, user_id)).fetchone()
            return int(row["count"])

    def set_request(self, thread_id: str, user_id: str, accepted: bool | None, declined: bool | None) -> dict:
        with self.social._connect() as connection, connection.transaction():
            thread = self._get(connection, thread_id, user_id)
            if thread is None:
                raise HTTPException(status_code=404, detail="Conversation not found.")
            participant = thread["participants"][user_id]
            if accepted is not None:
                participant["accepted"] = accepted
                if accepted:
                    participant["declined"] = False
            if declined is not None:
                participant["declined"] = declined
            connection.execute("UPDATE direct_message_participants SET accepted=%s,declined=%s WHERE thread_id=%s AND user_id=%s", (participant["accepted"], participant["declined"], thread_id, user_id))
            return self._get(connection, thread_id, user_id)

    def delete_user(self, user_id: str) -> None:
        with self.social._connect() as connection:
            connection.execute("DELETE FROM direct_message_threads WHERE user_a=%s OR user_b=%s", (user_id, user_id))


class DirectMessageService:
    def __init__(self, store, repository) -> None:
        self.store = store
        self.repository = repository

    def _relationships(self, user_id: str) -> dict:
        if self.store.postgres_social is not None:
            return self.store.postgres_social.relationship_state(user_id)
        # The fallback store's relationship sets are request-scoped only for
        # its current account; injected test stores may provide a scoped reader.
        reader = getattr(self.store, "relationships_for_user", None)
        if reader is not None:
            return reader(user_id)
        scoped_blocks = self.repository.blocked_users(user_id)
        if user_id == self.store.user.id:
            relationships = self.store.social_relationship_state()
            return {**relationships, "blocked_user_ids": sorted(set(relationships.get("blocked_user_ids", [])) | set(scoped_blocks))}
        return {"blocked_user_ids": scoped_blocks, "followed_user_ids": []}

    def _peer(self, user: User, peer_id: str) -> User:
        peer = self.store.get_auth_user_by_id(peer_id)
        if peer is None or peer.banned or user.banned or peer_id == user.id:
            raise HTTPException(status_code=404, detail="Conversation unavailable.")
        if peer_id in self._relationships(user.id).get("blocked_user_ids", []) or user.id in self._relationships(peer_id).get("blocked_user_ids", []):
            raise HTTPException(status_code=404, detail="Conversation unavailable.")
        return peer

    def _authorized(self, user: User, thread_id: str) -> tuple[dict, User]:
        thread = self.repository.get_thread(thread_id, user.id)
        if thread is None:
            raise HTTPException(status_code=404, detail="Conversation not found.")
        peer_id = thread["user_b"] if thread["user_a"] == user.id else thread["user_a"]
        return thread, self._peer(user, peer_id)

    def _message(self, message: dict, user: User, peer: User) -> dict:
        result = {key: message.get(key) for key in ("id", "sender_user_id", "text", "created_at", "client_message_id", "shared_post_id")}
        if message.get("shared_post_id"):
            own = self.store.get_visible_post(message["shared_post_id"], user.id)
            other = self.store.get_visible_post(message["shared_post_id"], peer.id)
            result["shared_post"] = own.model_dump(mode="json") if own is not None and other is not None else None
        return result

    def _summary(self, thread: dict, user: User, peer: User, full: bool = False) -> dict:
        participant = thread["participants"][user.id]
        last = thread["messages"][-1] if thread["messages"] else None
        result = {
            "id": thread["id"], "peer_user_id": peer.id,
            "peer_name": peer.display_name, "peer_handle": peer.handle,
            "peer_avatar_url": peer.avatar_url, "peer_premium": peer.premium,
            "preview": (last["text"] or "Shared a post") if last else "",
            "updated_at": thread["updated_at"],
            "unread_count": thread.get("unread_count", _unread(thread, user.id)),
            "request_accepted": participant["accepted"], "request_declined": participant["declined"],
        }
        if full:
            result["messages"] = [self._message(item, user, peer) for item in thread["messages"][-100:]]
        return result

    def create_thread(self, user: User, peer_id: str) -> dict:
        if not user.email_verified:
            raise HTTPException(status_code=403, detail="Verify your email before starting conversations.")
        peer = self._peer(user, peer_id)
        accepted = user.id in self._relationships(peer_id).get("followed_user_ids", [])
        thread = self.repository.ensure_thread(user.id, peer.id, accepted)
        return self._summary(thread, user, peer, True)

    def list_threads(self, user: User) -> dict:
        items = []
        for thread in self.repository.list_threads(user.id):
            try:
                peer_id = thread["user_b"] if thread["user_a"] == user.id else thread["user_a"]
                peer = thread.get("_peer") or self._peer(user, peer_id)
            except HTTPException:
                continue
            items.append(self._summary(thread, user, peer))
            if len(items) >= 100:
                break
        return {"user_id": user.id, "threads": items}

    def get_thread(self, user: User, thread_id: str) -> dict:
        thread, peer = self._authorized(user, thread_id)
        return self._summary(thread, user, peer, True)

    def send(self, user: User, thread_id: str, text: str, client_id: str, shared_post_id: str | None) -> dict:
        _, peer = self._authorized(user, thread_id)
        if not user.email_verified:
            raise HTTPException(status_code=403, detail="Verify your email before sending messages.")
        if shared_post_id:
            if self.store.get_visible_post(shared_post_id, user.id) is None or self.store.get_visible_post(shared_post_id, peer.id) is None:
                raise HTTPException(status_code=404, detail="This post cannot be shared with that account.")
        message = self.repository.send(thread_id, user.id, text, client_id, shared_post_id, daily_limit=100)
        return self._message(message, user, peer)

    def mark_read(self, user: User, thread_id: str, last_message_id: str) -> dict:
        self._authorized(user, thread_id)
        count = self.repository.mark_read(thread_id, user.id, last_message_id)
        return {"user_id": user.id, "thread_id": thread_id, "unread_count": count}

    def set_request(self, user: User, thread_id: str, accepted: bool | None, declined: bool | None) -> dict:
        _, peer = self._authorized(user, thread_id)
        thread = self.repository.set_request(thread_id, user.id, accepted, declined)
        return self._summary(thread, user, peer)

    def unread_count(self, user: User) -> dict:
        if hasattr(self.repository, "unread_count"):
            return {"user_id": user.id, "unread_count": self.repository.unread_count(user.id)}
        total = 0
        for thread in self.repository.unread_threads(user.id):
            try:
                peer_id = thread["user_b"] if thread["user_a"] == user.id else thread["user_a"]
                self._peer(user, peer_id)
            except HTTPException:
                continue
            total += thread.get("unread_count", _unread(thread, user.id))
        return {"user_id": user.id, "unread_count": total}


_services: dict[tuple, DirectMessageService] = {}
_services_lock = RLock()


def get_direct_message_service() -> DirectMessageService:
    from app.core.store import store
    social = store.postgres_social
    if social is None and os.getenv("DATABASE_URL", "").strip():
        raise HTTPException(status_code=503, detail="Messaging storage is unavailable. Try again shortly.")
    state_path = Path(store.state_file).with_name("direct_messages.json")
    key = (id(social), str(state_path))
    with _services_lock:
        if key not in _services:
            repository = PostgresDirectMessageRepository(social) if social is not None else JsonDirectMessageRepository(state_path)
            _services[key] = DirectMessageService(store, repository)
        return _services[key]


def delete_direct_messages_for_user(user_id: str) -> None:
    get_direct_message_service().repository.delete_user(user_id)


def record_direct_message_block(user_id: str, peer_id: str, blocked: bool) -> None:
    repository = get_direct_message_service().repository
    if isinstance(repository, JsonDirectMessageRepository):
        repository.set_block(user_id, peer_id, blocked)
