from fastapi import APIRouter, Request

from app.core.rate_limit import (
    RateLimitRule,
    account_or_client_rate_limit_key,
    api_rate_limiter,
)
from app.core.store import ForecastFreshness, store

router = APIRouter(prefix="/forecasts", tags=["forecasts"])


@router.get("")
def list_forecasts(
    request: Request,
    spot_id: str | None = None,
    freshness: ForecastFreshness = "fresh",
):
    _limit_forecast_request(request, "forecast", limit=120)
    return list(store.list_forecasts(spot_id, freshness=freshness))


@router.get("/tides")
def get_tides(spot_id: str, request: Request):
    _limit_forecast_request(request, "tides", limit=60)
    return store.get_tides(spot_id)


@router.get("/surf-window")
def get_surf_window(spot_id: str, request: Request):
    _limit_forecast_request(request, "surf-window", limit=60)
    return store.get_surf_window(spot_id)


@router.get("/next-swell")
def get_next_swell(request: Request):
    _limit_forecast_request(request, "next-swell", limit=30)
    return store.get_next_swell()


def _limit_forecast_request(request: Request, scope: str, *, limit: int) -> None:
    api_rate_limiter.enforce(
        RateLimitRule(
            scope=f"forecast:{scope}",
            key=account_or_client_rate_limit_key(request),
            limit=limit,
            window_seconds=5 * 60,
        )
    )
