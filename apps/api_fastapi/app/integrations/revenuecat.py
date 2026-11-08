from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import os
from urllib.parse import quote

import httpx
from fastapi import HTTPException

from app.core.models import User
from app.core.rate_limit import RateLimitRule, api_rate_limiter


class RevenueCatNotConfigured(RuntimeError):
    pass


class RevenueCatVerificationError(RuntimeError):
    pass


@dataclass(frozen=True)
class RevenueCatSubscription:
    active: bool
    expires_at: datetime | None = None
    management_url: str | None = None


def revenuecat_is_configured() -> bool:
    return bool(_server_api_key())


def _server_api_key() -> str:
    return (
        os.getenv("REVENUECAT_SECRET_API_KEY")
        or os.getenv("REVENUECAT_REST_API_KEY")
        or ""
    ).strip()


def revenuecat_entitlement_id() -> str:
    return os.getenv("REVENUECAT_ENTITLEMENT_ID", "premium").strip() or "premium"


async def fetch_revenuecat_entitlement_active(app_user_id: str) -> bool:
    return (await fetch_revenuecat_subscription(app_user_id)).active


async def fetch_revenuecat_subscription(app_user_id: str) -> RevenueCatSubscription:
    api_key = _server_api_key()
    if not api_key:
        raise RevenueCatNotConfigured("RevenueCat server API key is not configured.")

    safe_user_id = quote(app_user_id, safe="")
    url = f"https://api.revenuecat.com/v1/subscribers/{safe_user_id}"
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {api_key}",
    }

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(url, headers=headers)
    except httpx.HTTPError as error:
        raise RevenueCatVerificationError(
            "Subscription verification is temporarily unavailable."
        ) from error

    if response.status_code == 404:
        return RevenueCatSubscription(active=False)
    if response.status_code >= 400:
        raise RevenueCatVerificationError(
            f"RevenueCat verification failed with status {response.status_code}."
        )

    try:
        payload = response.json()
    except ValueError as error:
        raise RevenueCatVerificationError("Invalid subscription verification response.") from error
    if not isinstance(payload, dict):
        raise RevenueCatVerificationError("Invalid subscription verification response.")
    subscriber = payload.get("subscriber")
    if not isinstance(subscriber, dict):
        raise RevenueCatVerificationError("Invalid subscription verification response.")
    entitlements = subscriber.get("entitlements")
    if not isinstance(entitlements, dict):
        raise RevenueCatVerificationError("Invalid subscription verification response.")
    management_url = subscriber.get("management_url")
    if not isinstance(management_url, str) or not management_url.startswith("https://"):
        management_url = None
    entitlement = entitlements.get(revenuecat_entitlement_id())
    if not isinstance(entitlement, dict):
        return RevenueCatSubscription(active=False, management_url=management_url)

    expires_date = entitlement.get("expires_date")
    if expires_date is None:
        # A non-expiring entitlement still needs a real product identity.
        return RevenueCatSubscription(
            active=bool(entitlement.get("product_identifier")),
            management_url=management_url,
        )
    if not isinstance(expires_date, str) or not expires_date.strip():
        raise RevenueCatVerificationError("Invalid subscription expiration date.")

    try:
        expires_at = datetime.fromisoformat(expires_date.replace("Z", "+00:00"))
    except ValueError:
        raise RevenueCatVerificationError("Invalid subscription expiration date.")
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    grace_date = entitlement.get("grace_period_expires_date")
    if isinstance(grace_date, str):
        try:
            grace_at = datetime.fromisoformat(grace_date.replace("Z", "+00:00"))
            if grace_at.tzinfo is None:
                grace_at = grace_at.replace(tzinfo=timezone.utc)
            expires_at = max(expires_at, grace_at)
        except ValueError:
            pass
    return RevenueCatSubscription(
        active=expires_at > datetime.now(timezone.utc),
        expires_at=expires_at,
        management_url=management_url,
    )


async def refresh_subscription_if_stale(user: User) -> User:
    """Refresh on account reads, at most hourly; never turn an outage into a logout."""
    from app.core.store import store

    if not revenuecat_is_configured():
        return user
    checked_at = user.subscription_checked_at
    expired_since_check = (
        user.subscription_active is True
        and user.subscription_expires_at is not None
        and user.subscription_expires_at <= datetime.now(timezone.utc)
    )
    if (
        not expired_since_check
        and checked_at is not None
        and datetime.now(timezone.utc) - checked_at < timedelta(hours=1)
    ):
        return user
    try:
        api_rate_limiter.enforce(
            RateLimitRule(
                scope="billing:auto-check:user", key=user.id,
                limit=6, window_seconds=3600,
            )
        )
    except HTTPException:
        return user
    try:
        subscription = await fetch_revenuecat_subscription(user.id)
    except (RevenueCatNotConfigured, RevenueCatVerificationError):
        return user
    return store.set_user_subscription_status(user.id, subscription) or user
