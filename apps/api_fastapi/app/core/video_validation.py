"""Bounded, isolated validation before any paid video ingestion is requested.

Untrusted clips are decoded in a separate process with no application secrets.
Only one validator runs per service/database. There is no client-selected URL,
shell command, codec, encoding option, or Bunny upload credential in this path.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import BoundedSemaphore
import time

MAX_SOURCE_BYTES = 50 * 1024 * 1024
MAX_SECONDS = 30.5
MAX_EDGE = 4096
MAX_PIXELS = 4096 * 2160
MAX_VIDEO_FRAMES = 3660
MAX_AUDIO_FRAMES = 6000
MAX_PACKETS = 20_000
CPU_SECONDS = 20
WALL_SECONDS = 25
MEMORY_BYTES = 384 * 1024 * 1024
_slot = BoundedSemaphore(1)
_DATABASE_SLOT = 1_982_910_251
_TYPES = {"video/mp4", "video/quicktime", "video/x-m4v"}


class ValidationBusy(Exception):
    pass


class VideoValidationUnavailable(Exception):
    pass


@dataclass(frozen=True)
class ValidatedVideo:
    etag: str
    duration_seconds: float
    width: int
    height: int
    frame_count: int


def is_available() -> bool:
    return os.name == "posix" and importlib.util.find_spec("av") is not None


@contextmanager
def _validation_slot():
    if not _slot.acquire(blocking=False):
        raise ValidationBusy()
    connection = None
    locked = False
    try:
        database_url = os.getenv("DATABASE_URL", "").strip()
        if database_url:
            import psycopg
            connection = psycopg.connect(database_url, connect_timeout=3)
            locked = bool(connection.execute(
                "SELECT pg_try_advisory_lock(%s)", (_DATABASE_SLOT,),
            ).fetchone()[0])
            if not locked:
                raise ValidationBusy()
        yield
    except ValidationBusy:
        raise
    except (ValueError, VideoValidationUnavailable):
        raise
    except Exception:
        raise VideoValidationUnavailable() from None
    finally:
        try:
            if connection is not None:
                try:
                    if locked:
                        connection.execute("SELECT pg_advisory_unlock(%s)", (_DATABASE_SLOT,))
                except Exception:
                    pass  # Closing the session also releases its advisory lock.
                finally:
                    try:
                        connection.close()
                    except Exception:
                        pass
        finally:
            _slot.release()


def validate_staged_video(storage, source_name: str, expected_bytes: int,
                          content_type: str) -> ValidatedVideo:
    if content_type not in _TYPES or not 0 < expected_bytes <= MAX_SOURCE_BYTES:
        raise ValueError("Choose an MP4 or MOV video no larger than 50 MB.")
    if not is_available():
        raise VideoValidationUnavailable()
    with _validation_slot():
        metadata = storage.object_metadata(source_name)
        if (metadata.size != expected_bytes
                or metadata.content_type.split(";")[0].lower() != content_type
                or not isinstance(metadata.etag, str)
                or not re.fullmatch(r'"[0-9a-fA-F]{32}(?:-[1-9][0-9]*)?"', metadata.etag)):
            raise ValueError("Uploaded video does not match its reservation.")
        with TemporaryDirectory(prefix="tydes-video-check-") as directory:
            path = Path(directory) / "source.mp4"
            with path.open("wb") as output:
                storage.download_for_validation(source_name, output, metadata)
            result = _run_worker(path)
        return ValidatedVideo(etag=metadata.etag, **result)


def _run_worker(path: Path) -> dict:
    # No API keys, session secrets, proxy settings, Python path, or inherited FDs.
    environment = {"LANG": "C", "LC_ALL": "C", "OMP_NUM_THREADS": "1",
                   "OPENBLAS_NUM_THREADS": "1", "PATH": "/usr/bin:/bin"}
    command = [sys.executable, "-I", str(Path(__file__).resolve()), "--worker", str(path)]
    with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env=environment,
                          cwd=path.parent, close_fds=True) as process:
        selector = selectors.DefaultSelector()
        output = bytearray()
        deadline = time.monotonic() + WALL_SECONDS
        try:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("Video is too complex to verify. Re-export it at 1080p or lower.")
                for key, _ in selector.select(min(remaining, 0.2)):
                    chunk = os.read(key.fileobj.fileno(), 4097 - len(output))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output.extend(chunk)
                        if len(output) > 4096:
                            raise ValueError("Video could not be verified. Choose a different file.")
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise ValueError("Video took too long to verify. Re-export it at 1080p or lower.") from None
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
        try:
            report = json.loads(output)
        except (ValueError, UnicodeError):
            raise ValueError("Video could not be verified. Re-export it as an MP4 or MOV.") from None
        if not isinstance(report, dict):
            raise ValueError("Video verification returned invalid metadata.")
        if process.returncode != 0 or report.get("ok") is not True:
            message = {
                "duration": "Videos must be no longer than 30 seconds.",
                "dimensions": "Video is too large to process. Re-export at 4K or lower.",
                "format": "This video format is not supported. Re-export as H.264 or HEVC MP4/MOV.",
            }.get(report.get("error"), "Video could not be verified. Re-export it as an MP4 or MOV.")
            raise ValueError(message)
        result = {key: report.get(key) for key in
                  ("duration_seconds", "width", "height", "frame_count")}
        if (not isinstance(result["duration_seconds"], (int, float))
                or isinstance(result["duration_seconds"], bool)
                or not math.isfinite(result["duration_seconds"])
                or not 0 < result["duration_seconds"] <= MAX_SECONDS
                or not all(isinstance(result[key], int) and not isinstance(result[key], bool)
                           for key in ("width", "height", "frame_count"))
                or not 0 < result["frame_count"] <= MAX_VIDEO_FRAMES
                or not _dimensions_allowed(result["width"], result["height"])):
            raise ValueError("Video verification returned invalid metadata.")
        return result


def _dimensions_allowed(width: int, height: int) -> bool:
    return 0 < width <= MAX_EDGE and 0 < height <= MAX_EDGE and width * height <= MAX_PIXELS


class _InvalidVideo(Exception):
    pass


def _reject(code: str):
    raise _InvalidVideo(code)


def _worker_limits():
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (CPU_SECONDS, CPU_SECONDS + 1))
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
    resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    if sys.platform.startswith("linux"):
        # macOS virtual mappings differ; production Render/Linux is fail-closed.
        resource.setrlimit(resource.RLIMIT_AS, (MEMORY_BYTES, MEMORY_BYTES))


def _decode_file(path: str) -> dict:
    import av
    av.logging.set_level(av.logging.PANIC)
    with av.open(path, mode="r", format="mov", options={
        "protocol_whitelist": "file", "enable_drefs": "0", "use_absolute_path": "0",
        "probesize": "1048576", "analyzeduration": "5000000", "max_probe_packets": "1000",
    }) as container:
        videos = list(container.streams.video)
        audios = list(container.streams.audio)
        if len(container.streams) > 8 or len(videos) != 1 or len(audios) > 1:
            _reject("format")
        video = videos[0]
        if video.codec_context.name not in {"h264", "hevc"}:
            _reject("format")
        if not _dimensions_allowed(video.codec_context.width, video.codec_context.height):
            _reject("dimensions")
        if container.duration is None or not 0 < container.duration / av.time_base <= MAX_SECONDS:
            _reject("duration")
        streams = [video, *audios]
        durations = []
        for stream in streams:
            context = stream.codec_context
            context.thread_count = 1
            context.options = {**context.options, "max_pixels": str(MAX_PIXELS)}
            if stream.duration is None or stream.time_base is None:
                _reject("duration")
            duration = float(stream.duration * stream.time_base)
            if not math.isfinite(duration) or not 0 < duration <= MAX_SECONDS:
                _reject("duration")
            durations.append(duration)
            if stream.type == "audio" and (context.name not in {"aac", "mp3", "alac", "pcm_s16le", "pcm_s24le"}
                    or not 0 < context.sample_rate <= 96000 or not 0 < context.channels <= 2):
                _reject("format")
        video_count = audio_count = packet_count = 0
        audio_samples = 0
        starts, ends, previous = {}, {}, {}
        max_width = max_height = 0
        for packet in container.demux(streams):
            packet_count += 1
            if packet_count > MAX_PACKETS:
                _reject("duration")
            for frame in packet.decode():
                kind = packet.stream.type
                if frame.pts is None or frame.time_base is None:
                    _reject("duration")
                stamp = float(frame.pts * frame.time_base)
                if not math.isfinite(stamp) or abs(stamp) > 3600:
                    _reject("duration")
                if kind in previous and stamp < previous[kind] - 0.001:
                    _reject("duration")
                previous[kind] = stamp
                starts.setdefault(kind, stamp)
                if kind == "video":
                    video_count += 1
                    if video_count > MAX_VIDEO_FRAMES:
                        _reject("duration")
                    if not _dimensions_allowed(frame.width, frame.height):
                        _reject("dimensions")
                    max_width, max_height = max(max_width, frame.width), max(max_height, frame.height)
                    frame_duration = float(frame.duration * frame.time_base) if frame.duration else 0
                else:
                    audio_count += 1
                    if audio_count > MAX_AUDIO_FRAMES or not 0 < frame.samples <= 8192:
                        _reject("duration")
                    audio_samples += frame.samples
                    if audio_samples > math.ceil(MAX_SECONDS * packet.stream.codec_context.sample_rate):
                        _reject("duration")
                    frame_duration = frame.samples / packet.stream.codec_context.sample_rate
                if not math.isfinite(frame_duration) or frame_duration < 0 or frame_duration > MAX_SECONDS:
                    _reject("duration")
                end = stamp + frame_duration
                ends[kind] = max(ends.get(kind, end), end)
                if ends[kind] - starts[kind] > MAX_SECONDS + 0.001:
                    _reject("duration")
        if video_count < 1 or (audios and audio_count < 1):
            _reject("format")
        # A forged duration label must not conceal a large audio/video offset.
        common_timeline = max(ends.values()) - min(starts.values())
        actual_duration = max([*durations, common_timeline,
                               *(ends[k] - starts[k] for k in ends)])
        if actual_duration <= 0 or actual_duration > MAX_SECONDS:
            _reject("duration")
        return {"ok": True, "duration_seconds": actual_duration, "width": max_width,
                "height": max_height, "frame_count": video_count}


def _worker_main(path: str) -> int:
    try:
        _worker_limits()
        if not 0 < Path(path).stat().st_size <= MAX_SOURCE_BYTES:
            _reject("format")
        report = _decode_file(path)
    except _InvalidVideo as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 1
    except BaseException:
        print(json.dumps({"ok": False, "error": "invalid"}))
        return 1
    print(json.dumps(report, allow_nan=False))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--worker":
        raise SystemExit(2)
    raise SystemExit(_worker_main(sys.argv[2]))
