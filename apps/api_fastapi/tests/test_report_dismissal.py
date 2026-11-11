"""Reversible moderation actions without production accounts or network access."""
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
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-report-tests-"))

from app.core.models import SocialPost, SocialReport
from app.core.rate_limit import api_rate_limiter
from app.core.store import store
from app.main import app

client = TestClient(app)


@pytest.fixture
def moderation(tmp_path, monkeypatch):
    monkeypatch.setenv("TYDES_ADMIN_EMAILS", "owner@tydes.io")
    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", "")
    for name, value in {
        "state_file": tmp_path / "moderation.json",
        "postgres_auth": None,
        "postgres_social": None,
        "postgres_planning": None,
        "auth_accounts": {},
        "session_tokens": {},
        "verified_emails": set(),
        "email_verification_codes": {},
        "password_reset_codes": {},
        "social_reports": [],
        "posts": [],
        "comments": [],
        "_default_user": store._default_user.model_copy(deep=True),
    }.items():
        monkeypatch.setattr(store, name, value)
    monkeypatch.setattr(
        "app.core.store.send_verification_email",
        lambda *_args: SimpleNamespace(configured=False, sent=False, error=None),
    )
    monkeypatch.setattr("app.modules.social.router.send_moderation_report_email", lambda **_kwargs: None)
    api_rate_limiter.clear()

    def account(email):
        response = client.post("/api/v1/auth/signup", json={
            "email": email, "password": "surf-test-password", "locale": "en",
        })
        assert response.status_code == 200, response.text
        token = response.json()["session"]["access_token"]
        return {"Authorization": f"Bearer {token}"}, store.resolve_session_user(token)

    admin_headers, admin = account("owner@tydes.io")
    reporter_headers, reporter = account("reporter@example.com")
    post = SocialPost(
        id="reviewed-post", user_id=reporter.id, author_name="Reporter",
        body="Real post must remain untouched", post_type="general", created_at=datetime.now(timezone.utc),
    )
    store.posts = [post]
    report = SocialReport(
        id="report-one", reporter_user_id=reporter.id, target_type="post",
        target_id=post.id, reason="Testing spam report", created_at=datetime.now(timezone.utc),
    )
    store.social_reports = [report]
    yield admin_headers, reporter_headers, admin, reporter, post, report
    api_rate_limiter.clear()


def test_only_authenticated_admin_can_dismiss_or_restore(moderation):
    admin_headers, reporter_headers, _, _, _, report = moderation
    endpoint = f"/api/v1/admin/dashboard/reports/{report.id}"
    for status in ("dismissed", "open"):
        assert client.patch(endpoint, json={"status": status}).status_code == 401
        assert client.patch(endpoint, json={"status": status}, headers=reporter_headers).status_code == 403
    assert store.social_reports[0].status == "open"
    assert client.patch(endpoint, json={"status": "dismissed"}, headers=admin_headers).status_code == 200


def test_dismiss_updates_active_queue_and_preserves_content_and_audit(moderation):
    admin_headers, reporter_headers, admin, reporter, post, report = moderation
    endpoint = f"/api/v1/admin/dashboard/reports/{report.id}"
    response = client.patch(endpoint, json={"status": "dismissed"}, headers=admin_headers)
    assert response.status_code == 200
    payload = response.json()
    assert payload["id"] == report.id
    assert payload["status"] == "dismissed"
    assert payload["dismissed_at"] is not None
    assert payload["dismissed_by_user_id"] == admin.id
    active = client.get("/api/v1/admin/dashboard/reports", headers=admin_headers).json()
    assert active == {"count": 0, "reports": []}
    history = client.get("/api/v1/admin/dashboard/reports?include_dismissed=true", headers=admin_headers).json()
    assert history["count"] == 1
    assert history["reports"][0]["status"] == "dismissed"
    assert history["reports"][0]["reporter_handle"] == reporter.handle
    assert store.get_post(post.id).model_dump() == post.model_dump()
    assert not store.get_auth_user_by_id(reporter.id).banned
    assert client.get("/api/v1/users/me", headers=reporter_headers).status_code == 200
    # Retrying a completed request must not rewrite the original audit time.
    assert client.patch(endpoint, json={"status": "dismissed"}, headers=admin_headers).json() == payload


def test_restore_reopens_same_report_without_creating_a_duplicate(moderation):
    admin_headers, _, _, _, _, report = moderation
    endpoint = f"/api/v1/admin/dashboard/reports/{report.id}"
    client.patch(endpoint, json={"status": "dismissed"}, headers=admin_headers)
    restored = client.patch(endpoint, json={"status": "open"}, headers=admin_headers)
    assert restored.status_code == 200
    assert restored.json()["status"] == "open"
    assert restored.json()["dismissed_at"] is None
    assert restored.json()["dismissed_by_user_id"] is None
    assert len(store.social_reports) == 1
    active = client.get("/api/v1/admin/dashboard/reports", headers=admin_headers).json()
    assert active["count"] == 1
    assert active["reports"][0]["id"] == report.id


def test_missing_and_invalid_report_updates_are_rejected(moderation):
    headers, *_ = moderation
    missing = client.patch("/api/v1/admin/dashboard/reports/missing", json={"status": "dismissed"}, headers=headers)
    assert missing.status_code == 404
    assert missing.json()["detail"] == "Report not found."
    for payload in ({}, {"status": "deleted"}, {"status": None}):
        assert client.patch("/api/v1/admin/dashboard/reports/report-one", json=payload, headers=headers).status_code == 422
    assert store.social_reports[0].status == "open"


def test_dismissal_survives_saved_state_reload_and_legacy_defaults(moderation):
    headers, _, admin, _, _, report = moderation
    client.patch(f"/api/v1/admin/dashboard/reports/{report.id}", json={"status": "dismissed"}, headers=headers)
    data = json.loads(store.state_file.read_text())
    assert data["social_reports"][0]["dismissed_by_user_id"] == admin.id
    store.social_reports = []
    store._load_state()
    assert store.list_social_reports() == []
    assert store.list_social_reports(include_dismissed=True)[0].status == "dismissed"
    legacy = report.model_dump(mode="json", exclude={"status", "dismissed_at", "dismissed_by_user_id"})
    assert SocialReport.model_validate(legacy).status == "open"


def test_failed_disk_write_does_not_dismiss_in_memory(moderation, monkeypatch):
    *_, report = moderation
    def unavailable():
        raise OSError("Storage unavailable")
    monkeypatch.setattr(store, "_save_state", unavailable)
    with pytest.raises(OSError):
        store.set_social_report_status(report.id, "dismissed", admin_user_id="admin")
    assert store.social_reports[0].status == "open"
    assert store.social_reports[0].dismissed_at is None
