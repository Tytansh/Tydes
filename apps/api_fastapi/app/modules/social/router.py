from datetime import date, datetime, timedelta, timezone
import hashlib
import os
from pathlib import Path
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, UploadFile
from pydantic import BaseModel, Field, field_validator

from app.core.auth import optional_authenticated_user, require_authenticated_user
from app.core.bunny_stream import BunnyStreamClient, bunny_stream_enabled
from app.core.email_sender import send_moderation_report_email
from app.core.media_cleanup import queue_post_media_deletion, run_media_cleanup
from app.core.media_storage import R2MediaStorage, configured_media_storage
from app.core.media_uploads import (
    UploadLimits,
    UploadQuotaExceeded,
    UploadReservation,
    upload_ledger,
)
from app.core.moderation import ensure_allowed_content
from app.core.rate_limit import (
    RateLimitRule,
    account_or_client_rate_limit_key,
    api_rate_limiter,
)
from app.core.runtime import DEFAULT_PUBLIC_BACKEND_URL, public_backend_url
from app.core.models import SocialMediaAttachment, SocialPost
from app.core.store import store
from app.core.video_metadata import mp4_duration_seconds

router = APIRouter(prefix="/social", tags=["social"])
ALLOWED_IMAGE_TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
ALLOWED_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
ALLOWED_VIDEO_TYPES = {
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/x-m4v": ".m4v",
}
ALLOWED_VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v"}
MAX_MEDIA_PER_POST = 3
MAX_PHOTO_BYTES = 15 * 1024 * 1024
# Keep feed clips small enough to start quickly on mobile connections. Tydes
# currently serves progressive MP4 files, not an adaptive HLS/DASH ladder.
MAX_VIDEO_BYTES = 25 * 1024 * 1024
MAX_BUNNY_VIDEO_BYTES = 250 * 1024 * 1024
MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024
MAX_VIDEO_DURATION_SECONDS = 30.5
MAX_POST_BODY_CHARS = 1600
MAX_POST_BODY_LINES = 16


class SocialPostCreateRequest(BaseModel):
    body: str = Field(default="", max_length=MAX_POST_BODY_CHARS)
    spot_id: str | None = None
    post_type: Literal["looking_for_buddy", "surf_plan", "general"] = "general"
    visibility: Literal["public", "followers"] = "public"
    media: list[SocialMediaAttachment] = Field(default_factory=list)
    meetup_date: date | None = None
    meetup_end_date: date | None = None

    @field_validator("visibility", mode="before")
    @classmethod
    def normalize_legacy_visibility(cls, value: str) -> str:
        return "followers" if value == "friends" else value

    @field_validator("body")
    @classmethod
    def normalize_body(cls, value: str) -> str:
        body = value.strip()
        if len(body.splitlines()) > MAX_POST_BODY_LINES:
            raise ValueError(f"Post captions can be up to {MAX_POST_BODY_LINES} lines")
        return body


class SocialCommentCreateRequest(BaseModel):
    post_id: str
    text: str = Field(min_length=1, max_length=600)
    reply_to_comment_id: str | None = None


class EventChatMessageCreateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=600)


class SocialReportCreateRequest(BaseModel):
    target_type: Literal["post", "profile", "comment", "message"]
    target_id: str = Field(min_length=1, max_length=120)
    reason: str = Field(default="", max_length=500)


class DirectMediaUploadCreateRequest(BaseModel):
    media_type: Literal["photo", "video"]
    content_type: str = Field(min_length=1, max_length=80)
    size_bytes: int = Field(gt=0)
    thumbnail_content_type: str | None = Field(default=None, max_length=80)
    thumbnail_size_bytes: int = Field(default=0, ge=0)
    file_name: str | None = Field(default=None, max_length=180)


class DirectUploadTarget(BaseModel):
    url: str
    headers: dict[str, str]
    protocol: Literal["put", "tus"] = "put"


