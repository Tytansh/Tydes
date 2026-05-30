from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

from fastapi import HTTPException, UploadFile

from app.core.runtime import media_dir_path


@dataclass(frozen=True)
class StoredMedia:
    name: str
    url: str


class MediaStorage:
    def store_upload(
        self,
        file: UploadFile,
        object_name: str,
        max_bytes: int,
        *,
        local_base_url: str,
    ) -> StoredMedia:
        raise NotImplementedError


class LocalMediaStorage(MediaStorage):
    def store_upload(
        self,
        file: UploadFile,
        object_name: str,
        max_bytes: int,
        *,
        local_base_url: str,
    ) -> StoredMedia:
        media_dir = media_dir_path()
        media_dir.mkdir(parents=True, exist_ok=True)
        target_path = media_dir / object_name
        _write_upload_with_limit(file, target_path, max_bytes)
        return StoredMedia(
            name=object_name,
            url=f"{local_base_url.rstrip('/')}/media/{object_name}",
        )


class R2MediaStorage(MediaStorage):
    def __init__(self) -> None:
        self.bucket = _required_env("CLOUDFLARE_R2_BUCKET")
        self.public_url = _required_env("CLOUDFLARE_R2_PUBLIC_URL").rstrip("/")
        self.prefix = os.getenv("CLOUDFLARE_R2_PREFIX", "uploads").strip("/")
        self._client = None

    @property
    def client(self):
        if self._client is None:
            import boto3

            self._client = boto3.client(
                "s3",
                endpoint_url=_r2_endpoint_url(),
                aws_access_key_id=_required_env("CLOUDFLARE_R2_ACCESS_KEY_ID"),
                aws_secret_access_key=_required_env(
                    "CLOUDFLARE_R2_SECRET_ACCESS_KEY"
                ),
                region_name="auto",
            )
        return self._client

    def store_upload(
        self,
        file: UploadFile,
        object_name: str,
        max_bytes: int,
        *,
        local_base_url: str,
    ) -> StoredMedia:
        del local_base_url
        key = f"{self.prefix}/{object_name}" if self.prefix else object_name
        temp_path = _write_upload_to_temp_file(file, max_bytes)
        try:
            self.client.upload_file(
                str(temp_path),
                self.bucket,
                key,
                ExtraArgs={
                    "ContentType": file.content_type or "application/octet-stream",
                    "CacheControl": "public, max-age=31536000, immutable",
                },
            )
        finally:
            temp_path.unlink(missing_ok=True)
        return StoredMedia(name=object_name, url=f"{self.public_url}/{key}")


def configured_media_storage() -> MediaStorage:
    backend = os.getenv("MEDIA_STORAGE_BACKEND", "local").strip().lower()
    if backend in {"", "local", "disk"}:
        return LocalMediaStorage()
    if backend in {"r2", "cloudflare_r2", "cloudflare"}:
        return R2MediaStorage()
    raise HTTPException(
        status_code=500,
        detail=f"Unknown media backend: {backend}",
    )


def _write_upload_with_limit(file: UploadFile, path: Path, max_bytes: int) -> int:
    bytes_written = 0
    with path.open("wb") as output:
        while chunk := file.file.read(1024 * 1024):
            bytes_written += len(chunk)
            if bytes_written > max_bytes:
                output.close()
                path.unlink(missing_ok=True)
                _raise_file_too_large(max_bytes)
            output.write(chunk)
    return bytes_written


def _write_upload_to_temp_file(file: UploadFile, max_bytes: int) -> Path:
    bytes_written = 0
    with NamedTemporaryFile(delete=False) as output:
        temp_path = Path(output.name)
        try:
            while chunk := file.file.read(1024 * 1024):
                bytes_written += len(chunk)
                if bytes_written > max_bytes:
                    output.close()
                    temp_path.unlink(missing_ok=True)
                    _raise_file_too_large(max_bytes)
                output.write(chunk)
        except Exception:
            temp_path.unlink(missing_ok=True)
            raise
    return temp_path


def _raise_file_too_large(max_bytes: int) -> None:
    limit_mb = max_bytes // (1024 * 1024)
    raise HTTPException(
        status_code=413,
        detail=f"File is too large. Limit is {limit_mb} MB.",
    )


def _required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if value:
        return value
    raise HTTPException(
        status_code=500,
        detail=f"Missing environment variable: {name}",
    )


def _r2_endpoint_url() -> str:
    configured = os.getenv("CLOUDFLARE_R2_ENDPOINT_URL", "").strip().rstrip("/")
    if configured:
        return configured
    account_id = _required_env("CLOUDFLARE_R2_ACCOUNT_ID")
    return f"https://{account_id}.r2.cloudflarestorage.com"
