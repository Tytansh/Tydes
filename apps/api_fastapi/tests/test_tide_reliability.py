"""TideCheck reliability fixtures; no real key, database or provider traffic."""
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
import sys
from threading import Lock
import time
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.models import Spot
from app.core.persistent_cache import CachedJson
from app.integrations.tide_providers.tidecheck import TideCheckProvider


def _spot(index=0, *, country="Indonesia"):
    return Spot(
        id=f"fixture-spot-{index}", name=f"Beach {index}", country=country,
        region="Fixture coast", area="Fixture area", latitude=-8.8,
        longitude=115 + index / 100, difficulty="intermediate", best_months=[],
        wave_height_m=1.0, water_temp_c=26.0, image_url="", summary="Fixture",
    )


def _provider(monkeypatch, zone="Asia/Makassar"):
    monkeypatch.setenv("TIDECHECK_API_KEY", "fixture-not-a-real-key")
    monkeypatch.setattr("app.integrations.tide_providers.tidecheck.PostgresJsonCache.from_env", lambda: None)
    provider = TideCheckProvider()
    reserves = []
    monkeypatch.setattr(provider, "_reserve_upstream_request", lambda: reserves.append(1))
    day = datetime.now(ZoneInfo(zone)).date()
    noon = datetime.combine(day, datetime.min.time(), ZoneInfo(zone)) + timedelta(hours=12)
    payload = {
        "station": {"name": "Fixture station", "timezone": zone},
        "datum": "LAT",
        "extremes": [{"type": "high", "time": noon.astimezone(UTC).isoformat(), "height": 1.2}],
        "timeSeries": [{"time": noon.astimezone(UTC).isoformat(), "height": 1.2}],
    }
    return provider, payload, day, reserves


def _response(payload, *, path="/fixture", status=200):
    return httpx.Response(status, json=payload, request=httpx.Request("GET", f"https://tidecheck.com{path}"))


def _station(distance=1.0):
    return [{"id": "one-real-station", "name": "Fixture station", "distanceKm": distance, "timezone": "Asia/Makassar"}]


def test_transient_station_timeout_retries_once_and_counts_each_attempt(monkeypatch):
    provider, payload, day, reserves = _provider(monkeypatch)
    calls = []
    def get(path, **_kwargs):
        calls.append(path)
        if len(calls) == 1:
            raise httpx.ConnectTimeout("fixture timeout")
        return _response(_station() if path.endswith("nearest") else payload)
    provider._client = SimpleNamespace(get=get)
    assert provider.fetch_spot_tides(_spot(), day, days=5).available
    assert len(calls) == len(reserves) == 3
    assert provider.fetch_spot_tides(_spot(), day, days=5).available
    assert len(calls) == len(reserves) == 3


def test_transient_prediction_503_retries_once_without_repeating_station_lookup(monkeypatch):
    provider, payload, day, reserves = _provider(monkeypatch)
    calls = []
    def get(path, **_kwargs):
        calls.append(path)
        if len(calls) == 2:
            return _response({}, status=503)
        return _response(_station() if path.endswith("nearest") else payload)
    provider._client = SimpleNamespace(get=get)
    assert provider.fetch_spot_tides(_spot(), day).available
    assert calls.count("/api/stations/nearest") == 1
    assert len(calls) == len(reserves) == 3


def test_repeated_timeout_is_bounded_and_then_negatively_cached(monkeypatch):
    provider, _, day, reserves = _provider(monkeypatch)
    def get(*_args, **_kwargs):
        raise httpx.ReadTimeout("fixture timeout")
    provider._client = SimpleNamespace(get=get)
    assert not provider.fetch_spot_tides(_spot(), day).available
    assert not provider.fetch_spot_tides(_spot(), day).available
    assert len(reserves) == 2


@pytest.mark.parametrize("status", [400, 401, 403, 404, 429])
def test_non_transient_provider_errors_never_retry(monkeypatch, status):
    provider, _, day, reserves = _provider(monkeypatch)
    provider._client = SimpleNamespace(get=lambda *_args, **_kwargs: _response({}, status=status))
    assert not provider.fetch_spot_tides(_spot(), day).available
    assert len(reserves) == 1


@pytest.mark.parametrize("status", [401, 429])
def test_provider_wide_auth_or_quota_failure_is_not_hammered_by_other_spots(monkeypatch, status):
    provider, _, day, reserves = _provider(monkeypatch)
    provider._client = SimpleNamespace(get=lambda *_args, **_kwargs: _response({}, status=status))
    first = provider.fetch_spot_tides(_spot(), day)
    second = provider.fetch_spot_tides(_spot(1), day)
    assert not first.available and not second.available
    assert first.spot_id != second.spot_id
    assert first.note == second.note
    assert len(reserves) == 1


def test_neighboring_spots_share_station_prediction_without_sharing_spot_metadata(monkeypatch):
    provider, payload, day, reserves = _provider(monkeypatch)
    calls = []
    guard = Lock()
    def get(path, **kwargs):
        with guard:
            calls.append(path)
        if path.endswith("nearest"):
            return _response(_station((kwargs["params"]["lng"] - 114) * 10))
        time.sleep(0.01)
        return _response(payload)
    provider._client = SimpleNamespace(get=get)
    with ThreadPoolExecutor(max_workers=6) as pool:
        forecasts = list(pool.map(lambda i: provider.fetch_spot_tides(_spot(i), day, days=5), range(6)))
    assert all(item.available for item in forecasts)
    assert {item.spot_id for item in forecasts} == {_spot(i).id for i in range(6)}
    assert len({item.station_distance_km for item in forecasts}) > 1
    assert len({item.fetched_at for item in forecasts}) == 1
    assert calls.count("/api/station/one-real-station/tides") == 1
    assert len(calls) == len(reserves) == 7  # Six first-time lookups; one prediction.


