from datetime import datetime, timedelta, timezone
import os
from typing import Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.core.auth import require_authenticated_user
from app.core.models import Alert
from app.core.rate_limit import RateLimitRule, api_rate_limiter
from app.core.store import store

router = APIRouter(prefix="/alerts", tags=["alerts"])


class AlertCreateRequest(BaseModel):
    spot_id: str
    wave_enabled: bool = True
    min_wave_height_m: float | None = Field(default=None, ge=0, le=20)
    wind_enabled: bool = True
    max_wind_kts: int | None = Field(default=None, ge=0, le=200)
    tide_enabled: bool = False
    tide_type: Literal["high", "low"] | None = None
    tide_offset_hours: int | None = Field(default=None, ge=-12, le=12)
    enabled: bool = True


class AlertUpdateRequest(BaseModel):
    spot_id: str | None = None
    wave_enabled: bool | None = None
    min_wave_height_m: float | None = Field(default=None, ge=0, le=20)
    wind_enabled: bool | None = None
    max_wind_kts: int | None = Field(default=None, ge=0, le=200)
    tide_enabled: bool | None = None
    tide_type: Literal["high", "low"] | None = None
    tide_offset_hours: int | None = Field(default=None, ge=-12, le=12)
    enabled: bool | None = None


@router.get("")
def list_alerts(user=Depends(require_authenticated_user)):
    return list(store.list_alerts(user.id))


@router.post("")
def create_alert(
    payload: AlertCreateRequest,
    user=Depends(require_authenticated_user),
):
    if store.get_spot(payload.spot_id) is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    retained_limit = _positive_env("ALERTS_MAX_PER_USER", 25)
    if len(list(store.list_alerts(user.id))) >= retained_limit:
        raise HTTPException(
            status_code=409,
            detail=f"You can keep up to {retained_limit} surf alerts.",
        )
    api_rate_limiter.enforce(
        RateLimitRule(
            scope="planning:create-alert:user",
            key=user.id,
            limit=_positive_env("ALERTS_CREATED_PER_USER_DAY", 10),
            window_seconds=24 * 60 * 60,
        )
    )
    alert = Alert(
        id=f"alert_{uuid4().hex[:8]}",
        user_id=user.id,
        spot_id=payload.spot_id,
        wave_enabled=payload.wave_enabled,
        min_wave_height_m=payload.min_wave_height_m,
        wind_enabled=payload.wind_enabled,
        max_wind_kts=payload.max_wind_kts,
        tide_enabled=payload.tide_enabled,
        tide_type=payload.tide_type,
        tide_offset_hours=payload.tide_offset_hours,
        enabled=payload.enabled,
        next_check_at=datetime.now(timezone.utc) + timedelta(hours=4),
    )
    return store.add_alert(alert)


@router.patch("/{alert_id}")
def update_alert(
    alert_id: str,
    payload: AlertUpdateRequest,
    user=Depends(require_authenticated_user),
):
    alert = store.update_alert(
        alert_id,
        payload.model_dump(exclude_unset=True),
        user_id=user.id,
    )
    if alert is None:
        raise HTTPException(status_code=404, detail="Alert not found")
    return alert


@router.delete("/{alert_id}")
def delete_alert(alert_id: str, user=Depends(require_authenticated_user)):
    deleted = store.delete_alert(alert_id, user_id=user.id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Alert not found")
    return {"deleted": True}


def _positive_env(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default
