from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.modules.ads.router import router as ads_router
from app.modules.alerts.router import router as alerts_router
from app.modules.auth.router import router as auth_router
from app.modules.billing.router import router as billing_router
from app.modules.forecasts.router import router as forecasts_router
from app.modules.social.router import router as social_router
from app.modules.spots.router import router as spots_router
from app.modules.trips.router import router as trips_router
from app.modules.users.router import router as users_router

app = FastAPI(title="Surf Travel API", version="0.1.0")
MEDIA_DIR = Path(__file__).resolve().parents[1] / "data" / "media"
MEDIA_DIR.mkdir(parents=True, exist_ok=True)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {
        "name": "Surf Travel API",
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
app.mount("/media", StaticFiles(directory=MEDIA_DIR), name="media")
