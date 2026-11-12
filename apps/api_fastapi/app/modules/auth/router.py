from pydantic import BaseModel, ConfigDict, EmailStr, Field
from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.auth import require_signed_in_user
from app.core.media_cleanup import queue_account_media_deletion
from app.core.rate_limit import (
    RateLimitRule,
    api_rate_limiter,
    client_rate_limit_key,
)
from app.core.store import store
from app.integrations.google_identity import (
    GoogleIdentityError, GoogleIdentityUnavailable, create_google_challenge,
    google_auth_origins, google_web_client_id, verify_google_login,
)

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginRequest(BaseModel):
    email: EmailStr
    password: str | None = Field(default=None, max_length=128)
    locale: str = Field(default="en", max_length=10)


class SignupRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    locale: str = Field(default="en", max_length=10)


class VerifyEmailRequest(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=12)


class CurrentEmailVerificationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CurrentEmailVerificationConfirm(BaseModel):
    model_config = ConfigDict(extra="forbid")
    code: str = Field(pattern=r"^[0-9]{6}$")


class PasswordResetRequest(BaseModel):
    email: EmailStr


class PasswordResetConfirmRequest(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=12)
    password: str = Field(min_length=8, max_length=128)


class WaitlistRequest(BaseModel):
    email: EmailStr


class GoogleChallengeRequest(BaseModel):
    verifier_hash: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")


class GoogleLoginRequest(BaseModel):
    credential: str = Field(min_length=20, max_length=16_384)
    challenge_id: str = Field(min_length=43, max_length=128)
    verifier: str = Field(min_length=43, max_length=128)
    locale: str = Field(default="en", max_length=10)
    # Account creation must be an explicit Sign up action, never a login retry.
    allow_signup: bool = False


def _require_google_origin(request: Request) -> None:
    if request.headers.get("origin", "").rstrip("/") not in google_auth_origins():
        raise HTTPException(status_code=403, detail="Open Google sign-in from the TYDES website.")


@router.get("/google/config")
def google_config():
    client_id = google_web_client_id()
    return {"enabled": bool(client_id), "client_id": client_id}


@router.post("/google/challenge")
def google_challenge(payload: GoogleChallengeRequest, request: Request):
    _require_google_origin(request)
    api_rate_limiter.enforce(
        RateLimitRule(scope="auth:google-challenge:client", key=client_rate_limit_key(request), limit=30, window_seconds=900),
        RateLimitRule(scope="auth:google-challenge:global", key="all", limit=1000, window_seconds=3600),
    )
    try:
        return create_google_challenge(payload.verifier_hash)
    except GoogleIdentityUnavailable as error:
        raise HTTPException(status_code=503, detail=str(error)) from error


@router.post("/google")
def google_login(payload: GoogleLoginRequest, request: Request):
    _require_google_origin(request)
    api_rate_limiter.enforce(RateLimitRule(
        scope="auth:google:client", key=client_rate_limit_key(request), limit=30, window_seconds=900,
    ))
    try:
        identity = verify_google_login(payload.credential, payload.challenge_id, payload.verifier)
        api_rate_limiter.enforce(RateLimitRule(
            scope="auth:google:account", key=identity.subject, limit=15, window_seconds=900,
        ))
        return store.login_google(identity, payload.locale, allow_signup=payload.allow_signup)
    except GoogleIdentityUnavailable as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    except GoogleIdentityError as error:
        raise HTTPException(status_code=401, detail=str(error)) from error
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except RuntimeError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


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


@router.post("/email-verification/request")
def request_current_email_verification(
    request: Request,
    payload: CurrentEmailVerificationRequest | None = None,
    user=Depends(require_signed_in_user),
):
    _limit_auth_request(
        request, "current-email-request", user.email,
        client_limit=12, account_limit=3, window_seconds=60 * 60,
    )
    api_rate_limiter.enforce(RateLimitRule(
        scope="auth:current-email-request:global", key="all",
        limit=80, window_seconds=60 * 60,
    ))
    try:
        return store.request_current_email_verification(user)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    except Exception as error:
        # Never expose mail-provider responses, credentials, codes, or storage
        # details, and never claim delivery when sending/persistence failed.
        raise HTTPException(status_code=503, detail="Could not send verification email right now. Please try again later.") from error


@router.post("/email-verification/confirm")
def confirm_current_email_verification(
    payload: CurrentEmailVerificationConfirm,
    request: Request,
    user=Depends(require_signed_in_user),
):
    _limit_auth_request(
        request, "current-email-confirm", user.email,
        client_limit=30, account_limit=10, window_seconds=15 * 60,
    )
    api_rate_limiter.enforce(RateLimitRule(
        scope="auth:current-email-confirm:global", key="all",
        limit=1000, window_seconds=60 * 60,
    ))
    try:
        return store.confirm_current_email_verification(user, payload.code)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    except Exception as error:
        raise HTTPException(status_code=503, detail="Could not verify your email right now. Please try again later.") from error


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
def logout(_user=Depends(require_signed_in_user)):
    return store.logout()


@router.delete("/account")
def delete_account(user=Depends(require_signed_in_user)):
    queue_account_media_deletion(user.id)
    deleted_user = store.delete_current_account()
    # The existing cleanup worker handles queued media. Do not keep a deletion
    # response waiting on third-party storage after the account is gone.
    return deleted_user


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
