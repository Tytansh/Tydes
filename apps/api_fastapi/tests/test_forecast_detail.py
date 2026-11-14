"""Provider fixtures only: these tests never spend upstream API credits."""
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-forecast-tests-"))

from app.main import app
from app.core.models import DetailedSpotForecast
from app.core.store import store
from app.integrations.tide_providers.tidecheck import TideCheckProvider
from app.integrations.weather_providers.open_meteo import (
    MARINE_VARIABLES, OpenMeteoMarineProvider,
    _best_surf_window,
)


def _payloads():
    zone = ZoneInfo("Asia/Makassar")
    midnight = datetime.now(zone).replace(hour=0, minute=0, second=0, microsecond=0)
    stamps = [int((midnight + timedelta(hours=hour)).timestamp()) for hour in range(120)]
    marine = {
        "timezone": "Asia/Makassar", "utc_offset_seconds": 28800,
        "hourly": {"time": stamps, **{name: [None] * 120 for name in MARINE_VARIABLES}},
    }
    marine["hourly"].update({
        "wave_height": [1.5] * 120, "wave_period": [10.5] * 120,
        "wave_direction": [220.0] * 120, "swell_wave_height": [1.3] * 120,
        "swell_wave_period": [12.0] * 120, "swell_wave_peak_period": [15.0] * 120,
        "swell_wave_direction": [225.0] * 120,
    })
    weather = {
        "timezone": "Asia/Makassar", "utc_offset_seconds": 28800,
        "hourly": {
            "time": stamps, "wind_speed_10m": [7.0] * 120,
            "wind_gusts_10m": [11.0] * 120, "wind_direction_10m": [90.0] * 120,
            "is_day": [int(6 <= hour % 24 < 18) for hour in range(120)],
        },
        "daily": {
            "time": [int((midnight + timedelta(days=day)).timestamp()) for day in range(5)],
            "sunrise": [int((midnight + timedelta(days=day, hours=6)).timestamp()) for day in range(5)],
            "sunset": [int((midnight + timedelta(days=day, hours=18)).timestamp()) for day in range(5)],
        },
    }
    return marine, weather


def _provider(monkeypatch, *, delay=0):
    provider = OpenMeteoMarineProvider()
    marine, weather = _payloads()
    calls = []
    def get(kind, payload, **kwargs):
        if delay:
            time.sleep(delay)
        calls.append((kind, kwargs["params"]))
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: payload)
    provider._persistent_cache = None
    provider._marine_client = SimpleNamespace(get=lambda path, **kwargs: get("marine", marine, **kwargs))
    provider._forecast_client = SimpleNamespace(get=lambda path, **kwargs: get("weather", weather, **kwargs))
    monkeypatch.setattr(provider, "_reserve_upstream_budget", lambda: None)
    return provider, marine, weather, calls


def test_detail_preserves_nulls_and_exact_provider_components(monkeypatch):
    provider, marine, weather, calls = _provider(monkeypatch)
    weather["hourly"]["wind_speed_10m"][0] = None
    marine["hourly"]["sea_surface_temperature"][0] = float("nan")
    detail = provider.fetch_spot_detail(store.spots[0])
    assert detail.available and len(detail.hours) == 120 and len(detail.days) == 5
    assert detail.timezone == "Asia/Makassar" and detail.utc_offset_seconds == 28800
    assert detail.fetched_at.tzinfo == UTC
    assert detail.hours[0].time.hour == 16  # midnight in Bali is the previous UTC day
    assert detail.hours[0].local_time == "00:00"
    assert detail.hours[0].swell_period_s == 12.0
    assert detail.hours[0].swell_peak_period_s == 15.0
    assert detail.hours[0].wind_kts is None
    assert detail.hours[0].secondary_swell_height_m is None
    assert detail.hours[0].sea_surface_temperature_c is None
    assert detail.hours[1].wind_gusts_kts == 11.0
    assert detail.hours[1].wind_direction_deg == 90.0
    assert detail.days[0].sunrise.endswith("06:00:00+08:00")
    assert "not breaking-wave face height" in detail.note
    assert detail.marine_model == "Best Match (automatic)"
    assert len(calls) == 2
    assert calls[0][1]["forecast_days"] == 5
    assert calls[0][1]["timeformat"] == "unixtime"


