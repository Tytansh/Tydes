from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
import os
from threading import Lock


class UploadQuotaExceeded(ValueError):
    pass


@dataclass(frozen=True)
class UploadLimits:
    uploads_per_minute: int
    videos_per_user_day: int
    media_per_user_day: int
    user_bytes_per_day: int
    global_bytes_per_day: int
    global_uploads_per_day: int
    global_retained_bytes: int

    @classmethod
    def from_env(cls) -> "UploadLimits":
        return cls(
            uploads_per_minute=_positive_env("MEDIA_UPLOADS_PER_MINUTE", 4),
            videos_per_user_day=_positive_env("MEDIA_VIDEOS_PER_USER_DAY", 10),
            media_per_user_day=_positive_env("MEDIA_UPLOADS_PER_USER_DAY", 40),
            user_bytes_per_day=_positive_env(
                "MEDIA_USER_BYTES_PER_DAY", 700 * 1024 * 1024
            ),
            global_bytes_per_day=_positive_env(
                "MEDIA_GLOBAL_BYTES_PER_DAY", 2 * 1024 * 1024 * 1024
            ),
            global_uploads_per_day=_positive_env(
                "MEDIA_GLOBAL_UPLOADS_PER_DAY", 2_000
            ),
            global_retained_bytes=_positive_env(
                "MEDIA_GLOBAL_RETAINED_BYTES", 50 * 1024 * 1024 * 1024
            ),
        )


@dataclass(frozen=True)
class UploadReservation:
    id: str
    user_id: str
    client_ip_hash: str
    media_type: str
    content_type: str
    thumbnail_content_type: str | None
    expected_bytes: int
    expected_thumbnail_bytes: int
    pending_name: str
    final_name: str
    pending_thumbnail_name: str | None
    final_thumbnail_name: str | None
    public_url: str
    thumbnail_public_url: str
    status: str
    created_at: datetime
    expires_at: datetime

    @property
    def total_bytes(self) -> int:
        return self.expected_bytes + self.expected_thumbnail_bytes


