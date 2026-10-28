from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from threading import Barrier
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault(
    "TYDES_DATA_DIR",
    tempfile.mkdtemp(prefix="tydes-test-state-"),
)

from app.main import app
from app.core import email_sender
from app.core.models import Alert, SurfWindowForecast, SurfWindowHour, TideForecast, Trip
from app.core.persistent_cache import CachedJson
from app.core.rate_limit import api_rate_limiter
from app.core.store import store
from app.integrations.tide_providers.tidecheck import TideCheckProvider
from app.integrations.weather_providers.open_meteo import OpenMeteoMarineProvider

client = TestClient(app)


@pytest.fixture(autouse=True)
def reset_api_rate_limits():
    api_rate_limiter.clear()
    yield
    api_rate_limiter.clear()


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


def test_email_delivery_hard_cap_stops_before_resend(monkeypatch):
    monkeypatch.setenv("RESEND_API_KEY", "re_test")
    monkeypatch.setenv("AUTH_EMAIL_FROM", "Tydes <verify@send.tydes.io>")
    def reject_email(*_rules):
        raise email_sender.HTTPException(status_code=429, detail="Too many requests")

    monkeypatch.setattr(email_sender.api_rate_limiter, "enforce", reject_email)
    monkeypatch.setattr(
        email_sender.httpx,
        "post",
        lambda *_args, **_kwargs: pytest.fail("Resend should not be called"),
    )

    result = email_sender.send_verification_email("surfer@example.com", "123456")

    assert result.configured is True
    assert result.sent is False
    assert result.error == "Email delivery safety limit reached."


def test_spots_list():
    response = client.get("/api/v1/spots")
    assert response.status_code == 200
    assert len(response.json()) >= 1


def test_taiwan_spot_coverage_includes_twenty_known_breaks():
    response = client.get("/api/v1/spots")
    assert response.status_code == 200

    taiwan_spots = {
        spot["name"] for spot in response.json() if spot["country"] == "Taiwan"
    }
    assert len(taiwan_spots) == 20
    assert {
        "Wushi Harbor",
        "Baishawan",
        "Beibin Park",
        "Baxiandong",
        "Changbin",
        "Xiaoyugang",
        "Jihui",
        "Duli",
    } <= taiwan_spots


def test_trips_start_empty_instead_of_showing_a_demo_itinerary(monkeypatch):
    access_token = _signup_access_token(monkeypatch, "empty-trips@example.com")
    response = client.get(
        "/api/v1/trips",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert response.status_code == 200
    assert response.json() == []


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("get", "/api/v1/trips"),
        ("get", "/api/v1/alerts"),
        ("get", "/api/v1/users/dashboard"),
        ("get", "/api/v1/users/favorites"),
        ("post", "/api/v1/billing/sync-revenuecat"),
    ],
)
def test_private_account_endpoints_require_authentication(method, path):
    response = getattr(client, method)(path)
    assert response.status_code == 401


def test_password_reset_email_requests_are_rate_limited(monkeypatch):
    email = "reset-limit@example.com"
    _signup_access_token(monkeypatch, email)
    sent_codes: list[str] = []
    monkeypatch.setattr(
        "app.core.store.send_password_reset_email",
        lambda _email, code: (
            sent_codes.append(code)
            or SimpleNamespace(configured=False, sent=False, error=None)
        ),
    )

    for _ in range(3):
        response = client.post(
            "/api/v1/auth/password-reset/request",
            json={"email": email},
        )
        assert response.status_code == 200

    blocked = client.post(
        "/api/v1/auth/password-reset/request",
        json={"email": email},
    )
    assert blocked.status_code == 429
    assert int(blocked.headers["retry-after"]) > 0
    assert len(sent_codes) == 3


