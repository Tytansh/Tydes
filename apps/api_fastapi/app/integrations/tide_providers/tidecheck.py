from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
import logging
import math
import os
from pathlib import Path
from threading import RLock
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from app.core.models import Spot, TideEvent, TideForecast, TideSample
from app.core.persistent_cache import PostgresJsonCache
from app.core.rate_limit import RateLimitRule, api_rate_limiter

logger = logging.getLogger(__name__)


@dataclass
class _CacheItem:
    expires_at: datetime
    data: Any


@dataclass
class _PredictionPayload:
    payload: dict[str, Any]
    fetched_at: datetime


class _ProviderBackoff(RuntimeError):
    def __init__(self, status_code: int, note: str) -> None:
        super().__init__(note)
        self.status_code = status_code
        self.note = note


class TideCheckProvider:
    """Fetch high/low tide predictions from TideCheck behind a swappable provider."""

    def __init__(self) -> None:
        self._api_key = _load_api_key()
        self._client = httpx.Client(base_url="https://tidecheck.com", timeout=8.0)
        self._station_cache: dict[str, _CacheItem] = {}
        self._tide_cache: dict[str, _CacheItem] = {}
        self._persistent_cache = PostgresJsonCache.from_env()
        self._locks_guard = RLock()
        self._spot_locks: dict[str, RLock] = {}
        self._negative_cache: dict[str, _CacheItem] = {}
        self._prediction_cache: dict[str, _CacheItem] = {}
        self._prediction_locks: dict[str, RLock] = {}
        self._provider_backoff: _CacheItem | None = None

    def fetch_spot_tides(self, spot: Spot, start_day: date, days: int = 3) -> TideForecast:
        identity = self._cache_identity(spot)
        with self._locks_guard:
            self._prune_expired(datetime.now(UTC))
            lock = self._spot_locks.setdefault(identity, RLock())
        # Concurrent chart refreshes share the station lookup and tide fetch.
        with lock:
            return self._fetch_spot_tides_locked(spot, start_day, days)

    def _fetch_spot_tides_locked(self, spot: Spot, start_day: date, days: int) -> TideForecast:
        now = datetime.now(UTC)
        identity = self._cache_identity(spot)
        cache_key = f"{identity}:{start_day.isoformat()}:{days}"
        cached = self._tide_cache.get(cache_key)
        if cached and cached.expires_at > now and self._valid_forecast_time(cached.data, now):
            return cached.data

        persistent = self._read_persistent_tides(cache_key)
        if persistent is not None:
            forecast, updated_at = persistent
            self._remember(self._tide_cache, cache_key, _CacheItem(
                expires_at=updated_at + timedelta(hours=12),
                data=forecast,
            ))
            return forecast

        negative = self._negative_cache.get(identity)
        if negative and negative.expires_at > now:
            return negative.data

        if not self._api_key:
            forecast = TideForecast(
                spot_id=spot.id,
                available=False,
                note="Tide provider is not configured yet.",
            )
            self._remember(self._negative_cache, identity, _CacheItem(now + timedelta(minutes=5), forecast))
            return forecast

        retry_minutes = 1
        try:
            station = self._nearest_station(spot)
            prediction = self._station_predictions(station, start_day, days)
            forecast = self._to_tide_forecast(
                spot, station, prediction.payload, start_day=start_day, days=days,
            )
            forecast.fetched_at = prediction.fetched_at
        except _ProviderBackoff as error:
            retry_minutes = 5
            forecast = TideForecast(
                spot_id=spot.id, available=False, source="tidecheck", note=error.note,
            )
        except httpx.HTTPStatusError as error:
            status_code = error.response.status_code
            if status_code == 429:
                retry_minutes = 5
                internal_note = "TideCheck daily limit reached."
                user_note = (
                    "TideCheck daily rate limit exceeded. Live tides will work "
                    "again when the plan resets or the TideCheck plan is upgraded."
                )
            elif status_code == 401:
                retry_minutes = 5
                internal_note = "TideCheck API key is invalid."
                user_note = "TideCheck API key is invalid."
            elif status_code == 403:
                retry_minutes = 5
                internal_note = "TideCheck plan does not allow this request."
                user_note = "TideCheck plan does not allow this tide request."
            else:
                internal_note = f"TideCheck returned HTTP {status_code}."
                user_note = "TideCheck is unavailable right now."
            logger.warning("Tide data unavailable for %s: %s", spot.id, internal_note)
            forecast = TideForecast(
                spot_id=spot.id,
                available=False,
                source="tidecheck",
                note=user_note,
            )
        except Exception as error:
            if getattr(error, "status_code", None) == 429:
                retry_minutes = 5
            logger.warning("Tide data unavailable for %s (%s)", spot.id, type(error).__name__)
            forecast = TideForecast(
                spot_id=spot.id,
                available=False,
                source="tidecheck",
                note="Tide data is unavailable right now.",
            )

        if forecast.available:
            with self._locks_guard:
                self._negative_cache.pop(identity, None)
            self._remember(self._tide_cache, cache_key, _CacheItem(
                expires_at=now + timedelta(hours=12),
                data=forecast,
            ))
            self._write_persistent(
                f"tidecheck:v3:tides:{cache_key}",
                forecast.model_dump(mode="json"),
            )
        else:
            self._remember(self._negative_cache, identity, _CacheItem(
                expires_at=now + timedelta(minutes=retry_minutes),
                data=forecast,
            ))
        return forecast

    def _remember(self, cache: dict[str, _CacheItem], key: str, item: _CacheItem) -> None:
        with self._locks_guard:
            cache[key] = item

    def _prune_expired(self, now: datetime) -> None:
        # The keys contain dates. Without eviction a long-running service keeps
        # every old five-day chart forever even though it can no longer use it.
        # Caller holds the guard used by all cache writes.
        for cache in (self._tide_cache, self._prediction_cache, self._station_cache, self._negative_cache):
            for key, item in list(cache.items()):
                if item.expires_at <= now:
                    cache.pop(key, None)

    def _get_with_retry(self, path: str, *, params: dict[str, Any]) -> Any:
        """One bounded retry for transient failures; every attempt spends budget.

        Authentication, plan limits, 429s and invalid requests never retry.
        The existing eight-second timeout remains in force for each attempt.
        """
        for attempt in range(2):
            with self._locks_guard:
                backoff = self._provider_backoff
                if backoff and backoff.expires_at > datetime.now(UTC):
                    raise backoff.data
            self._reserve_upstream_request()
            try:
                response = self._client.get(
                    path, headers={"X-API-Key": self._api_key}, params=params,
                )
                response.raise_for_status()
                return response
            except httpx.HTTPStatusError as error:
                if error.response.status_code in {401, 429}:
                    note = (
                        "TideCheck API key is invalid."
                        if error.response.status_code == 401
                        else "TideCheck daily rate limit exceeded. Live tides will work again when the plan resets or the TideCheck plan is upgraded."
                    )
                    with self._locks_guard:
                        self._provider_backoff = _CacheItem(
                            datetime.now(UTC) + timedelta(minutes=5),
                            _ProviderBackoff(error.response.status_code, note),
                        )
                if attempt or error.response.status_code not in {408, 500, 502, 503, 504}:
                    raise
            except (httpx.TimeoutException, httpx.NetworkError, httpx.RemoteProtocolError):
                if attempt:
                    raise
        raise RuntimeError("Tide request retry exhausted")

    def _station_predictions(
        self, station: dict[str, Any], start_day: date, days: int,
    ) -> _PredictionPayload:
        # A station's prediction is identical for neighboring beaches. Cache it
        # once, then attach each spot's own ID/distance when building the result.
        # This avoids repeatedly charging quota for the same station and dates.
        upstream_days = max(1, min(days + 2, 7))
        key = f"{station['id']}:LAT:{start_day.isoformat()}:{upstream_days}"
        with self._locks_guard:
            # Dates vary, but requests for one station can use the same bounded
            # lock entry rather than retaining a new lock each calendar day.
            lock = self._prediction_locks.setdefault(f"{station['id']}:LAT", RLock())
        with lock:
            now = datetime.now(UTC)
            cached = self._prediction_cache.get(key)
            if cached and cached.expires_at > now:
                return cached.data
            persistent = self._read_persistent(
                f"tidecheck:v4:predictions:{key}", timedelta(hours=12),
            )
            if persistent is not None:
                payload, updated_at = persistent
                try:
                    fetched_at = datetime.fromisoformat(str(payload["fetched_at"]).replace("Z", "+00:00"))
                    prediction = payload["payload"]
                    if (
                        isinstance(prediction, dict)
                        and fetched_at.tzinfo is not None
                        and updated_at <= now + timedelta(minutes=1)
                        and -timedelta(minutes=1) <= now - fetched_at <= timedelta(hours=12)
                        and self._has_prediction_data(prediction)
                    ):
                        result = _PredictionPayload(prediction, fetched_at)
                        self._remember(self._prediction_cache, key, _CacheItem(
                            expires_at=min(updated_at, fetched_at) + timedelta(hours=12), data=result,
                        ))
                        return result
                except (ValueError, KeyError, TypeError):
                    # A malformed stored payload must not permanently suppress
                    # a working provider request after a restart.
                    pass
            response = self._get_with_retry(
                f"/api/station/{station['id']}/tides",
                params={"datum": "LAT", "days": upstream_days, "start": start_day.isoformat()},
            )
            payload = response.json()
            if not isinstance(payload, dict):
                raise ValueError("Invalid TideCheck prediction payload")
            result = _PredictionPayload(payload, datetime.now(UTC))
            if self._has_prediction_data(payload):
                self._remember(self._prediction_cache, key, _CacheItem(
                    expires_at=result.fetched_at + timedelta(hours=12), data=result,
                ))
                self._write_persistent(
                    f"tidecheck:v4:predictions:{key}",
                    {"payload": payload, "fetched_at": result.fetched_at.isoformat()},
                )
            return result

    @staticmethod
    def _has_prediction_data(payload: dict[str, Any]) -> bool:
        for item in _payload_rows(payload, "extremes") + _payload_rows(payload, "timeSeries"):
            if _as_float(item.get("height")) is None:
                continue
            try:
                stamp = datetime.fromisoformat(str(item["time"]).replace("Z", "+00:00"))
                if stamp.tzinfo is not None:
                    return True
            except (ValueError, KeyError, TypeError):
                pass
        return False

    @staticmethod
    def _cache_identity(spot: Spot) -> str:
        # Station and prediction caches must follow coordinate corrections even
        # when the public spot ID, favorites and shared links remain unchanged.
        return f"{spot.id}:{spot.latitude!r}:{spot.longitude!r}"

    @staticmethod
    def _reserve_upstream_request() -> None:
        # This bounds TYDES' HTTP attempts, not provider credits from other apps
        # or the account's final bill. The limiter persists across workers when
        # its existing PostgreSQL backend is configured.
        try:
            limit = max(1, min(int(os.getenv("TIDECHECK_DAILY_REQUEST_BUDGET", "500")), 100_000))
        except ValueError:
            limit = 500
        api_rate_limiter.enforce(RateLimitRule(
            scope="upstream:tidecheck-request-budget",
            key="all-tide-requests",
            limit=limit,
            window_seconds=24 * 60 * 60,
        ))

    @staticmethod
    def _valid_forecast_time(forecast: TideForecast, now: datetime) -> bool:
        if forecast.fetched_at is not None and forecast.fetched_at.tzinfo is None:
            return False
        return forecast.fetched_at is None or (
            -timedelta(minutes=1) <= now - forecast.fetched_at <= timedelta(hours=12)
        )

    def _nearest_station(self, spot: Spot) -> dict[str, Any]:
        now = datetime.now(UTC)
        identity = self._cache_identity(spot)
        cached = self._station_cache.get(identity)
        if cached and cached.expires_at > now:
            return cached.data

        persistent = self._read_persistent_station(identity)
        if persistent is not None:
            station, updated_at = persistent
            self._remember(self._station_cache, identity, _CacheItem(
                expires_at=updated_at + timedelta(days=30),
                data=station,
            ))
            return station

        response = self._get_with_retry(
            "/api/stations/nearest",
            params={"lat": spot.latitude, "lng": spot.longitude},
        )
        stations = response.json()
        if not isinstance(stations, list) or not stations or not isinstance(stations[0], dict) or not stations[0].get("id"):
            raise ValueError("No TideCheck station found")

        station = stations[0]
        self._remember(self._station_cache, identity, _CacheItem(
            expires_at=now + timedelta(days=30),
            data=station,
        ))
        self._write_persistent(f"tidecheck:v3:station:{identity}", station)
        return station

    def _read_persistent_tides(
        self,
        cache_key: str,
    ) -> tuple[TideForecast, datetime] | None:
        cached = self._read_persistent(
            f"tidecheck:v3:tides:{cache_key}",
            timedelta(hours=12),
        )
        if cached is None:
            return None
        payload, updated_at = cached
        try:
            forecast = TideForecast.model_validate(payload)
        except (ValueError, TypeError):
            return None
        now = datetime.now(UTC)
        if updated_at > now + timedelta(minutes=1) or not self._valid_forecast_time(forecast, now):
            return None
        return forecast, updated_at

    def _read_persistent_station(
        self,
        spot_id: str,
    ) -> tuple[dict[str, Any], datetime] | None:
        cached = self._read_persistent(
            f"tidecheck:v3:station:{spot_id}",
            timedelta(days=30),
        )
        if cached is None:
            return None
        station, updated_at = cached
        if not isinstance(station, dict) or not station.get("id") or updated_at > datetime.now(UTC) + timedelta(minutes=1):
            return None
        return station, updated_at

    def _read_persistent(
        self,
        cache_key: str,
        max_age: timedelta,
    ) -> tuple[dict[str, Any], datetime] | None:
        if self._persistent_cache is None:
            return None
        try:
            cached = self._persistent_cache.get(cache_key, max_age)
            if cached is None:
                return None
            return cached.payload, cached.updated_at
        except Exception:
            logger.exception("Could not read persistent TideCheck cache %s", cache_key)
            return None

    def _write_persistent(
        self,
        cache_key: str,
        payload: dict[str, Any],
    ) -> None:
        if self._persistent_cache is None:
            return
        try:
            self._persistent_cache.set(cache_key, payload)
        except Exception:
            logger.exception("Could not persist TideCheck cache %s", cache_key)

    def _to_tide_forecast(
        self,
        spot: Spot,
        station: dict[str, Any],
        payload: dict[str, Any],
        *,
        start_day: date | None = None,
        days: int = 3,
    ) -> TideForecast:
        station_payload = payload.get("station", {})
        if not isinstance(station_payload, dict):
            station_payload = {}
        timezone_name = station_payload.get("timezone") or station.get("timezone") or "UTC"
        try:
            timezone = ZoneInfo(timezone_name)
        except (ValueError, KeyError, TypeError):
            # Prefer a valid station timezone to a malformed response field.
            timezone_name = station.get("timezone") or "UTC"
            try:
                timezone = ZoneInfo(timezone_name)
            except (ValueError, KeyError, TypeError):
                timezone_name, timezone = "UTC", ZoneInfo("UTC")
        events = []
        for item in _payload_rows(payload, "extremes"):
            if item.get("type") not in {"high", "low"}:
                continue
            try:
                event = self._to_tide_event(item, timezone)
                if event.time.tzinfo is not None:
                    events.append(event)
            except (ValueError, KeyError, TypeError):
                continue
        samples = []
        for item in _payload_rows(payload, "timeSeries"):
            try:
                stamp = datetime.fromisoformat(str(item["time"]).replace("Z", "+00:00"))
                height = _as_float(item.get("height"), digits=3)
                if stamp.tzinfo is None or height is None:
                    continue
                local_stamp = stamp.astimezone(timezone)
                samples.append(TideSample(
                    time=stamp.astimezone(UTC), height_m=height,
                    local_date=local_stamp.date(), local_time=local_stamp.strftime("%H:%M"),
                ))
            except (ValueError, KeyError, TypeError):
                continue
        if start_day is not None:
            end_day = start_day + timedelta(days=days)
            events = [event for event in events if start_day <= event.local_date < end_day]
            samples = [sample for sample in samples if start_day <= sample.local_date < end_day]
        samples = sorted({sample.time: sample for sample in samples}.values(), key=lambda sample: sample.time)
        events = sorted({(event.time, event.type): event for event in events}.values(), key=lambda event: event.time)

        return TideForecast(
            spot_id=spot.id,
            available=bool(events or samples),
            station_name=station_payload.get("name") or station.get("name"),
            station_distance_km=_as_float(station.get("distanceKm")),
            source="tidecheck",
            events=events[:28],
            samples=samples[:7 * 24 * 4 + 1],
            timezone=timezone_name,
            datum=str(payload["datum"]) if payload.get("datum") else None,
            fetched_at=datetime.now(UTC),
            note=(
                "Tide times are estimates for surf planning, not navigation."
                if events or samples
                else "Tide data is unavailable right now."
            ),
        )

    def _to_tide_event(self, item: dict[str, Any], timezone: ZoneInfo) -> TideEvent:
        stamp = datetime.fromisoformat(item["time"].replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            raise ValueError("Tide event is missing a timezone")
        local_stamp = stamp.astimezone(timezone)
        return TideEvent(
            type=item["type"],
            time=stamp,
            local_time=local_stamp.strftime("%-I:%M %p"),
            local_date=local_stamp.date(),
            height_m=_as_float(item.get("height")),
        )


def _payload_rows(payload: dict[str, Any], key: str) -> list[dict[str, Any]]:
    rows = payload.get(key)
    return [item for item in rows if isinstance(item, dict)] if isinstance(rows, list) else []


def _as_float(value: Any, *, digits: int = 1) -> float | None:
    if value is None:
        return None
    try:
        numeric = float(value)
    except (ValueError, TypeError):
        return None
    return round(numeric, digits) if math.isfinite(numeric) else None


def _load_api_key() -> str:
    env_key = os.getenv("TIDECHECK_API_KEY", "").strip()
    if env_key:
        return env_key

    api_dir = Path(__file__).resolve().parents[3]
    repo_dir = api_dir.parents[1]
    for env_path in (api_dir / ".env", repo_dir / ".env"):
        key = _read_env_value(env_path, "TIDECHECK_API_KEY")
        if key:
            return key
    return ""


def _read_env_value(path: Path, name: str) -> str:
    if not path.exists():
        return ""
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        if key.strip() == name:
            return value.strip().strip("'\"")
    return ""
