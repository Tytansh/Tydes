from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
import logging
import os
from threading import RLock
import time
from typing import Any


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class CachedJson:
    payload: dict[str, Any]
    updated_at: datetime


class PostgresJsonCache:
    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._cleanup_lock = RLock()
        self._last_cleanup = 0.0
        self._ensure_schema()

    @classmethod
    def from_env(cls) -> "PostgresJsonCache | None":
        database_url = os.getenv("DATABASE_URL", "").strip()
        if not database_url:
            return None
        try:
            return cls(database_url)
        except Exception:
            logger.exception(
                "Could not initialize persistent provider cache; using memory cache"
            )
            return None

    def get(self, cache_key: str, max_age: timedelta) -> CachedJson | None:
        cutoff = datetime.now(UTC) - max_age
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT payload, updated_at
                FROM api_json_cache
                WHERE cache_key = %s AND updated_at >= %s
                """,
                (cache_key, cutoff),
            ).fetchone()
        if row is None:
            return None
        return CachedJson(
            payload=dict(row["payload"]),
            updated_at=_aware(row["updated_at"]),
        )

    def set(self, cache_key: str, payload: dict[str, Any]) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO api_json_cache (cache_key, payload, updated_at)
                VALUES (%s, %s, NOW())
                ON CONFLICT (cache_key) DO UPDATE
                SET payload = EXCLUDED.payload, updated_at = NOW()
                """,
                (cache_key, self._jsonb(payload)),
            )
        self._cleanup_if_due()

    def delete_older_than(self, max_age: timedelta) -> int:
        cutoff = datetime.now(UTC) - max_age
        with self._connect() as connection:
            result = connection.execute(
                "DELETE FROM api_json_cache WHERE updated_at < %s",
                (cutoff,),
            )
        return result.rowcount

    def _connect(self):
        import psycopg
        from psycopg.rows import dict_row

        return psycopg.connect(
            self.database_url,
            autocommit=False,
            row_factory=dict_row,
        )

    def _cleanup_if_due(self) -> None:
        now = time.monotonic()
        with self._cleanup_lock:
            if now - self._last_cleanup < 24 * 60 * 60:
                return
            self._last_cleanup = now
        self.delete_older_than(timedelta(days=45))

    def _jsonb(self, payload: dict[str, Any]):
        from psycopg.types.json import Jsonb

        return Jsonb(payload)

    def _ensure_schema(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS api_json_cache (
                    cache_key TEXT PRIMARY KEY,
                    payload JSONB NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS api_json_cache_updated_idx
                ON api_json_cache (updated_at)
                """
            )


def _aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value