class DirectMediaUploadReservationResponse(BaseModel):
    id: str
    media_type: Literal["photo", "video"]
    upload: DirectUploadTarget
    thumbnail_upload: DirectUploadTarget | None = None
    expires_at: datetime


@router.get("/friends")
def list_friends():
    return list(store.list_friends())


@router.get("/posts")
def list_posts(
    request: Request,
    limit: int = Query(default=50, ge=1, le=100),
):
    _limit_public_read(request, "posts", limit=240)
    current_user = optional_authenticated_user(request)
    current_user_id = current_user.id if current_user is not None else None
    return list(store.list_posts(current_user_id=current_user_id, limit=limit))


@router.get("/engagement")
def get_engagement(_user=Depends(require_authenticated_user)):
    return store.social_engagement_state()


@router.get("/events")
def list_upcoming_events(
    request: Request,
    limit: int = Query(default=300, ge=1, le=500),
    _user=Depends(require_authenticated_user),
):
    _limit_public_read(request, "events", limit=120)
    return store.list_upcoming_events(limit=limit)


@router.get("/relationships")
def get_relationships(_user=Depends(require_authenticated_user)):
    return store.social_relationship_state()


@router.get("/profiles")
def get_profiles(
    request: Request,
    limit: int = Query(default=50, ge=1, le=100),
):
    _limit_public_read(request, "profiles", limit=120)
    current_user = optional_authenticated_user(request)
    current_user_id = current_user.id if current_user is not None else None
    return list(
        store.list_social_profiles(
            current_user_id=current_user_id,
            limit=limit,
        )
    )


@router.get("/blocked-profiles")
def get_blocked_profiles(_user=Depends(require_authenticated_user)):
    return list(store.list_blocked_social_profiles())


@router.get("/notifications")
def get_notifications(_user=Depends(require_authenticated_user)):
    return list(store.list_social_notifications())


@router.post("/follows/{user_id}")
def follow_user(user_id: str, _user=Depends(require_authenticated_user)):
    return store.set_user_follow(user_id, True)


@router.delete("/follows/{user_id}")
def unfollow_user(user_id: str, _user=Depends(require_authenticated_user)):
    return store.set_user_follow(user_id, False)


@router.delete("/followers/{user_id}")
def remove_follower(user_id: str, _user=Depends(require_authenticated_user)):
    return store.remove_follower(user_id)


@router.post("/blocks/{user_id}")
def block_user(user_id: str, _user=Depends(require_authenticated_user)):
    return store.set_user_block(user_id, True)


@router.delete("/blocks/{user_id}")
def unblock_user(user_id: str, _user=Depends(require_authenticated_user)):
    return store.set_user_block(user_id, False)


@router.post("/reports")
def report_social_content(
    payload: SocialReportCreateRequest,
    user=Depends(require_authenticated_user),
):
    _limit_user_action(
        user.id,
        "create-report",
        _positive_env("SOCIAL_REPORTS_PER_USER_DAY", 10),
    )
    try:
        ensure_allowed_content(payload.reason)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    report = store.create_social_report(
        report_id=f"report_{uuid4().hex[:10]}",
        target_type=payload.target_type,
        target_id=payload.target_id,
        reason=payload.reason,
    )
    send_moderation_report_email(
        report_id=report.id,
        target_type=report.target_type,
        target_id=report.target_id,
        reporter_user_id=report.reporter_user_id,
        reason=report.reason,
    )
    return report


