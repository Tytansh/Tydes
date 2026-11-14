from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
import logging
import math
import os
from threading import RLock
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx

from app.core.models import (
    DetailedForecastHour, DetailedSpotForecast, ForecastDaylight, ForecastEntry,
    Spot, SurfWindowForecast, SurfWindowHour,
)
from app.core.persistent_cache import PostgresJsonCache
from app.core.rate_limit import RateLimitRule, api_rate_limiter


logger = logging.getLogger(__name__)

FRESH_FORECAST_MAX_AGE = timedelta(hours=3)
PREVIEW_FORECAST_MAX_AGE = timedelta(hours=24)
FREE_FORECAST_MAX_AGE = timedelta(days=5)
STALE_FORECAST_MAX_AGE = timedelta(hours=12)
PARTIAL_FORECAST_MAX_AGE = timedelta(minutes=1)
FREE_MARINE_BASE_URL = "https://marine-api.open-meteo.com/v1"
FREE_FORECAST_BASE_URL = "https://api.open-meteo.com/v1"
CUSTOMER_MARINE_BASE_URL = "https://customer-marine-api.open-meteo.com/v1"
CUSTOMER_FORECAST_BASE_URL = "https://customer-api.open-meteo.com/v1"
CACHE_PREFIX = "open-meteo:v3"
MARINE_VARIABLES = (
    "wave_height", "wave_period", "wave_direction",
    "swell_wave_height", "swell_wave_period", "swell_wave_peak_period",
    "swell_wave_direction", "secondary_swell_wave_height",
    "secondary_swell_wave_period", "secondary_swell_wave_direction",
    "wind_wave_height", "wind_wave_period", "wind_wave_direction",
    "sea_surface_temperature",
)
WEATHER_VARIABLES = ("wind_speed_10m", "wind_direction_10m", "wind_gusts_10m", "is_day")
_UPSTREAM_POOL = ThreadPoolExecutor(max_workers=8, thread_name_prefix="marine-upstream")
_STALE_NOTE = "Showing a previously fetched model forecast while the latest refresh is unavailable. Check the fetch time; this is not a current observation."
_WEATHER_NOTE = "Wind and daylight data are temporarily unavailable; the wave and swell data shown are still from the marine model."


@dataclass
class _CacheItem:
    fetched_at: datetime
    data: list[ForecastEntry]
    hourly_rows: list[dict[str, float | str | None]]
    timezone: str = "UTC"
    utc_offset_seconds: int = 0
    days: list[ForecastDaylight] | None = None
    weather_available: bool = True


