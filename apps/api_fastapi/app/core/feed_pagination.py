"""Small, account-bound keyset cursors. A cursor is a selector, never authority."""
from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import re
from typing import Literal

from pydantic import BaseModel, Field

from app.core.models import SocialEngagementState, SocialPost

FeedKind = Literal["post", "repost"]
FEED_CURSOR_MAX_LENGTH = 1024
FEED_PAGE_MAX_SIZE = 50
_IDENTIFIER = re.compile(r"^[A-Za-z0-9_-]{1,120}$")


def feed_datetime(value: datetime) -> datetime:
    # Old local fixtures can be naive; cursor input itself is always strict.
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


class FeedEntry(BaseModel):
    entry_id: str
    post: SocialPost
    kind: FeedKind
    activity_at: datetime


class FeedPage(BaseModel):
    items: list[FeedEntry]
    next_cursor: str | None = None
    engagement: SocialEngagementState = Field(default_factory=SocialEngagementState)
    scoped_post_ids: list[str] = Field(default_factory=list)


@dataclass(frozen=True)
class FeedPosition:
    activity_at: datetime
    kind: FeedKind
    post_id: str

    @property
    def key(self) -> tuple[datetime, str, str]:
        return (self.activity_at, self.kind, self.post_id)


@dataclass(frozen=True)
class FeedWindow:
    snapshot_at: datetime
    after: FeedPosition | None = None


def feed_position(entry: FeedEntry) -> FeedPosition:
    return FeedPosition(feed_datetime(entry.activity_at), entry.kind, entry.post.id)


def decode_feed_cursor(cursor: str | None, viewer_id: str, *, now: datetime | None = None) -> FeedWindow:
    instant = feed_datetime(now or datetime.now(timezone.utc))
    if cursor is None:
        return FeedWindow(instant)
    try:
        if not cursor or len(cursor) > FEED_CURSOR_MAX_LENGTH or not re.fullmatch(r"[A-Za-z0-9_-]+", cursor):
            raise ValueError
        raw = base64.b64decode(cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True)
        data = json.loads(raw)
        if not isinstance(data, dict) or set(data) != {"v", "u", "s", "a", "k", "p"}:
            raise ValueError
        if type(data["v"]) is not int or data["v"] != 1 or data["u"] != viewer_id:
            raise ValueError
        if data["k"] not in {"post", "repost"} or not isinstance(data["p"], str) or not _IDENTIFIER.fullmatch(data["p"]):
            raise ValueError
        dates = []
        for key in ("s", "a"):
            if not isinstance(data[key], str) or len(data[key]) > 40:
                raise ValueError
            value = datetime.fromisoformat(data[key])
            if value.tzinfo is None or value.utcoffset() is None:
                raise ValueError
            dates.append(value.astimezone(timezone.utc))
        snapshot, activity = dates
        if snapshot > instant + timedelta(seconds=5) or activity > snapshot:
            raise ValueError
        return FeedWindow(snapshot, FeedPosition(activity, data["k"], data["p"]))
    except (ValueError, TypeError, KeyError, OverflowError, binascii.Error, UnicodeDecodeError) as error:
        raise ValueError("Invalid feed cursor. Refresh the feed and try again.") from error


def encode_feed_cursor(viewer_id: str, snapshot_at: datetime, position: FeedPosition) -> str:
    data = {
        "v": 1, "u": viewer_id,
        "s": feed_datetime(snapshot_at).isoformat(),
        "a": feed_datetime(position.activity_at).isoformat(),
        "k": position.kind, "p": position.post_id,
    }
    return base64.urlsafe_b64encode(json.dumps(data, separators=(",", ":")).encode()).decode().rstrip("=")


def finish_feed_page(entries: list[FeedEntry], *, viewer_id: str, window: FeedWindow, limit: int) -> FeedPage:
    items = entries[:limit]
    cursor = encode_feed_cursor(viewer_id, window.snapshot_at, feed_position(items[-1])) if len(entries) > limit else None
    return FeedPage(items=items, next_cursor=cursor)
