"""Basic model wave outlooks reuse fixture upstreams; never spend API credits."""
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-basic-forecast-"))

from app.core.models import BasicSpotForecast, build_estimated_forecasts
from app.core.persistent_cache import CachedJson
from app.core.rate_limit import api_rate_limiter
from app.core.store import store
from app.main import app
from test_forecast_reliability import _provider, _timeout


def test_basic_reuses_daily_detail_cache_snapshot_mean_and_real_timestamp(monkeypatch):
    provider, marine, _, calls, reservations = _provider(monkeypatch)
    spot = store.spots[0]
    marine["hourly"]["wave_height"][:24] = [1.0] * 12 + [2.0] * 12
    detail = provider.fetch_spot_detail(spot)
    cached = provider._cache[provider._cache_identity(spot)]
    first = provider.fetch_spot_basic(spot)
    again = provider.fetch_spot_basic(spot)
    assert first.available and first.source == "open-meteo"
    assert first.fetched_at == again.fetched_at == detail.fetched_at == cached.fetched_at
    assert first.timezone == "Asia/Makassar" and first.utc_offset_seconds == 28800
    assert first.local_date == datetime.now(ZoneInfo(first.timezone)).date()
    assert first.days[0].wave_height_m == 1.5
    assert len(first.days) == 5 and first.marine_model == "Best Match (automatic)"
    assert "Daily mean significant combined sea height" in first.note
    assert "not breaking-wave face height" in first.note
    assert len(calls) == 2 and reservations == [3]
    assert set(first.model_dump()) == {"spot_id", "available", "source", "marine_model", "weather_model", "timezone", "utc_offset_seconds", "fetched_at", "local_date", "note", "days"}
    assert set(first.days[0].model_dump()) == {"day", "wave_height_m", "wind_kts", "wind_direction_deg", "wind_direction_status", "sea_surface_temperature_c", "sunrise_local", "sunset_local"}


def test_basic_concurrent_requests_share_existing_singleflight_and_budget(monkeypatch):
    provider, _, _, calls, reservations = _provider(monkeypatch)
    spot = store.spots[0]
    with ThreadPoolExecutor(max_workers=6) as pool:
        values = list(pool.map(lambda _: provider.fetch_spot_basic(spot), range(6)))
    assert all(value.available for value in values)
    assert len({value.fetched_at for value in values}) == 1
    assert len(calls) == 2 and reservations == [3]


def test_basic_refreshes_same_calendar_snapshot_older_than_output_freshness(monkeypatch):
    provider, _, _, calls, reservations = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_basic(spot)
    cached = provider._cache[provider._cache_identity(spot)]
    cached.fetched_at = datetime.now(UTC) - timedelta(hours=25)
    result = provider.fetch_spot_basic(spot)
    assert result.available and result.fetched_at > cached.fetched_at
    assert datetime.now(UTC) - result.fetched_at < timedelta(minutes=1)
    assert len(calls) == 4 and reservations == [3, 3]


def test_basic_restart_cache_reuse_and_coordinate_correction(monkeypatch):
    provider, _, _, calls, reservations = _provider(monkeypatch)
    spot = store.spots[0]
    first = provider.fetch_spot_basic(spot)
    snapshot = provider._cache[provider._cache_identity(spot)]
    payload = {"forecasts": [entry.model_dump(mode="json") for entry in snapshot.data],
               "hourly_rows": snapshot.hourly_rows, "timezone": snapshot.timezone,
               "utc_offset_seconds": snapshot.utc_offset_seconds}
    key = f"open-meteo:v3:{provider._cache_identity(spot)}"
    provider._cache.clear()
    provider._persistent_cache = SimpleNamespace(
        get=lambda identity, _age: CachedJson(payload=payload, updated_at=first.fetched_at) if identity == key else None,
        set=lambda *_: None,
    )
    assert provider.fetch_spot_basic(spot).fetched_at == first.fetched_at
    assert len(calls) == 2 and reservations == [3]
    corrected = spot.model_copy(update={"latitude": spot.latitude - 0.01})
    assert provider.fetch_spot_basic(corrected).available
    assert len(calls) == 4 and reservations == [3, 3]
    assert calls[-2][1]["latitude"] == corrected.latitude


def test_basic_outage_uses_only_current_remaining_model_days_and_old_fetch_time(monkeypatch):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_basic(spot)
    item = provider._cache[provider._cache_identity(spot)]
    item.fetched_at = datetime.now(UTC) - timedelta(hours=4)
    for entry in item.data:
        entry.day -= timedelta(days=1)
    for row in item.hourly_rows:
        for key in ("time", "time_utc"):
            row[key] = (datetime.fromisoformat(row[key]) - timedelta(days=1)).isoformat()
        row["day"] = datetime.fromisoformat(row["time"]).date().isoformat()
    provider._marine_client = SimpleNamespace(get=_timeout)
    basic = provider.fetch_spot_basic(spot)
    assert basic.available and basic.fetched_at == item.fetched_at
    assert "previously fetched" in basic.note
    assert basic.local_date == datetime.now(ZoneInfo(basic.timezone)).date()
    assert len(basic.days) == 4
    assert min(row.day for row in basic.days) == basic.local_date


