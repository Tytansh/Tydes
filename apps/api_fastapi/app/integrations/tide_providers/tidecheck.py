from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
import logging
import os
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from app.core.models import Spot, TideEvent, TideForecast
from app.core.persistent_cache import PostgresJsonCache

logger = logging.getLogger(__name__)


@dataclass
class _CacheItem:
    expires_at: datetime
    data: Any


class TideCheckProvider:
    """Fetch high/low tide predictions from TideCheck behind a swappable provider."""

    def __init__(self) -> None:
        self._api_key = _load_api_key()
        self._client = httpx.Client(base_url="https://tidecheck.com", timeout=8.0)
        self._station_cache: dict[str, _CacheItem] = {}
        self._tide_cache: dict[str, _CacheItem] = {}
        self._persistent_cache = PostgresJsonCache.from_env()

    def fetch_spot_tides(self, spot: Spot, start_day: date, days: int = 3) -> TideForecast:
        now = datetime.now(UTC)
        cache_key = f"{spot.id}:{start_day.isoformat()}:{days}"
        cached = self._tide_cache.get(cache_key)
        if cached and cached.expires_at > now:
            return cached.data

        persistent = self._read_persistent_tides(cache_key)
        if persistent is not None:
            forecast, updated_at = persistent
            self._tide_cache[cache_key] = _CacheItem(
                expires_at=updated_at + timedelta(hours=12),
                data=forecast,
            )
            return forecast

        if not self._api_key:
            return TideForecast(
                spot_id=spot.id,
                available=False,
                note="Tide provider is not configured yet.",
            )

        try:
            station = self._nearest_station(spot)
            response = self._client.get(
                f"/api/station/{station['id']}/tides",
                headers={"X-API-Key": self._api_key},
                params={
                    "datum": "LAT",
                    "days": max(1, min(days, 7)),
                    "start": start_day.isoformat(),
                },
            )
            response.raise_for_status()
            forecast = self._to_tide_forecast(spot, station, response.json())
        except httpx.HTTPStatusError as error:
            status_code = error.response.status_code
            if status_code == 429:
                internal_note = "TideCheck daily limit reached."
                user_note = (
                    "TideCheck daily rate limit exceeded. Live tides will work "
                    "again when the plan resets or the TideCheck plan is upgraded."
                )
            elif status_code == 401:
                internal_note = "TideCheck API key is invalid."
                user_note = "TideCheck API key is invalid."
            elif status_code == 403:
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
            logger.warning("Tide data unavailable for %s: %s", spot.id, error)
            forecast = TideForecast(
                spot_id=spot.id,
                available=False,
                source="tidecheck",
                note="Tide data is unavailable right now.",
            )

        if forecast.available:
            self._tide_cache[cache_key] = _CacheItem(
                expires_at=now + timedelta(hours=12),
                data=forecast,
            )
            self._write_persistent(
                f"tidecheck:tides:{cache_key}",
                forecast.model_dump(mode="json"),
            )
        return forecast

    def _nearest_station(self, spot: Spot) -> dict[str, Any]:
        now = datetime.now(UTC)
        cached = self._station_cache.get(spot.id)
        if cached and cached.expires_at > now:
            return cached.data

        persistent = self._read_persistent_station(spot.id)
        if persistent is not None:
            station, updated_at = persistent
            self._station_cache[spot.id] = _CacheItem(
                expires_at=updated_at + timedelta(days=30),
                data=station,
            )
            return station

        response = self._client.get(
            "/api/stations/nearest",
            headers={"X-API-Key": self._api_key},
            params={"lat": spot.latitude, "lng": spot.longitude},
        )
        response.raise_for_status()
        stations = response.json()
        if not stations:
            raise ValueError("No TideCheck station found")

        station = stations[0]
        self._station_cache[spot.id] = _CacheItem(
            expires_at=now + timedelta(days=30),
            data=station,
        )
        self._write_persistent(f"tidecheck:station:{spot.id}", station)
        return station

    def _read_persistent_tides(
        self,
        cache_key: str,
    ) -> tuple[TideForecast, datetime] | None:
        cached = self._read_persistent(
            f"tidecheck:tides:{cache_key}",
            timedelta(hours=12),
        )
        if cached is None:
            return None
        payload, updated_at = cached
        return TideForecast.model_validate(payload), updated_at

    def _read_persistent_station(
        self,
        spot_id: str,
    ) -> tuple[dict[str, Any], datetime] | None:
        return self._read_persistent(
            f"tidecheck:station:{spot_id}",
            timedelta(days=30),
        )

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
    ) -> TideForecast:
        station_payload = payload.get("station", {})
        timezone_name = station_payload.get("timezone") or "UTC"
        timezone = ZoneInfo(timezone_name)
        events = [
            self._to_tide_event(item, timezone)
            for item in payload.get("extremes", [])
            if item.get("type") in {"high", "low"}
        ]

        return TideForecast(
            spot_id=spot.id,
            available=bool(events),
            station_name=station_payload.get("name") or station.get("name"),
            station_distance_km=_as_float(station.get("distanceKm")),
            source="tidecheck",
            events=events[:16],
            note=(
                "Tide times are estimates for surf planning, not navigation."
                if events
                else "Tide data is unavailable right now."
            ),
        )

    def _to_tide_event(self, item: dict[str, Any], timezone: ZoneInfo) -> TideEvent:
        stamp = datetime.fromisoformat(item["time"].replace("Z", "+00:00"))
        local_stamp = stamp.astimezone(timezone)
        return TideEvent(
            type=item["type"],
            time=stamp,
            local_time=local_stamp.strftime("%-I:%M %p"),
            local_date=local_stamp.date(),
            height_m=_as_float(item.get("height")),
        )


def _as_float(value: Any) -> float | None:
    if value is None:
        return None
    return round(float(value), 1)


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
