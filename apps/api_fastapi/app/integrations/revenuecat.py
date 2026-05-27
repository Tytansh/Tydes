from __future__ import annotations

from datetime import datetime, timezone
import os
from urllib.parse import quote

import httpx


class RevenueCatNotConfigured(RuntimeError):
    pass


class RevenueCatVerificationError(RuntimeError):
    pass


def revenuecat_entitlement_id() -> str:
    return os.getenv("REVENUECAT_ENTITLEMENT_ID", "premium").strip() or "premium"


async def fetch_revenuecat_entitlement_active(app_user_id: str) -> bool:
    api_key = (
        os.getenv("REVENUECAT_SECRET_API_KEY")
        or os.getenv("REVENUECAT_REST_API_KEY")
        or ""
    ).strip()
    if not api_key:
        raise RevenueCatNotConfigured("RevenueCat server API key is not configured.")

    safe_user_id = quote(app_user_id, safe="")
    url = f"https://api.revenuecat.com/v1/subscribers/{safe_user_id}"
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {api_key}",
    }

    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.get(url, headers=headers)

    if response.status_code == 404:
        return False
    if response.status_code >= 400:
        raise RevenueCatVerificationError(
            f"RevenueCat verification failed with status {response.status_code}."
        )

    payload = response.json()
    subscriber = payload.get("subscriber")
    if not isinstance(subscriber, dict):
        return False
    entitlements = subscriber.get("entitlements")
    if not isinstance(entitlements, dict):
        return False
    entitlement = entitlements.get(revenuecat_entitlement_id())
    if not isinstance(entitlement, dict):
        return False

    expires_date = entitlement.get("expires_date")
    if expires_date is None:
        return True
    if not isinstance(expires_date, str) or not expires_date.strip():
        return False

    try:
        expires_at = datetime.fromisoformat(expires_date.replace("Z", "+00:00"))
    except ValueError:
        return False
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    return expires_at > datetime.now(timezone.utc)
