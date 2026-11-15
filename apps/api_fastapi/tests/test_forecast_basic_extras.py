"""Free daily extras read only the shared model snapshot; no live API calls."""
from datetime import UTC, date, datetime, timedelta
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-basic-extras-"))

from app.core.models import ForecastDaylight
from app.core.persistent_cache import CachedJson
from app.core.store import store
from app.integrations.weather_providers.open_meteo import _basic_daylight, _basic_wind_direction
from test_forecast_reliability import _provider


def _warm(monkeypatch):
    provider, _, _, calls, reservations = _provider(monkeypatch)
    spot = store.spots[0]
    first = provider.fetch_spot_basic(spot)
    return provider, spot, provider._cache[provider._cache_identity(spot)], first, calls, reservations


def test_daily_extras_preserve_real_values_nulls_and_original_cache_cost(monkeypatch):
    provider, spot, cached, first, calls, reservations = _warm(monkeypatch)
    day = first.local_date
    cached.data[0].wind_kts = 8.0
    cached.data[0].sea_surface_temperature_c = -1.8
    cached.days = [ForecastDaylight(day=day, sunrise=f"{day}T06:12:00+08:00", sunset=f"{day}T18:23:00+08:00")]
    for hour in cached.hourly_rows[:24]:
        hour.update(wind_speed=8.0, wind_direction=1)
    result = provider.fetch_spot_basic(spot)
    row = result.days[0]
    assert row.wind_kts == 8.0 and row.wind_direction_deg == 1
    assert row.wind_direction_status == "available"
    assert row.sea_surface_temperature_c == -1.8
    assert (row.sunrise_local, row.sunset_local) == ("06:12", "18:23")
    assert result.weather_model == "Best Match (automatic)"
    assert result.fetched_at == first.fetched_at
    assert len(calls) == 2 and reservations == [3]
    assert not {"wind_gusts_kts", "tides", "swell_period_s", "hours"} & set(row.model_dump())


@pytest.mark.parametrize("speeds,directions,mean,expected,status", [
    ([8] * 24, [359, 1] * 12, 8, 0, "available"),
    ([8] * 24, [90, 270] * 12, 8, None, "variable"),
    ([18, 2] * 12, [0, 180] * 12, 10, 0, "available"),
    ([0.5] * 24, [120] * 24, 0.5, None, "calm"),
    ([0] * 24, [0] * 24, 0, None, "calm"),
    ([None] * 24, [120] * 24, None, None, "unavailable"),
    ([8] * 24, [None] * 24, 8, None, "unavailable"),
    ([8] * 24, [0] + [None] * 23, 8, None, "unavailable"),
    ([8] * 24, [0] * 11 + [None] * 13, 8, None, "unavailable"),
    ([8] * 24, [0] * 12 + [None] * 12, 8, 0, "available"),
    ([8] * 2, [0, 0], 8, None, "unavailable"),
])
def test_circular_from_direction_calm_variable_missing_and_coverage(speeds, directions, mean, expected, status):
    rows = [{"wind_speed": speed, "wind_direction": direction} for speed, direction in zip(speeds, directions)]
    assert _basic_wind_direction(rows, mean) == (expected, status)


@pytest.mark.parametrize("invalid", [None, float("nan"), float("inf"), -1, 251, True, "broken", {}])
def test_bad_optional_wind_cannot_remove_real_waves_or_become_zero(monkeypatch, invalid):
    provider, spot, cached, _, calls, reservations = _warm(monkeypatch)
    cached.data[0].wind_kts = invalid
    for hour in cached.hourly_rows[:24]:
        hour["wind_direction"] = "broken"
    row = provider.fetch_spot_basic(spot).days[0]
    assert row.wave_height_m == 1.5
    assert row.wind_kts is None and row.wind_direction_deg is None
    assert row.wind_direction_status == "unavailable"
    assert len(calls) == 2 and reservations == [3]


@pytest.mark.parametrize("temperature,expected", [(None, None), (0, 0), (-1.8, -1.8),
    (float("nan"), None), (float("inf"), None), (-6, None), (51, None), ("broken", None)])
def test_real_zero_and_negative_sst_are_not_missing_or_spot_temperature(monkeypatch, temperature, expected):
    provider, spot, cached, _, _, _ = _warm(monkeypatch)
    cached.data[0].sea_surface_temperature_c = temperature
    assert provider.fetch_spot_basic(spot).days[0].sea_surface_temperature_c == expected