def test_shared_station_prediction_survives_restart_for_a_different_beach(monkeypatch):
    provider, payload, day, _ = _provider(monkeypatch)
    cache = {}
    def persistent_get(key, max_age):
        item = cache.get(key)
        return item if item and datetime.now(UTC) - item.updated_at <= max_age else None
    persistent = SimpleNamespace(
        get=persistent_get,
        set=lambda key, value: cache.update({key: CachedJson(value, datetime.now(UTC))}),
    )
    provider._persistent_cache = persistent
    provider._client = SimpleNamespace(get=lambda path, **_kwargs: _response(_station() if path.endswith("nearest") else payload))
    first = provider.fetch_spot_tides(_spot(), day, days=5)
    restarted, _, _, reserves = _provider(monkeypatch)
    restarted._persistent_cache = persistent
    calls = []
    def get(path, **_kwargs):
        calls.append(path)
        assert path.endswith("nearest"), "Shared cached predictions must not spend another upstream request"
        return _response(_station(2.3))
    restarted._client = SimpleNamespace(get=get)
    second = restarted.fetch_spot_tides(_spot(1), day, days=5)
    assert second.available and second.fetched_at == first.fetched_at
    assert second.spot_id != first.spot_id
    assert second.station_distance_km == 2.3
    assert len(calls) == len(reserves) == 1


@pytest.mark.parametrize("zone,country", [
    ("Asia/Makassar", "Indonesia"), ("Australia/Sydney", "Australia"),
    ("Asia/Taipei", "Taiwan"), ("America/Los_Angeles", "United States"),
])
def test_five_local_days_include_the_last_evening_in_eastern_and_western_timezones(monkeypatch, zone, country):
    provider, _, day, _ = _provider(monkeypatch, zone)
    requested = []
    def get(path, **kwargs):
        if path.endswith("nearest"):
            return _response(_station())
        params = kwargs["params"]
        requested.append(params)
        # TideCheck documents a UTC interval starting one day before `start`.
        # Six UTC days would cut off the last local evening west of UTC.
        start = datetime.combine(date.fromisoformat(params["start"]), datetime.min.time(), UTC) - timedelta(days=1)
        end = start + timedelta(days=params["days"])
        last_evening = datetime.combine(day + timedelta(days=4), datetime.min.time(), ZoneInfo(zone)) + timedelta(hours=23)
        stamp = last_evening.astimezone(UTC)
        rows = [{"time": stamp.isoformat(), "height": 0.4}] if start <= stamp < end else []
        return _response({
            "station": {"timezone": zone}, "datum": "LAT",
            "extremes": [{**row, "type": "low"} for row in rows], "timeSeries": rows,
        })
    provider._client = SimpleNamespace(get=get)
    forecast = provider.fetch_spot_tides(_spot(country=country), day, days=5)
    assert requested[0]["days"] == 7
    assert forecast.available and forecast.events[0].local_date == day + timedelta(days=4)
    assert forecast.samples[0].local_time == "23:00"


def test_bad_extreme_rows_do_not_discard_other_real_tides(monkeypatch):
    provider, payload, day, _ = _provider(monkeypatch)
    payload["extremes"] += [
        {"type": "low", "time": "not-a-time", "height": 0.1},
        {"type": "low", "time": "2026-11-14T10:00:00", "height": 0.1},
        {"type": "high"}, None, "bad row",
    ]
    forecast = provider._to_tide_forecast(_spot(), _station()[0], payload, start_day=day, days=5)
    assert forecast.available and len(forecast.events) == len(forecast.samples) == 1
    assert forecast.events[0].time.tzinfo is not None


def test_bad_response_timezone_uses_valid_station_timezone(monkeypatch):
    provider, payload, day, _ = _provider(monkeypatch)
    payload["station"]["timezone"] = "not/a/real/zone"
    forecast = provider._to_tide_forecast(_spot(), _station()[0], payload, start_day=day, days=5)
    assert forecast.available and forecast.timezone == "Asia/Makassar"
    assert forecast.samples[0].local_time == "12:00"


def test_corrupt_persistent_tide_payload_does_not_block_provider_recovery(monkeypatch):
    provider, payload, day, reserves = _provider(monkeypatch)
    provider._persistent_cache = SimpleNamespace(
        get=lambda *_args: CachedJson({"invalid": "old payload"}, datetime.now(UTC)),
        set=lambda *_args: None,
    )
    provider._client = SimpleNamespace(get=lambda path, **_kwargs: _response(_station() if path.endswith("nearest") else payload))
    assert provider.fetch_spot_tides(_spot(), day).available
    assert len(reserves) == 2


def test_expired_dated_charts_are_evicted_instead_of_growing_forever(monkeypatch):
    provider, payload, day, _ = _provider(monkeypatch)
    expired = SimpleNamespace(expires_at=datetime.now(UTC) - timedelta(seconds=1), data=None)
    for cache in (provider._tide_cache, provider._prediction_cache, provider._station_cache, provider._negative_cache):
        cache["expired-date"] = expired
    provider._client = SimpleNamespace(get=lambda path, **_kwargs: _response(_station() if path.endswith("nearest") else payload))
    assert provider.fetch_spot_tides(_spot(), day).available
    assert all("expired-date" not in cache for cache in (
        provider._tide_cache, provider._prediction_cache, provider._station_cache, provider._negative_cache,
    ))
    provider._station_predictions(_station()[0], day + timedelta(days=1), 5)
    assert len(provider._prediction_locks) == 1
