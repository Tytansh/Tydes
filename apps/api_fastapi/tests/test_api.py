from pathlib import Path
import json
import sys

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.main import app
from app.core.store import store

client = TestClient(app)


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_spots_list():
    response = client.get("/api/v1/spots")
    assert response.status_code == 200
    assert len(response.json()) >= 1


def test_forecasts_fallback_uses_estimated_ranges(monkeypatch):
    def raise_provider_error(_spot):
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
    assert all(row["wave_height_m"] is None for row in rows)
    assert all(row["wave_height_min_m"] is not None for row in rows)
    assert all(row["wave_height_max_m"] is not None for row in rows)


def test_free_user_only_gets_live_data_for_unlocked_spot(monkeypatch):
    store.login("demo@surftravel.app")

    def fail_if_called(_spot):
        raise AssertionError("locked free spot should not hit live provider")

    monkeypatch.setattr(store.weather_provider, "fetch_spot_forecast", fail_if_called)

    response = client.get("/api/v1/forecasts", params={"spot_id": "spot_balangan"})

    assert response.status_code == 200
    rows = response.json()
    assert all(row["source"] == "estimated" for row in rows)


def test_premium_user_hides_ads_and_can_use_live_data(monkeypatch):
    store.login("demo+premium@surftravel.app")

    response = client.get("/api/v1/ads", params={"placement": "home_feed"})
    assert response.status_code == 200
    assert response.json() == []

    called = {"value": False}

    def fake_live_forecast(_spot):
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


def test_social_feed_and_create_post():
    friends_response = client.get("/api/v1/social/friends")
    assert friends_response.status_code == 200
    assert len(friends_response.json()) >= 1

    create_response = client.post(
        "/api/v1/social/posts",
        json={
            "body": "Anyone surfing Echo Beach tomorrow morning?",
            "spot_id": "spot_echo_beach",
            "visibility": "friends",
        },
    )
    assert create_response.status_code == 200
    assert create_response.json()["body"].startswith("Anyone surfing")
    assert create_response.json()["visibility"] == "friends"

    posts_response = client.get("/api/v1/social/posts")
    assert posts_response.status_code == 200
    assert any(
        post["body"].startswith("Anyone surfing")
        for post in posts_response.json()
    )
