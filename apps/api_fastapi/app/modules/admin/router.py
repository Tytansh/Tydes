import os
import secrets
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel

from app.core.auth import require_authenticated_user
from app.core.models import User
from app.core.store import store

router = APIRouter(prefix="/admin", tags=["admin"])


class AdminUserAccessUpdate(BaseModel):
    premium: bool | None = None
    banned: bool | None = None


class AdminReportStatusUpdate(BaseModel):
    status: Literal["open", "dismissed"]


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


@router.get("/dashboard/reports")
def list_dashboard_reports(
    include_dismissed: bool = False,
    _admin: User = Depends(require_admin_user),
):
    reports = []
    for report in store.list_social_reports(include_dismissed=include_dismissed):
        item = report.model_dump(mode="json")
        reporter = store.get_auth_user_by_id(report.reporter_user_id)
        item["reporter_handle"] = reporter.handle if reporter else ""
        item["reporter_display_name"] = reporter.display_name if reporter else ""
        reported_user = None
        target_available = False
        if report.target_type == "post":
            post = store.get_post(report.target_id)
            target_available = post is not None
            if post is not None:
                reported_user = store.get_auth_user_by_id(post.user_id)
                item["reported_user_id"] = post.user_id
        elif report.target_type == "profile":
            reported_user = store.get_auth_user_by_id(report.target_id)
            item["reported_user_id"] = report.target_id
            target_available = reported_user is not None
        elif report.target_type == "comment":
            comment = store.get_comment(report.target_id)
            target_available = comment is not None
            if comment is not None:
                reported_user = store.get_auth_user_by_id(comment.user_id)
                item["reported_user_id"] = comment.user_id
        item["reported_handle"] = reported_user.handle if reported_user else ""
        item["reported_display_name"] = (
            reported_user.display_name if reported_user else ""
        )
        item["target_available"] = target_available
        reports.append(item)
    return {"count": len(reports), "reports": reports}


@router.patch("/dashboard/reports/{report_id}")
def update_dashboard_report(
    report_id: str,
    payload: AdminReportStatusUpdate,
    admin: User = Depends(require_admin_user),
):
    report = store.set_social_report_status(
        report_id, payload.status, admin_user_id=admin.id,
    )
    if report is None:
        raise HTTPException(status_code=404, detail="Report not found.")
    return report.model_dump(mode="json")


@router.patch("/dashboard/users/{user_id}")
def update_dashboard_user(
    user_id: str,
    payload: AdminUserAccessUpdate,
    admin: User = Depends(require_admin_user),
):
    if payload.premium is None and payload.banned is None:
        raise HTTPException(status_code=400, detail="No account change supplied.")
    if user_id == admin.id and payload.banned is True:
        raise HTTPException(status_code=400, detail="You cannot ban your own account.")
    user = store.set_admin_user_access(
        user_id,
        premium=payload.premium,
        banned=payload.banned,
    )
    if user is None:
        raise HTTPException(status_code=404, detail="Account not found.")
    return {
        "email": user.email,
        "user_id": user.id,
        "handle": user.handle,
        "display_name": user.display_name,
        "email_verified": user.email_verified,
        "premium": user.premium,
        "banned": user.banned,
    }


@router.get("/reports")
def list_reports(x_tydes_admin_token: str | None = Header(default=None)):
    require_admin_token(x_tydes_admin_token)
    reports = [
        report.model_dump(mode="json")
        for report in store.list_social_reports()
    ]
    return {"count": len(reports), "reports": reports}
