"""Private media protocol, using only fake credentials and fake providers."""
import base64
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import httpx
from pathlib import Path
import sys

import pytest
from fastapi import HTTPException
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core import chat_media, media_cleanup
from app.core.bunny_stream import BunnyFetchRejected, BunnyVideo, PrivateChatBunnyClient
from app.core.media_storage import PrivateChatR2Storage, StoredObjectMetadata
from app.core.media_uploads import MediaUploadLedger, UploadLimits, UploadQuotaExceeded
from app.core.models import build_seed
from app.core.auth import require_authenticated_user
from app.core.rate_limit import api_rate_limiter
from app.modules.messages.media_router import router as media_router
from app.core.video_validation import ValidatedVideo


class PhotoStorage:
    deleted = []
    size = 16
    header = bytes.fromhex("ffd8ffc0000b080001000101011100") + b"0"
    def create_direct_upload_url(self, name, **kwargs):
        self.target = (name, kwargs)
        return "https://private-r2.example.invalid/signed-put"
    def object_metadata(self, name):
        return StoredObjectMetadata(self.size, "image/jpeg")
    def read_object_range(self, *args):
        return self.header
    def signed_read_url(self, name, **kwargs):
        self.read_target = (name, kwargs)
        return "https://private-r2.example.invalid/object?signature=temporary"
    def delete_object(self, name):
        self.deleted.append(name)


class VideoStorage:
    deleted = []
    video = BunnyVideo("video-guid", 3, 18, 100_000, encode_progress=100,
                       available_resolutions=("240p", "360p", "480p"), has_mp4_fallback=True)
    reads = 0
    probes = 0
    mp4_resolution = "480p"
    def fetch_validated_source(self, url, title, *, etag):
        self.fetches.append((url, title, etag))
    def resolve_imported_video(self, title):
        self.resolves.append(title)
        return self.resolved_id
    def get_video(self, identifier):
        self.reads += 1
        return self.video
    def verified_mp4_resolution(self, identifier, resolutions, *, max_bytes):
        self.probes += 1
        assert max_bytes == chat_media.VIDEO_MAX_BYTES
        return self.mp4_resolution
    def delete_video(self, identifier):
        self.deleted.append(identifier)
    def signed_url(self, identifier, filename, **kwargs):
        return f"https://private-video.example.invalid/signed/{identifier}/{filename}"


class DurableFixtureLedger:
    """Advertise the tested production prerequisite without opening a database.

    Every operation remains bound to a separate in-memory ledger. Merely
    changing that ledger's database_url would accidentally invoke psycopg.
    """
    database_url = "postgresql://fixture.invalid/tydes-test-only"

    def __init__(self):
        self.memory = MediaUploadLedger()

    def __getattr__(self, name):
        return getattr(self.memory, name)


@pytest.fixture
def fixture(monkeypatch):
    values = {
        "CHAT_MEDIA_ENABLED": "true", "CHAT_R2_PRIVATE_VERIFIED": "true",
        "CHAT_R2_PRIVATE_BUCKET": "private-chat-fixture", "CHAT_R2_ACCESS_KEY_ID": "fake",
        "CHAT_R2_SECRET_ACCESS_KEY": "fake-secret", "CHAT_BUNNY_STREAM_PRIVATE_VERIFIED": "true",
        "CHAT_BUNNY_STREAM_LIBRARY_ID": "private-library", "CHAT_BUNNY_STREAM_API_KEY": "fake-video",
        "CHAT_BUNNY_STREAM_CDN_HOSTNAME": "private.example.invalid",
        "CHAT_BUNNY_STREAM_TOKEN_KEY": "fake-token-key",
        "CHAT_VIDEO_STAGING_VERIFIED": "true",
    }
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    ledger = DurableFixtureLedger()
    photo, video = PhotoStorage(), VideoStorage()
    photo.deleted, video.deleted = [], []
    video.fetches, video.resolves, video.resolved_id = [], [], "video-guid"
    video.reads = video.probes = 0
    monkeypatch.setattr(chat_media, "upload_ledger", ledger)
    monkeypatch.setattr(chat_media, "PrivateChatR2Storage", lambda: photo)
    monkeypatch.setattr(chat_media, "PrivateChatBunnyClient", lambda: video)
    monkeypatch.setattr(chat_media, "authorize_context", lambda *args, **kwargs: None)
    monkeypatch.setattr(chat_media, "_message_exists", lambda *args: True)
    monkeypatch.setattr(chat_media.video_validation, "is_available", lambda: True)
    monkeypatch.setattr(chat_media.video_validation, "validate_staged_video", lambda *args:
        ValidatedVideo('"' + "a" * 32 + '"', 18, 320, 180, 540))
    user = build_seed()["user"].model_copy(update={"id": "alice", "email_verified": True})
    return user, ledger, photo, video


def upload(fixture, media_type="photo", scope="thread-a"):
    user = fixture[0]
    return chat_media.reserve(user, "direct", scope, media_type,
        "image/jpeg" if media_type == "photo" else "video/mp4", 16, "127.0.0.1")


def test_capabilities_fail_closed_independently(monkeypatch):
    monkeypatch.setenv("CHAT_MEDIA_ENABLED", "false")
    assert not chat_media.capabilities()["enabled"]
    monkeypatch.setenv("CHAT_MEDIA_ENABLED", "true")
    monkeypatch.setenv("CHAT_R2_PRIVATE_VERIFIED", "false")
    monkeypatch.setenv("CHAT_BUNNY_STREAM_PRIVATE_VERIFIED", "false")
    assert not chat_media.capabilities()["enabled"]


def test_photos_can_work_without_private_video(fixture, monkeypatch):
    monkeypatch.delenv("CHAT_BUNNY_STREAM_TOKEN_KEY")
    assert chat_media.capabilities()["photos_enabled"]
    assert not chat_media.capabilities()["videos_enabled"]
    with pytest.raises(HTTPException) as error:
        upload(fixture, "video")
    assert error.value.status_code == 503
    assert fixture[1]._memory == {}


