"""Shared plumbing for the harness's live voice sidecars.

A sidecar speaks newline-delimited JSON on stdin and stdout and keeps
every audio sample to itself: Emacs sends control events, the sidecar
sends captions, playback state and delegation requests.  This module
holds what the GPT-Live and local sidecars share: the event loop, raw
PCM capture and playback, an energy voice detector, HTTP helpers and a
small WebSocket client, all in the Python standard library.

Protocol (both directions unless said otherwise), one object per line:

    start   Emacs -> sidecar   session start; ``protocol``
    ready   sidecar -> Emacs   the sidecar is up
    listening / speaking       playback state for the indicator
    user_delta / assistant_delta  caption text, optional ``final``
    backchannel                a short listening sound happened
    delegation  sidecar -> Emacs  ``id``, ``text`` and optional ``final``
    delegate_result  Emacs -> sidecar  ``id``, ``text``, ``error``, ``message``
    commentary / thinking  Emacs -> sidecar  speakable reply, quiet progress
    mute / interrupt / stop    Emacs -> sidecar
    interrupted / notice / error / closed  sidecar -> Emacs

``error`` ends the session: only a failure the sidecar cannot carry on
from sends it.  ``notice`` says one reply could not be spoken or one
utterance could not be transcribed; the call goes on, and Emacs shows
the line without stopping the microphone.

Both bundled sidecars support ``--self-test``: they run their mapping
against fake audio and a fake service, print one line and exit zero, so
CI can check them without a microphone, a key or a network.
"""

import array
import base64
import collections
import io
import json
import os
import queue
import select
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave

PROTOCOL = 1

#: The harness protocol's native rate.  GPT-Live and the local models
#: all accept PCM16 mono at these rates through the sidecar.
GPT_RATE = 24000
LOCAL_RATE = 16000

#: How much audio one capture read asks for, in seconds.  A sidecar's loop
#: ticks about every 20 ms, so a tick-sized read leaves no room for even
#: one late tick: the pipe fills, and PipeWire or PulseAudio -- which
#: cannot block a real-time capture -- overruns and drops the microphone.
#: Ten ticks of headroom drains a backlog instead of adding to it.
CAPTURE_SECONDS = 0.2


def _libc_prctl():
    """Return the C library's prctl, or None where the platform has none."""
    if not sys.platform.startswith("linux"):
        return None
    try:
        import ctypes
        return ctypes.CDLL(None, use_errno=True).prctl
    except (OSError, AttributeError):
        return None


#: Loaded in the parent, so the forked child only makes the call: see
#: `die_with_parent'.
_PRCTL = _libc_prctl()

#: Linux's "send me a signal when my parent dies" request.
PR_SET_PDEATHSIG = 1


def die_with_parent():
    """Return a child setup that ties an audio process to the sidecar.

    Emacs can go away without sending ``stop``: its last window is
    closed, its process is killed, a session ends.  A player that
    outlives the sidecar keeps playing the audio it has already read, so
    a reply is heard long after the UI is gone; a recorder that outlives
    it keeps the microphone open for a process nobody can see.  Linux's
    PR_SET_PDEATHSIG makes the kernel kill the child when the sidecar
    dies, and the parent check closes the race where the sidecar died
    between the fork and the setting.

    The function that ``preexec_fn`` runs must stay this small: the
    sidecar has threads, and a child that allocated or waited after the
    fork could hang before exec.  The call into the C library needs no
    Python object beyond the two integers.
    """
    parent = os.getpid()

    def setup():
        if _PRCTL is not None:
            _PRCTL(PR_SET_PDEATHSIG, int(signal.SIGKILL))
        if os.getppid() != parent:
            os._exit(1)

    return setup


def log(text):
    """Write a diagnostic line to stderr, where it cannot corrupt stdout."""
    sys.stderr.write("%s\n" % text)
    sys.stderr.flush()


# A piece of text with no letters or digits is not speech: an
# OpenAI-compatible speech server answers "🙂", "—" or a stray "`" with
# an empty body, which reads as failed synthesis though there was simply
# nothing to say.
def speakable(text):
    """Return TEXT when a speech server could say it, else an empty string."""
    text = text or ""
    return text if any(ch.isalnum() for ch in text) else ""


#; ------------------------------------------------------------------
#; Events
#; ------------------------------------------------------------------

class Events:
    """Newline-delimited JSON events over two text streams."""

    def __init__(self, stream_in=None, stream_out=None):
        self._in = stream_in or sys.stdin
        self._out = stream_out or sys.stdout
        self._lock = threading.Lock()
        self._queue = queue.Queue()
        self._reader = None
        self.closed = False

    def send(self, event, **fields):
        """Write one protocol event and flush it."""
        message = {"event": event}
        message.update(fields)
        line = json.dumps(message, separators=(",", ":")) + "\n"
        with self._lock:
            try:
                self._out.write(line)
                self._out.flush()
            except (BrokenPipeError, ValueError):
                self.closed = True

    def start(self):
        """Read stdin on a thread, so events arrive while audio runs."""
        def read():
            for line in self._in:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except ValueError as error:
                    log("invalid JSON from harness: %s" % error)
                    continue
                if isinstance(event, dict):
                    self._queue.put(event)
                else:
                    log("protocol event is not an object")
            self._queue.put(None)

        self._reader = threading.Thread(target=read, name="events", daemon=True)
        self._reader.start()
        return self

    def get(self, timeout=None):
        """Return the next event, or None when none arrived in TIME."""
        try:
            return self._queue.get(timeout=timeout)
        except queue.Empty:
            return None

    def drain(self):
        """Return every event waiting now, without blocking."""
        events = []
        while True:
            event = self.get(0)
            if event is None:
                return events
            events.append(event)


class Loop:
    """Run a sidecar's command handler and periodic tick until stopped."""

    def __init__(self, events=None, tick=0.05):
        self.events = events or Events()
        self.tick = tick
        self.stopped = False
        self.exit_code = 0

    def stop(self, code=0):
        """Stop the loop and remember the exit status."""
        self.stopped = True
        self.exit_code = code

    def run(self, on_event, on_tick=None):
        """Call ON_EVENT for commands and ON_TICK about every TICK seconds."""
        self.events.start()
        while not self.stopped:
            event = self.events.get(self.tick)
            if event is None:
                if not self.events._reader.is_alive() and self.events._queue.empty():
                    # The harness closed the pipe: end like a stop.
                    break
                if on_tick:
                    on_tick()
                continue
            try:
                on_event(event)
            except Exception as error:  # keep one bad event from killing audio
                log("handler failed: %s: %s" % (type(error).__name__, error))
                self.events.send("error", message="%s: %s" % (type(error).__name__, error))
                self.stop(1)
        return self.exit_code


#; ------------------------------------------------------------------
#; Audio
#; ------------------------------------------------------------------

