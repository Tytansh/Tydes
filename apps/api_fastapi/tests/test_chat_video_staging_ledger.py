"""Bounded staging lifecycle; no provider requests or real database access."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from threading import RLock
from types import SimpleNamespace

import pytest

from app.core import media_cleanup
from app.core.media_uploads import (MediaUploadLedger, UploadLimits, UploadQuotaExceeded,
    _reservation_from_row, chat_import_deadline, retained_upload_bytes)
from test_private_video_ledger import Database, Result, postgres_ledger, reservation

MIB = 1024 * 1024


def staged(identifier="staged-video", **changes):
    return replace(reservation(), id=identifier, external_id=None, pending_name="staged-placeholder",
        final_name="staged-placeholder", chat_source_name=f"private/chat/{identifier}.mp4",
        chat_source_bytes=25 * MIB, chat_import_state="staged",
        expires_at=datetime.now(timezone.utc) + timedelta(minutes=15), **changes)


def begin(ledger, row):
    return ledger.begin_chat_video_fetch(row.id, row.user_id, etag='"verified-source-etag"',
        duration_seconds=2.0, read_expires_at=datetime.now(timezone.utc) + timedelta(minutes=10))


class StagingDatabase(Database):
    def __init__(self):
        super().__init__()
        self.lock = RLock()

    @contextmanager
    def connect(self):
        with self.lock:
            with super().connect():
                yield self

    def execute(self, query, params=()):
        normalized = " ".join(query.split())
        if "SET chat_import_state='fetch_started'" in normalized:
            self.statements.append((query, params))
            now = datetime.now(timezone.utc)
            etag, duration, read_expiry, identifier, user, _ = params
            row = self.rows.get(identifier)
            if (not row or row["user_id"] != user or row["status"] != "pending"
                    or row.get("chat_import_state") != "staged" or not row.get("chat_source_name")
                    or row.get("external_id") is not None or row.get("chat_source_deleted_at")
                    or row["expires_at"] <= now):
                return Result()
            row.update(chat_import_state="fetch_started", chat_import_started_at=now,
                chat_source_etag=etag, chat_source_duration_seconds=duration,
                chat_source_read_expires_at=read_expiry)
            return Result({"id": identifier})
        if normalized.startswith("UPDATE") and "SET chat_import_state=%s" in normalized:
            state, identifier, user = params
            row = self.rows.get(identifier)
            if row and row["user_id"] == user and row.get("chat_import_state") == "fetch_started" and row.get("external_id") is None:
                row["chat_import_state"] = state
            return Result()
        if normalized.startswith("UPDATE") and "SET external_id=%s,pending_name=%s,final_name=%s" in normalized:
            external, pending, final, identifier, user, same_external = params
            row = self.rows.get(identifier)
            if (not row or row["user_id"] != user or row["status"] not in {"pending", "canceled", "deletion_pending", "failed"}
                    or row.get("chat_import_state") not in {"fetch_started", "fetch_submitted", "imported"}
                    or row.get("external_id") not in {None, same_external}):
                return Result()
            row.update(external_id=external, pending_name=pending, final_name=final, chat_import_state="imported")
            return Result(deepcopy(row))
        if normalized.startswith("UPDATE") and "SET chat_source_deleted_at=" in normalized:
            now, identifier, user, _, _ = params
            row = self.rows.get(identifier)
            if (not row or row["user_id"] != user or row["expires_at"] > now
                    or (row.get("chat_source_read_expires_at") and row["chat_source_read_expires_at"] > now)):
                return Result()
            row["chat_source_deleted_at"] = row.get("chat_source_deleted_at") or now
            return Result({"id": identifier})
        if normalized.startswith("UPDATE") and "SET status='deletion_pending'" in normalized:
            identifier, user, expected, _ = params
            row = self.rows.get(identifier)
            if not row or row["user_id"] != user or row["status"] != expected:
                return Result()
            row["status"] = "deletion_pending"
            return Result({"id": identifier})
        if normalized.startswith("UPDATE") and "SET status=%s,updated_at=NOW()" in normalized:
            status, identifier, user, allowed = params
            row = self.rows.get(identifier)
            if not row or row["user_id"] != user or row["status"] not in allowed or row.get("message_id") is not None:
                return Result()
            row["status"] = status
            return Result({"id": identifier})
        if normalized.startswith("UPDATE") and "SET status='complete',chat_video_resolutions" in normalized:
            row = self.rows.get(params[2])
            if row and row.get("chat_source_name") and row.get("chat_import_state") != "imported":
                return Result()
        return super().execute(query, params)


@pytest.mark.parametrize("postgres", [False, True])
def test_only_one_worker_can_begin_the_external_fetch_and_restarts_cannot_replay(postgres):
    database = StagingDatabase()
    ledger = postgres_ledger(database) if postgres else MediaUploadLedger()
    row = staged()
    ledger.reserve(row, UploadLimits.from_env())
    with ThreadPoolExecutor(max_workers=8) as pool:
        claims = list(pool.map(lambda _: begin(ledger, row), range(8)))
    assert claims.count(True) == 1
    restarted = postgres_ledger(database) if postgres else ledger
    assert not begin(restarted, row)
    saved = restarted.get(row.id, row.user_id)
    assert saved.chat_import_state == "fetch_started" and saved.chat_source_etag == '"verified-source-etag"'
    assert saved.chat_source_duration_seconds == 2.0 and saved.chat_import_started_at is not None


def test_fetch_intent_commit_failure_does_not_grant_an_external_post():
    database = StagingDatabase()
    ledger = postgres_ledger(database)
    row = staged()
    ledger.reserve(row, UploadLimits.from_env())
    database.fail_commit = True
    with pytest.raises(OSError):
        begin(ledger, row)
    database.fail_commit = False
    assert ledger.get(row.id, row.user_id).chat_import_state == "staged"


@pytest.mark.parametrize("postgres", [False, True])
def test_only_verified_imports_complete_and_target_binding_is_idempotent_not_replaceable(postgres):
    database = StagingDatabase()
    ledger = postgres_ledger(database) if postgres else MediaUploadLedger()
    row = staged()
    ledger.reserve(row, UploadLimits.from_env())
    with pytest.raises(ValueError):
        ledger.complete_chat_video(row.id, row.user_id, ("360p",), "360p")
    assert begin(ledger, row)
    ledger.record_chat_video_fetch_outcome(row.id, row.user_id, accepted=True)
    ledger.bind_chat_video_import(row.id, row.user_id, "verified-guid")
    ledger.bind_chat_video_import(row.id, row.user_id, "verified-guid")
    with pytest.raises(ValueError):
        ledger.bind_chat_video_import(row.id, row.user_id, "different-guid")
    with pytest.raises(ValueError):
        ledger.bind_chat_video_import(row.id, "mallory", "verified-guid")
    ledger.complete_chat_video(row.id, row.user_id, ("360p",), "360p")
    ledger.record_chat_video_fetch_outcome(row.id, row.user_id, accepted=False)
    saved = ledger.get(row.id, row.user_id)
    assert saved.status == "complete" and saved.chat_import_state == "imported"


def test_cancel_after_fetch_start_still_records_the_target_for_cleanup_without_sending():
    ledger = MediaUploadLedger()
    row = staged()
    ledger.reserve(row, UploadLimits.from_env())
    assert begin(ledger, row)
    ledger.cancel_chat_media(row.id, row.user_id)
    ledger.record_chat_video_fetch_outcome(row.id, row.user_id, accepted=True)
    saved = ledger.bind_chat_video_import(row.id, row.user_id, "verified-guid")
    assert saved.status == "canceled" and saved.external_id == "verified-guid"
    assert not begin(ledger, row)
    with pytest.raises(ValueError):
        ledger.complete_chat_video(row.id, row.user_id, ("360p",), "360p")


def test_source_plus_encoded_quota_is_reserved_and_daily_cost_never_refunded():
    ledger = MediaUploadLedger()
    row = staged()
    limits = replace(UploadLimits.from_env(), user_retained_bytes=100 * MIB,
        global_retained_bytes=100 * MIB)
    ledger.reserve(row, limits)
    assert row.total_bytes == 75 * MIB
    with pytest.raises(UploadQuotaExceeded):
        ledger.reserve(staged("second"), limits)
    with pytest.raises(ValueError):
        ledger.mark_chat_source_deleted(row.id, row.user_id)
    expired = replace(row, status="used", expires_at=datetime.now(timezone.utc) - timedelta(seconds=1))
    ledger._memory[row.id] = expired
    ledger.mark_chat_source_deleted(row.id, row.user_id)
    cleaned = ledger.get(row.id, row.user_id)
    assert cleaned.total_bytes == 75 * MIB and retained_upload_bytes(cleaned) == 50 * MIB
    ledger.reserve(replace(staged("smaller"), expected_bytes=20 * MIB), limits)


def test_unknown_fetch_retains_encoded_quota_after_expiry_and_physical_source_cleanup():
    now = datetime.now(timezone.utc)
    row = replace(staged(), status="expired", chat_import_state="fetch_submitted",
        created_at=now - timedelta(hours=3), expires_at=now - timedelta(hours=2),
        chat_source_read_expires_at=now - timedelta(hours=2), chat_source_deleted_at=now)
    assert retained_upload_bytes(row) == 50 * MIB
    assert chat_import_deadline(row) <= now


def test_pending_import_gets_bounded_ingestion_grace_not_put_expiry():
    now = datetime.now(timezone.utc)
    ledger = MediaUploadLedger()
    row = replace(staged(), created_at=now - timedelta(minutes=20),
        expires_at=now - timedelta(minutes=5), chat_import_state="fetch_started",
        chat_source_read_expires_at=now - timedelta(minutes=1))
    ledger._memory[row.id] = row
    assert ledger.expired_pending() == [] and ledger.chat_sources_due() == []
    old = replace(row, created_at=now - timedelta(hours=3), expires_at=now - timedelta(hours=2),
        chat_source_read_expires_at=now - timedelta(hours=2))
    ledger._memory[row.id] = old
    assert ledger.expired_pending() == [old] and ledger.chat_sources_due() == [old]


def test_successful_used_source_cleanup_preserves_message_and_failed_delete_keeps_quota(monkeypatch):
    from app.core import media_storage
    now = datetime.now(timezone.utc)
    ledger = MediaUploadLedger()
    row = replace(staged(), status="used", message_id="retained-message",
        expires_at=now - timedelta(minutes=2), chat_import_state="imported", external_id="guid")
    ledger._memory[row.id] = row
    deleted = []
    monkeypatch.setattr(media_cleanup, "upload_ledger", ledger)
    monkeypatch.setattr(media_cleanup, "configured_media_storage", lambda: None)
    monkeypatch.setattr(media_storage, "PrivateChatR2Storage", lambda: SimpleNamespace(
        delete_object=lambda name: deleted.append(name)))
    result = media_cleanup.run_media_cleanup()
    saved = ledger.get(row.id, row.user_id)
    assert deleted == [row.chat_source_name] and result.staged_sources == 1
    assert saved.status == "used" and saved.message_id == "retained-message"
    assert saved.chat_source_deleted_at is not None and retained_upload_bytes(saved) == 50 * MIB
    assert media_cleanup.run_media_cleanup().staged_sources == 0
    ledger._memory[row.id] = row
    def fail(_):
        raise OSError("fixture delete outage")
    monkeypatch.setattr(media_storage, "PrivateChatR2Storage", lambda: SimpleNamespace(delete_object=fail))
    assert media_cleanup.run_media_cleanup().failed == 1
    assert ledger.get(row.id, row.user_id).chat_source_deleted_at is None
    assert retained_upload_bytes(ledger.get(row.id, row.user_id)) == 75 * MIB


def test_old_rows_decode_with_no_staging_or_import_privileges():
    from dataclasses import asdict
    raw = asdict(reservation())
    for name in list(raw):
        if name.startswith("chat_source_") or name.startswith("chat_import_"):
            raw.pop(name)
    old = _reservation_from_row(raw)
    assert old.chat_source_name is None and old.chat_source_bytes == 0
    assert old.chat_import_state is None and old.total_bytes == 50 * MIB


def test_postgres_source_delete_requires_expired_write_and_read_grants_and_round_trips():
    database = StagingDatabase()
    ledger = postgres_ledger(database)
    row = staged()
    ledger.reserve(row, UploadLimits.from_env())
    with pytest.raises(ValueError):
        ledger.mark_chat_source_deleted(row.id, row.user_id)
    stored = database.rows[row.id]
    stored.update(expires_at=datetime.now(timezone.utc) - timedelta(minutes=1),
        chat_source_read_expires_at=datetime.now(timezone.utc) + timedelta(minutes=1))
    with pytest.raises(ValueError):
        ledger.mark_chat_source_deleted(row.id, row.user_id)
    stored["chat_source_read_expires_at"] = datetime.now(timezone.utc) - timedelta(seconds=1)
    ledger.mark_chat_source_deleted(row.id, row.user_id)
    loaded = postgres_ledger(database).get(row.id, row.user_id)
    assert loaded.chat_source_deleted_at is not None and loaded.total_bytes == 75 * MIB
    assert retained_upload_bytes(loaded) == 50 * MIB
    retained_query = next(sql for sql, _ in database.statements if "SUM(retained_bytes)" in sql)
    assert "chat_source_deleted_at IS NULL" in retained_query
    assert "chat_import_state IN ('fetch_started','fetch_submitted') AND external_id IS NULL" in retained_query


@pytest.mark.parametrize("postgres", [False, True])
def test_cleanup_claim_prevents_a_later_import_dispatch(postgres):
    database = StagingDatabase()
    ledger = postgres_ledger(database) if postgres else MediaUploadLedger()
    row = staged()
    ledger.reserve(row, UploadLimits.from_env())
    assert ledger.claim_chat_cleanup(row.id, row.user_id, "pending")
    assert not begin(ledger, row)
    assert ledger.get(row.id, row.user_id).chat_import_state == "staged"


def test_postgres_fetch_uses_current_wall_clock_not_a_stale_transaction_timestamp():
    database = StagingDatabase()
    ledger = postgres_ledger(database)
    row = staged()
    ledger.reserve(row, UploadLimits.from_env())
    assert begin(ledger, row)
    query = next(sql for sql, _ in database.statements if "SET chat_import_state='fetch_started'" in sql)
    assert "expires_at>clock_timestamp()" in query
    assert "%s>clock_timestamp()" in query


@pytest.mark.parametrize("postgres", [False, True])
@pytest.mark.parametrize("status", ["pending", "complete", "used"])
def test_rejection_is_pending_only_and_never_invalidates_a_completed_message(postgres, status):
    database = StagingDatabase()
    ledger = postgres_ledger(database) if postgres else MediaUploadLedger()
    row = replace(staged(), status=status, message_id="sent-message" if status == "used" else None)
    ledger.reserve(row, UploadLimits.from_env())
    if status == "pending":
        ledger.reject_chat_media(row.id, row.user_id)
        assert ledger.get(row.id, row.user_id).status == "rejected"
    else:
        with pytest.raises(ValueError):
            ledger.reject_chat_media(row.id, row.user_id)
        assert ledger.get(row.id, row.user_id) == row
    assert ledger.get(row.id, row.user_id).chat_source_deleted_at is None
