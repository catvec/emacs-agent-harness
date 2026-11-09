#!/usr/bin/env python3
"""Tests for the voice-local Parakeet server.

The server's routes, upload parsing, WAV decoding and model download are
checked here with fakes: no speech model, microphone or network is
needed.  Set PARAKEET_TEST_MODEL to a downloaded model directory to add
the real transcription of the model's own test WAV:

    PARAKEET_TEST_MODEL=/path/to/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 \
        python3 -B test/harness-voice-parakeet-test.py
"""

from __future__ import annotations

import array
import importlib.util
import io
import json
import os
import socket
import tarfile
import tempfile
import threading
import unittest
import wave
from http.client import HTTPConnection
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "scripts" / "stacks" / "voice-local" / "parakeet" / "server.py"


def load_server():
    """Return the server module, loaded by path."""
    spec = importlib.util.spec_from_file_location("parakeet_server", SERVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = load_server()


def wav_bytes(rate=16000, channels=1, width=2, frames=4000, left=0, right=0):
    """Return a WAV with a constant sample, for the route tests."""
    if width == 2:
        samples = array.array("h")
        for _ in range(frames):
            samples.append(left)
            for _ in range(channels - 1):
                samples.append(right)
        raw = samples.tobytes()
    else:
        raw = bytes(frames * channels * width)
    with io.BytesIO() as buffer:
        with wave.open(buffer, "wb") as recording:
            recording.setnchannels(channels)
            recording.setsampwidth(width)
            recording.setframerate(rate)
            recording.writeframes(raw)
        return buffer.getvalue()


class FakeRecognizer:
    """A recognizer that records each call and answers fixed text."""

    def __init__(self, text="fake transcript"):
        self.text = text
        self.calls = []

    def transcribe(self, samples, sample_rate):
        self.calls.append((len(samples), sample_rate))
        return self.text


class ServerTest(unittest.TestCase):
    """The HTTP routes over a fake recognizer."""

    def setUp(self):
        self.fake = FakeRecognizer()
        self.httpd = server.Server(("127.0.0.1", 0), self.fake, "test-model")
        self.thread = threading.Thread(
            target=self.httpd.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)

    def exchange(self, method, path, body=None, headers=None):
        connection = HTTPConnection("127.0.0.1", self.httpd.server_port, timeout=10)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.read(), response.getheader("Content-Type", "")
        finally:
            connection.close()

    def post(self, path="/inference", fields=None, upload=None, body=None, content_type=None):
        if body is None:
            body, content_type = server.multipart_body(fields or {}, upload)
        return self.exchange("POST", path, body=body,
                             headers={"Content-Type": content_type})

    def test_inference_json(self):
        status, answer, kind = self.post(upload=wav_bytes())
        self.assertEqual(status, 200)
        self.assertEqual(kind, "application/json")
        self.assertEqual(json.loads(answer)["text"], "fake transcript")
        self.assertEqual(self.fake.calls[-1], (4000, 16000))

    def test_inference_reads_the_harness_fields(self):
        status, answer, _ = self.post(
            fields={"model": "whisper-1", "response_format": "json", "language": "en"},
            upload=wav_bytes())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(answer)["text"], "fake transcript")

    def test_openai_route_takes_the_same_upload(self):
        status, answer, _ = self.post(
            path="/v1/audio/transcriptions",
            fields={"model": "parakeet", "response_format": "json"},
            upload=wav_bytes())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(answer), {"text": "fake transcript"})

    def test_text_response(self):
        status, answer, kind = self.post(fields={"response_format": "text"},
                                         upload=wav_bytes())
        self.assertEqual(status, 200)
        self.assertEqual(answer, b"fake transcript")
        self.assertTrue(kind.startswith("text/plain"))

    def test_stereo_is_downmixed_and_the_rate_kept(self):
        status, _, _ = self.post(upload=wav_bytes(rate=8000, channels=2, frames=2000))
        self.assertEqual(status, 200)
        self.assertEqual(self.fake.calls[-1], (2000, 8000))

    def test_empty_transcript(self):
        self.fake.text = ""
        status, answer, _ = self.post(upload=wav_bytes())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(answer), {"text": ""})

    def test_health(self):
        status, answer, _ = self.exchange("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(answer), {"status": "ok", "model": "test-model"})

    def test_unknown_routes(self):
        self.assertEqual(self.exchange("GET", "/nope")[0], 404)
        self.assertEqual(self.post(path="/nope", upload=wav_bytes())[0], 404)
        self.assertEqual(json.loads(self.exchange("GET", "/nope")[1]), {"error": "unknown route"})

    def test_other_methods_are_refused(self):
        self.assertEqual(self.exchange("PUT", "/inference")[0], 405)
        self.assertEqual(self.exchange("DELETE", "/inference")[0], 405)

    def test_missing_file_field(self):
        status, answer, _ = self.post(fields={"model": "x"})
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(answer), {"error": "file field missing"})

    def test_not_multipart(self):
        status, answer, _ = self.exchange(
            "POST", "/inference", body=b"{}", headers={"Content-Type": "application/json"})
        self.assertEqual(status, 415)
        self.assertEqual(json.loads(answer), {"error": "multipart form required"})

    def test_missing_content_length(self):
        with socket.create_connection(("127.0.0.1", self.httpd.server_port), timeout=5) as sock:
            sock.sendall(b"POST /inference HTTP/1.0\r\nContent-Type: text/plain\r\n\r\n")
            head = sock.recv(4096)
        self.assertIn(b" 411 ", head.split(b"\r\n")[0])

    def test_oversized_body_is_refused_before_reading(self):
        with socket.create_connection(("127.0.0.1", self.httpd.server_port), timeout=5) as sock:
            sock.sendall((
                "POST /inference HTTP/1.0\r\n"
                "Content-Type: multipart/form-data; boundary=x\r\n"
                "Content-Length: %d\r\n\r\n" % (server.MAX_BODY_BYTES + 1)).encode("ascii"))
            head = sock.recv(4096)
        self.assertIn(b" 413 ", head.split(b"\r\n")[0])

    def test_oversized_audio(self):
        saved = server.MAX_AUDIO_BYTES
        server.MAX_AUDIO_BYTES = 10
        try:
            status, answer, _ = self.post(upload=b"x" * 20)
        finally:
            server.MAX_AUDIO_BYTES = saved
        self.assertEqual(status, 413)
        self.assertEqual(json.loads(answer), {"error": "audio too large"})

    def test_bad_wav(self):
        status, answer, _ = self.post(upload=b"not a wav")
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(answer), {"error": "WAV audio unreadable"})

    def test_recognizer_failure_is_reported_and_the_server_stays_up(self):
        class Broken(FakeRecognizer):
            def transcribe(self, samples, sample_rate):
                raise RuntimeError("decoder failed")

        self.httpd.recognizer = Broken()
        status, answer, _ = self.post(upload=wav_bytes())
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(answer), {"error": "transcription failed"})
        self.assertEqual(self.exchange("GET", "/health")[0], 200)


