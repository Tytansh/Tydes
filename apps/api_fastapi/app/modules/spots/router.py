from fastapi import APIRouter, HTTPException, Request, Response

from app.core.rate_limit import (
    RateLimitRule,
    account_or_client_rate_limit_key,
    api_rate_limiter,
)
from app.core.store import store

router = APIRouter(prefix="/spots", tags=["spots"])


@router.get("")
def list_spots(request: Request, response: Response, region: str | None = None):
    _limit_spot_read(request, "list", 60)
    response.headers["Cache-Control"] = (
        "public, max-age=3600, stale-while-revalidate=86400"
    )
    return list(store.list_spots(region))


@router.get("/{spot_id}")
def get_spot(spot_id: str, request: Request, response: Response):
    _limit_spot_read(request, "detail", 120)
    spot = store.get_spot(spot_id)
    if spot is None:
        raise HTTPException(status_code=404, detail="Spot not found")
    response.headers["Cache-Control"] = (
        "public, max-age=3600, stale-while-revalidate=86400"
    )
    return spot


def _limit_spot_read(request: Request, scope: str, limit: int) -> None:
    api_rate_limiter.enforce(
        RateLimitRule(
            scope=f"spots:read:{scope}",
            key=account_or_client_rate_limit_key(request),
            limit=limit,
            window_seconds=5 * 60,
        )
    )

