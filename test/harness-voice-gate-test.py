#!/usr/bin/env python3
"""Deterministic tests for the low-latency voice gate.

The fixtures are synthetic (see test/voice_fixtures.py): they exercise the
detector and the sidecar's held-output logic without a microphone, a
speech model or a network.  A live microphone and speaker check is a
separate manual step; these tests do not claim it.
"""

from __future__ import annotations

import argparse
import array
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import queue
import shutil
import signal
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


def process_alive(pid):
    """Return whether PID still runs; a zombie waits only to be reaped."""
    try:
        with open("/proc/%d/stat" % pid) as handle:
            state = handle.read().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return False
    return state not in ("Z", "X")

import voice_fixtures as fixtures  # noqa: E402
from harness_voice_sidecar import (  # noqa: E402
    AUDIO_BACKENDS, LOCAL_RATE, FakeEvents, NullAudio, Player, Recorder,
    SpeechDetector, Vad, audio_backend, audio_backend_names, audio_backends,
    audio_missing_reason, pcm_energy, pcm_from_wav, self_test_audio, wav_from_pcm,
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


def detector_stream(parts):
    """Feed (PCM, playback level) pairs, returning events and the detector."""
    detector = SpeechDetector()
    events = []
    for data, level in parts:
        detector.set_playback(level)
        for offset in range(0, len(data), 320):
            for event in detector.feed(data[offset:offset + 320]):
                events.append(event[0])
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


class ChunkRecorder(NullAudio):
    """A recorder returning the chunks a test hands it, then silence."""

    def __init__(self, chunks):
        super().__init__()
        self.chunks = list(chunks)

    def read(self, frames, timeout=0.2):
        return self.chunks.pop(0) if self.chunks else b""

    def exhausted(self):
        return False


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
        self.transcript_queue = []
        self.sidecar = unmute.UnmuteSidecar(
            args(), events=self.events, player=self.player,
            recorder=NullAudio(),
            post_multipart=self._stt, post_json=self._tts)
        self.sidecar.start_session({"event": "start", "protocol": 1})

    def _stt(self, url, fields, filename, data, headers=None, timeout=120):
        self.stt_calls.append({"bytes": len(data)})
        self.stt_gate.wait(timeout=5)
        if self.transcript_queue:
            return json.dumps({"text": self.transcript_queue.pop(0)}).encode("utf-8")
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


class TelemetryTest(unittest.TestCase):
    """The sidecar's level and segment events come from real decisions."""

    def test_level_is_the_capture_chunk_before_the_filter(self):
        rig = SidecarRig()
        try:
            pcm = fixtures.voiced(0.02)
            rig.sidecar.recorder = ChunkRecorder([pcm])
            rig.sidecar.tick()
            levels = rig.find("level")
            self.assertEqual(len(levels), 1, "no level reported for the chunk")
            measured = pcm_energy(pcm)
            self.assertAlmostEqual(levels[0]["input"], round(measured, 3),
                                   places=3)
            # The level is the microphone's, not the filter's: the same
            # chunk is noise for the gate and still has a level.
            self.assertNotIn("segment", rig.names())
        finally:
            rig.stop()

    def test_levels_are_bounded_and_stop_while_muted(self):
        rig = SidecarRig()
        try:
            rig.sidecar.recorder = ChunkRecorder([fixtures.voiced(0.02)] * 3)
            rig.sidecar.tick()
            rig.sidecar.tick()
            self.assertEqual(len(rig.find("level")), 1,
                             "levels are not rate limited")
            rig.sidecar.handle({"event": "mute", "on": True})
            rig.sidecar.tick()
            self.assertEqual(len(rig.find("level")), 1,
                             "a muted microphone still reported a level")
        finally:
            rig.stop()

    def test_a_kept_burst_is_accepted_with_its_measured_length(self):
        rig = SidecarRig()
        try:
            audio = fixtures.voiced(0.6) + fixtures.silence(1.0)
            rig.feed(audio)
            segments = rig.find("segment")
            self.assertEqual([item["state"] for item in segments], ["accepted"])
            self.assertEqual(segments[0]["id"], "u-1")
            # The burst is what the gate recorded: the speech and the
            # hangover it keeps before it lets go, not a made-up figure.
            self.assertGreater(segments[0]["seconds"], 0.6)
            self.assertLess(segments[0]["seconds"], 1.6)
        finally:
            rig.stop()

    def test_a_short_blip_is_kept_and_measured_as_recorded(self):
        # The gate's hangover is part of the recording, so a blip in a
        # quiet room is a kept burst of about a second, not a "too short"
        # drop.  The strip must show what the path did, not a guess.
        rig = SidecarRig()
        try:
            rig.feed(fixtures.voiced(0.08) + fixtures.silence(1.0))
            segments = rig.find("segment")
            self.assertEqual([item["state"] for item in segments], ["accepted"])
            self.assertGreater(segments[0]["seconds"], 0.8)
        finally:
            rig.stop()

    def test_an_empty_transcript_is_dropped_as_no_words(self):
        rig = SidecarRig()
        try:
            rig.transcript = ""
            rig.feed(fixtures.voiced(0.6) + fixtures.silence(1.0))
            self.assertTrue(rig.pump(until=lambda: rig.find("delegation") or
                                     len(rig.find("segment")) > 1))
            states = [(item["state"], item.get("reason"))
                      for item in rig.find("segment")]
            self.assertEqual(states, [("accepted", None), ("dropped", "no words")])
        finally:
            rig.stop()

    def test_a_failed_transcription_is_failed_not_dropped(self):
        rig = SidecarRig()

        def broken(*_args, **_kwargs):
            raise RuntimeError("speech service down")

        try:
            rig.sidecar.post_multipart = broken
            rig.feed(fixtures.voiced(0.6) + fixtures.silence(1.0))
            self.assertTrue(rig.pump(
                until=lambda: rig.find("segment") and
                rig.find("segment")[-1]["state"] == "failed",
                timeout=6.0))
            states = [item["state"] for item in rig.find("segment")]
            self.assertEqual(states, ["accepted", "failed"])
            # One burst that could not be transcribed is a notice, not the
            # end of the call: the next thing said is still heard.
            self.assertTrue(rig.find("notice"))
            self.assertFalse(rig.find("error"))
        finally:
            rig.stop()

    def test_a_failed_transcription_leaves_the_microphone_listening(self):
        rig = SidecarRig()

        def broken(*_args, **_kwargs):
            raise RuntimeError("speech service down")

        try:
            rig.sidecar.post_multipart = broken
            rig.feed(fixtures.voiced(0.6) + fixtures.silence(1.0))
            self.assertTrue(rig.pump(until=lambda: rig.find("notice"),
                                     timeout=6.0))
            rig.sidecar.post_multipart = rig._stt
            self.assertTrue(rig.sidecar.started)
            rig.feed(fixtures.voiced(0.6) + fixtures.silence(1.0))
            self.assertTrue(rig.pump(until=lambda: rig.find("delegation"),
                                     timeout=6.0),
                            "the call stopped listening after one failure")
        finally:
            rig.stop()


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

    def test_a_quieter_utterance_after_digital_silence_is_still_detected(self):
        loud = fixtures.voiced(2.0, amplitude=0.30)
        quiet = fixtures.voiced(2.0, amplitude=0.08)
        events, detector = detector_events(
            fixtures.concat(loud, fixtures.silence(2.0), quiet))
        self.assertEqual([kind for _, kind in events], ["start", "end", "start"])
        self.assertGreater(events[2][0], 4.0,
                           "the second onset came from the first utterance")
        # The loud utterance and the silence leave the configured threshold,
        # not a raised one the quieter utterance cannot cross.
        self.assertEqual(detector._threshold(), detector.threshold)
        self.assertLess(detector._noise, 0.001)
        fresh, _ = detector_events(quiet)
        self.assertEqual([kind for _, kind in fresh], ["start"],
                         "a fresh detector accepts the fixture; the estimator did not")

    def test_a_missed_quiet_utterance_does_not_raise_the_floor_for_the_next(self):
        # 0.010 is below the threshold floor even at its loudest frame, so
        # this attempt is missed; 0.07 is accepted by a clean detector but
        # not above a floor the missed attempt would have taught.
        missed = fixtures.voiced(2.0, amplitude=0.010)
        next_one = fixtures.voiced(1.5, amplitude=0.07)
        events, detector = detector_events(
            fixtures.concat(missed, fixtures.silence(1.0), next_one))
        self.assertEqual([kind for _, kind in events], ["start"])
        self.assertEqual(detector._threshold(), detector.threshold)
        self.assertLess(detector._noise, 0.001)

    def test_repeated_utterances_recover_after_each_one(self):
        parts = []
        for amplitude in (0.30, 0.08, 0.25, 0.06, 0.30):
            parts.append(fixtures.voiced(1.0, amplitude=amplitude))
            parts.append(fixtures.silence(1.2))
        events, detector = detector_events(fixtures.concat(*parts))
        self.assertEqual([kind for _, kind in events], ["start", "end"] * 5)
        self.assertEqual(detector._threshold(), detector.threshold)

    def test_low_level_room_noise_does_not_hide_a_quiet_utterance(self):
        # A quiet room and a microphone whose gain leaves speech around a
        # third of a normal mouth's level: the frames of the words sit near
        # 0.006 and the room near 0.0015, which is a Scarlett Solo with its
        # gain low.  The gate is a floor under the room, not a level speech
        # has to reach.
        room = 0.003
        speech = fixtures.mix(
            fixtures.voiced(1.5, amplitude=0.02),
            fixtures.white_noise(1.5, amplitude=room, seed=11))
        events, detector = detector_events(
            fixtures.concat(fixtures.white_noise(1.0, amplitude=room),
                            speech,
                            fixtures.white_noise(1.0, amplitude=room, seed=13)))
        self.assertEqual([kind for _, kind in events], ["start", "end"])
        self.assertEqual(detector._threshold(), detector.threshold,
                         "a quiet room raised the threshold a quiet voice needs")
        events, _ = detector_events(
            fixtures.white_noise(4.0, amplitude=room))
        self.assertEqual(events, [], "room noise created an utterance")

    def test_chunk_boundaries_do_not_change_the_decisions(self):
        data = fixtures.concat(fixtures.voiced(0.6, amplitude=0.30),
                               fixtures.silence(1.0),
                               fixtures.voiced(0.6, amplitude=0.08),
                               fixtures.silence(1.0))
        expected = None
        for chunk in (1, 3, 160, 320, 999, 4096, len(data)):
            events, _ = detector_events(data, chunk=chunk)
            kinds = [kind for _, kind in events]
            if expected is None:
                expected = kinds
            self.assertEqual(kinds, expected, "chunk size %d" % chunk)
        self.assertEqual(expected, ["start", "end", "start", "end"])

    def test_digital_silence_decays_a_raised_noise_floor(self):
        detector = SpeechDetector()
        detector.feed(fixtures.white_noise(1.0, amplitude=0.02))
        self.assertGreater(detector._threshold(), detector.threshold,
                           "the fixture did not raise the floor")
        detector.feed(fixtures.silence(1.0))
        self.assertLess(detector._noise, 0.001)
        self.assertEqual(detector._threshold(), detector.threshold)

    def test_a_hum_and_a_click_do_not_leave_a_raised_floor(self):
        cases = (
            ("hum", fixtures.hum(2.0)),
            ("click", fixtures.concat(fixtures.silence(0.5),
                                      fixtures.click(),
                                      fixtures.silence(0.5))),
        )
        for name, data in cases:
            detector = SpeechDetector()
            events = []
            for offset in range(0, len(data), 320):
                events.extend(detector.feed(data[offset:offset + 320]))
            self.assertEqual(events, [], name)
            detector.feed(fixtures.silence(1.0))
            self.assertEqual(detector._threshold(), detector.threshold, name)

    def test_playback_echo_does_not_raise_the_floor_or_hide_the_next_voice(self):
        playback = fixtures.voiced(1.0)
        level = SpeechDetector.energy(playback)
        events, detector = detector_stream([
            (fixtures.echo(playback, gain=0.32), level),
            (fixtures.silence(0.5), 0.0),
            (fixtures.voiced(1.5, amplitude=0.08), 0.0),
            (fixtures.silence(1.0), 0.0),
        ])
        self.assertEqual(events, ["start", "end"],
                         "the echo crossed the gate or hid the next voice")
        self.assertEqual(detector._noise, 0.0,
                         "the assistant's echo was learned as room noise")
        self.assertEqual(detector._threshold(), detector.threshold)

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

    def test_two_utterances_at_different_levels_both_reach_transcription(self):
        rig = SidecarRig()
        try:
            rig.transcript_queue = ["first words", "second words"]
            rig.feed(fixtures.concat(fixtures.voiced(1.2, amplitude=0.30),
                                     fixtures.silence(1.2),
                                     fixtures.voiced(1.2, amplitude=0.08),
                                     fixtures.silence(1.2)))
            self.assertTrue(
                rig.pump(until=lambda: len(rig.find("delegation")) == 2),
                "the quieter second utterance never reached transcription")
            self.assertEqual(len(rig.stt_calls), 2)
            self.assertEqual([item["text"] for item in rig.find("delegation")],
                             ["first words", "second words"])
            self.assertEqual(len(rig.find("transcribing")), 2)
            self.assertEqual(len(rig.find("user_delta")), 2)
            self.assertFalse(rig.sidecar.gate_blocked())
        finally:
            rig.stop()

    def test_noise_hum_and_echo_create_no_utterance_or_self_interruption(self):
        rig = SidecarRig()
        try:
            playback = fixtures.voiced(1.0)
            level = SpeechDetector.energy(playback)
            rig.player.busy_value = True
            rig.player.level_value = level
            rig.sidecar.vad.set_playback(level)
            rig.feed(fixtures.echo(playback, gain=0.32))
            self.assertEqual(rig.find("speech"), [],
                             "the assistant's echo interrupted it")
            self.assertFalse(rig.sidecar.speech_active)
            rig.player.busy_value = False
            rig.player.level_value = 0.0
            rig.sidecar.vad.set_playback(0.0)
            rig.feed(fixtures.concat(
                fixtures.white_noise(1.0),
                fixtures.hum(1.0),
                fixtures.silence(0.3),
                fixtures.click(),
                fixtures.silence(0.3)))
            rig.pump(timeout=0.2)
            self.assertEqual(rig.find("speech"), [])
            self.assertEqual(rig.find("transcribing"), [])
            self.assertEqual(rig.find("delegation"), [])
            self.assertFalse(rig.sidecar.speech_active)
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
        pcm = b"\x01\x00" * 800
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
            player.play(pcm)
            # The writer thread hands the audio over, so wait for it to
            # arrive rather than assuming play() wrote it synchronously.
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if (os.path.exists(played)
                        and os.path.getsize(played) >= len(pcm)):
                    break
                time.sleep(0.02)
            self.assertEqual(player.backend, "pipewire")
            player.close()
            with open(played, "rb") as handle:
                self.assertEqual(handle.read(), pcm)
        finally:
            player.close()


class PlayerPacingTest(unittest.TestCase):
    """Playback runs on a writer thread; the capture loop never waits for it.

    The player's pipe holds about two seconds of audio.  Writing a whole
    reply from the sidecar's tick therefore blocked that tick -- and the
    microphone with it -- for the rest of the reply.  ``play`` now hands
    the audio to the writer and returns.
    """

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="harness-player-")
        self.path = os.environ.get("PATH", "")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.addCleanup(os.environ.__setitem__, "PATH", self.path)

    def program(self, name, body):
        path = os.path.join(self.work, name)
        with open(path, "w") as handle:
            handle.write(body)
        os.chmod(path, 0o755)
        return path

    def only(self):
        os.environ["PATH"] = self.work + os.pathsep + self.path

    def test_play_does_not_wait_for_a_slow_player(self):
        played = os.path.join(self.work, "played.raw")
        self.program("pw-record", "#!/bin/sh\nexit 0\n")
        self.program("pw-play", (
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "out = open(%r, 'wb')\n"
            "while True:\n"
            "    data = sys.stdin.buffer.read1(1280)\n"
            "    if not data:\n"
            "        break\n"
            "    out.write(data)\n"
            "    out.flush()\n"
            "    time.sleep(0.04)\n") % played)
        self.only()
        player = Player(16000)
        try:
            pcm = b"\x01\x00" * (16000 * 4)  # four seconds of audio
            start = time.monotonic()
            player.play(pcm)
            elapsed = time.monotonic() - start
            self.assertLess(elapsed, 0.5,
                            "play() waited %.2fs for a slow player" % elapsed)
            self.assertTrue(player.busy())
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not os.path.exists(played):
                time.sleep(0.02)
            self.assertTrue(os.path.exists(played), "the writer wrote nothing")
            player.stop()
            self.assertFalse(player.busy())
        finally:
            player.close()

    def test_a_stopped_player_starts_again_for_the_next_reply(self):
        played = os.path.join(self.work, "played.raw")
        starts = os.path.join(self.work, "starts.log")
        self.program("pw-record", "#!/bin/sh\nexit 0\n")
        self.program("pw-play", (
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "open(%r, 'a').write('start\\n')\n"
            "out = open(%r, 'ab')\n"
            "while True:\n"
            "    data = sys.stdin.buffer.read1(4096)\n"
            "    if not data:\n"
            "        break\n"
            "    out.write(data)\n"
            "    out.flush()\n") % (starts, played))
        self.only()
        player = Player(16000)
        first = b"\x01\x00" * 16000
        second = b"\x02\x00" * 16000

        def wait_for(total):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    if os.path.getsize(played) >= total:
                        return True
                except OSError:
                    pass
                time.sleep(0.02)
            return False

        try:
            player.play(first)
            self.assertTrue(wait_for(len(first)), "the first reply never played")
            player.stop()
            player.play(second)
            self.assertTrue(wait_for(len(first) + len(second)),
                            "playback did not restart after a stop")
            player.close()
            with open(played, "rb") as handle:
                self.assertEqual(handle.read(), first + second)
            with open(starts) as handle:
                self.assertEqual(len(handle.read().split()), 2)
        finally:
            player.close()


