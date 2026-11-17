from dataclasses import replace
from fractions import Fraction
from io import BytesIO
import json
from pathlib import Path
from types import SimpleNamespace
import subprocess
import sys
from urllib.parse import parse_qs, urlparse

import pytest

from app.core import video_validation as validation
from app.core.media_storage import PrivateChatR2Storage, StoredObjectMetadata


@pytest.fixture(autouse=True)
def isolated_database(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)


def make_clip(path, *, seconds=2, audio=False):
    import av
    with av.open(str(path), mode="w", format="mp4") as output:
        video = output.add_stream("libx264", rate=12)
        video.width, video.height, video.pix_fmt = 320, 240, "yuv420p"
        stream = output.add_stream("aac", rate=48000) if audio else None
        if stream is not None:
            stream.layout = "stereo"
        for _ in range(seconds * 12):
            frame = av.VideoFrame(320, 240, format="yuv420p")
            for index, plane in enumerate(frame.planes):
                plane.update(bytes([40 if index == 0 else 128]) * plane.buffer_size)
            for packet in video.encode(frame):
                output.mux(packet)
        for packet in video.encode():
            output.mux(packet)
        if audio:
            for offset in range(0, seconds * 48000, 1024):
                frame = av.AudioFrame(format="fltp", layout="stereo", samples=1024)
                frame.sample_rate, frame.pts, frame.time_base = 48000, offset, Fraction(1, 48000)
                for plane in frame.planes:
                    plane.update(bytes(plane.buffer_size))
                for packet in stream.encode(frame):
                    output.mux(packet)
            for packet in stream.encode():
                output.mux(packet)
    return Path(path)


@pytest.fixture
def clip(tmp_path):
    return make_clip(tmp_path / "generated.mp4")


def test_real_isolated_decoder_accepts_generated_clip(clip):
    result = validation._run_worker(clip)
    assert result == {"duration_seconds": 2.0, "width": 320, "height": 240, "frame_count": 24}


def test_real_isolated_decoder_checks_audio_and_video(tmp_path):
    result = validation._run_worker(make_clip(tmp_path / "audio.mp4", audio=True))
    assert 2 <= result["duration_seconds"] <= 2.1
    assert result["frame_count"] == 24


def test_real_decoder_rejects_long_clip_before_bunny(tmp_path):
    with pytest.raises(ValueError, match="30 seconds"):
        validation._run_worker(make_clip(tmp_path / "long.mp4", seconds=31))


def test_decoded_timing_rejects_forged_duration_labels(tmp_path):
    path = make_clip(tmp_path / "forged.mp4", seconds=31)
    data = bytearray(path.read_bytes())
    for atom in (b"mvhd", b"mdhd"):
        cursor = 0
        while (index := data.find(atom, cursor)) >= 0:
            assert data[index + 4] == 0  # Generated ISO-BMFF version-0 timing boxes.
            scale = int.from_bytes(data[index + 16:index + 20], "big")
            data[index + 20:index + 24] = scale.to_bytes(4, "big")
            cursor = index + 24
    path.write_bytes(data)
    with pytest.raises(ValueError, match="30 seconds"):
        validation._run_worker(path)


def test_invalid_file_fails_closed(tmp_path):
    path = tmp_path / "bad.mp4"
    path.write_bytes(b"not a video")
    with pytest.raises(ValueError, match="could not be verified"):
        validation._run_worker(path)


def test_decoded_frame_and_dimension_caps(clip, monkeypatch):
    monkeypatch.setattr(validation, "MAX_VIDEO_FRAMES", 2)
    with pytest.raises(validation._InvalidVideo, match="duration"):
        validation._decode_file(str(clip))
    monkeypatch.setattr(validation, "MAX_VIDEO_FRAMES", 3660)
    monkeypatch.setattr(validation, "MAX_PIXELS", 100)
    with pytest.raises(validation._InvalidVideo, match="dimensions"):
        validation._decode_file(str(clip))


class _Storage:
    def __init__(self, clip):
        self.data = clip.read_bytes()
        self.metadata = StoredObjectMetadata(len(self.data), "video/mp4", '"' + 'a' * 32 + '"')
        self.downloads = 0
        self.saved_path = None

    def object_metadata(self, name):
        assert name == "staging/owned.mp4"
        return self.metadata

    def download_for_validation(self, name, output, metadata):
        assert name == "staging/owned.mp4" and metadata is self.metadata
        self.downloads += 1
        self.saved_path = Path(output.name)
        output.write(self.data)