@pytest.mark.parametrize("day,sunrise,sunset", [
    (date(2026, 10, 3), "2026-10-02T20:00:00Z", "2026-10-03T08:00:00Z"),
    (date(2026, 10, 4), "2026-10-03T19:00:00Z", "2026-10-04T07:00:00Z"),
    (date(2026, 4, 4), "2026-04-03T19:00:00Z", "2026-04-04T07:00:00Z"),
    (date(2026, 4, 5), "2026-04-04T20:00:00Z", "2026-04-05T08:00:00Z"),
])
def test_daylight_uses_target_date_iana_offset_across_sydney_dst(day, sunrise, sunset):
    assert _basic_daylight([ForecastDaylight(day=day, sunrise=sunrise, sunset=sunset)], day, "Australia/Sydney") == ("06:00", "18:00")


@pytest.mark.parametrize("sunrise,sunset,expected", [
    ("2026-11-16T06:00:00+08:00", "2026-11-16T18:00:00+08:00", ("06:00", "18:00")),
    ("2026-11-16T06:00:00", "2026-11-16T18:00:00+08:00", (None, "18:00")),
    ("2026-11-17T06:00:00+08:00", "2026-11-16T18:00:00+08:00", (None, "18:00")),
    ("broken", None, (None, None)),
    ("2026-11-16T19:00:00+08:00", "2026-11-16T18:00:00+08:00", (None, None)),
    ("2026-11-16T18:00:00+08:00", "2026-11-16T18:00:00+08:00", (None, None)),
])
def test_daylight_rejects_naive_wrong_local_date_and_contradictory_pairs(sunrise, sunset, expected):
    day = date(2026, 11, 16)
    assert _basic_daylight([ForecastDaylight(day=day, sunrise=sunrise, sunset=sunset)], day, "Asia/Makassar") == expected


def test_partial_weather_and_corrupt_optional_metadata_keep_available_waves(monkeypatch):
    provider, spot, cached, first, calls, reservations = _warm(monkeypatch)
    cached.weather_available = False
    cached.data[0].sea_surface_temperature_c = 24.0
    cached.days = {"bad": "optional metadata"}
    cached.hourly_rows = None
    result = provider.fetch_spot_basic(spot)
    assert result.available and result.days[0].wave_height_m == first.days[0].wave_height_m
    assert result.weather_model == "Temporarily unavailable"
    assert result.days[0].wind_kts is None
    assert result.days[0].wind_direction_status == "unavailable"
    assert result.days[0].sea_surface_temperature_c == 24.0
    assert result.days[0].sunrise_local is None and result.days[0].sunset_local is None
    assert len(calls) == 2 and reservations == [3]


def test_persisted_corrupt_optional_values_do_not_trigger_an_extra_fetch(monkeypatch):
    provider, spot, cached, first, calls, reservations = _warm(monkeypatch)
    entries = [entry.model_dump(mode="json") for entry in cached.data]
    for entry in entries:
        entry.update(wind_kts="broken", sea_surface_temperature_c="broken")
    payload = {"forecasts": entries, "hourly_rows": cached.hourly_rows,
               "timezone": cached.timezone, "utc_offset_seconds": cached.utc_offset_seconds,
               "days": [{"day": first.local_date.isoformat(), "sunrise": 42, "sunset": {"broken": True}}]}
    provider._cache.clear()
    provider._persistent_cache = SimpleNamespace(get=lambda *_: CachedJson(payload=payload, updated_at=first.fetched_at))
    result = provider.fetch_spot_basic(spot)
    assert result.available and result.fetched_at == first.fetched_at
    assert result.days[0].wave_height_m == 1.5 and result.days[0].wind_kts is None
    assert result.days[0].sea_surface_temperature_c is None
    assert result.days[0].sunrise_local is None and result.days[0].sunset_local is None
    assert len(calls) == 2 and reservations == [3]


@pytest.mark.parametrize("daily", [None, {"time": None}, {"time": ["broken"]},
    {"time": ["2026-11-16"], "sunrise": ["broken"], "sunset": {"bad": True}}])
def test_fresh_malformed_optional_daylight_does_not_discard_marine_waves(monkeypatch, daily):
    provider, _, weather, calls, reservations = _provider(monkeypatch)
    weather["daily"] = daily
    result = provider.fetch_spot_basic(store.spots[0])
    assert result.available and result.days[0].wave_height_m == 1.5
    assert result.days[0].sunrise_local is None and result.days[0].sunset_local is None
    assert len(calls) == 2 and reservations == [3]