class RecorderAlignmentTest(unittest.TestCase):
    """A split sample is carried, not dropped, so later samples stay aligned."""

    def test_a_byte_between_reads_does_not_shift_the_stream(self):
        work = tempfile.mkdtemp(prefix="harness-align-")
        self.addCleanup(shutil.rmtree, work, True)
        script = os.path.join(work, "capture")
        with open(script, "w") as handle:
            handle.write(
                "#!/usr/bin/env python3\n"
                "import sys, time\n"
                "sys.stdout.buffer.write(b'\\x01')\n"
                "sys.stdout.buffer.flush()\n"
                "time.sleep(0.2)\n"
                "sys.stdout.buffer.write(b'\\x02\\x03\\x04')\n"
                "sys.stdout.buffer.flush()\n"
                "time.sleep(0.5)\n")
        os.chmod(script, 0o755)
        recorder = Recorder(16000, command=[sys.executable, script])
        try:
            data = b""
            chunks = []
            deadline = time.monotonic() + 10
            while len(data) < 4 and time.monotonic() < deadline:
                chunk = recorder.read(1, timeout=1.0)
                if chunk:
                    chunks.append(chunk)
                    data += chunk
            # Every read of a PCM16 stream is whole samples: a byte split
            # across reads is carried, not returned on its own.
            self.assertTrue(chunks)
            for chunk in chunks:
                self.assertEqual(len(chunk) % 2, 0, chunks)
            self.assertEqual(data, b"\x01\x02\x03\x04")
        finally:
            recorder.close()


