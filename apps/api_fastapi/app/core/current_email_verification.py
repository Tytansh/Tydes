"""Short-lived proofs for the authenticated, current-account-only flow."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import secrets


def make_current_email_proof(user_id: str, email: str, code: str, *, now: datetime | None = None) -> str:
    salt = secrets.token_urlsafe(16)
    return json.dumps({
        "v": 1,
        "user_id": user_id,
        "email": email.strip().lower(),
        "expires_at": ((now or datetime.now(timezone.utc)) + timedelta(minutes=15)).isoformat(),
        "salt": salt,
        "digest": hashlib.sha256(f"{salt}\0{code}".encode()).hexdigest(),
    }, separators=(",", ":"))


def matches_current_email_proof(stored: str | None, user_id: str, email: str, code: str, *, now: datetime | None = None) -> bool:
    try:
        proof = json.loads(stored or "")
        if not isinstance(proof, dict) or proof.get("v") != 1:
            return False
        if proof.get("user_id") != user_id or proof.get("email") != email.strip().lower():
            return False
        expires_at = datetime.fromisoformat(proof["expires_at"])
        if expires_at.tzinfo is None or expires_at <= (now or datetime.now(timezone.utc)):
            return False
        salt = proof["salt"]
        expected = proof["digest"]
        if not isinstance(salt, str) or not isinstance(expected, str):
            return False
        digest = hashlib.sha256(f"{salt}\0{code.strip()}".encode()).hexdigest()
        return secrets.compare_digest(expected, digest)
    except (ValueError, KeyError, TypeError):
        return False
