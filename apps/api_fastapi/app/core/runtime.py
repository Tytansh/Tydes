from __future__ import annotations

import os
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def csv_env(name: str, default: str = "") -> list[str]:
    raw_value = os.getenv(name, default)
    return [item.strip() for item in raw_value.split(",") if item.strip()]


def public_backend_url() -> str:
    return os.getenv("PUBLIC_BACKEND_URL", "http://127.0.0.1:8000").strip().rstrip("/")


def public_media_url(filename: str) -> str:
    return f"{public_backend_url()}/media/{filename.lstrip('/')}"


def data_dir_path() -> Path:
    return Path(os.getenv("TYDES_DATA_DIR", str(PROJECT_ROOT / "data"))).expanduser()


def media_dir_path() -> Path:
    return Path(os.getenv("TYDES_MEDIA_DIR", str(data_dir_path() / "media"))).expanduser()


def state_file_path() -> Path:
    return Path(
        os.getenv("TYDES_STATE_FILE", str(data_dir_path() / "demo_state.json"))
    ).expanduser()
