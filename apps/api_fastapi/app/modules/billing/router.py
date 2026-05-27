from fastapi import APIRouter, HTTPException

from app.core.store import store
from app.integrations.revenuecat import (
    RevenueCatNotConfigured,
    RevenueCatVerificationError,
    fetch_revenuecat_entitlement_active,
    revenuecat_entitlement_id,
)

router = APIRouter(prefix="/billing", tags=["billing"])


@router.get("/plans")
def list_plans():
    return list(store.list_plans())


@router.post("/sync-revenuecat")
async def sync_revenuecat_entitlement():
    try:
        premium_active = await fetch_revenuecat_entitlement_active(store.user.id)
    except RevenueCatNotConfigured as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    except RevenueCatVerificationError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error

    user = store.set_premium_status(premium_active)
    return {
        "entitlement_id": revenuecat_entitlement_id(),
        "premium": user.premium,
        "user": user,
    }
