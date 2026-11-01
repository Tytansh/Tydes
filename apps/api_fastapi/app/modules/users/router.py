from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
import re

from app.core.auth import require_authenticated_user
from app.core.media_cleanup import queue_post_media_deletion
from app.core.media_uploads import upload_ledger
from app.core.moderation import ensure_allowed_content
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
    home_region: str
    avatar_url: str | None = None
    avatar_media_id: str | None = None
    cover_url: str | None = None
    cover_media_id: str | None = None


@router.get("/me")
def me(user=Depends(require_authenticated_user)):
    return user


@router.put("/me")
def update_me(payload: UpdateProfileRequest, user=Depends(require_authenticated_user)):
    display_name = payload.display_name.strip()
    handle = payload.handle.strip().lower().replace(" ", "")
    bio = payload.bio.strip()
    home_region = payload.home_region.strip()
    try:
        ensure_allowed_content(display_name, bio, home_region)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    if not display_name:
        raise HTTPException(status_code=400, detail="Display name is required")
    if len(display_name) > 32:
        raise HTTPException(
            status_code=400,
            detail="Display name must be 32 characters or fewer",
        )
    if not handle:
        raise HTTPException(status_code=400, detail="Handle is required")
    if handle.startswith("@"):
        handle = handle[1:]
    if len(handle) < 2:
        raise HTTPException(status_code=400, detail="Handle is too short")
    if len(handle) > 20:
        raise HTTPException(status_code=400, detail="Handle is too long")
    if not re.fullmatch(r"[a-z0-9_]+", handle):
        raise HTTPException(
            status_code=400,
            detail="Handle can only use letters, numbers, and underscores",
        )
    if store.handle_exists(handle):
        raise HTTPException(status_code=400, detail="That @tag is already taken")
    if len(bio) > 180:
        raise HTTPException(status_code=400, detail="Bio is too long")
    if payload.surf_skill not in {"", "beginner", "intermediate", "pro"}:
        raise HTTPException(status_code=400, detail="Surf skill is invalid")
    if len(home_region) > 40:
        raise HTTPException(status_code=400, detail="Location is too long")

    avatar_media_id = payload.avatar_media_id or upload_ledger.media_id_for_url(
        user.id,
        payload.avatar_url,
    )
    cover_media_id = payload.cover_media_id or upload_ledger.media_id_for_url(
        user.id,
        payload.cover_url,
    )
    new_media_ids: list[str] = []
    _validate_profile_media(
        user.id,
        avatar_media_id,
        payload.avatar_url,
        label="profile picture",
    )
    _validate_profile_media(
        user.id,
        cover_media_id,
        payload.cover_url,
        label="cover photo",
    )
    if avatar_media_id:
        new_media_ids.append(avatar_media_id)
    if cover_media_id:
        new_media_ids.append(cover_media_id)

    replaced_media_ids: list[str] = []
    if user.avatar_url != payload.avatar_url:
        old_avatar_id = upload_ledger.media_id_for_url(user.id, user.avatar_url)
        if old_avatar_id and old_avatar_id not in new_media_ids:
            replaced_media_ids.append(old_avatar_id)
    if user.cover_url != payload.cover_url:
        old_cover_id = upload_ledger.media_id_for_url(user.id, user.cover_url)
        if old_cover_id and old_cover_id not in new_media_ids:
            replaced_media_ids.append(old_cover_id)

    updated = store.update_profile(
        display_name=display_name,
        handle=handle,
        bio=bio,
        surf_skill=payload.surf_skill,
        home_region=home_region,
        avatar_url=payload.avatar_url,
        cover_url=payload.cover_url,
    )
    upload_ledger.mark_used(user.id, new_media_ids)
    queue_post_media_deletion(user.id, replaced_media_ids)
    return updated


def _validate_profile_media(
    user_id: str,
    media_id: str | None,
    url: str | None,
    *,
    label: str,
) -> None:
    if media_id is None:
        return
    if not url:
        raise HTTPException(status_code=400, detail=f"The {label} URL is missing.")
    reservation = upload_ledger.get(media_id, user_id)
    if reservation is None or reservation.status not in {"complete", "used"}:
        raise HTTPException(status_code=400, detail=f"The {label} upload is incomplete.")
    if reservation.media_type != "photo" or url not in {
        reservation.public_url,
        reservation.thumbnail_public_url,
    }:
        raise HTTPException(status_code=400, detail=f"The {label} upload does not match.")


@router.get("/dashboard")
def dashboard(_user=Depends(require_authenticated_user)):
    return store.get_dashboard()


@router.get("/favorites")
def favorites(_user=Depends(require_authenticated_user)):
    return list(store.list_favorite_spots())


@router.post("/favorites")
def add_favorite(
    payload: FavoriteSpotRequest,
    _user=Depends(require_authenticated_user),
):
    if store.get_spot(payload.spot_id) is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    favorite_spot_ids = store.add_favorite_spot(payload.spot_id)
    return {"favorite_spot_ids": favorite_spot_ids}


@router.delete("/favorites/{spot_id}")
def remove_favorite(spot_id: str, _user=Depends(require_authenticated_user)):
    favorite_spot_ids = store.remove_favorite_spot(spot_id)
    return {"favorite_spot_ids": favorite_spot_ids}


@router.post("/free-live-spot")
def set_free_live_spot(
    payload: FreeLiveSpotRequest,
    _user=Depends(require_authenticated_user),
):
    if store.get_spot(payload.spot_id) is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    try:
        user = store.set_free_live_spot(payload.spot_id)
    except ValueError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    return user
