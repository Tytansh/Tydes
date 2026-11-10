"""Small, explicitly public share previews. No forecasts or social membership."""
from datetime import date, datetime, timezone
from typing import Literal

from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel

from app.core.auth import optional_authenticated_user
from app.core.models import User
from app.core.rate_limit import RateLimitRule, api_rate_limiter, client_rate_limit_key
from app.core.store import store

router = APIRouter(prefix="/public", tags=["public previews"])


class PublicSpotPreview(BaseModel):
    id: str
    name: str
    country: str
    region: str
    area: str
    summary: str
    difficulty: Literal["beginner", "intermediate", "advanced"]
    best_months: list[str]


class PublicEventHost(BaseModel):
    name: str
    handle: str | None
    avatar_url: str | None


class PublicEventPreview(BaseModel):
    id: str
    body: str
    meetup_date: date | None
    meetup_end_date: date | None
    ended: bool
    host: PublicEventHost
    spot: PublicSpotPreview | None


def _limit(request: Request) -> None:
    api_rate_limiter.enforce(RateLimitRule(
        scope="public-preview:read", key=client_rate_limit_key(request),
        limit=120, window_seconds=300,
    ))


def _spot(spot) -> PublicSpotPreview:
    return PublicSpotPreview(**{key: getattr(spot, key) for key in PublicSpotPreview.model_fields})


def _unavailable():
    # Identical response for a private, removed, or unknown event.
    raise HTTPException(status_code=404, detail="This event is not available publicly.",
                        headers={"Cache-Control": "no-store"})


@router.get("/spots/{spot_id}", response_model=PublicSpotPreview)
def spot_preview(spot_id: str, request: Request, response: Response):
    _limit(request)
    spot = store.get_spot(spot_id)
    if spot is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    response.headers["Cache-Control"] = "public, max-age=3600"
    return _spot(spot)


@router.get("/events/{post_id}", response_model=PublicEventPreview)
def event_preview(post_id: str, request: Request, response: Response):
    _limit(request)
    response.headers["Cache-Control"] = "no-store"
    post = store.get_post(post_id)
    if post is None or post.visibility != "public" or post.post_type not in {"surf_plan", "looking_for_buddy"}:
        _unavailable()
    if store.postgres_auth is not None:
        author = store.postgres_auth.get_user_by_id(post.user_id)
    else:
        author = next((User.model_validate(item["user"]) for item in store.auth_accounts.values()
                       if isinstance(item.get("user"), dict) and item["user"].get("id") == post.user_id), None)
    if author is None or author.banned:
        _unavailable()
    viewer = optional_authenticated_user(request)
    if viewer is not None and post.user_id in store._blocked_user_ids_for(viewer.id):
        _unavailable()
    spot = store.get_spot(post.spot_id) if post.spot_id else None
    end = post.meetup_end_date or post.meetup_date
    return PublicEventPreview(
        id=post.id, body=post.body, meetup_date=post.meetup_date,
        meetup_end_date=post.meetup_end_date,
        ended=end is not None and end < datetime.now(timezone.utc).date(),
        host=PublicEventHost(name=author.display_name or "Event host", handle=author.handle or None,
                             avatar_url=author.avatar_url),
        spot=_spot(spot) if spot is not None else None,
    )
