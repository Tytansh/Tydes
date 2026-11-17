"""Private chat media. Clients upload to private R2, never to a paid video API.

Validated video bytes reach Bunny directly from R2. Render only receives a
bounded validation download; it never relays those bytes to Bunny.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import math
import os
from uuid import uuid4

from fastapi import HTTPException

from app.core.bunny_stream import BunnyFetchRejected, PrivateChatBunnyClient
from app.core.media_storage import PrivateChatR2Storage
from app.core.media_uploads import (UploadLimits, UploadQuotaExceeded, UploadReservation,
                                   chat_import_deadline, chat_source_can_delete,
                                   upload_ledger, verified_chat_video_playback)
from app.core.models import User
from app.core import video_validation

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
    # Video ingestion intents and quotas must survive worker/process restarts.
    # Check the constructed ledger, not an environment variable that may have
    # changed after the service initialized its in-memory development fallback.
    video = bool(upload_ledger.database_url) and photo and _true("CHAT_VIDEO_STAGING_VERIFIED") and video_validation.is_available() and _true("CHAT_BUNNY_STREAM_PRIVATE_VERIFIED") and all(
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
    ttl = 300 if media_type == "photo" else 900
    identifier = "chat_media_" + uuid4().hex
    owner = hashlib.sha256(user.id.encode()).hexdigest()[:16]
    name = f"objects/{owner}/{identifier}{_PHOTO_TYPES.get(content_type, '')}"
    row = UploadReservation(
        id=identifier, user_id=user.id,
        client_ip_hash=hashlib.sha256(client_ip.encode()).hexdigest(), media_type=media_type,
        content_type=content_type, thumbnail_content_type=None,
        # Staging and encoded bytes are both charged by the shared ledger.
        expected_bytes=size_bytes if media_type == "photo" else VIDEO_MAX_BYTES,
        expected_thumbnail_bytes=0, pending_name=name, final_name=name,
        pending_thumbnail_name=None, final_thumbnail_name=None,
        public_url="", thumbnail_public_url="", status="pending", created_at=now,
        expires_at=now + timedelta(seconds=ttl),
        storage_provider="chat_r2" if media_type == "photo" else "chat_bunny",
        purpose="chat", scope_type=scope_type, scope_id=scope_id,
        chat_source_name=name if media_type == "video" else None,
        chat_source_bytes=size_bytes if media_type == "video" else 0,
        chat_import_state="staged" if media_type == "video" else None,
    )
    try:
        upload_ledger.reserve(row, UploadLimits.from_env(premium=user.premium))
    except UploadQuotaExceeded as error:
        raise HTTPException(429, str(error)) from error
    try:
        storage = PrivateChatR2Storage()
        url = storage.create_direct_upload_url(name, content_type=content_type,
            content_length=size_bytes, expires_seconds=ttl)
        upload = {"url": url, "headers": {"Content-Type": content_type, "If-None-Match": "*"}, "protocol": "put"}
    except Exception as error:
        upload_ledger.set_status(row.id, user.id, "failed")
        raise HTTPException(503, "Private upload is temporarily unavailable.") from error
    return {"id": row.id, "media_type": media_type, "upload": upload,
            "expires_at": row.expires_at.isoformat()}


def _delete(row: UploadReservation) -> None:
    # Cleanup/cancel snapshots can race a send, cancellation, or import bind.
    row = _reservation(row.id)
    if row.status in {"complete", "used"}:
        raise RuntimeError("Active private media must be queued before deletion")
    if row.storage_provider == "chat_r2":
        storage = PrivateChatR2Storage()
        for name in {row.pending_name, row.final_name, row.pending_thumbnail_name, row.final_thumbnail_name} - {None}:
            storage.delete_object(name)
    elif row.storage_provider == "chat_bunny":
        bunny = PrivateChatBunnyClient()
        if row.chat_source_name is not None:
            row = _resolve_import(row, bunny)
            if row.external_id is None and row.chat_import_state in {"fetch_started", "fetch_submitted"}:
                # An ambiguous fetch may still materialize. Retain the encoded
                # reservation and reconcile again; never claim it was deleted.
                raise RuntimeError("Private video import still needs reconciliation")
            if row.external_id is not None:
                bunny.delete_video(row.external_id)
            if row.chat_source_deleted_at is None:
                if not chat_source_can_delete(row):
                    raise RuntimeError("Private video source authorization is still active")
                PrivateChatR2Storage().delete_object(row.chat_source_name)
                upload_ledger.mark_chat_source_deleted(row.id, row.user_id)
        else:
            bunny.delete_video(row.external_id)
    else:
        raise RuntimeError("Invalid private storage provider")


def _import_title(row: UploadReservation) -> str:
    return "TYDES private " + row.id


def _resolve_import(row: UploadReservation, bunny: PrivateChatBunnyClient) -> UploadReservation:
    if (row.external_id is None and row.chat_source_name is not None
            and row.chat_import_state in {"fetch_started", "fetch_submitted"}):
        video_id = bunny.resolve_imported_video(_import_title(row))
        if video_id is not None:
            return upload_ledger.bind_chat_video_import(row.id, row.user_id, video_id)
    return row


def _prepare_video_import(row: UploadReservation, user: User,
                          bunny: PrivateChatBunnyClient) -> UploadReservation:
    if row.chat_source_name is None:
        # Existing ready/used rows remain readable, but old unbounded upload
        # grants may not be completed through the new ingestion path.
        raise ValueError("Choose the video again to use the protected upload.")
    if row.chat_import_state == "staged":
        storage = PrivateChatR2Storage()
        validated = video_validation.validate_staged_video(storage, row.chat_source_name,
            row.chat_source_bytes, row.content_type)
        read_ttl = 600
        # Generate before committing intent: signing failure cannot strand a
        # reservation. The URL is server-only and binds the validated ETag.
        source_url = storage.signed_read_url(row.chat_source_name,
            expires_seconds=read_ttl, etag=validated.etag)
        # Record after signing, never an earlier timestamp that could permit
        # cleanup while the generated source URL is still valid.
        read_expires_at = datetime.now(timezone.utc) + timedelta(seconds=read_ttl)
        first = upload_ledger.begin_chat_video_fetch(row.id, user.id,
            etag=validated.etag, duration_seconds=validated.duration_seconds,
            read_expires_at=read_expires_at)
        if first:
            try:
                bunny.fetch_validated_source(source_url, _import_title(row), etag=validated.etag)
            except BunnyFetchRejected:
                upload_ledger.record_chat_video_fetch_outcome(row.id, user.id, accepted=False)
            except Exception:
                # Includes network timeout, malformed response, and a crash's
                # durable equivalent. No caller will ever retry this POST.
                pass
            else:
                upload_ledger.record_chat_video_fetch_outcome(row.id, user.id, accepted=True)
        row = _reservation(row.id, user.id)
    if row.status != "pending":
        raise HTTPException(409, "This attachment upload is no longer active.")
    if row.chat_import_state == "fetch_rejected":
        raise ValueError("Video import was not accepted. Choose the video again.")
    row = _resolve_import(row, bunny)
    if row.status != "pending":
        raise HTTPException(409, "This attachment upload is no longer active.")
    return row


def complete(user: User, identifier: str) -> dict:
    row = _reservation(identifier, user.id)
    authorize_context(user, row.scope_type, row.scope_id)
    _require_provider(row.media_type)
    result = {"id": row.id, "media_type": row.media_type, "status": "ready"}
    if row.status in {"complete", "used"}:
        if row.media_type == "video":
            try:
                verified_chat_video_playback(row)
            except ValueError as error:
                raise HTTPException(409, str(error)) from error
        return result
    if row.status != "pending":
        raise HTTPException(409, "This attachment upload is no longer active.")
    deadline = chat_import_deadline(row) if row.chat_import_state in {"fetch_started", "fetch_submitted", "imported"} else row.expires_at
    if deadline < datetime.now(timezone.utc):
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
            bunny = PrivateChatBunnyClient()
            row = _prepare_video_import(row, user, bunny)
            if row.external_id is None:
                return {**result, "status": "processing"}
            video = bunny.get_video(row.external_id)
            if video.failed:
                raise ValueError("Video processing failed.")
            if video.storage_size is not None and video.storage_size > VIDEO_MAX_BYTES:
                raise ValueError("Processed video exceeds the private attachment storage limit.")
            if video.length_seconds is not None and (not math.isfinite(video.length_seconds)
                    or video.length_seconds > VIDEO_MAX_SECONDS):
                raise ValueError("Videos must be no longer than 30 seconds.")
            if video.available_resolutions and any(
                    value not in {"240p", "360p", "480p", "720p"}
                    for value in video.available_resolutions):
                raise ValueError("Private videos must be encoded at 720p or lower.")
            # Get Video may report status=3 before its final progress update.
            # Private attachments must not be published while encoding can
            # still add rendition/storage bytes. Do not infer completion from
            # caption/title event-like statuses or the shared early-play flag.
            if video.status not in {3, 4} or video.encode_progress != 100:
                return {**result, "status": "processing"}
            if video.length_seconds is not None and video.length_seconds < 0:
                raise ValueError("Videos must be no longer than 30 seconds.")
            # Provider status/progress, storage totals and MP4 generation are
            # separate updates. Finished transcoding alone cannot make an
            # attachment ready or prove that missing metadata is terminal.
            # Keep the same import deadline; never re-submit the Fetch job.
            if (video.length_seconds is None or video.length_seconds == 0
                    or video.storage_size is None or video.storage_size <= 0
                    or not video.available_resolutions
                    or video.has_mp4_fallback is not True):
                return {**result, "status": "processing"}
            mp4_resolution = bunny.verified_mp4_resolution(row.external_id,
                video.available_resolutions, max_bytes=VIDEO_MAX_BYTES)
            if mp4_resolution is None:
                return {**result, "status": "processing"}
    except video_validation.ValidationBusy:
        return {**result, "status": "processing"}
    except video_validation.VideoValidationUnavailable as error:
        raise HTTPException(503, "Video verification is temporarily unavailable.") from error
    except HTTPException:
        raise
    except ValueError as error:
        try:
            upload_ledger.reject_chat_media(row.id, user.id)
        except ValueError:
            raise HTTPException(409, "This attachment upload is no longer active.") from error
        try:
            _delete(row)
        except Exception:
            # Still-valid staging links and unknown imports retain their quota
            # until durable cleanup can safely remove all provider bytes.
            pass
        raise HTTPException(400, str(error)) from error
    except Exception as error:
        raise HTTPException(503, "Attachment verification is temporarily unavailable.") from error
    try:
        if row.media_type == "video":
            upload_ledger.complete_chat_video(row.id, user.id,
                video.available_resolutions, mp4_resolution)
        else:
            upload_ledger.complete_chat_media(row.id, user.id)
    except ValueError as error:
        current = _reservation(row.id, user.id)
        if current.status in {"complete", "used"}:
            if row.media_type == "video":
                try:
                    verified_chat_video_playback(current)
                except ValueError as verification_error:
                    raise HTTPException(409, str(verification_error)) from verification_error
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
    if row.media_type == "video":
        try:
            _, mp4_resolution = verified_chat_video_playback(row)
        except ValueError as error:
            raise HTTPException(409, str(error)) from error
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
        video_url = signed(f"play_{mp4_resolution}.mp4")
        return {"id": row.id, "media_type": row.media_type, "url": video_url,
                "thumbnail_url": signed("thumbnail.jpg"), "fallback_url": video_url,
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