class OpenMeteoMarineProvider:
    """Fetch marine forecasts with memory and restart-safe database caches."""

    def __init__(self) -> None:
        self._api_key = os.getenv("OPEN_METEO_API_KEY", "").strip()
        marine_base_url = os.getenv(
            "OPEN_METEO_MARINE_BASE_URL",
            CUSTOMER_MARINE_BASE_URL if self._api_key else FREE_MARINE_BASE_URL,
        ).strip()
        forecast_base_url = os.getenv(
            "OPEN_METEO_FORECAST_BASE_URL",
            CUSTOMER_FORECAST_BASE_URL if self._api_key else FREE_FORECAST_BASE_URL,
        ).strip()
        self._marine_client = httpx.Client(
            base_url=marine_base_url,
            timeout=httpx.Timeout(12.0, connect=5.0, pool=5.0),
        )
        self._forecast_client = httpx.Client(
            base_url=forecast_base_url,
            timeout=httpx.Timeout(12.0, connect=5.0, pool=5.0),
        )
        self._cache: dict[str, _CacheItem] = {}
        self._persistent_cache = PostgresJsonCache.from_env()
        self._locks_guard = RLock()
        self._spot_locks: dict[str, RLock] = {}
        self._retry_after: dict[str, datetime] = {}
        self._fallback_notes: dict[str, str] = {}

    def fetch_spot_forecast(
        self,
        spot: Spot,
        *,
        max_cache_age: timedelta = FRESH_FORECAST_MAX_AGE,
    ) -> list[ForecastEntry]:
        identity = self._cache_identity(spot)
        with self._locks_guard:
            lock = self._spot_locks.setdefault(identity, RLock())
        # A simultaneous chart, daily forecast and surf-window request must share
        # one upstream fetch rather than consume three lots of API credits.
        with lock:
            now = datetime.now(UTC)
            cached = self._cache.get(identity)
            if cached and self._cache_is_current(cached, now, max_cache_age):
                self._fallback_notes.pop(identity, None)
                return self._current_entries(cached, now)
            persistent = self._read_persistent_cache(identity, max_cache_age)
            if persistent is not None and self._cache_is_current(persistent, now, max_cache_age):
                self._cache[identity] = persistent
                self._fallback_notes.pop(identity, None)
                return self._current_entries(persistent, now)
            if self._retry_after.get(identity, now) > now:
                fallback = self._usable_fallback(identity, cached, now)
                if fallback is not None:
                    return self._fallback_entries(identity, fallback, now)
                raise RuntimeError("Forecast provider is temporarily backing off")
            try:
                self._reserve_upstream_budget()
                item = self._fetch_cache_item(spot, now)
            except Exception as error:
                # Never turn absent observations into zero or hit the provider
                # repeatedly while it is unavailable/rate limited.
                status = getattr(getattr(error, "response", None), "status_code", None)
                self._retry_after[identity] = now + timedelta(minutes=5 if status == 429 else 1)
                fallback = self._usable_fallback(identity, cached, now)
                if fallback is not None:
                    return self._fallback_entries(identity, fallback, now)
                raise
            self._cache[identity] = item
            self._retry_after.pop(identity, None)
            self._fallback_notes.pop(identity, None)
            self._write_persistent_cache(identity, item)
            return self._current_entries(item, now)

    @staticmethod
    def _cache_identity(spot: Spot) -> str:
        # Coordinates are part of identity, not just the public spot ID. A
        # catalog correction must never reuse forecasts for the old location.
        # repr preserves the exact catalog float rather than grouping cells.
        return f"{spot.id}:{spot.latitude!r}:{spot.longitude!r}"

    def _fetch_cache_item(self, spot: Spot, now: datetime) -> _CacheItem:
        marine_params = self._with_api_key(
            {
                "latitude": spot.latitude,
                "longitude": spot.longitude,
                "hourly": ",".join(MARINE_VARIABLES),
                "forecast_days": 5,
                "timezone": "auto",
                "timeformat": "unixtime",
                "cell_selection": "sea",
            }
        )
        weather_params = self._with_api_key(
            {
                "latitude": spot.latitude,
                "longitude": spot.longitude,
                "hourly": ",".join(WEATHER_VARIABLES),
                "daily": "sunrise,sunset",
                "forecast_days": 5,
                "timezone": "auto",
                "timeformat": "unixtime",
                "wind_speed_unit": "kn",
                "cell_selection": "sea",
            }
        )
        # Independent upstreams run together, not as two serial network waits.
        # A weather outage must not discard an otherwise valid wave forecast.
        marine_future = _UPSTREAM_POOL.submit(
            self._request_payload, self._marine_client, "/marine", marine_params, 2,
        )
        weather_future = _UPSTREAM_POOL.submit(
            self._request_payload, self._forecast_client, "/forecast", weather_params, 1,
        )
        marine_payload = marine_future.result()
        weather_available = True
        try:
            weather_payload = weather_future.result()
        except Exception as error:
            logger.warning("Forecast weather component unavailable for %s (%s)", spot.id, type(error).__name__)
            weather_payload = {}
            weather_available = False
        if not marine_payload.get("timezone"):
            marine_payload = {**marine_payload, "timezone": spot_timezone_name(spot)}
        rows = self._to_hourly_rows(marine_payload, weather_payload)
        if not any(row.get("wave_height") is not None for row in rows):
            raise ValueError("Marine model returned no wave data")
        timezone_name = str(marine_payload.get("timezone") or spot_timezone_name(spot))
        return _CacheItem(
            fetched_at=now,
            data=self._to_daily_forecasts_from_rows(spot, rows),
            hourly_rows=rows,
            timezone=timezone_name,
            utc_offset_seconds=(
                int(marine_payload["utc_offset_seconds"])
                if marine_payload.get("utc_offset_seconds") is not None
                else int(now.astimezone(_zone(timezone_name)).utcoffset().total_seconds())
            ),
            days=_daylight_days(weather_payload, timezone_name),
            weather_available=weather_available,
        )

    def _request_payload(
        self, client, path: str, params: dict[str, Any], retry_units: int,
    ) -> dict[str, Any]:
        for attempt in range(2):
            try:
                response = client.get(path, params=params)
                response.raise_for_status()
                return response.json()
            except (httpx.TransportError, httpx.HTTPStatusError) as error:
                status = getattr(getattr(error, "response", None), "status_code", None)
                transient = (
                    isinstance(error, (
                        httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadError,
                        httpx.ReadTimeout, httpx.RemoteProtocolError,
                    ))
                    or status in {502, 503, 504}
                )
                if attempt or not transient:
                    raise
                # Retries are never free bypasses around the application cap.
                self._reserve_budget_units(retry_units)
        raise RuntimeError("Forecast request did not complete")

    @staticmethod
    def _reserve_upstream_budget() -> None:
        # Open-Meteo counts >10 variables fractionally. Reserve a conservative
        # rounded-up unit count for both requests BEFORE either starts. This is
        # an application guardrail, not a provider-account spending guarantee.
        units = math.ceil(len(MARINE_VARIABLES) / 10) + math.ceil((len(WEATHER_VARIABLES) + 2) / 10)
        OpenMeteoMarineProvider._reserve_budget_units(units)

    @staticmethod
    def _reserve_budget_units(units: int) -> None:
        try:
            limit = max(1, min(int(os.getenv("OPEN_METEO_DAILY_CREDIT_BUDGET", "3000")), 100_000))
        except ValueError:
            limit = 3000
        for _ in range(units):
            api_rate_limiter.enforce(RateLimitRule(
                scope="upstream:open-meteo-credit-budget",
                key="all-forecast-requests",
                limit=limit,
                window_seconds=24 * 60 * 60,
            ))

    @staticmethod
    def _cache_is_current(item: _CacheItem, now: datetime, max_age: timedelta) -> bool:
        local_day = now.astimezone(_zone(item.timezone)).date()
        if not item.weather_available:
            max_age = min(max_age, PARTIAL_FORECAST_MAX_AGE)
        return (
            -timedelta(minutes=1) <= now - item.fetched_at <= max_age
            and bool(item.data)
            and min(entry.day for entry in item.data) == local_day
        )

    @staticmethod
    def _current_entries(item: _CacheItem, now: datetime) -> list[ForecastEntry]:
        local_day = now.astimezone(_zone(item.timezone)).date()
        return [entry for entry in item.data if entry.day >= local_day]

    def _usable_fallback(
        self, identity: str, cached: _CacheItem | None, now: datetime,
    ) -> _CacheItem | None:
        candidates = [cached]
        if cached is None or not self._has_usable_future_hours(cached, now):
            candidates.append(self._read_persistent_cache(identity, STALE_FORECAST_MAX_AGE))
        for item in candidates:
            if item is not None and self._has_usable_future_hours(item, now):
                return item
        return None

    @staticmethod
    def _has_usable_future_hours(item: _CacheItem, now: datetime) -> bool:
        if not (-timedelta(minutes=1) <= now - item.fetched_at <= STALE_FORECAST_MAX_AGE):
            return False
        for row in item.hourly_rows:
            try:
                wave = row.get("wave_height")
                if (
                    wave is not None and math.isfinite(float(wave))
                    and _utc_stamp(row.get("time_utc") or row["time"], item.timezone) >= now
                ):
                    return True
            except (KeyError, TypeError, ValueError, OverflowError):
                continue
        return False

    def _fallback_entries(
        self, identity: str, item: _CacheItem, now: datetime,
    ) -> list[ForecastEntry]:
        self._cache[identity] = item
        self._fallback_notes[identity] = _STALE_NOTE
        # Cached outage fallback must never trigger a "conditions now" alert.
        return [
            entry.model_copy(update={
                "confidence": "estimated", "confidence_note": _STALE_NOTE,
            })
            for entry in self._current_entries(item, now)
        ]

    def fetch_spot_detail(self, spot: Spot) -> DetailedSpotForecast:
        self.fetch_spot_forecast(spot)
        cached = self._cache[self._cache_identity(spot)]
        local_day = datetime.now(UTC).astimezone(_zone(cached.timezone)).date()
        hours = [
            _detail_hour(row, cached.timezone)
            for row in cached.hourly_rows
            if date.fromisoformat(str(row["day"])) >= local_day
        ]
        return DetailedSpotForecast(
            spot_id=spot.id, available=bool(hours), timezone=cached.timezone,
            utc_offset_seconds=cached.utc_offset_seconds,
            fetched_at=cached.fetched_at, local_date=local_day, hours=hours,
            days=[day for day in (cached.days or []) if day.day >= local_day],
            weather_model="Best Match (automatic)" if cached.weather_available else "Temporarily unavailable",
            note=" ".join(filter(None, [
                "Numerical model forecast, not an observed surf report. Wave height is significant combined sea height, not breaking-wave face height. Secondary swell may be unavailable for the automatically selected model.",
                None if cached.weather_available else _WEATHER_NOTE,
                self._fallback_notes.get(self._cache_identity(spot)),
            ])),
        )

    def fetch_spot_surf_window(
        self,
        spot: Spot,
        *,
        max_cache_age: timedelta = FRESH_FORECAST_MAX_AGE,
    ) -> SurfWindowForecast:
        self.fetch_spot_forecast(spot, max_cache_age=max_cache_age)
        cached = self._cache.get(self._cache_identity(spot))
        if cached is None:
            return SurfWindowForecast(
                spot_id=spot.id,
                available=False,
                note="Hourly forecast is unavailable right now.",
            )
        result = _best_surf_window(spot, cached.hourly_rows, timezone_name=cached.timezone)
        if self._cache_identity(spot) in self._fallback_notes:
            return result.model_copy(update={"confidence": "estimated", "note": _STALE_NOTE})
        return result

    def _with_api_key(self, params: dict[str, Any]) -> dict[str, Any]:
        if not self._api_key:
            return params
        return {**params, "apikey": self._api_key}

    def _read_persistent_cache(
        self,
        spot_id: str,
        max_cache_age: timedelta,
    ) -> _CacheItem | None:
        if self._persistent_cache is None:
            return None
        try:
            cached = self._persistent_cache.get(
                f"{CACHE_PREFIX}:{spot_id}",
                max_cache_age,
            )
            if cached is None:
                return None
            forecasts = [
                ForecastEntry.model_validate(item)
                for item in cached.payload.get("forecasts", [])
            ]
            hourly_rows = [
                dict(item) for item in cached.payload.get("hourly_rows", [])
            ]
            if not forecasts:
                return None
            return _CacheItem(
                fetched_at=cached.updated_at,
                data=forecasts,
                hourly_rows=hourly_rows,
                timezone=str(cached.payload.get("timezone") or "UTC"),
                utc_offset_seconds=int(cached.payload.get("utc_offset_seconds") or 0),
                days=[ForecastDaylight.model_validate(day) for day in cached.payload.get("days", [])],
                weather_available=bool(cached.payload.get("weather_available", True)),
            )
        except Exception:
            logger.exception("Could not read cached Open-Meteo forecast for %s", spot_id)
            return None

    def _write_persistent_cache(
        self,
        spot_id: str,
        cache_item: _CacheItem,
    ) -> None:
        if self._persistent_cache is None:
            return
        try:
            self._persistent_cache.set(
                f"{CACHE_PREFIX}:{spot_id}",
                {
                    "forecasts": [
                        item.model_dump(mode="json") for item in cache_item.data
                    ],
                    "hourly_rows": cache_item.hourly_rows,
                    "timezone": cache_item.timezone,
                    "utc_offset_seconds": cache_item.utc_offset_seconds,
                    "days": [day.model_dump(mode="json") for day in (cache_item.days or [])],
                    "weather_available": cache_item.weather_available,
                },
            )
        except Exception:
            logger.exception("Could not persist Open-Meteo forecast for %s", spot_id)

    def _to_daily_forecasts(
        self,
        spot: Spot,
        marine_payload: dict[str, Any],
        weather_payload: dict[str, Any],
    ) -> list[ForecastEntry]:
        hourly_rows = self._to_hourly_rows(marine_payload, weather_payload)
        return self._to_daily_forecasts_from_rows(spot, hourly_rows)

    def _to_hourly_rows(
        self,
        marine_payload: dict[str, Any],
        weather_payload: dict[str, Any],
    ) -> list[dict[str, float | str | None]]:
        hourly = marine_payload.get("hourly", {})
        timezone_name = str(marine_payload.get("timezone") or "UTC")
        weather_zone = str(weather_payload.get("timezone") or timezone_name)
        weather_hourly = weather_payload.get("hourly", {})
        weather_rows = {
            _utc_stamp(stamp, weather_zone): {
                name: _optional_value(weather_hourly.get(name, []), index)
                for name in WEATHER_VARIABLES
            }
            for index, stamp in enumerate(weather_hourly.get("time", []))
        }
        rows = []
        for index, stamp in enumerate(hourly.get("time", [])):
            utc_time = _utc_stamp(stamp, timezone_name)
            local_time = utc_time.astimezone(_zone(timezone_name))
            row = {
                "time": local_time.isoformat(),
                "time_utc": utc_time.isoformat(),
                "day": local_time.date().isoformat(),
                **{name: _optional_value(hourly.get(name, []), index) for name in MARINE_VARIABLES},
            }
            weather = weather_rows.get(utc_time, {})
            row.update({
                "wind_speed": weather.get("wind_speed_10m"),
                "wind_gusts": weather.get("wind_gusts_10m"),
                "wind_direction": weather.get("wind_direction_10m"),
                "is_day": weather.get("is_day"),
            })
            rows.append(row)
        return rows

    def _to_daily_forecasts_from_rows(
        self,
        spot: Spot,
        hourly_rows: list[dict[str, float | str | None]],
    ) -> list[ForecastEntry]:
        grouped: dict[str, list[dict[str, Any]]] = {}
        for row in hourly_rows:
            day_key = str(row["day"])
            grouped.setdefault(day_key, []).append(row)

        forecasts: list[ForecastEntry] = []
        for index, (day_key, rows) in enumerate(grouped.items(), start=1):
            avg_wave = _average(row["wave_height"] for row in rows)
            avg_period = _average(row["wave_period"] for row in rows)
            avg_wind_wave = _average(row["wind_wave_height"] for row in rows)
            avg_swell_wave = _average(row["swell_wave_height"] for row in rows)
            avg_wave_direction = _average_direction(
                row["wave_direction"] for row in rows
            )
            avg_swell_direction = _average_direction(
                row["swell_wave_direction"] for row in rows
            )
            avg_temp = _average(row["sea_surface_temperature"] for row in rows)
            avg_wind_speed = _average(row["wind_speed"] for row in rows)

            forecasts.append(
                ForecastEntry(
                    id=f"live_{spot.id}_{index}",
                    spot_id=spot.id,
                    day=datetime.strptime(day_key, "%Y-%m-%d").date(),
                    wave_height_m=_round_optional(avg_wave),
                    period_s=round(avg_period) if avg_period is not None else None,
                    wind_kts=_round_optional(avg_wind_speed),
                    quality=_quality_for(avg_wave, avg_period),
                    swell_wave_height_m=_round_optional(avg_swell_wave),
                    swell_wave_direction_deg=avg_swell_direction,
                    wind_wave_height_m=_round_optional(avg_wind_wave),
                    wave_direction_deg=avg_wave_direction,
                    sea_surface_temperature_c=_round_optional(avg_temp),
                    source="open-meteo",
                    confidence="live",
                    confidence_note="Numerical model forecast. Significant sea height is not breaking-wave face height; the legacy quality label is not an observed surf rating.",
                )
            )
        return forecasts