def test_hourly_and_daily_views_share_single_flight_cache(monkeypatch):
    provider, _, _, calls = _provider(monkeypatch, delay=0.01)
    spot = store.spots[0]
    with ThreadPoolExecutor(max_workers=6) as pool:
        details = list(pool.map(lambda _: provider.fetch_spot_detail(spot), range(6)))
    provider.fetch_spot_forecast(spot)
    provider.fetch_spot_surf_window(spot)
    assert all(detail.available for detail in details)
    assert len(calls) == 2


def test_missing_weather_and_sst_are_not_zero_calm_or_zero_degrees(monkeypatch):
    provider, marine, _, _ = _provider(monkeypatch)
    entries = provider._to_daily_forecasts(store.spots[0], marine, {})
    assert entries[0].wind_kts is None
    assert entries[0].sea_surface_temperature_c is None


def test_provider_429_backoff_avoids_repeated_paid_calls(monkeypatch):
    provider, _, _, _ = _provider(monkeypatch)
    calls = []
    def unavailable(*_args, **_kwargs):
        calls.append(1)
        request = httpx.Request("GET", "https://marine-api.open-meteo.com/v1/marine")
        raise httpx.HTTPStatusError("rate limited", request=request, response=httpx.Response(429, request=request))
    provider._marine_client = SimpleNamespace(get=unavailable)
    with pytest.raises(httpx.HTTPStatusError):
        provider.fetch_spot_forecast(store.spots[0])
    with pytest.raises(RuntimeError, match="backing off"):
        provider.fetch_spot_forecast(store.spots[0])
    assert calls == [1]


def test_global_budget_reserves_weighted_units_before_network(monkeypatch):
    from app.integrations.weather_providers import open_meteo
    calls = []
    monkeypatch.setattr(open_meteo.api_rate_limiter, "enforce", lambda rule: calls.append(rule))
    monkeypatch.setenv("OPEN_METEO_DAILY_CREDIT_BUDGET", "3000")
    OpenMeteoMarineProvider._reserve_upstream_budget()
    assert len(calls) == 3
    assert all(rule.limit == 3000 and rule.window_seconds == 86400 for rule in calls)


def test_exhausted_budget_blocks_before_either_upstream_request(monkeypatch):
    from app.integrations.weather_providers import open_meteo
    provider, _, _, network_calls = _provider(monkeypatch)
    monkeypatch.delattr(provider, "_reserve_upstream_budget")
    reserved = []
    def enforce(rule):
        reserved.append(rule)
        if len(reserved) > rule.limit:
            raise HTTPException(status_code=429, detail="Budget exhausted")
    monkeypatch.setenv("OPEN_METEO_DAILY_CREDIT_BUDGET", "2")
    monkeypatch.setattr(open_meteo.api_rate_limiter, "enforce", enforce)
    with pytest.raises(HTTPException):
        provider.fetch_spot_forecast(store.spots[0])
    assert network_calls == []


def test_expired_calendar_rows_are_not_returned_as_current(monkeypatch):
    provider, _, _, calls = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_forecast(spot)
    cached = provider._cache[provider._cache_identity(spot)]
    for entry in cached.data:
        entry.day = entry.day - timedelta(days=10)
    provider.fetch_spot_forecast(spot)
    assert len(calls) == 4


def test_cache_refreshes_after_spot_local_midnight_to_keep_five_days(monkeypatch):
    provider, _, _, calls = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_forecast(spot)
    cached = provider._cache[provider._cache_identity(spot)]
    # Four dates would still be in the future, but the new local day should
    # start a fresh five-day horizon rather than retain yesterday's first day.
    for entry in cached.data:
        entry.day -= timedelta(days=1)
    provider.fetch_spot_forecast(spot)
    assert len(calls) == 4


