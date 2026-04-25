from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.core.store import store

router = APIRouter(prefix="/users", tags=["users"])


class FavoriteSpotRequest(BaseModel):
    spot_id: str


@router.get("/me")
def me():
    return store.user


@router.get("/dashboard")
def dashboard():
    return store.get_dashboard()


@router.get("/favorites")
def favorites():
    return list(store.list_favorite_spots())


@router.post("/favorites")
def add_favorite(payload: FavoriteSpotRequest):
    if store.get_spot(payload.spot_id) is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    store.add_favorite_spot(payload.spot_id)
    return {"favorite_spot_ids": store.user.favorite_spot_ids}


@router.delete("/favorites/{spot_id}")
def remove_favorite(spot_id: str):
    store.remove_favorite_spot(spot_id)
    return {"favorite_spot_ids": store.user.favorite_spot_ids}