def _optional_value(values: list[Any], index: int) -> float | None:
    try:
        value = values[index]
    except IndexError:
        return None
    if value is None:
        return None
    try:
        numeric = float(value)
    except (ValueError, TypeError):
        return None
    return numeric if math.isfinite(numeric) else None


def _direction_value(value: Any) -> float | None:
    if value is None:
        return None
    return float(value) % 360


def _round_optional(value: float | None, digits: int = 1) -> float | None:
    return round(value, digits) if value is not None else None


def _zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def spot_timezone_name(spot: Spot) -> str:
    """Regional IANA fallback only; provider timezone takes precedence."""
    if spot.country == "Australia":
        return {
            "Western Australia": "Australia/Perth",
            "South Australia": "Australia/Adelaide",
            "Northern Territory": "Australia/Darwin",
            "Queensland": "Australia/Brisbane",
            "Tasmania": "Australia/Hobart",
            "Victoria": "Australia/Melbourne",
        }.get(spot.region, "Australia/Sydney")
    if spot.country == "Indonesia":
        return "Asia/Jakarta" if spot.region in {"Java", "Sumatra", "Mentawai", "Banyak Islands", "Nias"} else "Asia/Makassar"
    return {
        "Taiwan": "Asia/Taipei", "Philippines": "Asia/Manila",
        "Sri Lanka": "Asia/Colombo", "Thailand": "Asia/Bangkok",
        "Vietnam": "Asia/Ho_Chi_Minh", "Malaysia": "Asia/Kuala_Lumpur",
        "Myanmar": "Asia/Yangon", "Timor-Leste": "Asia/Dili",
    }.get(spot.country, "UTC")


