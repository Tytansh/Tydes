from pathlib import Path
from datetime import date
import json
import sys
from types import SimpleNamespace

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.main import app
from app.core.models import SurfWindowForecast, SurfWindowHour, TideForecast
from app.core.store import store

client = TestClient(app)


def _stub_email_senders(monkeypatch):
    monkeypatch.setattr(
        "app.core.store.send_verification_email",
        lambda _email, _code: SimpleNamespace(
            configured=False,
            sent=False,
            error=None,
        ),
    )
    monkeypatch.setattr(
        "app.core.store.send_password_reset_email",
        lambda _email, _code: SimpleNamespace(
            configured=False,
            sent=False,
            error=None,
        ),
    )


def _signup_access_token(monkeypatch, email: str) -> str:
    _stub_email_senders(monkeypatch)
    response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": email,
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert response.status_code == 200
    return response.json()["session"]["access_token"]


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_spots_list():
    response = client.get("/api/v1/spots")
    assert response.status_code == 200
    assert len(response.json()) >= 1


def test_forecasts_fallback_uses_estimated_spot_values(monkeypatch):
    def raise_provider_error(_spot, **_kwargs):
        raise RuntimeError("provider unavailable")

    monkeypatch.setattr(
        store.weather_provider,
        "fetch_spot_forecast",
        raise_provider_error,
    )

    response = client.get("/api/v1/forecasts", params={"spot_id": "spot_balangan"})

    assert response.status_code == 200
    rows = response.json()
    assert len(rows) == 5
    assert all(row["source"] == "estimated" for row in rows)
    assert all(row["confidence"] == "estimated" for row in rows)
    assert all(row["wave_height_m"] is not None for row in rows)
    assert all(row["wave_height_min_m"] is None for row in rows)
    assert all(row["wave_height_max_m"] is None for row in rows)


def test_free_user_locked_spot_gets_real_forecast_on_five_day_cache(monkeypatch):
    store.login("demo@surftravel.app")
    captured = {}

    def fake_live_forecast(spot, **kwargs):
        captured["max_cache_age"] = kwargs["max_cache_age"]
        return [
            store.forecasts[0].model_copy(
                update={
                    "id": f"free_est_{spot.id}_1",
                    "spot_id": spot.id,
                    "wave_height_m": 0.6,
                    "period_s": 11,
                    "wind_kts": 8.0,
                    "sea_surface_temperature_c": 27.2,
                    "source": "open-meteo",
                    "confidence": "estimated",
                }
            )
        ]

    monkeypatch.setattr(store.weather_provider, "fetch_spot_forecast", fake_live_forecast)

    response = client.get("/api/v1/forecasts", params={"spot_id": "spot_balangan"})

    assert response.status_code == 200
    rows = response.json()
    assert rows[0]["source"] == "open-meteo"
    assert rows[0]["confidence"] == "estimated"
    assert rows[0]["confidence_note"].startswith("Estimated from cached")
    assert rows[0]["wave_height_m"] is None
    assert rows[0]["wave_height_min_m"] == 0.5
    assert rows[0]["wave_height_max_m"] == 0.7
    assert rows[0]["period_s"] is None
    assert rows[0]["wind_kts"] is None
    assert rows[0]["sea_surface_temperature_c"] is None
    assert captured["max_cache_age"].total_seconds() == 5 * 24 * 60 * 60


def test_premium_user_hides_ads_and_can_use_live_data(monkeypatch):
    store.login("demo+premium@surftravel.app")

    response = client.get("/api/v1/ads", params={"placement": "home_feed"})
    assert response.status_code == 200
    assert response.json() == []

    called = {"value": False}

    def fake_live_forecast(_spot, **_kwargs):
        called["value"] = True
        return list(store.forecasts)[:1]

    monkeypatch.setattr(
        store.weather_provider,
        "fetch_spot_forecast",
        fake_live_forecast,
    )
    forecast_response = client.get("/api/v1/forecasts", params={"spot_id": "spot_balangan"})

    assert forecast_response.status_code == 200
    assert called["value"] is True


