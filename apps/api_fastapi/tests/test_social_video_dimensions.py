"""Provider dimensions reach feed attachments without extra provider requests."""
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import asdict, replace
from datetime import datetime, timedelta, timezone
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-test-dimensions-"))

from app.core.bunny_stream import BunnyStreamClient, BunnyVideo
from app.core.media_storage import R2MediaStorage
from app.core.media_uploads import MediaUploadLedger, UploadLimits, UploadReservation
from app.core.models import User
from app.core.rate_limit import api_rate_limiter
from app.core.store import DemoStore, store
from app.main import app
from app.modules.social import router as social_router


def reservation():
    now = datetime.now(timezone.utc)
    return UploadReservation(
        id="media_dimensions", user_id="alice", client_ip_hash="test-ip",
        media_type="video", content_type="video/mp4", thumbnail_content_type=None,
        expected_bytes=100, expected_thumbnail_bytes=0,
        pending_name="video-guid", final_name="video-guid",
        pending_thumbnail_name=None, final_thumbnail_name=None,
        public_url="https://video.example/video-guid/playlist.m3u8",
        thumbnail_public_url="https://video.example/video-guid/thumbnail.jpg",
        status="pending", created_at=now, expires_at=now + timedelta(minutes=5),
        storage_provider="bunny_stream", external_id="video-guid",
    )


@pytest.mark.parametrize("rotation,expected", [
    (None, (1920, 1080)), (0, (1920, 1080)), (180, (1920, 1080)),
    (90, (1080, 1920)), (-90, (1080, 1920)), (270, (1080, 1920)),
])
def test_bunny_existing_metadata_response_supplies_display_dimensions(monkeypatch, rotation, expected):
    calls = []

    def get(url, **kwargs):
        calls.append(url)
        return SimpleNamespace(
            raise_for_status=lambda: None,
            json=lambda: dict(status=3, length=18, width=1920, height=1080, rotation=rotation),
        )

    monkeypatch.setattr("app.core.bunny_stream.httpx.get", get)
    client = object.__new__(BunnyStreamClient)
    client.library_id, client.api_key, client.timeout = "fixture-library", "fixture-key", 1
    video = client.get_video("video-guid")
    assert (video.width, video.height) == expected
    assert calls == ["https://video.bunnycdn.com/library/fixture-library/videos/video-guid"]


@pytest.mark.parametrize("width,height,rotation", [
    (None, None, None), (0, 1080, None), (-1, 1080, None),
    (1920, None, None), (True, 1080, None), (1920.5, 1080, None),
    ("1920", 1080, None), (32769, 1080, None),
    (1920, 1080, "90"), (1920, 1080, 45), (1920, 1080, False),
])
def test_bunny_invalid_dimensions_remain_unknown(monkeypatch, width, height, rotation):
    monkeypatch.setattr("app.core.bunny_stream.httpx.get", lambda *args, **kwargs:
        SimpleNamespace(raise_for_status=lambda: None, json=lambda:
            dict(status=3, length=18, width=width, height=height, rotation=rotation)))
    client = object.__new__(BunnyStreamClient)
    client.library_id, client.api_key, client.timeout = "fixture-library", "fixture-key", 1
    video = client.get_video("video-guid")
    assert (video.width, video.height) == (None, None)
    assert video.ready


def test_completed_and_used_upload_responses_retain_dimensions_without_refetch(monkeypatch):
    ledger = MediaUploadLedger()
    row = reservation()
    ledger.reserve(row, UploadLimits.from_env())
    provider_calls = []

    class Provider:
        def get_video(self, video_id):
            provider_calls.append(video_id)
            return BunnyVideo(video_id, 3, 18, width=1920, height=1080)

        def fallback_url(self, video_id):
            return f"https://video.example/{video_id}/play_720p.mp4"

    monkeypatch.setattr(social_router, "upload_ledger", ledger)
    monkeypatch.setattr(social_router, "BunnyStreamClient", Provider)
    monkeypatch.setattr(social_router, "configured_media_storage", lambda: object.__new__(R2MediaStorage))
    user = SimpleNamespace(id=row.user_id)
    attachment = social_router.complete_direct_media_upload(row.id, user)
    repeated = social_router.complete_direct_media_upload(row.id, user)
    ledger.set_status(row.id, row.user_id, "used")
    used = social_router.complete_direct_media_upload(row.id, user)
    assert attachment.width == repeated.width == used.width == 1920
    assert attachment.height == repeated.height == used.height == 1080
    assert attachment.url == row.public_url and attachment.thumbnail_url == row.thumbnail_public_url
    assert attachment.fallback_url == "https://video.example/video-guid/play_720p.mp4"
    assert provider_calls == ["video-guid"]