def spot_local_date(spot: Spot) -> date:
    return datetime.now(UTC).astimezone(_zone(spot_timezone_name(spot))).date()


def _utc_stamp(value: Any, timezone_name: str = "UTC") -> datetime:
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, UTC)
    stamp = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=_zone(timezone_name))
    return stamp.astimezone(UTC)


def _daylight_days(payload: dict[str, Any], timezone_name: str) -> list[ForecastDaylight]:
    daily = payload.get("daily", {})
    zone = _zone(timezone_name)
    days = []
    for index, value in enumerate(daily.get("time", [])):
        stamp = _utc_stamp(value, timezone_name) if not (isinstance(value, str) and len(value) == 10) else None
        day = stamp.astimezone(zone).date() if stamp else date.fromisoformat(value)
        def daylight(name: str) -> str | None:
            values = daily.get(name, [])
            if index >= len(values) or values[index] is None:
                return None
            return _utc_stamp(values[index], timezone_name).astimezone(zone).isoformat()
        days.append(ForecastDaylight(day=day, sunrise=daylight("sunrise"), sunset=daylight("sunset")))
    return days


def _detail_hour(row: dict[str, Any], timezone_name: str) -> DetailedForecastHour:
    stamp = _utc_stamp(row.get("time_utc") or row["time"], timezone_name)
    local = stamp.astimezone(_zone(timezone_name))
    return DetailedForecastHour(
        time=stamp, local_date=local.date(), local_time=local.strftime("%H:%M"),
        is_day=bool(row["is_day"]) if row.get("is_day") is not None else None,
        wave_height_m=row.get("wave_height"), wave_period_s=row.get("wave_period"),
        wave_direction_deg=row.get("wave_direction"),
        swell_height_m=row.get("swell_wave_height"), swell_period_s=row.get("swell_wave_period"),
        swell_peak_period_s=row.get("swell_wave_peak_period"), swell_direction_deg=row.get("swell_wave_direction"),
        secondary_swell_height_m=row.get("secondary_swell_wave_height"),
        secondary_swell_period_s=row.get("secondary_swell_wave_period"),
        secondary_swell_direction_deg=row.get("secondary_swell_wave_direction"),
        wind_wave_height_m=row.get("wind_wave_height"), wind_wave_period_s=row.get("wind_wave_period"),
        wind_wave_direction_deg=row.get("wind_wave_direction"), wind_kts=row.get("wind_speed"),
        wind_gusts_kts=row.get("wind_gusts"), wind_direction_deg=row.get("wind_direction"),
        sea_surface_temperature_c=row.get("sea_surface_temperature"),
    )


