from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import base64
import os
import re
from urllib.parse import urlsplit

import httpx


TUS_UPLOAD_URL = "https://video.bunnycdn.com/tusupload"


class BunnyFetchRejected(RuntimeError):
    """The provider explicitly rejected a fetch before accepting a job."""


@dataclass(frozen=True)
class BunnyUploadTarget:
    video_id: str
    url: str
    headers: dict[str, str]
    expires_at: datetime


@dataclass(frozen=True)
class BunnyVideo:
    video_id: str
    status: int
    length_seconds: float | None
    storage_size: int | None = None
    encode_progress: int | None = None
    available_resolutions: tuple[str, ...] | None = None
    has_mp4_fallback: bool | None = None

    @property
    def fully_encoded(self) -> bool:
        return self.status in {3, 9, 10} or (self.status == 4 and self.encode_progress == 100)

    @property
    def ready(self) -> bool:
        return self.status in {3, 4, 9, 10}

    @property
    def failed(self) -> bool:
        return self.status in {5, 8}


class BunnyStreamClient:
    def __init__(self) -> None:
        self.library_id = _required_env("BUNNY_STREAM_LIBRARY_ID")
        self.api_key = _required_env("BUNNY_STREAM_API_KEY")
        self.cdn_hostname = _required_env("BUNNY_STREAM_CDN_HOSTNAME").strip("/")
        self.timeout = httpx.Timeout(30.0, connect=15.0)

    def create_upload(self, title: str, *, expires_seconds: int) -> BunnyUploadTarget:
        response = httpx.post(
            f"https://video.bunnycdn.com/library/{self.library_id}/videos",
            headers={"AccessKey": self.api_key},
            json={"title": title},
            timeout=self.timeout,
        )
        response.raise_for_status()
        payload = response.json()
        video_id = str(payload.get("guid") or payload.get("videoId") or "").strip()
        if not video_id:
            raise RuntimeError("Bunny Stream did not return a video ID")

        expires_at = datetime.now(timezone.utc) + timedelta(seconds=expires_seconds)
        expires = int(expires_at.timestamp())
        signature = bunny_upload_signature(
            self.library_id,
            self.api_key,
            expires,
            video_id,
        )
        return BunnyUploadTarget(
            video_id=video_id,
            url=TUS_UPLOAD_URL,
            headers={
                "AuthorizationSignature": signature,
                "AuthorizationExpire": str(expires),
                "VideoId": video_id,
                "LibraryId": self.library_id,
            },
            expires_at=expires_at,
        )

    def get_video(self, video_id: str) -> BunnyVideo:
        response = httpx.get(
            f"https://video.bunnycdn.com/library/{self.library_id}/videos/{video_id}",
            headers={"AccessKey": self.api_key},
            timeout=self.timeout,
        )
        response.raise_for_status()
        payload = response.json()
        raw_length = payload.get("length")
        try:
            length_seconds = float(raw_length) if raw_length is not None else None
        except (TypeError, ValueError):
            length_seconds = None
        return BunnyVideo(
            video_id=video_id,
            status=int(payload.get("status", 0)),
            length_seconds=length_seconds,
            storage_size=_storage_size(payload.get("storageSize")),
            encode_progress=_storage_size(payload.get("encodeProgress")),
            available_resolutions=_available_resolutions(payload.get("availableResolutions")),
            has_mp4_fallback=(payload.get("hasMP4Fallback")
                              if isinstance(payload.get("hasMP4Fallback"), bool) else None),
        )

    def delete_video(self, video_id: str | None) -> None:
        if not video_id:
            return
        response = httpx.delete(
            f"https://video.bunnycdn.com/library/{self.library_id}/videos/{video_id}",
            headers={"AccessKey": self.api_key},
            timeout=self.timeout,
        )
        if response.status_code != 404:
            response.raise_for_status()

    def playlist_url(self, video_id: str) -> str:
        return f"https://{self.cdn_hostname}/{video_id}/playlist.m3u8"

    def thumbnail_url(self, video_id: str) -> str:
        return f"https://{self.cdn_hostname}/{video_id}/thumbnail.jpg"

    def fallback_url(self, video_id: str, resolution: str = "720p") -> str:
        return f"https://{self.cdn_hostname}/{video_id}/play_{resolution}.mp4"


