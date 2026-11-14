"""Forecast recovery tests use isolated fixtures, never upstream credits."""
from datetime import UTC, datetime, timedelta
from pathlib import Path
import sys
from threading import Event
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.persistent_cache import CachedJson
from app.core.store import store
from app.integrations.weather_providers.open_meteo import (
    MARINE_VARIABLES, OpenMeteoMarineProvider, spot_timezone_name,
)


def _payloads(zone_name="Asia/Makassar"):
    zone = ZoneInfo(zone_name)
    midnight = datetime.now(zone).replace(hour=0, minute=0, second=0, microsecond=0)
    stamps = [int((midnight + timedelta(hours=i)).timestamp()) for i in range(120)]
    marine = {
        "timezone": zone_name,
        "utc_offset_seconds": int(midnight.utcoffset().total_seconds()),
        "hourly": {"time": stamps, **{key: [None] * 120 for key in MARINE_VARIABLES}},
    }
    marine["hourly"].update({"wave_height": [1.5] * 120, "wave_period": [12.0] * 120})
    weather = {
        "timezone": zone_name,
        "hourly": {"time": stamps, "wind_speed_10m": [8.0] * 120,
                   "wind_direction_10m": [90.0] * 120, "wind_gusts_10m": [11.0] * 120,
                   "is_day": [float(6 <= i % 24 < 18) for i in range(120)]},
    }
    return marine, weather


def _response(payload):
    return SimpleNamespace(raise_for_status=lambda: None, json=lambda: payload)


def _provider(monkeypatch, zone_name="Asia/Makassar"):
    provider = OpenMeteoMarineProvider()
    provider._persistent_cache = None
    marine, weather = _payloads(zone_name)
    calls, reservations = [], []
    provider._marine_client = SimpleNamespace(get=lambda *_args, **kwargs: (calls.append(("marine", kwargs["params"])), _response(marine))[1])
    provider._forecast_client = SimpleNamespace(get=lambda *_args, **kwargs: (calls.append(("weather", kwargs["params"])), _response(weather))[1])
    monkeypatch.setattr(provider, "_reserve_upstream_budget", lambda: reservations.append(3))
    monkeypatch.setattr(provider, "_reserve_budget_units", lambda units: reservations.append(units))
    return provider, marine, weather, calls, reservations


def _timeout(*_args, **_kwargs):
    raise httpx.ReadTimeout("fixture timeout")


def test_wind_outage_keeps_real_wave_chart_without_inventing_calm_wind(monkeypatch):
    provider, _, _, calls, reservations = _provider(monkeypatch)
    provider._forecast_client = SimpleNamespace(get=_timeout)
    detail = provider.fetch_spot_detail(store.spots[0])
    assert detail.available and len(detail.hours) == 120
    assert detail.hours[0].wave_height_m == 1.5
    assert all(hour.wind_kts is None for hour in detail.hours)
    assert detail.weather_model == "Temporarily unavailable"
    assert "Wind and daylight data are temporarily unavailable" in detail.note
    assert reservations == [3, 1]
    provider.fetch_spot_detail(store.spots[0])
    assert len(calls) == 1  # Three simultaneous UI panels share the partial result too.


def test_transient_marine_timeout_retries_once_and_reserves_its_cost(monkeypatch):
    provider, marine, _, _, reservations = _provider(monkeypatch)
    attempts = []
    def get(*_args, **_kwargs):
        attempts.append(1)
        if len(attempts) == 1:
            raise httpx.ReadTimeout("fixture timeout")
        return _response(marine)
    provider._marine_client = SimpleNamespace(get=get)
    assert provider.fetch_spot_detail(store.spots[0]).available
    assert len(attempts) == 2
    assert reservations == [3, 2]


def test_rate_limit_is_not_retried_and_recovery_never_bypasses_budget(monkeypatch):
    provider, _, _, _, reservations = _provider(monkeypatch)
    attempts = []
    def get(*_args, **_kwargs):
        attempts.append(1)
        request = httpx.Request("GET", "https://fixture.invalid/marine")
        raise httpx.HTTPStatusError("fixture rate limit", request=request, response=httpx.Response(429, request=request))
    provider._marine_client = SimpleNamespace(get=get)
    with pytest.raises(httpx.HTTPStatusError):
        provider.fetch_spot_detail(store.spots[0])
    with pytest.raises(RuntimeError, match="backing off"):
        provider.fetch_spot_detail(store.spots[0])
    assert len(attempts) == 1 and reservations == [3]


