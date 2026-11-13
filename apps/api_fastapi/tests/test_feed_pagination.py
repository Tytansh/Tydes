"""Cursor feed contracts exercised against local state and local SQL, never production."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import base64
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-feed-tests-"))

from app.main import app
from app.core.direct_messages import JsonDirectMessageRepository
from app.core.feed_pagination import decode_feed_cursor
from app.core.models import SocialComment, SocialMediaAttachment, SocialPost, SocialRepost, User
from app.core.postgres_social import PostgresSocialRepository
from app.core.rate_limit import api_rate_limiter
from app.core.store import store


class FeedSqlConnection:
    def __init__(self):
        self.db = sqlite3.connect(":memory:", check_same_thread=False)
        def rows(cursor, values):
            row = dict(zip((item[0] for item in cursor.description), values))
            if isinstance(row.get("payload"), str):
                row["payload"] = json.loads(row["payload"])
            return row
        self.db.row_factory = rows
        self.db.executescript("""
            CREATE TABLE social_posts (id TEXT PRIMARY KEY, user_id TEXT, payload TEXT, created_at TEXT);
            CREATE TABLE social_reposts (user_id TEXT, post_id TEXT, created_at TEXT, PRIMARY KEY(user_id,post_id));
            CREATE TABLE social_post_likes (user_id TEXT, post_id TEXT);
            CREATE TABLE social_rsvps (user_id TEXT, post_id TEXT);
            CREATE TABLE social_follows (follower_user_id TEXT, followed_user_id TEXT);
            CREATE TABLE social_blocks (user_id TEXT, blocked_user_id TEXT);
            CREATE TABLE social_comments (id TEXT PRIMARY KEY, post_id TEXT, user_id TEXT, payload TEXT, created_at TEXT);
            CREATE TABLE social_comment_likes (user_id TEXT, comment_id TEXT);
        """)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def execute(self, query, parameters=()):
        values = tuple(value.isoformat() if isinstance(value, datetime) else value for value in parameters)
        return self.db.execute(query.replace("%s", "?"), values)


@pytest.fixture(params=["local", "sql"])
def feed(request, monkeypatch, tmp_path):
    monkeypatch.setenv("DATABASE_URL", "")
    monkeypatch.setattr(store, "postgres_auth", None)
    monkeypatch.setattr(store, "postgres_social", None)
    monkeypatch.setattr(store, "state_file", tmp_path / "state.json")
    for name, value in {"posts": [], "comments": [], "reposts": [], "liked_post_ids": set(), "liked_comment_ids": set(),
                        "rsvp_user_ids_by_post": {}, "followed_user_ids": set(),
                        "blocked_user_ids": set()}.items():
        monkeypatch.setattr(store, name, value)
    viewer = User(id="viewer", email="viewer@example.com", display_name="Viewer", handle="viewer", email_verified=True, home_region="Bali", locale="en")
    monkeypatch.setattr(store, "_default_user", viewer.model_copy(deep=True))
    other = viewer.model_copy(update={"id": "other", "email": "other@example.com", "handle": "other"})
    unverified = viewer.model_copy(update={"id": "unverified", "email": "unverified@example.com", "email_verified": False})
    monkeypatch.setattr(store, "auth_accounts", {
        user.email: {"user": user.model_dump(mode="json")} for user in (viewer, other, unverified)
    })
    monkeypatch.setattr(store, "session_tokens", {
        hashlib.sha256(token.encode()).hexdigest(): user.email
        for token, user in (("viewer-token", viewer), ("other-token", other), ("unverified-token", unverified))
    })
    connection = FeedSqlConnection() if request.param == "sql" else None
    if connection is not None:
        repository = object.__new__(PostgresSocialRepository)
        monkeypatch.setattr(repository, "_connect", lambda: connection)
        monkeypatch.setattr(store, "postgres_social", repository)
    api_rate_limiter.clear()

    class Fixture:
        client = TestClient(app)
        headers = {"Authorization": "Bearer viewer-token"}
        sql = connection
        user = viewer
        instant = datetime.now(timezone.utc) - timedelta(days=1)

        def add(self, index, *, user_id="author", visibility="public", created_at=None):
            post = SocialPost(id=f"post_{index:03d}", user_id=user_id, author_name="Surfer",
                              body=f"Post {index}", post_type="general", visibility=visibility,
                              created_at=created_at or self.instant - timedelta(minutes=index))
            if self.sql is None:
                store.posts.append(post)
            else:
                self.sql.execute("INSERT INTO social_posts VALUES (%s,%s,%s,%s)",
                                 (post.id, post.user_id, json.dumps(post.model_dump(mode="json")), post.created_at))
            return post

        def repost(self, post, *, at=None, user_id="viewer"):
            instant = at or self.instant + timedelta(hours=1)
            if self.sql is None:
                assert user_id == "viewer"
                store.reposts.append(SocialRepost(post_id=post.id, created_at=instant))
            else:
                self.sql.execute("INSERT INTO social_reposts VALUES (%s,%s,%s)", (user_id, post.id, instant))

        def block(self, owner, peer):
            if self.sql is None:
                JsonDirectMessageRepository(tmp_path / "direct_messages.json").set_block(owner, peer, True)
                if owner == "viewer":
                    store.blocked_user_ids.add(peer)
            else:
                self.sql.execute("INSERT INTO social_blocks VALUES (%s,%s)", (owner, peer))

        def follow(self, author):
            if self.sql is None:
                store.followed_user_ids.add(author)
            else:
                self.sql.execute("INSERT INTO social_follows VALUES (%s,%s)", ("viewer", author))

        def page(self, *, cursor=None, limit=25, headers=None):
            params = {"limit": limit}
            if cursor is not None:
                params["cursor"] = cursor
            return self.client.get("/api/v1/social/feed", params=params, headers=self.headers if headers is None else headers)

        def delete(self, post_id):
            if self.sql is None:
                store.posts = [post for post in store.posts if post.id != post_id]
            else:
                self.sql.execute("DELETE FROM social_posts WHERE id=%s", (post_id,))

        def comment(self, post, index, *, user_id="commenter", created_at=None):
            comment = SocialComment(id=f"comment_{index:04d}", post_id=post.id, user_id=user_id,
                                    author_name="Commenter", text=f"Comment {index}",
                                    created_at=created_at or self.instant + timedelta(seconds=index))
            if self.sql is None:
                store.comments.append(comment)
            else:
                self.sql.execute("INSERT INTO social_comments VALUES (%s,%s,%s,%s,%s)",
                                 (comment.id, comment.post_id, comment.user_id,
                                  json.dumps(comment.model_dump(mode="json")), comment.created_at))
            return comment

        def like_post(self, post_id):
            if self.sql is None:
                store.liked_post_ids.add(post_id)
            else:
                self.sql.execute("INSERT INTO social_post_likes VALUES (%s,%s)", ("viewer", post_id))

        def like_comment(self, comment_id):
            if self.sql is None:
                store.liked_comment_ids.add(comment_id)
            else:
                self.sql.execute("INSERT INTO social_comment_likes VALUES (%s,%s)", ("viewer", comment_id))

    yield Fixture()
    api_rate_limiter.clear()
    if connection is not None:
        connection.db.close()


def _data(response):
    assert response.status_code == 200, response.text
    assert response.headers["cache-control"] == "private, no-store"
    result = response.json()
    assert set(result) == {"items", "next_cursor", "engagement", "scoped_post_ids"}
    assert set(result["scoped_post_ids"]) == {entry["post"]["id"] for entry in result["items"]}
    return result


def test_feed_paginates_beyond_old_fifty_post_limit(feed):
    expected = [feed.add(index).id for index in range(57)]
    pages = []
    cursor = None
    while True:
        data = _data(feed.page(cursor=cursor))
        pages.append(data["items"])
        cursor = data["next_cursor"]
        if cursor is None:
            break
    assert list(map(len, pages)) == [25, 25, 7]
    assert [item["post"]["id"] for page in pages for item in page] == expected
    assert len({item["entry_id"] for page in pages for item in page}) == 57


def test_feed_identical_timestamps_have_stable_ties(feed):
    for index in range(55):
        feed.add(index, created_at=feed.instant)
    ids = []
    cursor = None
    while True:
        data = _data(feed.page(cursor=cursor))
        ids.extend(item["post"]["id"] for item in data["items"])
        cursor = data["next_cursor"]
        if cursor is None:
            break
    assert ids == [f"post_{index:03d}" for index in reversed(range(55))]


def test_new_posts_and_reposts_do_not_shift_an_existing_snapshot(feed):
    posts = [feed.add(index) for index in range(52)]
    first = _data(feed.page())
    newer = datetime.now(timezone.utc) + timedelta(seconds=1)
    feed.add(999, created_at=newer)
    feed.repost(posts[-1], at=newer)
    second = _data(feed.page(cursor=first["next_cursor"]))
    third = _data(feed.page(cursor=second["next_cursor"]))
    combined = first["items"] + second["items"] + third["items"]
    assert [entry["post"]["id"] for entry in combined] == [post.id for post in posts]
    assert all(entry["kind"] == "post" for entry in combined)


def test_deleting_cursor_post_does_not_break_continuation(feed):
    posts = [feed.add(index) for index in range(40)]
    first = _data(feed.page())
    feed.delete(first["items"][-1]["post"]["id"])
    second = _data(feed.page(cursor=first["next_cursor"]))
    assert [entry["post"]["id"] for entry in second["items"]] == [post.id for post in posts[25:]]


def test_visibility_and_bidirectional_blocks_precede_page_limit(feed):
    for index in range(30):
        feed.add(index, visibility="followers", user_id="stranger")
    for index in range(30, 60):
        feed.add(index, user_id="blocked")
    for index in range(60, 90):
        feed.add(index, user_id="blocker")
    visible = [feed.add(index) for index in range(90, 120)]
    feed.block("viewer", "blocked")
    feed.block("blocker", "viewer")
    data = _data(feed.page())
    assert [entry["post"]["id"] for entry in data["items"]] == [post.id for post in visible[:25]]
    assert data["next_cursor"] is not None


def test_followers_and_own_posts_remain_visible_and_permissions_are_rechecked(feed):
    own = feed.add(0, visibility="followers", user_id="viewer")
    following = feed.add(1, visibility="followers", user_id="following")
    for index in range(2, 30):
        feed.add(index, user_id="following")
    feed.follow("following")
    first = _data(feed.page(limit=1))
    assert first["items"][0]["post"]["id"] == own.id
    second = _data(feed.page(cursor=first["next_cursor"], limit=1))
    assert second["items"][0]["post"]["id"] == following.id
    feed.block("following", "viewer")
    assert _data(feed.page(cursor=first["next_cursor"]))["items"] == []


def test_recent_repost_of_old_post_is_first_and_has_distinct_identity(feed):
    posts = [feed.add(index) for index in range(55)]
    feed.repost(posts[-1])
    first = _data(feed.page())
    assert first["items"][0]["entry_id"] == "repost:post_054"
    assert first["items"][0]["kind"] == "repost"
    entries = list(first["items"])
    cursor = first["next_cursor"]
    while cursor:
        page = _data(feed.page(cursor=cursor))
        entries.extend(page["items"])
        cursor = page["next_cursor"]
    assert len(entries) == 56
    assert len({item["entry_id"] for item in entries}) == 56
    assert sum(item["post"]["id"] == posts[-1].id for item in entries) == 2
    assert entries[-1]["entry_id"] == "post:post_054"


def test_post_and_repost_tie_order_is_stable_across_pages(feed):
    post = feed.add(1, created_at=feed.instant)
    feed.repost(post, at=feed.instant)
    first = _data(feed.page(limit=1))
    assert first["items"][0]["kind"] == "repost"
    second = _data(feed.page(limit=1, cursor=first["next_cursor"]))
    assert second["items"][0]["kind"] == "post"
    assert second["next_cursor"] is None


@pytest.mark.parametrize("cursor", ["", "not-json", "=", "a" * 1025])
def test_invalid_cursor_is_rejected(feed, cursor):
    response = feed.page(cursor=cursor)
    assert response.status_code in {400, 422}
    assert "items" not in response.json()


def test_cursor_is_bound_to_current_account(feed):
    for index in range(30):
        feed.add(index)
    cursor = _data(feed.page())["next_cursor"]
    response = feed.page(cursor=cursor, headers={"Authorization": "Bearer other-token"})
    assert response.status_code == 400


@pytest.mark.parametrize("change", [
    {"v": 2}, {"v": True}, {"k": "other"}, {"p": "bad/id"},
    {"a": "2026-01-01"}, {"s": "9999-01-01T00:00:00+00:00"},
    {"a": "9999-01-01T00:00:00+00:00"}, {"extra": "unexpected"},
])
def test_cursor_fields_are_validated(feed, change):
    for index in range(30):
        feed.add(index)
    cursor = _data(feed.page())["next_cursor"]
    value = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))
    value.update(change)
    invalid = base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    assert feed.page(cursor=invalid).status_code == 400


def test_feed_requires_verified_authentication_and_bounded_limit(feed):
    assert feed.page(headers={}).status_code == 401
    unverified = feed.page(headers={"Authorization": "Bearer unverified-token"})
    assert unverified.status_code == 403
    assert unverified.json()["detail"]["code"] == "email_verification_required"
    assert feed.page(limit=0).status_code == 422
    assert feed.page(limit=51).status_code == 422


def test_legacy_posts_response_shape_remains_list(feed):
    feed.add(1)
    response = feed.client.get("/api/v1/social/posts", headers=feed.headers)
    assert response.status_code == 200
    assert isinstance(response.json(), list)


def test_feed_sql_counts_only_other_users_and_only_current_viewer_reposts(feed):
    if feed.sql is None:
        pytest.skip("SQL engagement contract")
    event = feed.add(0, user_id="host")
    feed.sql.execute("INSERT INTO social_post_likes VALUES (%s,%s)", ("viewer", event.id))
    feed.sql.execute("INSERT INTO social_post_likes VALUES (%s,%s)", ("other", event.id))
    feed.sql.execute("INSERT INTO social_rsvps VALUES (%s,%s)", ("host", event.id))
    feed.sql.execute("INSERT INTO social_rsvps VALUES (%s,%s)", ("guest", event.id))
    feed.repost(event, user_id="other")
    data = _data(feed.page())
    assert len(data["items"]) == 1
    post = data["items"][0]["post"]
    assert post["like_count"] == 1 and post["repost_count"] == 1 and post["rsvp_count"] == 1


def test_feed_engagement_is_scoped_to_returned_posts(feed):
    posts = [feed.add(index) for index in range(30)]
    visible_comment = feed.comment(posts[0], 0)
    outside_comment = feed.comment(posts[-1], 1)
    feed.like_post(posts[0].id)
    feed.like_post(posts[-1].id)
    feed.like_comment(visible_comment.id)
    feed.like_comment(outside_comment.id)
    data = _data(feed.page(limit=1))
    assert data["scoped_post_ids"] == [posts[0].id]
    engagement = data["engagement"]
    assert engagement["liked_post_ids"] == [posts[0].id]
    assert engagement["liked_comment_ids"] == [visible_comment.id]
    assert [comment["id"] for comment in engagement["comments"]] == [visible_comment.id]


def test_legacy_engagement_comments_enforce_visibility_and_both_block_directions(feed):
    public = feed.add(0)
    private = feed.add(1, user_id="stranger", visibility="followers")
    blocked = feed.add(2, user_id="blocked")
    blocker = feed.add(3, user_id="blocker")
    visible = feed.comment(public, 0)
    for index, post in enumerate([private, blocked, blocker], start=1):
        feed.comment(post, index)
    feed.comment(public, 4, user_id="blocked")
    feed.comment(public, 5, user_id="blocker")
    feed.block("viewer", "blocked")
    feed.block("blocker", "viewer")
    response = feed.client.get("/api/v1/social/engagement", headers=feed.headers)
    assert response.status_code == 200
    assert [item["id"] for item in response.json()["comments"]] == [visible.id]


def test_engagement_filters_private_comments_before_cap(feed):
    public = feed.add(0)
    private = feed.add(1, user_id="stranger", visibility="followers")
    for index in range(510):
        feed.comment(public, index)
        feed.comment(private, 1000 + index)
    feed.like_comment("comment_0000")
    feed.like_comment("comment_0509")
    response = feed.client.get("/api/v1/social/engagement", headers=feed.headers)
    assert response.status_code == 200
    comments = response.json()["comments"]
    assert len(comments) == 500
    assert {item["post_id"] for item in comments} == {public.id}
    assert comments[0]["id"] == "comment_0509" and comments[-1]["id"] == "comment_0010"
    assert response.json()["liked_comment_ids"] == ["comment_0509"]


def test_local_legacy_relationships_and_personal_activity_do_not_belong_to_other_accounts(feed):
    if feed.sql is not None:
        pytest.skip("Legacy JSON fallback only")
    public = feed.add(0)
    private = feed.add(1, user_id="private-author", visibility="followers")
    public_comment = feed.comment(public, 0)
    private_comment = feed.comment(private, 1)
    feed.follow("private-author")
    feed.repost(public)
    feed.like_post(public.id)
    feed.like_comment(public_comment.id)

    owner = _data(feed.page())
    assert private.id in {item["post"]["id"] for item in owner["items"]}
    assert any(item["kind"] == "repost" for item in owner["items"])
    assert public.id in owner["engagement"]["liked_post_ids"]

    outsider_headers = {"Authorization": "Bearer other-token"}
    outsider = _data(feed.page(headers=outsider_headers))
    assert [item["entry_id"] for item in outsider["items"]] == [f"post:{public.id}"]
    assert outsider["engagement"]["liked_post_ids"] == []
    assert outsider["engagement"]["reposted_post_ids"] == []
    assert outsider["engagement"]["reposts"] == []
    assert outsider["engagement"]["liked_comment_ids"] == []
    assert [comment["id"] for comment in outsider["engagement"]["comments"]] == [public_comment.id]
    legacy = feed.client.get("/api/v1/social/engagement", headers=outsider_headers)
    assert legacy.status_code == 200
    assert legacy.json()["reposts"] == [] and legacy.json()["liked_post_ids"] == []
    assert private_comment.id not in {comment["id"] for comment in legacy.json()["comments"]}

    # New account-scoped block records still apply in both directions, even
    # when the account cannot inherit the persisted owner's legacy block set.
    feed.block("author", "other")
    assert _data(feed.page(headers=outsider_headers))["items"] == []