def test_open_meteo_rejects_cache_timestamp_far_in_the_future(monkeypatch):
    provider, _, _, calls = _provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_forecast(spot)
    provider._cache[provider._cache_identity(spot)].fetched_at = datetime.now(UTC) + timedelta(hours=1)
    provider.fetch_spot_forecast(spot)
    assert len(calls) == 4


def test_weather_is_joined_by_utc_stamp_not_array_position(monkeypatch):
    provider, marine, weather, _ = _provider(monkeypatch)
    weather["hourly"]["time"] = weather["hourly"]["time"][::-1]
    weather["hourly"]["wind_speed_10m"] = list(range(120))
    rows = provider._to_hourly_rows(marine, weather)
    assert rows[0]["wind_speed"] == 119.0
    assert rows[-1]["wind_speed"] == 0.0


def test_coordinate_correction_invalidates_marine_memory_and_persistent_identity(monkeypatch):
    provider, _, _, calls = _provider(monkeypatch)
    reads, writes = [], []
    provider._persistent_cache = SimpleNamespace(
        get=lambda key, age: reads.append(key),
        set=lambda key, payload: writes.append(key),
    )
    original = store.spots[0]
    corrected = original.model_copy(update={"latitude": original.latitude - 0.3, "longitude": original.longitude - 0.4})
    provider.fetch_spot_forecast(original)
    detail = provider.fetch_spot_detail(corrected)
    provider.fetch_spot_forecast(original)
    assert detail.spot_id == original.id == corrected.id
    assert len(calls) == 4
    assert calls[2][1]["latitude"] == corrected.latitude
    assert calls[2][1]["longitude"] == corrected.longitude
    assert len(set(reads)) == len(set(writes)) == 2
    assert all(key.startswith("open-meteo:v3:") for key in writes)
    assert f":{corrected.latitude!r}:{corrected.longitude!r}" in writes[1]


def test_coordinate_correction_does_not_inherit_marine_failure_backoff(monkeypatch):
    provider, _, _, calls = _provider(monkeypatch)
    original_client = provider._marine_client
    def limited(*_args, **_kwargs):
        request = httpx.Request("GET", "https://marine-api.open-meteo.com/v1/marine")
        raise httpx.HTTPStatusError("rate limited", request=request, response=httpx.Response(429, request=request))
    provider._marine_client = SimpleNamespace(get=limited)
    original = store.spots[0]
    with pytest.raises(httpx.HTTPStatusError):
        provider.fetch_spot_forecast(original)
    provider._marine_client = original_client
    corrected = original.model_copy(update={"latitude": original.latitude - 0.3})
    assert provider.fetch_spot_detail(corrected).available
    # The rejected location's weather runs independently. Only the corrected
    # location must make a new, complete marine/weather pair.
    corrected_calls = [
        kind for kind, params in calls if params["latitude"] == corrected.latitude
    ]
    assert sorted(corrected_calls) == ["marine", "weather"]


def test_best_window_uses_current_local_day_not_first_cached_day():
    rows = []
    for day in ("2026-11-10", "2026-11-11"):
        for hour in range(6, 18):
            rows.append({"day": day, "time": f"{day}T{hour:02}:00:00+08:00", "wave_height": 1.5, "wave_period": 12.0, "wind_speed": 7.0, "is_day": 1.0})
    result = _best_surf_window(store.spots[0], rows, timezone_name="Asia/Makassar", now=datetime(2026, 11, 11, 2, tzinfo=UTC))
    assert result.available
    assert result.day.isoformat() == "2026-11-11"
    assert result.best_start_label == "10 AM"
    assert all(hour.time.startswith("2026-11-11") for hour in result.hours)
    assert "not an observed" in result.note
    for row in rows:
        row["wind_speed"] = None
    assert not _best_surf_window(store.spots[0], rows, timezone_name="Asia/Makassar", now=datetime(2026, 11, 11, 2, tzinfo=UTC)).available


