"""Private media protocol, using only fake credentials and fake providers."""
import base64
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
from pathlib import Path
import sys
from urllib.parse import urljoin

import pytest
from fastapi import HTTPException
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.core import chat_media, media_cleanup
from app.core.bunny_stream import BunnyUploadTarget, BunnyVideo, PrivateChatBunnyClient
from app.core.media_storage import PrivateChatR2Storage, StoredObjectMetadata
from app.core.media_uploads import MediaUploadLedger, UploadLimits, UploadQuotaExceeded
from app.core.models import build_seed
from app.core.auth import require_authenticated_user
from app.core.rate_limit import api_rate_limiter
from app.modules.messages.media_router import router as media_router


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
        return "https://private-r2.example.invalid/object?signature=temporary"
    def delete_object(self, name):
        self.deleted.append(name)


class VideoStorage:
    deleted = []
    video = BunnyVideo("video-guid", 3, 18, 100_000)
    def create_upload(self, title, *, expires_seconds):
        return BunnyUploadTarget("video-guid", "https://video.bunnycdn.com/tusupload",
            {"VideoId": "video-guid", "AuthorizationSignature": "temporary"},
            datetime.now(timezone.utc) + timedelta(seconds=expires_seconds))
    def get_video(self, identifier):
        return self.video
    def delete_video(self, identifier):
        self.deleted.append(identifier)
    def signed_url(self, identifier, filename, **kwargs):
        return f"https://private-video.example.invalid/signed/{identifier}/{filename}"


@pytest.fixture
def fixture(monkeypatch):
    values = {
        "CHAT_MEDIA_ENABLED": "true", "CHAT_R2_PRIVATE_VERIFIED": "true",
        "CHAT_R2_PRIVATE_BUCKET": "private-chat-fixture", "CHAT_R2_ACCESS_KEY_ID": "fake",
        "CHAT_R2_SECRET_ACCESS_KEY": "fake-secret", "CHAT_BUNNY_STREAM_PRIVATE_VERIFIED": "true",
        "CHAT_BUNNY_STREAM_LIBRARY_ID": "private-library", "CHAT_BUNNY_STREAM_API_KEY": "fake-video",
        "CHAT_BUNNY_STREAM_CDN_HOSTNAME": "private.example.invalid",
        "CHAT_BUNNY_STREAM_TOKEN_KEY": "fake-token-key",
    }
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    ledger = MediaUploadLedger()
    photo, video = PhotoStorage(), VideoStorage()
    photo.deleted, video.deleted = [], []
    monkeypatch.setattr(chat_media, "upload_ledger", ledger)
    monkeypatch.setattr(chat_media, "PrivateChatR2Storage", lambda: photo)
    monkeypatch.setattr(chat_media, "PrivateChatBunnyClient", lambda: video)
    monkeypatch.setattr(chat_media, "authorize_context", lambda *args, **kwargs: None)
    monkeypatch.setattr(chat_media, "_message_exists", lambda *args: True)
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
    assert ledger.get(identifier, user.id).total_bytes == chat_media.VIDEO_MAX_BYTES
    video.video = BunnyVideo("video-guid", 2, None, 100)
    assert chat_media.complete(user, identifier)["status"] == "processing"
    video.video = BunnyVideo("video-guid", 3, 18, chat_media.VIDEO_MAX_BYTES + 1)
    with pytest.raises(HTTPException) as error:
        chat_media.complete(user, identifier)
    assert error.value.status_code == 400
    assert video.deleted == ["video-guid"]
    assert ledger.get(identifier, user.id).status == "rejected"


@pytest.mark.parametrize("duration,size", [(31, 100), (float("nan"), 100), (18, None)])
def test_unverifiable_video_never_becomes_ready(fixture, duration, size):
    user, ledger, _, video = fixture
    identifier = upload(fixture, "video")["id"]
    video.video = BunnyVideo("video-guid", 3, duration, size)
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
    video.video = BunnyVideo("video-guid", 4, 18, 100, 100)
    assert chat_media.complete(user, identifier)["status"] == "ready"


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


def test_bunny_tokens_are_hmac_directory_tokens_for_every_rendition(fixture):
    client = PrivateChatBunnyClient()
    expires = 1800000000
    url = client.signed_url("video-guid", "playlist.m3u8", expires=expires)
    message = f"/video-guid/{expires}token_path=/video-guid/".encode()
    expected = base64.urlsafe_b64encode(hmac.new(b"fake-token-key", message, hashlib.sha256).digest()).decode().rstrip("=")
    assert f"bcdn_token=HS256-{expected}" in url
    assert "token_path=%2Fvideo-guid%2F" in url
    child = urljoin(url, "720p/video.m3u8")
    segment = urljoin(child, "segment0.ts")
    assert "/bcdn_token=" in segment and segment.endswith("/video-guid/720p/segment0.ts")
    assert "fake-token-key" not in url
    for filename in ["thumbnail.jpg", "play_720p.mp4"]:
        assert "/bcdn_token=" in client.signed_url("video-guid", filename, expires=expires)


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


def test_private_video_upload_link_expires_after_thirty_minutes(fixture):
    user, ledger, _, _ = fixture
    target = upload(fixture, "video")
    row = ledger.get(target["id"], user.id)
    assert timedelta(minutes=29) < row.expires_at - row.created_at < timedelta(minutes=31)


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
