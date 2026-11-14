from typing import Literal

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from app.core.auth import require_authenticated_user
from app.core import chat_media
from app.core.models import User
from app.core.rate_limit import RateLimitRule, api_rate_limiter

router = APIRouter(prefix="/media", tags=["private-message-media"])


class MediaContext(BaseModel):
    model_config = ConfigDict(extra="forbid")
    conversation_type: Literal["direct", "event"]
    conversation_id: str = Field(min_length=1, max_length=120)


class MediaUpload(MediaContext):
    media_type: Literal["photo", "video"]
    content_type: str = Field(min_length=1, max_length=100)
    size_bytes: int = Field(gt=0, le=chat_media.VIDEO_MAX_BYTES)
    file_name: str | None = Field(default=None, max_length=255)


def _limit(user: User, scope: str, limit: int = 30) -> None:
    api_rate_limiter.enforce(RateLimitRule(scope="chat-media:" + scope, key=user.id,
                                        limit=limit, window_seconds=60))


def _private(response: Response) -> None:
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Pragma"] = "no-cache"


@router.get("/capabilities")
def capabilities(response: Response, user: User = Depends(require_authenticated_user)):
    _limit(user, "capabilities")
    _private(response)
    return chat_media.capabilities()


@router.post("/uploads")
def reserve(payload: MediaUpload, request: Request, response: Response,
            user: User = Depends(require_authenticated_user)):
    _limit(user, "reserve", 4)
    _private(response)
    return chat_media.reserve(user, payload.conversation_type, payload.conversation_id,
        payload.media_type, payload.content_type.lower().strip(), payload.size_bytes,
        request.client.host if request.client else "unknown")


@router.post("/uploads/{identifier}/complete")
def complete(identifier: str, response: Response, user: User = Depends(require_authenticated_user)):
    _limit(user, "complete")
    _private(response)
    result = chat_media.complete(user, identifier)
    if result["status"] == "processing":
        response.headers["Retry-After"] = "5"
    return result


@router.delete("/uploads/{identifier}")
def cancel(identifier: str, response: Response, user: User = Depends(require_authenticated_user)):
    _limit(user, "cancel")
    _private(response)
    return chat_media.cancel(user, identifier)


@router.post("/{identifier}/access")
def access(identifier: str, payload: MediaContext, response: Response,
           user: User = Depends(require_authenticated_user)):
    _limit(user, "access", 60)
    _private(response)
    return chat_media.access(user, identifier, payload.conversation_type, payload.conversation_id)