def test_videos_require_the_constructed_durable_ledger_not_only_a_database_environment(fixture, monkeypatch):
    user, _, _, bunny = fixture
    memory = MediaUploadLedger()
    monkeypatch.setattr(chat_media, "upload_ledger", memory)
    monkeypatch.setenv("DATABASE_URL", "postgresql://fixture.invalid/not-opened")
    caps = chat_media.capabilities()
    assert caps["photos_enabled"] is True and caps["enabled"] is True
    assert caps["videos_enabled"] is False
    with pytest.raises(HTTPException) as error:
        chat_media.reserve(user, "direct", "thread-a", "video", "video/mp4", 16, "127.0.0.1")
    assert error.value.status_code == 503 and memory._memory == {}
    assert bunny.fetches == []
    photo = chat_media.reserve(user, "direct", "thread-a", "photo", "image/jpeg", 16, "127.0.0.1")
    assert chat_media.complete(user, photo["id"])["status"] == "ready"


def test_video_durable_gate_uses_initialized_ledger_even_if_environment_changes(fixture, monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    assert fixture[1].database_url
    assert fixture[1].memory.database_url is None  # All test I/O is memory-only.
    assert chat_media.capabilities()["videos_enabled"] is True


def test_photo_upload_has_no_public_url_and_requires_sent_binding(fixture):
    user, ledger, photo, _ = fixture
    target = upload(fixture)
    row = ledger.get(target["id"], user.id)
    assert row.purpose == "chat" and row.scope_id == "thread-a"
    assert row.public_url == row.thumbnail_public_url == ""
    assert photo.target[1]["content_length"] == 16
    assert target["upload"]["protocol"] == "put"
    assert chat_media.complete(user, row.id)["status"] == "ready"
    with pytest.raises(HTTPException):
        chat_media.access(user, row.id, "direct", "thread-a")
    ledger.claim_chat_media(user.id, "direct", "thread-a", [row.id], "message-a", "retry-a")
    signed = chat_media.access(user, row.id, "direct", "thread-a")
    assert "signature=" in signed["url"]
    with pytest.raises(HTTPException):
        chat_media.access(user, row.id, "direct", "thread-b")
    with pytest.raises(ValueError):
        ledger.assert_completed_media(user.id, [(row.id, "photo", "", "")])
    with pytest.raises(ValueError):
        ledger.mark_used(user.id, [row.id])


def test_claim_is_idempotent_but_never_reusable_across_messages(fixture):
    user, ledger, _, _ = fixture
    identifier = upload(fixture)["id"]
    chat_media.complete(user, identifier)
    def claim(message):
        try:
            ledger.claim_chat_media(user.id, "direct", "thread-a", [identifier], message, message)
            return True
        except ValueError:
            return False
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(claim, ["message-a", "message-b"]))
    assert sorted(results) == [False, True]
    bound = ledger.get(identifier, user.id)
    assert claim(bound.message_id)
    with pytest.raises(HTTPException) as error:
        chat_media.cancel(user, identifier)
    assert error.value.status_code == 409


def test_ambiguous_claim_without_durable_message_cannot_issue_access(fixture, monkeypatch):
    user, ledger, _, _ = fixture
    identifier = upload(fixture)["id"]
    chat_media.complete(user, identifier)
    ledger.claim_chat_media(user.id, "direct", "thread-a", [identifier], "message-a", "retry-a")
    monkeypatch.setattr(chat_media, "_message_exists", lambda *args: False)
    with pytest.raises(HTTPException) as error:
        chat_media.access(user, identifier, "direct", "thread-a")
    assert error.value.status_code == 404


@pytest.mark.parametrize("bad_size,bad_header", [(17, False), (16, True)])
def test_invalid_photo_is_rejected_and_deleted(fixture, bad_size, bad_header):
    user, ledger, photo, _ = fixture
    identifier = upload(fixture)["id"]
    photo.size = bad_size
    if bad_header:
        photo.header = b"<html>not-photo!"
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    assert ledger.get(identifier, user.id).status == "rejected"
    assert photo.deleted