def pcm_energy(pcm):
    """Return the mean absolute sample of PCM16 bytes, in [0, 1]."""
    if not pcm:
        return 0.0
    count = len(pcm) // 2
    if not count:
        return 0.0
    total = 0
    for (sample,) in struct.iter_unpack("<h", pcm[:count * 2]):
        total += sample if sample >= 0 else -sample
    return total / (count * 32768.0)


class Backend:
    """One way to capture and play raw PCM16 mono on this machine.

    ``capture`` and ``play`` build the argv list for a sample rate, with
    PCM16 mono on standard output and standard input.  ``programs`` is
    the capture and the playback program, so a reason Emacs shows can
    name the one that is missing.  The order and the names are the ones
    in `harness-ui-media.el', where the WAV dictation picks its recorder
    and player; keep the two tables in step.
    """

    def __init__(self, name, label, capture, play, programs):
        self.name = name
        self.label = label
        self.capture = capture
        self.play = play
        self.programs = programs

    def capture_command(self, rate):
        """Return the argv list capturing RATE Hz PCM16 mono to stdout."""
        return self.capture(int(rate))

    def play_command(self, rate):
        """Return the argv list playing RATE Hz PCM16 mono from stdin."""
        return self.play(int(rate))


def _pipewire_capture(rate):
    return ["pw-record", "--rate", str(rate), "--channels", "1",
            "--format", "s16", "--raw", "-"]


def _pipewire_play(rate):
    return ["pw-play", "--rate", str(rate), "--channels", "1",
            "--format", "s16", "--raw", "-"]


def _pulse_capture(rate):
    return ["parec", "--raw", "--format=s16le", "--rate=%d" % rate,
            "--channels=1", "--latency-msec=50"]


def _pulse_play(rate):
    return ["paplay", "--raw", "--format=s16le", "--rate=%d" % rate,
            "--channels=1", "--latency-msec=50"]


def _alsa_capture(rate):
    return ["arecord", "-q", "-f", "S16_LE", "-r", str(rate), "-c", "1",
            "-t", "raw"]


def _alsa_play(rate):
    return ["aplay", "-q", "-f", "S16_LE", "-r", str(rate), "-c", "1",
            "-t", "raw"]


def _ffmpeg_capture(rate):
    return ["ffmpeg", "-loglevel", "error", "-nostdin", "-f", "pulse",
            "-i", "default", "-f", "s16le", "-ar", str(rate), "-ac", "1", "-"]


def _ffmpeg_play(rate):
    return ["ffmpeg", "-loglevel", "error", "-nostdin", "-f", "s16le",
            "-ar", str(rate), "-ac", "1", "-i", "-", "-f", "pulse", "default"]


AUDIO_BACKENDS = (
    Backend("pipewire", "PipeWire", _pipewire_capture, _pipewire_play,
            ("pw-record", "pw-play")),
    Backend("pulse", "PulseAudio", _pulse_capture, _pulse_play,
            ("parec", "paplay")),
    Backend("alsa", "ALSA", _alsa_capture, _alsa_play, ("arecord", "aplay")),
    Backend("ffmpeg", "FFmpeg", _ffmpeg_capture, _ffmpeg_play,
            ("ffmpeg", "ffmpeg")),
)

AUDIO_AUTO = "auto"

#: What a missing side is called in a reason, in the sidecar's own words.
AUDIO_SIDES = {"capture": "microphone", "playback": "speaker"}


def audio_backend_names():
    """Return every value the sidecars' `--audio' option takes."""
    return [AUDIO_AUTO] + [backend.name for backend in AUDIO_BACKENDS]


def audio_backend(name):
    """Return the backend NAME names, or None when no backend has that name."""
    for backend in AUDIO_BACKENDS:
        if backend.name == name:
            return backend
    return None


def audio_installed(backend):
    """Return whether both of BACKEND's programs are on this machine."""
    return all(shutil.which(program) for program in backend.programs)


def audio_backends(requested=AUDIO_AUTO):
    """Return the backends to try for REQUESTED, in preference order.

    `auto' offers every backend whose programs are installed, so a
    machine without alsa-utils records through PipeWire or its
    PulseAudio compatibility instead.  A named backend offers itself
    alone: a forced backend that fails says so rather than switching to
    another one under the user.
    """
    if requested and requested != AUDIO_AUTO:
        backend = audio_backend(requested)
        return [backend] if backend and audio_installed(backend) else []
    return [backend for backend in AUDIO_BACKENDS if audio_installed(backend)]


def _listed(items):
    """Return ITEMS as "a, b or c"."""
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " or " + items[-1]


def audio_missing_reason(requested, side):
    """Return why the SIDE of REQUESTED audio cannot start.

    SIDE is `capture' or `playback'.  The line names the programs that
    would make it work, in preference order, so the fix is visible
    without reading the source.
    """
    index = 0 if side == "capture" else 1
    if requested and requested != AUDIO_AUTO:
        backend = audio_backend(requested)
        if backend is None:
            return "audio backend unknown · %s" % requested
        return "%s command unavailable · %s" % (
            AUDIO_SIDES[side], backend.programs[index])
    programs = [backend.programs[index] for backend in AUDIO_BACKENDS]
    return "%s unavailable · %s" % (AUDIO_SIDES[side], _listed(programs))


