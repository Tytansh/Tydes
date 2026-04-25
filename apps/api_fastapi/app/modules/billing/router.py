from fastapi import APIRouter

from app.core.store import store

router = APIRouter(prefix="/billing", tags=["billing"])


@router.get("/plans")
def list_plans():
    return list(store.list_plans())