def test_video_processing_and_actual_encoded_storage_guard(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    assert ledger.get(identifier, user.id).total_bytes == chat_media.VIDEO_MAX_BYTES + 16
    video.video = BunnyVideo("video-guid", 2, None, 100)
    assert chat_media.complete(user, identifier)["status"] == "processing"
    video.video = BunnyVideo("video-guid", 3, 18, chat_media.VIDEO_MAX_BYTES + 1, encode_progress=100)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    assert video.deleted == ["video-guid"]
    assert ledger.get(identifier, user.id).status == "rejected"


@pytest.mark.parametrize("duration,size", [(31, 100), (float("nan"), 100), (-1, 100)])
def test_unverifiable_video_never_becomes_ready(fixture, duration, size):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.video = BunnyVideo("video-guid", 3, duration, size, encode_progress=100)
    with pytest.raises(HTTPException):
        chat_media.complete(user, identifier)
    assert ledger.get(identifier, user.id).status != "complete"


def test_pending_and_canceled_private_bytes_still_consume_shared_quota(fixture):
    user, ledger, _, _ = fixture
    identifier = upload(fixture)["id"]
    row = ledger.get(identifier, user.id)
    chat_media.cancel(user, identifier)
    assert ledger.get(identifier, user.id).status == "canceled"
    limits = replace(UploadLimits.from_env(), user_retained_bytes=16)
    with pytest.raises(UploadQuotaExceeded, match="storage is full"):
        ledger.reserve(replace(row, id="another", purpose="social", status="pending"), limits)
    assert len(ledger._memory) == 1


def test_partially_encoded_video_stays_processing_until_all_storage_is_known(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.video = BunnyVideo("video-guid", 4, 18, 100, 50)
    assert chat_media.complete(user, identifier)["status"] == "processing"
    assert ledger.get(identifier, user.id).status == "pending"
    video.video = BunnyVideo("video-guid", 4, 18, 100, 100,
                            available_resolutions=("480p",), has_mp4_fallback=True)
    assert chat_media.complete(user, identifier)["status"] == "ready"


@pytest.mark.parametrize("status,progress", [
    (3, 5), (3, None), (3, 0), (3, 99), (4, 99),
    (9, 100), (10, 100),
])
def test_private_video_needs_final_get_video_progress_and_supported_status(fixture, status, progress):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    valid = video.video
    # Every other proof is present, but private completion must still wait.
    video.video = replace(valid, status=status, encode_progress=progress)
    assert video.video.storage_size > 0 and video.video.has_mp4_fallback
    for _ in range(2):
        assert chat_media.complete(user, identifier)["status"] == "processing"
    row = ledger.get(identifier, user.id)
    assert row.status == "pending" and row.chat_video_mp4_resolution is None
    assert len(video.fetches) == 1 and video.probes == 0 and video.deleted == []
    with pytest.raises(ValueError):
        ledger.validate_chat_media(user.id, "direct", "thread-a", [identifier])
    video.video = replace(valid, status=4, encode_progress=100)
    assert chat_media.complete(user, identifier)["status"] == "ready"
    assert len(video.fetches) == 1 and video.probes == 1


def test_low_resolution_video_persists_verified_mp4_and_access_never_rechecks_provider(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    assert chat_media.complete(user, identifier)["status"] == "ready"
    row = ledger.get(identifier, user.id)
    assert row.chat_video_resolutions == "240p,360p,480p"
    assert row.chat_video_mp4_resolution == "480p"
    assert (video.reads, video.probes) == (1, 1)
    # Completion retries and every authorized viewer use the durable choice.
    assert chat_media.complete(user, identifier)["status"] == "ready"
    ledger.claim_chat_media(user.id, "direct", "thread-a", [identifier], "message-a", "retry-a")
    for _ in range(3):
        result = chat_media.access(user, identifier, "direct", "thread-a")
        assert result["url"].endswith("/play_480p.mp4")
        assert result["fallback_url"] == result["url"]
        assert result["thumbnail_url"].endswith("/thumbnail.jpg")
    assert (video.reads, video.probes) == (1, 1)


@pytest.mark.parametrize("resolutions,fallback,code", [
    (("720p", "1080p"), True, 400), (("2160p",), True, 400),
])
def test_unverified_or_high_private_video_metadata_never_becomes_ready(fixture, resolutions, fallback, code):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.video = replace(video.video, available_resolutions=resolutions, has_mp4_fallback=fallback)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == code
    row = ledger.get(identifier, user.id)
    assert row.status != "complete" and row.chat_video_mp4_resolution is None
    assert video.probes == 0


@pytest.mark.parametrize("field,value", [
    ("length_seconds", None), ("length_seconds", 0),
    ("storage_size", None), ("storage_size", 0),
    ("available_resolutions", None), ("available_resolutions", ()),
    ("has_mp4_fallback", None), ("has_mp4_fallback", False),
])
def test_finished_encoding_with_lagging_metadata_stays_pending_then_ready(fixture, field, value):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    valid = video.video
    video.video = replace(valid, **{field: value})
    assert video.video.fully_encoded
    for _ in range(2):
        assert chat_media.complete(user, identifier)["status"] == "processing"
    row = ledger.get(identifier, user.id)
    assert row.status == "pending" and row.chat_import_state == "imported"
    assert row.chat_video_mp4_resolution is None
    assert video.probes == 0 and video.deleted == [] and len(video.fetches) == 1
    with pytest.raises(ValueError):
        ledger.validate_chat_media(user.id, "direct", "thread-a", [identifier])
    video.video = valid
    assert chat_media.complete(user, identifier)["status"] == "ready"
    assert ledger.get(identifier, user.id).chat_video_mp4_resolution == "480p"
    assert len(video.fetches) == 1 and video.probes == 1


def test_lagging_finished_metadata_does_not_extend_the_import_deadline(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.video = replace(video.video, storage_size=0, has_mp4_fallback=False)
    assert chat_media.complete(user, identifier)["status"] == "processing"
    row = ledger.get(identifier, user.id)
    original_read_expiry = row.chat_source_read_expires_at
    ledger._memory[identifier] = replace(row, created_at=datetime.now(timezone.utc) - timedelta(hours=3))
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 410
    assert ledger.get(identifier, user.id).chat_source_read_expires_at == original_read_expiry
    assert len(video.fetches) == 1 and video.probes == 0


@pytest.mark.parametrize("change", [
    {"storage_size": chat_media.VIDEO_MAX_BYTES + 1},
    {"length_seconds": float("nan")},
    {"length_seconds": 31},
    {"available_resolutions": ("480p", "1080p")},
    {"status": 5}, {"status": 8},
])
def test_known_video_violations_reject_even_when_other_metadata_is_lagging(fixture, change):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.video = replace(video.video, **{"storage_size": 0, "has_mp4_fallback": False, **change})
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    assert ledger.get(identifier, user.id).status == "rejected"
    assert video.deleted == ["video-guid"] and video.probes == 0


def test_mp4_not_distributed_yet_stays_processing_without_claimable_metadata(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.mp4_resolution = None
    assert chat_media.complete(user, identifier)["status"] == "processing"
    row = ledger.get(identifier, user.id)
    assert row.status == "pending" and row.chat_video_resolutions is None
    with pytest.raises(ValueError):
        ledger.validate_chat_media(user.id, "direct", "thread-a", [identifier])


def test_legacy_private_video_rows_fail_closed_without_provider_revalidation(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    ledger._memory[identifier] = replace(ledger.get(identifier, user.id), status="used", message_id="old-message")
    for operation in [lambda: chat_media.complete(user, identifier),
                      lambda: chat_media.access(user, identifier, "direct", "thread-a")]:
        with pytest.raises(HTTPException) as error:
            operation()
        assert error.value.status_code == 409
    with pytest.raises(ValueError):
        ledger.validate_chat_media(user.id, "direct", "thread-a", [identifier])
    with pytest.raises(ValueError):
        ledger.claim_chat_media(user.id, "direct", "thread-a", [identifier], "old-message", "old-client")
    assert (video.reads, video.probes) == (0, 0)


def test_mp4_probe_rejects_redirects_and_uses_only_bounded_head_requests(fixture, monkeypatch):
    client = PrivateChatBunnyClient()
    requests = []
    def head(url, **kwargs):
        requests.append((url, kwargs))
        code = 404 if url.endswith("play_720p.mp4") else 200
        return httpx.Response(code, headers={"content-type": "video/mp4", "content-length": "1200"},
                              request=httpx.Request("HEAD", url))
    monkeypatch.setattr("app.core.bunny_stream.httpx.head", head)
    resolution = client.verified_mp4_resolution("video-guid", ("240p", "360p", "480p", "720p"), max_bytes=50_000)
    assert resolution == "480p" and len(requests) == 2
    assert all(kwargs["follow_redirects"] is False and kwargs["timeout"].read == 5 for _, kwargs in requests)
    assert all(kwargs["headers"] == {"Referer": "https://tydes.io/"} for _, kwargs in requests)
    assert all("token_path=" not in url for url, _ in requests)
    assert all("bcdn_token=HS256-" in url for url, _ in requests)
    monkeypatch.setattr("app.core.bunny_stream.httpx.head", lambda url, **_: httpx.Response(
        302, headers={"location": "https://untrusted.invalid/"}, request=httpx.Request("HEAD", url)))
    with pytest.raises(httpx.HTTPStatusError):
        client.verified_mp4_resolution("video-guid", ("480p",), max_bytes=50_000)


@pytest.mark.parametrize("headers", [
    {"content-type": "text/html", "content-length": "120"},
    {"content-type": "video/mp4"},
    {"content-type": "video/mp4", "content-length": "0"},
    {"content-type": "video/mp4", "content-length": "50001"},
])
def test_mp4_probe_never_trusts_missing_wrong_or_oversize_file_headers(fixture, monkeypatch, headers):
    monkeypatch.setattr("app.core.bunny_stream.httpx.head", lambda url, **_: httpx.Response(
        200, headers=headers, request=httpx.Request("HEAD", url)))
    with pytest.raises(RuntimeError):
        PrivateChatBunnyClient().verified_mp4_resolution("video-guid", ("480p",), max_bytes=50_000)


def test_mp4_probe_is_capped_to_four_candidates_and_missing_files_stay_unready(fixture, monkeypatch):
    requests = []
    def head(url, **kwargs):
        requests.append(url)
        return httpx.Response(404, request=httpx.Request("HEAD", url))
    monkeypatch.setattr("app.core.bunny_stream.httpx.head", head)
    client = PrivateChatBunnyClient()
    assert client.verified_mp4_resolution("video-guid", ("240p", "360p", "480p", "720p"), max_bytes=50_000) is None
    assert len(requests) == 4
    with pytest.raises(ValueError):
        client.verified_mp4_resolution("video-guid", ("1080p",), max_bytes=50_000)
    assert len(requests) == 4


def test_cancel_while_mp4_is_checked_cannot_publish_ready_playback(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    def canceled(*args, **kwargs):
        chat_media.cancel(user, identifier)
        return "480p"
    video.verified_mp4_resolution = canceled
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 409
    row = ledger.get(identifier, user.id)
    assert row.status == "canceled" and row.chat_video_mp4_resolution is None


@pytest.mark.parametrize("raw,expected", [
    ("720p, 240p,480p", ("240p", "480p", "720p")),
    ("1080p,720p", ("720p", "1080p")), (None, None),
    ("", None), ("480p,480p", None), ("../original", None), (["480p"], None),
])
def test_bunny_video_metadata_parser_keeps_actual_resolutions_and_strict_mp4_flag(fixture, monkeypatch, raw, expected):
    def get(url, **kwargs):
        return httpx.Response(200, json={"guid": "video-guid", "status": 3,
            "length": 18, "storageSize": 100, "availableResolutions": raw,
            "hasMP4Fallback": True}, request=httpx.Request("GET", url))
    monkeypatch.setattr("app.core.bunny_stream.httpx.get", get)
    video = PrivateChatBunnyClient().get_video("video-guid")
    assert video.available_resolutions == expected
    assert video.has_mp4_fallback is True


@pytest.mark.parametrize("value,expected", [(False, False), ("true", None), (1, None), (None, None)])
def test_bunny_mp4_flag_never_coerces_truthy_unverified_values(fixture, monkeypatch, value, expected):
    monkeypatch.setattr("app.core.bunny_stream.httpx.get", lambda url, **_: httpx.Response(
        200, json={"status": 3, "length": 18, "hasMP4Fallback": value}, request=httpx.Request("GET", url)))
    assert PrivateChatBunnyClient().get_video("video-guid").has_mp4_fallback is expected


def test_mp4_probe_does_not_mask_a_private_cdn_authorization_failure(fixture, monkeypatch):
    requests = []
    def head(url, **kwargs):
        requests.append(url)
        return httpx.Response(403, request=httpx.Request("HEAD", url))
    monkeypatch.setattr("app.core.bunny_stream.httpx.head", head)
    with pytest.raises(httpx.HTTPStatusError):
        PrivateChatBunnyClient().verified_mp4_resolution("video-guid", ("240p", "720p"), max_bytes=50_000)
    assert len(requests) == 1


def test_overlong_video_is_deleted_without_waiting_for_encoding(fixture):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.video = BunnyVideo("video-guid", 2, 3600, 100, 5)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    assert video.deleted == ["video-guid"]


def test_private_cleanup_rechecks_after_signed_write_expiry(fixture, monkeypatch):
    user, ledger, photo, _ = fixture
    identifier = upload(fixture)["id"]
    chat_media.cancel(user, identifier)
    ledger._memory[identifier] = replace(ledger.get(identifier, user.id),
        expires_at=datetime.now(timezone.utc) - timedelta(seconds=1))
    monkeypatch.setattr(media_cleanup, "upload_ledger", ledger)
    monkeypatch.setattr(media_cleanup, "configured_media_storage", lambda: None)
    assert media_cleanup.run_media_cleanup().expired == 1
    assert ledger.get(identifier, user.id).status == "expired"
    assert len(photo.deleted) == 2


def test_stale_cleanup_snapshot_cannot_delete_a_newly_sent_attachment(fixture, monkeypatch):
    user, ledger, photo, _ = fixture
    identifier = upload(fixture)["id"]
    chat_media.complete(user, identifier)
    snapshot = ledger.get(identifier, user.id)
    ledger.claim_chat_media(user.id, "direct", "thread-a", [identifier], "message-a", "retry-a")
    monkeypatch.setattr(media_cleanup, "upload_ledger", ledger)
    result = media_cleanup._delete_reservations(None, [snapshot],
        object_names=media_cleanup._final_object_names, final_status="abandoned")
    assert result == (0, 0)
    assert photo.deleted == []
    assert ledger.get(identifier, user.id).status == "used"


def test_bunny_tokens_are_exact_path_hmac_tokens_for_approved_mp4_and_thumbnail(fixture):
    client = PrivateChatBunnyClient()
    expires = 1800000000
    url = client.signed_url("video-guid", "play_480p.mp4", expires=expires)
    message = f"/video-guid/play_480p.mp4{expires}".encode()
    expected = base64.urlsafe_b64encode(hmac.new(b"fake-token-key", message, hashlib.sha256).digest()).decode().rstrip("=")
    assert f"bcdn_token=HS256-{expected}" in url
    assert "token_path=" not in url
    assert url.endswith("/video-guid/play_480p.mp4")
    assert "fake-token-key" not in url
    for filename in ["thumbnail.jpg", "play_240p.mp4", "play_360p.mp4", "play_480p.mp4", "play_720p.mp4"]:
        assert "/bcdn_token=" in client.signed_url("video-guid", filename, expires=expires)
    for filename in ["original", "playlist.m3u8", "720p/video.m3u8", "play_1080p.mp4", "play_2160p.mp4", "../thumbnail.jpg"]:
        with pytest.raises(ValueError):
            client.signed_url("video-guid", filename, expires=expires)


def test_private_r2_signer_never_uses_public_domain(fixture):
    captured = {}
    class Client:
        def generate_presigned_url(self, operation, **kwargs):
            captured.update(operation=operation, **kwargs)
            return "https://private-s3.example.invalid/signed"
    storage = PrivateChatR2Storage()
    storage._client = Client()
    assert "private-s3" in storage.signed_read_url("photo.jpg", expires_seconds=300)
    assert captured["Params"]["Bucket"] == "private-chat-fixture"
    assert captured["Params"]["ResponseCacheControl"] == "private, no-store"
    with pytest.raises(RuntimeError):
        storage.public_object_url("photo.jpg")


def test_private_provider_configuration_rejects_public_reuse(fixture, monkeypatch):
    monkeypatch.setenv("CLOUDFLARE_R2_BUCKET", "private-chat-fixture")
    assert not chat_media.capabilities()["photos_enabled"]
    with pytest.raises(RuntimeError):
        PrivateChatR2Storage()
    monkeypatch.setenv("BUNNY_STREAM_LIBRARY_ID", "private-library")
    assert not chat_media.capabilities()["videos_enabled"]
    with pytest.raises(RuntimeError):
        PrivateChatBunnyClient()


def test_complete_never_finds_another_owners_reservation(fixture):
    user, _, _, _ = fixture
    identifier = upload(fixture)["id"]
    other = user.model_copy(update={"id": "mallory"})
    with pytest.raises(HTTPException) as error:
        chat_media.complete(other, identifier)
    assert error.value.status_code == 404


def test_http_contract_has_no_arbitrary_url_input_and_no_store_output(fixture):
    user, ledger, _, _ = fixture
    application = FastAPI()
    application.include_router(media_router, prefix="/messages")
    application.dependency_overrides[require_authenticated_user] = lambda: user
    api_rate_limiter.clear()
    with TestClient(application) as client:
        caps = client.get("/messages/media/capabilities")
        assert caps.status_code == 200
        assert caps.json()["photos_enabled"] and caps.json()["videos_enabled"]
        assert caps.headers["cache-control"] == "private, no-store"
        payload = {"conversation_type": "direct", "conversation_id": "thread-a",
                   "media_type": "photo", "content_type": "image/jpeg", "size_bytes": 16}
        assert client.post("/messages/media/uploads", json={**payload, "url": "https://public.invalid/leak.jpg"}).status_code == 422
        result = client.post("/messages/media/uploads", json=payload)
        assert result.status_code == 200
        identifier = result.json()["id"]
        assert "url" not in {key: value for key, value in result.json().items() if key != "upload"}
        assert client.post(f"/messages/media/uploads/{identifier}/complete").json()["status"] == "ready"
        ledger.claim_chat_media(user.id, "direct", "thread-a", [identifier], "message-a", "retry-a")
        response = client.post(f"/messages/media/{identifier}/access", json={"conversation_type": "direct", "conversation_id": "thread-a"})
        assert response.status_code == 200 and response.headers["cache-control"] == "private, no-store"
        assert response.json()["expires_at"]
    api_rate_limiter.clear()


def _jpeg_header(width, height):
    return b"\xff\xd8\xff\xc0\x00\x0b\x08" + height.to_bytes(2, "big") + width.to_bytes(2, "big") + b"\x01\x01\x11\x00"


@pytest.mark.parametrize("width,height", [(10000, 1), (7000, 7000)])
def test_photo_header_dimension_bombs_are_rejected_without_decoding(fixture, width, height):
    user, ledger, photo, _ = fixture
    identifier = upload(fixture)["id"]
    photo.header = _jpeg_header(width, height)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    assert ledger.get(identifier, user.id).status == "rejected"
    assert photo.deleted


def test_png_webp_and_jpeg_dimension_headers_are_parsed_in_bounded_memory():
    png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + (100000).to_bytes(4, "big") * 2 + b"\x08\x02\0\0\0" + b"\0" * 4
    assert chat_media._image_dimensions(png, "image/png") == (100000, 100000)
    assert chat_media._image_dimensions(_jpeg_header(2048, 1024), "image/jpeg") == (2048, 1024)
    packed = (2047 | (1023 << 14)).to_bytes(4, "little")
    vp8l = b"RIFF" + (18).to_bytes(4, "little") + b"WEBPVP8L" + (5).to_bytes(4, "little") + b"\x2f" + packed + b"\0"
    assert chat_media._image_dimensions(vp8l, "image/webp") == (2048, 1024)
    vp8x = b"RIFF" + (22).to_bytes(4, "little") + b"WEBPVP8X" + (10).to_bytes(4, "little") + b"\x02" + b"\0" * 9
    with pytest.raises(ValueError, match="Animated"):
        chat_media._image_dimensions(vp8x, "image/webp")
    for data, content_type in [(b"\xff\xd8\xff\xe1\xff\xff" + b"0" * 65530, "image/jpeg"), (png[:20], "image/png"), (vp8l[:20], "image/webp")]:
        with pytest.raises(ValueError):
            chat_media._image_dimensions(data[:65536], content_type)


def test_tiny_png_with_huge_ihdr_is_rejected_before_ready(fixture):
    user, ledger, photo, _ = fixture
    png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + (100000).to_bytes(4, "big") * 2 + b"\x08\x02\0\0\0" + b"\0" * 4
    photo.header = png
    photo.object_metadata = lambda name: StoredObjectMetadata(len(png), "image/png")
    target = chat_media.reserve(user, "direct", "thread-a", "photo", "image/png", len(png), "127.0.0.1")
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, target["id"])
    assert error.value.status_code == 400
    assert ledger.get(target["id"], user.id).status == "rejected"
    assert photo.deleted


def test_private_video_staging_link_expires_after_fifteen_minutes(fixture):
    user, ledger, _, _ = fixture
    target = upload(fixture, "video")
    row = ledger.get(target["id"], user.id)
    assert timedelta(minutes=14) < row.expires_at - row.created_at < timedelta(minutes=16)


def test_scope_deletion_queues_other_participants_without_releasing_retained_bytes(fixture):
    user, ledger, _, _ = fixture
    identifier = upload(fixture)["id"]
    chat_media.complete(user, identifier)
    ledger.claim_chat_media(user.id, "direct", "thread-a", [identifier], "message-a", "retry-a")
    row = ledger.get(identifier, user.id)
    ledger.reserve(replace(row, id="bob-photo", user_id="bob"), UploadLimits.from_env())
    ledger.queue_chat_scope_deletion("direct", "thread-a")
    assert ledger.get(identifier, user.id).status == "deletion_pending"
    assert ledger.get("bob-photo", "bob").status == "deletion_pending"
    with pytest.raises(UploadQuotaExceeded):
        ledger.reserve(replace(row, id="another", status="pending"),
                       replace(UploadLimits.from_env(), user_retained_bytes=16))


def test_private_video_reserves_exact_immutable_r2_source_without_any_bunny_grant(fixture):
    user, ledger, storage, bunny = fixture
    target = upload(fixture, "video")
    row = ledger.get(target["id"], user.id)
    assert target["upload"]["protocol"] == "put"
    assert target["upload"]["headers"] == {"Content-Type": "video/mp4", "If-None-Match": "*"}
    assert storage.target[1] == {"content_type": "video/mp4", "content_length": 16, "expires_seconds": 900}
    assert row.chat_source_name == row.pending_name
    assert row.chat_source_bytes == 16 and row.expected_bytes == chat_media.VIDEO_MAX_BYTES
    assert row.external_id is None and row.chat_import_state == "staged"
    assert row.total_bytes == chat_media.VIDEO_MAX_BYTES + 16
    assert bunny.fetches == bunny.resolves == []
    assert "Bunny" not in str(target) and "AuthorizationSignature" not in str(target)


@pytest.mark.parametrize("disabled", ["staging", "r2", "decoder"])
def test_private_video_requires_every_staging_safety_gate(fixture, monkeypatch, disabled):
    if disabled == "staging":
        monkeypatch.delenv("CHAT_VIDEO_STAGING_VERIFIED")
    elif disabled == "r2":
        monkeypatch.setenv("CHAT_R2_PRIVATE_VERIFIED", "false")
    else:
        monkeypatch.setattr(chat_media.video_validation, "is_available", lambda: False)
    assert not chat_media.capabilities()["videos_enabled"]
    with pytest.raises(HTTPException) as error:
        upload(fixture, "video")
    assert error.value.status_code == 503 and fixture[1]._memory == {}


def test_rejected_source_never_creates_or_imports_paid_video_and_waits_for_write_expiry(fixture, monkeypatch):
    user, ledger, storage, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    def invalid(*args):
        raise ValueError("Videos must be no longer than 30 seconds.")
    monkeypatch.setattr(chat_media.video_validation, "validate_staged_video", invalid)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    assert ledger.get(identifier, user.id).status == "rejected"
    assert bunny.fetches == bunny.resolves == bunny.deleted == storage.deleted == []
    ledger._memory[identifier] = replace(ledger.get(identifier, user.id),
        expires_at=datetime.now(timezone.utc) - timedelta(seconds=1))
    chat_media._delete(ledger.get(identifier, user.id))
    assert storage.deleted and ledger.get(identifier, user.id).chat_source_deleted_at is not None


@pytest.mark.parametrize("exception,code", [
    (chat_media.video_validation.ValidationBusy, None),
    (chat_media.video_validation.VideoValidationUnavailable, 503),
])
def test_busy_or_unavailable_validator_does_not_consume_fetch_intent(fixture, monkeypatch, exception, code):
    user, ledger, _, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    def fail(*args):
        raise exception()
    monkeypatch.setattr(chat_media.video_validation, "validate_staged_video", fail)
    if code:
        with pytest.raises(HTTPException) as error:
            chat_media.complete(user, identifier)
        assert error.value.status_code == code
    else:
        assert chat_media.complete(user, identifier)["status"] == "processing"
    assert ledger.get(identifier, user.id).chat_import_state == "staged"
    assert bunny.fetches == bunny.resolves == []


def test_fetch_cas_is_durable_before_http_and_timeout_retries_are_read_only(fixture):
    user, ledger, storage, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    bunny.resolved_id = None
    def timeout(url, title, *, etag):
        row = ledger.get(identifier, user.id)
        assert row.chat_import_state == "fetch_started" and row.chat_source_etag == etag
        assert row.chat_source_duration_seconds == 18 and row.chat_source_read_expires_at
        bunny.fetches.append((url, title, etag))
        raise httpx.ReadTimeout("fake timeout")
    bunny.fetch_validated_source = timeout
    for _ in range(3):
        assert chat_media.complete(user, identifier)["status"] == "processing"
    assert len(bunny.fetches) == 1 and len(bunny.resolves) == 3
    assert storage.read_target == (ledger.get(identifier, user.id).chat_source_name,
        {"expires_seconds": 600, "etag": '"' + "a" * 32 + '"'})
    assert ledger.get(identifier, user.id).chat_import_state == "fetch_started"
    bunny.resolved_id = "video-guid"
    assert chat_media.complete(user, identifier)["status"] == "ready"
    assert len(bunny.fetches) == 1
    assert ledger.get(identifier, user.id).chat_import_state == "imported"


def test_two_workers_validate_but_only_one_submits_fetch(fixture, monkeypatch):
    from threading import Barrier
    user, ledger, _, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    gate = Barrier(2)
    def validate(*args):
        gate.wait(timeout=5)
        return ValidatedVideo('"' + "a" * 32 + '"', 18, 320, 180, 540)
    monkeypatch.setattr(chat_media.video_validation, "validate_staged_video", validate)
    bunny.resolved_id = None
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: chat_media.complete(user, identifier), range(2)))
    assert all(result["status"] == "processing" for result in results)
    assert len(bunny.fetches) == 1 and ledger.get(identifier, user.id).chat_import_state == "fetch_submitted"


def test_cancel_during_validation_prevents_fetch_and_cannot_be_reimported(fixture, monkeypatch):
    user, ledger, _, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    def validate(*args):
        chat_media.cancel(user, identifier)
        return ValidatedVideo('"' + "a" * 32 + '"', 18, 320, 180, 540)
    monkeypatch.setattr(chat_media.video_validation, "validate_staged_video", validate)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 409
    assert ledger.get(identifier, user.id).status == "canceled" and bunny.fetches == []


def test_stale_validation_failure_cannot_reject_or_delete_another_workers_sent_video(fixture, monkeypatch):
    user, ledger, storage, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    def stale_failure(*args):
        ledger._memory[identifier] = replace(ledger.get(identifier, user.id),
            status="used", message_id="sent-message", external_id="video-guid",
            chat_import_state="imported", chat_video_resolutions="480p", chat_video_mp4_resolution="480p")
        raise ValueError("Stale validation failure")
    monkeypatch.setattr(chat_media.video_validation, "validate_staged_video", stale_failure)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 409
    assert ledger.get(identifier, user.id).status == "used"
    assert storage.deleted == bunny.deleted == bunny.fetches == []


def test_crash_after_fetch_intent_never_authorizes_another_post(fixture, monkeypatch):
    user, ledger, _, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    bunny.resolved_id = None
    original = ledger.begin_chat_video_fetch
    class SimulatedWorkerExit(BaseException):
        pass
    def crash(*args, **kwargs):
        assert original(*args, **kwargs)
        raise SimulatedWorkerExit()
    monkeypatch.setattr(ledger, "begin_chat_video_fetch", crash)
    with pytest.raises(SimulatedWorkerExit):
        chat_media.complete(user, identifier)
    assert ledger.get(identifier, user.id).chat_import_state == "fetch_started"
    assert chat_media.complete(user, identifier)["status"] == "processing"
    assert bunny.fetches == [] and len(bunny.resolves) == 1


def test_response_persistence_failure_recovers_guid_without_resubmission(fixture, monkeypatch):
    user, ledger, _, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    def failure(*args, **kwargs):
        raise RuntimeError("fake durable write failure")
    monkeypatch.setattr(ledger, "record_chat_video_fetch_outcome", failure)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 503
    assert ledger.get(identifier, user.id).chat_import_state == "fetch_started"
    assert chat_media.complete(user, identifier)["status"] == "ready"
    assert len(bunny.fetches) == 1


def test_expired_source_is_never_validated_or_submitted(fixture, monkeypatch):
    user, ledger, _, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    ledger._memory[identifier] = replace(ledger.get(identifier, user.id),
        expires_at=datetime.now(timezone.utc) - timedelta(seconds=1))
    monkeypatch.setattr(chat_media.video_validation, "validate_staged_video", lambda *args:
        pytest.fail("An expired upload must not consume validation resources"))
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 410 and bunny.fetches == bunny.resolves == []


def test_explicit_fetch_rejection_never_retries_and_keeps_staging_quota_until_safe_cleanup(fixture):
    user, ledger, storage, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    def rejected(url, title, *, etag):
        bunny.fetches.append((url, title, etag))
        raise BunnyFetchRejected("fake rejection")
    bunny.fetch_validated_source = rejected
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    row = ledger.get(identifier, user.id)
    assert row.chat_import_state == "fetch_rejected" and row.status == "rejected"
    assert len(bunny.fetches) == 1 and bunny.resolves == [] and storage.deleted == []
    with pytest.raises(HTTPException):
        chat_media.complete(user, identifier)
    assert len(bunny.fetches) == 1


def test_unknown_canceled_import_reconciles_before_cleanup_without_resubmitting(fixture):
    user, ledger, storage, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    bunny.resolved_id = None
    assert chat_media.complete(user, identifier)["status"] == "processing"
    chat_media.cancel(user, identifier)
    row = ledger.get(identifier, user.id)
    with pytest.raises(RuntimeError, match="reconciliation"):
        chat_media._delete(row)
    assert storage.deleted == bunny.deleted == []
    assert row.total_bytes == chat_media.VIDEO_MAX_BYTES + 16
    past = datetime.now(timezone.utc) - timedelta(seconds=1)
    ledger._memory[identifier] = replace(row, expires_at=past, chat_source_read_expires_at=past)
    bunny.resolved_id = "video-guid"
    chat_media._delete(row)  # Deliberately pass the old snapshot: reread is required.
    current = ledger.get(identifier, user.id)
    assert current.external_id == "video-guid" and current.chat_import_state == "imported"
    assert bunny.deleted == ["video-guid"] and current.chat_source_deleted_at
    assert len(bunny.fetches) == 1


def test_video_can_finish_processing_after_put_expires_without_renewing_any_grant(fixture):
    user, ledger, _, bunny = fixture
    identifier = upload(fixture, "video")["id"]
    bunny.resolved_id = None
    assert chat_media.complete(user, identifier)["status"] == "processing"
    row = ledger.get(identifier, user.id)
    ledger._memory[identifier] = replace(row, expires_at=datetime.now(timezone.utc) - timedelta(seconds=1))
    bunny.resolved_id = "video-guid"
    assert chat_media.complete(user, identifier)["status"] == "ready"
    assert len(bunny.fetches) == 1


def test_private_client_cannot_create_an_unbounded_tus_grant(fixture):
    with pytest.raises(RuntimeError, match="staging"):
        PrivateChatBunnyClient().create_upload("ignored", expires_seconds=300)


def test_server_fetch_only_sends_validated_signed_source_and_etag(fixture, monkeypatch):
    calls = []
    def post(url, **kwargs):
        calls.append((url, kwargs))
        return httpx.Response(200, json={"success": True, "statusCode": 200}, request=httpx.Request("POST", url))
    monkeypatch.setattr("app.core.bunny_stream.httpx.post", post)
    client = PrivateChatBunnyClient()
    title = "TYDES private chat_media_" + "a" * 32
    client.fetch_validated_source("https://private-r2.example.invalid/chat/source?signature=temporary", title,
                                 etag='"' + "b" * 32 + '"')
    assert len(calls) == 1 and calls[0][0].endswith("/videos/fetch")
    assert calls[0][1]["json"] == {"url": "https://private-r2.example.invalid/chat/source?signature=temporary",
        "headers": {"If-Match": '"' + "b" * 32 + '"'}, "title": title}
    assert calls[0][1]["follow_redirects"] is False
    assert set(calls[0][1]["json"]) == {"url", "headers", "title"}


@pytest.mark.parametrize("http_code,payload,explicit", [
    (400, {"success": False, "statusCode": 400}, True),
    (429, {"success": False, "statusCode": 429}, True),
    (500, {"success": False, "statusCode": 500}, False),
    (408, {"success": False, "statusCode": 408}, False),
    (400, {"success": False, "statusCode": 200}, False),
    (400, {"success": True, "statusCode": 400}, False),
    (200, {"success": True}, False),
])
def test_only_explicit_matching_rejection_is_safe_to_record(fixture, monkeypatch, http_code, payload, explicit):
    monkeypatch.setattr("app.core.bunny_stream.httpx.post", lambda url, **kwargs: httpx.Response(
        http_code, json=payload, request=httpx.Request("POST", url)))
    with pytest.raises(RuntimeError) as error:
        PrivateChatBunnyClient().fetch_validated_source("https://private.invalid/source?signature=test",
            "TYDES private chat_media_" + "a" * 32, etag='"' + "b" * 32 + '"')
    assert isinstance(error.value, BunnyFetchRejected) is explicit


@pytest.mark.parametrize("mutation", ["none", "duplicate", "wrong_title", "wrong_library", "wrong_id", "bad_total", "truncated"])
def test_import_reconciliation_requires_exact_unique_provider_identity(fixture, monkeypatch, mutation):
    monkeypatch.setenv("CHAT_BUNNY_STREAM_LIBRARY_ID", "809201")
    title = "TYDES private chat_media_" + "a" * 32
    identifier = "12345678-1234-1234-1234-123456789abc"
    item = {"guid": identifier, "title": title, "videoLibraryId": 809201}
    payload = {"totalItems": 1, "items": [item]}
    if mutation == "none":
        payload = {"totalItems": 0, "items": []}
    elif mutation == "duplicate":
        payload = {"totalItems": 2, "items": [item, item]}
    elif mutation == "wrong_title":
        item["title"] = title + " copy"
    elif mutation == "wrong_library":
        item["videoLibraryId"] = 42
    elif mutation == "wrong_id":
        item["guid"] = "../../another-video"
    elif mutation == "bad_total":
        payload["totalItems"] = True
    elif mutation == "truncated":
        payload["totalItems"] = 11
    def get(url, **kwargs):
        assert kwargs["params"] == {"search": title, "page": 1, "itemsPerPage": 10}
        assert kwargs["follow_redirects"] is False
        return httpx.Response(200, json=payload, request=httpx.Request("GET", url))
    monkeypatch.setattr("app.core.bunny_stream.httpx.get", get)
    client = PrivateChatBunnyClient()
    if mutation == "none":
        assert client.resolve_imported_video(title) is None
    else:
        with pytest.raises(RuntimeError):
            client.resolve_imported_video(title)


def test_exact_unique_import_is_bound_without_any_new_create_or_fetch(fixture, monkeypatch):
    monkeypatch.setenv("CHAT_BUNNY_STREAM_LIBRARY_ID", "809201")
    title = "TYDES private chat_media_" + "a" * 32
    identifier = "12345678-1234-1234-1234-123456789abc"
    monkeypatch.setattr("app.core.bunny_stream.httpx.get", lambda url, **kwargs: httpx.Response(
        200, json={"totalItems": 1, "items": [{"guid": identifier, "title": title, "videoLibraryId": 809201}]},
        request=httpx.Request("GET", url)))
    assert PrivateChatBunnyClient().resolve_imported_video(title) == identifier
