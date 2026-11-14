#!/usr/bin/env python3
"""How long the shipped local sidecar takes to start a request's receipt.

`scripts/analysis/bench-acknowledgment.sh' measures the harness's own
path in Emacs.  This measures the other end: `scripts/harness-voice-live-unmute'
exactly as Emacs runs it, driven over its own protocol.

What it does, once per sample: the stub microphone speaks, the sidecar's
gate, transcription and delegation turn that into a `delegation', the
driver sends the `acknowledge' Emacs sends after the prompt, and the time
is from that send to the stub speaker's first write for the receipt.
Both ends are wall clock in this process's own frame.

What it does NOT measure: no real microphone records and no real speaker
plays.  The stub speaker is a `pw-play' that logs each write and throws
the audio away, so the numbers are the sidecar's protocol, gate and
player plumbing, not a sound card's startup.  The stub speech service
answers with a tone, not a speech model: the phrases were generated
before the request arrived, so no synthesis is in the path.

Run it with:

    scripts/analysis/bench-acknowledgment-sidecar.sh [SAMPLES]

It needs nothing installed beyond python3 and this checkout.  Its stubs,
its speech service's logs and the sidecar's own stderr go in a work
directory under scripts/.dev/, never in the checkout.
"""

import json
import math
import os
import struct
import subprocess
import sys
import threading
import time
import wave
import io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RATE = 16000
#: Seconds of "speech" and of silence in each stub utterance.  The sidecar
#: ends an utterance HANGOVER seconds after the detector lets go, so a
#: sample is about SPEECH + 0.85 + SILENCE long.
SPEECH_SECONDS = 0.4
SILENCE_SECONDS = 2.0
#: The stub microphone writes in 20 ms chunks, as a real PipeWire capture
#: does: the sidecar's tick waits on a read, so a 100 ms chunk would make
#: its ticks 100 ms apart and inflate what this measures.
CHUNK_SECONDS = 0.02

PW_RECORD = r'''#!/usr/bin/env python3
"""A stub microphone: speech, then a silent gap for the receipt, forever."""
import math, os, struct, sys, time
RATE = %(rate)d
CHUNK = %(chunk)s
SPEECH = %(speech)s
SILENCE = %(silence)s

def pcm(seconds, amplitude):
    return b"".join(struct.pack("<h", int(32767 * amplitude * math.sin(2 * math.pi * 180 * i / RATE)))
                    for i in range(int(seconds * RATE)))

out = sys.stdout.buffer
speech = pcm(CHUNK, 0.28)
silence = pcm(CHUNK, 0.0)
try:
    while True:
        for _ in range(int(SPEECH / CHUNK)):
            out.write(speech); out.flush(); time.sleep(CHUNK)
        for _ in range(int(SILENCE / CHUNK)):
            out.write(silence); out.flush(); time.sleep(CHUNK)
except (BrokenPipeError, KeyboardInterrupt):
    pass
'''

PW_PLAY = r'''#!/usr/bin/env python3
"""A stub speaker: log each start (a write after a gap) and discard the audio."""
import os, sys, time
LOG = %(log)r
stream = sys.stdin.buffer
last = 0.0
try:
    while True:
        chunk = stream.read(4096)
        if not chunk:
            break
        now = time.time()
        if now - last > 0.25:
            with open(LOG, "a") as handle:
                handle.write("%%d start %%d\n" %% (int(now * 1e9), len(chunk)))
        last = now
except (BrokenPipeError, KeyboardInterrupt):
    pass
'''


def tone(seconds=0.4):
    """Return WAV bytes of a plain tone, standing in for a synthesized phrase."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        frames = b"".join(
            struct.pack("<h", int(12000 * math.sin(2 * math.pi * 180 * i / RATE)))
            for i in range(int(seconds * RATE)))
        handle.writeframes(frames)
    return buf.getvalue()


class SpeechService(BaseHTTPRequestHandler):
    """A stand-in OpenAI-compatible speech service, and its request log."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        with open(LOG, "a") as handle:
            handle.write("%.6f %s %d\n" % (time.time(), self.path, len(body)))
        if self.path.startswith("/v1/audio/speech"):
            payload = json.loads(body.decode("utf-8") or "{}")
            with open(PHRASES, "a") as handle:
                handle.write("%.6f %s\n" % (time.time(), payload.get("input", "")))
            data = tone()
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            data = json.dumps({"text": "Add a docstring to parse."}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)


WORK = ""
LOG = ""
PHRASES = ""
REQUESTS = ""
STDERR = ""


def set_work(directory):
    """Point the stubs and their logs at DIRECTORY."""
    global WORK, LOG, PHRASES, REQUESTS, STDERR
    WORK = directory
    LOG = os.path.join(WORK, "played.log")
    PHRASES = os.path.join(WORK, "phrases.log")
    REQUESTS = os.path.join(WORK, "requests.log")
    STDERR = os.path.join(WORK, "sidecar.log")