def test_staged_validation_binds_exact_bytes_type_and_etag_and_cleans_temp(clip):
    storage = _Storage(clip)
    result = validation.validate_staged_video(storage, "staging/owned.mp4", len(storage.data), "video/mp4")
    assert result.etag == storage.metadata.etag and result.duration_seconds == 2
    assert storage.downloads == 1 and not storage.saved_path.exists()


@pytest.mark.parametrize("change", ["size", "type", "etag"])
def test_metadata_mismatch_never_downloads_or_decodes(clip, change):
    storage = _Storage(clip)
    storage.metadata = replace(storage.metadata, **{
        "size": {"size": 123}, "type": {"content_type": "image/jpeg"}, "etag": {"etag": None},
    }[change])
    with pytest.raises(ValueError, match="reservation"):
        validation.validate_staged_video(storage, "staging/owned.mp4", len(storage.data), "video/mp4")
    assert storage.downloads == 0


def test_busy_validator_returns_without_metadata_request(clip):
    storage = _Storage(clip)
    validation._slot.acquire()
    try:
        with pytest.raises(validation.ValidationBusy):
            validation.validate_staged_video(storage, "staging/owned.mp4", len(storage.data), "video/mp4")
    finally:
        validation._slot.release()
    assert storage.downloads == 0


def test_subprocess_receives_no_service_secrets(clip, monkeypatch):
    captured = {}
    original = validation.subprocess.Popen
    def launch(*args, **kwargs):
        captured.update(kwargs)
        return original(*args, **kwargs)
    monkeypatch.setenv("CHAT_BUNNY_STREAM_API_KEY", "fixture-secret-never-forward")
    monkeypatch.setenv("DATABASE_URL", "fixture-database-never-forward")
    monkeypatch.setattr(validation.subprocess, "Popen", launch)
    assert validation._run_worker(clip)["frame_count"] == 24
    assert "CHAT_BUNNY_STREAM_API_KEY" not in captured["env"]
    assert "DATABASE_URL" not in captured["env"]
    assert captured["close_fds"] is True
    assert captured["stderr"] == validation.subprocess.DEVNULL


def test_worker_limits_are_mandatory_on_production_linux(monkeypatch):
    import resource
    limits = []
    monkeypatch.setattr(validation.sys, "platform", "linux")
    monkeypatch.setattr(resource, "setrlimit", lambda *args: limits.append(args))
    validation._worker_limits()
    assert (resource.RLIMIT_AS, (384 * 1024 * 1024,) * 2) in limits
    assert (resource.RLIMIT_CPU, (20, 21)) in limits
    assert (resource.RLIMIT_FSIZE, (0, 0)) in limits


def test_private_signed_put_is_exact_length_type_and_create_only(monkeypatch):
    monkeypatch.setenv("CHAT_R2_PRIVATE_VERIFIED", "true")
    monkeypatch.setenv("CHAT_R2_PRIVATE_BUCKET", "private-fixture")
    monkeypatch.setenv("CLOUDFLARE_R2_BUCKET", "public-fixture")
    monkeypatch.setenv("CHAT_R2_ACCESS_KEY_ID", "fixture-id")
    monkeypatch.setenv("CHAT_R2_SECRET_ACCESS_KEY", "fixture-secret")
    monkeypatch.setenv("CHAT_R2_ENDPOINT_URL", "https://fixture.r2.cloudflarestorage.com")
    storage = PrivateChatR2Storage()
    signed = storage.create_direct_upload_url("video/source.mp4", content_type="video/mp4", content_length=3582, expires_seconds=900)
    query = parse_qs(urlparse(signed).query)
    assert {"content-length", "content-type", "if-none-match", "host"} <= set(query["X-Amz-SignedHeaders"][0].split(";"))
    assert query["X-Amz-Expires"] == ["900"]
    read = parse_qs(urlparse(storage.signed_read_url("video/source.mp4", expires_seconds=600, etag='"etag"')).query)
    assert "if-match" in read["X-Amz-SignedHeaders"][0].split(";")


@pytest.mark.parametrize("actual,declared", [(b"tiny", 4), (b"toolong", 4), (b"short", 8)])
def test_validation_download_is_bounded_and_etag_conditional(actual, declared):
    body = BytesIO(actual)
    requests = []
    def get(**kwargs):
        requests.append(kwargs)
        return {"Body": body, "ContentLength": declared, "ETag": '"etag"'}
    storage = PrivateChatR2Storage.__new__(PrivateChatR2Storage)
    storage.bucket, storage.prefix, storage._client = "private-fixture", "chat", SimpleNamespace(get_object=get)
    output = BytesIO()
    metadata = StoredObjectMetadata(declared, "video/mp4", '"etag"')
    if len(actual) == declared:
        storage.download_for_validation("owned/source.mp4", output, metadata)
        assert output.getvalue() == actual
    else:
        with pytest.raises(ValueError):
            storage.download_for_validation("owned/source.mp4", output, metadata)
        assert len(output.getvalue()) <= declared
    assert body.closed
    assert requests == [{"Bucket": "private-fixture", "Key": "chat/owned/source.mp4", "IfMatch": '"etag"'}]