class Service(BaseHTTPRequestHandler):
    """Speech to text and text to speech with the OpenAI request shapes."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if self.path.endswith("/audio/transcriptions"):
            texts = getattr(self.server, "transcripts", None)
            text = texts.pop(0) if texts else "add a docstring"
            payload = json.dumps({"text": text}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.endswith("/audio/speech"):
            data = getattr(self.server, "tts_wav", None)
            if data is None:
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

    def test_two_utterances_at_different_levels_both_transcribe(self):
        speech = fixtures.concat(
            fixtures.voiced(1.2, amplitude=0.30),
            fixtures.silence(1.0),
            fixtures.voiced(1.2, amplitude=0.08),
            fixtures.silence(1.0))
        speech_file = os.path.join(self.work, "speech.raw")
        with open(speech_file, "wb") as handle:
            handle.write(speech)
        self.program("pw-record", (
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "sys.stdout.buffer.write(open(%r, 'rb').read())\n"
            "sys.stdout.buffer.flush()\n"
            "while True:\n"
            "    sys.stdout.buffer.write(b'\\x00' * 640)\n"
            "    sys.stdout.buffer.flush()\n"
            "    time.sleep(0.02)\n") % speech_file)
        self.program("pw-play", "#!/bin/sh\ncat > /dev/null\n")
        original = os.environ.get("PATH", "")
        os.environ["PATH"] = self.work + os.pathsep + original
        server = ThreadingHTTPServer(("127.0.0.1", 0), Service)
        server.transcripts = ["first words", "second words"]
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

        def wait_for(kind, timeout=30):
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
            first = wait_for("delegation")
            second = wait_for("delegation")
            self.assertEqual([first.get("text"), second.get("text")],
                             ["first words", "second words"])
            self.assertEqual(seen.count("transcribing"), 2)
            send(event="stop")
            wait_for("closed")
        finally:
            os.environ["PATH"] = original
            sidecar.stdin.close()
            sidecar.wait(timeout=15)
            log = sidecar.stderr.read()
            sidecar.stdout.close()
            sidecar.stderr.close()
            server.shutdown()
            server.server_close()
        self.assertIn("capture · pw-record", log)

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


class LivePacingTest(unittest.TestCase):
    """A reply must not take the microphone away from the person.

    The sidecar's loop reads the microphone and plays replies on the same
    thread.  A reply longer than the player's pipe used to block that
    loop: the capture pipe filled, the sound server dropped the
    microphone, and the next thing the person said reached the speech
    service cut short.  These tests run a real sidecar process with fake
    capture and playback programs that behave like a sound server, and a
    fake speech service.
    """

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="harness-voice-pacing-")
        self.path = os.environ.get("PATH", "")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.addCleanup(os.environ.__setitem__, "PATH", self.path)

    def program(self, name, body):
        path = os.path.join(self.work, name)
        with open(path, "w") as handle:
            handle.write(body)
        os.chmod(path, 0o755)
        return path

    @staticmethod
    def capture_counts(path):
        """Return (chunks produced, chunks dropped) from a fake recorder log."""
        chunks = dropped = 0
        with open(path) as handle:
            for line in handle:
                fields = line.split()
                if len(fields) == 3 and fields[0].isdigit():
                    chunks, dropped = int(fields[0]), int(fields[1])
        return chunks, dropped

    def capture_program(self, log, trigger, first=(0.5, 1.2), second=1.2):
        """A sound-server capture program that drops what the pipe will not take.

        It speaks one 1.2 s burst at 0.5 s, so the sidecar has an
        utterance and a delegation, then waits for TRIGGER and speaks the
        second burst.  A chunk the pipe will not accept while the app is
        not reading is counted as dropped, the way PipeWire and
        PulseAudio overrun a real-time capture.
        """
        body = (
            "#!/usr/bin/env python3\n"
            "import fcntl, math, os, struct, sys, time\n"
            "rate = 16000\n"
            "def voiced(seconds, amplitude=0.3):\n"
            "    return b''.join(struct.pack('<h', int(32767 * amplitude"
            " * math.sin(2*math.pi*140*i/rate))) for i in range(int(seconds*rate)))\n"
            "def chunk_of(pcm, at, start):\n"
            "    offset = int((at - start) * rate) * 2\n"
            "    return pcm[offset:offset + 640]\n"
            "first_start, first_len = __FIRST__\n"
            "fd = sys.stdout.fileno()\n"
            "flags = fcntl.fcntl(fd, fcntl.F_GETFL)\n"
            "fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)\n"
            "log = open(__LOG__, 'w')\n"
            "log.write('0 0 0.000\\n'); log.flush()\n"
            "start = time.monotonic()\n"
            "count = dropped = 0\n"
            "second_start = None\n"
            "first_pcm = voiced(first_len)\n"
            "second_pcm = None\n"
            "while True:\n"
            "    elapsed = time.monotonic() - start\n"
            "    target = int(elapsed / 0.02)\n"
            "    while count < target:\n"
            "        at = count * 0.02\n"
            "        data = b'\\x00\\x00' * 320\n"
            "        if first_start <= at < first_start + first_len:\n"
            "            data = chunk_of(first_pcm, at, first_start)\n"
            "        if second_start is None and os.path.exists(__TRIGGER__):\n"
            "            second_start = at\n"
            "            second_pcm = voiced(__SECOND__)\n"
            "        if (second_start is not None\n"
            "                and second_start <= at < second_start + __SECOND__):\n"
            "            data = chunk_of(second_pcm, at, second_start)\n"
            "        try:\n"
            "            os.write(fd, data)\n"
            "        except BlockingIOError:\n"
            "            dropped += 1\n"
            "        count += 1\n"
            "        if count % 10 == 0:\n"
            "            log.write('%d %d %.3f\\n' % (count, dropped, elapsed))\n"
            "            log.flush()\n"
            "    time.sleep(0.004)\n"
        )
        return (body.replace("__FIRST__", repr(first))
                    .replace("__TRIGGER__", repr(trigger))
                    .replace("__SECOND__", repr(second))
                    .replace("__LOG__", repr(log)))

    def prefill_capture_program(self, seconds, log):
        """A capture program that starts with a full pipe, then runs in real time.

        The burst is written with blocking writes, so it fills the pipe;
        the real-time silence that follows is dropped when the pipe will
        not take it.  A real session ends up here once a stall has
        filled the pipe; a correct reader drains the burst instead of
        keeping the pipe full.
        """
        body = (
            "#!/usr/bin/env python3\n"
            "import fcntl, math, os, struct, sys, time\n"
            "rate = 16000\n"
            "def voiced(seconds, amplitude=0.3):\n"
            "    return b''.join(struct.pack('<h', int(32767 * amplitude"
            " * math.sin(2*math.pi*140*i/rate))) for i in range(int(seconds*rate)))\n"
            "fd = sys.stdout.fileno()\n"
            "log = open(__LOG__, 'w')\n"
            "view = memoryview(voiced(__SECONDS__))\n"
            "while view:\n"
            "    view = view[os.write(fd, view):]\n"
            "log.write('0 0 0.000\\n'); log.flush()\n"
            "flags = fcntl.fcntl(fd, fcntl.F_GETFL)\n"
            "fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)\n"
            "chunk = b'\\x00\\x00' * 320\n"
            "start = time.monotonic()\n"
            "count = dropped = 0\n"
            "while True:\n"
            "    elapsed = time.monotonic() - start\n"
            "    target = int(elapsed / 0.02)\n"
            "    while count < target:\n"
            "        try:\n"
            "            os.write(fd, chunk)\n"
            "        except BlockingIOError:\n"
            "            dropped += 1\n"
            "        count += 1\n"
            "    if count % 10 == 0:\n"
            "        log.write('%d %d %.3f\\n' % (count, dropped, elapsed))\n"
            "        log.flush()\n"
            "    time.sleep(0.004)\n"
        )
        return (body.replace("__SECONDS__", repr(seconds))
                    .replace("__LOG__", repr(log)))

    def player_program(self, log):
        """A speaker that consumes PCM at real time, logging that it started."""
        return (
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "open(__LOG__, 'a').write('start\\n')\n"
            "while True:\n"
            "    data = sys.stdin.buffer.read1(1280)\n"
            "    if not data:\n"
            "        break\n"
            "    time.sleep(0.04)\n"
        ).replace("__LOG__", repr(log))

    def start(self, transcripts, tts_wav):
        """Start a fake speech service and the real sidecar against it."""
        server = ThreadingHTTPServer(("127.0.0.1", 0), Service)
        server.transcripts = list(transcripts)
        server.tts_wav = tts_wav
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = "http://127.0.0.1:%d" % server.server_address[1]
        sidecar = subprocess.Popen(
            [sys.executable, SCRIPT, "--stt-url", base + "/v1/audio/transcriptions",
             "--tts-url", base + "/v1/audio/speech", "--threshold", "0.02"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ), text=True, bufsize=1)
        self.sidecar = sidecar
        events = queue.Queue()
        seen = []

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

        def wait_for(kind, timeout=30):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    event = events.get(timeout=0.2)
                except queue.Empty:
                    continue
                seen.append(event)
                if event.get("event") == kind:
                    return event
            self.fail("no %s event, saw %s"
                      % (kind, [event.get("event") for event in seen]))

        def finish():
            try:
                send(event="stop")
                wait_for("closed", 5)
            except (OSError, ValueError, self.failureException):
                pass
            try:
                sidecar.stdin.close()
            except (OSError, ValueError):
                pass
            try:
                sidecar.wait(timeout=15)
            except subprocess.TimeoutExpired:
                sidecar.kill()
                sidecar.wait()
            sidecar.stdout.close()
            sidecar.stderr.close()

        return send, wait_for, seen, finish

    def test_a_reply_does_not_stop_the_microphone(self):
        capture_log = os.path.join(self.work, "capture.log")
        player_log = os.path.join(self.work, "player.log")
        trigger = os.path.join(self.work, "trigger")
        self.program("pw-record", self.capture_program(capture_log, trigger))
        self.program("pw-play", self.player_program(player_log))
        os.environ["PATH"] = self.work + os.pathsep + self.path
        send, wait_for, seen, finish = self.start(
            ["first words", "second words"],
            wav_from_pcm(fixtures.silence(5), fixtures.RATE))
        try:
            send(event="start", protocol=1, context="")
            wait_for("ready")
            first = wait_for("delegation", 15)
            self.assertEqual(first.get("text"), "first words")
            send(event="delegate_result", id=first.get("id"), text="A long answer.")
            wait_for("assistant_delta", 10)
            # Wait until the reply is actually being played, then let the
            # person speak over it.  A blocking player writes the reply
            # from the sidecar's tick, so everything said now is dropped.
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not os.path.exists(player_log):
                time.sleep(0.02)
            self.assertTrue(os.path.exists(player_log),
                            "the reply never started playing")
            with open(trigger, "w") as handle:
                handle.write("speak\n")
            # A stalled loop overruns the capture pipe within a few
            # hundred milliseconds; give it longer than that to show.
            time.sleep(3.0)
            chunks, dropped = self.capture_counts(capture_log)
            self.assertGreater(chunks, 0)
            self.assertEqual(
                dropped, 0,
                "%d of %d capture chunks dropped while the reply played"
                % (dropped, chunks))
            second = wait_for("delegation", 20)
            self.assertEqual(second.get("text"), "second words")
            segments = [event for event in seen
                        if event.get("event") == "segment"
                        and event.get("state") == "accepted"]
            self.assertGreaterEqual(len(segments), 2, segments)
            # A 1.2 s burst with pre-roll and hangover is about 2.3 s; a
            # burst the blocked loop cut in half is about 1.5 s.
            self.assertGreaterEqual(segments[-1].get("seconds", 0), 2.0,
                                    segments)
        finally:
            finish()

    def test_capture_keeps_up_when_the_pipe_is_full(self):
        capture_log = os.path.join(self.work, "capture.log")
        self.program("pw-record", self.prefill_capture_program(2.0, capture_log))
        self.program("pw-play", "#!/bin/sh\ncat > /dev/null\n")
        os.environ["PATH"] = self.work + os.pathsep + self.path
        send, wait_for, seen, finish = self.start(
            ["after the ring"], wav_from_pcm(fixtures.silence(0.2), fixtures.RATE))
        try:
            send(event="start", protocol=1, context="")
            wait_for("ready")
            delegation = wait_for("delegation", 15)
            self.assertEqual(delegation.get("text"), "after the ring")
            chunks, dropped = self.capture_counts(capture_log)
            self.assertGreater(chunks, 20)
            self.assertEqual(
                dropped, 0,
                "%d of %d capture chunks dropped behind a full pipe"
                % (dropped, chunks))
        finally:
            finish()

    def test_playback_dies_with_the_sidecar(self):
        """Killing the sidecar, as closing Emacs does, stops the speaker.

        Emacs can go away without sending ``stop``: its last window is
        closed, its process is killed.  A player that outlives the
        sidecar has already read the reply out of the pipe, so it plays
        it on to an empty room; the audio process must be tied to the
        sidecar's life instead.
        """
        if not os.path.isdir("/proc"):
            self.skipTest("no /proc to watch the player")
        pidfile = os.path.join(self.work, "player.pid")
        self.program("pw-record", (
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "while True:\n"
            "    sys.stdout.buffer.write(b'\\x00' * 640)\n"
            "    sys.stdout.buffer.flush()\n"
            "    time.sleep(0.02)\n"))
        self.program("pw-play", (
            "#!/usr/bin/env python3\n"
            "import os, sys, time\n"
            "open(__PID__, 'w').write(str(os.getpid()))\n"
            "sys.stdin.buffer.read()\n"
            "time.sleep(30)\n").replace("__PID__", repr(pidfile)))
        os.environ["PATH"] = self.work + os.pathsep + self.path
        send, wait_for, _seen, finish = self.start(
            [], wav_from_pcm(fixtures.silence(0.3), fixtures.RATE))
        pid = None

        def silence():
            if pid:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

        self.addCleanup(silence)
        try:
            send(event="start", protocol=1, context="")
            wait_for("ready")
            send(event="commentary", id="c-1",
                 text="A reply that is already being played.")
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not os.path.exists(pidfile):
                time.sleep(0.02)
            self.assertTrue(os.path.exists(pidfile),
                            "the reply never started playing")
            with open(pidfile) as handle:
                pid = int(handle.read().strip())
            self.assertTrue(process_alive(pid))
            # The sidecar dies the way Emacs kills it: no stop, no finally.
            self.sidecar.kill()
            self.sidecar.wait(timeout=10)
            deadline = time.monotonic() + 5
            while process_alive(pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(process_alive(pid),
                             "the player outlived the sidecar")
        finally:
            finish()


class TtsWavTest(unittest.TestCase):
    """A speech reply is PCM16 mono at the rate the local pipeline plays."""

    def test_resamples_the_service_rate(self):
        source = tone(0.1, rate=24000)
        pcm = pcm_from_wav(wav_from_pcm(source, 24000))
        self.assertEqual(round(len(source) / 2 * LOCAL_RATE / 24000),
                         len(pcm) // 2)
        samples = array.array("h")
        samples.frombytes(pcm)
        self.assertGreater(max(abs(sample) for sample in samples), 1000)

    def test_keeps_the_pipeline_rate(self):
        source = tone(0.1)
        pcm = pcm_from_wav(wav_from_pcm(source, LOCAL_RATE))
        self.assertEqual(source, pcm)

    def test_downmixes_stereo(self):
        frames = array.array("h", [1000, -1000] * 100)
        pcm = pcm_from_wav(wav_from_pcm(frames.tobytes(), LOCAL_RATE, channels=2))
        mono = array.array("h")
        mono.frombytes(pcm)
        self.assertEqual(100, len(mono))
        self.assertTrue(all(abs(sample) <= 1 for sample in mono))

    def test_reads_a_streamed_wav_to_the_end(self):
        # OpenAI-compatible servers stream a WAV whose RIFF and data sizes
        # are 0xffffffff; every frame is in the body.
        data = bytearray(wav_from_pcm(tone(0.1)))
        data[4:8] = b"\xff\xff\xff\xff"
        data[40:44] = b"\xff\xff\xff\xff"
        pcm = pcm_from_wav(bytes(data))
        self.assertEqual(int(0.1 * LOCAL_RATE) * 2, len(pcm))

    def test_rejects_a_width_it_cannot_play(self):
        with self.assertRaises(ValueError):
            pcm_from_wav(wav_from_pcm(b"\x00" * 100, LOCAL_RATE, width=1))

    def test_synthesize_plays_at_the_pipeline_rate(self):
        rig = SidecarRig()
        rig.sidecar.post_json = lambda *args, **kwargs: wav_from_pcm(
            tone(0.1, rate=24000), 24000)
        pcm = rig.sidecar.synthesize("Hello.")
        self.assertEqual(int(rig.sidecar.rate * 0.1) * 2, len(pcm))

    def test_a_speech_server_with_no_audio_is_a_notice_not_the_end(self):
        # Kokoro answers an empty body for text it has no phonemes for.
        # That is one reply lost; the call, the microphone and the next
        # turn go on, and no error event ends the session.
        rig = SidecarRig()
        rig.sidecar.post_json = lambda *args, **kwargs: {"data": b""}
        try:
            self.assertIsNone(rig.sidecar.synthesize("🙂"))
            rig.sidecar.post_json = lambda *args, **kwargs: {}
            self.assertIsNone(rig.sidecar.synthesize("Hello there."))
            notices = rig.find("notice")
            self.assertEqual([item["message"] for item in notices],
                             ["Local speech · no audio"])
            self.assertFalse(rig.find("error"))
            self.assertTrue(rig.sidecar.started)
        finally:
            rig.stop()

    def test_a_speech_service_error_is_one_reply_not_the_session(self):
        rig = SidecarRig()

        def broken(*_args, **_kwargs):
            raise RuntimeError("speech service down")

        try:
            rig.sidecar.post_json = broken
            self.assertIsNone(rig.sidecar.synthesize("Hello there."))
            notices = rig.find("notice")
            self.assertEqual(1, len(notices))
            self.assertTrue(notices[0]["message"].startswith(
                "Local speech failed · "))
            self.assertFalse(rig.find("error"))
            # The next reply is spoken as usual.
            rig.sidecar.post_json = rig._tts
            rig.sidecar.handle({"event": "commentary", "text": "Back again.",
                                "id": "c-2"})
            self.assertTrue(rig.pump(until=lambda: rig.tts_calls))
            self.assertEqual("Back again.", rig.tts_calls[-1])
        finally:
            rig.stop()

    def test_text_a_voice_cannot_say_is_never_synthesized(self):
        rig = SidecarRig()
        try:
            for text in ("🙂", "—", "…", "`", "**"):
                self.assertEqual("", unmute.speakable(text))
                rig.sidecar.handle({"event": "commentary", "text": text,
                                    "id": "n-" + text.encode("unicode_escape").decode()})
            self.assertEqual([], rig.tts_calls)
            self.assertEqual([], rig.sidecar.held)
            # Text with a letter in it is spoken as it is.
            self.assertEqual("1, 2, 3", unmute.speakable("1, 2, 3"))
            self.assertEqual("Hi 🙂", unmute.speakable("Hi 🙂"))
        finally:
            rig.stop()

    def test_a_markup_sentence_is_not_spoken_twice(self):
        # Emacs strips the markup before it sends a piece; the result's
        # own sentences are compared the same way, or the sentence with
        # `code` in it never matched and was spoken a second time.
        rig = SidecarRig()
        try:
            rig.sidecar.handle({"event": "commentary",
                                "text": "The `parse` function is done.",
                                "id": "c1"})
            rig.sidecar.handle({"event": "delegate_result", "id": "u-1",
                                "text": "The `parse` function is done."})
            rig.pump(until=lambda: rig.tts_calls)
            time.sleep(0.1)
            rig.pump(timeout=0.1)
            self.assertEqual(rig.tts_calls, ["The `parse` function is done."])
        finally:
            rig.stop()

    def test_defaults_match_the_bundled_stack(self):
        options = unmute.parse_args(["harness-voice-live-unmute"])
        self.assertEqual("af_heart", options.voice)
        # The gate's floor, not a level speech must reach: a quiet
        # interface's words are still speech (see the detector tests).
        self.assertEqual(0.004, options.threshold)
        self.assertEqual("tts-1", options.tts_model)
        self.assertTrue(options.tts_url.endswith("/v1/audio/speech"))
        self.assertTrue(options.stt_url.endswith("/inference"))


class ProbeOutputTest(unittest.TestCase):
    """A probe run without a trace file prints each measurement once."""

    def test_events_are_printed_once(self):
        loader = importlib.machinery.SourceFileLoader(
            "harness_voice_probe",
            os.path.join(ROOT, "scripts", "harness-voice-probe"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        probe = importlib.util.module_from_spec(spec)
        loader.exec_module(probe)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            probe.emit(probe._Null(), {"stage": "capture", "level": 0.001})
            probe.emit(None, {"stage": "capture", "level": 0.001})
        self.assertEqual(2, len(output.getvalue().splitlines()))


class ProbeReplayTest(unittest.TestCase):
    """The probe's replay reports the capture and filter stages of one WAV."""

    def test_replay_keeps_the_speech_and_reports_each_stage(self):
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work, True)
        wav = os.path.join(work, "speech.wav")
        with open(wav, "wb") as handle:
            # One utterance, then the silence that closes it.
            handle.write(wav_from_pcm(fixtures.voiced(1.2) + fixtures.silence(1.2),
                                      fixtures.RATE))
        trace = os.path.join(work, "trace.jsonl")
        out = os.path.join(work, "out")
        result = subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "harness-voice-probe"),
             "replay", wav, "--out", out, "--trace", trace],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(0, result.returncode, result.stderr)
        with open(trace) as handle:
            events = [json.loads(line) for line in handle if line.strip()]
        stages = [event for event in events if event.get("stage") == "gate"]
        kinds = [event["event"] for event in stages]
        self.assertIn("speech-start", kinds)
        self.assertIn("speech-end", kinds)
        kept = [event for event in stages if event["event"] == "kept"]
        self.assertEqual(1, len(kept), events)
        self.assertGreater(kept[0]["seconds"], 0.5)
        self.assertTrue(os.path.exists(kept[0]["wav"]))
        # The trace's clock is audio time: the kept utterance ends the file.
        self.assertGreater(kept[0]["t"], 1.0)

    def test_replay_keeps_nothing_from_silence(self):
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work, True)
        wav = os.path.join(work, "silence.wav")
        with open(wav, "wb") as handle:
            handle.write(wav_from_pcm(fixtures.silence(1.0), fixtures.RATE))
        trace = os.path.join(work, "trace.jsonl")
        result = subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "harness-voice-probe"),
             "replay", wav, "--trace", trace],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(0, result.returncode, result.stderr)
        with open(trace) as handle:
            events = [json.loads(line) for line in handle if line.strip()]
        self.assertEqual([], [event for event in events
                              if event.get("event") == "kept"])


if __name__ == "__main__":
    unittest.main(verbosity=2)