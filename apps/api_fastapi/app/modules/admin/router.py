import os
import secrets

from fastapi import APIRouter, Header, HTTPException

from app.core.store import store

router = APIRouter(prefix="/admin", tags=["admin"])


def require_admin_token(provided_token: str | None):
    expected_token = os.getenv("TYDES_ADMIN_TOKEN", "").strip()
    if not expected_token:
        raise HTTPException(status_code=404, detail="Admin tools are not enabled.")
    provided_token = (provided_token or "").strip()
    if not secrets.compare_digest(provided_token, expected_token):
        raise HTTPException(status_code=403, detail="Admin access denied.")


@router.get("/users")
def list_users(x_tydes_admin_token: str | None = Header(default=None)):
    require_admin_token(x_tydes_admin_token)
    users = []
    for email, account in sorted(store.auth_accounts.items()):
        user = account.get("user")
        if not isinstance(user, dict):
            continue
        users.append(
            {
                "email": email,
                "user_id": user.get("id"),
                "handle": user.get("handle") or "",
                "display_name": user.get("display_name") or "",
                "email_verified": bool(user.get("email_verified")),
                "premium": bool(user.get("premium")),
            }
        )
    return {"count": len(users), "users": users}
