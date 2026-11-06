#!/usr/bin/env python3
"""Loopback HTTP/CLI tests for scripts/harness-voice-stt; no speech model needed."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave
from contextlib import contextmanager
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "harness-voice-stt"


def wav_bytes():
    with io.BytesIO() as buffer:
        with wave.open(buffer, "wb") as recording:
            recording.setnchannels(1)
            recording.setsampwidth(2)
            recording.setframerate(16000)
            recording.writeframes(b"\x01\x00" * 320)
        return buffer.getvalue()


@contextmanager
def endpoint(payload=b'{"text":"transcript"}', status=200, headers=None, delay=0):
    """Serve one configured response, recording every request for assertions."""
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            requests.append(
                {
                    "path": self.path,
                    "headers": self.headers,
                    "body": self.rfile.read(int(self.headers["Content-Length"])),
                }
            )
            if delay:
                time.sleep(delay)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Expected when a short client timeout closes the socket.

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(
        target=lambda: server.serve_forever(poll_interval=0.01), daemon=True
    )
    thread.start()
    try:
        yield "http://127.0.0.1:" + str(server.server_port) + "/inference", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


class VoiceSTTTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="harness-voice-stt-")
        self.addCleanup(self.directory.cleanup)
        self.wav = Path(self.directory.name) / 'private "input".wav'
        self.audio = wav_bytes()
        self.wav.write_bytes(self.audio)

    def cli(self, *arguments, env=None):
        environment = os.environ.copy()
        environment.update(
            {
                "LC_ALL": "C",
                "PYTHONUTF8": "0",
                "PYTHONCOERCECLOCALE": "0",
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        environment.update(env or {})
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), str(self.wav), *arguments],
            capture_output=True,
            env=environment,
            timeout=5,
        )

    def test_success_utf8_and_whisper_multipart_contract(self):
        with endpoint(json.dumps({"text": "  A café function.\nNext line.  "}).encode()) as (url, calls):
            result = self.cli("--url", url, "--language", "en")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode("utf-8"), "A café function.\nNext line.\n")
        self.assertEqual(result.stderr, b"")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["path"], "/inference")
        message = BytesParser(policy=policy.default).parsebytes(
            ("Content-Type: " + calls[0]["headers"]["Content-Type"] + "\r\n\r\n").encode()
            + calls[0]["body"]
        )
        parts = {
            part.get_param("name", header="content-disposition"): part
            for part in message.iter_parts()
        }
        self.assertEqual(parts["response_format"].get_payload(decode=True), b"json")
        self.assertEqual(parts["language"].get_payload(decode=True), b"en")
        self.assertEqual(parts["file"].get_content_type(), "audio/wav")
        self.assertEqual(parts["file"].get_filename(), "recording.wav")
        self.assertEqual(parts["file"].get_payload(decode=True), self.audio)
        self.assertNotIn(str(self.wav).encode(), calls[0]["body"])

    def test_default_is_local_and_language_is_auto(self):
        loader = importlib.machinery.SourceFileLoader("voice_stt", str(SCRIPT))
        specification = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(specification)
        loader.exec_module(module)
        self.assertEqual(module.DEFAULT_URL, "http://127.0.0.1:8080/inference")
        with endpoint() as (url, calls):
            result = self.cli("--url", url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'name="language"\r\n\r\nauto\r\n', calls[0]["body"])

    def test_empty_missing_and_nontext_results_fail_without_stdout(self):
        for payload in ({"text": " \n"}, {}, {"text": None}, {"text": 1}, [], "words"):
            with self.subTest(payload=payload):
                with endpoint(json.dumps(payload).encode()) as (url, _calls):
                    result = self.cli("--url", url)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(
                    result.stderr,
                    b"harness-voice-stt: transcription response without text\n",
                )

    def test_malformed_json_and_invalid_utf8_fail_without_traceback(self):
        for payload in (b"not JSON", b'{"text":"\xff"}'):
            with self.subTest(payload=payload):
                with endpoint(payload) as (url, _calls):
                    result = self.cli("--url", url)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(
                    result.stderr,
                    b"harness-voice-stt: transcription response invalid JSON\n",
                )

    def test_http_error_does_not_echo_response_body(self):
        with endpoint(b"private response body", status=503) as (url, _calls):
            result = self.cli("--url", url)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"harness-voice-stt: transcription endpoint HTTP 503\n")

    def test_redirect_cannot_upload_to_another_endpoint(self):
        with endpoint() as (target, target_calls):
            with endpoint(status=307, headers={"Location": target}) as (url, first_calls):
                result = self.cli("--url", url)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"harness-voice-stt: transcription endpoint HTTP 307\n")
        self.assertEqual(len(first_calls), 1)
        self.assertEqual(target_calls, [])

    def test_proxy_environment_cannot_intercept_recording(self):
        with endpoint() as (url, calls):
            with endpoint() as (proxy, proxy_calls):
                result = self.cli(
                    "--url", url,
                    env={"http_proxy": proxy, "HTTP_PROXY": proxy, "no_proxy": "", "NO_PROXY": ""},
                )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(proxy_calls, [])

    def test_timeout_is_nonzero_and_has_no_transcript(self):
        with endpoint(delay=0.2) as (url, _calls):
            result = self.cli("--url", url, "--timeout", "0.03")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"harness-voice-stt: transcription endpoint timeout\n")

    def test_invalid_or_absent_audio_never_reaches_endpoint(self):
        for contents in (b"", b"this is not WAV", None):
            with self.subTest(contents=contents):
                if contents is None:
                    self.wav.unlink()
                else:
                    self.wav.write_bytes(contents)
                with endpoint() as (url, calls):
                    result = self.cli("--url", url)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertTrue(result.stderr.startswith(b"harness-voice-stt: WAV input"))
                self.assertEqual(calls, [])

    def test_invalid_options_are_rejected_before_upload(self):
        for arguments in (
            ("--url", "file:///etc/passwd"),
            ("--url", "http://user:password@127.0.0.1/inference"),
            ("--url", "http://127.0.0.1/inference#fragment"),
            ("--timeout", "0"),
            ("--timeout", "nan"),
            ("--timeout", "inf"),
        ):
            with self.subTest(arguments=arguments):
                result = self.cli(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
                self.assertNotIn(b"Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
