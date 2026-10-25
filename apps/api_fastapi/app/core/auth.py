from fastapi import HTTPException, Request

from app.core.models import User


def optional_authenticated_user(request: Request) -> User | None:
    user = getattr(request.state, "user", None)
    return user if isinstance(user, User) else None


def require_authenticated_user(request: Request) -> User:
    user = optional_authenticated_user(request)
    if user is None:
        raise HTTPException(status_code=401, detail="Sign in required")
    return user
