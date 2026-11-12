"""Public previews are a whitelist, never a public copy of the social API."""
from datetime import datetime, timedelta, timezone
import hashlib
import os
from pathlib import Path
import sys
import tempfile

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-public-tests-"))

from app.main import app
from app.core.models import SocialMediaAttachment, SocialPost, User
from app.core.rate_limit import api_rate_limiter
from app.core.store import store

client = TestClient(app)


@pytest.fixture(autouse=True)
def isolated_preview_data(monkeypatch, tmp_path):
    monkeypatch.setattr(store, "postgres_auth", None)
    monkeypatch.setattr(store, "postgres_social", None)
    monkeypatch.setattr(store, "state_file", tmp_path / "public.json")
    monkeypatch.setattr(store, "followed_user_ids", set())
    monkeypatch.setattr(store, "blocked_user_ids", set())
    host = User(id="host", email="host@example.com", display_name="Maya Surfer",
                handle="maya", home_region="Bali", locale="en", email_verified=True)
    viewer = host.model_copy(update={"id": "viewer", "email": "viewer@example.com", "handle": "viewer"})
    monkeypatch.setattr(store, "auth_accounts", {
        user.email: {"user": user.model_dump(mode="json")} for user in [host, viewer]
    })
    monkeypatch.setattr(store, "session_tokens", {
        hashlib.sha256(token.encode()).hexdigest(): user.email
        for token, user in [("host-token", host), ("viewer-token", viewer)]
    })
    event = SocialPost(
        id="public_event", user_id=host.id, author_name="Old name", post_type="surf_plan",
        body="Sunset surf at Uluwatu", spot_id=next(iter(store.spots)).id,
        meetup_date=(datetime.now(timezone.utc) + timedelta(days=2)).date(),
        created_at=datetime.now(timezone.utc),
        media=[SocialMediaAttachment(id="secret-media", url="https://example.com/video.mp4",
                                    thumbnail_url="https://example.com/thumbnail.jpg")],
        rsvp_count=7,
    )
    monkeypatch.setattr(store, "posts", [
        event,
        event.model_copy(update={"id": "private_event", "visibility": "followers"}),
        event.model_copy(update={"id": "general_post", "post_type": "general"}),
        event.model_copy(update={"id": "orphan_event", "user_id": "deleted-user"}),
    ])
    api_rate_limiter.clear()
    yield
    api_rate_limiter.clear()


def test_spot_preview_is_static_public_information_only():
    spot = next(iter(store.spots))
    response = client.get(f"/api/v1/public/spots/{spot.id}")
    assert response.status_code == 200
    assert set(response.json()) == {"id", "name", "country", "region", "area", "summary", "difficulty", "best_months"}
    assert response.json()["name"] == spot.name
    assert response.headers["Cache-Control"] == "public, max-age=3600"
    assert client.get("/api/v1/public/spots/missing").status_code == 404


def test_public_event_has_host_date_and_spot_but_no_membership_or_media():
    response = client.get("/api/v1/public/events/public_event")
    assert response.status_code == 200
    data = response.json()
    assert set(data) == {"id", "body", "meetup_date", "meetup_end_date", "ended", "host", "spot"}
    assert data["host"] == {"name": "Maya Surfer", "handle": "maya", "avatar_url": None}
    assert data["ended"] is False
    for secret in ["host@example.com", "secret-media", "video.mp4", "rsvp_count", "attendees", "premium"]:
        assert secret not in response.text
    assert response.headers["Cache-Control"] == "no-store"


@pytest.mark.parametrize("post_id", ["private_event", "general_post", "missing", "orphan_event"])
@pytest.mark.parametrize("token", [None, "host-token", "viewer-token"])
def test_non_public_events_are_indistinguishable_even_to_owner(post_id, token):
    headers = {} if token is None else {"Authorization": f"Bearer {token}"}
    response = client.get(f"/api/v1/public/events/{post_id}", headers=headers)
    assert response.status_code == 404
    assert response.json() == {"detail": "This event is not available publicly."}
    assert response.headers["Cache-Control"] == "no-store"


def test_banned_host_event_is_not_public():
    store.auth_accounts["host@example.com"]["user"]["banned"] = True
    assert client.get("/api/v1/public/events/public_event").status_code == 404


