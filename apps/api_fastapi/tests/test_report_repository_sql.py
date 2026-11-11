"""Local SQL contract checks for reversible moderation, without credentials."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core.models import SocialReport
from app.core.postgres_social import PostgresSocialRepository


class LocalReportConnection:
    def __init__(self):
        self.db = sqlite3.connect(":memory:")
        self.queries = []

        def row_factory(cursor, values):
            row = dict(zip((column[0] for column in cursor.description), values))
            if isinstance(row.get("payload"), str):
                row["payload"] = json.loads(row["payload"])
            return row

        self.db.row_factory = row_factory
        self.db.create_function("NOW", 0, lambda: datetime.now(timezone.utc).isoformat())
        self.db.execute("""
            CREATE TABLE social_reports (
                id TEXT PRIMARY KEY, reporter_user_id TEXT, target_type TEXT,
                target_id TEXT, payload TEXT, created_at TEXT, updated_at TEXT
            )
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
        self.queries.append((query, parameters))
        values = tuple(
            value.isoformat() if isinstance(value, datetime) else value
            for value in parameters
        )
        # SQLite exercises the actual JSON/UPDATE contract. Row locking is
        # PostgreSQL-specific and is separately asserted on the original SQL.
        sql = query.replace("%s", "?").replace("FOR UPDATE", "")
        return self.db.execute(sql, values)


@pytest.fixture
def report_sql(monkeypatch):
    connection = LocalReportConnection()
    repository = object.__new__(PostgresSocialRepository)
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", json.dumps)
    yield repository, connection
    connection.db.close()


def _report(report_id="report", created_at=None):
    return SocialReport(
        id=report_id,
        reporter_user_id="reporter",
        target_type="post",
        target_id="original-post",
        reason="Review this",
        created_at=created_at or datetime.now(timezone.utc),
    )


def _stored(connection, report_id):
    row = connection.execute(
        "SELECT payload FROM social_reports WHERE id = %s", (report_id,)
    ).fetchone()
    return SocialReport.model_validate(row["payload"]) if row else None


def test_report_sql_dismiss_is_persistent_reversible_and_idempotent(report_sql):
    repository, connection = report_sql
    original = _report()
    repository.save_report(original)
    connection.queries.clear()

    dismissed = repository.set_report_status("report", "dismissed", "admin-one")
    assert dismissed.status == "dismissed"
    assert dismissed.dismissed_by_user_id == "admin-one"
    assert dismissed.dismissed_at is not None
    assert _stored(connection, "report") == dismissed
    assert repository.list_reports() == []
    assert repository.list_reports(include_dismissed=True) == [dismissed]

    repeated = repository.set_report_status("report", "dismissed", "admin-two")
    assert repeated.dismissed_at == dismissed.dismissed_at
    assert repeated.dismissed_by_user_id == "admin-one"

    restored = repository.set_report_status("report", "open", "admin-one")
    assert restored.status == "open"
    assert restored.dismissed_at is None
    assert restored.dismissed_by_user_id is None
    assert restored.target_id == original.target_id
    assert restored.reporter_user_id == original.reporter_user_id
    assert restored.reason == original.reason
    assert restored.created_at == original.created_at
    assert repository.list_reports() == [restored]

    sql = "\n".join(query for query, _ in connection.queries).lower()
    assert "for update" in sql
    assert "delete" not in sql
    assert "social_posts" not in sql
    assert "auth_accounts" not in sql


def test_report_sql_targets_records_outside_newest_500(report_sql):
    repository, connection = report_sql
    now = datetime.now(timezone.utc)
    for index in range(501):
        repository.save_report(_report(str(index), now - timedelta(minutes=index)))
    assert len(repository.list_reports()) == 500
    assert "500" not in {report.id for report in repository.list_reports()}
    connection.queries.clear()

    dismissed = repository.set_report_status("500", "dismissed", "admin")
    assert dismissed.id == "500"
    assert _stored(connection, "500").status == "dismissed"
    updates = [(query, params) for query, params in connection.queries
               if query.lstrip().upper().startswith("UPDATE")]
    assert len(updates) == 1
    assert "WHERE id = %s" in updates[0][0]
    assert "500" in updates[0][1]
    assert all("LIMIT" not in query.upper() for query, _ in connection.queries)


def test_report_sql_filter_before_limit_keeps_older_open_reports(report_sql):
    repository, _ = report_sql
    now = datetime.now(timezone.utc)
    for index in range(501):
        repository.save_report(_report(str(index), now - timedelta(minutes=index)))
    for index in range(500):
        repository.set_report_status(str(index), "dismissed", "admin")
    assert [report.id for report in repository.list_reports()] == ["500"]


def test_report_sql_history_prioritizes_open_queue_before_bounded_limit(report_sql):
    repository, _ = report_sql
    now = datetime.now(timezone.utc)
    for index in range(501):
        report = _report(f"dismissed-{index}", now - timedelta(minutes=index))
        repository.save_report(report.model_copy(update={"status": "dismissed"}))
    older = _report("old-open", now - timedelta(days=2))
    newer = _report("newer-open", now - timedelta(days=1))
    repository.save_report(older)
    repository.save_report(newer)

    history = repository.list_reports(include_dismissed=True)
    assert len(history) == 500
    # A full page of newer dismissed reports cannot bury an actionable item.
    # Both groups still retain newest-first ordering for their own UI views.
    assert [report.id for report in history[:2]] == [newer.id, older.id]
    assert all(report.status == "dismissed" for report in history[2:])
    assert [report.id for report in history[2:]] == [f"dismissed-{index}" for index in range(498)]
    assert [report.id for report in repository.list_reports()] == [newer.id, older.id]


def test_report_sql_missing_id_does_not_insert_or_mutate(report_sql):
    repository, connection = report_sql
    assert _stored(connection, "missing") is None
    assert repository.set_report_status("missing", "dismissed", "admin") is None
    assert repository.list_reports(include_dismissed=True) == []
    assert all(not query.lstrip().upper().startswith(("INSERT", "UPDATE", "DELETE"))
               for query, _ in connection.queries)


def test_report_sql_legacy_payload_defaults_to_open(report_sql):
    repository, connection = report_sql
    original = _report()
    payload = original.model_dump(mode="json")
    for name in ("status", "dismissed_at", "dismissed_by_user_id"):
        payload.pop(name, None)
    connection.execute(
        "INSERT INTO social_reports VALUES (%s, %s, %s, %s, %s, %s, %s)",
        (original.id, original.reporter_user_id, original.target_type,
         original.target_id, json.dumps(payload), original.created_at, None),
    )
    assert _stored(connection, original.id).status == "open"
    assert [report.id for report in repository.list_reports()] == [original.id]
