from fastapi import APIRouter

from app.core.store import store

router = APIRouter(prefix="/forecasts", tags=["forecasts"])


@router.get("")
def list_forecasts(spot_id: str | None = None):
    return list(store.list_forecasts(spot_id))


@router.get("/tides")
def get_tides(spot_id: str):
    return store.get_tides(spot_id)
