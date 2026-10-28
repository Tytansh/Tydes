from __future__ import annotations

import os
from typing import Any

from app.core.models import Alert, Trip


class PostgresPlanningRepository:
    """Persist private trip plans and surf alerts by owning account."""

    _BOOTSTRAP_KEY = "planning-state-v1"

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_schema()

    @classmethod
    def from_env(cls) -> "PostgresPlanningRepository | None":
        database_url = os.getenv("DATABASE_URL", "").strip()
        if not database_url:
            return None
        return cls(database_url)

    def bootstrap_from_state(
        self,
        *,
        trips: list[Trip],
        alerts: list[Alert],
    ) -> None:
        with self._connect() as connection:
            migrated = connection.execute(
                "SELECT 1 FROM planning_migrations WHERE migration_key = %s",
                (self._BOOTSTRAP_KEY,),
            ).fetchone()
            if migrated is not None:
                return

            for trip in trips:
                connection.execute(
                    """
                    INSERT INTO planning_trips (id, user_id, payload)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (id) DO NOTHING
                    """,
                    (trip.id, trip.user_id, self._jsonb(trip.model_dump(mode="json"))),
                )
            for alert in alerts:
                connection.execute(
                    """
                    INSERT INTO planning_alerts (id, user_id, payload)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (id) DO NOTHING
                    """,
                    (
                        alert.id,
                        alert.user_id,
                        self._jsonb(alert.model_dump(mode="json")),
                    ),
                )
            connection.execute(
                """
                INSERT INTO planning_migrations (migration_key)
                VALUES (%s)
                ON CONFLICT (migration_key) DO NOTHING
                """,
                (self._BOOTSTRAP_KEY,),
            )

    def list_trips(self, user_id: str) -> list[Trip]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT payload FROM planning_trips
                WHERE user_id = %s
                ORDER BY payload->>'start_date', created_at
                """,
                (user_id,),
            ).fetchall()
        return [Trip.model_validate(_payload_dict(row["payload"])) for row in rows]

    def save_trip(self, trip: Trip) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO planning_trips (id, user_id, payload)
                VALUES (%s, %s, %s)
                ON CONFLICT (id) DO UPDATE
                SET user_id = EXCLUDED.user_id,
                    payload = EXCLUDED.payload,
                    updated_at = NOW()
                WHERE planning_trips.user_id = EXCLUDED.user_id
                """,
                (trip.id, trip.user_id, self._jsonb(trip.model_dump(mode="json"))),
            )

    def list_alerts(self, user_id: str) -> list[Alert]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT payload FROM planning_alerts
                WHERE user_id = %s
                ORDER BY created_at, id
                """,
                (user_id,),
            ).fetchall()
        return [Alert.model_validate(_payload_dict(row["payload"])) for row in rows]

    def get_alert(self, alert_id: str, user_id: str) -> Alert | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT payload FROM planning_alerts
                WHERE id = %s AND user_id = %s
                """,
                (alert_id, user_id),
            ).fetchone()
        if row is None:
            return None
        return Alert.model_validate(_payload_dict(row["payload"]))

    def save_alert(self, alert: Alert) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO planning_alerts (id, user_id, payload)
                VALUES (%s, %s, %s)
                ON CONFLICT (id) DO UPDATE
                SET user_id = EXCLUDED.user_id,
                    payload = EXCLUDED.payload,
                    updated_at = NOW()
                WHERE planning_alerts.user_id = EXCLUDED.user_id
                """,
                (
                    alert.id,
                    alert.user_id,
                    self._jsonb(alert.model_dump(mode="json")),
                ),
            )

    def delete_alert(self, alert_id: str, user_id: str) -> bool:
        with self._connect() as connection:
            result = connection.execute(
                "DELETE FROM planning_alerts WHERE id = %s AND user_id = %s",
                (alert_id, user_id),
            )
        return result.rowcount > 0

    def delete_user_data(self, user_id: str) -> None:
        with self._connect() as connection:
            connection.execute(
                "DELETE FROM planning_trips WHERE user_id = %s",
                (user_id,),
            )
            connection.execute(
                "DELETE FROM planning_alerts WHERE user_id = %s",
                (user_id,),
            )

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
                CREATE TABLE IF NOT EXISTS planning_trips (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    payload JSONB NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS planning_trips_user_idx
                ON planning_trips (user_id)
                """
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS planning_alerts (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    payload JSONB NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS planning_alerts_user_idx
                ON planning_alerts (user_id)
                """
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS planning_migrations (
                    migration_key TEXT PRIMARY KEY,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )


def _payload_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    return {}
