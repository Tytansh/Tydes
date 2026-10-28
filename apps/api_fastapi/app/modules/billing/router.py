import os

from fastapi import APIRouter, Depends, HTTPException

from app.core.auth import require_authenticated_user
from app.core.rate_limit import RateLimitRule, api_rate_limiter
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
async def sync_revenuecat_entitlement(user=Depends(require_authenticated_user)):
    api_rate_limiter.enforce(
        RateLimitRule(
            scope="billing:sync-revenuecat:user",
            key=user.id,
            limit=_positive_env("REVENUECAT_SYNCS_PER_USER_HOUR", 30),
            window_seconds=60 * 60,
        )
    )
    try:
        premium_active = await fetch_revenuecat_entitlement_active(user.id)
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


def _positive_env(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default
