#!/usr/bin/env python3
"""Serve an NVIDIA Parakeet speech model to the local voice pipeline.

The harness's ``voice-local`` compose stack runs this beside Kokoro as
the speech-to-text half of its local pipeline.  One process loads one
NVIDIA Parakeet TDT 0.6B model with sherpa-onnx and keeps it in memory,
then answers the two request shapes the harness already speaks:

    POST /inference                whisper.cpp's multipart form
    POST /v1/audio/transcriptions  the OpenAI audio route
                                   -> {"text": "..."}

Both take one WAV upload in a ``file`` field and answer JSON with a
``text`` field, so the local sidecar and ``scripts/harness-voice-stt``
work with Parakeet without a change.  ``GET /health`` answers while the
model is loaded.

The model is a directory of the sherpa-onnx model zoo.  ``PARAKEET_MODEL``
names it and ``PARAKEET_MODELS`` is where it lives; a missing model is
downloaded there on first start unless ``PARAKEET_DOWNLOAD=0``.  All
audio stays on this machine, and the server needs no key.

    server.py --models-dir /models --model sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8

Run it with ``--self-test`` to check the routes without a model, a
microphone or a network.
"""

from __future__ import annotations

import argparse
import array
import http.client
import io
import json
import os
import re
import shutil
import socket
import sys
import tarfile
import tempfile
import threading
import traceback
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

DEFAULT_MODEL = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
DEFAULT_FEATURE_DIM = 80
SAMPLE_RATE = 16000
#: Where the sherpa-onnx project publishes its converted models.
MODEL_BASE_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
#: The files a complete int8 transducer model directory holds.
MODEL_FILES = ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")
#: The harness's own upload limit; a sidecar utterance is far smaller.
MAX_AUDIO_BYTES = 32 * 1024 * 1024
#: The multipart envelope around that upload.
MAX_BODY_BYTES = MAX_AUDIO_BYTES + 1024 * 1024
#: Long enough for a slow first download, short enough to fail visibly.
MODEL_DOWNLOAD_TIMEOUT = 120


def log(message):
    """Write one line to stderr, where the container's log shows it."""
    print("voice-local parakeet: " + message, file=sys.stderr, flush=True)


class ModelError(Exception):
    """A model directory that is missing and cannot be completed."""


class RequestError(Exception):
    """A request the server refuses, with its HTTP status and reason."""

    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status
        self.reason = reason


#; ------------------------------------------------------------------
#; The model
#; ------------------------------------------------------------------


def model_ready(directory):
    """Return whether DIRECTORY holds a complete model."""
    return all((directory / name).is_file() for name in MODEL_FILES)


def extract_archive(path, destination):
    """Extract the model archive at PATH into DESTINATION, safely."""
    with tarfile.open(path, "r:bz2") as archive:
        try:
            # Refuse members that leave the destination (Python 3.12+).
            archive.extractall(destination, filter="data")
        except TypeError:  # pragma: no cover - Python before 3.12
            archive.extractall(destination)


#: What a failed download or unpack may raise, so it is reported as a
#: model error rather than a traceback.
DOWNLOAD_ERRORS = (OSError, ValueError, tarfile.TarError) + (
    (tarfile.FilterError,) if hasattr(tarfile, "FilterError") else ())


def ensure_model(models_dir, name, download=True):
    """Return the model directory NAME under MODELS_DIR, downloading it once.

    A complete directory is used as it stands.  Otherwise the model's
    tar.bz2 is fetched from the sherpa-onnx releases and unpacked beside
    it; ``PARAKEET_MODEL_URL`` names a mirror with the same layout, and
    DOWNLOAD nil (``PARAKEET_DOWNLOAD=0``) refuses the fetch and says
    what is missing.
    """
    models_dir = Path(models_dir)
    directory = models_dir / name
    if model_ready(directory):
        return directory
    if not download:
        raise ModelError("%s missing and download disabled" % name)
    base = (os.environ.get("PARAKEET_MODEL_URL") or MODEL_BASE_URL).rstrip("/")
    url = "%s/%s.tar.bz2" % (base, name)
    models_dir.mkdir(parents=True, exist_ok=True)
    log("downloading %s" % url)
    handle, archive_path = tempfile.mkstemp(prefix=name + "-", suffix=".tar.bz2", dir=models_dir)
    os.close(handle)
    try:
        with urllib.request.urlopen(url, timeout=MODEL_DOWNLOAD_TIMEOUT) as response:
            with open(archive_path, "wb") as archive_file:
                shutil.copyfileobj(response, archive_file, length=1024 * 1024)
        log("unpacking %s" % name)
        extract_archive(archive_path, models_dir)
    except DOWNLOAD_ERRORS as exc:
        raise ModelError("model download failed: %s" % exc) from exc
    finally:
        try:
            os.unlink(archive_path)
        except OSError:
            pass
    if not model_ready(directory):
        raise ModelError("%s incomplete after download" % name)
    return directory


