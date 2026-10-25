from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from tempfile import NamedTemporaryFile
from threading import Lock

from fastapi import HTTPException, UploadFile

from app.core.runtime import media_dir_path


@dataclass(frozen=True)
class StoredMedia:
    name: str
    url: str


@dataclass(frozen=True)
class StoredObjectMetadata:
    size: int
    content_type: str


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

    def public_object_url(self, object_name: str) -> str:
        return f"{self.public_url}/{self._key(object_name)}"

    def create_direct_upload_url(
        self,
        object_name: str,
        *,
        content_type: str,
        content_length: int,
        expires_seconds: int,
    ) -> str:
        self.ensure_direct_upload_cors()
        return self.client.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": self.bucket,
                "Key": self._key(object_name),
                "ContentType": content_type,
                "ContentLength": content_length,
                "IfNoneMatch": "*",
            },
            ExpiresIn=expires_seconds,
            HttpMethod="PUT",
        )

    def object_metadata(self, object_name: str) -> StoredObjectMetadata:
        response = self.client.head_object(
            Bucket=self.bucket,
            Key=self._key(object_name),
        )
        return StoredObjectMetadata(
            size=int(response.get("ContentLength", 0)),
            content_type=str(response.get("ContentType") or "application/octet-stream"),
        )

    def read_object_range(self, object_name: str, start: int, end: int) -> bytes:
        response = self.client.get_object(
            Bucket=self.bucket,
            Key=self._key(object_name),
            Range=f"bytes={start}-{end}",
        )
        return bytes(response["Body"].read())

    def promote_object(
        self,
        pending_name: str,
        final_name: str,
        *,
        content_type: str,
    ) -> None:
        self.client.copy_object(
            Bucket=self.bucket,
            Key=self._key(final_name),
            CopySource={"Bucket": self.bucket, "Key": self._key(pending_name)},
            ContentType=content_type,
            CacheControl="public, max-age=31536000, immutable",
            MetadataDirective="REPLACE",
        )
        self.delete_object(pending_name)

    def delete_object(self, object_name: str | None) -> None:
        if object_name is None:
            return
        self.client.delete_object(Bucket=self.bucket, Key=self._key(object_name))

    def ensure_direct_upload_cors(self) -> None:
        cache_key = (self.bucket, _r2_endpoint_url())
        with _R2_CORS_LOCK:
            if cache_key in _R2_CORS_CONFIGURED:
                return
            origins = [
                item.strip().rstrip("/")
                for item in os.getenv("ALLOWED_ORIGINS", "").split(",")
                if item.strip() and item.strip() != "*"
            ]
            if not origins:
                raise HTTPException(
                    status_code=503,
                    detail="Direct uploads need explicit allowed web origins.",
                )
            try:
                current = self.client.get_bucket_cors(Bucket=self.bucket)
                rules = list(current.get("CORSRules") or [])
            except Exception as error:
                error_code = str(
                    getattr(error, "response", {})
                    .get("Error", {})
                    .get("Code", "")
                )
                if error_code not in {
                    "NoSuchCORSConfiguration",
                    "NoSuchCORS",
                    "404",
                }:
                    raise HTTPException(
                        status_code=503,
                        detail="Could not verify secure browser upload settings.",
                    ) from error
                rules = []
            rules = [
                rule for rule in rules if rule.get("ID") != "tydes-direct-uploads"
            ]
            rules.append(
                {
                    "ID": "tydes-direct-uploads",
                    "AllowedHeaders": ["content-type", "if-none-match"],
                    "AllowedMethods": ["PUT"],
                    "AllowedOrigins": sorted(set(origins)),
                    "ExposeHeaders": ["etag"],
                    "MaxAgeSeconds": 3600,
                }
            )
            try:
                self.client.put_bucket_cors(
                    Bucket=self.bucket,
                    CORSConfiguration={"CORSRules": rules},
                )
            except Exception as error:
                raise HTTPException(
                    status_code=503,
                    detail="Could not configure secure browser uploads.",
                ) from error
            _R2_CORS_CONFIGURED.add(cache_key)

    def _key(self, object_name: str) -> str:
        return f"{self.prefix}/{object_name}" if self.prefix else object_name


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


_R2_CORS_CONFIGURED: set[tuple[str, str]] = set()
_R2_CORS_LOCK = Lock()
