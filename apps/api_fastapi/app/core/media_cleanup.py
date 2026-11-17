from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import logging
import os
from typing import Callable

from app.core.bunny_stream import BunnyStreamClient
from app.core.media_storage import R2MediaStorage, configured_media_storage
from app.core.media_uploads import UploadReservation, upload_ledger, chat_source_can_delete


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class MediaCleanupResult:
    deleted: int = 0
    expired: int = 0
    abandoned: int = 0
    failed: int = 0
    staged_sources: int = 0


def queue_post_media_deletion(user_id: str, media_ids: list[str]) -> None:
    upload_ledger.queue_media_deletion(user_id, media_ids)


def queue_account_media_deletion(user_id: str) -> None:
    upload_ledger.queue_user_media_deletion(user_id)


def run_media_cleanup(limit: int = 100) -> MediaCleanupResult:
    try:
        storage = configured_media_storage()
    except Exception:
        logger.exception("Could not initialize media storage for cleanup")
        storage = None

    staged_sources = _delete_staged_sources(upload_ledger.chat_sources_due(limit=limit))

    deleted = _delete_reservations(
        storage,
        upload_ledger.deletion_pending(limit=limit),
        object_names=_all_object_names,
        final_status="deleted",
    )
    expired = _delete_reservations(
        storage,
        upload_ledger.expired_pending(limit=limit),
        object_names=_pending_object_names,
        final_status="expired",
    )
    cutoff = datetime.now(timezone.utc) - timedelta(
        seconds=_abandoned_upload_grace_seconds()
    )
    abandoned = _delete_reservations(
        storage,
        upload_ledger.abandoned_completed(cutoff, limit=limit),
        object_names=_final_object_names,
        final_status="abandoned",
    )
    return MediaCleanupResult(
        deleted=deleted[0],
        expired=expired[0],
        abandoned=abandoned[0],
        failed=deleted[1] + expired[1] + abandoned[1] + staged_sources[1],
        staged_sources=staged_sources[0],
    )


def _delete_staged_sources(reservations: list[UploadReservation]) -> tuple[int, int]:
    cleaned = failed = 0
    for row in reservations:
        try:
            if not chat_source_can_delete(row):
                continue
            # The object must remain present until the signed If-None-Match
            # write expires: deleting earlier would make that URL reusable.
            from app.core.media_storage import PrivateChatR2Storage
            PrivateChatR2Storage().delete_object(row.chat_source_name)
            upload_ledger.mark_chat_source_deleted(row.id, row.user_id)
            cleaned += 1
        except Exception:
            failed += 1
            logger.exception("Could not clean staged media source %s", row.id)
    return cleaned, failed


def _delete_reservations(
    storage: R2MediaStorage,
    reservations: list[UploadReservation],
    *,
    object_names: Callable[[UploadReservation], tuple[str | None, ...]],
    final_status: str,
) -> tuple[int, int]:
    cleaned = 0
    failed = 0
    for reservation in reservations:
        try:
            if reservation.purpose == "chat":
                if reservation.chat_source_name is not None and not chat_source_can_delete(reservation):
                    continue
                if not upload_ledger.claim_chat_cleanup(reservation.id, reservation.user_id, reservation.status):
                    continue
                from app.core.chat_media import _delete
                _delete(reservation)
            elif reservation.storage_provider == "bunny_stream":
                BunnyStreamClient().delete_video(reservation.external_id)
            else:
                if not isinstance(storage, R2MediaStorage):
                    raise RuntimeError("Public media storage is unavailable")
                for object_name in object_names(reservation):
                    storage.delete_object(object_name)
            upload_ledger.set_status(
                reservation.id,
                reservation.user_id,
                final_status,
            )
            cleaned += 1
        except Exception:
            failed += 1
            logger.exception(
                "Could not clean media reservation %s",
                reservation.id,
            )
    return cleaned, failed


def _all_object_names(reservation: UploadReservation) -> tuple[str | None, ...]:
    return (
        reservation.pending_name,
        reservation.pending_thumbnail_name,
        reservation.final_name,
        reservation.final_thumbnail_name,
    )


def _pending_object_names(
    reservation: UploadReservation,
) -> tuple[str | None, ...]:
    return reservation.pending_name, reservation.pending_thumbnail_name


def _final_object_names(
    reservation: UploadReservation,
) -> tuple[str | None, ...]:
    return reservation.final_name, reservation.final_thumbnail_name


def _abandoned_upload_grace_seconds() -> int:
    raw = os.getenv("MEDIA_ABANDONED_UPLOAD_GRACE_SECONDS", "86400").strip()
    try:
        value = int(raw)
    except ValueError:
        value = 86_400
    return min(max(value, 3_600), 7 * 24 * 60 * 60)