class Recognizer:
    """A loaded Parakeet model, decoding one utterance at a time.

    sherpa-onnx keeps one recognizer for the process and creates a stream
    per utterance.  The lock keeps two uploads from decoding at once;
    each decode is short relative to the audio, and a queue of them is
    cheaper than loading the 0.6B encoder twice.
    """

    def __init__(self, directory, feature_dim=DEFAULT_FEATURE_DIM, num_threads=2):
        try:
            import numpy
            import sherpa_onnx
        except ImportError as exc:  # pragma: no cover - the image installs both
            raise ModelError("sherpa-onnx unavailable: %s" % exc) from exc
        self.numpy = numpy
        self.lock = threading.Lock()
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(directory / "encoder.int8.onnx"),
            decoder=str(directory / "decoder.int8.onnx"),
            joiner=str(directory / "joiner.int8.onnx"),
            tokens=str(directory / "tokens.txt"),
            model_type="nemo_transducer",
            num_threads=num_threads,
            feature_dim=feature_dim,
            sample_rate=SAMPLE_RATE,
            decoding_method="greedy_search",
        )

    def transcribe(self, samples, sample_rate):
        """Return the text of SAMPLES, mono floats at SAMPLE-RATE."""
        audio = self.numpy.asarray(samples, dtype=self.numpy.float32)
        with self.lock:
            stream = self.recognizer.create_stream()
            # sherpa-onnx resamples to the model's rate when they differ.
            stream.accept_waveform(int(sample_rate), audio)
            self.recognizer.decode_stream(stream)
            return stream.result.text.strip()


#; ------------------------------------------------------------------
#; Uploads
#; ------------------------------------------------------------------


def parse_multipart(content_type, body):
    """Return (FIELDS, UPLOAD) from a multipart/form-data CONTENT-TYPE and BODY.

    FIELDS maps each non-file field name to its text, and UPLOAD is the
    first part with a filename, or nil.  The boundary a client sends is
    random, so its bytes do not occur in a WAV; the parser splits on it
    and keeps the last match of each field.
    """
    match = re.search(r'boundary="?([^";]+)"?', content_type or "", re.IGNORECASE)
    if not match:
        raise RequestError(400, "multipart boundary missing")
    delimiter = b"--" + match.group(1).encode("utf-8")
    fields = {}
    upload = None
    for chunk in body.split(delimiter):
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        if chunk in (b"", b"--", b"--\r\n"):
            continue
        head, separator, data = chunk.partition(b"\r\n\r\n")
        if not separator:
            continue
        if data.endswith(b"\r\n"):
            data = data[:-2]
        headers = {}
        for line in head.split(b"\r\n"):
            name, _, value = line.partition(b":")
            if name:
                headers[name.strip().lower()] = value.strip()
        disposition = headers.get(b"content-disposition", b"").decode("utf-8", "replace")
        field = re.search(r'name="([^"]*)"', disposition)
        if not field:
            continue
        if "filename=" in disposition:
            upload = data
        else:
            fields[field.group(1)] = data.decode("utf-8", "replace")
    return fields, upload


def raw_to_floats(raw, width):
    """Return RAW PCM samples as floats between -1 and 1, for sample WIDTH."""
    if width == 1:
        return [(byte - 128) / 128.0 for byte in raw]
    if width == 2:
        values = array.array("h")
        values.frombytes(raw)
        if sys.byteorder == "big":
            values.byteswap()
        return [value / 32768.0 for value in values]
    if width == 3:
        if len(raw) % 3:
            raise RequestError(400, "WAV sample width unsupported")
        samples = []
        for index in range(0, len(raw), 3):
            value = raw[index] | (raw[index + 1] << 8) | (raw[index + 2] << 16)
            if value & 0x800000:
                value -= 0x1000000
            samples.append(value / 8388608.0)
        return samples
    if width == 4:
        values = array.array("i")
        values.frombytes(raw)
        if sys.byteorder == "big":
            values.byteswap()
        return [value / 2147483648.0 for value in values]
    raise RequestError(400, "WAV sample width unsupported")


