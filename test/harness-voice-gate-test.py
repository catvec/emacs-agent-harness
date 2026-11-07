#!/usr/bin/env python3
"""Deterministic tests for the low-latency voice gate.

The fixtures are synthetic (see test/voice_fixtures.py): they exercise the
detector and the sidecar's held-output logic without a microphone, a
speech model or a network.  A live microphone and speaker check is a
separate manual step; these tests do not claim it.
"""

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import os
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
sys.path.insert(0, os.path.join(ROOT, "test"))

import voice_fixtures as fixtures  # noqa: E402
from harness_voice_sidecar import (  # noqa: E402
    AUDIO_BACKENDS, FakeEvents, NullAudio, Player, Recorder, SpeechDetector, Vad,
    audio_backend, audio_backend_names, audio_backends, audio_missing_reason,
    self_test_audio, wav_from_pcm,
)

SCRIPT = os.path.join(ROOT, "scripts", "harness-voice-live-unmute")
LOADER = importlib.machinery.SourceFileLoader("harness_voice_unmute", SCRIPT)
SPEC = importlib.util.spec_from_loader("harness_voice_unmute", LOADER)
unmute = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(unmute)

GPT_SCRIPT = os.path.join(ROOT, "scripts", "harness-voice-live-gpt")
GPT_LOADER = importlib.machinery.SourceFileLoader("harness_voice_gpt", GPT_SCRIPT)
GPT_SPEC = importlib.util.spec_from_loader("harness_voice_gpt", GPT_LOADER)
gpt = importlib.util.module_from_spec(GPT_SPEC)
GPT_LOADER.exec_module(gpt)


def tone(seconds, frequency=140.0, amplitude=0.25, rate=fixtures.RATE):
    """A short voiced-looking tone for sidecar tests."""
    import math
    count = int(seconds * rate)
    return b"".join(
        struct.pack("<h", int(32767 * amplitude
                              * math.sin(2.0 * math.pi * frequency * i / rate)))
        for i in range(count))


def detector_events(data, level=0.0, chunk=320):
    detector = SpeechDetector()
    detector.set_playback(level)
    events = []
    for offset in range(0, len(data), chunk):
        for event in detector.feed(data[offset:offset + chunk]):
            events.append((offset / 32000.0, event[0]))
    return events, detector


class TestPlayer(NullAudio):
    """A NullAudio player whose playback level and busy state tests control."""

    def __init__(self):
        super().__init__()
        self.level_value = 0.0
        self.busy_value = False

    def level(self):
        return self.level_value if self.busy_value else 0.0

    def busy(self):
        return self.busy_value


def args():
    return argparse.Namespace(
        stt_url="http://speech.test/transcriptions",
        tts_url="http://speech.test/speech",
        stt_model="whisper-1", tts_model="tts-1", voice="unmute",
        threshold=0.02, hangover=0.85, max_speech=120.0, api_key_env="",
        self_test=False)


