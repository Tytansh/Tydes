"""Exercise owned notification SQL against a local JSON-capable adapter."""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core.models import SocialNotification
from app.core.postgres_social import PostgresSocialRepository


class LocalNotificationConnection:
    def __init__(self):
        self.db = sqlite3.connect(":memory:")
        self.queries = []

        def row_factory(cursor, values):
            row = dict(zip((item[0] for item in cursor.description), values))
            if isinstance(row.get("payload"), str):
                row["payload"] = json.loads(row["payload"])
            return row

        self.db.row_factory = row_factory
        self.db.create_function("NOW", 0, lambda: datetime.now(timezone.utc).isoformat())
        self.db.execute("""CREATE TABLE social_notifications (
            id TEXT PRIMARY KEY, recipient_user_id TEXT, actor_user_id TEXT,
            payload TEXT, created_at TEXT, updated_at TEXT
        )""")

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    @contextmanager
    def transaction(self):
        with self.db:
            yield

    def execute(self, query, parameters=()):
        self.queries.append((query, parameters))
        query = query.replace("actor_user_id = ANY(%s)", "actor_user_id IN (SELECT value FROM json_each(%s))")
        query = query.replace("id = ANY(%s)", "id IN (SELECT value FROM json_each(%s))")
        query = query.replace("FOR UPDATE", "").replace("%s", "?")
        values = tuple(
            json.dumps(value) if isinstance(value, list)
            else value.isoformat() if isinstance(value, datetime)
            else value
            for value in parameters
        )
        return self.db.execute(query, values)


@pytest.fixture
def notification_sql(monkeypatch):
    connection = LocalNotificationConnection()
    repository = object.__new__(PostgresSocialRepository)
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", json.dumps)
    yield repository, connection
    connection.db.close()


def _item(identifier, recipient="owner", actor="surfer"):
    return SocialNotification(
        id=identifier, recipient_user_id=recipient, actor_user_id=actor,
        actor_name="Surfer", type="like", message="liked your post.",
        created_at=datetime.now(timezone.utc),
    )


def test_notification_sql_count_all_and_owned_exact_snapshot(notification_sql):
    repository, connection = notification_sql
    for index in range(95):
        repository.save_notification(_item(f"own-{index}"))
    repository.save_notification(_item("other", "other"))
    repository.save_notification(_item("blocked", actor="blocked-surfer"))
    assert len(repository.list_notifications("owner")) == 80
    assert repository.unread_notification_count("owner", {"blocked-surfer"}) == 95
    ids = repository.mark_notifications_read("owner", ["own-0", "own-1", "other", "blocked"], {"blocked-surfer"})
    assert set(ids) == {"own-0", "own-1"}
    assert repository.unread_notification_count("owner", {"blocked-surfer"}) == 93
    assert repository.unread_notification_count("other", set()) == 1
    sql = "\n".join(query for query, _ in connection.queries).lower()
    assert "for update" in sql
    assert "where id = %s and recipient_user_id = %s" in sql
    assert "delete" not in sql


def test_notification_sql_new_arrival_and_idempotent_receipts(notification_sql):
    repository, _ = notification_sql
    repository.save_notification(_item("visible"))
    repository.save_notification(_item("later"))
    assert repository.mark_notifications_read("owner", ["visible"], set()) == ["visible"]
    first = next(item for item in repository.list_notifications("owner") if item.id == "visible")
    assert repository.mark_notifications_read("owner", ["visible"], set()) == ["visible"]
    second = next(item for item in repository.list_notifications("owner") if item.id == "visible")
    assert first.read_at == second.read_at
    assert repository.unread_notification_count("owner", set()) == 1
