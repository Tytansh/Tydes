from datetime import date
from uuid import uuid4

import os

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, model_validator

from app.core.auth import require_authenticated_user
from app.core.models import Trip
from app.core.rate_limit import RateLimitRule, api_rate_limiter
from app.core.store import store

router = APIRouter(prefix="/trips", tags=["trips"])


class TripCreateRequest(BaseModel):
    title: str = Field(min_length=1, max_length=100)
    destination: str = Field(min_length=1, max_length=120)
    start_date: date
    end_date: date
    travelers: int = Field(default=1, ge=1, le=30)
    notes: str = Field(default="", max_length=2_000)
    budget_usd: int = Field(default=0, ge=0, le=1_000_000)

    @model_validator(mode="after")
    def validate_dates(self):
        if self.end_date < self.start_date:
            raise ValueError("Trip end date must be on or after the start date")
        return self


@router.get("")
def list_trips(user=Depends(require_authenticated_user)):
    return list(store.list_trips(user.id))


@router.post("")
def create_trip(
    payload: TripCreateRequest,
    user=Depends(require_authenticated_user),
):
    retained_limit = _positive_env("TRIPS_MAX_PER_USER", 25)
    if len(list(store.list_trips(user.id))) >= retained_limit:
        raise HTTPException(
            status_code=409,
            detail=f"You can keep up to {retained_limit} trip plans.",
        )
    api_rate_limiter.enforce(
        RateLimitRule(
            scope="planning:create-trip:user",
            key=user.id,
            limit=_positive_env("TRIPS_CREATED_PER_USER_DAY", 10),
            window_seconds=24 * 60 * 60,
        )
    )
    trip = Trip(
        id=f"trip_{uuid4().hex[:8]}",
        user_id=user.id,
        title=payload.title,
        destination=payload.destination,
        start_date=payload.start_date,
        end_date=payload.end_date,
        travelers=payload.travelers,
        notes=payload.notes,
        budget_usd=payload.budget_usd,
    )
    return store.add_trip(trip)


def _positive_env(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default

