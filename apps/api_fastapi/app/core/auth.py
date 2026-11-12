from fastapi import HTTPException, Request

from app.core.models import User


EMAIL_VERIFICATION_REQUIRED_DETAIL = {
    "code": "email_verification_required",
    "message": "Verify your email to continue.",
}


def optional_authenticated_user(request: Request) -> User | None:
    user = getattr(request.state, "user", None)
    return user if isinstance(user, User) else None


def require_signed_in_user(request: Request) -> User:
    """Identity-only access for bootstrap and account recovery, not app features."""
    user = optional_authenticated_user(request)
    if user is None:
        raise HTTPException(status_code=401, detail="Sign in required")
    return user


def require_authenticated_user(request: Request) -> User:
    """Private app access always requires a verified email, even for admins."""
    user = require_signed_in_user(request)
    if not user.email_verified:
        raise HTTPException(status_code=403, detail=EMAIL_VERIFICATION_REQUIRED_DETAIL)
    return user