class Player:
    """Play raw PCM16 mono through a subprocess, cancellably.

    Emacs owns interruption, so every gap in playback has to be visible:
    ``stop`` kills the process at once and ``busy`` reports the tail of
    the audio still queued, which the sidecar turns into
    ``speaking``/``listening``.

    A writer thread feeds the player's pipe, so ``play`` returns at once.
    Writing a reply straight from the sidecar's loop would block once the
    pipe's buffer filled, and the microphone and the speech gate with it:
    a person speaking over the assistant then could not be heard until
    the reply was almost over.  The queue is bounded so a caller that
    runs ahead of real time cannot grow it without limit.

    The player takes the first installed backend that starts.  One that
    dies is dropped and the next one is tried, so a missing aplay or a
    PipeWire session that stopped does not leave a silent session
    behind: ``error`` says what happened.  ``stop`` keeps the selected
    backend and the next ``play`` starts it again: an interruption, not
    a broken service, must not leave the assistant mute.
    """

    #: Most audio queued for the writer, in seconds.  Beyond it the
    #: oldest audio is dropped, so a caller that never waits cannot grow
    #: the queue without bound.
    QUEUE_SECONDS = 120.0

    def __init__(self, rate=GPT_RATE, command=None, backend=AUDIO_AUTO):
        self.rate = rate
        self.command = list(command) if command else None
        self.requested = backend or AUDIO_AUTO
        self.backend = None
        self.error = None
        self._candidates = None
        self._candidate = 0
        self._process = None
        self._until = 0.0
        self._queue = collections.deque()
        self._queued = 0
        self._writer = None
        self._wake = threading.Event()
        self._closing = False
        self._lock = threading.Lock()
        self.played = 0
        self._level = 0.0

    def candidates(self):
        """Return the playback commands this player may try, in order."""
        if self._candidates is None:
            if self.command:
                self._candidates = [(self.command[0], self.command)]
            else:
                self._candidates = [(backend.name, backend.play_command(self.rate))
                                    for backend in audio_backends(self.requested)]
        return self._candidates

    def available(self):
        """Return nil, or why this player cannot start."""
        if self.candidates():
            return None
        return audio_missing_reason(self.requested, "playback")

    def level(self):
        """Return the level of the audio still playing, in [0, 1]."""
        return self._level if self.busy() else 0.0

    def _start(self):
        """Start the next playback backend; called with the lock held."""
        pending = self.candidates()
        while self._candidate < len(pending):
            name, command = pending[self._candidate]
            if shutil.which(command[0]):
                try:
                    process = subprocess.Popen(
                        command, stdin=subprocess.PIPE,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        preexec_fn=die_with_parent())
                except OSError as error:
                    self.error = "speaker failed · %s: %s" % (command[0], error)
                else:
                    self.backend = name
                    self._process = process
                    self.error = None
                    log("playback · %s" % " ".join(command))
                    return True
            self._candidate += 1
        # Every backend failed: a later play starts the list again rather
        # than leaving the session mute after a transient failure.
        self._candidate = 0
        if self.error is None:
            self.error = audio_missing_reason(self.requested, "playback")
        return False

    def play(self, pcm):
        """Queue PCM16 bytes for playback and return at once."""
        if not pcm:
            return
        with self._lock:
            if self._closing:
                return
            self._queue.append(pcm)
            self._queued += len(pcm)
            limit = int(self.QUEUE_SECONDS * 2 * self.rate)
            while self._queued > limit and len(self._queue) > 1:
                dropped = self._queue.popleft()
                self._queued -= len(dropped)
                log("playback queue full · dropped %d bytes" % len(dropped))
            self._level = max(self._level * 0.6, pcm_energy(pcm))
            self._until = (max(time.monotonic(), self._until)
                           + len(pcm) / (2.0 * self.rate))
            if self._writer is None or not self._writer.is_alive():
                self._writer = threading.Thread(
                    target=self._write_loop, name="voice-player", daemon=True)
                self._writer.start()
        self._wake.set()

    def _write_loop(self):
        """Write queued PCM to the player's pipe, off the sidecar's loop."""
        while True:
            with self._lock:
                if self._closing:
                    return
                if not self._queue:
                    chunk = None
                    process = None
                else:
                    chunk = self._queue.popleft()
                    self._queued -= len(chunk)
                    if self._process is None or self._process.poll() is not None:
                        self._discard()
                        if not self._start():
                            self._fail()
                            continue
                        # A new process starts with whatever is queued
                        # now, so the projected end of playback is here,
                        # not where the enqueue that preceded the stall
                        # put it.
                        self._until = time.monotonic() + (
                            len(chunk) + self._queued) / (2.0 * self.rate)
                    process = self._process
            if chunk is None:
                self._wake.wait(0.2)
                self._wake.clear()
                continue
            try:
                process.stdin.write(chunk)
                process.stdin.flush()
            except (BrokenPipeError, ValueError, OSError) as error:
                log("playback lost · %s: %s" % (self.backend, error))
                with self._lock:
                    if process is self._process:
                        self._discard()
                        self._fail()
                continue
            with self._lock:
                self.played += len(chunk)

    def _fail(self):
        """Forget queued audio after a backend failure; locked."""
        self._queue.clear()
        self._queued = 0
        self._until = 0.0

    def busy(self):
        """Non-nil while the queued audio is still playing."""
        with self._lock:
            if self._queue:
                return True
            return time.monotonic() < self._until

    def _discard(self):
        """Kill the playing process; called with the lock held."""
        process, self._process = self._process, None
        self._until = 0.0
        if process is None:
            return
        try:
            process.kill()
        except OSError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        try:
            process.stdin.close()
        except (BrokenPipeError, ValueError, OSError):
            pass

    def stop(self):
        """Silence playback now and forget what was queued."""
        with self._lock:
            self._queue.clear()
            self._queued = 0
            self._discard()

    def close(self):
        """Stop playback and close the pipe."""
        with self._lock:
            self._closing = True
            self._queue.clear()
            self._queued = 0
            self._until = 0.0
            process, self._process = self._process, None
            writer, self._writer = self._writer, None
        self._wake.set()
        if process is not None:
            try:
                process.kill()
            except OSError:
                pass
        if writer is not None:
            writer.join(timeout=2)
        if process is None:
            return
        try:
            process.stdin.close()
        except (BrokenPipeError, ValueError, OSError):
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


