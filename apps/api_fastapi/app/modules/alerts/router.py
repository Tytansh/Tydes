from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.core.models import Alert
from app.core.store import store

router = APIRouter(prefix="/alerts", tags=["alerts"])


class AlertCreateRequest(BaseModel):
    spot_id: str
    wave_enabled: bool = True
    min_wave_height_m: float | None = None
    wind_enabled: bool = True
    max_wind_kts: int | None = None
    tide_enabled: bool = False
    tide_type: str | None = None
    tide_offset_hours: int | None = None
    enabled: bool = True


class AlertUpdateRequest(BaseModel):
    enabled: bool


@router.get("")
def list_alerts():
    return list(store.list_alerts())


@router.post("")
def create_alert(payload: AlertCreateRequest):
    alert = Alert(
        id=f"alert_{uuid4().hex[:8]}",
        user_id=store.user.id,
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
def update_alert(alert_id: str, payload: AlertUpdateRequest):
    alert = store.update_alert_enabled(alert_id, payload.enabled)
    if alert is None:
        raise HTTPException(status_code=404, detail="Alert not found")
    return alert


@router.delete("/{alert_id}")
def delete_alert(alert_id: str):
    deleted = store.delete_alert(alert_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Alert not found")
    return {"deleted": True}
