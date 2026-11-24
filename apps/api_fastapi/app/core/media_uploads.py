from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
import math
import os
import re
from threading import Lock


class UploadQuotaExceeded(ValueError):
    pass


@dataclass(frozen=True)
class UploadLimits:
    uploads_per_minute: int
    videos_per_user_day: int
    media_per_user_day: int
    user_bytes_per_day: int
    user_retained_bytes: int
    global_bytes_per_day: int
    global_uploads_per_day: int
    global_retained_bytes: int

    @classmethod
    def from_env(cls, *, premium: bool = False) -> "UploadLimits":
        return cls(
            uploads_per_minute=_positive_env("MEDIA_UPLOADS_PER_MINUTE", 4),
            videos_per_user_day=_positive_env(
                "MEDIA_PREMIUM_VIDEOS_PER_USER_DAY" if premium
                else "MEDIA_VIDEOS_PER_USER_DAY",
                5 if premium else 2,
            ),
            media_per_user_day=_positive_env("MEDIA_UPLOADS_PER_USER_DAY", 40),
            user_bytes_per_day=_positive_env(
                "MEDIA_USER_BYTES_PER_DAY", 700 * 1024 * 1024
            ),
            user_retained_bytes=_positive_env(
                "MEDIA_USER_RETAINED_BYTES", 2 * 1024 * 1024 * 1024
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
    storage_provider: str = "r2"
    external_id: str | None = None
    purpose: str = "social"
    scope_type: str | None = None
    scope_id: str | None = None
    message_id: str | None = None
    client_message_id: str | None = None
    chat_video_resolutions: str | None = None
    chat_video_mp4_resolution: str | None = None
    chat_source_name: str | None = None
    chat_source_bytes: int = 0
    chat_source_deleted_at: datetime | None = None
    chat_source_read_expires_at: datetime | None = None
    chat_source_etag: str | None = None
    chat_source_duration_seconds: float | None = None
    chat_import_state: str | None = None
    chat_import_started_at: datetime | None = None
    media_width: int | None = None
    media_height: int | None = None

    @property
    def total_bytes(self) -> int:
        return self.expected_bytes + self.expected_thumbnail_bytes + self.chat_source_bytes


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

    def complete_social_bunny_video(
        self, reservation_id: str, user_id: str,
        *, width: int | None, height: int | None,
    ) -> UploadReservation:
        """Persist trusted provider dimensions and completion in one transition."""
        if (width is None) != (height is None) or (
            width is not None and (
                type(width) is not int or type(height) is not int
                or not 0 < width <= 32768 or not 0 < height <= 32768
            )
        ):
            raise ValueError("Video dimensions are invalid.")
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute(
                    """UPDATE media_upload_reservations
                    SET status='complete',media_width=%s,media_height=%s,updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='social'
                        AND media_type='video' AND storage_provider='bunny_stream'
                        AND status='pending' RETURNING *""",
                    (width, height, reservation_id, user_id),
                ).fetchone()
            if row is None:
                raise ValueError("Video upload is no longer active.")
            return _reservation_from_row(row)
        with self._lock:
            row = self._memory.get(reservation_id)
            if (row is None or row.user_id != user_id or row.purpose != "social"
                    or row.media_type != "video" or row.storage_provider != "bunny_stream"
                    or row.status != "pending"):
                raise ValueError("Video upload is no longer active.")
            result = replace(row, status="complete", media_width=width, media_height=height)
            self._memory[reservation_id] = result
            return result

    def set_chat_video_target(self, reservation_id: str, user_id: str,
                              video_id: str, expires_at: datetime) -> UploadReservation:
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("""UPDATE media_upload_reservations
                    SET external_id=%s,pending_name=%s,final_name=%s,expires_at=%s,updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat' AND status='pending'
                    RETURNING *""", (video_id, video_id, video_id, expires_at, reservation_id, user_id)).fetchone()
            if row is None:
                raise ValueError("Upload is no longer active.")
            return _reservation_from_row(row)
        with self._lock:
            row = self._memory.get(reservation_id)
            if row is None or row.user_id != user_id or row.purpose != "chat" or row.status != "pending":
                raise ValueError("Upload is no longer active.")
            result = replace(row, external_id=video_id, pending_name=video_id,
                             final_name=video_id, expires_at=expires_at)
            self._memory[row.id] = result
            return result

    def get_chat(self, identifier: str) -> UploadReservation | None:
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("SELECT * FROM media_upload_reservations WHERE id=%s AND purpose='chat'", (identifier,)).fetchone()
            return _reservation_from_row(row) if row is not None else None
        with self._lock:
            row = self._memory.get(identifier)
            return row if row is not None and row.purpose == "chat" else None

    def complete_chat_media(self, identifier: str, user_id: str) -> None:
        self._transition_chat(identifier, user_id, "complete", {"pending"})

    def begin_chat_video_fetch(self, identifier: str, user_id: str, *,
                               etag: str, duration_seconds: float,
                               read_expires_at: datetime) -> bool:
        """Commit the sole fetch intent before external I/O; never reclaim it.

        Validation is read-only/retryable. A crash after this CAS may leave an
        uncertain import, but must never authorize a second provider POST.
        """
        now = datetime.now(timezone.utc)
        if (not isinstance(etag, str) or not etag or len(etag) > 256
                or any(ord(value) < 32 for value in etag)
                or isinstance(duration_seconds, bool)
                or not isinstance(duration_seconds, (int, float))
                or not math.isfinite(duration_seconds) or not 0 < duration_seconds <= 30.5
                or read_expires_at.tzinfo is None or read_expires_at <= now):
            raise ValueError("Validated source metadata is incomplete.")
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("""UPDATE media_upload_reservations
                    SET chat_import_state='fetch_started',chat_import_started_at=clock_timestamp(),
                        chat_source_etag=%s,chat_source_duration_seconds=%s,
                        chat_source_read_expires_at=%s,updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat' AND media_type='video'
                      AND storage_provider='chat_bunny' AND status='pending'
                      AND chat_import_state='staged' AND chat_source_name IS NOT NULL
                      AND chat_source_bytes>0 AND chat_source_deleted_at IS NULL
                      AND expires_at>clock_timestamp() AND %s>clock_timestamp()
                      AND external_id IS NULL RETURNING id""",
                    (etag, duration_seconds, read_expires_at, identifier, user_id, read_expires_at)).fetchone()
                return row is not None
        with self._lock:
            now = datetime.now(timezone.utc)
            row = self._memory.get(identifier)
            if (row is None or row.user_id != user_id or not _staged_video(row)
                    or row.status != "pending" or row.chat_import_state != "staged"
                    or row.chat_source_deleted_at is not None or row.external_id is not None
                    or row.expires_at <= now or read_expires_at <= now):
                return False
            self._memory[identifier] = replace(row, chat_import_state="fetch_started",
                chat_import_started_at=now, chat_source_etag=etag,
                chat_source_duration_seconds=float(duration_seconds),
                chat_source_read_expires_at=read_expires_at)
            return True

    def record_chat_video_fetch_outcome(self, identifier: str, user_id: str, *, accepted: bool) -> None:
        if not isinstance(accepted, bool):
            raise ValueError("The fetch outcome must be explicit.")
        state = "fetch_submitted" if accepted else "fetch_rejected"
        if self.database_url is not None:
            with self._connect() as connection:
                connection.execute("""UPDATE media_upload_reservations
                    SET chat_import_state=%s,updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat' AND media_type='video'
                      AND storage_provider='chat_bunny' AND chat_source_name IS NOT NULL
                      AND chat_import_state='fetch_started' AND external_id IS NULL""",
                    (state, identifier, user_id))
            return
        with self._lock:
            row = self._memory.get(identifier)
            if (row is not None and row.user_id == user_id and _staged_video(row)
                    and row.chat_import_state == "fetch_started" and row.external_id is None):
                self._memory[identifier] = replace(row, chat_import_state=state)

    def bind_chat_video_import(self, identifier: str, user_id: str, video_id: str) -> UploadReservation:
        if not isinstance(video_id, str) or not re.fullmatch(r"[A-Za-z0-9-]+", video_id):
            raise ValueError("Invalid imported video identifier.")
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("""UPDATE media_upload_reservations
                    SET external_id=%s,pending_name=%s,final_name=%s,
                        chat_import_state='imported',updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat' AND media_type='video'
                      AND storage_provider='chat_bunny' AND chat_source_name IS NOT NULL
                      AND status IN ('pending','canceled','deletion_pending','failed')
                      AND chat_import_state IN ('fetch_started','fetch_submitted','imported')
                      AND (external_id IS NULL OR external_id=%s) RETURNING *""",
                    (video_id, video_id, video_id, identifier, user_id, video_id)).fetchone()
            if row is None:
                raise ValueError("The imported video no longer matches this upload.")
            return _reservation_from_row(row)
        with self._lock:
            row = self._memory.get(identifier)
            if (row is None or row.user_id != user_id or not _staged_video(row)
                    or row.status not in {"pending", "canceled", "deletion_pending", "failed"}
                    or row.chat_import_state not in {"fetch_started", "fetch_submitted", "imported"}
                    or row.external_id not in {None, video_id}):
                raise ValueError("The imported video no longer matches this upload.")
            result = replace(row, external_id=video_id, pending_name=video_id,
                final_name=video_id, chat_import_state="imported")
            self._memory[identifier] = result
            return result

    def chat_sources_due(self, limit: int = 100) -> list[UploadReservation]:
        now = datetime.now(timezone.utc)
        if self.database_url is not None:
            with self._connect() as connection:
                rows = connection.execute("""SELECT * FROM media_upload_reservations
                    WHERE purpose='chat' AND media_type='video' AND storage_provider='chat_bunny'
                      AND chat_source_name IS NOT NULL AND chat_source_deleted_at IS NULL
                      AND expires_at<=%s AND COALESCE(chat_source_read_expires_at,expires_at)<=%s
                      AND (COALESCE(chat_import_state,'') NOT IN ('fetch_started','fetch_submitted')
                        OR external_id IS NOT NULL
                        OR LEAST(GREATEST(expires_at,COALESCE(chat_source_read_expires_at,expires_at)) + INTERVAL '1 hour',created_at + INTERVAL '2 hours')<=%s)
                      AND (status IN ('complete','used','canceled','rejected','failed','deletion_pending','deleted','expired','abandoned')
                        OR chat_import_state IN ('staged','fetch_rejected')
                        OR LEAST(GREATEST(expires_at,COALESCE(chat_source_read_expires_at,expires_at)) + INTERVAL '1 hour',created_at + INTERVAL '2 hours')<=%s)
                    ORDER BY expires_at ASC LIMIT %s""", (now, now, now, now, limit)).fetchall()
            return [_reservation_from_row(row) for row in rows]
        with self._lock:
            return [row for row in self._memory.values() if _staged_video(row)
                    and row.chat_source_deleted_at is None and chat_source_can_delete(row, now)
                    and (row.chat_import_state not in {"fetch_started", "fetch_submitted"}
                         or row.external_id is not None or chat_import_deadline(row) <= now)
                    and (row.status in {"complete", "used", "canceled", "rejected", "failed", "deletion_pending", "deleted", "expired", "abandoned"}
                         or row.chat_import_state in {"staged", "fetch_rejected"}
                         or chat_import_deadline(row) <= now)][:limit]

    def mark_chat_source_deleted(self, identifier: str, user_id: str) -> None:
        now = datetime.now(timezone.utc)
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("""UPDATE media_upload_reservations
                    SET chat_source_deleted_at=COALESCE(chat_source_deleted_at,%s),updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat' AND media_type='video'
                      AND storage_provider='chat_bunny' AND chat_source_name IS NOT NULL
                      AND expires_at<=%s AND COALESCE(chat_source_read_expires_at,expires_at)<=%s
                    RETURNING id""", (now, identifier, user_id, now, now)).fetchone()
            if row is None:
                raise ValueError("Source upload authorization has not expired.")
            return
        with self._lock:
            row = self._memory.get(identifier)
            if row is None or row.user_id != user_id or not _staged_video(row) or not chat_source_can_delete(row, now):
                raise ValueError("Source upload authorization has not expired.")
            self._memory[identifier] = replace(row, chat_source_deleted_at=row.chat_source_deleted_at or now)

    def complete_chat_video(self, identifier: str, user_id: str,
                            resolutions: tuple[str, ...], mp4_resolution: str) -> None:
        # Persist the provider-verified playback choice and readiness together.
        # Old rows intentionally remain NULL and cannot receive guessed URLs.
        encoded = ",".join(resolutions)
        _validate_video_playback(encoded, mp4_resolution)
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("""UPDATE media_upload_reservations
                    SET status='complete',chat_video_resolutions=%s,
                        chat_video_mp4_resolution=%s,updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat'
                    AND media_type='video' AND storage_provider='chat_bunny'
                    AND (chat_source_name IS NULL OR chat_import_state='imported')
                    AND status='pending' AND message_id IS NULL RETURNING id""",
                    (encoded, mp4_resolution, identifier, user_id)).fetchone()
                if row is None:
                    raise ValueError("Attachment upload is no longer active.")
            return
        with self._lock:
            row = self._memory.get(identifier)
            if (row is None or row.user_id != user_id or row.purpose != "chat"
                    or row.media_type != "video" or row.storage_provider != "chat_bunny"
                    or (row.chat_source_name is not None and row.chat_import_state != "imported")
                    or row.status != "pending" or row.message_id is not None):
                raise ValueError("Attachment upload is no longer active.")
            self._memory[identifier] = replace(row, status="complete",
                chat_video_resolutions=encoded, chat_video_mp4_resolution=mp4_resolution)

    def claim_chat_cleanup(self, identifier: str, user_id: str, expected_status: str) -> bool:
        """A cleanup snapshot must not delete an attachment claimed meanwhile."""
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("""UPDATE media_upload_reservations
                    SET status='deletion_pending',updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat' AND status=%s
                    AND (%s<>'complete' OR message_id IS NULL) RETURNING id""",
                    (identifier, user_id, expected_status, expected_status)).fetchone()
                return row is not None
        with self._lock:
            row = self._memory.get(identifier)
            if (row is None or row.user_id != user_id or row.purpose != "chat"
                    or row.status != expected_status
                    or (expected_status == "complete" and row.message_id is not None)):
                return False
            self._memory[identifier] = replace(row, status="deletion_pending")
            return True

    def cancel_chat_media(self, identifier: str, user_id: str) -> None:
        self._transition_chat(identifier, user_id, "canceled", {"pending", "complete", "canceled", "failed", "rejected"})

    def reject_chat_media(self, identifier: str, user_id: str) -> None:
        """A stale verification failure must never invalidate completed media."""
        self._transition_chat(identifier, user_id, "rejected", {"pending"})

    def _transition_chat(self, identifier: str, user_id: str, status: str, allowed: set[str]) -> None:
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute("""UPDATE media_upload_reservations SET status=%s,updated_at=NOW()
                    WHERE id=%s AND user_id=%s AND purpose='chat' AND status=ANY(%s) AND message_id IS NULL RETURNING id""",
                    (status, identifier, user_id, list(allowed))).fetchone()
                if row is None:
                    raise ValueError("Attachment upload is no longer active.")
            return
        with self._lock:
            row = self._memory.get(identifier)
            if row is None or row.user_id != user_id or row.purpose != "chat" or row.status not in allowed or row.message_id is not None:
                raise ValueError("Attachment upload is no longer active.")
            self._memory[identifier] = replace(row, status=status)

    def assert_completed_media(
        self,
        user_id: str,
        attachments: list[tuple[str, str, str, str]],
    ) -> None:
        for media_id, media_type, url, thumbnail_url in attachments:
            reservation = self.get(media_id, user_id)
            if reservation is None or reservation.purpose != "social" or reservation.status not in {"complete", "used"}:
                raise ValueError("Upload is missing or has not finished.")
            if (
                reservation.media_type != media_type
                or reservation.public_url != url
                or reservation.thumbnail_public_url != thumbnail_url
            ):
                raise ValueError("Upload details do not match the reserved media.")

    def mark_used(self, user_id: str, media_ids: list[str]) -> None:
        for media_id in media_ids:
            reservation = self.get(media_id, user_id)
            if reservation is None or reservation.purpose != "social":
                raise ValueError("Private message media cannot be used publicly.")
            self.set_status(media_id, user_id, "used")

    def validate_chat_media(self, user_id: str, scope_type: str, scope_id: str,
                            media_ids: list[str]) -> list[UploadReservation]:
        if len(media_ids) > 1 or len(set(media_ids)) != len(media_ids):
            raise ValueError("Choose at most one attachment per message.")
        rows = [self.get(identifier, user_id) for identifier in media_ids]
        for row in rows:
            if (row is None or row.purpose != "chat" or row.scope_type != scope_type
                    or row.scope_id != scope_id or row.status not in {"complete", "used"}):
                raise ValueError("Message attachment is unavailable or belongs to another conversation.")
            if row.media_type == "video":
                verified_chat_video_playback(row)
        return rows

    def claim_chat_media(self, user_id: str, scope_type: str, scope_id: str,
                         media_ids: list[str], message_id: str, client_message_id: str,
                         *, connection=None) -> list[UploadReservation]:
        if not media_ids:
            return []
        if len(media_ids) > 1 or len(set(media_ids)) != len(media_ids):
            raise ValueError("Choose at most one attachment per message.")
        def claimed(row):
            if (row is None or row.purpose != "chat" or row.user_id != user_id
                    or row.scope_type != scope_type or row.scope_id != scope_id
                    or row.status not in {"complete", "used"}
                    or (row.message_id is not None and
                        (row.message_id != message_id or row.client_message_id != client_message_id))):
                raise ValueError("Message attachment is unavailable or already used.")
            if row.media_type == "video":
                verified_chat_video_playback(row)
            return replace(row, status="used", message_id=message_id,
                           client_message_id=client_message_id)
        def sql_claim(conn):
            result = []
            for identifier in media_ids:
                raw = conn.execute("SELECT * FROM media_upload_reservations WHERE id=%s AND user_id=%s FOR UPDATE",
                                   (identifier, user_id)).fetchone()
                row = claimed(_reservation_from_row(raw) if raw is not None else None)
                conn.execute("UPDATE media_upload_reservations SET status='used', message_id=%s, client_message_id=%s, updated_at=NOW() WHERE id=%s AND user_id=%s",
                             (message_id, client_message_id, identifier, user_id))
                result.append(row)
            return result
        if connection is not None:
            return sql_claim(connection)
        if self.database_url is not None:
            with self._connect() as conn, conn.transaction():
                return sql_claim(conn)
        with self._lock:
            result = [claimed(self._memory.get(identifier)) for identifier in media_ids]
            for row in result:
                self._memory[row.id] = row
            return result

    def media_id_for_url(self, user_id: str, url: str | None) -> str | None:
        if not url:
            return None
        if self.database_url is not None:
            with self._connect() as connection:
                row = connection.execute(
                    """
                    SELECT id FROM media_upload_reservations
                    WHERE user_id = %s
                      AND (public_url = %s OR thumbnail_public_url = %s)
                      AND status IN ('complete', 'used')
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                    (user_id, url, url),
                ).fetchone()
            return str(row["id"]) if row is not None else None
        with self._lock:
            matches = [
                reservation
                for reservation in self._memory.values()
                if reservation.user_id == user_id
                and url in {reservation.public_url, reservation.thumbnail_public_url}
                and reservation.status in {"complete", "used"}
            ]
        if not matches:
            return None
        return max(matches, key=lambda item: item.created_at).id

    def queue_media_deletion(
        self,
        user_id: str,
        media_ids: list[str],
    ) -> list[UploadReservation]:
        normalized_ids = sorted({media_id for media_id in media_ids if media_id})
        if not normalized_ids:
            return []
        if self.database_url is not None:
            with self._connect() as connection:
                rows = connection.execute(
                    """
                    UPDATE media_upload_reservations
                    SET status = 'deletion_pending', updated_at = NOW()
                    WHERE user_id = %s
                        AND id = ANY(%s)
                        AND status NOT IN ('deleted', 'expired', 'abandoned')
                    RETURNING *
                    """,
                    (user_id, normalized_ids),
                ).fetchall()
            return [_reservation_from_row(row) for row in rows]
        queued: list[UploadReservation] = []
        with self._lock:
            for media_id in normalized_ids:
                reservation = self._memory.get(media_id)
                if (
                    reservation is None
                    or reservation.user_id != user_id
                    or reservation.status in {"deleted", "expired", "abandoned"}
                ):
                    continue
                updated = replace(reservation, status="deletion_pending")
                self._memory[media_id] = updated
                queued.append(updated)
        return queued

    def queue_chat_scope_deletion(self, scope_type: str, scope_id: str, *, connection=None) -> None:
        """Deleting a conversation also deletes every participant's attachments."""
        def sql_queue(conn):
            conn.execute("""UPDATE media_upload_reservations
                SET status='deletion_pending',updated_at=NOW()
                WHERE purpose='chat' AND scope_type=%s AND scope_id=%s
                AND status NOT IN ('deleted','expired','abandoned')""", (scope_type, scope_id))
        if connection is not None:
            sql_queue(connection)
            return
        if self.database_url is not None:
            with self._connect() as conn:
                sql_queue(conn)
            return
        with self._lock:
            for identifier, row in list(self._memory.items()):
                if (row.purpose == "chat" and row.scope_type == scope_type and row.scope_id == scope_id
                        and row.status not in {"deleted", "expired", "abandoned"}):
                    self._memory[identifier] = replace(row, status="deletion_pending")

    def queue_user_media_deletion(self, user_id: str) -> list[UploadReservation]:
        if self.database_url is not None:
            with self._connect() as connection:
                rows = connection.execute(
                    """
                    UPDATE media_upload_reservations
                    SET status = 'deletion_pending', updated_at = NOW()
                    WHERE user_id = %s
                        AND status NOT IN ('deleted', 'expired', 'abandoned')
                    RETURNING *
                    """,
                    (user_id,),
                ).fetchall()
            return [_reservation_from_row(row) for row in rows]
        queued: list[UploadReservation] = []
        with self._lock:
            for reservation_id, reservation in list(self._memory.items()):
                if (
                    reservation.user_id != user_id
                    or reservation.status in {"deleted", "expired", "abandoned"}
                ):
                    continue
                updated = replace(reservation, status="deletion_pending")
                self._memory[reservation_id] = updated
                queued.append(updated)
        return queued

    def deletion_pending(self, limit: int = 100) -> list[UploadReservation]:
        return self._reservations_with_status("deletion_pending", limit)

    def abandoned_completed(
        self,
        older_than: datetime,
        limit: int = 100,
    ) -> list[UploadReservation]:
        if self.database_url is not None:
            with self._connect() as connection:
                rows = connection.execute(
                    """
                    SELECT * FROM media_upload_reservations
                    WHERE status = 'complete' AND updated_at < %s
                    ORDER BY updated_at ASC
                    LIMIT %s
                    """,
                    (older_than, limit),
                ).fetchall()
            return [_reservation_from_row(row) for row in rows]
        with self._lock:
            return [
                reservation
                for reservation in self._memory.values()
                if reservation.status == "complete"
                and reservation.created_at < older_than
            ][:limit]

    def expired_pending(self, limit: int = 20) -> list[UploadReservation]:
        now = datetime.now(timezone.utc)
        if self.database_url is not None:
            with self._connect() as connection:
                rows = connection.execute(
                    """
                    SELECT * FROM media_upload_reservations
                    WHERE (status = 'pending' OR (purpose='chat' AND status IN ('canceled','rejected','failed','deleted')))
                      AND CASE WHEN status='pending' AND chat_source_name IS NOT NULL
                        AND chat_import_state IN ('fetch_started','fetch_submitted','imported')
                        THEN LEAST(GREATEST(expires_at,COALESCE(chat_source_read_expires_at,expires_at)) + INTERVAL '1 hour',created_at + INTERVAL '2 hours')
                        ELSE expires_at END < %s
                    ORDER BY expires_at ASC
                    LIMIT %s
                    """,
                    (now, limit),
                ).fetchall()
            return [_reservation_from_row(row) for row in rows]
        with self._lock:
            return [
                reservation
                for reservation in self._memory.values()
                if (reservation.status == "pending" or (reservation.purpose == "chat" and reservation.status in {"canceled", "rejected", "failed", "deleted"}))
                and (chat_import_deadline(reservation)
                     if reservation.status == "pending" and _staged_video(reservation)
                        and reservation.chat_import_state in {"fetch_started", "fetch_submitted", "imported"}
                     else reservation.expires_at) < now
            ][:limit]

    def _reservations_with_status(
        self,
        status: str,
        limit: int,
    ) -> list[UploadReservation]:
        if self.database_url is not None:
            with self._connect() as connection:
                rows = connection.execute(
                    """
                    SELECT * FROM media_upload_reservations
                    WHERE status = %s
                    ORDER BY updated_at ASC
                    LIMIT %s
                    """,
                    (status, limit),
                ).fetchall()
            return [_reservation_from_row(row) for row in rows]
        with self._lock:
            return [
                reservation
                for reservation in self._memory.values()
                if reservation.status == status
            ][:limit]

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
                    retained_upload_bytes(row, now)
                    for row in rows
                ),
                user_retained_bytes=sum(
                    retained_upload_bytes(row, now)
                    for row in rows
                    if row.user_id == reservation.user_id
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
                retained_row = connection.execute(
                    """
                    SELECT
                        COALESCE(SUM(retained_bytes), 0) AS global_bytes,
                        COALESCE(
                            SUM(retained_bytes) FILTER (WHERE user_id = %s),
                            0
                        ) AS user_bytes
                    FROM (
                      SELECT user_id,
                        CASE WHEN status IN ('pending','complete','used','deletion_pending')
                          OR (purpose='chat' AND status IN ('canceled','rejected','failed','deleted'))
                          OR (purpose='chat' AND media_type='video' AND chat_source_name IS NOT NULL
                            AND chat_import_state IN ('fetch_started','fetch_submitted') AND external_id IS NULL)
                          THEN expected_bytes+expected_thumbnail_bytes ELSE 0 END
                        + CASE WHEN chat_source_name IS NOT NULL
                          AND (chat_source_deleted_at IS NULL OR expires_at>%s
                            OR COALESCE(chat_source_read_expires_at,expires_at)>%s)
                          THEN chat_source_bytes ELSE 0 END AS retained_bytes
                      FROM media_upload_reservations
                    ) retained_uploads
                    """,
                    (reservation.user_id, now, now),
                ).fetchone()
                _enforce_limits(
                    reservation,
                    limits,
                    minute_count=int(minute_count),
                    user_day_count=int(day_row["user_count"]),
                    user_video_day_count=int(day_row["user_video_count"]),
                    user_day_bytes=int(day_row["user_bytes"]),
                    global_day_count=int(day_row["global_count"]),
                    global_day_bytes=int(day_row["global_bytes"]),
                    retained_bytes=int(retained_row["global_bytes"]),
                    user_retained_bytes=int(retained_row["user_bytes"]),
                )
                connection.execute(
                    """
                    INSERT INTO media_upload_reservations (
                        id, user_id, client_ip_hash, media_type, content_type,
                        thumbnail_content_type, expected_bytes,
                        expected_thumbnail_bytes, total_bytes, pending_name,
                        final_name, pending_thumbnail_name, final_thumbnail_name,
                        public_url, thumbnail_public_url, status, created_at,
                        expires_at, storage_provider, external_id,
                        purpose, scope_type, scope_id, message_id, client_message_id,
                        chat_video_resolutions, chat_video_mp4_resolution,
                        chat_source_name,chat_source_bytes,chat_source_deleted_at,
                        chat_source_read_expires_at,chat_source_etag,chat_source_duration_seconds,
                        chat_import_state,chat_import_started_at
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
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
                        reservation.storage_provider,
                        reservation.external_id,
                        reservation.purpose,
                        reservation.scope_type,
                        reservation.scope_id,
                        reservation.message_id,
                        reservation.client_message_id,
                        reservation.chat_video_resolutions,
                        reservation.chat_video_mp4_resolution,
                        reservation.chat_source_name,
                        reservation.chat_source_bytes,
                        reservation.chat_source_deleted_at,
                        reservation.chat_source_read_expires_at,
                        reservation.chat_source_etag,
                        reservation.chat_source_duration_seconds,
                        reservation.chat_import_state,
                        reservation.chat_import_started_at,
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
                    storage_provider TEXT NOT NULL DEFAULT 'r2',
                    external_id TEXT,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                """
                ALTER TABLE media_upload_reservations
                ADD COLUMN IF NOT EXISTS storage_provider TEXT NOT NULL DEFAULT 'r2'
                """
            )
            connection.execute(
                """
                ALTER TABLE media_upload_reservations
                ADD COLUMN IF NOT EXISTS external_id TEXT
                """
            )
            for name, definition in (("purpose", "TEXT NOT NULL DEFAULT 'social'"),
                                     ("scope_type", "TEXT"), ("scope_id", "TEXT"),
                                     ("message_id", "TEXT"), ("client_message_id", "TEXT"),
                                     ("chat_video_resolutions", "TEXT"),
                                     ("chat_video_mp4_resolution", "TEXT"),
                                     ("chat_source_name", "TEXT"), ("chat_source_bytes", "BIGINT NOT NULL DEFAULT 0"),
                                     ("chat_source_deleted_at", "TIMESTAMPTZ"), ("chat_source_read_expires_at", "TIMESTAMPTZ"),
                                     ("chat_source_etag", "TEXT"), ("chat_source_duration_seconds", "DOUBLE PRECISION"),
                                     ("chat_import_state", "TEXT"), ("chat_import_started_at", "TIMESTAMPTZ"),
                                     ("media_width", "INTEGER"), ("media_height", "INTEGER")):
                connection.execute(f"ALTER TABLE media_upload_reservations ADD COLUMN IF NOT EXISTS {name} {definition}")
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
            connection.execute("""CREATE INDEX IF NOT EXISTS media_chat_sources_idx
                ON media_upload_reservations (expires_at)
                WHERE chat_source_name IS NOT NULL AND chat_source_deleted_at IS NULL""")


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
    user_retained_bytes: int,
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
    if user_retained_bytes + reservation.total_bytes > limits.user_retained_bytes:
        raise UploadQuotaExceeded(
            "Your media storage is full. Delete older posts before uploading more."
        )
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
        storage_provider=str(row.get("storage_provider") or "r2"),
        external_id=(
            str(row["external_id"]) if row.get("external_id") is not None else None
        ),
        media_width=row.get("media_width"),
        media_height=row.get("media_height"),
        purpose=str(row.get("purpose") or "social"),
        scope_type=row.get("scope_type"),
        scope_id=row.get("scope_id"),
        message_id=row.get("message_id"),
        client_message_id=row.get("client_message_id"),
        chat_video_resolutions=row.get("chat_video_resolutions"),
        chat_video_mp4_resolution=row.get("chat_video_mp4_resolution"),
        chat_source_name=row.get("chat_source_name"),
        chat_source_bytes=int(row.get("chat_source_bytes") or 0),
        chat_source_deleted_at=_aware(row["chat_source_deleted_at"]) if row.get("chat_source_deleted_at") else None,
        chat_source_read_expires_at=_aware(row["chat_source_read_expires_at"]) if row.get("chat_source_read_expires_at") else None,
        chat_source_etag=row.get("chat_source_etag"),
        chat_source_duration_seconds=row.get("chat_source_duration_seconds"),
        chat_import_state=row.get("chat_import_state"),
        chat_import_started_at=_aware(row["chat_import_started_at"]) if row.get("chat_import_started_at") else None,
    )


def _staged_video(row: UploadReservation) -> bool:
    return (row.purpose == "chat" and row.media_type == "video"
            and row.storage_provider == "chat_bunny"
            and row.chat_source_name is not None and row.chat_source_bytes > 0)


def chat_source_can_delete(row: UploadReservation, now: datetime | None = None) -> bool:
    now = now or datetime.now(timezone.utc)
    return (_staged_video(row) and row.expires_at <= now
            and (row.chat_source_read_expires_at is None or row.chat_source_read_expires_at <= now))


def chat_import_deadline(row: UploadReservation) -> datetime:
    grants_end = max(row.expires_at, row.chat_source_read_expires_at or row.expires_at)
    return min(grants_end + timedelta(hours=1), row.created_at + timedelta(hours=2))


def retained_upload_bytes(row: UploadReservation, now: datetime | None = None) -> int:
    now = now or datetime.now(timezone.utc)
    retained = row.status in {"pending", "complete", "used", "deletion_pending"} or (
        row.purpose == "chat" and row.status in {"canceled", "rejected", "failed", "deleted"})
    unknown_fetch = (_staged_video(row) and row.chat_import_state in {"fetch_started", "fetch_submitted"}
                     and row.external_id is None)
    base = row.expected_bytes + row.expected_thumbnail_bytes if retained or unknown_fetch else 0
    source = (row.chat_source_bytes if row.chat_source_name is not None and (
        row.chat_source_deleted_at is None or not chat_source_can_delete(row, now)) else 0)
    return base + source


def _validate_video_playback(encoded, mp4_resolution) -> tuple[tuple[str, ...], str]:
    approved = {"240p", "360p", "480p", "720p"}
    if not isinstance(encoded, str) or not isinstance(mp4_resolution, str):
        raise ValueError("Private video playback has not been verified. Choose the video again.")
    resolutions = tuple(encoded.split(","))
    if (not resolutions or any(value not in approved for value in resolutions)
            or len(resolutions) != len(set(resolutions))
            or resolutions != tuple(sorted(resolutions, key=lambda value: int(value[:-1])))
            or mp4_resolution not in resolutions):
        raise ValueError("Private video playback metadata is invalid. Choose the video again.")
    return resolutions, mp4_resolution


def verified_chat_video_playback(row: UploadReservation) -> tuple[tuple[str, ...], str]:
    if row.purpose != "chat" or row.media_type != "video" or row.storage_provider != "chat_bunny":
        raise ValueError("Private video playback metadata is unavailable.")
    return _validate_video_playback(row.chat_video_resolutions, row.chat_video_mp4_resolution)


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
