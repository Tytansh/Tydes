from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

from app.core.models import ForecastEntry, Spot, SurfWindowForecast, SurfWindowHour

FRESH_FORECAST_MAX_AGE = timedelta(hours=3)
PREVIEW_FORECAST_MAX_AGE = timedelta(hours=24)
FREE_FORECAST_MAX_AGE = timedelta(days=5)


@dataclass
class _CacheItem:
    fetched_at: datetime
    data: list[ForecastEntry]
    hourly_rows: list[dict[str, float | str]]


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

    def fetch_spot_forecast(
        self,
        spot: Spot,
        *,
        max_cache_age: timedelta = FRESH_FORECAST_MAX_AGE,
    ) -> list[ForecastEntry]:
        now = datetime.now(UTC)
        cached = self._cache.get(spot.id)
        if cached and now - cached.fetched_at <= max_cache_age:
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
            fetched_at=now,
            data=entries,
            hourly_rows=self._to_hourly_rows(
                marine_response.json(),
                weather_response.json(),
            ),
        )
        return entries

    def fetch_spot_surf_window(
        self,
        spot: Spot,
        *,
        max_cache_age: timedelta = FRESH_FORECAST_MAX_AGE,
    ) -> SurfWindowForecast:
        self.fetch_spot_forecast(spot, max_cache_age=max_cache_age)
        cached = self._cache.get(spot.id)
        if cached is None:
            return SurfWindowForecast(
                spot_id=spot.id,
                available=False,
                note="Hourly forecast is unavailable right now.",
            )
        return _best_surf_window(spot, cached.hourly_rows)

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
    ) -> list[dict[str, float | str]]:
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

        return [
            {
                "time": stamp,
                "day": stamp.split("T")[0],
                "wave_height": _safe_value(wave_heights, index),
                "wave_period": _safe_value(wave_periods, index),
                "wind_wave_height": _safe_value(wind_wave_heights, index),
                "swell_wave_height": _safe_value(swell_wave_heights, index),
                "sea_surface_temperature": _safe_value(sea_surface_temps, index),
                "wind_speed": wind_speeds_by_time.get(stamp, 0.0),
            }
            for index, stamp in enumerate(times)
        ]

    def _to_daily_forecasts_from_rows(
        self,
        spot: Spot,
        hourly_rows: list[dict[str, float | str]],
    ) -> list[ForecastEntry]:
        grouped: dict[str, list[dict[str, float]]] = {}
        for row in hourly_rows:
            day_key = str(row["day"])
            grouped.setdefault(day_key, []).append(
                {
                    "wave_height": float(row["wave_height"]),
                    "wave_period": float(row["wave_period"]),
                    "wind_wave_height": float(row["wind_wave_height"]),
                    "swell_wave_height": float(row["swell_wave_height"]),
                    "sea_surface_temperature": float(row["sea_surface_temperature"]),
                    "wind_speed": float(row["wind_speed"]),
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


def _best_surf_window(
    spot: Spot,
    hourly_rows: list[dict[str, float | str]],
) -> SurfWindowForecast:
    if not hourly_rows:
        return SurfWindowForecast(
            spot_id=spot.id,
            available=False,
            note="Hourly forecast is unavailable right now.",
        )

    day_key = str(hourly_rows[0]["day"])
    today_rows = [
        row
        for row in hourly_rows
        if row["day"] == day_key and 5 <= _hour_from_stamp(str(row["time"])) <= 18
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
    best_slice = max(
        (scored_rows[index : index + 3] for index in range(len(scored_rows) - 2)),
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
            f"Average {avg_wave:.1f}m surf, {round(avg_period)}s period, "
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