def wav_to_samples(data):
    """Return (MONO SAMPLES, RATE) from a WAV body.

    Channels are averaged, which is what a microphone and the harness
    send anyway; the rate is the file's, and sherpa-onnx resamples it.
    """
    try:
        with wave.open(io.BytesIO(data), "rb") as recording:
            channels = recording.getnchannels()
            width = recording.getsampwidth()
            rate = recording.getframerate()
            raw = recording.readframes(recording.getnframes())
    except (wave.Error, EOFError, ValueError) as exc:
        raise RequestError(400, "WAV audio unreadable") from exc
    if channels < 1 or rate <= 0 or not raw:
        raise RequestError(400, "WAV audio empty")
    values = raw_to_floats(raw, width)
    if channels > 1:
        values = [
            sum(values[index:index + channels]) / channels
            for index in range(0, len(values), channels)
        ]
    return values, rate


#; ------------------------------------------------------------------
#; HTTP
#; ------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    """The harness's speech routes over one loaded model."""

    server_version = "harness-voice-parakeet/1"

    def do_GET(self):
        path = urlsplit(self.path).path.rstrip("/") or "/"
        if path == "/health":
            self.send_json(200, {"status": "ok", "model": self.server.model_name})
        else:
            self.send_json(404, {"error": "unknown route"})

    def do_POST(self):
        path = urlsplit(self.path).path.rstrip("/") or "/"
        if path not in ("/inference", "/v1/audio/transcriptions"):
            return self.send_json(404, {"error": "unknown route"})
        try:
            fields, upload = self.read_upload()
            if upload is None:
                raise RequestError(400, "file field missing")
            if len(upload) > MAX_AUDIO_BYTES:
                raise RequestError(413, "audio too large")
            samples, rate = wav_to_samples(upload)
            text = self.server.recognizer.transcribe(samples, rate)
        except RequestError as exc:
            return self.send_json(exc.status, {"error": exc.reason})
        except Exception:
            traceback.print_exc()
            return self.send_json(500, {"error": "transcription failed"})
        if fields.get("response_format", "json") == "text":
            self.send_bytes(200, text.encode("utf-8"), "text/plain; charset=utf-8")
        else:
            self.send_json(200, {"text": text})

    def do_PUT(self):
        self.send_json(405, {"error": "method not allowed"})

    do_DELETE = do_PUT
    do_PATCH = do_PUT

    def read_upload(self):
        """Return (FIELDS, UPLOAD) from the request body."""
        length = self.headers.get("Content-Length")
        try:
            length = int(length or "")
        except ValueError:
            raise RequestError(411, "content length required")
        if length <= 0:
            raise RequestError(411, "content length required")
        if length > MAX_BODY_BYTES:
            raise RequestError(413, "upload too large")
        body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        if not content_type.lower().startswith("multipart/form-data"):
            raise RequestError(415, "multipart form required")
        return parse_multipart(content_type, body)

    def send_json(self, status, payload):
        """Answer STATUS with PAYLOAD as JSON."""
        self.send_bytes(status, json.dumps(payload).encode("utf-8"), "application/json")

    def send_bytes(self, status, body, content_type):
        """Answer STATUS with BODY of CONTENT-TYPE."""
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        log("%s %s" % (self.address_string(), format % args))


