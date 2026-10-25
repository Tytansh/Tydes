from pydantic import BaseModel, EmailStr, Field
from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.auth import require_authenticated_user
from app.core.rate_limit import (
    RateLimitRule,
    api_rate_limiter,
    client_rate_limit_key,
)
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
def login(payload: LoginRequest, request: Request):
    _limit_auth_request(
        request,
        "login",
        payload.email,
        client_limit=40,
        account_limit=10,
        window_seconds=15 * 60,
    )
    try:
        return store.login(payload.email, payload.locale, payload.password)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/signup")
def signup(payload: SignupRequest, request: Request):
    _limit_auth_request(
        request,
        "signup",
        payload.email,
        client_limit=12,
        account_limit=3,
        window_seconds=60 * 60,
    )
    try:
        return store.signup(payload.email, payload.password, payload.locale)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    except RuntimeError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


@router.post("/verify-email")
def verify_email(payload: VerifyEmailRequest, request: Request):
    _limit_auth_request(
        request,
        "verify-email",
        payload.email,
        client_limit=30,
        account_limit=10,
        window_seconds=15 * 60,
    )
    try:
        return store.verify_email(payload.email, payload.code)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/password-reset/request")
def request_password_reset(payload: PasswordResetRequest, request: Request):
    _limit_auth_request(
        request,
        "password-reset-request",
        payload.email,
        client_limit=8,
        account_limit=3,
        window_seconds=60 * 60,
    )
    try:
        return store.request_password_reset(payload.email)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    except RuntimeError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


@router.post("/password-reset/confirm")
def confirm_password_reset(payload: PasswordResetConfirmRequest, request: Request):
    _limit_auth_request(
        request,
        "password-reset-confirm",
        payload.email,
        client_limit=20,
        account_limit=8,
        window_seconds=60 * 60,
    )
    try:
        return store.reset_password(payload.email, payload.code, payload.password)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/logout")
def logout(_user=Depends(require_authenticated_user)):
    return store.logout()


@router.delete("/account")
def delete_account(_user=Depends(require_authenticated_user)):
    return store.delete_current_account()


@router.post("/waitlist")
def join_waitlist(payload: WaitlistRequest, request: Request):
    _limit_auth_request(
        request,
        "waitlist",
        payload.email,
        client_limit=15,
        account_limit=3,
        window_seconds=24 * 60 * 60,
    )
    return store.capture_email(payload.email)


def _limit_auth_request(
    request: Request,
    scope: str,
    email: str,
    *,
    client_limit: int,
    account_limit: int,
    window_seconds: int,
) -> None:
    api_rate_limiter.enforce(
        RateLimitRule(
            scope=f"auth:{scope}:client",
            key=client_rate_limit_key(request),
            limit=client_limit,
            window_seconds=window_seconds,
        ),
        RateLimitRule(
            scope=f"auth:{scope}:account",
            key=email.strip().lower(),
            limit=account_limit,
            window_seconds=window_seconds,
        ),
    )
