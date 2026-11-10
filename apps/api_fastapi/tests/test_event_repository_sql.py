"""Exercise the event SQL contract locally, without production credentials."""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core.models import SocialPost
from app.core.postgres_social import PostgresSocialRepository


class LocalSqlConnection:
    """SQLite supports the JSON extraction/UPSERT subset used by these queries."""
    def __init__(self):
        self.db = sqlite3.connect(":memory:")
        def row_factory(cursor, values):
            row = dict(zip((column[0] for column in cursor.description), values))
            if isinstance(row.get("payload"), str):
                row["payload"] = json.loads(row["payload"])
            return row
        self.db.row_factory = row_factory
        self.db.create_function("NOW", 0, lambda: datetime.now(timezone.utc).isoformat())
        self.db.executescript("""
            CREATE TABLE social_posts (id TEXT PRIMARY KEY, user_id TEXT, payload TEXT,
                created_at TEXT, updated_at TEXT);
            CREATE TABLE social_rsvps (user_id TEXT, post_id TEXT, created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY(user_id, post_id));
            CREATE TABLE social_post_likes (user_id TEXT, post_id TEXT);
            CREATE TABLE social_reposts (user_id TEXT, post_id TEXT);
            CREATE TABLE social_follows (follower_user_id TEXT, followed_user_id TEXT);
            CREATE TABLE social_blocks (user_id TEXT, blocked_user_id TEXT);
        """)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    @contextmanager
    def transaction(self):
        with self.db:
            yield

    def execute(self, query, parameters=()):
        values = tuple(value.isoformat() if isinstance(value, datetime) else value
                       for value in parameters)
        return self.db.execute(query.replace("%s", "?"), values)


@pytest.fixture
def event_sql(monkeypatch):
    connection = LocalSqlConnection()
    repository = object.__new__(PostgresSocialRepository)
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", json.dumps)
    yield repository, connection
    connection.db.close()


def _event(event_id="event", visibility="public"):
    return SocialPost(id=event_id, user_id="owner", author_name="Host",
        body="Surf together", post_type="surf_plan", visibility=visibility,
        created_at=datetime.now(timezone.utc))


def test_event_sql_autojoins_host_once_and_counts_only_guests(event_sql):
    repository, connection = event_sql
    event = _event()
    repository.save_post(event)
    repository.save_post(event)
    assert repository.list_rsvp_user_ids(event.id) == ["owner"]
    assert repository.get_post(event.id).rsvp_count == 0
    assert repository.list_posts(viewer_user_id="owner")[0].rsvp_count == 0
    repository.set_rsvp("guest", event.id, True)
    repository.set_rsvp("guest", event.id, True)
    assert set(repository.list_rsvp_user_ids(event.id)) == {"owner", "guest"}
    assert repository.get_post(event.id).rsvp_count == 1
    assert repository.list_posts(viewer_user_id="guest")[0].rsvp_count == 1
    assert [p.id for p in repository.list_event_chat_posts("owner")] == [event.id]
    assert [p.id for p in repository.list_event_chat_posts("guest")] == [event.id]
    assert repository.list_event_chat_posts("outsider") == []
    connection.execute("INSERT INTO social_blocks VALUES (?, ?)", ("guest", "owner"))
    assert repository.list_event_chat_posts("guest") == []


def test_event_sql_inbox_preserves_followers_visibility(event_sql):
    repository, connection = event_sql
    event = _event(visibility="followers")
    repository.save_post(event)
    repository.set_rsvp("guest", event.id, True)
    assert repository.list_event_chat_posts("guest") == []
    connection.execute("INSERT INTO social_follows VALUES (?, ?)", ("guest", "owner"))
    assert [p.id for p in repository.list_event_chat_posts("guest")] == [event.id]


def test_event_and_host_membership_are_one_atomic_write(event_sql):
    repository, connection = event_sql
    connection.db.executescript("""
        CREATE TRIGGER fail_membership BEFORE INSERT ON social_rsvps
        BEGIN SELECT RAISE(ABORT, 'membership unavailable'); END;
    """)
    with pytest.raises(sqlite3.IntegrityError):
        repository.save_post(_event("failed-event"))
    assert repository.get_post("failed-event") is None