def test_completed_dimensions_survive_post_validation_response_and_persisted_reload(monkeypatch, tmp_path):
    row = reservation()
    ledger = MediaUploadLedger()
    ledger.reserve(row, UploadLimits.from_env())
    completed = ledger.complete_social_bunny_video(row.id, row.user_id, width=1920, height=1080)
    monkeypatch.setattr(social_router, "upload_ledger", ledger)
    monkeypatch.setattr(social_router, "BunnyStreamClient", lambda: SimpleNamespace(
        fallback_url=lambda identifier: f"https://video.example/{identifier}/play_720p.mp4"))
    monkeypatch.setattr(social_router, "configured_media_storage", lambda: object.__new__(R2MediaStorage))
    attachment = social_router._reservation_attachment(completed)
    user = User(id=row.user_id, email="dimensions-owner@example.com", display_name="Dimension Owner",
                handle="dimensionsowner", home_region="Bali", locale="en", email_verified=True)
    token = "dimension-fixture-token"
    monkeypatch.setattr(store, "postgres_auth", None)
    monkeypatch.setattr(store, "postgres_social", None)
    monkeypatch.setattr(store, "postgres_planning", None)
    monkeypatch.setattr(store, "posts", [])
    monkeypatch.setattr(store, "state_file", tmp_path / "dimensions-state.json")
    monkeypatch.setattr(store, "auth_accounts", {user.email: {"user": user.model_dump(mode="json")}})
    monkeypatch.setattr(store, "session_tokens", {hashlib.sha256(token.encode()).hexdigest(): user.email})
    monkeypatch.setattr(store, "verified_emails", {user.email})
    api_rate_limiter.clear()
    try:
        with TestClient(app) as client:
            headers = {"Authorization": f"Bearer {token}"}
            response = client.post("/api/v1/social/posts", headers=headers, json={
                "body": "Dimensions fixture", "post_type": "general", "visibility": "public",
                "media": [attachment.model_dump(mode="json")],
            })
            assert response.status_code == 200, response.text
            saved = response.json()
            assert (saved["media"][0]["width"], saved["media"][0]["height"]) == (1920, 1080)
            read = client.get(f"/api/v1/social/posts/{saved['id']}", headers=headers)
            assert read.status_code == 200, read.text
            assert read.json()["media"][0] == saved["media"][0]
        monkeypatch.delenv("DATABASE_URL", raising=False)
        monkeypatch.setattr("app.core.store.state_file_path", lambda: tmp_path / "dimensions-state.json")
        reloaded = DemoStore()
        persisted = next(post for post in reloaded.posts if post.id == saved["id"])
        assert persisted.media[0].width == 1920 and persisted.media[0].height == 1080
        assert ledger.get(row.id, row.user_id).status == "used"
    finally:
        api_rate_limiter.clear()


@pytest.mark.parametrize("video,status,ledger_status", [
    (BunnyVideo("video-guid", 2, 18, width=1920, height=1080), 425, "pending"),
    (BunnyVideo("video-guid", 5, 18, width=1920, height=1080), 400, "rejected"),
    (BunnyVideo("video-guid", 3, 31, width=1920, height=1080), 400, "rejected"),
    (BunnyVideo("video-guid", 3, None, width=1920, height=1080), 400, "rejected"),
])
def test_dimensions_do_not_bypass_video_processing_or_duration_limits(monkeypatch, video, status, ledger_status):
    ledger = MediaUploadLedger()
    row = reservation()
    ledger.reserve(row, UploadLimits.from_env())
    monkeypatch.setattr(social_router, "upload_ledger", ledger)
    monkeypatch.setattr(social_router, "BunnyStreamClient", lambda: SimpleNamespace(
        get_video=lambda identifier: video, delete_video=lambda identifier: None))
    monkeypatch.setattr(social_router, "configured_media_storage", lambda: object.__new__(R2MediaStorage))
    with pytest.raises(HTTPException) as caught:
        social_router.complete_direct_media_upload(row.id, SimpleNamespace(id=row.user_id))
    assert caught.value.status_code == status
    loaded = ledger.get(row.id, row.user_id)
    assert loaded.status == ledger_status
    assert loaded.media_width is None and loaded.media_height is None


