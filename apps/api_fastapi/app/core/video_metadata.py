from __future__ import annotations

from app.core.media_storage import R2MediaStorage


def mp4_duration_seconds(
    storage: R2MediaStorage,
    object_name: str,
    object_size: int,
) -> float | None:
    if object_size <= 0:
        return None
    offset = 0
    boxes_checked = 0
    while offset + 8 <= object_size and boxes_checked < 64:
        header = storage.read_object_range(
            object_name,
            offset,
            min(object_size - 1, offset + 15),
        )
        parsed = _box_header(header, 0, object_size - offset)
        if parsed is None:
            return None
        box_size, box_type, header_size = parsed
        if box_type == b"moov":
            if box_size > 8 * 1024 * 1024:
                return None
            box = storage.read_object_range(
                object_name,
                offset,
                offset + box_size - 1,
            )
            return _duration_from_moov(box, header_size)
        offset += box_size
        boxes_checked += 1
    return None


def mp4_duration_from_bytes(data: bytes) -> float | None:
    parsed = _box_header(data, 0, len(data))
    if parsed is None:
        return None
    box_size, box_type, header_size = parsed
    if box_size > len(data):
        return None
    if box_type == b"moov":
        return _duration_from_moov(data[:box_size], header_size)
    if box_type == b"mvhd":
        return _duration_from_mvhd(data[:box_size], header_size)
    return None


def _duration_from_moov(data: bytes, header_size: int) -> float | None:
    offset = header_size
    while offset + 8 <= len(data):
        parsed = _box_header(data, offset, len(data) - offset)
        if parsed is None:
            return None
        box_size, box_type, child_header_size = parsed
        if offset + box_size > len(data):
            return None
        if box_type == b"mvhd":
            return _duration_from_mvhd(
                data[offset : offset + box_size],
                child_header_size,
            )
        offset += box_size
    return None


def _duration_from_mvhd(data: bytes, header_size: int) -> float | None:
    if header_size + 20 > len(data):
        return None
    version = data[header_size]
    if version == 0:
        timescale_offset = header_size + 12
        duration_offset = header_size + 16
        duration_size = 4
    elif version == 1:
        timescale_offset = header_size + 24
        duration_offset = header_size + 28
        duration_size = 8
    else:
        return None
    if duration_offset + duration_size > len(data):
        return None
    timescale = int.from_bytes(
        data[timescale_offset : timescale_offset + 4],
        "big",
    )
    duration = int.from_bytes(
        data[duration_offset : duration_offset + duration_size],
        "big",
    )
    if timescale <= 0:
        return None
    return duration / timescale


def _box_header(
    data: bytes,
    offset: int,
    available_size: int,
) -> tuple[int, bytes, int] | None:
    if offset + 8 > len(data):
        return None
    short_size = int.from_bytes(data[offset : offset + 4], "big")
    box_type = data[offset + 4 : offset + 8]
    header_size = 8
    if short_size == 1:
        if offset + 16 > len(data):
            return None
        box_size = int.from_bytes(data[offset + 8 : offset + 16], "big")
        header_size = 16
    elif short_size == 0:
        box_size = available_size
    else:
        box_size = short_size
    if box_size < header_size or box_size > available_size:
        return None
    return box_size, box_type, header_size
