from __future__ import annotations

import os
from pathlib import Path
import shutil


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def csv_env(name: str, default: str = "") -> list[str]:
    raw_value = os.getenv(name, default)
    return [item.strip() for item in raw_value.split(",") if item.strip()]


def public_backend_url() -> str:
    return os.getenv("PUBLIC_BACKEND_URL", "http://127.0.0.1:8000").strip().rstrip("/")


def public_media_url(filename: str) -> str:
    return f"{public_backend_url()}/media/{filename.lstrip('/')}"


def media_storage_backend() -> str:
    return os.getenv("MEDIA_STORAGE_BACKEND", "local").strip().lower()


def uses_local_media_storage() -> bool:
    return media_storage_backend() in {"", "local", "disk"}


def is_legacy_backend_media_url(url: str) -> bool:
    media_prefix = f"{public_backend_url()}/media/"
    return url.strip().startswith(media_prefix)


def data_dir_path() -> Path:
    return Path(os.getenv("TYDES_DATA_DIR", str(PROJECT_ROOT / "data"))).expanduser()


def media_dir_path() -> Path:
    return Path(os.getenv("TYDES_MEDIA_DIR", str(data_dir_path() / "media"))).expanduser()


def seed_media_dir_path() -> Path:
    return PROJECT_ROOT / "app" / "seed_media"


def sync_seed_media_files() -> None:
    source_dir = seed_media_dir_path()
    target_dir = media_dir_path()
    if not source_dir.exists():
        return

    target_dir.mkdir(parents=True, exist_ok=True)
    for source_file in source_dir.iterdir():
        if not source_file.is_file():
            continue
        target_file = target_dir / source_file.name
        if target_file.exists():
            continue
        shutil.copy2(source_file, target_file)


def state_file_path() -> Path:
    return Path(
        os.getenv("TYDES_STATE_FILE", str(data_dir_path() / "demo_state.json"))
    ).expanduser()
