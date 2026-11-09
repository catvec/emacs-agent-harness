#!/usr/bin/env python3
"""A speech service that answers the way the bundled pipeline does.

Usage: speech_service.py PORT [--refuse TEXT]

Serves whisper.cpp's multipart `/inference` (and the OpenAI route) and Kokoro's
`/v1/audio/speech` with fixed answers: one transcription, and a short WAV
for text it has phonemes for.  Kokoro answers text it has none for --
emoji, a dash, a stray backtick -- with **HTTP 200 and an empty body**
(measured on the bundled `voice-local` stack); this service does the same,
and with `--refuse TEXT` it does that for TEXT too, however speakable, so
the demo can show the failure path for a normal sentence.
"""

import argparse
import io
import json
import math
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def wav(seconds=0.3, rate=24000, frequency=180.0):
    """Return a short WAV, as a speech server answers."""
    frames = b"".join(
        struct.pack("<h", int(12000 * math.sin(2 * math.pi * frequency * i / rate)))
        for i in range(int(seconds * rate)))
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(frames), b"WAVE", b"fmt ", 16, 1, 1, rate,
        rate * 2, 2, 16, b"data", len(frames))
    return header + frames


def has_phonemes(text):
    """Non-nil when a speech server would have something to say for TEXT."""
    return any(ch.isalnum() for ch in text or "")


class Handler(BaseHTTPRequestHandler):
    """The two OpenAI-compatible audio routes, with Kokoro's silence."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if self.path.endswith("/audio/transcriptions") or self.path.endswith("/inference"):
            payload = json.dumps({"text": "Add a docstring to parse."}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.endswith("/audio/speech"):
            try:
                text = json.loads(body.decode("utf-8")).get("input") or ""
            except ValueError:
                text = ""
            self.server.calls.append(text)
            refuse = self.server.refuse
            audio = (b"" if (not has_phonemes(text) or (refuse and refuse in text))
                     else wav())
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(audio)))
            self.end_headers()
            self.wfile.write(audio)
            return
        self.send_response(404)
        self.end_headers()


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=int)
    parser.add_argument("--refuse", default="")
    options = parser.parse_args(argv[1:])
    server = ThreadingHTTPServer(("127.0.0.1", options.port), Handler)
    server.calls = []
    server.refuse = options.refuse
    print("listening", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