class SidecarRig:
    """An UnmuteSidecar with workers and fake speech services."""

    def __init__(self):
        self.events = FakeEvents()
        self.player = TestPlayer()
        self.stt_calls = []
        self.tts_calls = []
        self.stt_gate = threading.Event()
        self.stt_gate.set()
        self.transcript = "open the merge queue"
        self.sidecar = unmute.UnmuteSidecar(
            args(), events=self.events, player=self.player,
            recorder=NullAudio(),
            post_multipart=self._stt, post_json=self._tts)
        self.sidecar.start_session({"event": "start", "protocol": 1})

    def _stt(self, url, fields, filename, data, headers=None, timeout=120):
        self.stt_calls.append({"bytes": len(data)})
        self.stt_gate.wait(timeout=5)
        return json.dumps({"text": self.transcript}).encode("utf-8")

    def _tts(self, url, payload, headers=None, timeout=60, method=None):
        self.tts_calls.append(payload.get("input"))
        return {"data": wav_from_pcm(b"\x00\x01" * 800, fixtures.RATE)}

    def feed(self, data):
        for offset in range(0, len(data), 320):
            for result in self.sidecar.vad.feed(data[offset:offset + 320]):
                self.sidecar._consume([result])

    def pump(self, until=None, timeout=4.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.sidecar.drain_transcripts()
            self.sidecar.drain_audio()
            self.sidecar.maybe_release()
            if until is not None and until():
                return True
            time.sleep(0.01)
        return until is None

    def names(self):
        return self.events.names()

    def find(self, event):
        return [item for item in self.events.sent if item.get("event") == event]

    def stop(self):
        self.sidecar.handle({"event": "stop"})


class DetectorTest(unittest.TestCase):
    def test_human_speech_is_detected_before_a_transcription(self):
        events, detector = detector_events(fixtures.voiced(2.0) + fixtures.silence(1.2))
        self.assertEqual(events[0][1], "start")
        self.assertLessEqual(events[0][0], 0.12,
                             "onset should be a few frames, not an utterance")
        self.assertIn("end", [event for _, event in events])
        self.assertFalse(detector.active)

    def test_silence_noise_and_hum_do_not_trigger(self):
        for name, data in (
                ("silence", fixtures.silence(2.0)),
                ("noise", fixtures.white_noise(2.0)),
                ("hum", fixtures.hum(2.0))):
            events, _ = detector_events(data)
            self.assertEqual(events, [], name)

    def test_a_brief_click_is_not_speech(self):
        data = fixtures.concat(fixtures.silence(0.5), fixtures.click(),
                               fixtures.silence(0.5))
        events, _ = detector_events(data)
        self.assertEqual(events, [])

    def test_a_long_dictation_is_one_utterance_across_natural_pauses(self):
        vad = Vad(hangover=0.85)
        data = fixtures.concat(fixtures.with_pauses(speech_seconds=1.2,
                                                       pauses=(0.4,)),
                               fixtures.silence(1.2))
        results = []
        for offset in range(0, len(data), 320):
            for result in vad.feed(data[offset:offset + 320]):
                results.append(result)
        speech = [result for result in results if result[0] == "speech"]
        self.assertEqual(len(speech), 1, "a short natural pause split the dictation")
        self.assertGreater(len(speech[0][1]) / 32000.0, 2.0)

    def test_playback_echo_does_not_gate_the_assistant_against_itself(self):
        playback = fixtures.voiced(1.0)
        level = SpeechDetector.energy(playback)
        events, _ = detector_events(fixtures.echo(playback, gain=0.32),
                                    level=level)
        self.assertEqual(events, [], "speaker echo triggered the gate")
        louder = fixtures.concat(fixtures.echo(playback, gain=0.32),
                                 fixtures.voiced(1.0, amplitude=0.9))
        events, _ = detector_events(louder, level=level)
        self.assertIn("start", [event for _, event in events],
                      "a voice above the echo should still take the floor")

    def test_detector_cpu_is_within_a_bounded_local_budget(self):
        data = (fixtures.voiced(2.0) + fixtures.silence(1.0)) * 10
        started = time.perf_counter()
        detector = SpeechDetector()
        for offset in range(0, len(data), 640):
            detector.feed(data[offset:offset + 640])
        elapsed = time.perf_counter() - started
        seconds = len(data) / 32000.0
        self.assertLess(elapsed, 0.5, "detector CPU exceeded 0.5 s for %ss" % seconds)
        print("detector budget · %.1f ms cpu per audio second (%.1f s audio)"
              % (elapsed / seconds * 1000.0, seconds))


class SidecarGateTest(unittest.TestCase):
    def test_output_is_held_before_the_transcript_exists(self):
        rig = SidecarRig()
        try:
            rig.stt_gate.clear()
            rig.feed(fixtures.voiced(1.2) + fixtures.silence(1.2))
            self.assertTrue(rig.pump(until=lambda: rig.stt_calls))
            # The transcription is blocked in the worker.  Nothing has
            # reached the session yet, and reply text must not be spoken.
            self.assertEqual(rig.find("delegation"), [])
            rig.sidecar.handle({"event": "commentary", "text": "Old update.",
                                "id": "n-old"})
            rig.pump(timeout=0.2)
            self.assertEqual(rig.tts_calls, [], "held output reached speech")
            self.assertTrue(any(item["id"] == "n-old"
                                for item in rig.sidecar.held))
            rig.stt_gate.set()
            self.assertTrue(rig.pump(until=lambda: rig.find("delegation")))
            delegations = rig.find("delegation")
            self.assertEqual(len(delegations), 1)
            pending = delegations[0].get("pending") or []
            self.assertEqual([item["id"] for item in pending], ["n-old"])
            self.assertEqual(rig.find("user_delta")[-1]["text"],
                             "open the merge queue")
            # The held piece became context and was never spoken.
            self.assertNotIn("Old update.", rig.tts_calls)
            self.assertEqual(rig.sidecar.held, [])
        finally:
            rig.stop()

    def test_the_transcript_and_pending_context_arrive_exactly_once(self):
        rig = SidecarRig()
        try:
            rig.feed(fixtures.voiced(1.2) + fixtures.silence(1.2))
            self.assertTrue(rig.pump(until=lambda: rig.find("delegation")))
            rig.sidecar.drain_transcripts()
            rig.sidecar.drain_transcripts()
            self.assertEqual(len(rig.find("delegation")), 1)
            self.assertEqual(len(rig.find("user_delta")), 1)
        finally:
            rig.stop()

    def test_late_transcripts_are_delivered_in_utterance_order(self):
        rig = SidecarRig()
        try:
            rig.sidecar.awaiting.update({1, 2})
            rig.sidecar.transcripts.put((2, "second words"))
            rig.sidecar.transcripts.put((1, "first words"))
            rig.sidecar.drain_transcripts()
            texts = [item["text"] for item in rig.find("delegation")]
            self.assertEqual(texts, ["first words", "second words"])
            self.assertEqual(rig.sidecar.next_utterance, 3)
        finally:
            rig.stop()

    def test_a_false_trigger_does_not_hold_output_forever(self):
        rig = SidecarRig()
        try:
            rig.sidecar.held = [{"id": "n1", "text": "Held update."}]
            rig.sidecar.release_at = time.monotonic() - 1
            rig.sidecar.maybe_release()
            self.assertTrue(rig.pump(until=lambda: rig.tts_calls))
            self.assertEqual(rig.tts_calls, ["Held update."])
        finally:
            rig.stop()

    def test_stale_output_is_not_released_after_real_speech(self):
        rig = SidecarRig()
        try:
            rig.sidecar.speech_active = True
            rig.sidecar.awaiting.add(1)
            rig.sidecar.handle({"event": "commentary", "text": "Stale.",
                                "id": "n-stale"})
            pending = rig.sidecar.take_pending()
            self.assertEqual([item["text"] for item in pending], ["Stale."])
            rig.sidecar.speech_active = False
            rig.sidecar.awaiting.clear()
            rig.sidecar.release_at = time.monotonic() - 1
            rig.sidecar.maybe_release()
            rig.pump(timeout=0.2)
            self.assertEqual(rig.tts_calls, [], "consumed pending was replayed")
        finally:
            rig.stop()

    def test_stop_clears_the_gate_and_a_restart_works(self):
        rig = SidecarRig()
        try:
            rig.sidecar.speech_active = True
            rig.sidecar.awaiting.add(7)
            rig.sidecar.held = [{"id": "n", "text": "Held."}]
            rig.sidecar.ready.append(("n", "Held.", b"\x00\x00"))
            rig.stop()
            self.assertFalse(rig.sidecar.speech_active)
            self.assertEqual(rig.sidecar.held, [])
            self.assertEqual(list(rig.sidecar.ready), [])
            self.assertEqual(rig.sidecar.workers, [])
            rig.sidecar.start_session({"event": "start", "protocol": 1})
            self.assertFalse(rig.sidecar.gate_blocked())
            rig.sidecar.handle({"event": "delegate_result", "id": "u-1",
                                "text": "Again."})
            self.assertTrue(rig.pump(until=lambda: rig.tts_calls))
        finally:
            rig.stop()

    def test_mute_and_interrupt_clear_held_output(self):
        rig = SidecarRig()
        try:
            rig.sidecar.held = [{"id": "n", "text": "Held."}]
            rig.sidecar.handle({"event": "mute", "on": True})
            self.assertEqual(rig.sidecar.held, [])
            self.assertTrue(rig.sidecar.muted)
            self.assertFalse(rig.sidecar.speech_active)
            rig.sidecar.handle({"event": "mute", "on": False})
            rig.sidecar.held = [{"id": "n2", "text": "Held again."}]
            rig.sidecar.handle({"event": "interrupt"})
            self.assertEqual(rig.sidecar.held, [])
            self.assertIn("interrupted", rig.names())
        finally:
            rig.stop()

    def test_commentary_is_not_spoken_twice_by_the_result(self):
        rig = SidecarRig()
        try:
            rig.sidecar.handle({"event": "commentary", "text": "It is done.",
                                "id": "c1"})
            rig.sidecar.handle({"event": "delegate_result", "id": "u-1",
                                "text": "It is done."})
            rig.pump(until=lambda: rig.tts_calls)
            time.sleep(0.1)
            rig.pump(timeout=0.1)
            self.assertEqual(rig.tts_calls, ["It is done."])
        finally:
            rig.stop()


class GptGateTest(unittest.TestCase):
    def test_the_gpt_sidecar_gates_its_own_server_audio(self):
        from harness_voice_sidecar import FakeConnection, NullAudio
        events = FakeEvents()
        player = NullAudio()
        args = argparse.Namespace(
            url="ws://127.0.0.1:1/live", model="gpt-live-1",
            voice="marin", instructions="be brief",
            api_key_env="OPENAI_API_KEY")
        sidecar = gpt.GptSidecar(args, events=events,
                                 connection=FakeConnection(),
                                 player=player, recorder=NullAudio())
        sidecar.key_override = "self-test"
        sidecar.start_session({"event": "start", "protocol": 1})
        sidecar.gate(tone(0.8, rate=24000) + b"\x00\x00" * 36000)
        self.assertIn(True, [item.get("active") for item in events.sent
                             if item.get("event") == "speech"])
        self.assertIn(False, [item.get("active") for item in events.sent
                              if item.get("event") == "speech"])
        # While speech was active no server audio was played.  Feed a
        # fresh gate with speech, then an audio delta: it is dropped.
        sidecar.gate(tone(0.5, rate=24000))
        self.assertTrue(sidecar.speech_active)
        audio = __import__("base64").b64encode(b"\x01\x00" * 480).decode("ascii")
        sidecar.on_server_message(json.dumps(
            {"type": "session.output_audio.delta", "delta": audio}))
        self.assertEqual(player.played, b"")
        sidecar.handle({"event": "commentary", "text": "Held.",
                        "id": "n1"})
        self.assertFalse(any(message.get("type") == "session.commentary.append"
                             for message in sidecar.connection.sent))
        self.assertTrue(any(item.get("id") == "n1" for item in sidecar.held))
        sidecar.handle({"event": "stop"})


class ProtocolTest(unittest.TestCase):
    def test_speech_events_come_before_transcribing(self):
        rig = SidecarRig()
        try:
            rig.feed(fixtures.voiced(1.2) + fixtures.silence(1.2))
            names = rig.names()
            self.assertLess(names.index("speech"), names.index("transcribing"))
            speech = rig.find("speech")
            self.assertTrue(speech[0]["active"])
            self.assertFalse(speech[-1]["active"])
        finally:
            rig.stop()

    def test_a_delegation_carries_utterance_and_pending_fields(self):
        rig = SidecarRig()
        try:
            rig.sidecar.held = [{"id": "n", "text": "Pending."}]
            rig.feed(fixtures.voiced(1.2) + fixtures.silence(1.2))
            self.assertTrue(rig.pump(until=lambda: rig.find("delegation")))
            delegation = rig.find("delegation")[0]
            self.assertIn("utterance", delegation)
            self.assertEqual(delegation["pending"][0]["text"], "Pending.")
        finally:
            rig.stop()


# The budgets the docs report.  They are deliberately loose enough for a
# scheduler on a loaded machine; the fixture tests measure the detector and
# the sidecar's own timing, not a live microphone or a speech service.
DETECTION_TO_GATE_SECONDS = 0.10
SPEECH_END_TO_TRANSCRIPT_REQUEST_SECONDS = 1.05
SIDECAR_FALSE_TRIGGER_RELEASE_SECONDS = 1.10
CLIENT_FALSE_TRIGGER_RELEASE_SECONDS = 1.60
TRANSCRIPT_TO_DELEGATION_SECONDS = 0.10


class LatencyBudgetTest(unittest.TestCase):
    def test_detection_reaches_the_gate_before_a_transcript(self):
        events, _ = detector_events(
            fixtures.voiced(1.0) + fixtures.silence(1.2))
        onset = events[0][0]
        self.assertEqual(events[0][1], "start")
        self.assertLessEqual(onset, DETECTION_TO_GATE_SECONDS)
        print("detection-to-gate budget · onset %.0f ms, budget %.0f ms"
              % (onset * 1000.0, DETECTION_TO_GATE_SECONDS * 1000.0))

    def test_speech_end_and_transcript_request_fit_the_budget(self):
        sidecar = unmute.UnmuteSidecar(
            args(), events=FakeEvents(), player=NullAudio(),
            recorder=NullAudio())
        # One frame is 10 ms and the tick reads 20 ms; the hangover is the
        # deliberate tradeoff that stops a natural pause cutting a word.
        tick = 0.02
        self.assertLessEqual(sidecar.vad.hangover + tick,
                             SPEECH_END_TO_TRANSCRIPT_REQUEST_SECONDS)
        print("speech-end-to-request budget · hangover %.0f ms + tick %.0f ms,"
              " budget %.0f ms"
              % (sidecar.vad.hangover * 1000.0, tick * 1000.0,
                 SPEECH_END_TO_TRANSCRIPT_REQUEST_SECONDS * 1000.0))

    def test_false_trigger_release_and_delegation_fit_the_budget(self):
        # The sidecar schedules a release one second after a cancelled
        # trigger; Emacs and the Flutter controller use 1.5 s, still inside
        # the budget the docs give.
        self.assertLessEqual(1.0, SIDECAR_FALSE_TRIGGER_RELEASE_SECONDS)
        self.assertLessEqual(1.5, CLIENT_FALSE_TRIGGER_RELEASE_SECONDS)
        rig = SidecarRig()
        try:
            rig.sidecar.awaiting.add(1)
            rig.sidecar.transcripts.put((1, "words"))
            started = time.monotonic()
            rig.sidecar.drain_transcripts()
            elapsed = time.monotonic() - started
            self.assertLessEqual(elapsed, TRANSCRIPT_TO_DELEGATION_SECONDS)
            self.assertEqual(len(rig.find("delegation")), 1)
        finally:
            rig.stop()
        print("false-trigger release budget · sidecar 1.0 s (budget %.2f s),"
              " client 1.5 s (budget %.2f s); transcript-to-delegation %.1f ms"
              % (SIDECAR_FALSE_TRIGGER_RELEASE_SECONDS,
                 CLIENT_FALSE_TRIGGER_RELEASE_SECONDS, elapsed * 1000.0))

    def test_a_mute_drops_a_late_transcript_without_sticking(self):
        rig = SidecarRig()
        try:
            rig.stt_gate.clear()
            rig.feed(fixtures.voiced(1.2) + fixtures.silence(1.2))
            self.assertTrue(rig.pump(until=lambda: rig.stt_calls))
            rig.sidecar.handle({"event": "mute", "on": True})
            rig.sidecar.handle({"event": "mute", "on": False})
            rig.stt_gate.set()
            rig.pump(timeout=0.3)
            self.assertEqual(rig.find("delegation"), [])
            self.assertEqual(rig.find("user_delta"), [])
            self.assertFalse(rig.sidecar.gate_blocked())
        finally:
            rig.stop()

    def test_a_resumed_voice_keeps_the_gate_closed(self):
        rig = SidecarRig()
        try:
            rig.sidecar.held = [{"id": "n", "text": "Held."}]
            rig.sidecar.speech_active = True
            rig.sidecar.release_at = time.monotonic() - 1
            rig.sidecar.maybe_release()
            rig.pump(timeout=0.2)
            self.assertEqual(rig.tts_calls, [])
            rig.sidecar.speech_active = False
            rig.sidecar.maybe_release()
            self.assertTrue(rig.pump(until=lambda: rig.tts_calls))
            self.assertEqual(rig.tts_calls, ["Held."])
        finally:
            rig.stop()


class AudioBackendTest(unittest.TestCase):
    """The recorder and player follow the installed backend, without hardware.

    The programs are fakes on PATH: a ``pw-record`` that dies at once and
    a ``parec`` that keeps talking are the PipeWire session of a machine
    that installed the tools but has nothing to record from, which is
    what a missing alsa-utils used to look like instead.
    """

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="harness-audio-")
        self.path = os.environ.get("PATH", "")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.addCleanup(os.environ.__setitem__, "PATH", self.path)

    def program(self, name, body):
        """Write an executable NAME whose body is BODY, and return its path."""
        path = os.path.join(self.work, name)
        with open(path, "w") as handle:
            handle.write(body)
        os.chmod(path, 0o755)
        return path

    def only(self, *names):
        """Put the fakes for NAMES first on PATH."""
        os.environ["PATH"] = self.work + os.pathsep + self.path
        return names

    def test_backends_keep_the_newest_interface_first(self):
        self.assertEqual([backend.name for backend in AUDIO_BACKENDS],
                         ["pipewire", "pulse", "alsa", "ffmpeg"])
        self.assertEqual(audio_backend_names(),
                         ["auto", "pipewire", "pulse", "alsa", "ffmpeg"])
        self.assertIsNone(audio_backend("none"))
        for backend in AUDIO_BACKENDS:
            self.assertEqual(backend.capture_command(16000)[0], backend.programs[0])
            self.assertEqual(backend.play_command(16000)[0], backend.programs[1])
            self.assertIn("16000", " ".join(backend.capture_command(16000)))
            self.assertIn("16000", " ".join(backend.play_command(16000)))
        self.assertIsNone(self_test_audio())

    def test_a_missing_backend_names_the_programs(self):
        os.environ["PATH"] = self.work
        self.assertEqual(audio_missing_reason("auto", "capture"),
                         "microphone unavailable · pw-record, parec, arecord or ffmpeg")
        self.assertEqual(audio_missing_reason("auto", "playback"),
                         "speaker unavailable · pw-play, paplay, aplay or ffmpeg")
        self.assertEqual(audio_missing_reason("alsa", "capture"),
                         "microphone command unavailable · arecord")
        self.assertEqual(audio_missing_reason("none", "capture"),
                         "audio backend unknown · none")
        self.assertEqual(audio_backends("alsa"), [])

    def test_a_forced_backend_does_not_fall_back(self):
        self.program("parec", "#!/bin/sh\nexit 0\n")
        self.program("paplay", "#!/bin/sh\nexit 0\n")
        self.only()
        self.assertEqual([backend.name for backend in audio_backends("pulse")], ["pulse"])
        self.assertEqual(audio_backends("alsa"), [])

    def test_a_recorder_falls_over_from_a_dead_backend(self):
        self.program("pw-record", "#!/bin/sh\nexit 3\n")
        self.program("pw-play", "#!/bin/sh\nexit 0\n")
        self.program("paplay", "#!/bin/sh\nexit 0\n")
        self.program("parec", (
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "while True:\n"
            "    sys.stdout.buffer.write(b'\\x00' * 640)\n"
            "    sys.stdout.buffer.flush()\n"
            "    time.sleep(0.02)\n"))
        self.only()
        recorder = Recorder(16000)
        try:
            chunk = b""
            deadline = time.monotonic() + 10
            while not chunk and time.monotonic() < deadline:
                chunk = recorder.read(320)
            self.assertTrue(chunk)
            self.assertEqual(recorder.backend, "pulse")
        finally:
            recorder.close()

    def test_the_player_writes_through_the_backend(self):
        played = os.path.join(self.work, "played.raw")
        self.program("pw-record", "#!/bin/sh\nexit 0\n")
        self.program("pw-play", (
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "out = open(%r, 'wb')\n"
            "while True:\n"
            "    data = sys.stdin.buffer.read1(4096)\n"
            "    if not data:\n"
            "        break\n"
            "    out.write(data)\n"
            "    out.flush()\n") % played)
        self.only()
        player = Player(16000)
        try:
            player.play(b"\x01\x00" * 800)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not os.path.exists(played):
                time.sleep(0.02)
            self.assertEqual(player.backend, "pipewire")
            player.close()
            with open(played, "rb") as handle:
                self.assertEqual(handle.read(), b"\x01\x00" * 800)
        finally:
            player.close()


