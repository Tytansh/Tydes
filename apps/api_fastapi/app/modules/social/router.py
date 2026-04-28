from datetime import date, datetime, timezone
from pathlib import Path
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, File, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field

from app.core.models import SocialMediaAttachment, SocialPost
from app.core.store import store

router = APIRouter(prefix="/social", tags=["social"])
MEDIA_DIR = Path(__file__).resolve().parents[3] / "data" / "media"
ALLOWED_IMAGE_TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
ALLOWED_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
ALLOWED_VIDEO_TYPES = {
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/x-m4v": ".m4v",
}
ALLOWED_VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v"}
MAX_PHOTOS_PER_POST = 3
MAX_VIDEOS_PER_POST = 1
MAX_PHOTO_BYTES = 15 * 1024 * 1024
MAX_VIDEO_BYTES = 500 * 1024 * 1024


class SocialPostCreateRequest(BaseModel):
    body: str
    spot_id: str | None = None
    post_type: Literal["looking_for_buddy", "surf_plan", "general"] = "general"
    visibility: Literal["public", "friends"] = "public"
    media: list[SocialMediaAttachment] = Field(default_factory=list)
    meetup_date: date | None = None


@router.get("/friends")
def list_friends():
    return list(store.list_friends())


@router.get("/posts")
def list_posts():
    return list(store.list_posts())


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
        thumb_url = f"{str(request.base_url).rstrip('/')}/media/{thumb_path.name}"

    base_url = str(request.base_url).rstrip("/")
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


@router.post("/posts")
def create_post(payload: SocialPostCreateRequest):
    photos = [item for item in payload.media if item.media_type == "photo"][:MAX_PHOTOS_PER_POST]
    videos = [item for item in payload.media if item.media_type == "video"][:MAX_VIDEOS_PER_POST]
    media = videos if videos else photos
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
        created_at=datetime.now(timezone.utc),
    )
    return store.add_post(post)