def test_wave_and_wind_requests_start_independently_not_serially(monkeypatch):
    provider, marine, weather, _, _ = _provider(monkeypatch)
    marine_started, weather_started = Event(), Event()
    def get_marine(*_args, **_kwargs):
        marine_started.set()
        assert weather_started.wait(2)
        return _response(marine)
    def get_weather(*_args, **_kwargs):
        weather_started.set()
        assert marine_started.wait(2)
        return _response(weather)
    provider._marine_client = SimpleNamespace(get=get_marine)
    provider._forecast_client = SimpleNamespace(get=get_weather)
    assert provider.fetch_spot_detail(store.spots[0]).available


def test_recent_valid_cache_survives_provider_outage_but_is_labelled_cached(monkeypatch):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_detail(spot)
    cached = provider._cache[provider._cache_identity(spot)]
    cached.fetched_at = datetime.now(UTC) - timedelta(hours=4)
    provider._marine_client = SimpleNamespace(get=_timeout)
    detail = provider.fetch_spot_detail(spot)
    assert detail.available and detail.fetched_at == cached.fetched_at
    assert "previously fetched" in detail.note
    assert all(hour.local_date >= detail.local_date for hour in detail.hours)
    forecasts = provider.fetch_spot_forecast(spot)
    assert forecasts and all(item.confidence == "estimated" for item in forecasts)
    assert provider.fetch_spot_surf_window(spot).confidence == "estimated"


@pytest.mark.parametrize("age", [timedelta(hours=13), -timedelta(hours=1)])
def test_out_of_bounds_cache_never_substitutes_current_forecast(monkeypatch, age):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_detail(spot)
    provider._cache[provider._cache_identity(spot)].fetched_at = datetime.now(UTC) - age
    provider._marine_client = SimpleNamespace(get=_timeout)
    with pytest.raises(httpx.ReadTimeout):
        provider.fetch_spot_detail(spot)


def test_restart_safe_recent_cache_can_recover_when_upstream_is_down(monkeypatch):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_detail(spot)
    item = provider._cache[provider._cache_identity(spot)]
    cached_at = datetime.now(UTC) - timedelta(hours=4)
    payload = {
        "forecasts": [entry.model_dump(mode="json") for entry in item.data],
        "hourly_rows": item.hourly_rows, "timezone": item.timezone,
        "utc_offset_seconds": item.utc_offset_seconds,
    }
    provider._cache.clear()
    provider._persistent_cache = SimpleNamespace(get=lambda _key, age: CachedJson(payload=payload, updated_at=cached_at) if age >= timedelta(hours=4) else None)
    provider._marine_client = SimpleNamespace(get=_timeout)
    detail = provider.fetch_spot_detail(spot)
    assert detail.available and detail.fetched_at == cached_at
    assert "previously fetched" in detail.note


def test_outage_fallback_never_relabels_yesterdays_rows_as_today(monkeypatch):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_detail(spot)
    item = provider._cache[provider._cache_identity(spot)]
    item.fetched_at = datetime.now(UTC) - timedelta(hours=4)
    for row in item.hourly_rows:
        for key in ("time", "time_utc"):
            row[key] = (datetime.fromisoformat(row[key]) - timedelta(days=1)).isoformat()
        row["day"] = (datetime.fromisoformat(row["time"]).date()).isoformat()
    for entry in item.data:
        entry.day -= timedelta(days=1)
    provider._marine_client = SimpleNamespace(get=_timeout)
    detail = provider.fetch_spot_detail(spot)
    assert detail.available and len(detail.hours) == 96
    assert min(hour.local_date for hour in detail.hours) == detail.local_date
    assert detail.fetched_at == item.fetched_at


@pytest.mark.parametrize("invalid", [None, float("nan"), float("inf")])
def test_fallback_requires_real_finite_wave_samples(monkeypatch, invalid):
    provider, _, _, _, _ = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_detail(spot)
    item = provider._cache[provider._cache_identity(spot)]
    item.fetched_at = datetime.now(UTC) - timedelta(hours=4)
    for row in item.hourly_rows:
        row["wave_height"] = invalid
    provider._marine_client = SimpleNamespace(get=_timeout)
    with pytest.raises(httpx.ReadTimeout):
        provider.fetch_spot_detail(spot)


@pytest.mark.parametrize("country", ["Indonesia", "Australia", "Taiwan", "Philippines", "Sri Lanka", "Thailand"])
def test_reliability_path_uses_each_country_current_local_day(monkeypatch, country):
    spot = next(spot for spot in store.spots if spot.country == country)
    zone_name = spot_timezone_name(spot)
    provider, _, _, calls, _ = _provider(monkeypatch, zone_name)
    detail = provider.fetch_spot_detail(spot)
    assert detail.available and len(detail.hours) == 120
    assert detail.local_date == datetime.now(ZoneInfo(zone_name)).date()
    assert detail.timezone == zone_name
    assert all(params["latitude"] == spot.latitude and params["longitude"] == spot.longitude for _, params in calls)
