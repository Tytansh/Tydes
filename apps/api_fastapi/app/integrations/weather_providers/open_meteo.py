from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

from app.core.models import ForecastEntry, Spot


@dataclass
class _CacheItem:
    expires_at: datetime
    data: list[ForecastEntry]


class OpenMeteoMarineProvider:
    """Fetch marine forecasts from Open-Meteo with a short in-memory cache."""

    def __init__(self) -> None:
        self._marine_client = httpx.Client(
            base_url="https://marine-api.open-meteo.com/v1",
            timeout=8.0,
        )
        self._forecast_client = httpx.Client(
            base_url="https://api.open-meteo.com/v1",
            timeout=8.0,
        )
        self._cache: dict[str, _CacheItem] = {}

    def fetch_spot_forecast(self, spot: Spot) -> list[ForecastEntry]:
        now = datetime.now(UTC)
        cached = self._cache.get(spot.id)
        if cached and cached.expires_at > now:
            return cached.data

        marine_response = self._marine_client.get(
            "/marine",
            params={
                "latitude": spot.latitude,
                "longitude": spot.longitude,
                "hourly": ",".join(
                    [
                        "wave_height",
                        "wave_period",
                        "wind_wave_height",
                        "swell_wave_height",
                        "sea_surface_temperature",
                    ]
                ),
                "forecast_days": 5,
                "timezone": "auto",
                "cell_selection": "sea",
            },
        )
        marine_response.raise_for_status()

        weather_response = self._forecast_client.get(
            "/forecast",
            params={
                "latitude": spot.latitude,
                "longitude": spot.longitude,
                "hourly": "wind_speed_10m",
                "forecast_days": 5,
                "timezone": "auto",
                "wind_speed_unit": "kn",
                "cell_selection": "sea",
            },
        )
        weather_response.raise_for_status()

        entries = self._to_daily_forecasts(
            spot,
            marine_response.json(),
            weather_response.json(),
        )
        self._cache[spot.id] = _CacheItem(
            expires_at=now + timedelta(hours=3),
            data=entries,
        )
        return entries

    def _to_daily_forecasts(
        self,
        spot: Spot,
        marine_payload: dict[str, Any],
        weather_payload: dict[str, Any],
    ) -> list[ForecastEntry]:
        hourly = marine_payload.get("hourly", {})
        times = hourly.get("time", [])
        wave_heights = hourly.get("wave_height", [])
        wave_periods = hourly.get("wave_period", [])
        wind_wave_heights = hourly.get("wind_wave_height", [])
        swell_wave_heights = hourly.get("swell_wave_height", [])
        sea_surface_temps = hourly.get("sea_surface_temperature", [])
        weather_hourly = weather_payload.get("hourly", {})
        wind_speeds_by_time = {
            stamp: float(speed)
            for stamp, speed in zip(
                weather_hourly.get("time", []),
                weather_hourly.get("wind_speed_10m", []),
                strict=False,
            )
            if speed is not None
        }

        grouped: dict[str, list[dict[str, float]]] = {}
        for index, stamp in enumerate(times):
            day_key = stamp.split("T")[0]
            grouped.setdefault(day_key, []).append(
                {
                    "wave_height": _safe_value(wave_heights, index),
                    "wave_period": _safe_value(wave_periods, index),
                    "wind_wave_height": _safe_value(wind_wave_heights, index),
                    "swell_wave_height": _safe_value(swell_wave_heights, index),
                    "sea_surface_temperature": _safe_value(sea_surface_temps, index),
                    "wind_speed": wind_speeds_by_time.get(stamp, 0.0),
                }
            )

        forecasts: list[ForecastEntry] = []
        for index, (day_key, rows) in enumerate(grouped.items(), start=1):
            avg_wave = _average(row["wave_height"] for row in rows)
            avg_period = _average(row["wave_period"] for row in rows)
            avg_wind_wave = _average(row["wind_wave_height"] for row in rows)
            avg_swell_wave = _average(row["swell_wave_height"] for row in rows)
            avg_temp = _average(row["sea_surface_temperature"] for row in rows)
            avg_wind_speed = _average(row["wind_speed"] for row in rows)

            forecasts.append(
                ForecastEntry(
                    id=f"live_{spot.id}_{index}",
                    spot_id=spot.id,
                    day=datetime.strptime(day_key, "%Y-%m-%d").date(),
                    wave_height_m=round(avg_wave, 1),
                    period_s=max(1, round(avg_period)),
                    wind_kts=max(0, round(avg_wind_speed, 1)),
                    quality=_quality_for(avg_wave, avg_period),
                    swell_wave_height_m=round(avg_swell_wave, 1),
                    wind_wave_height_m=round(avg_wind_wave, 1),
                    sea_surface_temperature_c=round(avg_temp, 1),
                    source="open-meteo",
                    confidence="live",
                )
            )
        return forecasts


def _safe_value(values: list[Any], index: int) -> float:
    try:
        value = values[index]
    except IndexError:
        return 0.0
    if value is None:
        return 0.0
    return float(value)


def _average(values: Any) -> float:
    data = list(values)
    if not data:
        return 0.0
    return sum(data) / len(data)


def _quality_for(wave_height_m: float, period_s: float) -> str:
    score = wave_height_m + (period_s / 10)
    if score >= 3.2:
        return "epic"
    if score >= 2.4:
        return "good"
    if score >= 1.5:
        return "fair"
    return "poor"