def test_past_events_are_labelled_and_undated_events_do_not_invent_dates():
    store.posts[0].meetup_date = (datetime.now(timezone.utc) - timedelta(days=1)).date()
    assert client.get("/api/v1/public/events/public_event").json()["ended"] is True
    store.posts[0].meetup_date = None
    data = client.get("/api/v1/public/events/public_event").json()
    assert data["meetup_date"] is None and data["ended"] is False


def test_private_feed_and_authenticated_single_post_enforce_visibility():
    assert client.get("/api/v1/social/posts").status_code == 401
    assert client.get("/api/v1/social/posts/private_event").status_code == 401
    viewer = {"Authorization": "Bearer viewer-token"}
    assert {post["id"] for post in client.get("/api/v1/social/posts", headers=viewer).json()} == {
        "public_event", "general_post", "orphan_event"
    }
    assert client.get("/api/v1/social/posts/private_event", headers=viewer).status_code == 404
    assert client.get("/api/v1/social/posts/private_event", headers={"Authorization": "Bearer host-token"}).status_code == 200
    store.followed_user_ids.add("host")
    assert client.get("/api/v1/social/posts/private_event", headers=viewer).status_code == 200
    store.blocked_user_ids.add("host")
    assert client.get("/api/v1/social/posts/private_event", headers=viewer).status_code == 404
    assert client.get("/api/v1/public/events/public_event", headers=viewer).status_code == 404


def test_preview_reads_are_rate_limited():
    path = f"/api/v1/public/spots/{next(iter(store.spots)).id}"
    for _ in range(120):
        assert client.get(path).status_code == 200
    response = client.get(path)
    assert response.status_code == 429
    assert "Retry-After" in response.headers


def test_guest_spot_catalog_only_adds_public_map_coordinates():
    response = client.get('/api/v1/public/spots')
    assert response.status_code == 200 and response.json()
    assert response.headers['Cache-Control'] == 'public, max-age=3600'
    assert set(response.json()[0]) == {'id', 'name', 'country', 'region', 'area', 'summary',
                                       'difficulty', 'best_months', 'latitude', 'longitude'}
    for item in response.json():
        assert -90 <= item['latitude'] <= 90 and -180 <= item['longitude'] <= 180
    for secret in ['wave_height', 'water_temp', 'image_url', 'forecast']:
        # Check the data contract, not harmless words in a public guide such as
        # "approximate forecast-area position". No private forecast fields may
        # appear on any catalog item.
        assert all(not any(secret in key for key in item) for item in response.json())


@pytest.mark.parametrize('token', [None, 'host-token', 'viewer-token'])
def test_guest_event_catalog_never_includes_private_or_expired_events(token):
    event = store.posts[0]
    today = datetime.now(timezone.utc).date()
    store.posts.extend([
        event.model_copy(update={'id': 'expired', 'meetup_date': today - timedelta(days=1)}),
        event.model_copy(update={'id': 'undated', 'meetup_date': None}),
        event.model_copy(update={'id': 'ongoing', 'meetup_date': today - timedelta(days=2), 'meetup_end_date': today}),
    ])
    headers = {} if token is None else {'Authorization': f'Bearer {token}'}
    response = client.get('/api/v1/public/events', headers=headers)
    assert response.status_code == 200
    assert [item['id'] for item in response.json()] == ['ongoing', 'public_event']
    assert response.headers['Cache-Control'] == 'no-store'
    for secret in ['host@example.com', 'rsvp_count', 'private_event', 'video.mp4', 'user_id']:
        assert secret not in response.text
    store.posts[0].visibility = 'followers'
    assert [item['id'] for item in client.get('/api/v1/public/events').json()] == ['ongoing']
    store.auth_accounts['host@example.com']['user']['banned'] = True
    assert client.get('/api/v1/public/events').json() == []


def test_guest_events_are_bounded_and_read_only():
    event = store.posts[0]
    store.posts[:] = [event.model_copy(update={'id': f'public_{n:03}'}) for n in range(130)]
    response = client.get('/api/v1/public/events')
    assert len(response.json()) == 100
    assert response.json()[0]['id'] == 'public_000'
    assert client.post('/api/v1/public/events', json={'body': 'not allowed'}).status_code == 405
    assert client.post('/api/v1/social/posts/public_000/rsvp').status_code == 401
    assert client.get('/api/v1/social/posts/public_000/chat').status_code == 401
