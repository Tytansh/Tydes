from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import hashlib
import math
from threading import RLock
import time

from fastapi import HTTPException, Request

from app.core.models import User


@dataclass(frozen=True)
class RateLimitRule:
    scope: str
    key: str
    limit: int
    window_seconds: int


class SlidingWindowRateLimiter:
    _MAX_BUCKETS = 50_000

    def __init__(self) -> None:
        self._events: dict[tuple[str, str], deque[float]] = {}
        self._last_seen: dict[tuple[str, str], float] = {}
        self._lock = RLock()

    def enforce(self, *rules: RateLimitRule) -> None:
        now = time.monotonic()
        normalized_rules = [rule for rule in rules if rule.limit > 0]
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

    def clear(self) -> None:
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


api_rate_limiter = SlidingWindowRateLimiter()