def test_daily_post_limit_covers_posts_and_events(monkeypatch):
    access_token = _signup_access_token(monkeypatch, "post-limit@example.com")
    headers = {"Authorization": f"Bearer {access_token}"}
    monkeypatch.setenv("SOCIAL_DAILY_POST_LIMIT", "2")

    first = client.post(
        "/api/v1/social/posts",
        headers=headers,
        json={"body": "First post", "post_type": "general"},
    )
    second = client.post(
        "/api/v1/social/posts",
        headers=headers,
        json={"body": "Surf meetup", "post_type": "surf_plan"},
    )
    blocked = client.post(
        "/api/v1/social/posts",
        headers=headers,
        json={"body": "One too many", "post_type": "general"},
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert blocked.status_code == 429
    assert "2 posts or events per day" in blocked.json()["detail"]


def test_post_owner_can_delete_post_but_other_accounts_cannot(monkeypatch):
    owner_token = _signup_access_token(monkeypatch, "post-delete-owner@example.com")
    other_token = _signup_access_token(monkeypatch, "post-delete-other@example.com")
    owner_headers = {"Authorization": f"Bearer {owner_token}"}
    other_headers = {"Authorization": f"Bearer {other_token}"}

    created = client.post(
        "/api/v1/social/posts",
        headers=owner_headers,
        json={"body": "Temporary post", "post_type": "general"},
    )
    assert created.status_code == 200
    post_id = created.json()["id"]

    denied = client.delete(
        f"/api/v1/social/posts/{post_id}",
        headers=other_headers,
    )
    assert denied.status_code == 404

    deleted = client.delete(
        f"/api/v1/social/posts/{post_id}",
        headers=owner_headers,
    )
    assert deleted.status_code == 200
    assert deleted.json() == {"deleted": True}
    assert store.get_post(post_id) is None


def test_alert_changes_are_limited_to_the_owning_account(monkeypatch):
    owner_token = _signup_access_token(monkeypatch, "alert-owner@example.com")
    other_token = _signup_access_token(monkeypatch, "alert-other@example.com")
    owner_headers = {"Authorization": f"Bearer {owner_token}"}
    other_headers = {"Authorization": f"Bearer {other_token}"}

    created = client.post(
        "/api/v1/alerts",
        headers=owner_headers,
        json={"spot_id": "spot_balangan", "enabled": True},
    )
    assert created.status_code == 200
    alert_id = created.json()["id"]

    assert client.get("/api/v1/alerts", headers=other_headers).json() == []
    assert client.patch(
        f"/api/v1/alerts/{alert_id}",
        headers=other_headers,
        json={"enabled": False},
    ).status_code == 404
    assert client.delete(
        f"/api/v1/alerts/{alert_id}",
        headers=other_headers,
    ).status_code == 404

    owner_alerts = client.get("/api/v1/alerts", headers=owner_headers)
    assert owner_alerts.status_code == 200
    assert [item["id"] for item in owner_alerts.json()] == [alert_id]


def test_trips_are_limited_to_the_owning_account(monkeypatch):
    owner_token = _signup_access_token(monkeypatch, "trip-owner@example.com")
    other_token = _signup_access_token(monkeypatch, "trip-other@example.com")
    owner_headers = {"Authorization": f"Bearer {owner_token}"}
    other_headers = {"Authorization": f"Bearer {other_token}"}

    created = client.post(
        "/api/v1/trips",
        headers=owner_headers,
        json={
            "title": "Siargao run",
            "destination": "General Luna",
            "start_date": "2026-11-01",
            "end_date": "2026-11-08",
            "travelers": 1,
        },
    )
    assert created.status_code == 200

    assert client.get("/api/v1/trips", headers=other_headers).json() == []
    owner_trips = client.get("/api/v1/trips", headers=owner_headers)
    assert owner_trips.status_code == 200
    assert [item["title"] for item in owner_trips.json()] == ["Siargao run"]


def test_planning_uses_persistent_repository_when_configured(monkeypatch):
    class FakePlanningRepository:
        def __init__(self):
            self.trips = {}
            self.alerts = {}

        def list_trips(self, user_id):
            return [item for item in self.trips.values() if item.user_id == user_id]

        def save_trip(self, trip):
            self.trips[trip.id] = trip.model_copy(deep=True)

        def list_alerts(self, user_id):
            return [item for item in self.alerts.values() if item.user_id == user_id]

        def get_alert(self, alert_id, user_id):
            alert = self.alerts.get(alert_id)
            if alert is None or alert.user_id != user_id:
                return None
            return alert.model_copy(deep=True)

        def save_alert(self, alert):
            self.alerts[alert.id] = alert.model_copy(deep=True)

        def delete_alert(self, alert_id, user_id):
            alert = self.alerts.get(alert_id)
            if alert is None or alert.user_id != user_id:
                return False
            del self.alerts[alert_id]
            return True

    repository = FakePlanningRepository()
    monkeypatch.setattr(store, "postgres_planning", repository)
    monkeypatch.setattr(store, "_evaluate_alert", lambda _alert: None)
    user_id = "usr_persistent_planning"
    trip = Trip(
        id="trip_persistent",
        user_id=user_id,
        title="Taiwan run",
        destination="Taitung",
        start_date=date(2026, 11, 1),
        end_date=date(2026, 11, 8),
    )
    alert = Alert(
        id="alert_persistent",
        user_id=user_id,
        spot_id="spot_jinzun_harbor",
        next_check_at=datetime.now(timezone.utc),
    )

    store.add_trip(trip)
    store.add_alert(alert)
    updated = store.update_alert(
        alert.id,
        {"enabled": False},
        user_id=user_id,
    )

    assert list(store.list_trips(user_id)) == [trip]
    assert updated is not None and updated.enabled is False
    assert list(store.list_alerts(user_id))[0].enabled is False
    assert store.delete_alert(alert.id, user_id=user_id) is True
    assert list(store.list_alerts(user_id)) == []


def test_concurrent_requests_keep_account_context_isolated(monkeypatch):
    first_token = _signup_access_token(monkeypatch, "context-first@example.com")
    second_token = _signup_access_token(monkeypatch, "context-second@example.com")
    first_headers = {"Authorization": f"Bearer {first_token}"}
    second_headers = {"Authorization": f"Bearer {second_token}"}

    assert client.post(
        "/api/v1/users/favorites",
        headers=first_headers,
        json={"spot_id": "spot_balangan"},
    ).status_code == 200
    assert client.post(
        "/api/v1/users/favorites",
        headers=second_headers,
        json={"spot_id": "spot_bondi"},
    ).status_code == 200

    barrier = Barrier(2)
    original_list_favorites = store.list_favorite_spots

    def synchronized_list_favorites():
        barrier.wait(timeout=5)
        return original_list_favorites()

    monkeypatch.setattr(store, "list_favorite_spots", synchronized_list_favorites)

    def favorite_ids(token: str) -> set[str]:
        with TestClient(app) as concurrent_client:
            response = concurrent_client.get(
                "/api/v1/users/favorites",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert response.status_code == 200
        return {item["id"] for item in response.json()}

    with ThreadPoolExecutor(max_workers=2) as executor:
        first_future = executor.submit(favorite_ids, first_token)
        second_future = executor.submit(favorite_ids, second_token)
        assert first_future.result() == {"spot_balangan"}
        assert second_future.result() == {"spot_bondi"}


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


def test_open_meteo_forecast_keeps_swell_direction():
    provider = OpenMeteoMarineProvider()
    spot = store.spots[0]

    forecasts = provider._to_daily_forecasts(
        spot,
        {
            "hourly": {
                "time": ["2026-01-01T06:00", "2026-01-01T07:00"],
                "wave_height": [1.2, 1.4],
                "wave_period": [10, 12],
                "wave_direction": [350, 10],
                "wind_wave_height": [0.3, 0.5],
                "swell_wave_height": [1.0, 1.1],
                "swell_wave_direction": [220, 230],
                "sea_surface_temperature": [27.1, 27.3],
            }
        },
        {
            "hourly": {
                "time": ["2026-01-01T06:00", "2026-01-01T07:00"],
                "wind_speed_10m": [7.0, 9.0],
            }
        },
    )

    assert len(forecasts) == 1
    assert forecasts[0].wave_direction_deg == 0
    assert forecasts[0].swell_wave_direction_deg == 225


def test_open_meteo_uses_customer_api_key(monkeypatch):
    monkeypatch.setenv("OPEN_METEO_API_KEY", "om_test_key")

    provider = OpenMeteoMarineProvider()

    assert str(provider._marine_client.base_url) == (
        "https://customer-marine-api.open-meteo.com/v1/"
    )
    assert str(provider._forecast_client.base_url) == (
        "https://customer-api.open-meteo.com/v1/"
    )
    assert provider._with_api_key({"latitude": 1.0}) == {
        "latitude": 1.0,
        "apikey": "om_test_key",
    }


def test_open_meteo_uses_restart_safe_cached_forecast():
    provider = OpenMeteoMarineProvider()
    spot = store.spots[0]
    cached_forecast = store.forecasts[0].model_copy(
        update={
            "id": f"cached_{spot.id}",
            "spot_id": spot.id,
            "source": "open-meteo",
            "confidence": "live",
        }
    )
    requested = {}

    def cached_get(cache_key, max_age):
        requested["cache_key"] = cache_key
        requested["max_age"] = max_age
        return CachedJson(
            payload={
                "forecasts": [cached_forecast.model_dump(mode="json")],
                "hourly_rows": [],
            },
            updated_at=datetime.now(timezone.utc),
        )

    provider._persistent_cache = SimpleNamespace(get=cached_get)
    provider._marine_client = SimpleNamespace(
        get=lambda *_args, **_kwargs: pytest.fail("Marine API should not be called")
    )
    provider._forecast_client = SimpleNamespace(
        get=lambda *_args, **_kwargs: pytest.fail("Weather API should not be called")
    )

    forecasts = provider.fetch_spot_forecast(spot)

    assert forecasts == [cached_forecast]
    assert requested == {
        "cache_key": f"open-meteo:{spot.id}",
        "max_age": timedelta(hours=3),
    }


def test_tidecheck_uses_restart_safe_cached_tides(monkeypatch):
    monkeypatch.delenv("TIDECHECK_API_KEY", raising=False)
    provider = TideCheckProvider()
    spot = store.spots[0]
    start_day = date(2026, 10, 28)
    cached_forecast = TideForecast(
        spot_id=spot.id,
        available=True,
        station_name="Cached station",
        source="tidecheck",
    )

    provider._api_key = ""
    provider._persistent_cache = SimpleNamespace(
        get=lambda cache_key, max_age: CachedJson(
            payload=cached_forecast.model_dump(mode="json"),
            updated_at=datetime.now(timezone.utc),
        )
        if cache_key == f"tidecheck:tides:{spot.id}:{start_day.isoformat()}:3"
        and max_age == timedelta(hours=12)
        else None
    )
    provider._client = SimpleNamespace(
        get=lambda *_args, **_kwargs: pytest.fail("TideCheck should not be called")
    )

    forecast = provider.fetch_spot_tides(spot, start_day)

    assert forecast == cached_forecast


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


def test_next_swell_picks_one_best_destination_and_includes_australia(monkeypatch):
    store._next_swell_cache = None
    checked_spot_ids = set()

    def fake_live_forecast(spot, **_kwargs):
        checked_spot_ids.add(spot.id)
        is_snapper = spot.id == "spot_snapper"
        return [
            store.forecasts[0].model_copy(
                update={
                    "id": f"next_swell_{spot.id}",
                    "spot_id": spot.id,
                    "day": date.today() + timedelta(days=2),
                    "wave_height_m": 2.4 if is_snapper else 1.0,
                    "swell_wave_height_m": 2.1 if is_snapper else 0.7,
                    "period_s": 14 if is_snapper else 8,
                    "wind_kts": 8.0 if is_snapper else 18.0,
                    "quality": "epic" if is_snapper else "fair",
                    "source": "open-meteo",
                    "confidence": "live",
                }
            )
        ]

    monkeypatch.setattr(
        store.weather_provider,
        "fetch_spot_forecast",
        fake_live_forecast,
    )

    response = client.get("/api/v1/forecasts/next-swell")

    assert response.status_code == 200
    result = response.json()
    assert result["available"] is True
    assert result["spot_id"] == "spot_snapper"
    assert result["spot_name"] == "Snapper Rocks"
    assert result["destination"] == "Gold Coast, Australia"
    assert result["swell_height_m"] == 2.1
    assert result["source"] == "open-meteo"
    assert {
        "spot_snapper",
        "spot_lennox",
        "spot_bells",
        "spot_surfers_point",
    } <= checked_spot_ids
    store._next_swell_cache = None


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


def test_configured_premium_email_gets_premium_access(monkeypatch):
    email = "launch-reviewer@example.com"
    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", f"{email}, vip@example.com")
    _stub_email_senders(monkeypatch)
    signup_response = client.post(
        "/api/v1/auth/signup",
        json={
            "email": email,
            "password": "longboard123",
            "locale": "en",
        },
    )
    assert signup_response.status_code == 200
    access_token = signup_response.json()["session"]["access_token"]

    response = client.get(
        "/api/v1/users/me",
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert response.status_code == 200
    assert response.json()["email"] == email
    assert response.json()["premium"] is True
    assert response.json()["ads_enabled"] is False


def test_premium_email_override_applies_to_existing_session(monkeypatch):
    email = "existing-reviewer@example.com"
    monkeypatch.delenv("TYDES_PREMIUM_EMAILS", raising=False)
    access_token = _signup_access_token(monkeypatch, email)
    before_response = client.get(
        "/api/v1/users/me",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert before_response.status_code == 200
    assert before_response.json()["premium"] is False

    monkeypatch.setenv("TYDES_PREMIUM_EMAILS", email)
    after_response = client.get(
        "/api/v1/users/me",
        headers={"Authorization": f"Bearer {access_token}"},
    )

    assert after_response.status_code == 200
    assert after_response.json()["premium"] is True
    assert after_response.json()["ads_enabled"] is False


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


def test_balangan_surf_window_is_locked_for_free_users(monkeypatch):
    store.login("demo@surftravel.app")
    store.user.free_live_spot_id = None

    def fail_if_called(_spot, **_kwargs):
        raise AssertionError("Locked free users should not fetch surf windows")

    monkeypatch.setattr(store.weather_provider, "fetch_spot_surf_window", fail_if_called)

    response = client.get(
        "/api/v1/forecasts/surf-window",
        params={"spot_id": "spot_balangan"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["available"] is False
    assert payload["note"] == "Premium unlocks Best Time Today."


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


def test_can_add_and_remove_favorite_spot(monkeypatch):
    access_token = _signup_access_token(monkeypatch, "favorites@example.com")
    auth_headers = {"Authorization": f"Bearer {access_token}"}

    add_response = client.post(
        "/api/v1/users/favorites",
        json={"spot_id": "spot_balangan"},
        headers=auth_headers,
    )
    assert add_response.status_code == 200
    assert add_response.json()["favorite_spot_ids"] == ["spot_balangan"]

    list_response = client.get("/api/v1/users/favorites", headers=auth_headers)
    assert list_response.status_code == 200
    assert list_response.json()[0]["id"] == "spot_balangan"

    remove_response = client.delete(
        "/api/v1/users/favorites/spot_balangan",
        headers=auth_headers,
    )
    assert remove_response.status_code == 200
    assert remove_response.json()["favorite_spot_ids"] == []


def test_free_live_spot_can_change_after_cooldown(monkeypatch):
    original_user = store.user
    monkeypatch.setattr(store, "_save_state", lambda: None)
    try:
        store.user = original_user.model_copy(
            update={
                "premium": False,
                "free_live_spot_id": None,
                "free_live_spot_changed_at": None,
            }
        )

        first = store.set_free_live_spot("spot_bondi")
        assert first is not None
        assert first.free_live_spot_id == "spot_bondi"
        assert first.free_live_spot_changed_at is not None

        with pytest.raises(ValueError, match="change your free premium break"):
            store.set_free_live_spot("spot_balangan")

        store.user.free_live_spot_changed_at = datetime.now(timezone.utc) - timedelta(
            hours=25
        )
        changed = store.set_free_live_spot("spot_balangan")
        assert changed is not None
        assert changed.free_live_spot_id == "spot_balangan"
    finally:
        store.user = original_user


def test_can_toggle_and_delete_alert(monkeypatch):
    access_token = _signup_access_token(monkeypatch, "alerts@example.com")
    auth_headers = {"Authorization": f"Bearer {access_token}"}
    create_response = client.post(
        "/api/v1/alerts",
        json={
            "spot_id": "spot_balangan",
            "min_wave_height_m": 1.2,
            "max_wind_kts": 16,
            "enabled": True,
        },
        headers=auth_headers,
    )
    assert create_response.status_code == 200
    alert_id = create_response.json()["id"]

    update_response = client.patch(
        f"/api/v1/alerts/{alert_id}",
        json={"enabled": False},
        headers=auth_headers,
    )
    assert update_response.status_code == 200
    assert update_response.json()["enabled"] is False

    delete_response = client.delete(
        f"/api/v1/alerts/{alert_id}",
        headers=auth_headers,
    )
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

    blocked_profile_response = client.put(
        "/api/v1/users/me",
        json={
            "display_name": "Newsurfer",
            "handle": "ty",
            "bio": "onlyfans promo",
            "surf_skill": "beginner",
            "home_region": "",
            "avatar_url": None,
        },
        headers={"Authorization": f"Bearer {new_password_response.json()['access_token']}"},
    )
    assert blocked_profile_response.status_code == 400

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
    public_profiles_response = client.get("/api/v1/social/profiles")
    assert public_profiles_response.status_code == 200
    assert any(
        profile["handle"] == "samehandle"
        for profile in public_profiles_response.json()
    )
    assert all(
        profile["user_id"] != "usr_demo"
        for profile in public_profiles_response.json()
    )

    profiles_response = client.get(
        "/api/v1/social/profiles",
        headers={"Authorization": f"Bearer {other_token}"},
    )
    assert profiles_response.status_code == 200
    profiles = profiles_response.json()
    assert any(profile["handle"] == "samehandle" for profile in profiles)
    assert all(profile["user_id"] != "usr_demo" for profile in profiles)

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
    owner_user_id = create_response.json()["user_id"]
    post_id = create_response.json()["id"]

    rejected_post_response = client.post(
        "/api/v1/social/posts",
        json={
            "body": "onlyfans promo",
            "spot_id": "spot_echo_beach",
            "visibility": "public",
        },
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert rejected_post_response.status_code == 400

    rejected_comment_response = client.post(
        "/api/v1/social/comments",
        json={
            "post_id": post_id,
            "text": "onlyfans promo",
        },
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert rejected_comment_response.status_code == 400

    posts_response = client.get("/api/v1/social/posts")
    assert posts_response.status_code == 200
    assert any(
        post["body"].startswith("Anyone surfing")
        for post in posts_response.json()
    )

    blocked_relationships = client.get("/api/v1/social/relationships")
    assert blocked_relationships.status_code == 401

    follow_response = client.post(
        "/api/v1/social/follows/friend_lina",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert follow_response.status_code == 200
    assert "friend_lina" in follow_response.json()["followed_user_ids"]

    relationships_response = client.get(
        "/api/v1/social/relationships",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert relationships_response.status_code == 200
    assert "friend_lina" in relationships_response.json()["followed_user_ids"]

    unfollow_response = client.delete(
        "/api/v1/social/follows/friend_lina",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert unfollow_response.status_code == 200
    assert "friend_lina" not in unfollow_response.json()["followed_user_ids"]

    actor_token = _signup_access_token(monkeypatch, "socialactor@example.com")

    blocked_notifications = client.get("/api/v1/social/notifications")
    assert blocked_notifications.status_code == 401

    actor_follow_response = client.post(
        f"/api/v1/social/follows/{owner_user_id}",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert actor_follow_response.status_code == 200
    assert owner_user_id in actor_follow_response.json()["followed_user_ids"]

    actor_like_response = client.post(
        f"/api/v1/social/posts/{post_id}/likes",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert actor_like_response.status_code == 200
    assert post_id in actor_like_response.json()["liked_post_ids"]

    report_response = client.post(
        "/api/v1/social/reports",
        json={
            "target_type": "post",
            "target_id": post_id,
            "reason": "Spam or unsafe meetup",
        },
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert report_response.status_code == 200
    assert report_response.json()["target_id"] == post_id
    assert report_response.json()["reporter_user_id"] != owner_user_id

    monkeypatch.setenv("TYDES_ADMIN_TOKEN", "dev-admin-token")
    reports_response = client.get(
        "/api/v1/admin/reports",
        headers={"X-Tydes-Admin-Token": "dev-admin-token"},
    )
    assert reports_response.status_code == 200
    assert any(
        report["target_id"] == post_id
        for report in reports_response.json()["reports"]
    )

    block_response = client.post(
        f"/api/v1/social/blocks/{owner_user_id}",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert block_response.status_code == 200
    assert owner_user_id in block_response.json()["blocked_user_ids"]
    assert owner_user_id not in block_response.json()["followed_user_ids"]

    blocked_posts_response = client.get(
        "/api/v1/social/posts",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert blocked_posts_response.status_code == 200
    assert all(
        post["user_id"] != owner_user_id
        for post in blocked_posts_response.json()
    )

    blocked_profiles_response = client.get(
        "/api/v1/social/profiles",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert blocked_profiles_response.status_code == 200
    assert all(
        profile["user_id"] != owner_user_id
        for profile in blocked_profiles_response.json()
    )

    blocked_list_response = client.get(
        "/api/v1/social/blocked-profiles",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert blocked_list_response.status_code == 200
    assert any(
        profile["user_id"] == owner_user_id
        for profile in blocked_list_response.json()
    )

    unblock_response = client.delete(
        f"/api/v1/social/blocks/{owner_user_id}",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert unblock_response.status_code == 200
    assert owner_user_id not in unblock_response.json()["blocked_user_ids"]

    restored_posts_response = client.get(
        "/api/v1/social/posts",
        headers={"Authorization": f"Bearer {actor_token}"},
    )
    assert restored_posts_response.status_code == 200
    assert any(
        post["id"] == post_id
        for post in restored_posts_response.json()
    )

    notifications_response = client.get(
        "/api/v1/social/notifications",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert notifications_response.status_code == 200
    notifications = notifications_response.json()
    notification_types = {item["type"] for item in notifications}
    assert {"follow", "like"} <= notification_types
    assert all(item["recipient_user_id"] == owner_user_id for item in notifications)
    assert any(
        item["type"] == "like" and item["post_id"] == post_id
        for item in notifications
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


def test_r2_posts_hide_legacy_backend_media(monkeypatch):
    monkeypatch.setenv("MEDIA_STORAGE_BACKEND", "r2")

    posts = list(store.list_posts())

    assert all(
        not media.url.startswith("http://127.0.0.1:8000/media/")
        for post in posts
        for media in post.media
    )


def test_direct_r2_video_upload_is_verified_before_posting(monkeypatch):
    import app.modules.social.router as social_router_module
    from app.core.media_storage import R2MediaStorage, StoredObjectMetadata

    class FakeR2Storage(R2MediaStorage):
        def __init__(self):
            self.objects: dict[str, tuple[bytes, str]] = {}

        def public_object_url(self, object_name: str) -> str:
            return f"https://media.example/{object_name}"

        def create_direct_upload_url(
            self,
            object_name: str,
            *,
            content_type: str,
            content_length: int,
            expires_seconds: int,
        ) -> str:
            del content_type, content_length, expires_seconds
            return f"https://upload.example/{object_name}"

        def object_metadata(self, object_name: str) -> StoredObjectMetadata:
            data, content_type = self.objects[object_name]
            return StoredObjectMetadata(size=len(data), content_type=content_type)

        def read_object_range(self, object_name: str, start: int, end: int) -> bytes:
            return self.objects[object_name][0][start : end + 1]

        def promote_object(
            self,
            pending_name: str,
            final_name: str,
            *,
            content_type: str,
        ) -> None:
            data, _ = self.objects.pop(pending_name)
            self.objects[final_name] = (data, content_type)

        def delete_object(self, object_name: str | None) -> None:
            if object_name is not None:
                self.objects.pop(object_name, None)

    email = "premium@protected-upload.example.com"
    access_token = _signup_access_token(monkeypatch, email)
    signed_in_user = store.resolve_session_user(access_token)
    assert signed_in_user is not None
    assert signed_in_user.premium is True
    assert signed_in_user.email_verified is False
    storage = FakeR2Storage()
    monkeypatch.setattr(social_router_module, "configured_media_storage", lambda: storage)

    mvhd = b"".join(
        [
            (28).to_bytes(4, "big"),
            b"mvhd",
            b"\x00\x00\x00\x00",
            (0).to_bytes(4, "big"),
            (0).to_bytes(4, "big"),
            (1_000).to_bytes(4, "big"),
            (30_000).to_bytes(4, "big"),
        ]
    )
    video = (len(mvhd) + 8).to_bytes(4, "big") + b"moov" + mvhd
    thumbnail = b"thumbnail"
    headers = {"Authorization": f"Bearer {access_token}"}
    reservation_response = client.post(
        "/api/v1/social/media/uploads",
        headers=headers,
        json={
            "media_type": "video",
            "content_type": "video/mp4",
            "size_bytes": len(video),
            "thumbnail_content_type": "image/jpeg",
            "thumbnail_size_bytes": len(thumbnail),
        },
    )
    assert reservation_response.status_code == 200
    reservation_id = reservation_response.json()["id"]
    reservation = social_router_module.upload_ledger.get(
        reservation_id,
        signed_in_user.id,
    )
    assert reservation is not None
    storage.objects[reservation.pending_name] = (video, "video/mp4")
    assert reservation.pending_thumbnail_name is not None
    storage.objects[reservation.pending_thumbnail_name] = (
        thumbnail,
        "image/jpeg",
    )

    completed_response = client.post(
        f"/api/v1/social/media/uploads/{reservation_id}/complete",
        headers=headers,
    )
    assert completed_response.status_code == 200
    attachment = completed_response.json()

    post_response = client.post(
        "/api/v1/social/posts",
        headers=headers,
        json={
            "body": "Protected upload",
            "post_type": "general",
            "visibility": "public",
            "media": [attachment],
        },
    )
    assert post_response.status_code == 200
    assert post_response.json()["media"][0]["id"] == reservation_id
