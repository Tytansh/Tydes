from pydantic import BaseModel, EmailStr
from fastapi import APIRouter

from app.core.store import store

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginRequest(BaseModel):
    email: EmailStr
    locale: str = "en"


class WaitlistRequest(BaseModel):
    email: EmailStr


@router.post("/login")
def login(payload: LoginRequest):
    return store.login(payload.email, payload.locale)


@router.post("/logout")
def logout():
    return store.logout()


@router.post("/waitlist")
def join_waitlist(payload: WaitlistRequest):
    return store.capture_email(payload.email)
