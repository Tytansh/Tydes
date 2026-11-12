"""Authenticated, retry-safe RevenueCat notifications. No event grants access directly."""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import time

from fastapi import HTTPException, Request

from app.core.store import store
from app.integrations.revenuecat import (
    RevenueCatNotConfigured,
    RevenueCatVerificationError,
    fetch_revenuecat_subscription,
)

_delivery_lock = asyncio.Lock()
_MAX_BODY_BYTES = 64 * 1024


def _authenticate(request: Request, body: bytes) -> None:
    authorization = os.getenv("REVENUECAT_WEBHOOK_AUTHORIZATION", "").strip()
    signing_secret = os.getenv("REVENUECAT_WEBHOOK_SIGNING_SECRET", "").strip()
    if not authorization and not signing_secret:
        raise HTTPException(503, "Subscription notifications are not configured.")
    if authorization and not hmac.compare_digest(
        request.headers.get("authorization", "").encode(), authorization.encode()
    ):
        raise HTTPException(401, "Invalid subscription notification credentials.")
    if signing_secret:
        try:
            parts = dict(
                item.strip().split("=", 1)
                for item in request.headers.get("x-revenuecat-webhook-signature", "").split(",")
            )
            timestamp = parts["t"]
            if abs(time.time() - int(timestamp)) > 300:
                raise ValueError
            expected = hmac.new(
                signing_secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256
            ).hexdigest()
            if not hmac.compare_digest(expected, parts["v1"]):
                raise ValueError
        except (KeyError, ValueError):
            raise HTTPException(401, "Invalid subscription notification signature.") from None


def _target_ids(event: dict) -> list[str]:
    candidates = [event.get("app_user_id"), event.get("original_app_user_id")]
    for field in ("aliases", "transferred_from", "transferred_to"):
        values = event.get(field, [])
        if not isinstance(values, list):
            raise HTTPException(400, "Invalid subscription notification identities.")
        candidates.extend(values)
    if len(candidates) > 100:
        raise HTTPException(400, "Too many subscription notification identities.")
    # Anonymous RevenueCat IDs and unknown IDs cannot create TYDES accounts.
    return sorted({
        value for value in candidates
        if isinstance(value, str) and value.startswith("usr_") and len(value) <= 128
    })


async def revenuecat_webhook(request: Request) -> dict:
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > _MAX_BODY_BYTES:
            raise HTTPException(413, "Subscription notification is too large.")
    _authenticate(request, bytes(body))
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        raise HTTPException(400, "Invalid subscription notification.") from None
    event = payload.get("event") if isinstance(payload, dict) else None
    if not isinstance(event, dict):
        raise HTTPException(400, "Invalid subscription notification.")
    event_id = event.get("id")
    event_type = event.get("type")
    if not isinstance(event_id, str) or not 1 <= len(event_id) <= 200 or not isinstance(event_type, str):
        raise HTTPException(400, "Invalid subscription notification identity.")
    if event_type == "TEST":
        return {"status": "test_received"}
    environments = {
        item.strip() for item in os.getenv("REVENUECAT_WEBHOOK_ENVIRONMENTS", "PRODUCTION").split(",")
    }
    if event.get("environment") not in environments:
        return {"status": "ignored_environment"}
    target_ids = _target_ids(event)
    if len(target_ids) > 10:
        raise HTTPException(400, "Too many subscription notification targets.")
    try:
        # Keep below RevenueCat's delivery timeout. Failure is retried rather
        # than acknowledged and lost in an in-memory background task.
        async with asyncio.timeout(25):
            async with _delivery_lock:
                if await asyncio.to_thread(store.billing_event_completed, event_id):
                    return {"status": "already_processed"}
                for user_id in target_ids:
                    user = await asyncio.to_thread(store.get_auth_user_by_id, user_id)
                    if user is None:
                        continue
                    # Fetch current state, not event flags/dates: cancellation
                    # can retain paid access and out-of-order refunds/renewals
                    # must not overwrite a newer entitlement.
                    subscription = await fetch_revenuecat_subscription(user_id)
                    await asyncio.to_thread(store.set_user_subscription_status, user_id, subscription)
                await asyncio.to_thread(store.complete_billing_event, event_id)
    except (RevenueCatNotConfigured, RevenueCatVerificationError, TimeoutError):
        raise HTTPException(503, "Subscription notification verification is temporarily unavailable.") from None
    return {"status": "processed"}
