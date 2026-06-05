from __future__ import annotations

from datetime import datetime, timezone
import os
from typing import Any

from app.core.models import (
    SocialComment,
    SocialEngagementState,
    SocialPost,
    SocialRepost,
    User,
)


class PostgresSocialRepository:
    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_schema()

    @classmethod
    def from_env(cls) -> "PostgresSocialRepository | None":
        database_url = os.getenv("DATABASE_URL", "").strip()
        if not database_url:
            return None
        return cls(database_url)

    def bootstrap_from_state(
        self,
        *,
        posts: list[SocialPost],
        comments: list[SocialComment],
        engagement_state: SocialEngagementState,
        user_id: str,
    ) -> None:
        if self.post_count() > 0:
            return
        for post in posts:
            self.save_post(post)
        for comment in comments:
            if self.get_post(comment.post_id) is not None:
                self.save_comment(comment)
        for post_id in engagement_state.liked_post_ids:
            if self.get_post(post_id) is not None:
                self.set_post_like(user_id, post_id, True)
        for repost in engagement_state.reposts:
            if self.get_post(repost.post_id) is not None:
                self.set_repost(user_id, repost.post_id, True, repost.created_at)
        if not engagement_state.reposts:
            for post_id in engagement_state.reposted_post_ids:
                post = self.get_post(post_id)
                if post is not None:
                    self.set_repost(user_id, post_id, True, post.created_at)
        for comment_id in engagement_state.liked_comment_ids:
            if self.get_comment(comment_id) is not None:
                self.set_comment_like(user_id, comment_id, True)
        for post_id in engagement_state.rsvp_post_ids:
            if self.get_post(post_id) is not None:
                self.set_rsvp(user_id, post_id, True)

    def post_count(self) -> int:
        with self._connect() as connection:
            row = connection.execute("SELECT COUNT(*) AS count FROM social_posts").fetchone()
        return int(row["count"])

    def list_posts(self) -> list[SocialPost]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT payload FROM social_posts ORDER BY created_at DESC"
            ).fetchall()
        return [
            SocialPost.model_validate(_payload_dict(row["payload"]))
            for row in rows
        ]

    def get_post(self, post_id: str) -> SocialPost | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT payload FROM social_posts WHERE id = %s",
                (post_id,),
            ).fetchone()
        if row is None:
            return None
        return SocialPost.model_validate(_payload_dict(row["payload"]))

    def save_post(self, post: SocialPost) -> None:
        payload = post.model_dump(mode="json")
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO social_posts (id, user_id, payload, created_at)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (id) DO UPDATE
                SET user_id = EXCLUDED.user_id,
                    payload = EXCLUDED.payload,
                    created_at = EXCLUDED.created_at,
                    updated_at = NOW()
                """,
                (
                    post.id,
                    post.user_id,
                    self._jsonb(payload),
                    _aware_datetime(post.created_at),
                ),
            )

    def list_comments(self) -> list[SocialComment]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT payload FROM social_comments ORDER BY created_at DESC"
            ).fetchall()
        return [
            SocialComment.model_validate(_payload_dict(row["payload"]))
            for row in rows
        ]

    def get_comment(self, comment_id: str) -> SocialComment | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT payload FROM social_comments WHERE id = %s",
                (comment_id,),
            ).fetchone()
        if row is None:
            return None
        return SocialComment.model_validate(_payload_dict(row["payload"]))

    def save_comment(self, comment: SocialComment) -> None:
        payload = comment.model_dump(mode="json")
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO social_comments (id, post_id, user_id, payload, created_at)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (id) DO UPDATE
                SET post_id = EXCLUDED.post_id,
                    user_id = EXCLUDED.user_id,
                    payload = EXCLUDED.payload,
                    created_at = EXCLUDED.created_at,
                    updated_at = NOW()
                """,
                (
                    comment.id,
                    comment.post_id,
                    comment.user_id,
                    self._jsonb(payload),
                    _aware_datetime(comment.created_at),
                ),
            )

    def delete_comment_tree(self, comment_id: str) -> None:
        comment_ids = self._comment_tree_ids(comment_id)
        if not comment_ids:
            return
        with self._connect() as connection:
            for item_id in comment_ids:
                connection.execute(
                    "DELETE FROM social_comment_likes WHERE comment_id = %s",
                    (item_id,),
                )
                connection.execute(
                    "DELETE FROM social_comments WHERE id = %s",
                    (item_id,),
                )

    def set_post_like(self, user_id: str, post_id: str, liked: bool) -> None:
        with self._connect() as connection:
            if liked:
                connection.execute(
                    """
                    INSERT INTO social_post_likes (user_id, post_id)
                    VALUES (%s, %s)
                    ON CONFLICT (user_id, post_id) DO NOTHING
                    """,
                    (user_id, post_id),
                )
            else:
                connection.execute(
                    """
                    DELETE FROM social_post_likes
                    WHERE user_id = %s AND post_id = %s
                    """,
                    (user_id, post_id),
                )

    def set_comment_like(self, user_id: str, comment_id: str, liked: bool) -> None:
        with self._connect() as connection:
            if liked:
                connection.execute(
                    """
                    INSERT INTO social_comment_likes (user_id, comment_id)
                    VALUES (%s, %s)
                    ON CONFLICT (user_id, comment_id) DO NOTHING
                    """,
                    (user_id, comment_id),
                )
            else:
                connection.execute(
                    """
                    DELETE FROM social_comment_likes
                    WHERE user_id = %s AND comment_id = %s
                    """,
                    (user_id, comment_id),
                )

    def set_repost(
        self,
        user_id: str,
        post_id: str,
        reposted: bool,
        created_at: datetime | None = None,
    ) -> None:
        with self._connect() as connection:
            if reposted:
                connection.execute(
                    """
                    INSERT INTO social_reposts (user_id, post_id, created_at)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (user_id, post_id) DO UPDATE
                    SET created_at = EXCLUDED.created_at
                    """,
                    (user_id, post_id, _aware_datetime(created_at)),
                )
            else:
                connection.execute(
                    """
                    DELETE FROM social_reposts
                    WHERE user_id = %s AND post_id = %s
                    """,
                    (user_id, post_id),
                )

    def set_rsvp(self, user_id: str, post_id: str, joined: bool) -> None:
        with self._connect() as connection:
            if joined:
                connection.execute(
                    """
                    INSERT INTO social_rsvps (user_id, post_id)
                    VALUES (%s, %s)
                    ON CONFLICT (user_id, post_id) DO NOTHING
                    """,
                    (user_id, post_id),
                )
            else:
                connection.execute(
                    """
                    DELETE FROM social_rsvps
                    WHERE user_id = %s AND post_id = %s
                    """,
                    (user_id, post_id),
                )

    def set_follow(self, follower_user_id: str, followed_user_id: str, following: bool) -> None:
        if follower_user_id == followed_user_id:
            return
        with self._connect() as connection:
            if following:
                connection.execute(
                    """
                    INSERT INTO social_follows (follower_user_id, followed_user_id)
                    VALUES (%s, %s)
                    ON CONFLICT (follower_user_id, followed_user_id) DO NOTHING
                    """,
                    (follower_user_id, followed_user_id),
                )
            else:
                connection.execute(
                    """
                    DELETE FROM social_follows
                    WHERE follower_user_id = %s AND followed_user_id = %s
                    """,
                    (follower_user_id, followed_user_id),
                )

    def remove_follower(self, user_id: str, follower_user_id: str) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                DELETE FROM social_follows
                WHERE follower_user_id = %s AND followed_user_id = %s
                """,
                (follower_user_id, user_id),
            )

    def relationship_state(self, user_id: str) -> dict[str, list[str]]:
        with self._connect() as connection:
            following_rows = connection.execute(
                """
                SELECT followed_user_id FROM social_follows
                WHERE follower_user_id = %s
                ORDER BY followed_user_id
                """,
                (user_id,),
            ).fetchall()
            follower_rows = connection.execute(
                """
                SELECT follower_user_id FROM social_follows
                WHERE followed_user_id = %s
                ORDER BY follower_user_id
                """,
                (user_id,),
            ).fetchall()
        return {
            "followed_user_ids": [
                row["followed_user_id"]
                for row in following_rows
            ],
            "follower_user_ids": [
                row["follower_user_id"]
                for row in follower_rows
            ],
        }

    def engagement_state(self, user_id: str) -> SocialEngagementState:
        with self._connect() as connection:
            liked_posts = connection.execute(
                """
                SELECT post_id FROM social_post_likes
                WHERE user_id = %s
                ORDER BY post_id
                """,
                (user_id,),
            ).fetchall()
            repost_rows = connection.execute(
                """
                SELECT post_id, created_at FROM social_reposts
                WHERE user_id = %s
                ORDER BY created_at DESC
                """,
                (user_id,),
            ).fetchall()
            liked_comments = connection.execute(
                """
                SELECT comment_id FROM social_comment_likes
                WHERE user_id = %s
                ORDER BY comment_id
                """,
                (user_id,),
            ).fetchall()
            rsvp_rows = connection.execute(
                """
                SELECT post_id FROM social_rsvps
                WHERE user_id = %s
                ORDER BY post_id
                """,
                (user_id,),
            ).fetchall()
        reposts = [
            SocialRepost(
                post_id=row["post_id"],
                created_at=_aware_datetime(row["created_at"]),
            )
            for row in repost_rows
        ]
        return SocialEngagementState(
            liked_post_ids=[row["post_id"] for row in liked_posts],
            reposted_post_ids=[repost.post_id for repost in reposts],
            reposts=reposts,
            liked_comment_ids=[row["comment_id"] for row in liked_comments],
            rsvp_post_ids=[row["post_id"] for row in rsvp_rows],
            comments=self.list_comments(),
        )

    def update_author_snapshots(self, user: User) -> None:
        for post in self._posts_by_user(user.id):
            post.author_name = user.display_name
            post.author_handle = user.handle
            post.author_avatar_url = user.avatar_url
            post.author_premium = user.premium
            self.save_post(post)
        for comment in self._comments_by_user(user.id):
            comment.author_name = user.display_name
            comment.author_handle = user.handle
            comment.author_avatar_url = user.avatar_url
            comment.author_premium = user.premium
            self.save_comment(comment)

    def delete_user_social(self, user_id: str) -> None:
        for comment in self._comments_by_user(user_id):
            self.delete_comment_tree(comment.id)
        with self._connect() as connection:
            post_rows = connection.execute(
                "SELECT id FROM social_posts WHERE user_id = %s",
                (user_id,),
            ).fetchall()
        for row in post_rows:
            self.delete_post(row["id"])
        with self._connect() as connection:
            for table in (
                "social_post_likes",
                "social_comment_likes",
                "social_reposts",
                "social_rsvps",
            ):
                connection.execute(
                    f"DELETE FROM {table} WHERE user_id = %s",
                    (user_id,),
                )
            connection.execute(
                "DELETE FROM social_follows WHERE follower_user_id = %s OR followed_user_id = %s",
                (user_id, user_id),
            )

    def delete_post(self, post_id: str) -> None:
        with self._connect() as connection:
            comment_rows = connection.execute(
                "SELECT id FROM social_comments WHERE post_id = %s",
                (post_id,),
            ).fetchall()
        for row in comment_rows:
            self.delete_comment_tree(row["id"])
        with self._connect() as connection:
            for table in ("social_post_likes", "social_reposts", "social_rsvps"):
                connection.execute(
                    f"DELETE FROM {table} WHERE post_id = %s",
                    (post_id,),
                )
            connection.execute("DELETE FROM social_posts WHERE id = %s", (post_id,))

    def _posts_by_user(self, user_id: str) -> list[SocialPost]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT payload FROM social_posts WHERE user_id = %s",
                (user_id,),
            ).fetchall()
        return [
            SocialPost.model_validate(_payload_dict(row["payload"]))
            for row in rows
        ]

    def _comments_by_user(self, user_id: str) -> list[SocialComment]:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT payload FROM social_comments WHERE user_id = %s",
                (user_id,),
            ).fetchall()
        return [
            SocialComment.model_validate(_payload_dict(row["payload"]))
            for row in rows
        ]

    def _comment_tree_ids(self, comment_id: str) -> list[str]:
        ordered: list[str] = []
        pending = [comment_id]
        seen: set[str] = set()
        while pending:
            current_id = pending.pop(0)
            if current_id in seen:
                continue
            seen.add(current_id)
            ordered.append(current_id)
            with self._connect() as connection:
                rows = connection.execute(
                    """
                    SELECT id FROM social_comments
                    WHERE payload->>'reply_to_comment_id' = %s
                    """,
                    (current_id,),
                ).fetchall()
            pending.extend(row["id"] for row in rows if row["id"] not in seen)
        return list(reversed(ordered))

    def _connect(self):
        import psycopg
        from psycopg.rows import dict_row

        return psycopg.connect(
            self.database_url,
            autocommit=True,
            row_factory=dict_row,
        )

    def _jsonb(self, value: dict[str, Any]):
        from psycopg.types.json import Jsonb

        return Jsonb(value)

    def _ensure_schema(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS social_posts (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    payload JSONB NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS social_posts_created_at_idx ON social_posts (created_at DESC)"
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS social_posts_user_id_idx ON social_posts (user_id)"
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS social_comments (
                    id TEXT PRIMARY KEY,
                    post_id TEXT NOT NULL,
                    user_id TEXT NOT NULL,
                    payload JSONB NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS social_comments_post_id_idx ON social_comments (post_id)"
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS social_comments_user_id_idx ON social_comments (user_id)"
            )
            self._create_user_post_table(connection, "social_post_likes")
            self._create_user_post_table(connection, "social_reposts")
            self._create_user_post_table(connection, "social_rsvps")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS social_comment_likes (
                    user_id TEXT NOT NULL,
                    comment_id TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    PRIMARY KEY (user_id, comment_id)
                )
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS social_comment_likes_comment_id_idx ON social_comment_likes (comment_id)"
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS social_follows (
                    follower_user_id TEXT NOT NULL,
                    followed_user_id TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    PRIMARY KEY (follower_user_id, followed_user_id)
                )
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS social_follows_followed_idx ON social_follows (followed_user_id)"
            )

    def _create_user_post_table(self, connection, table: str) -> None:
        connection.execute(
            f"""
            CREATE TABLE IF NOT EXISTS {table} (
                user_id TEXT NOT NULL,
                post_id TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (user_id, post_id)
            )
            """
        )
        connection.execute(
            f"CREATE INDEX IF NOT EXISTS {table}_post_id_idx ON {table} (post_id)"
        )


def _payload_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    return {}


def _aware_datetime(value: datetime | None) -> datetime:
    if value is None:
        return datetime.now(timezone.utc)
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value
