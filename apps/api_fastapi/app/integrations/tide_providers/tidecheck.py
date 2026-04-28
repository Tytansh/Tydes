from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
import os
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from app.core.models import Spot, TideEvent, TideForecast


@dataclass
class _CacheItem:
    expires_at: datetime
    data: TideForecast


class TideCheckProvider:
    """Fetch high/low tide predictions from TideCheck behind a swappable provider."""

    def __init__(self) -> None:
        self._api_key = _load_api_key()
        self._client = httpx.Client(base_url="https://tidecheck.com", timeout=8.0)
        self._station_cache: dict[str, _CacheItem] = {}
        self._tide_cache: dict[str, _CacheItem] = {}

    def fetch_spot_tides(self, spot: Spot, start_day: date, days: int = 2) -> TideForecast:
        if not self._api_key:
            return TideForecast(
                spot_id=spot.id,
                available=False,
                note="Tide provider is not configured yet.",
            )

        now = datetime.now(UTC)
        cache_key = f"{spot.id}:{start_day.isoformat()}:{days}"
        cached = self._tide_cache.get(cache_key)
        if cached and cached.expires_at > now:
            return cached.data

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
            elif status_code == 401:
                internal_note = "TideCheck API key is invalid."
            elif status_code == 403:
                internal_note = "TideCheck plan does not allow this request."
            else:
                internal_note = f"TideCheck returned HTTP {status_code}."
            print(f"Tide data unavailable for {spot.id}: {internal_note}")
            forecast = TideForecast(
                spot_id=spot.id,
                available=False,
                source="tidecheck",
                note="Tide data is unavailable right now.",
            )
        except Exception as error:
            print(f"Tide data unavailable for {spot.id}: {error}")
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
        return forecast

    def _nearest_station(self, spot: Spot) -> dict[str, Any]:
        now = datetime.now(UTC)
        cached = self._station_cache.get(spot.id)
        if cached and cached.expires_at > now:
            return cached.data  # type: ignore[return-value]

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
            data=station,  # type: ignore[arg-type]
        )
        return station

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
            events=events[:8],
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