class ParsingTest(unittest.TestCase):
    """The multipart and WAV readers."""

    def test_fields_and_upload(self):
        body, content_type = server.multipart_body(
            {"model": "whisper-1", "response_format": "json"}, b"RIFFdata")
        fields, upload = server.parse_multipart(content_type, body)
        self.assertEqual(fields, {"model": "whisper-1", "response_format": "json"})
        self.assertEqual(upload, b"RIFFdata")

    def test_quoted_boundary(self):
        body, content_type = server.multipart_body({}, b"x", boundary="a-b_c")
        fields, upload = server.parse_multipart(
            content_type.replace("boundary=", 'boundary="') + '"', body)
        self.assertEqual(fields, {})
        self.assertEqual(upload, b"x")

    def test_missing_boundary(self):
        with self.assertRaises(server.RequestError) as caught:
            server.parse_multipart("multipart/form-data", b"")
        self.assertEqual(caught.exception.status, 400)

    def test_no_upload(self):
        body, content_type = server.multipart_body({"model": "x"}, None)
        fields, upload = server.parse_multipart(content_type, body)
        self.assertEqual(fields, {"model": "x"})
        self.assertIsNone(upload)

    def test_sample_widths(self):
        self.assertEqual(server.raw_to_floats(bytes([0, 128, 255]), 1),
                         [-1.0, 0.0, 127 / 128.0])
        self.assertEqual(server.raw_to_floats(array.array("h", [-32768, 0, 32767]).tobytes(), 2),
                         [-1.0, 0.0, 32767 / 32768.0])
        self.assertEqual(server.raw_to_floats(
            b"\x00\x00\x80\x00\x00\x00\xff\xff\x7f", 3), [-1.0, 0.0, 8388607 / 8388608.0])
        self.assertEqual(server.raw_to_floats(
            array.array("i", [-2147483648, 0, 2147483647]).tobytes(), 4),
            [-1.0, 0.0, 2147483647 / 2147483648.0])
        with self.assertRaises(server.RequestError):
            server.raw_to_floats(b"\x00", 8)
        with self.assertRaises(server.RequestError):
            server.raw_to_floats(b"\x00\x00", 3)

    def test_stereo_downmix(self):
        samples, rate = server.wav_to_samples(
            wav_bytes(rate=8000, channels=2, frames=3, left=16384, right=-16384))
        self.assertEqual(rate, 8000)
        self.assertEqual(samples, [0.0, 0.0, 0.0])

    def test_invalid_and_empty_wav(self):
        with self.assertRaises(server.RequestError):
            server.wav_to_samples(b"not a wav")
        with self.assertRaises(server.RequestError):
            server.wav_to_samples(wav_bytes(frames=0))


