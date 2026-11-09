"""Google ID-token login, with expiring one-use, browser-bound challenges.

Only Google's public signing certificates are cached. Credentials/ID tokens are
never persisted, logged, or used to request access to Google user APIs.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import base64
import hashlib
import hmac
import os
import re
import secrets
from threading import RLock

from pydantic import EmailStr, TypeAdapter


class GoogleIdentityError(ValueError):
    pass


class GoogleIdentityUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class GoogleIdentity:
    subject: str
    email: str
    authoritative_email: bool


_challenges: dict[str, dict] = {}
_challenge_lock = RLock()
_certificate_lock = RLock()
_google_request = None
_email_adapter = TypeAdapter(EmailStr)
_URLSAFE = re.compile(r"^[A-Za-z0-9_-]{43,128}$")


def google_web_client_id() -> str:
    value = os.getenv("GOOGLE_WEB_CLIENT_ID", "").strip()
    return value if re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", value) else ""


def google_auth_origins() -> set[str]:
    return {item.strip().rstrip("/") for item in os.getenv(
        "GOOGLE_AUTH_ALLOWED_ORIGINS",
        "https://tydes.io,https://www.tydes.io,https://tydes-surf-travel.tytaneth.chatgpt.site",
    ).split(",") if item.strip() and item.strip() != "*"}


def create_google_challenge(verifier_hash: str) -> dict:
    from app.core.store import store

    if not google_web_client_id():
        raise GoogleIdentityUnavailable("Google sign-in is not available yet. Use email below.")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", verifier_hash):
        raise GoogleIdentityError("Invalid Google sign-in request.")
    challenge_id = secrets.token_urlsafe(32)
    value = {"nonce": secrets.token_urlsafe(32), "verifier_hash": verifier_hash,
             "expires_at": datetime.now(timezone.utc) + timedelta(minutes=10)}
    if store.postgres_auth is not None:
        store.postgres_auth.create_google_challenge(challenge_id, value)
    else:
        with _challenge_lock:
            now = datetime.now(timezone.utc)
            for key in list(_challenges):
                if _challenges[key]["expires_at"] <= now:
                    del _challenges[key]
            if len(_challenges) >= 2_000:
                raise GoogleIdentityUnavailable("Google sign-in is busy. Please try again shortly.")
            _challenges[challenge_id] = value
    return {"challenge_id": challenge_id, "nonce": value["nonce"],
            "client_id": google_web_client_id(), "expires_in": 600}


def _verify_google_token(credential: str, client_id: str) -> dict:
    global _google_request
    from cachecontrol import CacheControl
    from google.auth.exceptions import TransportError
    from google.auth.transport.requests import Request
    from google.oauth2.id_token import verify_oauth2_token
    import requests

    class BoundedRequest(Request):
        def __call__(self, *args, **kwargs):
            kwargs["timeout"] = 10
            return super().__call__(*args, **kwargs)

    try:
        with _certificate_lock:
            if _google_request is None:
                _google_request = BoundedRequest(session=CacheControl(requests.Session()))
            return verify_oauth2_token(credential, _google_request, client_id, clock_skew_in_seconds=30)
    except (TransportError, requests.RequestException) as error:
        raise GoogleIdentityUnavailable("Google verification is temporarily unavailable. Try again.") from error
    except ValueError as error:
        raise GoogleIdentityError("Google sign-in could not be verified. Please try again.") from error


def verify_google_login(credential: str, challenge_id: str, verifier: str) -> GoogleIdentity:
    from app.core.store import store

    client_id = google_web_client_id()
    if not client_id:
        raise GoogleIdentityUnavailable("Google sign-in is not available yet. Use email below.")
    if not _URLSAFE.fullmatch(verifier) or not _URLSAFE.fullmatch(challenge_id):
        raise GoogleIdentityError("Google sign-in expired. Please try again.")
    if store.postgres_auth is not None:
        challenge = store.postgres_auth.get_google_challenge(challenge_id)
    else:
        with _challenge_lock:
            challenge = _challenges.get(challenge_id)
    now = datetime.now(timezone.utc)
    proof = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    if not challenge or challenge["expires_at"] <= now or not hmac.compare_digest(proof, challenge["verifier_hash"]):
        raise GoogleIdentityError("Google sign-in expired. Please try again.")
    claims = _verify_google_token(credential, client_id)
    nonce = claims.get("nonce")
    if not isinstance(nonce, str) or not hmac.compare_digest(nonce, challenge["nonce"]):
        raise GoogleIdentityError("Google sign-in could not be verified. Please try again.")
    if claims.get("aud") != client_id or claims.get("iss") not in {"accounts.google.com", "https://accounts.google.com"}:
        raise GoogleIdentityError("Google sign-in could not be verified. Please try again.")
    if claims.get("email_verified") is not True:
        raise GoogleIdentityError("Verify your email with Google first, or use email sign-up below.")
    subject = claims.get("sub")
    if not isinstance(subject, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,255}", subject):
        raise GoogleIdentityError("Google sign-in could not be verified. Please try again.")
    try:
        email = str(_email_adapter.validate_python(claims.get("email"))).lower()
    except ValueError as error:
        raise GoogleIdentityError("Google did not provide a valid email address.") from error
    if store.postgres_auth is not None:
        consumed = store.postgres_auth.consume_google_challenge(challenge_id, proof)
    else:
        with _challenge_lock:
            current = _challenges.pop(challenge_id, None)
            consumed = current is not None and current["expires_at"] > now
    if not consumed:
        raise GoogleIdentityError("This Google sign-in was already used. Please try again.")
    # For other Google-account emails, require Tydes' own email confirmation.
    # email_verified alone does not mean Google is authoritative for that domain.
    hosted_domain = claims.get("hd")
    authoritative = email.endswith("@gmail.com") or (
        isinstance(hosted_domain, str) and bool(hosted_domain)
        and email.rsplit("@", 1)[1] == hosted_domain.lower()
    )
    return GoogleIdentity(subject, email, authoritative)