class Recorder:
    """Raw PCM16 mono from the microphone, through a subprocess.

    The first installed backend starts.  One that exits, or that sends
    nothing at all for ``STALL_SECONDS``, is dropped and the next one is
    tried: a machine whose PipeWire session is down still records
    through its PulseAudio compatibility or its ALSA devices.  A backend
    that delivered audio and then stopped is replaced the same way, so a
    microphone that goes away leaves a working session rather than a
    dead one.

    ``backend`` names the backend in use, and ``error`` the last
    failure, which a sidecar reports to Emacs instead of waiting on a
    stream that will never speak.
    """

    #: Seconds without a single sample before a backend counts as broken.
    STALL_SECONDS = 5.0

    def __init__(self, rate=GPT_RATE, command=None, backend=AUDIO_AUTO):
        self.rate = rate
        self.command = list(command) if command else None
        self.requested = backend or AUDIO_AUTO
        self.backend = None
        self.error = None
        self._candidates = None
        self._process = None
        self._started = 0.0
        self._last = 0.0
        self._heard = 0
        self._carry = b""

    def candidates(self):
        """Return the capture commands this recorder has still to try."""
        if self._candidates is None:
            if self.command:
                self._candidates = [(self.command[0], self.command)]
            else:
                self._candidates = [(backend.name, backend.capture_command(self.rate))
                                    for backend in audio_backends(self.requested)]
        return self._candidates

    def available(self):
        """Return nil, or why this recorder cannot start."""
        if self.candidates():
            return None
        return audio_missing_reason(self.requested, "capture")

    def exhausted(self):
        """Return whether every backend was tried and none still runs."""
        return self._process is None and not self.candidates()

    def open(self):
        """Start capture on the next backend, unless it already runs."""
        if self._process is not None and self._process.poll() is None:
            return
        pending = self.candidates()
        while pending:
            name, command = pending.pop(0)
            if not shutil.which(command[0]):
                continue
            try:
                process = subprocess.Popen(
                    command, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    preexec_fn=die_with_parent())
            except OSError as error:
                self.error = "microphone failed · %s: %s" % (command[0], error)
                continue
            self.backend = name
            self._process = process
            self._started = self._last = time.monotonic()
            self._heard = 0
            self._carry = b""
            self.error = None
            log("capture · %s" % " ".join(command))
            return
        if self.error is None:
            self.error = audio_missing_reason(self.requested, "capture")

    def read(self, frames, timeout=0.2):
        """Return up to FRAMES samples as PCM16 bytes, or b"" when none yet.

        FRAMES is the most one call takes, not the amount it waits for:
        reading what the pipe holds drains a backlog a late tick left
        behind, where a tick-sized read would leave the pipe full and make
        the sound server drop audio.  A byte that ends a read in the middle
        of a sample is carried to the next one, so a split write cannot
        shift every later sample by a byte.
        """
        self.open()
        process = self._process
        if process is None or process.stdout is None:
            return b""
        try:
            ready, _, _ = select.select([process.stdout], [], [], timeout)
        except (OSError, ValueError):
            ready = []
        if ready:
            try:
                chunk = os.read(process.stdout.fileno(), frames * 2)
            except (OSError, ValueError):
                chunk = b""
            if chunk:
                heard = len(chunk)
                if self._carry:
                    chunk = self._carry + chunk
                    self._carry = b""
                if len(chunk) % 2:
                    self._carry = chunk[-1:]
                    chunk = chunk[:-1]
                self._heard += heard
                self._last = time.monotonic()
                if chunk:
                    return chunk
        if process.poll() is not None:
            self._died(process)
        elif time.monotonic() - self._last > self.STALL_SECONDS:
            self._died(process, "no audio")
        return b""

    def _died(self, process, reason=None):
        """Forget PROCESS, remember why it ended, and free the next backend."""
        if process is self._process:
            self._process = None
        self._carry = b""
        try:
            process.kill()
        except OSError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        message = self._stderr_text(process) or reason
        self._close_streams(process)
        if self._heard:
            self.error = "microphone stopped · %s%s" % (
                self.backend or "recorder", _after(message))
            log("capture stopped · %s" % self.error)
        else:
            self.error = "microphone unavailable · %s%s" % (
                self.backend or "recorder", _after(message))
            log("capture failed · %s" % self.error)
        self._heard = 0

    @staticmethod
    def _stderr_text(process):
        """Return the last line PROCESS wrote to stderr, or an empty string."""
        try:
            data = process.stderr.read() or b""
        except (OSError, ValueError, AttributeError):
            return ""
        lines = [line.strip() for line in data.decode("utf-8", "replace").splitlines()
                 if line.strip()]
        return lines[-1][:200] if lines else ""

    @staticmethod
    def _close_streams(process):
        """Close PROCESS's pipes after it ended."""
        for stream in (getattr(process, "stdout", None),
                       getattr(process, "stderr", None)):
            if stream is None:
                continue
            try:
                stream.close()
            except (OSError, ValueError):
                pass

    def close(self):
        """Stop the recorder."""
        process, self._process = self._process, None
        self._carry = b""
        if process is None:
            return
        try:
            process.kill()
        except OSError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        self._close_streams(process)


def _after(message):
    """Return MESSAGE as a ` · message' suffix, or an empty string."""
    return " · %s" % message if message else ""


class NullAudio:
    """A silent recorder and a player that only counts bytes, for tests."""

    def __init__(self, chunks=None):
        self.chunks = list(chunks or [])
        self.played = b""

    def available(self):
        return None

    def open(self):
        pass

    def read(self, frames, timeout=0.2):
        if self.chunks:
            return self.chunks.pop(0)
        return b""

    def play(self, pcm):
        self.played += pcm

    def busy(self):
        return False

    def level(self):
        return 0.0

    def stop(self):
        pass

    def close(self):
        pass


#; ------------------------------------------------------------------
#; Telemetry
#; ------------------------------------------------------------------

class LevelMeter:
    """Report the microphone's level at a bounded rate.

    The level is measured on the PCM the capture loop just read, before
    the speech filter sees it, so it answers "is the microphone reaching
    the app" rather than "did the filter keep anything".  One event per
    captured chunk would flood the control pipe, and a timer would report
    a level nobody measured in between: the capture loop offers each
    chunk and this keeps the ones that are due.
    """

    def __init__(self, interval=0.1):
        self.interval = interval
        self._last = None

    def measure(self, pcm, now=None):
        """Return the level to report for PCM, or None when it is not due."""
        now = time.monotonic() if now is None else now
        if self._last is not None and now - self._last < self.interval:
            return None
        self._last = now
        return pcm_energy(pcm)


#; ------------------------------------------------------------------
#; Voice detection
#; ------------------------------------------------------------------