def test_detail_endpoint_enforces_auth_and_live_entitlements(monkeypatch):
    user = store.user.model_copy(update={"premium": False, "free_live_spot_id": None})
    monkeypatch.setattr(store, "resolve_session_user", lambda token: user if token == "forecast-test-token" else None)
    monkeypatch.setattr(store.weather_provider, "fetch_spot_detail", lambda spot: DetailedSpotForecast(spot_id=spot.id, available=True))
    client = TestClient(app)
    params = {"spot_id": store.spots[0].id}
    assert client.get("/api/v1/forecasts/detail", params=params).status_code == 401
    headers = {"Authorization": "Bearer forecast-test-token"}
    locked = client.get("/api/v1/forecasts/detail", params=params, headers=headers)
    assert locked.status_code == 200 and locked.json()["hours"] == []
    assert locked.json()["available"] is False
    user.free_live_spot_id = params["spot_id"]
    assert client.get("/api/v1/forecasts/detail", params=params, headers=headers).json()["available"] is True
    user.free_live_spot_id = None
    user.premium = True
    assert client.get("/api/v1/forecasts/detail", params=params, headers=headers).json()["available"] is True
    assert client.get("/api/v1/forecasts/detail", params={"spot_id": "unknown"}, headers=headers).status_code == 404


def test_premium_bulk_cards_never_trigger_upstream_fanout(monkeypatch):
    calls = []
    monkeypatch.setattr(store.weather_provider, "fetch_spot_forecast", lambda *_args, **_kwargs: calls.append(1))
    with store.request_user_context(store.user.model_copy(update={"premium": True})):
        forecasts = list(store.list_forecasts())
    assert len(forecasts) == len(store.spots) * 5
    assert calls == []


def test_detail_outage_never_substitutes_seeded_chart_data(monkeypatch):
    def fail(_spot):
        raise RuntimeError("Provider unavailable")
    monkeypatch.setattr(store.weather_provider, "fetch_spot_detail", fail)
    with store.request_user_context(store.user.model_copy(update={"premium": True})):
        detail = store.get_detailed_forecast(store.spots[0].id)
    assert detail.available is False
    assert detail.hours == [] and detail.days == [] and detail.fetched_at is None
    assert "No estimated chart" in detail.note


def test_actual_tide_series_preserves_dst_and_datum_without_interpolation():
    provider = TideCheckProvider()
    forecast = provider._to_tide_forecast(store.spots[0], {"name": "Test station", "distanceKm": 12.4}, {
        "station": {"name": "Test station", "timezone": "America/Los_Angeles"},
        "datum": "LAT", "extremes": [],
        "timeSeries": [
            {"time": "2026-11-01T08:30:00Z", "height": 1.234},
            {"time": "2026-11-01T09:30:00Z", "height": 1.345},
            {"time": "2026-11-01T09:45:00Z", "height": None},
            {"time": "2026-11-01T10:00:00Z", "height": float("nan")},
        ],
    })
    assert forecast.available and forecast.datum == "LAT"
    assert forecast.timezone == "America/Los_Angeles"
    assert forecast.station_distance_km == 12.4
    assert len(forecast.samples) == 2
    assert forecast.samples[0].local_time == forecast.samples[1].local_time == "01:30"
    assert forecast.samples[0].time != forecast.samples[1].time
    assert forecast.samples[0].height_m == 1.234
    assert forecast.fetched_at.tzinfo == UTC


def _tide_provider(monkeypatch, *, delay=0):
    monkeypatch.setenv("TIDECHECK_API_KEY", "fixture-only-key")
    provider = TideCheckProvider()
    provider._persistent_cache = None
    monkeypatch.setattr(provider, "_reserve_upstream_request", lambda: None)
    local_noon = datetime.now(ZoneInfo("Asia/Makassar")).replace(hour=12, minute=0, second=0, microsecond=0)
    payload = {
        "station": {"name": "Fixture station", "timezone": "Asia/Makassar"},
        "datum": "LAT",
        "extremes": [{"type": "high", "time": local_noon.astimezone(UTC).isoformat(), "height": 1.2}],
        "timeSeries": [{"time": local_noon.astimezone(UTC).isoformat(), "height": 1.2}],
    }
    calls = []
    def get(path, **_kwargs):
        if delay:
            time.sleep(delay)
        calls.append(path)
        data = [{"id": "fixture-station", "name": "Fixture station", "distanceKm": 1.0}] if path == "/api/stations/nearest" else payload
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: data)
    provider._client = SimpleNamespace(get=get)
    return provider, payload, calls, local_noon.date()


