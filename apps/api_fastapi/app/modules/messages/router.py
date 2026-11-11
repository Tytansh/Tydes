from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.core.auth import require_authenticated_user
from app.core.direct_messages import DirectMessageService, get_direct_message_service
from app.core.models import User
from app.core.moderation import ensure_allowed_content
from app.core.rate_limit import RateLimitRule, api_rate_limiter

router = APIRouter(prefix="/messages", tags=["messages"])


class StartConversation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    recipient_user_id: str = Field(min_length=1, max_length=120)


class SendMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(default="", max_length=1600)
    client_message_id: str = Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9_-]+$")
    shared_post_id: str | None = Field(default=None, min_length=1, max_length=120)

    @model_validator(mode="after")
    def valid_content(self):
        self.text = self.text.strip()
        if not self.text and not self.shared_post_id:
            raise ValueError("Write a message or choose a post to share.")
        return self


class ReadMessages(BaseModel):
    model_config = ConfigDict(extra="forbid")
    last_message_id: str = Field(min_length=1, max_length=120)


class UpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    accepted: bool | None = None
    declined: bool | None = None

    @model_validator(mode="after")
    def valid_action(self):
        if self.accepted is None and self.declined is None:
            raise ValueError("No request change supplied.")
        if self.accepted is True and self.declined is True:
            raise ValueError("A request cannot be accepted and declined together.")
        return self


def _read_limit(user: User):
    api_rate_limiter.enforce(RateLimitRule(scope="messages:read", key=user.id, limit=240, window_seconds=300))


@router.get("/threads")
def list_threads(user: User = Depends(require_authenticated_user), service: DirectMessageService = Depends(get_direct_message_service)):
    _read_limit(user)
    return service.list_threads(user)


@router.get("/unread-count")
def unread_count(user: User = Depends(require_authenticated_user), service: DirectMessageService = Depends(get_direct_message_service)):
    _read_limit(user)
    return service.unread_count(user)


@router.post("/threads")
def start_thread(payload: StartConversation, user: User = Depends(require_authenticated_user), service: DirectMessageService = Depends(get_direct_message_service)):
    api_rate_limiter.enforce(RateLimitRule(scope="messages:start", key=user.id, limit=30, window_seconds=300))
    return service.create_thread(user, payload.recipient_user_id)


@router.get("/threads/{thread_id}")
def get_thread(thread_id: str, user: User = Depends(require_authenticated_user), service: DirectMessageService = Depends(get_direct_message_service)):
    _read_limit(user)
    return service.get_thread(user, thread_id)


@router.post("/threads/{thread_id}/messages")
def send_message(thread_id: str, payload: SendMessage, user: User = Depends(require_authenticated_user), service: DirectMessageService = Depends(get_direct_message_service)):
    api_rate_limiter.enforce(RateLimitRule(scope="messages:send", key=user.id, limit=20, window_seconds=60))
    try:
        ensure_allowed_content(payload.text)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    return service.send(user, thread_id, payload.text, payload.client_message_id, payload.shared_post_id)


@router.post("/threads/{thread_id}/read")
def read_messages(thread_id: str, payload: ReadMessages, user: User = Depends(require_authenticated_user), service: DirectMessageService = Depends(get_direct_message_service)):
    _read_limit(user)
    return service.mark_read(user, thread_id, payload.last_message_id)


@router.patch("/threads/{thread_id}/request")
def update_request(thread_id: str, payload: UpdateRequest, user: User = Depends(require_authenticated_user), service: DirectMessageService = Depends(get_direct_message_service)):
    api_rate_limiter.enforce(RateLimitRule(scope="messages:request", key=user.id, limit=60, window_seconds=300))
    return service.set_request(user, thread_id, payload.accepted, payload.declined)