class SpeechDetector:
    """Frame-wise speech activity, for gating output before STT exists.

    Energy alone calls a fan, a hum or the assistant's own speaker speech.
    A frame therefore also has to look voiced (zero-crossing rate) and carry
    change above a low hum (the first difference relative to its level).
    While the player is speaking, the onset threshold rises above the
    playback level and the hangover shortens, so a narrow-band echo cannot
    gate the assistant against itself; a voice louder than that echo still
    gets through.  This is not acoustic echo cancellation: an open speaker
    at a level close to the voice needs headphones or a real AEC.

    ``feed`` returns ``("start",)`` after ONSET_HOLD seconds of speech and
    ``("end",)`` after HANGOVER seconds without it.  The onset is the
    signal the gate uses; it is deliberately much earlier than a full
    utterance or a transcription.

    The noise floor is only learned from frames that do not look voiced.
    A frame that fails the energy test but has the zero-crossing and
    first-difference shape of voice is a quiet or missed word, not room
    noise: learning it would let one missed utterance raise the threshold
    that must then miss the next.  The floor follows a quieter frame down
    faster than a louder one up, and digital silence counts as a
    measurement, so a burst of speech leaves the configured threshold
    behind rather than a raised one.  It is frozen while the gate is
    active and while the assistant's player is audible, where the
    microphone is hearing the person or the speaker rather than the room.
    """

    #: Per-frame rates at which the noise floor follows a quiet frame down
    #: and a louder one up; a 10 ms frame makes decay about 100 ms.
    noise_rise = 0.02
    noise_decay = 0.1

    def __init__(self, rate=LOCAL_RATE, threshold=0.004, frame=0.01,
                 onset_hold=0.03, hangover=0.85, echo_hold=0.20,
                 echo_margin=1.8):
        self.rate = rate
        self.threshold = threshold
        self.frame_seconds = frame
        self.frame_bytes = max(2, int(rate * frame) * 2)
        self.onset_hold = onset_hold
        self.hangover = hangover
        self.echo_hold = echo_hold
        self.echo_margin = echo_margin
        self.active = False
        self.last_loud = False
        self.last_energy = 0.0
        self._pending = b""
        self._loud_for = 0.0
        self._quiet_for = 0.0
        self._noise = 0.0
        self._playback = 0.0

    def set_playback(self, level):
        """Tell the detector how loud the assistant's player is now."""
        self._playback = max(0.0, float(level or 0.0))

    def reset(self):
        """Forget the current onset; keep what the room sounds like."""
        self.active = False
        self.last_loud = False
        self._pending = b""
        self._loud_for = 0.0
        self._quiet_for = 0.0

    @staticmethod
    def energy(pcm):
        """Return the mean absolute sample of PCM16 bytes, in [0, 1]."""
        return pcm_energy(pcm)

    @staticmethod
    def zero_crossing_rate(pcm):
        """Return sign changes per sample, ignoring exact zeroes."""
        count = len(pcm) // 2
        if count < 2:
            return 0.0
        previous = 0
        crossings = 0
        for (sample,) in struct.iter_unpack("<h", pcm[:count * 2]):
            sign = 1 if sample > 0 else (-1 if sample < 0 else 0)
            if sign and previous and sign != previous:
                crossings += 1
            if sign:
                previous = sign
        return crossings / (count - 1.0)

    @staticmethod
    def change_ratio(pcm):
        """Return mean sample-to-sample change relative to mean level.

        A 50 Hz hum is a nearly constant slope; voiced speech has harmonics
        and changes faster even at the same loudness.
        """
        count = len(pcm) // 2
        if count < 2:
            return 0.0
        values = struct.unpack("<%dh" % count, pcm[:count * 2])
        total = 0
        change = 0
        previous = values[0]
        for sample in values:
            total += sample if sample >= 0 else -sample
            delta = sample - previous
            change += delta if delta >= 0 else -delta
            previous = sample
        level = total / (count * 32768.0)
        if level <= 0.0:
            return 0.0
        return (change / (count * 32768.0)) / level

    def _threshold(self):
        """Return the frame energy this detector calls speech.

        The configured THRESHOLD is the floor under a quiet microphone;
        the room's learned noise floor raises it to 2.5 times itself, so a
        fan, a hum or a room loud enough to matter is never speech.  The
        floor is deliberately far below a normal microphone's speech --
        0.004 against the 0.03 a speaking mouth gives -- because a quiet
        interface, an interface with its gain low, or a microphone across
        the room still carries words worth transcribing, and whisper
        needs no gain of its own for them.
        """
        threshold = max(self.threshold, self._noise * 2.5)
        if self._playback > 0.005:
            threshold = max(threshold, self._playback * self.echo_margin)
        return threshold

    def _learn_noise(self, energy):
        """Move the noise floor toward ENERGY, faster down than up.

        Digital silence is a measurement, not a missing one: a true pause
        has to decay the floor, or the raised threshold from the previous
        utterance outlives the sound that caused it.
        """
        energy = min(0.05, max(0.0, energy))
        if self._noise <= 0.0:
            self._noise = energy
            return
        rate = self.noise_decay if energy < self._noise else self.noise_rise
        self._noise = min(0.05, max(0.0,
                                      self._noise + (energy - self._noise) * rate))

    def classify(self, frame):
        """Return whether one PCM16 frame is likely human speech."""
        energy = pcm_energy(frame)
        self.last_energy = energy
        voice = False
        if energy > 0.0:
            voice = (self.zero_crossing_rate(frame) <= 0.35
                     and self.change_ratio(frame) >= 0.03)
        loud = energy >= self._threshold() and voice
        if (not loud and not voice and not self.active
                and self._playback <= 0.005
                and energy <= max(self.threshold, 0.03)):
            self._learn_noise(energy)
        self.last_loud = loud
        return loud

    def feed(self, pcm):
        """Consume PCM bytes, returning [("start",), ("end",), ...]."""
        output = []
        self._pending += pcm
        while len(self._pending) >= self.frame_bytes:
            frame = self._pending[:self.frame_bytes]
            self._pending = self._pending[self.frame_bytes:]
            loud = self.classify(frame)
            if not self.active:
                if loud:
                    self._loud_for += self.frame_seconds
                    if self._loud_for + 1e-9 >= self.onset_hold:
                        self.active = True
                        self._quiet_for = 0.0
                        output.append(("start",))
                else:
                    self._loud_for = 0.0
                continue
            if loud:
                self._quiet_for = 0.0
            else:
                self._quiet_for += self.frame_seconds
                hold = self.echo_hold if self._playback > 0.005 else self.hangover
                if self._quiet_for + 1e-9 >= hold:
                    self.active = False
                    self._loud_for = 0.0
                    self._quiet_for = 0.0
                    output.append(("end",))
        return output