def _average(values: Any) -> float | None:
    data = [float(value) for value in values if value is not None and math.isfinite(float(value))]
    if not data:
        return None
    return sum(data) / len(data)


def _average_direction(values: Any) -> int | None:
    data = [float(value) % 360 for value in values if value is not None]
    if not data:
        return None

    sin_sum = sum(math.sin(math.radians(value)) for value in data)
    cos_sum = sum(math.cos(math.radians(value)) for value in data)
    if abs(sin_sum) < 1e-9 and abs(cos_sum) < 1e-9:
        return None

    degrees = round(math.degrees(math.atan2(sin_sum, cos_sum)) % 360)
    return 0 if degrees == 360 else degrees


def _quality_for(wave_height_m: float | None, period_s: float | None) -> str:
    if wave_height_m is None or period_s is None:
        return "poor"
    score = wave_height_m + (period_s / 10)
    if score >= 3.2:
        return "epic"
    if score >= 2.4:
        return "good"
    if score >= 1.5:
        return "fair"
    return "poor"


def _best_surf_window(
    spot: Spot,
    hourly_rows: list[dict[str, float | str]],
    *,
    timezone_name: str = "UTC",
    now: datetime | None = None,
) -> SurfWindowForecast:
    if not hourly_rows:
        return SurfWindowForecast(
            spot_id=spot.id,
            available=False,
            note="Hourly forecast is unavailable right now.",
        )

    local_now = (now or datetime.now(UTC)).astimezone(_zone(timezone_name))
    day_key = local_now.date().isoformat()
    today_rows = [
        row
        for row in hourly_rows
        if row["day"] == day_key
        and (bool(row["is_day"]) if row.get("is_day") is not None else 5 <= _hour_from_stamp(str(row["time"])) <= 18)
        and all(row.get(key) is not None for key in ("wave_height", "wave_period", "wind_speed"))
    ]
    if len(today_rows) < 3:
        return SurfWindowForecast(
            spot_id=spot.id,
            available=False,
            note="Not enough hourly data for today's surf window.",
        )

    scored_rows = [
        {
            **row,
            "score": _surf_window_score(
                float(row["wave_height"]),
                float(row["wave_period"]),
                float(row["wind_speed"]),
            ),
        }
        for row in today_rows
    ]
    slices = [
        scored_rows[index : index + 3]
        for index in range(len(scored_rows) - 2)
        if _utc_stamp(scored_rows[index]["time"], timezone_name) >= local_now.replace(minute=0, second=0, microsecond=0)
        and _utc_stamp(scored_rows[index + 2]["time"], timezone_name) - _utc_stamp(scored_rows[index]["time"], timezone_name) == timedelta(hours=2)
    ]
    if not slices:
        return SurfWindowForecast(spot_id=spot.id, available=False, day=local_now.date(), note="Not enough remaining daylight data for a three-hour planning window today.")
    best_slice = max(
        slices,
        key=lambda rows: _average(row["score"] for row in rows),
    )
    avg_score = _average(row["score"] for row in best_slice)
    avg_wave = _average(float(row["wave_height"]) for row in best_slice)
    avg_period = _average(float(row["wave_period"]) for row in best_slice)
    avg_wind = _average(float(row["wind_speed"]) for row in best_slice)
    start_label = _hour_label(str(best_slice[0]["time"]))
    end_hour = (_hour_from_stamp(str(best_slice[-1]["time"])) + 1) % 24
    end_label = _display_hour(end_hour)
    rating = _window_rating(avg_score)

    return SurfWindowForecast(
        spot_id=spot.id,
        available=True,
        day=datetime.strptime(day_key, "%Y-%m-%d").date(),
        best_start_label=start_label,
        best_end_label=end_label,
        rating=rating,
        summary=(
            f"Best window: {start_label} - {end_label}. "
            f"Average {avg_wave:.1f}m significant sea height, {round(avg_period)}s period, "
            f"{avg_wind:.1f}kts wind."
        ),
        hours=[
            SurfWindowHour(
                time=str(row["time"]),
                label=_hour_label(str(row["time"])),
                wave_height_m=round(float(row["wave_height"]), 1),
                period_s=max(1, round(float(row["wave_period"]))),
                wind_kts=max(0, round(float(row["wind_speed"]), 1)),
                score=round(float(row["score"]), 2),
            )
            for row in scored_rows
        ],
        note="Simple model-based wave, period and wind planning index, not an observed or spot-calibrated surf rating. Check local conditions and hazards.",
    )


def _surf_window_score(wave_height_m: float, period_s: float, wind_kts: float) -> float:
    wave_score = min(wave_height_m / 2.0, 1.25)
    period_score = min(period_s / 14.0, 1.25)
    wind_score = max(0.0, 1.0 - (wind_kts / 24.0))
    return round((wave_score * 0.45) + (period_score * 0.35) + (wind_score * 0.20), 3)


def _window_rating(score: float) -> str:
    if score >= 0.95:
        return "epic"
    if score >= 0.78:
        return "good"
    if score >= 0.58:
        return "fair"
    return "poor"


def _hour_label(stamp: str) -> str:
    return _display_hour(_hour_from_stamp(stamp))


def _hour_from_stamp(stamp: str) -> int:
    return int(stamp.split("T")[1].split(":")[0])


def _display_hour(hour: int) -> str:
    suffix = "AM" if hour < 12 else "PM"
    display_hour = hour % 12 or 12
    return f"{display_hour} {suffix}"