def test_preview_forecasts_use_longer_cache_window(monkeypatch):
    store.login("demo+premium@surftravel.app")
    captured = {}

    def fake_live_forecast(spot, **kwargs):
        captured["max_cache_age"] = kwargs["max_cache_age"]
        return [
            store.forecasts[0].model_copy(
                update={
                    "id": f"live_{spot.id}_1",
                    "spot_id": spot.id,
                    "confidence": "live",
                    "source": "test-live",
                }
            )
        ]

    monkeypatch.setattr(
        store.weather_provider,
        "fetch_spot_forecast",
        fake_live_forecast,
    )

    response = client.get(
        "/api/v1/forecasts",
        params={"spot_id": "spot_balangan", "freshness": "preview"},
    )

    assert response.status_code == 200
    assert captured["max_cache_age"].total_seconds() == 24 * 60 * 60


def test_bulk_forecasts_do_not_fetch_every_premium_spot(monkeypatch):
    store.login("demo+premium@surftravel.app")

    def fail_if_called(_spot, **_kwargs):
        raise AssertionError("bulk forecasts should stay fast and estimated")

    monkeypatch.setattr(
        store.weather_provider,
        "fetch_spot_forecast",
        fail_if_called,
    )

    bulk_response = client.get("/api/v1/forecasts")

    assert bulk_response.status_code == 200
    assert all(row["confidence"] == "estimated" for row in bulk_response.json())


def test_bulk_forecasts_include_free_unlocked_live_spot_only(monkeypatch):
    store.login("demo@surftravel.app")
    store.user.free_live_spot_id = "spot_bondi"
    called_spot_ids = []

    def fake_live_forecast(spot, **_kwargs):
        called_spot_ids.append(spot.id)
        return [
            store.forecasts[0].model_copy(
                update={
                    "id": f"live_{spot.id}_1",
                    "spot_id": spot.id,
                    "wave_height_m": 2.3,
                    "wave_height_min_m": None,
                    "wave_height_max_m": None,
                    "source": "test-live",
                    "confidence": "live",
                }
            )
        ]

    monkeypatch.setattr(
        store.weather_provider,
        "fetch_spot_forecast",
        fake_live_forecast,
    )

    bulk_response = client.get("/api/v1/forecasts")

    assert bulk_response.status_code == 200
    bulk_rows = bulk_response.json()
    bulk_bondi = next(row for row in bulk_rows if row["spot_id"] == "spot_bondi")
    locked_rows = [row for row in bulk_rows if row["spot_id"] != "spot_bondi"]
    assert called_spot_ids == ["spot_bondi"]
    assert bulk_bondi["wave_height_m"] == 2.3
    assert bulk_bondi["confidence"] == "live"
    assert all(row["confidence"] == "estimated" for row in locked_rows)


def test_tides_surface_provider_unavailable_note(monkeypatch):
    store.login("demo+premium@surftravel.app")

    def unavailable_tides(_spot, _start_day, days=3):
        return TideForecast(
            spot_id="spot_bondi",
            available=False,
            note="Provider unavailable.",
        )

    monkeypatch.setattr(store.tide_provider, "fetch_spot_tides", unavailable_tides)

    response = client.get("/api/v1/forecasts/tides", params={"spot_id": "spot_bondi"})

    assert response.status_code == 200
    payload = response.json()
    assert payload["available"] is False
    assert payload["source"] == "unavailable"
    assert payload["events"] == []
    assert payload["note"] == "Provider unavailable."


