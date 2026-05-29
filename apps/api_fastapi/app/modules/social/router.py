from datetime import date, datetime, timezone
from pathlib import Path
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, File, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field, field_validator

from app.core.runtime import media_dir_path, public_backend_url
from app.core.models import SocialMediaAttachment, SocialPost
from app.core.store import store

router = APIRouter(prefix="/social", tags=["social"])
MEDIA_DIR = media_dir_path()
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
MAX_VIDEO_BYTES = 500 * 1024 * 1024


class SocialPostCreateRequest(BaseModel):
    body: str
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


class SocialCommentCreateRequest(BaseModel):
    post_id: str
    text: str = Field(min_length=1, max_length=600)
    reply_to_comment_id: str | None = None


@router.get("/friends")
def list_friends():
    return list(store.list_friends())


@router.get("/posts")
def list_posts():
    return list(store.list_posts())


@router.get("/engagement")
def get_engagement():
    return store.social_engagement_state()


@router.post("/posts/{post_id}/likes")
def like_post(post_id: str):
    state = store.set_post_like(post_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.delete("/posts/{post_id}/likes")
def unlike_post(post_id: str):
    state = store.set_post_like(post_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.post("/posts/{post_id}/reposts")
def repost_post(post_id: str):
    state = store.set_post_repost(post_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.delete("/posts/{post_id}/reposts")
def unrepost_post(post_id: str):
    state = store.set_post_repost(post_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Post not found.")
    return state


@router.post("/posts/{post_id}/rsvp")
def join_event(post_id: str):
    state = store.set_event_rsvp(post_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Event post not found.")
    return state


@router.delete("/posts/{post_id}/rsvp")
def leave_event(post_id: str):
    state = store.set_event_rsvp(post_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Event post not found.")
    return state


@router.post("/comments")
def create_comment(payload: SocialCommentCreateRequest):
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
def delete_comment(comment_id: str):
    state = store.delete_comment(comment_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Comment not found.")
    return state


@router.post("/comments/{comment_id}/likes")
def like_comment(comment_id: str):
    state = store.set_comment_like(comment_id, True)
    if state is None:
        raise HTTPException(status_code=404, detail="Comment not found.")
    return state


@router.delete("/comments/{comment_id}/likes")
def unlike_comment(comment_id: str):
    state = store.set_comment_like(comment_id, False)
    if state is None:
        raise HTTPException(status_code=404, detail="Comment not found.")
    return state


@router.post("/media")
async def upload_media(
    request: Request,
    file: UploadFile = File(...),
    thumbnail: UploadFile | None = File(None),
):
    extension = _image_extension(file)
    media_type = "photo"
    if extension is None:
        extension = _video_extension(file)
        media_type = "video"
    if extension is None:
        raise HTTPException(status_code=400, detail="Only photos and videos are supported.")

    media_id = f"media_{uuid4().hex[:10]}"
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)

    full_path = MEDIA_DIR / f"{media_id}{extension}"
    max_bytes = MAX_VIDEO_BYTES if media_type == "video" else MAX_PHOTO_BYTES
    _write_upload_with_limit(file, full_path, max_bytes)

    thumb_url: str | None = None
    if media_type == "photo":
        if thumbnail is None or _image_extension(thumbnail) is None:
            raise HTTPException(status_code=400, detail="Thumbnail must be a photo.")
        thumb_path = MEDIA_DIR / f"{media_id}_thumb{extension}"
        _write_upload_with_limit(thumbnail, thumb_path, MAX_PHOTO_BYTES)
        thumb_url = f"{_request_public_base_url(request)}/media/{thumb_path.name}"

    base_url = _request_public_base_url(request)
    media_url = f"{base_url}/media/{full_path.name}"
    return SocialMediaAttachment(
        id=media_id,
        media_type=media_type,
        url=media_url,
        thumbnail_url=thumb_url or media_url,
    )


def _write_upload_with_limit(file: UploadFile, path: Path, max_bytes: int) -> None:
    bytes_written = 0
    with path.open("wb") as output:
        while chunk := file.file.read(1024 * 1024):
            bytes_written += len(chunk)
            if bytes_written > max_bytes:
                output.close()
                path.unlink(missing_ok=True)
                limit_mb = max_bytes // (1024 * 1024)
                raise HTTPException(
                    status_code=413,
                    detail=f"File is too large. Limit is {limit_mb} MB.",
                )
            output.write(chunk)


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


def _request_public_base_url(request: Request) -> str:
    configured_url = public_backend_url()
    if configured_url != "http://127.0.0.1:8000":
        return configured_url
    return str(request.base_url).rstrip("/")


@router.post("/posts")
def create_post(payload: SocialPostCreateRequest):
    media = [
        item
        for item in payload.media
        if item.media_type in {"photo", "video"}
    ][:MAX_MEDIA_PER_POST]
    post = SocialPost(
        id=f"post_{uuid4().hex[:8]}",
        user_id=store.user.id,
        author_name=store.user.display_name,
        author_handle=store.user.handle,
        author_avatar_url=store.user.avatar_url,
        author_premium=store.user.premium,
        spot_id=payload.spot_id,
        post_type=payload.post_type,
        visibility=payload.visibility,
        body=payload.body,
        media=media,
        meetup_date=payload.meetup_date,
        meetup_end_date=payload.meetup_end_date,
        created_at=datetime.now(timezone.utc),
    )
    return store.add_post(post)