class MediaUploadLedger:
    def __init__(self, database_url: str | None = None) -> None:
        self.database_url = (database_url or "").strip() or None
        self._memory: dict[str, UploadReservation] = {}
        self._lock = Lock()
        if self.database_url is not None:
            self._ensure_schema()

    @classmethod
    def from_env(cls) -> "MediaUploadLedger":
        return cls(os.getenv("DATABASE_URL"))

    def reserve(
        self,
        reservation: UploadReservation,
        limits: UploadLimits,
    ) -> UploadReservation:
        if self.database_url is not None:
            return self._reserve_postgres(reservation, limits)
        return self._reserve_memory(reservation, limits)

    def get(self, reservation_id: str, user_id: str) -> UploadReservation | None:
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute(
                    """
                    SELECT * FROM media_upload_reservations
                    WHERE id = %s AND user_id = %s
                    """,
                    (reservation_id, user_id),
                ).fetchone()
            return _reservation_from_row(row) if row is not None else None
        with self._lock:
            reservation = self._memory.get(reservation_id)
            if reservation is None or reservation.user_id != user_id:
                return None
            return reservation

    def set_status(
        self,
        reservation_id: str,
        user_id: str,
        status: str,
    ) -> UploadReservation | None:
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute(
                    """
                    UPDATE media_upload_reservations
                    SET status = %s, updated_at = NOW()
                    WHERE id = %s AND user_id = %s
                    RETURNING *
                    """,
                    (status, reservation_id, user_id),
                ).fetchone()
            return _reservation_from_row(row) if row is not None else None
        with self._lock:
            reservation = self._memory.get(reservation_id)
            if reservation is None or reservation.user_id != user_id:
                return None
            updated = replace(reservation, status=status)
            self._memory[reservation_id] = updated
            return updated

    def assert_completed_media(
        self,
        user_id: str,
        attachments: list[tuple[str, str, str, str]],
    ) -> None:
        for media_id, media_type, url, thumbnail_url in attachments:
            reservation = self.get(media_id, user_id)
            if reservation is None or reservation.status not in {"complete", "used"}:
                raise ValueError("Upload is missing or has not finished.")
            if (
                reservation.media_type != media_type
                or reservation.public_url != url
                or reservation.thumbnail_public_url != thumbnail_url
            ):
                raise ValueError("Upload details do not match the reserved media.")

    def mark_used(self, user_id: str, media_ids: list[str]) -> None:
        for media_id in media_ids:
            self.set_status(media_id, user_id, "used")

    def expired_pending(self, limit: int = 20) -> list[UploadReservation]:
        now = datetime.now(timezone.utc)
        if self.database_url is not None:
            with self._connect() as connection:
                rows = connection.execute(
                    """
                    UPDATE media_upload_reservations
                    SET status = 'expired', updated_at = NOW()
                    WHERE id IN (
                        SELECT id FROM media_upload_reservations
                        WHERE status = 'pending' AND expires_at < %s
                        ORDER BY expires_at ASC
                        LIMIT %s
                    )
                    RETURNING *
                    """,
                    (now, limit),
                ).fetchall()
            return [_reservation_from_row(row) for row in rows]
        expired: list[UploadReservation] = []
        with self._lock:
            for reservation_id, reservation in list(self._memory.items()):
                if len(expired) >= limit:
                    break
                if reservation.status == "pending" and reservation.expires_at < now:
                    updated = replace(reservation, status="expired")
                    self._memory[reservation_id] = updated
                    expired.append(updated)
        return expired

    def _reserve_memory(
        self,
        reservation: UploadReservation,
        limits: UploadLimits,
    ) -> UploadReservation:
        now = reservation.created_at
        day_start = datetime(now.year, now.month, now.day, tzinfo=timezone.utc)
        minute_start = now - timedelta(minutes=1)
        with self._lock:
            rows = list(self._memory.values())
            _enforce_limits(
                reservation,
                limits,
                minute_count=sum(
                    1
                    for row in rows
                    if row.created_at >= minute_start
                    and (
                        row.user_id == reservation.user_id
                        or row.client_ip_hash == reservation.client_ip_hash
                    )
                ),
                user_day_count=sum(
                    1
                    for row in rows
                    if row.created_at >= day_start
                    and row.user_id == reservation.user_id
                ),
                user_video_day_count=sum(
                    1
                    for row in rows
                    if row.created_at >= day_start
                    and row.user_id == reservation.user_id
                    and row.media_type == "video"
                ),
                user_day_bytes=sum(
                    row.total_bytes
                    for row in rows
                    if row.created_at >= day_start
                    and row.user_id == reservation.user_id
                ),
                global_day_count=sum(1 for row in rows if row.created_at >= day_start),
                global_day_bytes=sum(
                    row.total_bytes for row in rows if row.created_at >= day_start
                ),
                retained_bytes=sum(
                    row.total_bytes
                    for row in rows
                    if row.status in {"complete", "used"}
                ),
            )
            self._memory[reservation.id] = reservation
        return reservation

    def _reserve_postgres(
        self,
        reservation: UploadReservation,
        limits: UploadLimits,
    ) -> UploadReservation:
        now = reservation.created_at
        day_start = datetime(now.year, now.month, now.day, tzinfo=timezone.utc)
        minute_start = now - timedelta(minutes=1)
        with self._connect() as connection:
            with connection.transaction():
                connection.execute(
                    "SELECT pg_advisory_xact_lock(%s)",
                    (1_982_910_247,),
                )
                minute_count = connection.execute(
                    """
                    SELECT COUNT(*) AS count FROM media_upload_reservations
                    WHERE created_at >= %s AND (user_id = %s OR client_ip_hash = %s)
                    """,
                    (minute_start, reservation.user_id, reservation.client_ip_hash),
                ).fetchone()["count"]
                day_row = connection.execute(
                    """
                    SELECT
                        COUNT(*) FILTER (WHERE user_id = %s) AS user_count,
                        COUNT(*) FILTER (
                            WHERE user_id = %s AND media_type = 'video'
                        ) AS user_video_count,
                        COALESCE(SUM(total_bytes) FILTER (WHERE user_id = %s), 0)
                            AS user_bytes,
                        COUNT(*) AS global_count,
                        COALESCE(SUM(total_bytes), 0) AS global_bytes
                    FROM media_upload_reservations
                    WHERE created_at >= %s
                    """,
                    (
                        reservation.user_id,
                        reservation.user_id,
                        reservation.user_id,
                        day_start,
                    ),
                ).fetchone()
                retained_bytes = connection.execute(
                    """
                    SELECT COALESCE(SUM(total_bytes), 0) AS bytes
                    FROM media_upload_reservations
                    WHERE status IN ('complete', 'used')
                    """
                ).fetchone()["bytes"]
                _enforce_limits(
                    reservation,
                    limits,
                    minute_count=int(minute_count),
                    user_day_count=int(day_row["user_count"]),
                    user_video_day_count=int(day_row["user_video_count"]),
                    user_day_bytes=int(day_row["user_bytes"]),
                    global_day_count=int(day_row["global_count"]),
                    global_day_bytes=int(day_row["global_bytes"]),
                    retained_bytes=int(retained_bytes),
                )
                connection.execute(
                    """
                    INSERT INTO media_upload_reservations (
                        id, user_id, client_ip_hash, media_type, content_type,
                        thumbnail_content_type, expected_bytes,
                        expected_thumbnail_bytes, total_bytes, pending_name,
                        final_name, pending_thumbnail_name, final_thumbnail_name,
                        public_url, thumbnail_public_url, status, created_at,
                        expires_at
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s
                    )
                    """,
                    (
                        reservation.id,
                        reservation.user_id,
                        reservation.client_ip_hash,
                        reservation.media_type,
                        reservation.content_type,
                        reservation.thumbnail_content_type,
                        reservation.expected_bytes,
                        reservation.expected_thumbnail_bytes,
                        reservation.total_bytes,
                        reservation.pending_name,
                        reservation.final_name,
                        reservation.pending_thumbnail_name,
                        reservation.final_thumbnail_name,
                        reservation.public_url,
                        reservation.thumbnail_public_url,
                        reservation.status,
                        reservation.created_at,
                        reservation.expires_at,
                    ),
                )
        return reservation

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
                CREATE TABLE IF NOT EXISTS media_upload_reservations (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    client_ip_hash TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    content_type TEXT NOT NULL,
                    thumbnail_content_type TEXT,
                    expected_bytes BIGINT NOT NULL,
                    expected_thumbnail_bytes BIGINT NOT NULL DEFAULT 0,
                    total_bytes BIGINT NOT NULL,
                    pending_name TEXT NOT NULL,
                    final_name TEXT NOT NULL,
                    pending_thumbnail_name TEXT,
                    final_thumbnail_name TEXT,
                    public_url TEXT NOT NULL,
                    thumbnail_public_url TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL,
                    expires_at TIMESTAMPTZ NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS media_upload_user_created_idx
                ON media_upload_reservations (user_id, created_at DESC)
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS media_upload_ip_created_idx
                ON media_upload_reservations (client_ip_hash, created_at DESC)
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS media_upload_status_idx
                ON media_upload_reservations (status, expires_at)
                """
            )


def _enforce_limits(
    reservation: UploadReservation,
    limits: UploadLimits,
    *,
    minute_count: int,
    user_day_count: int,
    user_video_day_count: int,
    user_day_bytes: int,
    global_day_count: int,
    global_day_bytes: int,
    retained_bytes: int,
) -> None:
    if minute_count >= limits.uploads_per_minute:
        raise UploadQuotaExceeded("Too many uploads. Wait a minute and try again.")
    if user_day_count >= limits.media_per_user_day:
        raise UploadQuotaExceeded("You reached today's media upload limit.")
    if (
        reservation.media_type == "video"
        and user_video_day_count >= limits.videos_per_user_day
    ):
        raise UploadQuotaExceeded("You reached today's video upload limit.")
    if user_day_bytes + reservation.total_bytes > limits.user_bytes_per_day:
        raise UploadQuotaExceeded("You reached today's upload size limit.")
    if global_day_count >= limits.global_uploads_per_day:
        raise UploadQuotaExceeded("Uploads are paused for today. Try again tomorrow.")
    if global_day_bytes + reservation.total_bytes > limits.global_bytes_per_day:
        raise UploadQuotaExceeded("Uploads are paused for today. Try again tomorrow.")
    if retained_bytes + reservation.total_bytes > limits.global_retained_bytes:
        raise UploadQuotaExceeded("Uploads are temporarily paused while storage is reviewed.")


def _reservation_from_row(row) -> UploadReservation:
    return UploadReservation(
        id=str(row["id"]),
        user_id=str(row["user_id"]),
        client_ip_hash=str(row["client_ip_hash"]),
        media_type=str(row["media_type"]),
        content_type=str(row["content_type"]),
        thumbnail_content_type=(
            str(row["thumbnail_content_type"])
            if row["thumbnail_content_type"] is not None
            else None
        ),
        expected_bytes=int(row["expected_bytes"]),
        expected_thumbnail_bytes=int(row["expected_thumbnail_bytes"]),
        pending_name=str(row["pending_name"]),
        final_name=str(row["final_name"]),
        pending_thumbnail_name=(
            str(row["pending_thumbnail_name"])
            if row["pending_thumbnail_name"] is not None
            else None
        ),
        final_thumbnail_name=(
            str(row["final_thumbnail_name"])
            if row["final_thumbnail_name"] is not None
            else None
        ),
        public_url=str(row["public_url"]),
        thumbnail_public_url=str(row["thumbnail_public_url"]),
        status=str(row["status"]),
        created_at=_aware(row["created_at"]),
        expires_at=_aware(row["expires_at"]),
    )


def _aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


def _positive_env(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


upload_ledger = MediaUploadLedger.from_env()