def test_balangan_surf_window_prototype(monkeypatch):
    store.login("demo@surftravel.app")

    def fake_surf_window(_spot, **_kwargs):
        return SurfWindowForecast(
            spot_id="spot_balangan",
            available=True,
            day=date.today(),
            best_start_label="6 AM",
            best_end_label="9 AM",
            rating="good",
            summary="Best window: 6 AM - 9 AM.",
            hours=[
                SurfWindowHour(
                    time="2026-05-11T06:00",
                    label="6 AM",
                    wave_height_m=1.4,
                    period_s=10,
                    wind_kts=6.0,
                    score=0.88,
                )
            ],
        )

    monkeypatch.setattr(store.weather_provider, "fetch_spot_surf_window", fake_surf_window)

    response = client.get(
        "/api/v1/forecasts/surf-window",
        params={"spot_id": "spot_balangan"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["available"] is True
    assert payload["best_start_label"] == "6 AM"
    assert payload["best_end_label"] == "9 AM"
    assert payload["confidence"] == "estimated"


def test_premium_surf_window_available_for_any_spot(monkeypatch):
    store.login("demo+premium@surftravel.app")

    def fake_surf_window(spot, **_kwargs):
        return SurfWindowForecast(
            spot_id=spot.id,
            available=True,
            day=date.today(),
            best_start_label="7 AM",
            best_end_label="10 AM",
            rating="good",
            summary="Best window: 7 AM - 10 AM.",
            hours=[
                SurfWindowHour(
                    time="2026-05-11T07:00",
                    label="7 AM",
                    wave_height_m=1.2,
                    period_s=9,
                    wind_kts=5.0,
                    score=0.82,
                )
            ],
        )

    monkeypatch.setattr(store.weather_provider, "fetch_spot_surf_window", fake_surf_window)

    response = client.get(
        "/api/v1/forecasts/surf-window",
        params={"spot_id": "spot_bondi"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["spot_id"] == "spot_bondi"
    assert payload["available"] is True
    assert payload["best_start_label"] == "7 AM"
    assert payload["best_end_label"] == "10 AM"
    assert payload["confidence"] == "live"


def test_can_add_and_remove_favorite_spot():
    store.login("demo@surftravel.app")
    store.user.favorite_spot_ids = []

    add_response = client.post(
        "/api/v1/users/favorites",
        json={"spot_id": "spot_balangan"},
    )
    assert add_response.status_code == 200
    assert add_response.json()["favorite_spot_ids"] == ["spot_balangan"]

    list_response = client.get("/api/v1/users/favorites")
    assert list_response.status_code == 200
    assert list_response.json()[0]["id"] == "spot_balangan"

    remove_response = client.delete("/api/v1/users/favorites/spot_balangan")
    assert remove_response.status_code == 200
    assert remove_response.json()["favorite_spot_ids"] == []


def test_can_toggle_and_delete_alert():
    create_response = client.post(
        "/api/v1/alerts",
        json={
            "spot_id": "spot_balangan",
            "min_wave_height_m": 1.2,
            "max_wind_kts": 16,
            "enabled": True,
        },
    )
    assert create_response.status_code == 200
    alert_id = create_response.json()["id"]

    update_response = client.patch(
        f"/api/v1/alerts/{alert_id}",
        json={"enabled": False},
    )
    assert update_response.status_code == 200
    assert update_response.json()["enabled"] is False

    delete_response = client.delete(f"/api/v1/alerts/{alert_id}")
    assert delete_response.status_code == 200
    assert delete_response.json()["deleted"] is True


def test_waitlist_capture_and_state_persistence(tmp_path):
    store.state_file = tmp_path / "demo_state.json"
    store.waitlist_emails = []

    response = client.post(
        "/api/v1/auth/waitlist",
        json={"email": "hello@example.com"},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "captured"

    saved = json.loads(store.state_file.read_text())
    assert "hello@example.com" in saved["waitlist_emails"]


def test_signup_creates_pending_email_verification(tmp_path, monkeypatch):
    store.state_file = tmp_path / "demo_state.json"
    store.verified_emails = set()
    store.email_verification_codes = {}
    store.password_reset_codes = {}
    store.auth_accounts = {}
    store.session_tokens = {}
    monkeypatch.setattr(
        "app.core.store.send_verification_email",
        lambda _email, _code: SimpleNamespace(
            configured=False,
            sent=False,
            error=None,
        ),
    )
    monkeypatch.setattr(
        "app.core.store.send_password_reset_email",
        lambda _email, _code: SimpleNamespace(
            configured=False,
            sent=False,
            error=None,
        ),
    )

    signup_response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": "newsurfer@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )

    assert signup_response.status_code == 200
    payload = signup_response.json()
    assert payload["verification_required"] is True
    assert payload["verification_sent_to"] == "newsurfer@example.com"
    assert payload["session"]["user"]["email"] == "newsurfer@example.com"
    assert payload["session"]["user"]["email_verified"] is False
    assert payload["session"]["user"]["display_name"] == ""
    assert payload["session"]["user"]["handle"] == ""
    assert payload["session"]["user"]["bio"] == ""
    assert payload["session"]["user"]["home_region"] == ""
    assert payload["session"]["user"]["surf_skill"] == ""
    assert payload["session"]["access_token"]
    verification_code = store.email_verification_codes["newsurfer@example.com"]
    assert len(verification_code) == 6
    assert verification_code.isdigit()
    assert verification_code in payload["verification_hint"]

    wrong_response = client.post(
        "/api/v1/auth/verify-email",
        json={"email": "newsurfer@example.com", "code": "999999"},
    )
    assert wrong_response.status_code == 400

    verify_response = client.post(
        "/api/v1/auth/verify-email",
        json={"email": "newsurfer@example.com", "code": verification_code},
    )

    assert verify_response.status_code == 200
    assert verify_response.json()["email_verified"] is True

    duplicate_response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": "newsurfer@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert duplicate_response.status_code == 400

    bad_login_response = client.post(
        "/api/v1/auth/login",
        json={
            "email": "newsurfer@example.com",
            "password": "wrongpassword",
            "locale": "en",
        },
    )
    assert bad_login_response.status_code == 400

    login_response = client.post(
        "/api/v1/auth/login",
        json={
            "email": "newsurfer@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert login_response.status_code == 200
    access_token = login_response.json()["access_token"]
    assert access_token
    assert login_response.json()["user"]["email"] == "newsurfer@example.com"

    me_response = client.get(
        "/api/v1/users/me",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert me_response.status_code == 200
    assert me_response.json()["email"] == "newsurfer@example.com"

    reset_request_response = client.post(
        "/api/v1/auth/password-reset/request",
        json={"email": "newsurfer@example.com"},
    )
    assert reset_request_response.status_code == 200
    reset_code = store.password_reset_codes["newsurfer@example.com"]
    assert reset_code in reset_request_response.json()["reset_hint"]

    missing_reset_response = client.post(
        "/api/v1/auth/password-reset/request",
        json={"email": "missing-surfer@example.com"},
    )
    assert missing_reset_response.status_code == 400
    assert missing_reset_response.json()["detail"] == "No account found for that email."

    bad_reset_response = client.post(
        "/api/v1/auth/password-reset/confirm",
        json={
            "email": "newsurfer@example.com",
            "code": "999999",
            "password": "newlongboard123",
        },
    )
    assert bad_reset_response.status_code == 400

    reset_confirm_response = client.post(
        "/api/v1/auth/password-reset/confirm",
        json={
            "email": "newsurfer@example.com",
            "code": reset_code,
            "password": "newlongboard123",
        },
    )
    assert reset_confirm_response.status_code == 200

    old_password_response = client.post(
        "/api/v1/auth/login",
        json={
            "email": "newsurfer@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert old_password_response.status_code == 400

    new_password_response = client.post(
        "/api/v1/auth/login",
        json={
            "email": "newsurfer@example.com",
            "password": "newlongboard123",
            "locale": "en",
        },
    )
    assert new_password_response.status_code == 200

    profile_response = client.put(
        "/api/v1/users/me",
        json={
            "display_name": "Newsurfer",
            "handle": "ty",
            "bio": "",
            "surf_skill": "beginner",
            "home_region": "",
            "avatar_url": None,
        },
        headers={"Authorization": f"Bearer {new_password_response.json()['access_token']}"},
    )
    assert profile_response.status_code == 200
    assert profile_response.json()["handle"] == "ty"

    rename_response = client.put(
        "/api/v1/users/me",
        json={
            "display_name": "Newsurfer",
            "handle": "samehandle",
            "bio": "",
            "surf_skill": "beginner",
            "home_region": "",
            "avatar_url": None,
        },
        headers={"Authorization": f"Bearer {new_password_response.json()['access_token']}"},
    )
    assert rename_response.status_code == 200

    other_signup_response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": "othersurfer@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert other_signup_response.status_code == 200
    other_token = other_signup_response.json()["session"]["access_token"]
    duplicate_handle_response = client.put(
        "/api/v1/users/me",
        json={
            "display_name": "Other Surfer",
            "handle": "samehandle",
            "bio": "",
            "surf_skill": "pro",
            "home_region": "",
            "avatar_url": None,
        },
        headers={"Authorization": f"Bearer {other_token}"},
    )
    assert duplicate_handle_response.status_code == 400

    delete_response = client.delete(
        "/api/v1/auth/account",
        headers={"Authorization": f"Bearer {new_password_response.json()['access_token']}"},
    )
    assert delete_response.status_code == 200
    assert "newsurfer@example.com" not in store.auth_accounts
    assert "newsurfer@example.com" not in store.verified_emails

    signup_again_response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": "newsurfer@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert signup_again_response.status_code == 200

    saved = json.loads(store.state_file.read_text())
    assert "newsurfer@example.com" in saved["auth_accounts"]
    assert "longboard123" not in saved["auth_accounts"]["newsurfer@example.com"]["password_hash"]


def test_admin_users_requires_token_and_lists_accounts(tmp_path, monkeypatch):
    store.state_file = tmp_path / "demo_state.json"
    store.verified_emails = set()
    store.email_verification_codes = {}
    store.password_reset_codes = {}
    store.auth_accounts = {}
    store.session_tokens = {}
    monkeypatch.setattr(
        "app.core.store.send_verification_email",
        lambda _email, _code: SimpleNamespace(
            configured=False,
            sent=False,
            error=None,
        ),
    )

    disabled_response = client.get("/api/v1/admin/users")
    assert disabled_response.status_code == 404

    monkeypatch.setenv("TYDES_ADMIN_TOKEN", "dev-admin-token")
    blocked_response = client.get("/api/v1/admin/users")
    assert blocked_response.status_code == 403

    signup_response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": "admincheck@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert signup_response.status_code == 200

    users_response = client.get(
        "/api/v1/admin/users",
        headers={"X-Tydes-Admin-Token": "dev-admin-token"},
    )

    assert users_response.status_code == 200
    payload = users_response.json()
    assert payload["count"] == 1
    assert payload["users"][0]["email"] == "admincheck@example.com"
    assert payload["users"][0]["handle"] == ""
    assert "password_hash" not in payload["users"][0]


def test_user_profile_requires_valid_session(tmp_path, monkeypatch):
    store.state_file = tmp_path / "demo_state.json"
    store.auth_accounts = {}
    store.session_tokens = {}
    store.verified_emails = set()
    store.email_verification_codes = {}
    monkeypatch.setattr(
        "app.core.store.send_verification_email",
        lambda _email, _code: SimpleNamespace(
            configured=False,
            sent=False,
            error=None,
        ),
    )

    signup_response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": "sessioncheck@example.com",
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert signup_response.status_code == 200
    access_token = signup_response.json()["session"]["access_token"]

    store.logout()

    missing_token_response = client.get("/api/v1/users/me")
    assert missing_token_response.status_code == 401

    invalid_token_response = client.get(
        "/api/v1/users/me",
        headers={"Authorization": "Bearer not-a-real-token"},
    )
    assert invalid_token_response.status_code == 401

    valid_token_response = client.get(
        "/api/v1/users/me",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert valid_token_response.status_code == 200
    assert valid_token_response.json()["email"] == "sessioncheck@example.com"
    assert valid_token_response.json()["handle"] == ""

    update_without_token_response = client.put(
        "/api/v1/users/me",
        json={
            "display_name": "Wrong User",
            "handle": "ty",
            "bio": "",
            "surf_skill": "beginner",
            "home_region": "",
            "avatar_url": None,
        },
    )
    assert update_without_token_response.status_code == 401


def test_social_feed_and_create_post(monkeypatch):
    access_token = _signup_access_token(monkeypatch, "socialpost@example.com")
    friends_response = client.get("/api/v1/social/friends")
    assert friends_response.status_code == 200
    assert len(friends_response.json()) >= 1

    blocked_response = client.post(
        "/api/v1/social/posts",
        json={
            "body": "This should not post without sign in.",
            "spot_id": "spot_echo_beach",
            "visibility": "public",
        },
    )
    assert blocked_response.status_code == 401

    create_response = client.post(
        "/api/v1/social/posts",
        json={
            "body": "Anyone surfing Echo Beach tomorrow morning?",
            "spot_id": "spot_echo_beach",
            "visibility": "friends",
        },
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert create_response.status_code == 200
    assert create_response.json()["body"].startswith("Anyone surfing")
    assert create_response.json()["visibility"] == "followers"
    assert create_response.json()["user_id"].startswith("usr_")

    posts_response = client.get("/api/v1/social/posts")
    assert posts_response.status_code == 200
    assert any(
        post["body"].startswith("Anyone surfing")
        for post in posts_response.json()
    )


def test_media_upload_stores_video_thumbnail_locally(monkeypatch, tmp_path):
    access_token = _signup_access_token(monkeypatch, "mediaupload@example.com")
    monkeypatch.setenv("MEDIA_STORAGE_BACKEND", "local")
    monkeypatch.setenv("TYDES_MEDIA_DIR", str(tmp_path / "media"))

    response = client.post(
        "/api/v1/social/media",
        headers={"Authorization": f"Bearer {access_token}"},
        files={
            "file": ("clip.mp4", b"fake video", "video/mp4"),
            "thumbnail": ("clip.jpg", b"fake image", "image/jpeg"),
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["media_type"] == "video"
    assert payload["url"].endswith(".mp4")
    assert payload["thumbnail_url"].endswith("_thumb.jpg")
    assert payload["thumbnail_url"] != payload["url"]
    assert len(list((tmp_path / "media").iterdir())) == 2