def test_oversized_source_never_starts_download():
    storage = PrivateChatR2Storage.__new__(PrivateChatR2Storage)
    with pytest.raises(ValueError):
        storage.download_for_validation("x", BytesIO(), StoredObjectMetadata(50 * 1024 * 1024 + 1, "video/mp4", '"etag"'))


@pytest.mark.parametrize("returned", [{"ContentLength": 9, "ETag": '"etag"'},
                                      {"ContentLength": 4, "ETag": '"changed"'}])
def test_changed_download_headers_close_body_without_writing(returned):
    body = BytesIO(b"data")
    storage = PrivateChatR2Storage.__new__(PrivateChatR2Storage)
    storage.bucket, storage.prefix = "private-fixture", "chat"
    storage._client = SimpleNamespace(get_object=lambda **_: {**returned, "Body": body})
    output = BytesIO()
    with pytest.raises(ValueError, match="changed"):
        storage.download_for_validation("owned", output, StoredObjectMetadata(4, "video/mp4", '"etag"'))
    assert body.closed and output.getvalue() == b""


@pytest.mark.parametrize("child", ["import time; time.sleep(60)", "print('x'*8000)"])
def test_worker_timeout_and_output_bomb_are_killed_and_reaped(clip, monkeypatch, child):
    processes = []
    original = subprocess.Popen
    def start(*args, **kwargs):
        process = original([sys.executable, "-c", child], **kwargs)
        processes.append(process)
        return process
    monkeypatch.setattr(validation.subprocess, "Popen", start)
    monkeypatch.setattr(validation, "WALL_SECONDS", 0.15)
    with pytest.raises(ValueError):
        validation._run_worker(clip)
    assert len(processes) == 1 and processes[0].poll() is not None


@pytest.mark.parametrize("failure", ["unlock", "close"])
def test_database_cleanup_error_does_not_strand_validation_slot(monkeypatch, failure):
    class Connection:
        def execute(self, sql, params):
            if "unlock" in sql and failure == "unlock":
                raise RuntimeError("offline cleanup failure")
            return SimpleNamespace(fetchone=lambda: (True,))
        def close(self):
            if failure == "close":
                raise RuntimeError("offline close failure")
    monkeypatch.setenv("DATABASE_URL", "fixture-only")
    monkeypatch.setitem(sys.modules, "psycopg", SimpleNamespace(connect=lambda *a, **kw: Connection()))
    for _ in range(2):
        with validation._validation_slot():
            pass


def test_common_decoded_timeline_rejects_forged_audio_offset(monkeypatch):
    video_context = SimpleNamespace(name="h264", width=320, height=240, thread_count=0, options={})
    audio_context = SimpleNamespace(name="aac", sample_rate=48000, channels=2, thread_count=0, options={})
    video = SimpleNamespace(type="video", codec_context=video_context, duration=2, time_base=Fraction(1))
    audio = SimpleNamespace(type="audio", codec_context=audio_context, duration=2, time_base=Fraction(1))
    video_frame = SimpleNamespace(pts=0, time_base=Fraction(1), duration=2, width=320, height=240)
    audio_frame = SimpleNamespace(pts=40, time_base=Fraction(1), samples=1024)
    class Container:
        duration = 2_000_000
        streams = SimpleNamespace(video=[video], audio=[audio])
        def __enter__(self): return self
        def __exit__(self, *args): return False
        def demux(self, streams):
            return [SimpleNamespace(stream=video, decode=lambda: [video_frame]),
                    SimpleNamespace(stream=audio, decode=lambda: [audio_frame])]
    class Streams(list):
        pass
    streams = Streams([video, audio])
    streams.video, streams.audio = [video], [audio]
    Container.streams = streams
    fake = SimpleNamespace(open=lambda *args, **kwargs: Container(), time_base=1_000_000,
                           logging=SimpleNamespace(PANIC=0, set_level=lambda *_: None))
    monkeypatch.setitem(sys.modules, "av", fake)
    with pytest.raises(validation._InvalidVideo, match="duration"):
        validation._decode_file("not-opened-by-fixture")