class ModelTest(unittest.TestCase):
    """The model directory check and its download."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="parakeet-model-")
        self.addCleanup(self.directory.cleanup)
        self.models = Path(self.directory.name)
        self.name = "test-model"
        self.model = self.models / self.name
        self.model.mkdir()
        for name in server.MODEL_FILES:
            (self.model / name).write_bytes(b"x")

    def test_complete_model(self):
        self.assertTrue(server.model_ready(self.model))
        self.assertEqual(server.ensure_model(self.models, self.name), self.model)

    def test_missing_model_without_download(self):
        (self.model / server.MODEL_FILES[0]).unlink()
        self.assertFalse(server.model_ready(self.model))
        with self.assertRaises(server.ModelError):
            server.ensure_model(self.models, self.name, download=False)

    def test_download_from_a_file_url(self):
        archive = self.models / "remote"
        archive.mkdir()
        with tarfile.open(archive / (self.name + ".tar.bz2"), "w:bz2") as tar:
            tar.add(self.model, arcname=self.name)
        (self.model / server.MODEL_FILES[0]).unlink()
        saved = os.environ.get("PARAKEET_MODEL_URL")
        os.environ["PARAKEET_MODEL_URL"] = archive.as_uri()
        try:
            self.assertEqual(server.ensure_model(self.models, self.name), self.model)
        finally:
            if saved is None:
                os.environ.pop("PARAKEET_MODEL_URL", None)
            else:
                os.environ["PARAKEET_MODEL_URL"] = saved
        self.assertTrue(server.model_ready(self.model))

    def test_archive_outside_the_destination_is_refused(self):
        archive = self.models / "remote"
        archive.mkdir()
        (self.model / server.MODEL_FILES[0]).unlink()
        evil = self.models / "evil"
        evil.write_bytes(b"x")
        with tarfile.open(archive / (self.name + ".tar.bz2"), "w:bz2") as tar:
            tar.add(evil, arcname="../evil")
        saved = os.environ.get("PARAKEET_MODEL_URL")
        os.environ["PARAKEET_MODEL_URL"] = archive.as_uri()
        try:
            with self.assertRaises(server.ModelError):
                server.ensure_model(self.models, self.name)
        finally:
            if saved is None:
                os.environ.pop("PARAKEET_MODEL_URL", None)
            else:
                os.environ["PARAKEET_MODEL_URL"] = saved
        self.assertFalse(server.model_ready(self.model))


@unittest.skipUnless(os.environ.get("PARAKEET_TEST_MODEL"), "PARAKEET_TEST_MODEL unset")
class RealModelTest(unittest.TestCase):
    """The real model, when one is downloaded; skipped in CI."""

    def test_transcribes_the_models_own_test_wav(self):
        directory = Path(os.environ["PARAKEET_TEST_MODEL"])
        try:
            import sherpa_onnx  # noqa: F401
        except ImportError as exc:
            self.skipTest("sherpa-onnx unavailable: %s" % exc)
        feature_dim = 128 if "v3" in directory.name else 80
        recognizer = server.Recognizer(directory, feature_dim=feature_dim, num_threads=4)
        data = (directory / "test_wavs" / "0.wav").read_bytes()
        samples, rate = server.wav_to_samples(data)
        text = recognizer.transcribe(samples, rate)
        self.assertIn("observed Phebe", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
