from fastapi import APIRouter, HTTPException

from app.core.store import store

router = APIRouter(prefix="/spots", tags=["spots"])


@router.get("")
def list_spots(region: str | None = None):
    return list(store.list_spots(region))


@router.get("/{spot_id}")
def get_spot(spot_id: str):
    spot = store.get_spot(spot_id)
    if spot is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    return spot

