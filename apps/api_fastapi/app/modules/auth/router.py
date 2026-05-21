from pydantic import BaseModel, EmailStr, Field
from fastapi import APIRouter, HTTPException

from app.core.store import store

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginRequest(BaseModel):
    email: EmailStr
    password: str | None = None
    locale: str = "en"


class SignupRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8)
    locale: str = "en"


class VerifyEmailRequest(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=12)


class PasswordResetRequest(BaseModel):
    email: EmailStr


class PasswordResetConfirmRequest(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=12)
    password: str = Field(min_length=8)


class WaitlistRequest(BaseModel):
    email: EmailStr


@router.post("/login")
def login(payload: LoginRequest):
    try:
        return store.login(payload.email, payload.locale, payload.password)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/signup")
def signup(payload: SignupRequest):
    try:
        return store.signup(payload.email, payload.password, payload.locale)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    except RuntimeError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


@router.post("/verify-email")
def verify_email(payload: VerifyEmailRequest):
    try:
        return store.verify_email(payload.email, payload.code)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/password-reset/request")
def request_password_reset(payload: PasswordResetRequest):
    try:
        return store.request_password_reset(payload.email)
    except RuntimeError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


@router.post("/password-reset/confirm")
def confirm_password_reset(payload: PasswordResetConfirmRequest):
    try:
        return store.reset_password(payload.email, payload.code, payload.password)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/logout")
def logout():
    return store.logout()


@router.delete("/account")
def delete_account():
    return store.delete_current_account()


@router.post("/waitlist")
def join_waitlist(payload: WaitlistRequest):
    return store.capture_email(payload.email)
