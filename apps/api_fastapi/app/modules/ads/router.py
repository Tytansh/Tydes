from fastapi import APIRouter

from app.core.store import store

router = APIRouter(prefix="/ads", tags=["ads"])


@router.get("")
def list_ads(placement: str | None = None):
    return list(store.list_ads(placement))