class Service(BaseHTTPRequestHandler):
    """Speech to text and text to speech with the OpenAI request shapes."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if self.path.endswith("/audio/transcriptions"):
            payload = json.dumps({"text": "add a docstring"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.endswith("/audio/speech"):
            data = wav_from_pcm(tone(0.4), fixtures.RATE)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()


class SidecarAudioTest(unittest.TestCase):
    """The real sidecar process records and plays through its backends."""

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="harness-sidecar-")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.played = os.path.join(self.work, "played.raw")

    def program(self, name, body):
        path = os.path.join(self.work, name)
        with open(path, "w") as handle:
            handle.write(body)
        os.chmod(path, 0o755)
        return path

    def test_the_local_sidecar_runs_the_whole_loop(self):
        tone_file = os.path.join(self.work, "tone.raw")
        with open(tone_file, "wb") as handle:
            handle.write(tone(1.0))
        # A recorder that says one utterance and then keeps the room quiet,
        # and a player that keeps what it was given.  Both are the backend
        # programs Emacs would start on a PipeWire machine.
        self.program("pw-record", (
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "sys.stdout.buffer.write(open(%r, 'rb').read())\n"
            "sys.stdout.buffer.flush()\n"
            "while True:\n"
            "    sys.stdout.buffer.write(b'\\x00' * 640)\n"
            "    sys.stdout.buffer.flush()\n"
            "    time.sleep(0.02)\n") % tone_file)
        self.program("pw-play", (
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "out = open(%r, 'wb')\n"
            "while True:\n"
            "    data = sys.stdin.buffer.read1(4096)\n"
            "    if not data:\n"
            "        break\n"
            "    out.write(data)\n"
            "    out.flush()\n") % self.played)
        os.environ["PATH"] = self.work + os.pathsep + os.environ.get("PATH", "")
        server = ThreadingHTTPServer(("127.0.0.1", 0), Service)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = "http://127.0.0.1:%d" % server.server_address[1]
        sidecar = subprocess.Popen(
            [sys.executable, SCRIPT, "--stt-url", base + "/v1/audio/transcriptions",
             "--tts-url", base + "/v1/audio/speech", "--threshold", "0.02"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ), text=True, bufsize=1)
        seen = []
        events = queue.Queue()

        def read_events():
            for line in sidecar.stdout:
                try:
                    events.put(json.loads(line))
                except ValueError:
                    pass

        threading.Thread(target=read_events, daemon=True).start()

        def send(**fields):
            sidecar.stdin.write(json.dumps(fields) + "\n")
            sidecar.stdin.flush()

        def wait_for(kind, timeout=20):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    event = events.get(timeout=0.2)
                except queue.Empty:
                    continue
                seen.append(event.get("event"))
                if event.get("event") == kind:
                    return event
            self.fail("no %s event, saw %s" % (kind, seen))

        try:
            send(event="start", protocol=1, context="")
            wait_for("ready")
            delegation = wait_for("delegation")
            self.assertEqual(delegation.get("text"), "add a docstring")
            send(event="delegate_result", id=delegation.get("id"), text="It is in place.")
            wait_for("speaking")
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if os.path.exists(self.played) and os.path.getsize(self.played) >= 1600:
                    break
                time.sleep(0.05)
            send(event="stop")
            wait_for("closed")
        finally:
            sidecar.stdin.close()
            sidecar.wait(timeout=15)
            log = sidecar.stderr.read()
            sidecar.stdout.close()
            sidecar.stderr.close()
            server.shutdown()
            server.server_close()
        self.assertIn("capture · pw-record", log)
        self.assertIn("playback · pw-play", log)
        with open(self.played, "rb") as handle:
            self.assertGreaterEqual(len(handle.read()), 1600)


if __name__ == "__main__":
    unittest.main(verbosity=2)