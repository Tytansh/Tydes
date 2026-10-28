from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
import hashlib
import logging
import math
import os
from threading import RLock
import time

from fastapi import HTTPException, Request

from app.core.models import User


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RateLimitRule:
    scope: str
    key: str
    limit: int
    window_seconds: int


class SlidingWindowRateLimiter:
    _MAX_BUCKETS = 50_000

    def __init__(self, database_url: str | None = None) -> None:
        self.database_url = (database_url or "").strip() or None
        self._events: dict[tuple[str, str], deque[float]] = {}
        self._last_seen: dict[tuple[str, str], float] = {}
        self._lock = RLock()
        self._last_database_cleanup = 0.0
        self._schema_ready = False
        if self.database_url is not None:
            self._try_ensure_schema()

    def enforce(self, *rules: RateLimitRule) -> None:
        normalized_rules = [rule for rule in rules if rule.limit > 0]
        if self.database_url is not None:
            try:
                if not self._schema_ready:
                    self._ensure_schema()
                    self._schema_ready = True
                self._enforce_postgres(normalized_rules)
                return
            except HTTPException:
                raise
            except Exception:
                logger.exception(
                    "Persistent rate limiting unavailable; using process-local limits"
                )
        self._enforce_memory(normalized_rules)

    def _enforce_memory(self, normalized_rules: list[RateLimitRule]) -> None:
        now = time.monotonic()
        with self._lock:
            retry_after = 0
            for rule in normalized_rules:
                bucket_key = (rule.scope, _digest(rule.key))
                events = self._events.get(bucket_key)
                if events is None:
                    continue
                cutoff = now - rule.window_seconds
                while events and events[0] <= cutoff:
                    events.popleft()
                if len(events) >= rule.limit:
                    retry_after = max(
                        retry_after,
                        math.ceil(events[0] + rule.window_seconds - now),
                    )
            if retry_after > 0:
                raise HTTPException(
                    status_code=429,
                    detail="Too many requests. Please try again later.",
                    headers={"Retry-After": str(retry_after)},
                )
            for rule in normalized_rules:
                bucket_key = (rule.scope, _digest(rule.key))
                self._events.setdefault(bucket_key, deque()).append(now)
                self._last_seen[bucket_key] = now
            self._trim_oldest_buckets()

    def clear(self, *, persistent: bool = False) -> None:
        if persistent and self.database_url is not None:
            with self._connect() as connection:
                connection.execute("DELETE FROM api_rate_limit_buckets")
        with self._lock:
            self._events.clear()
            self._last_seen.clear()

    def _trim_oldest_buckets(self) -> None:
        if len(self._events) <= self._MAX_BUCKETS:
            return
        buckets_to_remove = len(self._events) - (self._MAX_BUCKETS // 2)
        oldest_buckets = sorted(
            self._last_seen,
            key=self._last_seen.__getitem__,
        )[:buckets_to_remove]
        for bucket_key in oldest_buckets:
            self._events.pop(bucket_key, None)
            self._last_seen.pop(bucket_key, None)

    def _enforce_postgres(self, rules: list[RateLimitRule]) -> None:
        if not rules:
            return
        now = datetime.now(UTC)
        locked_rows: list[tuple[RateLimitRule, str, datetime, int]] = []
        with self._connect() as connection:
            with connection.transaction():
                for rule in rules:
                    key_hash = _digest(rule.key)
                    connection.execute(
                        """
                        INSERT INTO api_rate_limit_buckets (
                            scope, key_hash, window_seconds,
                            window_started_at, request_count, updated_at
                        ) VALUES (%s, %s, %s, %s, 0, %s)
                        ON CONFLICT (scope, key_hash) DO NOTHING
                        """,
                        (
                            rule.scope,
                            key_hash,
                            rule.window_seconds,
                            now,
                            now,
                        ),
                    )
                    row = connection.execute(
                        """
                        SELECT window_seconds, window_started_at, request_count
                        FROM api_rate_limit_buckets
                        WHERE scope = %s AND key_hash = %s
                        FOR UPDATE
                        """,
                        (rule.scope, key_hash),
                    ).fetchone()
                    window_started_at = _aware(row["window_started_at"])
                    request_count = int(row["request_count"])
                    if (
                        int(row["window_seconds"]) != rule.window_seconds
                        or now - window_started_at
                        >= timedelta(seconds=rule.window_seconds)
                    ):
                        window_started_at = now
                        request_count = 0
                    locked_rows.append(
                        (rule, key_hash, window_started_at, request_count)
                    )

                retry_after = max(
                    (
                        math.ceil(
                            (
                                window_started_at
                                + timedelta(seconds=rule.window_seconds)
                                - now
                            ).total_seconds()
                        )
                        for rule, _, window_started_at, request_count in locked_rows
                        if request_count >= rule.limit
                    ),
                    default=0,
                )
                if retry_after > 0:
                    raise HTTPException(
                        status_code=429,
                        detail="Too many requests. Please try again later.",
                        headers={"Retry-After": str(retry_after)},
                    )

                for rule, key_hash, window_started_at, request_count in locked_rows:
                    connection.execute(
                        """
                        UPDATE api_rate_limit_buckets
                        SET window_seconds = %s,
                            window_started_at = %s,
                            request_count = %s,
                            updated_at = %s
                        WHERE scope = %s AND key_hash = %s
                        """,
                        (
                            rule.window_seconds,
                            window_started_at,
                            request_count + 1,
                            now,
                            rule.scope,
                            key_hash,
                        ),
                    )
        try:
            self._cleanup_database_if_due()
        except Exception:
            logger.exception("Could not clean old persistent rate-limit buckets")

    def _cleanup_database_if_due(self) -> None:
        now = time.monotonic()
        with self._lock:
            if now - self._last_database_cleanup < 60 * 60:
                return
            self._last_database_cleanup = now
        cutoff = datetime.now(UTC) - timedelta(days=2)
        with self._connect() as connection:
            connection.execute(
                "DELETE FROM api_rate_limit_buckets WHERE updated_at < %s",
                (cutoff,),
            )

    def _connect(self):
        import psycopg
        from psycopg.rows import dict_row

        return psycopg.connect(
            self.database_url,
            autocommit=False,
            row_factory=dict_row,
        )

    def _ensure_schema(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS api_rate_limit_buckets (
                    scope TEXT NOT NULL,
                    key_hash TEXT NOT NULL,
                    window_seconds INTEGER NOT NULL,
                    window_started_at TIMESTAMPTZ NOT NULL,
                    request_count INTEGER NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    PRIMARY KEY (scope, key_hash)
                )
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS api_rate_limit_updated_idx
                ON api_rate_limit_buckets (updated_at)
                """
            )

    def _try_ensure_schema(self) -> None:
        try:
            self._ensure_schema()
            self._schema_ready = True
        except Exception:
            logger.exception(
                "Could not initialize persistent rate limits; "
                "requests will use process-local limits until the database recovers"
            )


def client_rate_limit_key(request: Request) -> str:
    forwarded_for = request.headers.get("x-forwarded-for", "")
    if forwarded_for:
        return forwarded_for.rsplit(",", 1)[-1].strip()
    if request.client is not None:
        return request.client.host
    return "unknown-client"


def account_or_client_rate_limit_key(request: Request) -> str:
    user = getattr(request.state, "user", None)
    if isinstance(user, User):
        return f"user:{user.id}"
    return f"client:{client_rate_limit_key(request)}"


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value


api_rate_limiter = SlidingWindowRateLimiter(os.getenv("DATABASE_URL"))