def test_tide_chart_refreshes_share_single_flight_and_twelve_hour_cache(monkeypatch):
    provider, _, calls, local_day = _tide_provider(monkeypatch, delay=0.01)
    spot = store.spots[0]
    with ThreadPoolExecutor(max_workers=6) as pool:
        forecasts = list(pool.map(lambda _: provider.fetch_spot_tides(spot, local_day, days=5), range(6)))
    assert all(forecast.available for forecast in forecasts)
    assert len(calls) == 2  # One station lookup and one prediction request.
    cache_key = f"{provider._cache_identity(spot)}:{local_day.isoformat()}:5"
    assert timedelta(hours=11, minutes=59) < provider._tide_cache[cache_key].expires_at - datetime.now(UTC) <= timedelta(hours=12)
    assert provider.fetch_spot_tides(spot, local_day, days=5).available
    assert len(calls) == 2


def test_tide_429_negative_cache_stops_chart_refresh_hammering(monkeypatch):
    provider, _, calls, local_day = _tide_provider(monkeypatch)
    def limited(path, **_kwargs):
        calls.append(path)
        request = httpx.Request("GET", "https://tidecheck.com/api/stations/nearest")
        raise httpx.HTTPStatusError("rate limited", request=request, response=httpx.Response(429, request=request))
    provider._client = SimpleNamespace(get=limited)
    spot = store.spots[0]
    assert not provider.fetch_spot_tides(spot, local_day, days=5).available
    for offset in range(5):
        result = provider.fetch_spot_tides(spot, local_day + timedelta(days=offset), days=5)
        assert not result.available and result.samples == []
    assert len(calls) == 1
    assert timedelta(minutes=4, seconds=59) < provider._negative_cache[provider._cache_identity(spot)].expires_at - datetime.now(UTC) <= timedelta(minutes=5)


def test_tide_empty_response_is_negatively_cached_without_invented_readings(monkeypatch):
    provider, payload, calls, local_day = _tide_provider(monkeypatch)
    payload["timeSeries"] = []
    payload["extremes"] = []
    spot = store.spots[0]
    for _ in range(4):
        result = provider.fetch_spot_tides(spot, local_day)
        assert not result.available and result.samples == [] and result.events == []
    assert len(calls) == 2
    assert timedelta(seconds=59) < provider._negative_cache[provider._cache_identity(spot)].expires_at - datetime.now(UTC) <= timedelta(minutes=1)


def test_tide_budget_counts_actual_requests_not_positive_cache_reads(monkeypatch):
    from app.integrations.tide_providers import tidecheck
    provider, _, calls, local_day = _tide_provider(monkeypatch)
    monkeypatch.delattr(provider, "_reserve_upstream_request")
    rules = []
    monkeypatch.setenv("TIDECHECK_DAILY_REQUEST_BUDGET", "500")
    monkeypatch.setattr(tidecheck.api_rate_limiter, "enforce", lambda rule: rules.append(rule))
    spot = store.spots[0]
    assert provider.fetch_spot_tides(spot, local_day).available
    assert provider.fetch_spot_tides(spot, local_day).available
    assert len(calls) == len(rules) == 2
    assert all(rule.limit == 500 and rule.window_seconds == 86400 for rule in rules)