class Vad:
    """Turn a continuous stream into utterances from speech activity.

    ``SpeechDetector`` decides when a person is speaking; this keeps a
    short pre-roll so the first syllable is not cut, ends an utterance
    HANGOVER seconds after the detector lets go, and bounds one so a noisy
    room cannot record forever.  Events are ``("start", ID)``,
    ``("end", ID)``, then ``("speech", PCM, ID)`` or ``("cancel", ID)``.
    A long dictation is one utterance up to MAX_SPEECH, not a prompt per
    natural pause.
    """

    def __init__(self, rate=LOCAL_RATE, threshold=0.004, frame=0.01,
                 hangover=0.85, pre_roll=0.3, min_speech=0.15,
                 max_speech=120.0, onset_hold=0.03, echo_hold=0.20,
                 echo_margin=1.8):
        self.rate = rate
        self.threshold = threshold
        self.hangover = hangover
        self.pre_roll_bytes = int(rate * pre_roll) * 2
        self.min_speech = min_speech
        self.max_speech = max_speech
        self.detector = SpeechDetector(
            rate=rate, threshold=threshold, frame=frame,
            onset_hold=onset_hold, hangover=hangover,
            echo_hold=echo_hold, echo_margin=echo_margin)
        self.frame_bytes = self.detector.frame_bytes
        self.frame_seconds = self.detector.frame_seconds
        self._pending = b""
        self._history = []
        self._tail = b""
        self._speech = b""
        self._uid = 0
        self._active_uid = None

    @property
    def gate_active(self):
        """Non-nil while the detector says a person is speaking now."""
        return self.detector.active

    def set_playback(self, level):
        """Tell the detector how loud the assistant's player is now."""
        self.detector.set_playback(level)

    @staticmethod
    def energy(pcm):
        """Return the mean absolute sample of PCM16 bytes, in [0, 1]."""
        return pcm_energy(pcm)

    def reset(self):
        """Forget the current utterance, keeping the noise estimate."""
        self.detector.reset()
        self._pending = b""
        self._history = []
        self._tail = b""
        self._speech = b""
        self._active_uid = None

    def _start(self, output):
        self._uid += 1
        self._active_uid = self._uid
        self._speech = self._tail or b"".join(self._history)
        self._history = []
        output.append(("start", self._uid))

    def _finish(self, output, final=False):
        uid = self._active_uid
        self._active_uid = None
        speech, self._speech = self._speech, b""
        self._history = []
        if uid is None:
            return
        seconds = len(speech) / (2.0 * self.rate)
        if seconds >= self.min_speech or (final and speech):
            output.append(("speech", speech, uid))
        else:
            output.append(("cancel", uid, seconds))

    def feed(self, pcm):
        """Consume PCM bytes, returning the events above, oldest first."""
        output = []
        self._pending += pcm
        while len(self._pending) >= self.frame_bytes:
            frame = self._pending[:self.frame_bytes]
            self._pending = self._pending[self.frame_bytes:]
            events = self.detector.feed(frame)
            for event in events:
                if event[0] == "start":
                    self._start(output)
                elif event[0] == "end":
                    uid = self._active_uid
                    if uid is not None:
                        output.append(("end", uid))
                    self._finish(output)
            if self._active_uid is not None:
                self._speech += frame
                self._tail = (self._tail + frame)[-self.pre_roll_bytes:]
                if len(self._speech) / (2.0 * self.rate) >= self.max_speech:
                    # A very long dictation is cut into another utterance
                    # rather than held in memory or dropped.
                    uid = self._active_uid
                    output.append(("speech", self._speech, uid))
                    self._uid += 1
                    self._active_uid = self._uid
                    self._speech = self._tail
                    output.append(("start", self._uid))
            else:
                self._history.append(frame)
                keep = max(1, int((self.pre_roll_bytes / 2.0)
                                  / (self.frame_bytes / 2.0))) + 4
                if len(self._history) > keep:
                    self._history = self._history[-keep:]
                self._tail = (self._tail + frame)[-self.pre_roll_bytes:]
        return output

    def flush(self):
        """End a speech still open when the session stops."""
        output = []
        if self._active_uid is not None:
            output.append(("end", self._active_uid))
            self._finish(output, final=True)
        self.detector.reset()
        self._pending = b""
        self._history = []
        self._tail = b""
        return output


#; ------------------------------------------------------------------
#; HTTP and WAV
#; ------------------------------------------------------------------

