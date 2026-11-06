import asyncio
from datetime import datetime, timedelta, timezone
import sys
from pathlib import Path

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.integrations import revenuecat


def verify(monkeypatch, payload, status=200):
    monkeypatch.setenv("REVENUECAT_SECRET_API_KEY", "test-server-secret")

    class Client:
        def __init__(self, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def get(self, url, headers):
            assert url.endswith("/subscribers/usr_test")
            assert headers["Authorization"] == "Bearer test-server-secret"
            return httpx.Response(status, json=payload)

    monkeypatch.setattr(revenuecat.httpx, "AsyncClient", Client)
    return asyncio.run(revenuecat.fetch_revenuecat_subscription("usr_test"))


def subscriber(entitlement):
    return {"subscriber": {"entitlements": {"premium": entitlement}, "management_url": "https://apps.apple.com/account/subscriptions"}}


def test_verified_subscription_expiration_and_management(monkeypatch):
    expiration = datetime.now(timezone.utc) + timedelta(days=20)
    result = verify(monkeypatch, subscriber({"product_identifier": "tydes_premium_monthly", "expires_date": expiration.isoformat()}))
    assert result.active
    assert result.expires_at == expiration
    assert result.management_url == "https://apps.apple.com/account/subscriptions"


def test_expired_and_grace_period_subscription(monkeypatch):
    yesterday = datetime.now(timezone.utc) - timedelta(days=1)
    tomorrow = datetime.now(timezone.utc) + timedelta(days=1)
    entitlement = {"product_identifier": "tydes_premium_monthly", "expires_date": yesterday.isoformat()}
    assert not verify(monkeypatch, subscriber(entitlement)).active
    entitlement["grace_period_expires_date"] = tomorrow.isoformat()
    result = verify(monkeypatch, subscriber(entitlement))
    assert result.active and result.expires_at == tomorrow


def test_no_product_or_entitlement_never_grants_premium(monkeypatch):
    assert not verify(monkeypatch, subscriber({})).active
    assert not verify(monkeypatch, {"subscriber": {"entitlements": {}}}).active
    assert not verify(monkeypatch, {}, status=404).active


@pytest.mark.parametrize("payload", [{}, [], {"subscriber": {}}, subscriber({"expires_date": "invalid"})])
def test_invalid_response_fails_without_overwriting_paid_access(monkeypatch, payload):
    with pytest.raises(revenuecat.RevenueCatVerificationError):
        verify(monkeypatch, payload)


def test_non_https_management_url_is_not_returned(monkeypatch):
    payload = subscriber({"product_identifier": "lifetime", "expires_date": None})
    payload["subscriber"]["management_url"] = "javascript:alert(1)"
    result = verify(monkeypatch, payload)
    assert result.active and result.management_url is None
