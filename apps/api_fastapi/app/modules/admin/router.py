import os
import secrets

from fastapi import APIRouter, Depends, Header, HTTPException

from app.core.auth import require_authenticated_user
from app.core.models import User
from app.core.store import store

router = APIRouter(prefix="/admin", tags=["admin"])


def require_admin_token(provided_token: str | None):
    expected_token = os.getenv("TYDES_ADMIN_TOKEN", "").strip()
    if not expected_token:
        raise HTTPException(status_code=404, detail="Admin tools are not enabled.")
    provided_token = (provided_token or "").strip()
    if not secrets.compare_digest(provided_token, expected_token):
        raise HTTPException(status_code=403, detail="Admin access denied.")


def require_admin_user(
    user: User = Depends(require_authenticated_user),
) -> User:
    configured_emails = {
        email.strip().lower()
        for email in os.getenv("TYDES_ADMIN_EMAILS", "").split(",")
        if email.strip()
    }
    if not configured_emails:
        configured_emails = {
            email.strip().lower()
            for email in os.getenv("TYDES_PREMIUM_EMAILS", "").split(",")
            if email.strip().lower().endswith("@tydes.io")
        }
    if user.email.lower() not in configured_emails:
        raise HTTPException(status_code=403, detail="Admin access denied.")
    return user


@router.get("/users")
def list_users(x_tydes_admin_token: str | None = Header(default=None)):
    require_admin_token(x_tydes_admin_token)
    users = store.list_auth_users()
    return {"count": len(users), "users": users}


@router.get("/dashboard/users")
def list_dashboard_users(_admin: User = Depends(require_admin_user)):
    users = store.list_auth_users()
    return {"count": len(users), "users": users}


@router.get("/reports")
def list_reports(x_tydes_admin_token: str | None = Header(default=None)):
    require_admin_token(x_tydes_admin_token)
    reports = [
        report.model_dump(mode="json")
        for report in store.list_social_reports()
    ]
    return {"count": len(reports), "reports": reports}