@pytest.mark.parametrize("width,height", [(None, None), (1920, 1080), (1080, 1920)])
def test_memory_completion_persists_only_pending_owned_social_bunny_video(width, height):
    ledger = MediaUploadLedger()
    row = reservation()
    ledger.reserve(row, UploadLimits.from_env())
    with pytest.raises(ValueError, match="no longer active"):
        ledger.complete_social_bunny_video(row.id, "mallory", width=width, height=height)
    completed = ledger.complete_social_bunny_video(row.id, row.user_id, width=width, height=height)
    assert completed.status == "complete"
    assert (completed.media_width, completed.media_height) == (width, height)
    assert ledger.get(row.id, row.user_id) == completed
    with pytest.raises(ValueError, match="no longer active"):
        ledger.complete_social_bunny_video(row.id, row.user_id, width=1, height=1)
    assert ledger.get(row.id, row.user_id) == completed


@pytest.mark.parametrize("changes", [
    {"purpose": "chat"}, {"media_type": "photo"}, {"storage_provider": "r2"},
    {"status": "canceled"}, {"status": "used"}, {"status": "deleted"},
])
def test_memory_completion_cannot_reclassify_other_uploads(changes):
    ledger = MediaUploadLedger()
    row = replace(reservation(), **changes)
    ledger.reserve(row, UploadLimits.from_env())
    with pytest.raises(ValueError, match="no longer active"):
        ledger.complete_social_bunny_video(row.id, row.user_id, width=1920, height=1080)
    assert ledger.get(row.id, row.user_id) == row


class Database:
    """Minimal transactional SQL fake for the completion/migration row codec."""
    def __init__(self, row):
        self.row = deepcopy(row)
        self.statements = []
        self.fail_commit = False

    @contextmanager
    def connect(self):
        before = deepcopy(self.row)
        try:
            yield self
            if self.fail_commit:
                raise OSError("simulated commit failure")
        except Exception:
            self.row = before
            raise

    def execute(self, query, params=()):
        self.statements.append((query, params))
        normalized = " ".join(query.split())
        result = None
        if "SET status='complete',media_width" in normalized:
            width, height, identifier, user = params
            if (self.row["id"] == identifier and self.row["user_id"] == user
                    and self.row["purpose"] == "social" and self.row["media_type"] == "video"
                    and self.row["storage_provider"] == "bunny_stream" and self.row["status"] == "pending"):
                self.row.update(status="complete", media_width=width, media_height=height)
                result = deepcopy(self.row)
        elif "SELECT * FROM media_upload_reservations" in normalized:
            identifier, user = params
            if self.row["id"] == identifier and self.row["user_id"] == user:
                result = deepcopy(self.row)
        elif normalized.startswith("ALTER TABLE"):
            name = re.search(r"ADD COLUMN IF NOT EXISTS (\w+)", normalized).group(1)
            self.row.setdefault(name, None)
        return SimpleNamespace(fetchone=lambda: result)


def postgres_ledger(database):
    ledger = object.__new__(MediaUploadLedger)
    ledger.database_url = "postgresql://fixture.invalid/not-connected"
    ledger._connect = database.connect
    return ledger


def test_postgres_completion_survives_new_ledger_and_failed_commit_stays_pending():
    row = reservation()
    database = Database(asdict(row))
    ledger = postgres_ledger(database)
    database.fail_commit = True
    with pytest.raises(OSError):
        ledger.complete_social_bunny_video(row.id, row.user_id, width=1920, height=1080)
    database.fail_commit = False
    saved = ledger.get(row.id, row.user_id)
    assert saved.status == "pending" and saved.media_width is None and saved.media_height is None
    ledger.complete_social_bunny_video(row.id, row.user_id, width=1920, height=1080)
    restarted = postgres_ledger(database)
    saved = restarted.get(row.id, row.user_id)
    assert saved.status == "complete" and (saved.media_width, saved.media_height) == (1920, 1080)
    assert restarted.get(row.id, "mallory") is None


def test_additive_schema_migration_does_not_invent_legacy_dimensions():
    row = asdict(replace(reservation(), status="used"))
    row.pop("media_width")
    row.pop("media_height")
    database = Database(row)
    ledger = postgres_ledger(database)
    ledger._ensure_schema()
    saved = ledger.get(row["id"], row["user_id"])
    assert saved.status == "used" and saved.media_width is None and saved.media_height is None
    assert any("media_width INTEGER" in sql for sql, _ in database.statements)
    assert any("media_height INTEGER" in sql for sql, _ in database.statements)
    assert all("DROP" not in sql and "DELETE" not in sql for sql, _ in database.statements)
