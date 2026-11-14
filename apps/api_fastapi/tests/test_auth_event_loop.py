"""Blocking session/database lookups must not run on the ASGI event loop."""
import asyncio
import importlib
import os
from pathlib import Path
import sys
import tempfile
import threading

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-auth-loop-"))

from app.core.store import store
from app.main import app


def test_session_lookup_runs_off_event_loop_and_keeps_invalid_session_rejected(monkeypatch):
    lookup_threads = []

    def resolve(_token):
        lookup_threads.append(threading.get_ident())
        return None

    monkeypatch.setattr(store, "resolve_session_user", resolve)

    async def scenario():
        loop_thread = threading.get_ident()
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://test.invalid",
        ) as client:
            response = await client.get(
                "/api/v1/forecasts/detail?spot_id=spot_balangan",
                headers={"Authorization": "Bearer invalid-test-session"},
            )
        assert response.status_code == 401
        assert response.headers["Cache-Control"] == "private, no-store"
        assert lookup_threads and all(thread != loop_thread for thread in lookup_threads)

    asyncio.run(scenario())


def test_concurrent_offloaded_lookups_keep_request_identity_and_verification(monkeypatch):
    base = store.user.model_copy(deep=True)
    users = {
        token: base.model_copy(update={
            "id": token,
            "email": f"{token}@example.invalid",
            "email_verified": token != "unverified",
            "banned": False,
        })
        for token in ("first", "second", "unverified")
    }
    monkeypatch.setattr(store, "resolve_session_user", users.get)
    users_router = importlib.import_module("app.modules.users.router")

    async def unchanged_subscription(user):
        await asyncio.sleep(0)
        return user

    monkeypatch.setattr(users_router, "refresh_subscription_if_stale", unchanged_subscription)

    async def scenario():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://test.invalid",
        ) as client:
            first, second, unverified = await asyncio.gather(
                client.get("/api/v1/users/me", headers={"Authorization": "Bearer first"}),
                client.get("/api/v1/users/me", headers={"Authorization": "Bearer second"}),
                client.get("/api/v1/forecasts/detail?spot_id=spot_balangan", headers={
                    "Authorization": "Bearer unverified",
                }),
            )
        assert first.status_code == second.status_code == 200
        assert first.json()["id"] == "first"
        assert second.json()["id"] == "second"
        assert unverified.status_code == 403
        assert unverified.json()["detail"]["code"] == "email_verification_required"

    asyncio.run(scenario())
