import asyncio
from contextlib import asynccontextmanager, suppress
import logging
import os

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from app.core.runtime import (
    csv_env,
    media_dir_path,
    sync_seed_media_files,
    uses_local_media_storage,
)
from app.core.media_cleanup import run_media_cleanup
from app.core.store import store
from app.modules.ads.router import router as ads_router
from app.modules.admin.router import router as admin_router
from app.modules.alerts.router import router as alerts_router
from app.modules.auth.router import router as auth_router
from app.modules.billing.router import router as billing_router
from app.modules.forecasts.router import router as forecasts_router
from app.modules.social.router import router as social_router
from app.modules.spots.router import router as spots_router
from app.modules.trips.router import router as trips_router
from app.modules.users.router import router as users_router

logger = logging.getLogger(__name__)


async def _media_cleanup_loop() -> None:
    while True:
        try:
            await asyncio.to_thread(run_media_cleanup)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Scheduled media cleanup failed")
        await asyncio.sleep(_media_cleanup_interval_seconds())


@asynccontextmanager
async def lifespan(_app: FastAPI):
    cleanup_task = asyncio.create_task(_media_cleanup_loop())
    try:
        yield
    finally:
        cleanup_task.cancel()
        with suppress(asyncio.CancelledError):
            await cleanup_task


def _media_cleanup_interval_seconds() -> int:
    raw = os.getenv("MEDIA_CLEANUP_INTERVAL_SECONDS", "3600").strip()
    try:
        value = int(raw)
    except ValueError:
        value = 3_600
    return min(max(value, 300), 24 * 60 * 60)


app = FastAPI(title="Tydes API", version="0.1.0", lifespan=lifespan)
MEDIA_DIR = media_dir_path()
MEDIA_DIR.mkdir(parents=True, exist_ok=True)
sync_seed_media_files()
ALLOWED_ORIGINS = csv_env("ALLOWED_ORIGINS", "*")

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials="*" not in ALLOWED_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def reject_oversized_api_requests(request, call_next):
    raw_content_length = request.headers.get("content-length")
    if raw_content_length:
        try:
            content_length = int(raw_content_length)
        except ValueError:
            return JSONResponse(
                status_code=400,
                content={"detail": "Invalid Content-Length header."},
            )
        if content_length > _max_api_request_bytes():
            return JSONResponse(
                status_code=413,
                content={"detail": "Request body is too large."},
            )
    return await call_next(request)


@app.middleware("http")
async def bind_authenticated_user(request, call_next):
    authenticated_user = None
    auth_header = request.headers.get("authorization", "")
    scheme, _, token = auth_header.partition(" ")
    if scheme.lower() == "bearer" and token.strip():
        authenticated_user = store.resolve_session_user(token.strip())
    request.state.user = authenticated_user
    request.state.authenticated_user = authenticated_user is not None
    with store.request_user_context(authenticated_user):
        return await call_next(request)


def _max_api_request_bytes() -> int:
    default = 100 * 1024 * 1024 if uses_local_media_storage() else 2 * 1024 * 1024
    raw = os.getenv("MAX_API_REQUEST_BYTES", str(default)).strip()
    try:
        value = int(raw)
    except ValueError:
        value = default
    return min(max(value, 1024), 100 * 1024 * 1024)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {
        "name": "Tydes API",
        "version": "0.1.0",
        "docs": "/docs",
        "api_base": "/api/v1",
    }


app.include_router(auth_router, prefix="/api/v1")
app.include_router(users_router, prefix="/api/v1")
app.include_router(spots_router, prefix="/api/v1")
app.include_router(forecasts_router, prefix="/api/v1")
app.include_router(social_router, prefix="/api/v1")
app.include_router(trips_router, prefix="/api/v1")
app.include_router(alerts_router, prefix="/api/v1")
app.include_router(billing_router, prefix="/api/v1")
app.include_router(ads_router, prefix="/api/v1")
app.include_router(admin_router, prefix="/api/v1")

if uses_local_media_storage():
    app.mount("/media", StaticFiles(directory=MEDIA_DIR), name="media")
else:
    _LEGACY_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}

    @app.get("/media/{filename:path}")
    def legacy_media(filename: str):
        candidate = (MEDIA_DIR / filename).resolve()
        if (
            candidate.suffix.lower() not in _LEGACY_IMAGE_EXTENSIONS
            or not candidate.is_relative_to(MEDIA_DIR.resolve())
            or not candidate.is_file()
        ):
            raise HTTPException(status_code=410, detail="Legacy media unavailable")
        return FileResponse(
            candidate,
            headers={"Cache-Control": "public, max-age=31536000, immutable"},
        )