def wav_from_pcm(pcm, rate=LOCAL_RATE, channels=1, width=2):
    """Return PCM bytes wrapped in a WAV container."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(width)
        handle.setframerate(rate)
        handle.writeframes(pcm)
    return buffer.getvalue()


def pcm_from_wav(data, rate=LOCAL_RATE):
    """Return a WAV file's frames as PCM16 mono at RATE.

    Speech services answer at their own rate -- Kokoro and OpenAI at
    24 kHz, Piper at 16 or 22.05 kHz -- while the local sidecar plays
    at ``LOCAL_RATE``.  The frames are therefore downmixed to mono and
    resampled when RATE differs, so a reply keeps its speed and pitch.

    A streamed reply carries a RIFF and data size of 0xffffffff; the
    wave module then reads every frame to the end of the body, which is
    what a chunked OpenAI-compatible server sends.
    """
    with wave.open(io.BytesIO(data), "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        source = handle.getframerate()
        raw = handle.readframes(handle.getnframes())
    if width != 2:
        raise ValueError("WAV sample width %d" % width)
    if channels < 1 or source <= 0 or rate <= 0:
        raise ValueError("WAV audio format")
    samples = array.array("h")
    samples.frombytes(raw[:len(raw) - len(raw) % 2])
    if sys.byteorder == "big":
        samples.byteswap()
    if channels > 1:
        samples = array.array(
            "h", (int(round(sum(samples[start:start + channels]) / channels))
                  for start in range(0, len(samples) - channels + 1, channels)))
    if source != rate and samples:
        count = int(round(len(samples) * rate / source))
        resampled = array.array("h", bytes(2 * count))
        last = len(samples) - 1
        ratio = source / float(rate)
        for index in range(count):
            position = index * ratio
            before = int(position)
            if before >= last:
                resampled[index] = samples[last]
            else:
                fraction = position - before
                first = samples[before]
                resampled[index] = int(round(
                    first + (samples[before + 1] - first) * fraction))
        samples = resampled
    if sys.byteorder == "big":
        samples.byteswap()
    return samples.tobytes()


def http_json(url, payload=None, headers=None, timeout=60, method=None):
    """POST or GET JSON, returning the decoded body and its status."""
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, method=method or ("POST" if body else "GET"))
    request.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read()
        if not data:
            return {}
        try:
            return json.loads(data.decode("utf-8"))
        except ValueError:
            return {"data": data}


def http_multipart(url, fields, filename, data, headers=None, timeout=120):
    """POST a multipart form with one file field, returning the body."""
    boundary = "----harnessvoice%d" % int(time.time() * 1000)
    parts = []
    for name, value in fields.items():
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                      % (boundary, name, value)).encode("utf-8"))
    parts.append(("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
                  "Content-Type: audio/wav\r\n\r\n" % (boundary, filename)).encode("utf-8"))
    parts.append(data)
    parts.append(("\r\n--%s--\r\n" % boundary).encode("utf-8"))
    body = b"".join(parts)
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "multipart/form-data; boundary=%s" % boundary)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


#; ------------------------------------------------------------------
#; WebSocket
#; ------------------------------------------------------------------

class WebSocket:
    """A small RFC 6455 client: text frames, TLS, ping and close.

    GPT-Live takes JSON events over one WebSocket.  Keeping the client
    here rather than importing a package keeps the sidecar to the
    Python standard library, like the other adapters in ``scripts``.
    """

    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self, url, headers=None, timeout=30):
        self.url = url
        self.headers = dict(headers or {})
        self.timeout = timeout
        self.sock = None
        self._buffer = b""

    def connect(self):
        """Open the socket and complete the HTTP upgrade."""
        from urllib.parse import urlparse

        parsed = urlparse(self.url)
        secure = parsed.scheme == "wss"
        host = parsed.hostname
        port = parsed.port or (443 if secure else 80)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        raw = socket.create_connection((host, port), timeout=self.timeout)
        if secure:
            context = ssl.create_default_context()
            raw = context.wrap_socket(raw, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        lines = ["GET %s HTTP/1.1" % path,
                 "Host: %s" % host,
                 "Upgrade: websocket",
                 "Connection: Upgrade",
                 "Sec-WebSocket-Key: %s" % key,
                 "Sec-WebSocket-Version: 13"]
        for name, value in self.headers.items():
            lines.append("%s: %s" % (name, value))
        raw.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("utf-8"))
        self.sock = raw
        response = self._read_until(b"\r\n\r\n")
        head = response.decode("latin-1")
        if " 101 " not in head.split("\r\n")[0]:
            raise OSError("WebSocket upgrade refused: %s" % head.split("\r\n")[0])
        expected = base64.b64encode(
            __import__("hashlib").sha1((key + self.GUID).encode("ascii")).digest()
        ).decode("ascii")
        if ("sec-websocket-accept: %s" % expected).lower() not in head.lower():
            raise OSError("WebSocket upgrade: bad accept key")
        return self

    def _read_until(self, marker):
        while marker not in self._buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise OSError("WebSocket closed during handshake")
            self._buffer += chunk
        head, self._buffer = self._buffer.split(marker, 1)
        return head

    def _read_exact(self, count):
        while len(self._buffer) < count:
            chunk = self.sock.recv(max(4096, count - len(self._buffer)))
            if not chunk:
                raise OSError("WebSocket closed")
            self._buffer += chunk
        data, self._buffer = self._buffer[:count], self._buffer[count:]
        return data

    def _send_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        mask = os.urandom(4)
        header += mask
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def send_text(self, text):
        """Send one text frame."""
        self._send_frame(0x1, text.encode("utf-8"))

    def send_json(self, payload):
        """Send PAYLOAD as one JSON text frame."""
        self.send_text(json.dumps(payload, separators=(",", ":")))

    def recv(self, timeout=None):
        """Return the next complete text message, or None on timeout."""
        if self.sock is None:
            return None
        if timeout is not None:
            self.sock.settimeout(timeout)
        try:
            while True:
                first, second = self._read_exact(2)
                opcode = first & 0x0F
                masked = bool(second & 0x80)
                length = second & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self._read_exact(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self._read_exact(8))[0]
                mask = self._read_exact(4) if masked else b""
                payload = self._read_exact(length)
                if masked:
                    payload = bytes(byte ^ mask[index % 4]
                                    for index, byte in enumerate(payload))
                if opcode == 0x8:
                    raise OSError("WebSocket closed by server")
                if opcode == 0x9:
                    self._send_frame(0xA, payload)
                    continue
                if opcode == 0xA:
                    continue
                if opcode in (0x1, 0x2):
                    return payload.decode("utf-8")
        except socket.timeout:
            return None

    def close(self):
        """Send a close frame and close the socket."""
        if self.sock is None:
            return
        try:
            self._send_frame(0x8, b"")
        except (OSError, AttributeError):
            pass
        sock, self.sock = self.sock, None
        try:
            sock.close()
        except OSError:
            pass


#; ------------------------------------------------------------------
#; Sidecar skeleton
#; ------------------------------------------------------------------

class Sidecar:
    """The command handling both sidecars share.

    Subclasses implement ``on_speech`` (a finished utterance or a
    delegation result), ``speak`` and the service-specific start and
    stop.  This class keeps the captions, the mute state, the playback
    indicator and the reply queue in one place so the two sidecars
    behave the same from Emacs's point of view.
    """

    def __init__(self, events=None, player=None, rate=GPT_RATE):
        self.events = events or Events()
        self.player = player
        self.rate = rate
        self.muted = False
        self.speaking = False
        self.working = False
        self.delegations = []
        self.caption = ""
        self.loop = None
        self.speech_active = False
        self.held = []
        self.held_seq = 0
        self.level_meter = LevelMeter()

    # -- lifecycle ---------------------------------------------------

    def announce(self):
        """Tell Emacs the sidecar is ready for audio."""
        self.events.send("ready", provider=self.provider, protocol=PROTOCOL)
        self.events.send("listening")

    def start_session(self, event):
        """Handle the harness's `start` command."""
        self.speech_active = False
        self.held = []
        self.announce()
        self.on_start()

    def close(self, reason="stopped"):
        """End the session: flush, stop playback and report closed."""
        try:
            self.on_stop()
        finally:
            if self.player:
                self.player.close()
            self.events.send("closed", reason=reason)

    def finish(self, reason="stopped", code=0):
        """End the session and stop this sidecar's loop."""
        self.close(reason)
        if self.loop is not None:
            self.loop.stop(code)

    # -- commands ----------------------------------------------------

    def handle(self, event):
        """Dispatch one harness command."""
        kind = event.get("event")
        if kind == "start":
            self.start_session(event)
        elif kind == "mute":
            self.muted = bool(event.get("on"))
            self.on_mute(self.muted)
        elif kind == "interrupt":
            self.interrupt()
        elif kind == "stop":
            self.finish("sidecar stopped")
        elif kind == "commentary":
            self.on_commentary(event.get("text") or "", event)
        elif kind == "thinking":
            self.on_thinking(event.get("text") or "")
        elif kind == "delegate_result":
            self.on_delegate_result(event)
        else:
            log("ignored %s" % kind)

    def announce_level(self, level):
        """Report the microphone's level before the speech filter."""
        if level is not None:
            self.events.send("level", input=round(float(level), 3))

    def notice(self, message):
        """Report a problem the session survives, in one line.

        A notice names what one reply or one utterance could not do; the
        microphone stays open and the next turn is tried as usual.  Only
        a failure no session can continue from sends ``error``
        (``fail``), which ends the call.
        """
        self.events.send("notice", message=message)

    def announce_segment(self, state, uid, seconds=None, reason=None):
        """Report one burst's own decision: accepted, or dropped."""
        fields = {"state": state, "id": "u-%s" % uid}
        if seconds is not None:
            fields["seconds"] = round(float(seconds), 2)
        if reason:
            fields["reason"] = reason
        self.events.send("segment", **fields)

    def announce_speech(self, active, utterance=None, reason=None):
        """Report the low-latency speech gate to Emacs.

        ``active`` is true as soon as ONSET_HOLD seconds of speech were
        heard, long before an utterance has ended or a transcription
        exists.  It is false when the detector lets go.  Emacs uses the
        edge, not the text, to hold assistant output.
        """
        active = bool(active)
        if active == self.speech_active and reason is None:
            return
        self.speech_active = active
        self.events.send("speech", active=active, utterance=utterance,
                         reason=reason or ("onset" if active else "hangover"))

    def interrupt(self):
        """Stop playback now; the agent turn keeps running in Emacs."""
        if self.player:
            self.player.stop()
        self.held = []
        self.speaking = False
        self.announce_listening()
        self.events.send("interrupted")

    def announce_listening(self):
        """Report that the speaker is silent."""
        if self.speaking:
            self.speaking = False
        self.events.send("listening")

    def announce_speaking(self):
        """Report that audio is playing."""
        if not self.speaking:
            self.speaking = True
        self.events.send("speaking")

    def tick_playback(self):
        """Turn the player's queue into speaking/listening events."""
        if self.speaking and self.player and not self.player.busy():
            self.announce_listening()

    def play(self, pcm):
        """Play PCM bytes, reporting the speaker as busy.

        While the person is speaking no reply audio starts: the gate owns
        the output.  A sidecar that already synthesized audio keeps the
        text and reports it as held instead of replaying it later.
        """
        if not pcm or self.muted or self.speech_active:
            return False
        if self.player is None:
            return False
        self.player.play(pcm)
        self.announce_speaking()
        return True

    # -- held output -------------------------------------------------

    def hold(self, text, item_id=None):
        """Remember reply TEXT that was not spoken, for the pending context.

        The id is the commentary piece's id when Emacs supplied one, so
        the client can merge its own held pieces and this sidecar's
        without counting one twice.
        """
        text = (text or "").strip()
        if not text:
            return
        if not item_id:
            self.held_seq += 1
            item_id = "held-%d" % self.held_seq
        if any(item.get("id") == item_id for item in self.held):
            return
        if any(item.get("text") == text for item in self.held):
            return
        self.held.append({"id": item_id, "text": text[:4000]})
        if len(self.held) > 20:
            self.held = self.held[-20:]

    def take_pending(self):
        """Return and forget the held reply pieces."""
        pending, self.held = self.held, []
        return pending

    # -- delegations -------------------------------------------------

    def delegation(self, text, delegation_id=None, final=True, pending=None,
                   utterance=None):
        """Ask the harness's agent for work, with the spoken transcript."""
        text = (text or "").strip()
        if not text:
            return
        delegation_id = delegation_id or "d-%d" % int(time.time() * 1000)
        self.working = True
        fields = {"id": delegation_id, "text": text, "final": bool(final)}
        if pending:
            fields["pending"] = list(pending)
        if utterance is not None:
            fields["utterance"] = utterance
        fields["speech_active"] = bool(self.speech_active)
        self.events.send("delegation", **fields)

    def on_delegate_result(self, event):
        """Handle the agent's answer: speak it and end the work state."""
        self.working = False
        delegation_id = event.get("id")
        text = event.get("text") or ""
        held = bool(event.get("held"))
        if event.get("error"):
            message = event.get("message") or "delegation failed"
            self.events.send("assistant_delta", text=message, final=True)
            if held:
                self.hold("result:%s" % (delegation_id or "error"), message)
                self.on_held_result(delegation_id, message)
            else:
                self.on_result(delegation_id, message, message)
            return
        self.events.send("assistant_delta", text=text, final=True)
        if held:
            # The full result is the pending update; piece-level ids were
            # already reported as commentary while speech was active.
            self.hold(text, "result:%s" % (delegation_id or "held"))
            self.on_held_result(delegation_id, text)
            return
        self.on_result(delegation_id, text, None)

    # -- hooks -------------------------------------------------------

    provider = "sidecar"
    def on_start(self): pass
    def on_stop(self): pass
    def on_mute(self, muted): pass
    def on_commentary(self, text, event=None): pass
    def on_thinking(self, text): pass
    def on_result(self, delegation_id, text, error): pass
    def on_held_result(self, delegation_id, text): pass
    def on_speech(self, pcm): pass