class Server(ThreadingHTTPServer):
    """A threading HTTP server around one recognizer."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, recognizer, model_name):
        super().__init__(address, Handler)
        self.recognizer = recognizer
        self.model_name = model_name


#; ------------------------------------------------------------------
#; Self-test
#; ------------------------------------------------------------------


def wav_bytes(rate=SAMPLE_RATE, channels=1, seconds=0.25, width=2):
    """Return a silent WAV with a short tone, for the self-test."""
    frames = int(rate * seconds)
    samples = array.array("h", [0]) * (frames * channels)
    if width == 2:
        for index in range(frames):
            value = int(8000 * ((index % 32) / 16.0 - 1.0))
            for channel in range(channels):
                samples[(index * channels) + channel] = value
        raw = samples.tobytes()
    else:
        raw = bytes(len(range(frames * channels * width)))
    with io.BytesIO() as buffer:
        with wave.open(buffer, "wb") as recording:
            recording.setnchannels(channels)
            recording.setsampwidth(width)
            recording.setframerate(rate)
            recording.writeframes(raw)
        return buffer.getvalue()


def multipart_body(fields, upload, filename="recording.wav", boundary="harness-parakeet-self-test"):
    """Return (BODY, CONTENT-TYPE) in the shape the harness sends.

    With UPLOAD nil the body holds only FIELDS, for the missing-file check.
    """
    parts = []
    for name, value in fields.items():
        parts.append(
            ('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'
             % (boundary, name, value)).encode("utf-8")
        )
    if upload is not None:
        parts.append(
            ('--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\n'
             'Content-Type: audio/wav\r\n\r\n' % (boundary, filename)).encode("utf-8")
        )
        parts.append(upload)
        parts.append(b"\r\n")
    parts.append(("--%s--\r\n" % boundary).encode("utf-8"))
    return b"".join(parts), "multipart/form-data; boundary=" + boundary


class FakeRecognizer:
    """A recognizer that answers a fixed text and records what it got."""

    def __init__(self, text="fake transcript"):
        self.text = text
        self.calls = []

    def transcribe(self, samples, sample_rate):
        self.calls.append((len(samples), sample_rate))
        return self.text


class SelfTest:
    """Collect named checks and stop at the first one that fails."""

    def __init__(self):
        self.checks = 0

    def check(self, name, condition):
        self.checks += 1
        if not condition:
            raise AssertionError(name)


def self_test():  # noqa: C901 - a list of small, named checks
    """Check the routes, the upload parsing and the WAV decoding."""
    global MAX_AUDIO_BYTES
    test = SelfTest()
    fake = FakeRecognizer()
    server = Server(("127.0.0.1", 0), fake, "self-test-model")
    thread = threading.Thread(target=server.serve_forever,
                              kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    host, port = "127.0.0.1", server.server_port

    def exchange(method, path, body=None, headers=None):
        connection = http.client.HTTPConnection(host, port, timeout=10)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.read(), response.getheader("Content-Type", "")
        finally:
            connection.close()

    def post(path, fields=None, upload=None, body=None, content_type=None):
        if body is None:
            body, content_type = multipart_body(fields or {}, upload)
        return exchange("POST", path, body=body, headers={"Content-Type": content_type})

    try:
        # A 16 kHz mono upload, the harness's own shape.
        body, content_type = multipart_body(
            {"model": "whisper-1", "response_format": "json"}, wav_bytes())
        status, answer, kind = exchange(
            "POST", "/inference", body=body, headers={"Content-Type": content_type})
        test.check("inference answers", status == 200 and kind == "application/json")
        test.check("inference text", json.loads(answer)["text"] == "fake transcript")
        test.check("inference audio", fake.calls[-1] == (4000, 16000))

        # Stereo at 8 kHz: channels are averaged, the rate is kept.
        status, answer, _ = post("/inference", upload=wav_bytes(8000, 2))
        test.check("stereo answers", status == 200)
        test.check("stereo downmixed", fake.calls[-1] == (2000, 8000))

        # whisper.cpp's plain-text response format.
        status, answer, kind = post("/inference",
                                    {"response_format": "text"}, wav_bytes())
        test.check("text format", status == 200 and answer == b"fake transcript")
        test.check("text content type", kind.startswith("text/plain"))

        # The OpenAI route takes the same upload.
        status, answer, _ = post("/v1/audio/transcriptions", {"model": "parakeet"}, wav_bytes())
        test.check("openai route", status == 200
                   and json.loads(answer)["text"] == "fake transcript")

        # Health, unknown routes and methods.
        status, answer, _ = exchange("GET", "/health")
        test.check("health", status == 200 and json.loads(answer)["status"] == "ok")
        test.check("unknown GET", exchange("GET", "/nope")[0] == 404)
        test.check("unknown POST", post("/nope", upload=wav_bytes())[0] == 404)
        test.check("PUT refused", exchange("PUT", "/inference")[0] == 405)

        # A request without a file, without a multipart body, with a bad WAV.
        status, answer, _ = post("/inference", {"model": "x"}, None)
        test.check("missing file", status == 400 and json.loads(answer)["error"] == "file field missing")
        test.check("not multipart",
                   exchange("POST", "/inference", body=b"x",
                            headers={"Content-Type": "application/json"})[0] == 415)
        status, answer, _ = post("/inference", upload=b"not a wav")
        test.check("bad wav", status == 400 and json.loads(answer)["error"] == "WAV audio unreadable")

        # A body declared larger than the limit is refused before reading.
        with socket.create_connection((host, port), timeout=5) as connection:
            connection.sendall(
                ("POST /inference HTTP/1.0\r\n"
                 "Content-Type: multipart/form-data; boundary=x\r\n"
                 "Content-Length: %d\r\n\r\n" % (MAX_BODY_BYTES + 1)).encode("ascii"))
            head = connection.recv(4096)
        test.check("oversized body", b" 413 " in head.split(b"\r\n")[0])

        # A file part larger than the audio limit.
        saved = MAX_AUDIO_BYTES
        MAX_AUDIO_BYTES = 10
        try:
            status, answer, _ = post("/inference", upload=b"x" * 20)
        finally:
            MAX_AUDIO_BYTES = saved
        test.check("oversized audio", status == 413)

        # The WAV decoders, one sample width at a time.
        test.check("u8", raw_to_floats(bytes([0, 128, 255]), 1) == [-1.0, 0.0, 0.9921875])
        test.check("s16", raw_to_floats(array.array("h", [-32768, 0, 32767]).tobytes(), 2)
                   == [-1.0, 0.0, 32767 / 32768.0])
        test.check("s24", raw_to_floats(b"\x00\x00\x80\x00\x00\x00\xff\xff\x7f", 3)
                   == [-1.0, 0.0, 8388607 / 8388608.0])
        test.check("s32", raw_to_floats(array.array("i", [-2147483648, 0]).tobytes(), 4)
                   == [-1.0, 0.0])

        # The model directory check and the download refusal.
        directory = Path(tempfile.mkdtemp(prefix="parakeet-self-test-"))
        try:
            for name in MODEL_FILES:
                (directory / name).write_bytes(b"x")
            test.check("complete model", model_ready(directory))
            test.check("model found", ensure_model(directory.parent, directory.name) == directory)
            (directory / MODEL_FILES[0]).unlink()
            try:
                ensure_model(directory.parent, directory.name, download=False)
                test.check("download refusal", False)
            except ModelError:
                test.check("download refusal", True)
        finally:
            shutil.rmtree(directory, ignore_errors=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    print("self-test ok (%d checks)" % test.checks)
    return 0


#; ------------------------------------------------------------------
#; Main
#; ------------------------------------------------------------------


def env_int(name, default):
    """Return the integer NAME holds, or DEFAULT when it holds none."""
    try:
        return int(os.environ.get(name, ""))
    except ValueError:
        return default


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    if "--self-test" in arguments:
        return self_test()
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--models-dir", type=Path,
                        default=Path(os.environ.get("PARAKEET_MODELS", "/models")),
                        help="where model directories live (default: %(default)s)")
    parser.add_argument("--model", default=os.environ.get("PARAKEET_MODEL", DEFAULT_MODEL),
                        help="model directory name (default: %(default)s)")
    parser.add_argument("--feature-dim", type=int,
                        default=env_int("PARAKEET_FEATURE_DIM", DEFAULT_FEATURE_DIM),
                        help="model feature dimension (default: %(default)s)")
    parser.add_argument("--threads", type=int, default=env_int("PARAKEET_THREADS", 2),
                        help="decoding threads (default: %(default)s)")
    parser.add_argument("--host", default=os.environ.get("PARAKEET_HOST", "0.0.0.0"),
                        help="listen address (default: %(default)s)")
    parser.add_argument("--port", type=int, default=env_int("PARAKEET_PORT", 8081),
                        help="listen port (default: %(default)s)")
    parser.add_argument("--no-download", action="store_true",
                        help="refuse to fetch a missing model")
    parser.add_argument("--self-test", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(arguments)
    download = not args.no_download and os.environ.get("PARAKEET_DOWNLOAD", "1") != "0"
    try:
        directory = ensure_model(args.models_dir, args.model, download=download)
        log("loading %s" % args.model)
        recognizer = Recognizer(directory, feature_dim=args.feature_dim,
                                num_threads=args.threads)
    except ModelError as exc:
        log(str(exc))
        return 1
    server = Server((args.host, args.port), recognizer, args.model)
    log("listening on %s:%d" % (args.host, args.port))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