class PrivateChatBunnyClient(BunnyStreamClient):
    def __init__(self) -> None:
        if os.getenv("CHAT_BUNNY_STREAM_PRIVATE_VERIFIED", "").lower() != "true":
            raise RuntimeError("Private video delivery has not been verified")
        self.library_id = _required_env("CHAT_BUNNY_STREAM_LIBRARY_ID")
        if self.library_id == os.getenv("BUNNY_STREAM_LIBRARY_ID", "").strip():
            raise RuntimeError("Private messages require a separate video library")
        self.api_key = _required_env("CHAT_BUNNY_STREAM_API_KEY")
        self.cdn_hostname = _required_env("CHAT_BUNNY_STREAM_CDN_HOSTNAME").strip("/")
        if self.cdn_hostname == os.getenv("BUNNY_STREAM_CDN_HOSTNAME", "").strip("/"):
            raise RuntimeError("Private messages require a separate delivery zone")
        if not re.fullmatch(r"[A-Za-z0-9.-]+", self.cdn_hostname):
            raise RuntimeError("Invalid private video hostname")
        self.token_key = _required_env("CHAT_BUNNY_STREAM_TOKEN_KEY")
        self.timeout = httpx.Timeout(30.0, connect=15.0)

    def create_upload(self, title: str, *, expires_seconds: int) -> BunnyUploadTarget:
        raise RuntimeError("Private videos require protected R2 staging, not client TUS grants")

    def fetch_validated_source(self, source_url: str, title: str, *, etag: str) -> None:
        """Submit once, server-side only. A timeout is NOT permission to retry.

        Fetch creates its own ID, so the durable reservation title is recovered
        through List Videos. Clients receive neither this URL nor a Bunny grant.
        """
        parsed = urlsplit(source_url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
                or parsed.password is not None or parsed.fragment or not parsed.query
                or not re.fullmatch(r"TYDES private chat_media_[0-9a-f]{32}", title)
                or not re.fullmatch(r'"[0-9a-fA-F]{32}(?:-[1-9][0-9]*)?"', etag)):
            raise ValueError("Invalid validated private video source")
        response = httpx.post(
            f"https://video.bunnycdn.com/library/{self.library_id}/videos/fetch",
            headers={"AccessKey": self.api_key},
            json={"url": source_url, "headers": {"If-Match": etag}, "title": title},
            timeout=self.timeout, follow_redirects=False,
        )
        try:
            payload = response.json()
        except ValueError:
            raise RuntimeError("Private video import outcome is uncertain") from None
        if not isinstance(payload, dict):
            raise RuntimeError("Private video import outcome is uncertain")
        # Only an explicit, matching validation/auth/rate-limit rejection can
        # release the import intent. Other HTTP failures may have side effects.
        if (response.status_code in {400, 401, 403, 404, 422, 429}
                and payload.get("success") is False
                and type(payload.get("statusCode")) is int
                and payload["statusCode"] == response.status_code):
            raise BunnyFetchRejected("Private video import was rejected")
        if (response.status_code != 200 or payload.get("success") is not True
                or type(payload.get("statusCode")) is not int or payload["statusCode"] != 200):
            raise RuntimeError("Private video import outcome is uncertain")

    def resolve_imported_video(self, title: str) -> str | None:
        """One bounded exact-title reconciliation; never create or re-upload."""
        if not re.fullmatch(r"TYDES private chat_media_[0-9a-f]{32}", title):
            raise ValueError("Invalid private video import title")
        response = httpx.get(
            f"https://video.bunnycdn.com/library/{self.library_id}/videos",
            headers={"AccessKey": self.api_key},
            params={"search": title, "page": 1, "itemsPerPage": 10},
            timeout=self.timeout, follow_redirects=False,
        )
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict):
            raise RuntimeError("Private video import could not be reconciled")
        total, items = payload.get("totalItems"), payload.get("items")
        if type(total) is int and total == 0 and items == []:
            return None
        if type(total) is not int or total != 1 or not isinstance(items, list) or len(items) != 1:
            raise RuntimeError("Private video import is not uniquely identifiable")
        item = items[0]
        if (not isinstance(item, dict) or item.get("title") != title
                or type(item.get("videoLibraryId")) is not int
                or str(item["videoLibraryId"]) != self.library_id
                or not isinstance(item.get("guid"), str)
                or not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", item["guid"])):
            raise RuntimeError("Private video import identity could not be verified")
        return item["guid"]

    def signed_url(self, video_id: str, filename: str, *, expires: int) -> str:
        if not re.fullmatch(r"[A-Za-z0-9-]+", video_id):
            raise ValueError("Invalid video identifier")
        exact_file = filename == "thumbnail.jpg" or re.fullmatch(r"play_(240|360|480|720)p\.mp4", filename)
        if not exact_file:
            raise ValueError("Invalid private video resource")
        resource = f"/{video_id}/{filename}"
        # Short private clips use verified MP4s only. Exact-path tokens cannot
        # be changed to an original, master playlist, or higher rendition.
        message = f"{resource}{expires}".encode()
        digest = hmac.new(self.token_key.encode(), message, hashlib.sha256).digest()
        token = "HS256-" + base64.urlsafe_b64encode(digest).decode().rstrip("=")
        return (f"https://{self.cdn_hostname}/bcdn_token={token}"
                f"&expires={expires}{resource}")

    def verified_mp4_resolution(self, video_id: str, resolutions: tuple[str, ...],
                                *, max_bytes: int) -> str | None:
        """Check at most four approved MP4 headers once, before readiness.

        availableResolutions describes HLS encodes, not proof that every MP4
        exists. Never fall back to a guessed path or download a video body.
        """
        approved = {"240p", "360p", "480p", "720p"}
        if not resolutions or any(value not in approved for value in resolutions):
            raise ValueError("Private video renditions must not exceed 720p.")
        expires = int((datetime.now(timezone.utc) + timedelta(seconds=120)).timestamp())
        for resolution in sorted(set(resolutions), key=lambda value: int(value[:-1]), reverse=True):
            response = httpx.head(
                self.signed_url(video_id, f"play_{resolution}.mp4", expires=expires),
                headers={"Referer": "https://tydes.io/"},
                timeout=httpx.Timeout(5.0, connect=3.0), follow_redirects=False,
            )
            if response.status_code == 404:
                continue
            response.raise_for_status()
            size = _storage_size(response.headers.get("content-length"))
            if (response.status_code not in {200, 206}
                    or response.headers.get("content-type", "").split(";")[0].lower() != "video/mp4"
                    or size is None or not 0 < size <= max_bytes):
                raise RuntimeError("Private video MP4 metadata could not be verified")
            return resolution
        return None


def _available_resolutions(raw) -> tuple[str, ...] | None:
    if not isinstance(raw, str):
        return None
    values = tuple(value.strip() for value in raw.split(","))
    known = {"240p", "360p", "480p", "720p", "1080p", "1440p", "2160p"}
    if not values or any(value not in known for value in values) or len(set(values)) != len(values):
        return None
    return tuple(sorted(values, key=lambda value: int(value[:-1])))


def _storage_size(raw) -> int | None:
    try:
        value = int(raw)
    except (TypeError, ValueError, OverflowError):
        return None
    return value if value >= 0 else None


def bunny_stream_enabled() -> bool:
    return os.getenv("BUNNY_STREAM_ENABLED", "false").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def bunny_upload_signature(
    library_id: str,
    api_key: str,
    expires: int,
    video_id: str,
) -> str:
    value = f"{library_id}{api_key}{expires}{video_id}".encode("utf-8")
    return hashlib.sha256(value).hexdigest()


def _required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if value:
        return value
    raise RuntimeError(f"Missing environment variable: {name}")
