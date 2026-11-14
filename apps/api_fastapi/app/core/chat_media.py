"""Private chat media. Upload/read bytes never pass through Render."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import math
import os
from uuid import uuid4

from fastapi import HTTPException

from app.core.bunny_stream import PrivateChatBunnyClient
from app.core.media_storage import PrivateChatR2Storage
from app.core.media_uploads import UploadLimits, UploadQuotaExceeded, UploadReservation, upload_ledger
from app.core.models import User

PHOTO_MAX_BYTES = 8 * 1024 * 1024
VIDEO_MAX_BYTES = 50 * 1024 * 1024
VIDEO_MAX_SECONDS = 30.5
PHOTO_MAX_EDGE = 8192
PHOTO_MAX_PIXELS = 32_000_000
_PHOTO_TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
_VIDEO_TYPES = {"video/mp4", "video/quicktime", "video/x-m4v"}


def _true(name: str) -> bool:
    return os.getenv(name, "").strip().lower() == "true"


def capabilities() -> dict:
    enabled = _true("CHAT_MEDIA_ENABLED")
    photo = enabled and _true("CHAT_R2_PRIVATE_VERIFIED") and all(
        os.getenv(name, "").strip() for name in (
            "CHAT_R2_PRIVATE_BUCKET", "CHAT_R2_ACCESS_KEY_ID", "CHAT_R2_SECRET_ACCESS_KEY"))
    photo = bool(photo and os.getenv("CHAT_R2_PRIVATE_BUCKET") != os.getenv("CLOUDFLARE_R2_BUCKET"))
    video = enabled and _true("CHAT_BUNNY_STREAM_PRIVATE_VERIFIED") and all(
        os.getenv(name, "").strip() for name in (
            "CHAT_BUNNY_STREAM_LIBRARY_ID", "CHAT_BUNNY_STREAM_API_KEY",
            "CHAT_BUNNY_STREAM_CDN_HOSTNAME", "CHAT_BUNNY_STREAM_TOKEN_KEY"))
    video = bool(video and os.getenv("CHAT_BUNNY_STREAM_LIBRARY_ID") != os.getenv("BUNNY_STREAM_LIBRARY_ID"))
    video = bool(video and os.getenv("CHAT_BUNNY_STREAM_CDN_HOSTNAME") != os.getenv("BUNNY_STREAM_CDN_HOSTNAME"))
    return {"enabled": photo or video, "photos_enabled": photo, "videos_enabled": video,
            "photo_max_bytes": PHOTO_MAX_BYTES, "video_max_bytes": VIDEO_MAX_BYTES,
            "photo_max_edge": PHOTO_MAX_EDGE, "photo_max_pixels": PHOTO_MAX_PIXELS,
            "video_max_seconds": VIDEO_MAX_SECONDS, "media_per_message": 1,
            "reason": None if photo and video else "Some private attachments are not available yet."}


def _require_provider(media_type: str) -> None:
    key = "photos_enabled" if media_type == "photo" else "videos_enabled"
    if not capabilities()[key]:
        raise HTTPException(503, "Private attachments are not available for this media type yet.")


def authorize_context(user: User, scope_type: str, scope_id: str, *, sender_user_id: str | None = None) -> None:
    if not user.email_verified or user.banned:
        raise HTTPException(403, "Verify your email before using private attachments.")
    if scope_type == "direct":
        from app.core.direct_messages import get_direct_message_service
        get_direct_message_service().authorize_media(user, scope_id)
    elif scope_type == "event":
        from app.core.store import store
        with store.request_user_context(user):
            if not store.can_access_event_chat(scope_id, sender_user_id=sender_user_id):
                raise HTTPException(404, "Conversation not found.")
    else:
        raise HTTPException(404, "Conversation not found.")


def _reservation(identifier: str, user_id: str | None = None) -> UploadReservation:
    # Reads by a recipient are scoped after lookup, never by user-controlled URL.
    row = upload_ledger.get(identifier, user_id) if user_id is not None else upload_ledger.get_chat(identifier)
    if row is None or row.purpose != "chat":
        raise HTTPException(404, "Attachment not found.")
    return row


def reserve(user: User, scope_type: str, scope_id: str, media_type: str,
            content_type: str, size_bytes: int, client_ip: str) -> dict:
    authorize_context(user, scope_type, scope_id)
    _require_provider(media_type)
    allowed = _PHOTO_TYPES if media_type == "photo" else _VIDEO_TYPES
    if content_type not in allowed or size_bytes <= 0:
        raise HTTPException(400, "Unsupported attachment format.")
    maximum = PHOTO_MAX_BYTES if media_type == "photo" else VIDEO_MAX_BYTES
    if size_bytes > maximum:
        raise HTTPException(413, "Attachment is too large.")
    now = datetime.now(timezone.utc)
    ttl = 300 if media_type == "photo" else 30 * 60
    identifier = "chat_media_" + uuid4().hex
    owner = hashlib.sha256(user.id.encode()).hexdigest()[:16]
    name = f"objects/{owner}/{identifier}{_PHOTO_TYPES.get(content_type, '')}"
    row = UploadReservation(
        id=identifier, user_id=user.id,
        client_ip_hash=hashlib.sha256(client_ip.encode()).hexdigest(), media_type=media_type,
        content_type=content_type, thumbnail_content_type=None,
        # TUS is not byte-bound. Reserve the full admitted storage ceiling and
        # reject/delete any video whose actual encoded storage exceeds it.
        expected_bytes=size_bytes if media_type == "photo" else VIDEO_MAX_BYTES,
        expected_thumbnail_bytes=0, pending_name=name, final_name=name,
        pending_thumbnail_name=None, final_thumbnail_name=None,
        public_url="", thumbnail_public_url="", status="pending", created_at=now,
        expires_at=now + timedelta(seconds=ttl),
        storage_provider="chat_r2" if media_type == "photo" else "chat_bunny",
        purpose="chat", scope_type=scope_type, scope_id=scope_id,
    )
    try:
        upload_ledger.reserve(row, UploadLimits.from_env(premium=user.premium))
    except UploadQuotaExceeded as error:
        raise HTTPException(429, str(error)) from error
    target = None
    try:
        if media_type == "photo":
            storage = PrivateChatR2Storage()
            url = storage.create_direct_upload_url(name, content_type=content_type,
                content_length=size_bytes, expires_seconds=ttl)
            upload = {"url": url, "headers": {"Content-Type": content_type, "If-None-Match": "*"}, "protocol": "put"}
        else:
            bunny = PrivateChatBunnyClient()
            target = bunny.create_upload("TYDES private message", expires_seconds=ttl)
            row = upload_ledger.set_chat_video_target(row.id, user.id, target.video_id, target.expires_at)
            upload = {"url": target.url, "headers": target.headers, "protocol": "tus"}
    except Exception as error:
        if target is not None:
            try:
                bunny.delete_video(target.video_id)
            except Exception:
                pass
        upload_ledger.set_status(row.id, user.id, "failed")
        raise HTTPException(503, "Private upload is temporarily unavailable.") from error
    return {"id": row.id, "media_type": media_type, "upload": upload,
            "expires_at": row.expires_at.isoformat()}


def _delete(row: UploadReservation) -> None:
    if row.storage_provider == "chat_r2":
        storage = PrivateChatR2Storage()
        for name in {row.pending_name, row.final_name, row.pending_thumbnail_name, row.final_thumbnail_name} - {None}:
            storage.delete_object(name)
    elif row.storage_provider == "chat_bunny":
        PrivateChatBunnyClient().delete_video(row.external_id)
    else:
        raise RuntimeError("Invalid private storage provider")


def complete(user: User, identifier: str) -> dict:
    row = _reservation(identifier, user.id)
    authorize_context(user, row.scope_type, row.scope_id)
    _require_provider(row.media_type)
    result = {"id": row.id, "media_type": row.media_type, "status": "ready"}
    if row.status in {"complete", "used"}:
        return result
    if row.status != "pending":
        raise HTTPException(409, "This attachment upload is no longer active.")
    if row.expires_at < datetime.now(timezone.utc):
        raise HTTPException(410, "Upload link expired. Choose the attachment again.")
    try:
        if row.storage_provider == "chat_r2":
            storage = PrivateChatR2Storage()
            metadata = storage.object_metadata(row.final_name)
            if metadata.size != row.expected_bytes or metadata.content_type.split(";")[0].lower() != row.content_type:
                raise ValueError("Uploaded photo does not match its reservation.")
            header = storage.read_object_range(row.final_name, 0, min(65_535, metadata.size - 1))
            width, height = _image_dimensions(header, row.content_type)
            if max(width, height) > PHOTO_MAX_EDGE or width * height > PHOTO_MAX_PIXELS:
                raise ValueError("Photo dimensions are too large. Resize to at most 8192 pixels per side and 32 megapixels.")
        else:
            video = PrivateChatBunnyClient().get_video(row.external_id)
            if video.failed:
                raise ValueError("Video processing failed.")
            if video.storage_size is not None and video.storage_size > VIDEO_MAX_BYTES:
                raise ValueError("Processed video exceeds the private attachment storage limit.")
            if video.length_seconds is not None and (not math.isfinite(video.length_seconds)
                    or video.length_seconds > VIDEO_MAX_SECONDS):
                raise ValueError("Videos must be no longer than 30 seconds.")
            if not video.fully_encoded:
                return {**result, "status": "processing"}
            if (video.length_seconds is None or not math.isfinite(video.length_seconds)
                    or not 0 < video.length_seconds <= VIDEO_MAX_SECONDS):
                raise ValueError("Videos must be no longer than 30 seconds.")
            if video.storage_size is None or video.storage_size <= 0:
                raise RuntimeError("Actual video storage metadata is not available yet")
    except ValueError as error:
        _delete(row)
        upload_ledger.set_status(row.id, user.id, "rejected")
        raise HTTPException(400, str(error)) from error
    except Exception as error:
        raise HTTPException(503, "Attachment verification is temporarily unavailable.") from error
    try:
        upload_ledger.complete_chat_media(row.id, user.id)
    except ValueError as error:
        current = _reservation(row.id, user.id)
        if current.status in {"complete", "used"}:
            return result
        raise HTTPException(409, str(error)) from error
    return result


def cancel(user: User, identifier: str) -> dict:
    row = _reservation(identifier, user.id)
    if row.message_id is not None or row.status == "used":
        raise HTTPException(409, "Sent attachments cannot be canceled as uploads.")
    if row.status not in {"deleted", "expired", "abandoned"}:
        try:
            upload_ledger.cancel_chat_media(row.id, user.id)
        except ValueError as error:
            raise HTTPException(409, str(error)) from error
        try:
            _delete(row)
        except Exception:
            # Cleanup retries after the still-valid signed write link expires.
            pass
    return {"canceled": True}


def access(user: User, identifier: str, scope_type: str, scope_id: str) -> dict:
    authorize_context(user, scope_type, scope_id)
    row = _reservation(identifier)
    if (row.scope_type != scope_type or row.scope_id != scope_id
            or row.status != "used" or row.message_id is None):
        raise HTTPException(404, "Attachment not found in this conversation.")
    authorize_context(user, scope_type, scope_id, sender_user_id=row.user_id)
    if not _message_exists(user, row):
        raise HTTPException(404, "Attachment message is no longer available.")
    _require_provider(row.media_type)
    try:
        ttl = min(600, max(300, int(os.getenv("CHAT_MEDIA_READ_TTL_SECONDS", "300"))))
    except ValueError:
        ttl = 300
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl)
    try:
        if row.storage_provider == "chat_r2":
            url = PrivateChatR2Storage().signed_read_url(row.final_name, expires_seconds=ttl)
            return {"id": row.id, "media_type": row.media_type, "url": url,
                    "thumbnail_url": url, "expires_at": expires_at.isoformat()}
        bunny = PrivateChatBunnyClient()
        def signed(filename):
            return bunny.signed_url(row.external_id, filename, expires=int(expires_at.timestamp()))
        return {"id": row.id, "media_type": row.media_type, "url": signed("playlist.m3u8"),
                "thumbnail_url": signed("thumbnail.jpg"), "fallback_url": signed("play_720p.mp4"),
                "expires_at": expires_at.isoformat()}
    except Exception as error:
        raise HTTPException(503, "Private attachment access is temporarily unavailable.") from error


def _message_exists(user: User, row: UploadReservation) -> bool:
    if row.scope_type == "direct":
        from app.core.direct_messages import get_direct_message_service
        return get_direct_message_service().attachment_message_exists(user, row.scope_id, row.message_id, row.id)
    from app.core.store import store
    with store.request_user_context(user):
        return store.event_attachment_message_exists(row.scope_id, row.message_id, row.id)


def _image_dimensions(data: bytes, content_type: str) -> tuple[int, int]:
    """Parse at most 64 KiB of headers, never decode untrusted pixel buffers."""
    dimensions = None
    if content_type == "image/png" and len(data) >= 33 and data[:8] == b"\x89PNG\r\n\x1a\n" and data[8:16] == b"\x00\x00\x00\rIHDR":
        dimensions = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    elif content_type == "image/jpeg" and data.startswith(b"\xff\xd8"):
        offset = 2
        while offset < len(data):
            if data[offset] != 0xFF:
                break
            while offset < len(data) and data[offset] == 0xFF:
                offset += 1
            if offset >= len(data):
                break
            marker = data[offset]
            offset += 1
            if marker in {0xD9, 0xDA} or offset + 2 > len(data):
                break
            if marker == 0x01 or 0xD0 <= marker <= 0xD8:
                continue
            length = int.from_bytes(data[offset:offset + 2], "big")
            if length < 2 or offset + length > len(data):
                break
            if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
                if length < 11:
                    break
                dimensions = (int.from_bytes(data[offset + 5:offset + 7], "big"),
                              int.from_bytes(data[offset + 3:offset + 5], "big"))
                break
            offset += length
    elif content_type == "image/webp" and data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        offset, canvas = 12, None
        while offset + 8 <= len(data):
            tag = data[offset:offset + 4]
            length = int.from_bytes(data[offset + 4:offset + 8], "little")
            start = offset + 8
            if tag == b"VP8X" and length >= 10 and start + 10 <= len(data):
                if data[start] & 0x02:
                    raise ValueError("Animated photos are not supported. Send a short video instead.")
                canvas = (1 + int.from_bytes(data[start + 4:start + 7], "little"),
                          1 + int.from_bytes(data[start + 7:start + 10], "little"))
            elif tag == b"VP8 " and length >= 10 and start + 10 <= len(data) and data[start + 3:start + 6] == b"\x9d\x01\x2a":
                dimensions = (int.from_bytes(data[start + 6:start + 8], "little") & 0x3FFF,
                              int.from_bytes(data[start + 8:start + 10], "little") & 0x3FFF)
                break
            elif tag == b"VP8L" and length >= 5 and start + 5 <= len(data) and data[start] == 0x2F:
                packed = int.from_bytes(data[start + 1:start + 5], "little")
                dimensions = 1 + (packed & 0x3FFF), 1 + ((packed >> 14) & 0x3FFF)
                break
            offset = start + length + length % 2
        if dimensions is not None and canvas is not None and dimensions != canvas:
            dimensions = None
    if dimensions is None or min(dimensions) <= 0:
        raise ValueError("Could not verify photo dimensions. Export as a standard JPEG, PNG, or WebP and retry.")
    return dimensions