def write_stubs():
    """Write the stub microphone and speaker into WORK and make them runnable."""
    for name, text in (
            ("pw-record", PW_RECORD % dict(rate=RATE, chunk=CHUNK_SECONDS,
                                           speech=SPEECH_SECONDS,
                                           silence=SILENCE_SECONDS)),
            ("pw-play", PW_PLAY % dict(log=LOG))):
        path = os.path.join(WORK, name)
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, 0o755)


def lines(path):
    try:
        with open(path) as handle:
            return [line for line in handle if line.strip()]
    except OSError:
        return []


def plays():
    return [line.split()[0] for line in lines(LOG)]


def phrases():
    return [line.split(None, 1)[-1].strip() for line in lines(PHRASES)]


def main(argv):
    root = argv[1]
    set_work(argv[2])
    samples_wanted = int(argv[3]) if len(argv) > 3 else 20
    write_stubs()
    for path in (LOG, PHRASES, REQUESTS):
        open(path, "w").close()

    server = ThreadingHTTPServer(("127.0.0.1", 0), SpeechService)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    events = []
    log = open(STDERR, "w")
    proc = subprocess.Popen(
        [sys.executable, os.path.join(root, "scripts", "harness-voice-live-unmute"),
         "--stt-url", "http://127.0.0.1:%d/v1/audio/transcriptions" % port,
         "--tts-url", "http://127.0.0.1:%d/v1/audio/speech" % port,
         "--voice", "af_heart"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
        env=dict(os.environ, PATH=WORK + os.pathsep + os.environ["PATH"]))

    def read():
        for line in proc.stdout:
            try:
                events.append((time.time(), json.loads(line)))
            except ValueError:
                pass

    threading.Thread(target=read, daemon=True).start()

    def send(event):
        proc.stdin.write(json.dumps(event) + "\n")
        proc.stdin.flush()
        return time.time()

    def wait_for(predicate, timeout=30, start=0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for at, event in list(events[start:]):
                if predicate(event):
                    return at, event
            time.sleep(0.002)
        return None, None

    def stop():
        try:
            send({"event": "stop"})
            proc.wait(timeout=10)
        except (subprocess.TimeoutExpired, BrokenPipeError, ValueError):
            proc.kill()
        server.shutdown()

    started = send({"event": "start", "protocol": 1})
    at_ready, _ = wait_for(lambda e: e.get("event") == "ready", 15)
    if at_ready is None:
        print("no ready event; exit %s; stderr:\n%s"
              % (proc.poll(), "".join(lines(STDERR))[:2000]))
        stop()
        return 1
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline and len(phrases()) < 3:
        time.sleep(0.002)
    primed = len(phrases())
    print("ready %.0f ms after start; bank primed %.0f ms after ready, %d phrases"
          % ((at_ready - started) * 1000.0, (time.time() - at_ready) * 1000.0,
             primed))
    if primed < 3:
        print("the bank never filled; the receipt would be silence")
        stop()
        return 1

    open(LOG, "w").close()
    open(LOG, "a").close()
    samples = []
    cursor = len(events)
    deadline = time.monotonic() + 40 * samples_wanted
    while len(samples) < samples_wanted and time.monotonic() < deadline:
        delegation = None
        until = time.monotonic() + 40
        while time.monotonic() < until and delegation is None:
            while cursor < len(events):
                _, event = events[cursor]
                cursor += 1
                if event.get("event") == "delegation":
                    delegation = event
                    break
            if delegation is None:
                time.sleep(0.002)
        if delegation is None:
            break
        before = len(plays())
        sent = send({"event": "acknowledge", "delegation": delegation.get("id")})
        until = time.monotonic() + 5
        while time.monotonic() < until and len(plays()) <= before:
            time.sleep(0.001)
        played = plays()
        if len(played) > before:
            samples.append((int(played[before]) / 1e9 - sent) * 1000.0)
            print("  request %d: %.1f ms (delegation %s)"
                  % (len(samples), samples[-1], delegation.get("id")))
        else:
            print("  request %d: no playback (delegation %s)"
                  % (len(samples) + 1, delegation.get("id")))
    synthesized = len(phrases())
    stop()

    if not samples:
        print("no receipt started; the measurement is empty")
        return 1
    ordered = sorted(samples)
    p50 = ordered[min(len(ordered) - 1, int(round(0.50 * (len(ordered) - 1))))]
    p95 = ordered[min(len(ordered) - 1, int(round(0.95 * (len(ordered) - 1))))]
    print("acknowledge-to-playback-start: n=%d p50 %.1f ms p95 %.1f ms max %.1f ms"
          % (len(samples), p50, p95, ordered[-1]))
    print("phrase synthesis requests: %d before the first request, %d by the end"
          % (primed, synthesized))
    print("receipts played: %d" % len(samples))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