@pytest.mark.parametrize("invalid", [None, float("nan"), float("inf"), -1.0])
def test_basic_never_converts_missing_or_invalid_waves_to_calm(monkeypatch, invalid):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_basic(spot)
    for entry in provider._cache[provider._cache_identity(spot)].data:
        entry.wave_height_m = invalid
    with pytest.raises(ValueError):
        provider.fetch_spot_basic(spot)


@pytest.mark.parametrize("bad_snapshot", ["static", "wrong-spot", "too-old", "future", "naive", "bad-zone", "duplicate"])
def test_basic_rejects_bad_snapshot_provenance_time_and_calendar(monkeypatch, bad_snapshot):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_basic(spot)
    item = provider._cache[provider._cache_identity(spot)]
    # Inspect the snapshot validator independently of upstream refresh behavior.
    monkeypatch.setattr(provider, "fetch_spot_forecast", lambda *_args, **_kwargs: item.data)
    if bad_snapshot == "static":
        item.data = build_estimated_forecasts(spot, datetime.now(ZoneInfo(item.timezone)).date())
    elif bad_snapshot == "wrong-spot":
        item.data[0].spot_id = "another-spot"
    elif bad_snapshot == "too-old":
        item.fetched_at = datetime.now(UTC) - timedelta(hours=25)
    elif bad_snapshot == "future":
        item.fetched_at = datetime.now(UTC) + timedelta(hours=1)
    elif bad_snapshot == "naive":
        item.fetched_at = datetime.now()
    elif bad_snapshot == "bad-zone":
        item.timezone = "not-a-real-zone"
    elif bad_snapshot == "duplicate":
        item.data.append(item.data[0])
    with pytest.raises((ValueError, KeyError)):
        provider.fetch_spot_basic(spot)


def test_basic_unchanged_budget_exhaustion_blocks_network_without_static_fallback(monkeypatch):
    provider, _, _, calls, _ = _provider(monkeypatch)
    def exhausted():
        raise HTTPException(429, "fixture upstream budget exhausted")
    monkeypatch.setattr(provider, "_reserve_upstream_budget", exhausted)
    monkeypatch.setattr(store, "weather_provider", provider)
    result = store.get_basic_forecast(store.spots[0].id)
    assert not result.available and result.source == "unavailable" and result.days == []
    assert result.fetched_at is None and calls == []


def test_store_rejects_malformed_provider_payloads_without_legacy_estimates(monkeypatch):
    spot = store.spots[0]
    provider, _, _, _, _ = _provider(monkeypatch)
    valid = provider.fetch_spot_basic(spot).model_dump()
    for change in ({"source": "estimated"}, {"fetched_at": None}, {"spot_id": "another"}, {"days": []}, {"wave_height_m": 2.0}):
        monkeypatch.setattr(store, "weather_provider", SimpleNamespace(fetch_spot_basic=lambda _spot: {**valid, **change}))
        result = store.get_basic_forecast(spot.id)
        assert not result.available and result.days == [] and result.source == "unavailable"


def test_basic_requires_verified_auth_but_all_spots_allowed_without_expanding_full_gates(monkeypatch):
    user = store.user.model_copy(update={"premium": False, "email_verified": True, "free_live_spot_id": None})
    monkeypatch.setattr(store, "resolve_session_user", lambda token: user if token == "basic-token" else None)
    provider, _, _, calls, _ = _provider(monkeypatch)
    monkeypatch.setattr(store, "weather_provider", provider)
    monkeypatch.setattr(store, "tide_provider", SimpleNamespace(fetch_spot_tides=lambda *_args, **_kwargs: pytest.fail("Basic outlook must not fetch tides")))
    api_rate_limiter.clear()
    client = TestClient(app)
    params = {"spot_id": store.spots[0].id}
    assert client.get("/api/v1/forecasts/basic", params=params).status_code == 401
    headers = {"Authorization": "Bearer basic-token"}
    user.email_verified = False
    assert client.get("/api/v1/forecasts/basic", params=params, headers=headers).status_code == 403
    user.email_verified = True
    for premium in (False, True):
        user.premium = premium
        for spot in store.spots[:2]:
            response = client.get("/api/v1/forecasts/basic", params={"spot_id": spot.id}, headers=headers)
            assert response.status_code == 200 and response.json()["available"]
            assert response.headers["cache-control"] == "private, no-store"
            assert response.json()["source"] == "open-meteo"
    assert len(calls) == 4  # Two visited spots, no catalog-wide fanout.
    user.premium = False
    assert not client.get("/api/v1/forecasts/detail", params=params, headers=headers).json()["available"]
    assert not client.get("/api/v1/forecasts/tides", params=params, headers=headers).json()["available"]
    assert not client.get("/api/v1/forecasts/surf-window", params=params, headers=headers).json()["available"]
    assert len(calls) == 4
    assert client.get("/api/v1/forecasts/basic", params={"spot_id": "unknown"}, headers=headers).status_code == 404
    api_rate_limiter.clear()
