from datetime import date
from uuid import uuid4

from fastapi import APIRouter
from pydantic import BaseModel

from app.core.models import Trip
from app.core.store import store

router = APIRouter(prefix="/trips", tags=["trips"])


class TripCreateRequest(BaseModel):
    title: str
    destination: str
    start_date: date
    end_date: date
    travelers: int = 1
    notes: str = ""
    budget_usd: int = 0


@router.get("")
def list_trips():
    return list(store.list_trips())


@router.post("")
def create_trip(payload: TripCreateRequest):
    trip = Trip(
        id=f"trip_{uuid4().hex[:8]}",
        user_id=store.user.id,
        title=payload.title,
        destination=payload.destination,
        start_date=payload.start_date,
        end_date=payload.end_date,
        travelers=payload.travelers,
        notes=payload.notes,
        budget_usd=payload.budget_usd,
    )
    return store.add_trip(trip)

