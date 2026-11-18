"""Account-scoped alert entitlements; no provider reads or automatic resumes."""
from datetime import datetime, timedelta, timezone
import os

from app.core.models import Alert, User


class AlertPolicyError(ValueError):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


def active_limit(user: User) -> int:
    return 10 if user.premium else 1


def retained_limit() -> int:
    try:
        value = int(os.getenv("ALERTS_MAX_PER_USER", "25"))
        return value if value > 0 else 25
    except ValueError:
        return 25


def eligible(user: User, spot_id: str, spot_ids: set[str]) -> bool:
    return spot_id in spot_ids and (user.premium or user.free_live_spot_id == spot_id)


def pause(alert: Alert, user: User, reason: str) -> None:
    now = datetime.now(timezone.utc)
    alert.enabled = False
    alert.pause_reason = reason
    alert.status = "watching"
    alert.status_reason = (
        "Paused: this alert is outside your available Premium breaks. "
        "Choose your free Premium break or upgrade, then turn this alert on again."
        if reason == "spot_access" else
        f"Paused: your plan supports {active_limit(user)} active surf "
        f"{'alert' if active_limit(user) == 1 else 'alerts'}. "
        "Turn another alert off before enabling this one."
    )
    alert.last_evaluated_at = now
    alert.next_check_at = now + timedelta(hours=4)


def reconcile(alerts: list[Alert], user: User, spot_ids: set[str]) -> None:
    # IDs are stable in JSON and PostgreSQL, unlike a process-specific iteration
    # order. Remove ineligible enabled rows first, then keep the first eligible
    # IDs up to the plan limit. Disabled rows never automatically resume.
    kept = 0
    for alert in sorted(alerts, key=lambda item: item.id):
        if not alert.enabled:
            continue
        if not eligible(user, alert.spot_id, spot_ids):
            pause(alert, user, "spot_access")
        elif kept >= active_limit(user):
            pause(alert, user, "active_limit")
        else:
            alert.pause_reason = None
            kept += 1


def validate_active(alert: Alert, others: list[Alert], user: User,
                    spot_ids: set[str], *, creating: bool = False) -> None:
    if not eligible(user, alert.spot_id, spot_ids):
        raise AlertPolicyError(403 if creating else 409,
            "Choose this spot as your free Premium break before creating an alert, "
            "or upgrade to Premium for alerts at more breaks.")
    if alert.enabled and sum(item.enabled for item in others if item.id != alert.id) >= active_limit(user):
        raise AlertPolicyError(409,
            f"Your plan supports {active_limit(user)} active surf "
            f"{'alert' if active_limit(user) == 1 else 'alerts'}. "
            "Turn an alert off before enabling another.")
