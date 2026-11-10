#!/usr/bin/env python3
"""A stand-in speech service for the harness's speech module tests.

It serves the two routes the local pipeline serves -- whisper.cpp's
multipart `/inference' for speech to text and Kokoro's OpenAI-compatible
`/v1/audio/speech' for text to speech -- with no model, no container and
no audio device.  The harness runs it as the child process its speech
module starts, so a test can start and stop the pipeline, watch it
report `running', and transcribe and synthesize over it.

The text-to-speech side also answers Kokoro's `/v1/audio/voices`, so a
client can be given a real service's answer shape without a container:
`{"voices": [{"id": ..., "name": ...}, ...]}`, the voices the bundled
stack's image bakes in unless `--voices` names others.  A `--no-voices`
run answers 404 there, which is what a service without the route does.

The answers are fixed and visible in the reply: transcription says
`harness speech fixture' (or the `text' field of a JSON body), and
synthesis answers a short silence as a RIFF WAV.  Every request is
written to the log file, one JSON object a line, so a test can assert
which route the harness posted to and what it sent.

Usage: harness-speech-service.py [--port PORT] [--log FILE] [--delay S]
                           [--status CODE] [--stt-only] [--tts-only]
                           [--no-voices] [--voices NAME,...]
                           [--announce FILE]

With `--port 0' the port the kernel picked is written to stdout as
`PORT <number>' and to the announce file, so a caller that starts the
service itself can read it.  `--status' makes every request answer that
HTTP status instead, for the failure path.
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TRANSCRIPT = "harness speech fixture"
SAMPLE_RATE = 16000

# The voices Kokoro-FastAPI v0.8.2's image bakes in, a sample of them: the
# route reports every voice the service has, and these are enough for a
# test to see a real list, its order and its duplicates.
DEFAULT_VOICES = [
    "af_heart", "af_alloy", "af_bella", "am_adam", "am_michael",
    "bf_emma", "bm_george", "ef_dora", "ff_siwis", "zf_xiaobei",
]


def wav_bytes(seconds: float = 0.1) -> bytes:
    """Return a short, valid mono WAV of silence."""
    with io.BytesIO() as buffer:
        with wave.open(buffer, "wb") as recording:
            recording.setnchannels(1)
            recording.setsampwidth(2)
            recording.setframerate(SAMPLE_RATE)
            recording.writeframes(b"\x00\x00" * int(SAMPLE_RATE * seconds))
        return buffer.getvalue()


class Service:
    """The arguments and the request log one run of the service shares."""

    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.port = 0

    def record(self, entry):
        with self.lock:
            if not self.args.log:
                return
            with open(self.args.log, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry) + "\n")
                handle.flush()


def multipart_text(body: bytes, content_type: str) -> dict:
    """Return the plain text fields of a multipart/form-data BODY."""
    boundary = ""
    for part in content_type.split(";"):
        part = part.strip()
        if part.startswith("boundary="):
            boundary = part[len("boundary="):].strip('"')
    fields = {}
    if not boundary:
        return fields
    for section in body.split(("--" + boundary).encode("ascii")):
        head, sep, payload = section.partition(b"\r\n\r\n")
        if not sep:
            continue
        name = ""
        for line in head.decode("latin-1").split("\r\n"):
            if line.lower().startswith("content-disposition:"):
                for piece in line.split(";"):
                    piece = piece.strip()
                    if piece.startswith("name="):
                        name = piece[len("name="):].strip('"')
        if name:
            fields[name] = payload[:-2].decode("utf-8", "replace") if payload.endswith(b"\r\n") else payload.decode("utf-8", "replace")
    return fields


class Handler(BaseHTTPRequestHandler):
    server_version = "HarnessSpeechFixture/1"

    def log_message(self, fmt, *args):  # noqa: D401 - quiet by design
        """Write nothing to stderr; the request log is the record."""

    def _answer(self, status, body: bytes, content_type: str):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        service = self.server.service
        if self.path == "/health":
            self._answer(200, b'{"status":"ok"}', "application/json")
            return
        if self.path.split("?")[0] in ("/v1/audio/voices", "/audio/voices"):
            if service.args.no_voices or service.args.stt_only:
                self._answer(404, b'{"error":"not found"}', "application/json")
                return
            voices = service.args.voices or DEFAULT_VOICES
            service.record({"path": self.path, "voices": len(voices)})
            body = json.dumps({
                "voices": [{"id": name, "name": name} for name in voices],
            }).encode("utf-8")
            self._answer(200, body, "application/json")
            return
        self._answer(404, b"{}", "application/json")

    def do_POST(self):
        service = self.server.service
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        content_type = self.headers.get("Content-Type") or ""
        if service.args.delay:
            time.sleep(service.args.delay)
        if service.args.status:
            service.record({"path": self.path, "status": service.args.status,
                            "bytes": len(body)})
            self._answer(service.args.status, b'{"error":"fixture failure"}',
                         "application/json")
            return
        if self.path == "/inference" and not service.args.tts_only:
            fields = multipart_text(body, content_type)
            audio = fields.get("file", "")
            service.record({"path": self.path, "fields": sorted(fields),
                            "multipart": "multipart/form-data" in content_type,
                            "audio_bytes": len(body)})
            if not audio:
                self._answer(400, b'{"error":"no file"}', "application/json")
                return
            self._answer(200, json.dumps({"text": TRANSCRIPT}).encode("utf-8"),
                         "application/json")
            return
        if self.path.startswith("/v1/audio/speech") and not service.args.stt_only:
            try:
                request = json.loads(body.decode("utf-8")) if body else {}
            except ValueError:
                request = {}
            service.record({"path": self.path, "json": True,
                            "input": request.get("input"),
                            "voice": request.get("voice"),
                            "model": request.get("model"),
                            "speed": request.get("speed"),
                            "volume_multiplier": request.get("volume_multiplier"),
                            "keys": sorted(request),
                            "response_format": request.get("response_format")})
            if not isinstance(request.get("input"), str) or not request["input"].strip():
                self._answer(400, b'{"error":"no input"}', "application/json")
                return
            self._answer(200, wav_bytes(), "audio/wav")
            return
        self._answer(404, b"{}", "application/json")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0,
                        help="port to listen on; 0 lets the kernel pick one")
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to listen on (loopback by default)")
    parser.add_argument("--log", type=Path, default=None,
                        help="file to append one JSON line per request to")
    parser.add_argument("--announce", type=Path, default=None,
                        help="file to write `PORT <number>' to once listening")
    parser.add_argument("--delay", type=float, default=0.0,
                        help="seconds to wait before answering a request")
    parser.add_argument("--status", type=int, default=0,
                        help="answer every request with this HTTP status")
    parser.add_argument("--stt-only", action="store_true", help="serve speech to text alone")
    parser.add_argument("--tts-only", action="store_true", help="serve text to speech alone")
    parser.add_argument("--no-voices", action="store_true",
                        help="answer 404 on the voice route, as a service without one")
    parser.add_argument("--voices", default="",
                        help="comma-separated voice names to report, in this order")
    args = parser.parse_args(argv)
    if args.voices:
        args.voices = [name.strip() for name in args.voices.split(",") if name.strip()]

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.service = Service(args)
    port = server.server_address[1]
    server.service.port = port
    line = "PORT " + str(port)
    if args.announce:
        args.announce.write_text(line + "\n", encoding="utf-8")
    print(line, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
