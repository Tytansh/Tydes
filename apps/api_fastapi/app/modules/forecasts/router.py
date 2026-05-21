from fastapi import APIRouter

from app.core.store import ForecastFreshness, store

router = APIRouter(prefix="/forecasts", tags=["forecasts"])


@router.get("")
def list_forecasts(spot_id: str | None = None, freshness: ForecastFreshness = "fresh"):
    return list(store.list_forecasts(spot_id, freshness=freshness))


@router.get("/tides")
def get_tides(spot_id: str):
    return store.get_tides(spot_id)


@router.get("/surf-window")
def get_surf_window(spot_id: str):
    return store.get_surf_window(spot_id)
