from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import os

import httpx


TUS_UPLOAD_URL = "https://video.bunnycdn.com/tusupload"


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
