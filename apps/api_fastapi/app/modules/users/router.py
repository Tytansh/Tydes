from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.core.store import store

router = APIRouter(prefix="/users", tags=["users"])


class FavoriteSpotRequest(BaseModel):
    spot_id: str


class FreeLiveSpotRequest(BaseModel):
    spot_id: str


class UpdateProfileRequest(BaseModel):
    display_name: str
    handle: str
    bio: str
    surf_skill: str
    avatar_url: str | None = None


@router.get("/me")
def me():
    return store.user


@router.put("/me")
def update_me(payload: UpdateProfileRequest):
    display_name = payload.display_name.strip()
    handle = payload.handle.strip().lower().replace(" ", "")
    bio = payload.bio.strip()

    if not display_name:
        raise HTTPException(status_code=400, detail="Display name is required")
    if not handle:
        raise HTTPException(status_code=400, detail="Handle is required")
    if handle.startswith("@"):
        handle = handle[1:]
    if len(handle) < 2:
        raise HTTPException(status_code=400, detail="Handle is too short")
    if len(bio) > 180:
        raise HTTPException(status_code=400, detail="Bio is too long")
    if payload.surf_skill not in {"beginner", "intermediate", "pro"}:
        raise HTTPException(status_code=400, detail="Surf skill is invalid")

    return store.update_profile(
        display_name=display_name,
        handle=handle,
        bio=bio,
        surf_skill=payload.surf_skill,
        avatar_url=payload.avatar_url,
    )


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


@router.post("/free-live-spot")
def set_free_live_spot(payload: FreeLiveSpotRequest):
    if store.get_spot(payload.spot_id) is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    try:
        user = store.set_free_live_spot(payload.spot_id)
    except ValueError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    return user
