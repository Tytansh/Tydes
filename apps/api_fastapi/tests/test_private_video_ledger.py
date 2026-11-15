"""Private playback metadata persists atomically; old rows stay unverified."""
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import asdict, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core.media_uploads import (MediaUploadLedger, UploadLimits, UploadReservation,
                                    _reservation_from_row, verified_chat_video_playback)


def reservation():
    now = datetime.now(timezone.utc)
    return UploadReservation(id="private-video", user_id="alice", client_ip_hash="ip",
        media_type="video", content_type="video/mp4", thumbnail_content_type=None,
        expected_bytes=50 * 1024 * 1024, expected_thumbnail_bytes=0,
        pending_name="video-guid", final_name="video-guid", pending_thumbnail_name=None,
        final_thumbnail_name=None, public_url="", thumbnail_public_url="",
        status="pending", created_at=now, expires_at=now + timedelta(minutes=30),
        storage_provider="chat_bunny", external_id="video-guid", purpose="chat",
        scope_type="direct", scope_id="thread-a")


class Result:
    def __init__(self, value=None):
        self.value = value

    def fetchone(self):
        return self.value


class Database:
    """Bounded transaction fake exercising the actual PG SQL/row codecs."""
    def __init__(self):
        self.rows = {}
        self.statements = []
        self.fail_commit = False

    @contextmanager
    def connect(self):
        before = deepcopy(self.rows)
        try:
            yield self
            if self.fail_commit:
                raise OSError("simulated commit failure")
        except Exception:
            self.rows = before
            raise

    @contextmanager
    def transaction(self):
        before = deepcopy(self.rows)
        try:
            yield
        except Exception:
            self.rows = before
            raise

    def execute(self, query, params=()):
        self.statements.append((query, params))
        normalized = " ".join(query.split())
        if "INSERT INTO media_upload_reservations" in query:
            columns = query.split("(", 1)[1].split(")", 1)[0].replace("\n", "").split(",")
            columns = [value.strip() for value in columns]
            assert len(columns) == len(params) == query.count("%s") == 27
            row = dict(zip(columns, params))
            self.rows[row["id"]] = row
        elif "SET status='complete',chat_video_resolutions" in normalized:
            encoded, fallback, identifier, user = params
            row = self.rows.get(identifier)
            if (row is None or row["user_id"] != user or row["purpose"] != "chat"
                    or row["media_type"] != "video" or row["storage_provider"] != "chat_bunny"
                    or row["status"] != "pending" or row.get("message_id") is not None):
                return Result()
            row.update(status="complete", chat_video_resolutions=encoded,
                       chat_video_mp4_resolution=fallback)
            return Result({"id": identifier})
        elif "SELECT * FROM media_upload_reservations" in normalized:
            identifier, user = params
            row = self.rows.get(identifier)
            return Result(deepcopy(row) if row and row["user_id"] == user else None)
        elif "COUNT(*) AS count" in normalized:
            return Result({"count": 0})
        elif "COUNT(*) AS global_count" in normalized:
            return Result(dict(user_count=0, user_video_count=0, user_bytes=0,
                               global_count=0, global_bytes=0))
        elif "AS global_bytes" in normalized:
            return Result(dict(global_bytes=0, user_bytes=0))
        elif normalized.startswith("ALTER TABLE"):
            name = re.search(r"ADD COLUMN IF NOT EXISTS (\w+)", normalized).group(1)
            default = "social" if name == "purpose" else "r2" if name == "storage_provider" else None
            for row in self.rows.values():
                row.setdefault(name, default)
        return Result()


def postgres_ledger(database):
    ledger = object.__new__(MediaUploadLedger)
    ledger.database_url = "postgresql://fixture.invalid/not-connected"
    ledger._connect = database.connect
    return ledger


def test_postgres_round_trip_and_fresh_ledger_use_durable_verified_choice():
    database = Database()
    ledger = postgres_ledger(database)
    row = reservation()
    ledger.reserve(row, UploadLimits.from_env())
    ledger.complete_chat_video(row.id, row.user_id, ("240p", "360p", "480p"), "360p")
    # A new service instance reads persisted metadata, never a provider cache.
    restarted = postgres_ledger(database)
    loaded = restarted.get(row.id, row.user_id)
    assert loaded.status == "complete"
    assert verified_chat_video_playback(loaded) == (("240p", "360p", "480p"), "360p")
    assert restarted.get(row.id, "mallory") is None


def test_postgres_completion_commit_failure_keeps_status_and_playback_unset():
    database = Database()
    ledger = postgres_ledger(database)
    row = reservation()
    ledger.reserve(row, UploadLimits.from_env())
    database.fail_commit = True
    with pytest.raises(OSError):
        ledger.complete_chat_video(row.id, row.user_id, ("480p",), "480p")
    database.fail_commit = False
    saved = ledger.get(row.id, row.user_id)
    assert saved.status == "pending" and saved.chat_video_resolutions is None
    assert saved.chat_video_mp4_resolution is None


def test_additive_postgres_migration_preserves_legacy_rows_without_inventing_playback():
    database = Database()
    legacy = asdict(replace(reservation(), status="used", message_id="old-message"))
    legacy.pop("chat_video_resolutions")
    legacy.pop("chat_video_mp4_resolution")
    database.rows[legacy["id"]] = legacy.copy()
    ledger = postgres_ledger(database)
    ledger._ensure_schema()
    loaded = ledger.get(legacy["id"], legacy["user_id"])
    assert loaded.status == "used" and loaded.message_id == "old-message"
    assert loaded.chat_video_resolutions is None and loaded.chat_video_mp4_resolution is None
    with pytest.raises(ValueError, match="not been verified"):
        verified_chat_video_playback(loaded)
    assert all("DROP" not in sql and "DELETE" not in sql for sql, _ in database.statements)
    # The row codec also reads snapshots made before the additive migration.
    assert _reservation_from_row(legacy).chat_video_mp4_resolution is None


@pytest.mark.parametrize("encoded,fallback", [
    (None, None), ("720p,1080p", "720p"), ("480p", "720p"),
    ("480p,240p", "480p"), ("480p,480p", "480p"),
    ("480p", "../original"), ("480p", "2160p"),
])
def test_corrupt_or_legacy_playback_metadata_is_not_claimable(encoded, fallback):
    ledger = MediaUploadLedger()
    row = replace(reservation(), status="complete", chat_video_resolutions=encoded,
                  chat_video_mp4_resolution=fallback)
    ledger._memory[row.id] = row
    with pytest.raises(ValueError):
        ledger.validate_chat_media("alice", "direct", "thread-a", [row.id])
    with pytest.raises(ValueError):
        ledger.claim_chat_media("alice", "direct", "thread-a", [row.id], "message", "retry")
    assert ledger.get(row.id, row.user_id).status == "complete"


def test_canceled_or_wrong_owner_video_cannot_receive_ready_metadata():
    ledger = MediaUploadLedger()
    row = replace(reservation(), status="canceled")
    ledger._memory[row.id] = row
    for owner in ["alice", "mallory"]:
        with pytest.raises(ValueError):
            ledger.complete_chat_video(row.id, owner, ("480p",), "480p")
    assert ledger.get(row.id, row.user_id) == row
