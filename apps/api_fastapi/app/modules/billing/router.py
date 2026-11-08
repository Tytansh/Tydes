import os

from fastapi import APIRouter, Depends, HTTPException

from app.core.auth import require_authenticated_user
from app.core.rate_limit import RateLimitRule, api_rate_limiter
from app.core.store import store
from app.modules.billing.webhook import revenuecat_webhook
from app.integrations.revenuecat import (
    RevenueCatNotConfigured,
    RevenueCatVerificationError,
    fetch_revenuecat_subscription,
    revenuecat_entitlement_id,
    refresh_subscription_if_stale,
    revenuecat_is_configured,
)

router = APIRouter(prefix="/billing", tags=["billing"])
router.add_api_route("/webhooks/revenuecat", revenuecat_webhook, methods=["POST"])


@router.get("/plans")
def list_plans():
    return list(store.list_plans())


@router.get("/config")
def billing_config(user=Depends(require_authenticated_user)):
    # This endpoint returns public SDK identifiers only, never a REST/secret key.
    web_key = os.getenv("REVENUECAT_WEB_API_KEY", "").strip()
    enabled = os.getenv("REVENUECAT_WEB_CHECKOUT_ENABLED", "").lower() == "true"
    test_users = {
        item.strip() for item in os.getenv("REVENUECAT_WEB_CHECKOUT_USER_IDS", "").split(",")
        if item.strip()
    }
    # Installing a key must never silently open purchases to everyone.
    enabled = enabled or user.id in test_users
    # Stripe Billing configurations use strp_; RevenueCat Billing uses rcb_.
    if not web_key.startswith(("rcb_", "strp_")) or not enabled:
        web_key = ""
    return {
        "web_api_key": web_key,
        "web_enabled": bool(web_key) and revenuecat_is_configured(),
        "verification_ready": revenuecat_is_configured(),
    }


@router.get("/management")
async def subscription_management(user=Depends(require_authenticated_user)):
    user = await refresh_subscription_if_stale(user)
    return {"url": user.subscription_management_url}


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
        subscription = await fetch_revenuecat_subscription(user.id)
    except RevenueCatNotConfigured as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    except RevenueCatVerificationError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error

    user = store.set_user_subscription_status(user.id, subscription)
    if user is None:
        raise HTTPException(status_code=401, detail="Account is no longer available.")
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