@router.post("/posts/{post_id}/likes")
def like_post(post_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_post_like(post_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.delete("/posts/{post_id}")
def delete_post(post_id: str, user=Depends(require_authenticated_user)):
    post = store.get_post(post_id)
    if post is None or post.user_id != user.id:
        raise HTTPException(status_code=404, detail="Post not found.")
    queue_post_media_deletion(user.id, [item.id for item in post.media])
    deleted = store.delete_post(post_id, user.id)
    if deleted is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    run_media_cleanup()
    return {"deleted": True}


@router.delete("/posts/{post_id}/likes")
def unlike_post(post_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_post_like(post_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.post("/posts/{post_id}/reposts")
def repost_post(post_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_post_repost(post_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.delete("/posts/{post_id}/reposts")
def unrepost_post(post_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_post_repost(post_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.post("/posts/{post_id}/rsvp")
def join_event(post_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_event_rsvp(post_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Event post not found.")
    return state


@router.delete("/posts/{post_id}/rsvp")
def leave_event(post_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_event_rsvp(post_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Event post not found.")
    return state


@router.get("/posts/{post_id}/attendees")
def list_event_attendees(post_id: str, _user=Depends(require_authenticated_user)):
    attendees = store.list_event_attendees(post_id)
    if attendees is None:
        raise HTTPException(status_code=404, detail="Event post not found.")
    return attendees


@router.get("/posts/{post_id}/chat")
def list_event_chat(post_id: str, _user=Depends(require_authenticated_user)):
    post = store.get_post(post_id)
    if post is None or post.post_type not in {"surf_plan", "looking_for_buddy"}:
        raise HTTPException(status_code=404, detail="Event post not found.")
    messages = store.list_event_chat_messages(post_id)
    if messages is None:
        raise HTTPException(
            status_code=403,
            detail="Join this event to enter its group chat.",
        )
    return messages


@router.post("/posts/{post_id}/chat")
def create_event_chat_message(
    post_id: str,
    payload: EventChatMessageCreateRequest,
    user=Depends(require_authenticated_user),
):
    _limit_user_action(
        user.id,
        "event-chat-message",
        _positive_env("SOCIAL_EVENT_CHAT_MESSAGES_PER_USER_DAY", 100),
    )
    text = payload.text.strip()
    try:
        ensure_allowed_content(text)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    post = store.get_post(post_id)
    if post is None or post.post_type not in {"surf_plan", "looking_for_buddy"}:
        raise HTTPException(status_code=404, detail="Event post not found.")
    message = store.add_event_chat_message(
        post_id=post_id,
        message_id=f"event_message_{uuid4().hex[:12]}",
        text=text,
    )
    if message is None:
        raise HTTPException(
            status_code=403,
            detail="Join this event to enter its group chat.",
        )
    return message


@router.post("/comments")
def create_comment(
    payload: SocialCommentCreateRequest,
    user=Depends(require_authenticated_user),
):
    _limit_user_action(
        user.id,
        "create-comment",
        _positive_env("SOCIAL_COMMENTS_PER_USER_DAY", 100),
    )
    try:
        ensure_allowed_content(payload.text)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    state = store.add_comment(
        post_id=payload.post_id,
        comment_id=f"comment_{uuid4().hex[:10]}",
        text=payload.text.strip(),
        reply_to_comment_id=payload.reply_to_comment_id,
    )
    if state is None:
        raise HTTPException(status_code=404, detail="Post or parent comment not found.")
    return state


@router.delete("/comments/{comment_id}")
def delete_comment(comment_id: str, _user=Depends(require_authenticated_user)):
    state = store.delete_comment(comment_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Comment not found.")
    return state


@router.post("/comments/{comment_id}/likes")
def like_comment(comment_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_comment_like(comment_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Comment not found.")
    return state


@router.delete("/comments/{comment_id}/likes")
def unlike_comment(comment_id: str, _user=Depends(require_authenticated_user)):
    state = store.set_comment_like(comment_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Comment not found.")
    return state


@router.post(
    "/media/uploads",
    response_model=DirectMediaUploadReservationResponse,
)
def create_direct_media_upload(
    payload: DirectMediaUploadCreateRequest,
    request: Request,
    user=Depends(require_authenticated_user),
):
    storage = configured_media_storage()
    use_bunny = payload.media_type == "video" and bunny_stream_enabled()
    if not isinstance(storage, R2MediaStorage) and not use_bunny:
        raise HTTPException(
            status_code=409,
            detail="Direct uploads are unavailable in this environment.",
        )
    if not user.email_verified and not user.premium:
        raise HTTPException(
            status_code=403,
            detail="Verify your email before uploading media.",
        )

    content_type, extension = _validated_direct_media_type(
        payload.media_type,
        payload.content_type,
    )
    max_bytes = (
        MAX_BUNNY_VIDEO_BYTES
        if use_bunny
        else MAX_VIDEO_BYTES
        if payload.media_type == "video"
        else MAX_PHOTO_BYTES
    )
    if payload.size_bytes > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"File is too large. Limit is {max_bytes // (1024 * 1024)} MB.",
        )
    thumbnail_content_type: str | None = None
    thumbnail_extension: str | None = None
    if use_bunny:
        thumbnail_content_type = None
        thumbnail_extension = None
    elif payload.thumbnail_size_bytes > 0 or payload.thumbnail_content_type is not None:
        if payload.thumbnail_size_bytes <= 0 or payload.thumbnail_content_type is None:
            raise HTTPException(status_code=400, detail="Thumbnail details are incomplete.")
        thumbnail_content_type, thumbnail_extension = _validated_direct_media_type(
            "photo",
            payload.thumbnail_content_type,
        )
        if payload.thumbnail_size_bytes > MAX_THUMBNAIL_BYTES:
            raise HTTPException(
                status_code=413,
                detail="Thumbnail is too large. Limit is 2 MB.",
            )
    elif payload.media_type == "photo":
        raise HTTPException(status_code=400, detail="Photos require a thumbnail.")

    now = datetime.now(timezone.utc)
    ttl_seconds = (
        max(_direct_upload_ttl_seconds(), 6 * 60 * 60)
        if use_bunny
        else _direct_upload_ttl_seconds()
    )
    expires_at = now + timedelta(seconds=ttl_seconds)
    media_id = f"media_{uuid4().hex[:16]}"
    user_path = hashlib.sha256(user.id.encode("utf-8")).hexdigest()[:16]
    pending_name = f"pending/{user_path}/{media_id}{extension}"
    final_name = f"media/{user_path}/{media_id}{extension}"
    pending_thumbnail_name = (
        f"pending/{user_path}/{media_id}_thumb{thumbnail_extension}"
        if thumbnail_extension is not None
        else None
    )
    final_thumbnail_name = (
        f"media/{user_path}/{media_id}_thumb{thumbnail_extension}"
        if thumbnail_extension is not None
        else None
    )
    bunny_client: BunnyStreamClient | None = None
    bunny_upload = None
    if use_bunny:
        bunny_client = BunnyStreamClient()
        bunny_upload = bunny_client.create_upload(
            payload.file_name or f"Tydes video {media_id}",
            expires_seconds=ttl_seconds,
        )
        expires_at = bunny_upload.expires_at
        pending_name = bunny_upload.video_id
        final_name = bunny_upload.video_id
        pending_thumbnail_name = None
        final_thumbnail_name = None
        public_url = bunny_client.playlist_url(bunny_upload.video_id)
        thumbnail_public_url = bunny_client.thumbnail_url(bunny_upload.video_id)
    else:
        public_url = storage.public_object_url(final_name)
        thumbnail_public_url = (
            storage.public_object_url(final_thumbnail_name)
            if final_thumbnail_name is not None
            else public_url
        )
    reservation = UploadReservation(
        id=media_id,
        user_id=user.id,
        client_ip_hash=_client_ip_hash(request),
        media_type=payload.media_type,
        content_type=content_type,
        thumbnail_content_type=thumbnail_content_type,
        expected_bytes=payload.size_bytes,
        expected_thumbnail_bytes=0 if use_bunny else payload.thumbnail_size_bytes,
        pending_name=pending_name,
        final_name=final_name,
        pending_thumbnail_name=pending_thumbnail_name,
        final_thumbnail_name=final_thumbnail_name,
        public_url=public_url,
        thumbnail_public_url=thumbnail_public_url,
        status="pending",
        created_at=now,
        expires_at=expires_at,
        storage_provider="bunny_stream" if use_bunny else "r2",
        external_id=bunny_upload.video_id if bunny_upload is not None else None,
    )
    try:
        upload_ledger.reserve(
            reservation,
            UploadLimits.from_env(premium=user.premium),
        )
    except UploadQuotaExceeded as error:
        if bunny_upload is not None:
            bunny_client.delete_video(bunny_upload.video_id)
        raise HTTPException(status_code=429, detail=str(error)) from error
    except Exception:
        if bunny_upload is not None:
            bunny_client.delete_video(bunny_upload.video_id)
        raise

    try:
        if bunny_upload is not None:
            upload_url = bunny_upload.url
        else:
            upload_url = storage.create_direct_upload_url(
                pending_name,
                content_type=content_type,
                content_length=payload.size_bytes,
                expires_seconds=ttl_seconds,
            )
        thumbnail_upload = None
        if pending_thumbnail_name is not None and thumbnail_content_type is not None:
            thumbnail_url = storage.create_direct_upload_url(
                pending_thumbnail_name,
                content_type=thumbnail_content_type,
                content_length=payload.thumbnail_size_bytes,
                expires_seconds=ttl_seconds,
            )
            thumbnail_upload = DirectUploadTarget(
                url=thumbnail_url,
                headers={
                    "Content-Type": thumbnail_content_type,
                    "If-None-Match": "*",
                },
            )
    except Exception:
        upload_ledger.set_status(media_id, user.id, "failed")
        if bunny_upload is not None:
            bunny_client.delete_video(bunny_upload.video_id)
        raise

    return DirectMediaUploadReservationResponse(
        id=media_id,
        media_type=payload.media_type,
        upload=DirectUploadTarget(
            url=upload_url,
            headers=(
                bunny_upload.headers
                if bunny_upload is not None
                else {
                    "Content-Type": content_type,
                    "If-None-Match": "*",
                }
            ),
            protocol="tus" if bunny_upload is not None else "put",
        ),
        thumbnail_upload=thumbnail_upload,
        expires_at=expires_at,
    )


@router.post("/media/uploads/{reservation_id}/complete")
def complete_direct_media_upload(
    reservation_id: str,
    user=Depends(require_authenticated_user),
):
    storage = configured_media_storage()
    if not isinstance(storage, R2MediaStorage):
        raise HTTPException(status_code=409, detail="Direct uploads are unavailable.")
    reservation = upload_ledger.get(reservation_id, user.id)
    if reservation is None:
        raise HTTPException(status_code=404, detail="Upload reservation not found.")
    if reservation.status in {"complete", "used"}:
        return _reservation_attachment(reservation)
    if reservation.status != "pending":
        raise HTTPException(status_code=409, detail="This upload is no longer active.")
    if reservation.expires_at < datetime.now(timezone.utc):
        if reservation.storage_provider == "bunny_stream":
            BunnyStreamClient().delete_video(reservation.external_id)
        else:
            _discard_pending_upload(storage, reservation)
        upload_ledger.set_status(reservation.id, user.id, "expired")
        raise HTTPException(status_code=410, detail="Upload link expired. Try again.")

    if reservation.storage_provider == "bunny_stream":
        bunny = BunnyStreamClient()
        try:
            video = bunny.get_video(reservation.external_id or reservation.final_name)
        except Exception as error:
            raise HTTPException(
                status_code=400,
                detail="Bunny did not receive the video correctly. Try again.",
            ) from error
        if video.failed:
            bunny.delete_video(video.video_id)
            upload_ledger.set_status(reservation.id, user.id, "rejected")
            raise HTTPException(status_code=400, detail="Video processing failed. Try again.")
        if not video.ready:
            raise HTTPException(
                status_code=425,
                detail="Video is processing. Tydes will retry automatically.",
                headers={"Retry-After": "5"},
            )
        if (
            video.length_seconds is None
            or video.length_seconds > MAX_VIDEO_DURATION_SECONDS
        ):
            bunny.delete_video(video.video_id)
            upload_ledger.set_status(reservation.id, user.id, "rejected")
            raise HTTPException(status_code=400, detail="Videos can be up to 30 seconds long.")
        completed = upload_ledger.set_status(reservation.id, user.id, "complete")
        return _reservation_attachment(completed or reservation)

    try:
        media_metadata = storage.object_metadata(reservation.pending_name)
        _validate_uploaded_object(
            media_metadata.size,
            media_metadata.content_type,
            reservation.expected_bytes,
            reservation.content_type,
        )
        if reservation.media_type == "video":
            duration = mp4_duration_seconds(
                storage,
                reservation.pending_name,
                media_metadata.size,
            )
            if duration is None:
                raise ValueError("Could not verify the video. Export it as an MP4 and retry.")
            if duration > MAX_VIDEO_DURATION_SECONDS:
                raise ValueError("Videos can be up to 30 seconds long.")

        if reservation.pending_thumbnail_name is not None:
            thumbnail_metadata = storage.object_metadata(
                reservation.pending_thumbnail_name
            )
            _validate_uploaded_object(
                thumbnail_metadata.size,
                thumbnail_metadata.content_type,
                reservation.expected_thumbnail_bytes,
                reservation.thumbnail_content_type or "",
            )

        storage.promote_object(
            reservation.pending_name,
            reservation.final_name,
            content_type=reservation.content_type,
        )
        if (
            reservation.pending_thumbnail_name is not None
            and reservation.final_thumbnail_name is not None
            and reservation.thumbnail_content_type is not None
        ):
            storage.promote_object(
                reservation.pending_thumbnail_name,
                reservation.final_thumbnail_name,
                content_type=reservation.thumbnail_content_type,
            )
    except ValueError as error:
        _discard_pending_upload(storage, reservation)
        upload_ledger.set_status(reservation.id, user.id, "rejected")
        raise HTTPException(status_code=400, detail=str(error)) from error
    except Exception as error:
        raise HTTPException(
            status_code=400,
            detail="Upload did not arrive correctly. Try again.",
        ) from error

    completed = upload_ledger.set_status(reservation.id, user.id, "complete")
    return _reservation_attachment(completed or reservation)


@router.delete("/media/uploads/{reservation_id}")
def cancel_direct_media_upload(
    reservation_id: str,
    user=Depends(require_authenticated_user),
):
    storage = configured_media_storage()
    reservation = upload_ledger.get(reservation_id, user.id)
    if reservation is None:
        return {"canceled": True}
    if reservation.status == "pending":
        if reservation.storage_provider == "bunny_stream":
            BunnyStreamClient().delete_video(reservation.external_id)
        elif isinstance(storage, R2MediaStorage):
            _discard_pending_upload(storage, reservation)
    upload_ledger.set_status(reservation.id, user.id, "canceled")
    return {"canceled": True}


@router.post("/media")
async def upload_media(
    request: Request,
    _user=Depends(require_authenticated_user),
    file: UploadFile = File(...),
    thumbnail: UploadFile | None = File(None),
):
    storage = configured_media_storage()
    if isinstance(storage, R2MediaStorage):
        raise HTTPException(
            status_code=426,
            detail="Update Tydes to use protected direct media uploads.",
        )
    extension = _image_extension(file)
    media_type = "photo"
    if extension is None:
        extension = _video_extension(file)
        media_type = "video"
    if extension is None:
        raise HTTPException(status_code=400, detail="Only photos and videos are supported.")

    media_id = f"media_{uuid4().hex[:10]}"
    base_url = _request_public_base_url(request)
    object_name = f"{media_id}{extension}"
    max_bytes = MAX_VIDEO_BYTES if media_type == "video" else MAX_PHOTO_BYTES
    stored_media = storage.store_upload(
        file,
        object_name,
        max_bytes,
        local_base_url=base_url,
    )

    thumb_url: str | None = None
    if media_type == "photo":
        thumb_extension = (
            _image_extension(thumbnail) if thumbnail is not None else None
        )
        if thumb_extension is None:
            raise HTTPException(status_code=400, detail="Thumbnail must be a photo.")
        stored_thumb = storage.store_upload(
            thumbnail,
            f"{media_id}_thumb{thumb_extension}",
            MAX_PHOTO_BYTES,
            local_base_url=base_url,
        )
        thumb_url = stored_thumb.url
    elif thumbnail is not None:
        thumb_extension = _image_extension(thumbnail)
        if thumb_extension is None:
            raise HTTPException(status_code=400, detail="Video thumbnail must be a photo.")
        stored_thumb = storage.store_upload(
            thumbnail,
            f"{media_id}_thumb{thumb_extension}",
            MAX_PHOTO_BYTES,
            local_base_url=base_url,
        )
        thumb_url = stored_thumb.url

    return SocialMediaAttachment(
        id=media_id,
        media_type=media_type,
        url=stored_media.url,
        thumbnail_url=thumb_url or stored_media.url,
    )


def _image_extension(file: UploadFile) -> str | None:
    if file.content_type in ALLOWED_IMAGE_TYPES:
        return ALLOWED_IMAGE_TYPES[file.content_type]
    suffix = Path(file.filename or "").suffix.lower()
    if suffix == ".jpeg":
        return ".jpg"
    if suffix in ALLOWED_IMAGE_EXTENSIONS:
        return suffix
    return None


def _video_extension(file: UploadFile) -> str | None:
    if file.content_type in ALLOWED_VIDEO_TYPES:
        return ALLOWED_VIDEO_TYPES[file.content_type]
    suffix = Path(file.filename or "").suffix.lower()
    if suffix in ALLOWED_VIDEO_EXTENSIONS:
        return suffix
    return None


def _validated_direct_media_type(
    media_type: str,
    content_type: str,
) -> tuple[str, str]:
    normalized = content_type.strip().lower().split(";", 1)[0]
    allowed = ALLOWED_VIDEO_TYPES if media_type == "video" else ALLOWED_IMAGE_TYPES
    extension = allowed.get(normalized)
    if extension is None:
        label = "video" if media_type == "video" else "photo"
        raise HTTPException(status_code=400, detail=f"Unsupported {label} format.")
    return normalized, extension


def _direct_upload_ttl_seconds() -> int:
    raw = os.getenv("MEDIA_UPLOAD_URL_TTL_SECONDS", "300").strip()
    try:
        value = int(raw)
    except ValueError:
        value = 300
    return min(max(value, 60), 600)


def _daily_post_limit() -> int:
    raw = os.getenv("SOCIAL_DAILY_POST_LIMIT", "20").strip()
    try:
        value = int(raw)
    except ValueError:
        value = 20
    return min(max(value, 1), 100)


def _positive_env(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _limit_user_action(
    user_id: str,
    scope: str,
    limit: int,
    *,
    window_seconds: int = 24 * 60 * 60,
) -> None:
    api_rate_limiter.enforce(
        RateLimitRule(
            scope=f"social:{scope}:user",
            key=user_id,
            limit=limit,
            window_seconds=window_seconds,
        )
    )


def _limit_public_read(request: Request, scope: str, *, limit: int) -> None:
    api_rate_limiter.enforce(
        RateLimitRule(
            scope=f"social:read:{scope}",
            key=account_or_client_rate_limit_key(request),
            limit=limit,
            window_seconds=5 * 60,
        )
    )


def _client_ip_hash(request: Request) -> str:
    client_ip = request.client.host if request.client is not None else "unknown"
    return hashlib.sha256(client_ip.encode("utf-8")).hexdigest()


def _validate_uploaded_object(
    actual_bytes: int,
    actual_content_type: str,
    expected_bytes: int,
    expected_content_type: str,
) -> None:
    if actual_bytes != expected_bytes:
        raise ValueError("Uploaded file size did not match the reservation.")
    normalized_actual = actual_content_type.strip().lower().split(";", 1)[0]
    if normalized_actual != expected_content_type:
        raise ValueError("Uploaded file type did not match the reservation.")


def _reservation_attachment(
    reservation: UploadReservation,
) -> SocialMediaAttachment:
    fallback_url = None
    if reservation.storage_provider == "bunny_stream":
        bunny = BunnyStreamClient()
        fallback_url = bunny.fallback_url(
            reservation.external_id or reservation.final_name,
        )
    return SocialMediaAttachment(
        id=reservation.id,
        media_type=reservation.media_type,
        url=reservation.public_url,
        thumbnail_url=reservation.thumbnail_public_url,
        fallback_url=fallback_url,
    )


def _discard_pending_upload(
    storage: R2MediaStorage,
    reservation: UploadReservation,
) -> None:
    for object_name in (
        reservation.pending_name,
        reservation.pending_thumbnail_name,
    ):
        try:
            storage.delete_object(object_name)
        except Exception:
            pass


def _request_public_base_url(request: Request) -> str:
    configured_url = public_backend_url()
    if configured_url != DEFAULT_PUBLIC_BACKEND_URL:
        return configured_url
    return str(request.base_url).rstrip("/")


@router.post("/posts")
def create_post(
    payload: SocialPostCreateRequest,
    user=Depends(require_authenticated_user),
):
    daily_post_limit = _daily_post_limit()
    now = datetime.now(timezone.utc)
    if (
        store.count_user_posts_since(user.id, now - timedelta(days=1))
        >= daily_post_limit
    ):
        raise HTTPException(
            status_code=429,
            detail=(
                f"You can create up to {daily_post_limit} posts or events per day."
            ),
            headers={"Retry-After": str(60 * 60)},
        )
    api_rate_limiter.enforce(
        RateLimitRule(
            scope="social:create-post:user",
            key=user.id,
            limit=daily_post_limit * 2,
            window_seconds=24 * 60 * 60,
        )
    )
    try:
        ensure_allowed_content(payload.body)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    media = [
        item
        for item in payload.media
        if item.media_type in {"photo", "video"}
    ][:MAX_MEDIA_PER_POST]
    if len({item.id for item in media}) != len(media):
        raise HTTPException(status_code=400, detail="Duplicate media is not allowed.")
    if isinstance(configured_media_storage(), R2MediaStorage) and media:
        try:
            upload_ledger.assert_completed_media(
                user.id,
                [
                    (item.id, item.media_type, item.url, item.thumbnail_url)
                    for item in media
                ],
            )
        except ValueError as error:
            raise HTTPException(status_code=400, detail=str(error)) from error
    post = SocialPost(
        id=f"post_{uuid4().hex[:8]}",
        user_id=user.id,
        author_name=user.display_name,
        author_handle=user.handle,
        author_avatar_url=user.avatar_url,
        author_premium=user.premium,
        spot_id=payload.spot_id,
        post_type=payload.post_type,
        visibility=payload.visibility,
        body=payload.body,
        media=media,
        meetup_date=payload.meetup_date,
        meetup_end_date=payload.meetup_end_date,
        created_at=datetime.now(timezone.utc),
    )
    created = store.add_post(post)
    if media:
        upload_ledger.mark_used(user.id, [item.id for item in media])
    return created
