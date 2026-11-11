"""Notification read receipts use owned explicit snapshots, never a global clear."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-notification-tests-"))

from app.core.models import SocialNotification
from app.core.rate_limit import api_rate_limiter
from app.core.store import DemoStore, store
from app.main import app

client = TestClient(app)


def _notification(notification_id, recipient, actor="actor"):
    return SocialNotification(
        id=notification_id, recipient_user_id=recipient, actor_user_id=actor,
        actor_name="Surfer", type="like", message="liked your post.",
        created_at=datetime.now(timezone.utc),
    )


@pytest.fixture
def notification_accounts(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "")
    for name, value in {
        "state_file": tmp_path / "notifications.json",
        "postgres_auth": None, "postgres_social": None, "postgres_planning": None,
        "auth_accounts": {}, "session_tokens": {}, "verified_emails": set(),
        "email_verification_codes": {}, "password_reset_codes": {},
        "social_notifications": [], "blocked_user_ids": set(),
        "_default_user": store._default_user.model_copy(deep=True),
    }.items():
        monkeypatch.setattr(store, name, value)
    monkeypatch.setattr(
        "app.core.store.send_verification_email",
        lambda *_args: SimpleNamespace(configured=False, sent=False, error=None),
    )
    api_rate_limiter.clear()

    def account(email):
        result = client.post("/api/v1/auth/signup", json={
            "email": email, "password": "local-test-password", "locale": "en",
        })
        assert result.status_code == 200, result.text
        token = result.json()["session"]["access_token"]
        return {"Authorization": f"Bearer {token}"}, store.resolve_session_user(token)

    first_headers, first = account("first-notification@example.com")
    other_headers, other = account("other-notification@example.com")
    yield first_headers, first, other_headers, other
    api_rate_limiter.clear()


def test_notification_endpoints_require_a_signed_in_account(notification_accounts):
    assert client.get("/api/v1/social/notifications/unread-count").status_code == 401
    assert client.post("/api/v1/social/notifications/read", json={"notification_ids": ["one"]}).status_code == 401


def test_actual_count_twelve_and_read_receipt_are_scoped(notification_accounts):
    headers, user, other_headers, other = notification_accounts
    store.social_notifications = [
        *[_notification(f"own-{index}", user.id) for index in range(12)],
        _notification("other-only", other.id),
    ]
    result = client.get("/api/v1/social/notifications/unread-count", headers=headers)
    assert result.json() == {"user_id": user.id, "unread_count": 12}
    assert client.get("/api/v1/social/notifications/unread-count", headers=other_headers).json()["unread_count"] == 1
    response = client.post("/api/v1/social/notifications/read", headers=headers, json={
        "notification_ids": ["own-0", "own-1", "other-only", "does-not-exist"],
    })
    assert response.status_code == 200
    assert response.json()["user_id"] == user.id
    assert set(response.json()["read_ids"]) == {"own-0", "own-1"}
    assert response.json()["unread_count"] == 10
    assert next(item for item in store.social_notifications if item.id == "other-only").read_at is None
    assert client.get("/api/v1/social/notifications/unread-count", headers=other_headers).json()["unread_count"] == 1


def test_read_marks_only_the_displayed_snapshot_and_is_idempotent(notification_accounts):
    headers, user, _, _ = notification_accounts
    store.social_notifications = [_notification("displayed", user.id)]
    displayed = client.get("/api/v1/social/notifications", headers=headers).json()
    assert displayed[0]["read_at"] is None
    store.social_notifications.insert(0, _notification("arrived-later", user.id))
    payload = {"notification_ids": [item["id"] for item in displayed]}
    response = client.post("/api/v1/social/notifications/read", headers=headers, json=payload)
    assert response.json()["unread_count"] == 1
    first_time = next(item for item in store.social_notifications if item.id == "displayed").read_at
    assert first_time is not None
    client.post("/api/v1/social/notifications/read", headers=headers, json=payload)
    assert next(item for item in store.social_notifications if item.id == "displayed").read_at == first_time
    assert next(item for item in store.social_notifications if item.id == "arrived-later").read_at is None


def test_count_is_not_limited_to_the_latest_notification_page(notification_accounts):
    headers, user, _, _ = notification_accounts
    store.social_notifications = [_notification(str(index), user.id) for index in range(95)]
    assert len(client.get("/api/v1/social/notifications", headers=headers).json()) == 80
    assert client.get("/api/v1/social/notifications/unread-count", headers=headers).json()["unread_count"] == 95


def test_blocked_actor_notifications_do_not_count_or_get_marked(notification_accounts, monkeypatch):
    headers, user, _, _ = notification_accounts
    monkeypatch.setattr(store, "_blocked_user_ids_for", lambda _user_id: {"blocked"})
    store.social_notifications = [
        _notification("blocked-item", user.id, "blocked"),
        _notification("visible-item", user.id),
    ]
    assert client.get("/api/v1/social/notifications/unread-count", headers=headers).json()["unread_count"] == 1
    response = client.post("/api/v1/social/notifications/read", headers=headers, json={
        "notification_ids": ["blocked-item", "visible-item"],
    })
    assert response.json()["read_ids"] == ["visible-item"]
    assert response.json()["unread_count"] == 0
    assert store.social_notifications[0].read_at is None


def test_read_state_persists_and_failed_save_does_not_fake_a_read(notification_accounts, monkeypatch):
    headers, user, _, _ = notification_accounts
    store.social_notifications = [_notification("one", user.id)]
    response = client.post("/api/v1/social/notifications/read", headers=headers, json={"notification_ids": ["one"]})
    assert response.status_code == 200
    payload = json.loads(store.state_file.read_text())
    restored = SocialNotification.model_validate(payload["social_notifications"][0])
    assert restored.read_at is not None
    store.social_notifications.append(_notification("save-fails", user.id))
    monkeypatch.setattr(store, "_save_state", lambda: (_ for _ in ()).throw(OSError("Disk unavailable")))
    with store.request_user_context(user):
        with pytest.raises(OSError):
            store.mark_social_notifications_read(["save-fails"])
    assert next(item for item in store.social_notifications if item.id == "save-fails").read_at is None


@pytest.mark.parametrize("ids", [[], [""] , ["n" * 121], [str(index) for index in range(501)]])
def test_read_snapshot_is_bounded_and_validated(notification_accounts, ids):
    headers, _, _, _ = notification_accounts
    assert client.post("/api/v1/social/notifications/read", headers=headers, json={"notification_ids": ids}).status_code == 422
