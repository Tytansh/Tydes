from __future__ import annotations

from dataclasses import dataclass
from html import escape
import os
from pathlib import Path

import httpx
from fastapi import HTTPException

from app.core.rate_limit import RateLimitRule, api_rate_limiter


@dataclass(frozen=True)
class EmailSendResult:
    configured: bool
    sent: bool
    error: str | None = None


def send_verification_email(email: str, code: str) -> EmailSendResult:
    return _send_code_email(
        email=email,
        code=code,
        subject_template="Verify your {app_name} email",
        intro="Use this code to finish creating your account:",
        text_template=(
            "Your {app_name} verification code is {code}.\n\n"
            "If you did not create an account, you can ignore this email."
        ),
        heading_template="Verify your {app_name} email",
    )


def send_password_reset_email(email: str, code: str) -> EmailSendResult:
    return _send_code_email(
        email=email,
        code=code,
        subject_template="Reset your {app_name} password",
        intro="Use this code to reset your password:",
        text_template=(
            "Your {app_name} password reset code is {code}.\n\n"
            "If you did not request this, you can ignore this email."
        ),
        heading_template="Reset your {app_name} password",
    )


def _send_code_email(
    *,
    email: str,
    code: str,
    subject_template: str,
    intro: str,
    text_template: str,
    heading_template: str,
) -> EmailSendResult:
    api_key = _read_env("RESEND_API_KEY")
    from_email = _read_env("AUTH_EMAIL_FROM")
    if not api_key or not from_email:
        return EmailSendResult(configured=False, sent=False)

    try:
        api_rate_limiter.enforce(
            RateLimitRule(
                scope="email:global:daily",
                key="all-email-delivery",
                limit=_positive_env("AUTH_EMAILS_PER_DAY", 80),
                window_seconds=24 * 60 * 60,
            ),
            RateLimitRule(
                scope="email:global:monthly",
                key="all-email-delivery",
                limit=_positive_env("AUTH_EMAILS_PER_MONTH", 2_500),
                window_seconds=30 * 24 * 60 * 60,
            ),
            RateLimitRule(
                scope="email:recipient:daily",
                key=email.strip().lower(),
                limit=_positive_env("AUTH_EMAILS_PER_RECIPIENT_DAY", 5),
                window_seconds=24 * 60 * 60,
            ),
        )
    except HTTPException:
        return EmailSendResult(
            configured=True,
            sent=False,
            error="Email delivery safety limit reached.",
        )

    app_name = _read_env("APP_NAME") or "Tydes"
    payload = {
        "from": from_email,
        "to": [email],
        "subject": subject_template.format(app_name=app_name),
        "text": text_template.format(app_name=app_name, code=code),
        "html": _code_email_html(
            heading=heading_template.format(app_name=app_name),
            intro=intro,
            code=code,
        ),
    }
    try:
        response = httpx.post(
            _read_env("RESEND_API_URL") or "https://api.resend.com/emails",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
            timeout=10,
        )
        response.raise_for_status()
    except httpx.HTTPError as error:
        return EmailSendResult(configured=True, sent=False, error=str(error))
    return EmailSendResult(configured=True, sent=True)


def _code_email_html(*, heading: str, intro: str, code: str) -> str:
    safe_heading = escape(heading)
    safe_intro = escape(intro)
    safe_code = escape(code)
    return f"""
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; color: #142127; line-height: 1.5;">
      <h1 style="margin: 0 0 16px;">{safe_heading}</h1>
      <p style="margin: 0 0 18px;">{safe_intro}</p>
      <div style="display: inline-block; padding: 14px 18px; border-radius: 16px; background: #f6f4ee; font-size: 28px; font-weight: 800; letter-spacing: 4px;">
        {safe_code}
      </div>
      <p style="margin: 22px 0 0; color: #5f6b6f;">If you did not request this, you can ignore this email.</p>
    </div>
    """


def _read_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if value:
        return value

    api_dir = Path(__file__).resolve().parents[2]
    repo_dir = api_dir.parents[1]
    for env_path in (api_dir / ".env", repo_dir / ".env"):
        env_value = _read_env_file_value(env_path, name)
        if env_value:
            return env_value
    return ""


def _read_env_file_value(path: Path, name: str) -> str:
    if not path.exists():
        return ""
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return ""
    prefix = f"{name}="
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or not stripped.startswith(prefix):
            continue
        return stripped.removeprefix(prefix).strip().strip('"').strip("'")
    return ""


def _positive_env(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default