#; ------------------------------------------------------------------
#; Tests
#; ------------------------------------------------------------------

class FakeEvents:
    """A stand-in for Emacs that records the events a sidecar sends."""

    def __init__(self):
        self.sent = []

    def send(self, event, **fields):
        message = {"event": event}
        message.update(fields)
        self.sent.append(message)

    def names(self):
        return [event.get("event") for event in self.sent]


class FakeConnection:
    """A stand-in for a WebSocket that records sends and replays events."""

    def __init__(self, incoming=None):
        self.incoming = list(incoming or [])
        self.sent = []
        self.closed = False

    def connect(self):
        return self

    def send_json(self, payload):
        self.sent.append(payload)

    def recv(self, timeout=None):
        if not self.incoming:
            return None
        item, self.incoming = self.incoming[0], self.incoming[1:]
        if isinstance(item, str):
            return item
        return json.dumps(item)

    def close(self):
        self.closed = True


def self_test_failed(message):
    """Print one failure line for --self-test and exit nonzero."""
    sys.stderr.write("self-test failed: %s\n" % message)
    return 1


def self_test_ok(name):
    """Print the one line --self-test writes on success."""
    sys.stdout.write("self-test ok · %s\n" % name)
    sys.stdout.flush()
    return 0


def self_test_audio():
    """Check the audio backend table and its failover without hardware.

    Returns a failure line, or nil when the backends keep their
    preference order, each builds a command for the rate it is given,
    and a recorder whose first program dies falls through to the next
    installed backend instead of leaving a silent session.
    """
    names = [backend.name for backend in AUDIO_BACKENDS]
    if names != ["pipewire", "pulse", "alsa", "ffmpeg"]:
        return "audio backend order · %s" % names
    if audio_backend_names() != [AUDIO_AUTO] + names:
        return "audio backend names"
    if audio_backend("no-such-backend") is not None:
        return "unknown audio backend accepted"
    for backend in AUDIO_BACKENDS:
        capture = backend.capture_command(GPT_RATE)
        play = backend.play_command(GPT_RATE)
        if capture[0] != backend.programs[0] or play[0] != backend.programs[1]:
            return "audio programs · %s" % backend.name
        if str(GPT_RATE) not in " ".join(capture) or str(GPT_RATE) not in " ".join(play):
            return "audio rate · %s" % backend.name
    forced = audio_backends("alsa")
    if [backend.name for backend in forced] not in ([], ["alsa"]):
        return "forced backend falls back"
    work = tempfile.mkdtemp(prefix="harness-audio-")
    original = os.environ.get("PATH", "")
    try:
        # pw-record dies at once; parec keeps sending silence.  A recorder
        # that starts on the first must end up on the second.
        scripts = {
            "pw-record": "#!/bin/sh\nexit 3\n",
            "pw-play": "#!/bin/sh\nexit 0\n",
            "paplay": "#!/bin/sh\nexit 0\n",
            "parec": ("#!/usr/bin/env python3\n"
                      "import sys, time\n"
                      "while True:\n"
                      "    sys.stdout.buffer.write(b'\\x00' * 640)\n"
                      "    sys.stdout.buffer.flush()\n"
                      "    time.sleep(0.02)\n"),
        }
        for name, body in scripts.items():
            path = os.path.join(work, name)
            with open(path, "w") as handle:
                handle.write(body)
            os.chmod(path, 0o755)
        os.environ["PATH"] = work + os.pathsep + original
        recorder = Recorder(GPT_RATE)
        chunk = b""
        deadline = time.monotonic() + 5
        try:
            while time.monotonic() < deadline and not chunk:
                chunk = recorder.read(320)
            if not chunk:
                return "audio failover · no audio"
            if recorder.backend != "pulse":
                return "audio failover · %s" % recorder.backend
        finally:
            recorder.close()
    finally:
        os.environ["PATH"] = original
        shutil.rmtree(work, ignore_errors=True)
    return None