def test_tide_budget_exhaustion_blocks_network_and_returns_unavailable(monkeypatch):
    from app.integrations.tide_providers import tidecheck
    provider, _, calls, local_day = _tide_provider(monkeypatch)
    monkeypatch.delattr(provider, "_reserve_upstream_request")
    def deny(_rule):
        raise HTTPException(status_code=429, detail="Budget exhausted")
    monkeypatch.setattr(tidecheck.api_rate_limiter, "enforce", deny)
    result = provider.fetch_spot_tides(store.spots[0], local_day)
    assert not result.available and result.samples == []
    assert calls == []


def test_tide_rejects_future_dated_positive_cache(monkeypatch):
    provider, _, calls, local_day = _tide_provider(monkeypatch)
    spot = store.spots[0]
    provider.fetch_spot_tides(spot, local_day)
    cache_key = f"{provider._cache_identity(spot)}:{local_day.isoformat()}:3"
    provider._tide_cache[cache_key].data.fetched_at = datetime.now(UTC) + timedelta(hours=1)
    repaired = provider.fetch_spot_tides(spot, local_day)
    assert repaired.available
    assert repaired.fetched_at <= datetime.now(UTC)
    # The separate station prediction payload retains its real fetched time,
    # so it can repair corrupt spot metadata without another paid request.
    assert len(calls) == 2


def test_coordinate_correction_invalidates_station_and_tide_caches(monkeypatch):
    provider, _, calls, local_day = _tide_provider(monkeypatch)
    reads, writes = [], []
    provider._persistent_cache = SimpleNamespace(
        get=lambda key, age: reads.append(key),
        set=lambda key, payload: writes.append(key),
    )
    original = store.spots[0]
    corrected = original.model_copy(update={"latitude": original.latitude - 0.3, "longitude": original.longitude - 0.4})
    provider.fetch_spot_tides(original, local_day)
    forecast = provider.fetch_spot_tides(corrected, local_day)
    provider.fetch_spot_tides(original, local_day)
    assert forecast.spot_id == original.id == corrected.id
    assert calls.count("/api/stations/nearest") == 2
    assert len(calls) == 3  # Two coordinate lookups resolve to one real station.
    assert len(set(writes)) == 5  # Both spot identities plus shared prediction.
    assert all(key.startswith(("tidecheck:v3:", "tidecheck:v4:predictions:")) for key in reads + writes)
    for kind in ("station", "tides"):
        assert any(f"tidecheck:v3:{kind}:{corrected.id}:{corrected.latitude!r}:{corrected.longitude!r}" in key for key in writes)


def test_coordinate_correction_does_not_inherit_tide_transient_failure_backoff(monkeypatch):
    provider, _, calls, local_day = _tide_provider(monkeypatch)
    original_client = provider._client
    def limited(path, **_kwargs):
        request = httpx.Request("GET", "https://tidecheck.com/api/stations/nearest")
        raise httpx.HTTPStatusError("temporary outage", request=request, response=httpx.Response(503, request=request))
    provider._client = SimpleNamespace(get=limited)
    original = store.spots[0]
    assert not provider.fetch_spot_tides(original, local_day).available
    provider._client = original_client
    corrected = original.model_copy(update={"longitude": original.longitude - 0.4})
    assert provider.fetch_spot_tides(corrected, local_day).available
    assert len(calls) == 2


def test_sumbawa_reference_areas_are_not_the_legacy_sape_points():
    references = {
        "spot_lakey_peak": (-8.79, 118.38, "Hu'u"),
        "spot_lakey_pipe": (-8.80, 118.38, "Hu'u"),
        "spot_nungas": (-8.79, 118.38, "Hu'u"),
        "spot_periscope_point": (-8.78, 118.37, "Hu'u"),
        "spot_cobblestones_sumbawa": (-8.82, 118.38, "Hu'u"),
        "spot_yoyos": (-8.98, 116.73, "Sekongkang"),
    }
    for spot_id, (latitude, longitude, area) in references.items():
        spot = store.get_spot(spot_id)
        assert (spot.latitude, spot.longitude, spot.area) == (latitude, longitude, area)
        assert "Approximate forecast-area position" in spot.summary
