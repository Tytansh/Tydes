from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.core.models import Alert
from app.core.store import store

router = APIRouter(prefix="/alerts", tags=["alerts"])


class AlertCreateRequest(BaseModel):
    spot_id: str
    min_wave_height_m: float
    max_wind_kts: int
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
        min_wave_height_m=payload.min_wave_height_m,
        max_wind_kts=payload.max_wind_kts,
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
