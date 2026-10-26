from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.media_uploads import (
    MediaUploadLedger,
    UploadLimits,
    UploadQuotaExceeded,
    UploadReservation,
)
from app.core import media_cleanup
from app.core.media_storage import R2MediaStorage
from app.core.video_metadata import mp4_duration_from_bytes


def _reservation(index: int, *, media_type: str = "video") -> UploadReservation:
    now = datetime.now(timezone.utc)
    return UploadReservation(
        id=f"media_{index}",
        user_id="user_1",
        client_ip_hash="ip_1",
        media_type=media_type,
        content_type="video/mp4" if media_type == "video" else "image/jpeg",
        thumbnail_content_type=None,
        expected_bytes=10,
        expected_thumbnail_bytes=0,
        pending_name=f"pending/media_{index}.mp4",
        final_name=f"media/media_{index}.mp4",
        pending_thumbnail_name=None,
        final_thumbnail_name=None,
        public_url=f"https://media.test/media_{index}.mp4",
        thumbnail_public_url=f"https://media.test/media_{index}.mp4",
        status="pending",
        created_at=now,
        expires_at=now + timedelta(minutes=5),
    )


def test_upload_ledger_enforces_video_daily_limit():
    ledger = MediaUploadLedger()
    limits = UploadLimits(
        uploads_per_minute=10,
        videos_per_user_day=1,
        media_per_user_day=10,
        user_bytes_per_day=1_000,
        user_retained_bytes=10_000,
        global_bytes_per_day=10_000,
        global_uploads_per_day=100,
        global_retained_bytes=10_000,
    )

    ledger.reserve(_reservation(1), limits)

    with pytest.raises(UploadQuotaExceeded, match="video upload limit"):
        ledger.reserve(_reservation(2), limits)


def test_upload_ledger_enforces_per_user_retained_storage_limit():
    ledger = MediaUploadLedger()
    limits = UploadLimits(
        uploads_per_minute=10,
        videos_per_user_day=10,
        media_per_user_day=10,
        user_bytes_per_day=1_000,
        user_retained_bytes=15,
        global_bytes_per_day=10_000,
        global_uploads_per_day=100,
        global_retained_bytes=10_000,
    )

    first = _reservation(1)
    ledger.reserve(first, limits)
    ledger.set_status(first.id, first.user_id, "used")

    with pytest.raises(UploadQuotaExceeded, match="media storage is full"):
        ledger.reserve(_reservation(2), limits)


def test_cleanup_deletes_abandoned_completed_uploads(monkeypatch):
    ledger = MediaUploadLedger()
    limits = UploadLimits(
        uploads_per_minute=10,
        videos_per_user_day=10,
        media_per_user_day=10,
        user_bytes_per_day=1_000,
        user_retained_bytes=10_000,
        global_bytes_per_day=10_000,
        global_uploads_per_day=100,
        global_retained_bytes=10_000,
    )
    reservation = _reservation(3)
    reservation = UploadReservation(
        **{
            **reservation.__dict__,
            "status": "complete",
            "created_at": datetime.now(timezone.utc) - timedelta(hours=2),
        }
    )
    ledger.reserve(reservation, limits)

    class FakeR2Storage(R2MediaStorage):
        def __init__(self):
            self.deleted: list[str] = []

        def delete_object(self, object_name):
            if object_name is not None:
                self.deleted.append(object_name)

    storage = FakeR2Storage()
    monkeypatch.setattr(media_cleanup, "upload_ledger", ledger)
    monkeypatch.setattr(media_cleanup, "configured_media_storage", lambda: storage)
    monkeypatch.setenv("MEDIA_ABANDONED_UPLOAD_GRACE_SECONDS", "3600")

    result = media_cleanup.run_media_cleanup()

    assert result.abandoned == 1
    assert reservation.final_name in storage.deleted
    assert ledger.get(reservation.id, reservation.user_id).status == "abandoned"


def test_mp4_duration_parser_reads_version_zero_movie_header():
    timescale = 1_000
    duration = 30_000
    mvhd = b"".join(
        [
            (28).to_bytes(4, "big"),
            b"mvhd",
            b"\x00\x00\x00\x00",
            (0).to_bytes(4, "big"),
            (0).to_bytes(4, "big"),
            timescale.to_bytes(4, "big"),
            duration.to_bytes(4, "big"),
        ]
    )
    moov = (len(mvhd) + 8).to_bytes(4, "big") + b"moov" + mvhd

    assert mp4_duration_from_bytes(moov) == 30.0


def test_direct_upload_signature_binds_exact_content_length():
    captured: dict[str, object] = {}

    class FakeClient:
        def generate_presigned_url(self, operation, **kwargs):
            captured["operation"] = operation
            captured.update(kwargs)
            return "https://upload.example/signed"

    storage = object.__new__(R2MediaStorage)
    storage.bucket = "tydes-media"
    storage.public_url = "https://media.example"
    storage.prefix = "uploads"
    storage._client = FakeClient()

    url = storage.create_direct_upload_url(
        "pending/video.mp4",
        content_type="video/mp4",
        content_length=12_345,
        expires_seconds=300,
    )

    assert url == "https://upload.example/signed"
    assert captured["operation"] == "put_object"
    assert captured["Params"]["ContentLength"] == 12_345
    assert captured["Params"]["IfNoneMatch"] == "*"
    assert captured["ExpiresIn"] == 300
