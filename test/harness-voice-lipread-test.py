#!/usr/bin/env python3
"""Deterministic tests for the webcam lip-reading voice path.

Every test here runs without a camera, a model file or a network: the
frames are scripted, the mouth tracker is scripted, and the recognizer
answers scripted transcripts.  What the suite does hold the code to:

* the motion gate's onset, hangover, minimum and maximum utterance, and
  that a still face never becomes a sentence;
* greedy CTC decoding and the certainty bands, with the measured
  thresholds;
* the mouth crop geometry the model was trained on;
* the model directory's check and a download that is atomic;
* the sidecar's lifecycle: no camera without consent, release on stop,
  on mute, on failure and on a closed pipe, and the exact camera states;
* what an unusable frame, an unsure reading and a low-confidence reading
  do: never a delegation, always a notice.

A real camera and a real face are not tested here, and the suite says so:
that check needs hardware this repository's tests never touch.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import harness_voice_lipread as lipread  # noqa: E402
from harness_voice_sidecar import FakeEvents, NullAudio  # noqa: E402

SCRIPT = os.path.join(ROOT, "scripts", "harness-voice-live-lipread")
LOADER = importlib.machinery.SourceFileLoader("harness_voice_live_lipread", SCRIPT)
SPEC = importlib.util.spec_from_loader("harness_voice_live_lipread", LOADER)
sidecar_module = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(sidecar_module)


class MotionTest(unittest.TestCase):
    """Where an utterance starts and ends, from mouth movement alone."""

    def feed(self, gate, motions):
        events = []
        for motion in motions:
            events += gate.feed(motion)
        return events

    def test_still_face_never_speaks(self):
        """A face that does not move is not a sentence, however long."""
        gate = lipread.MouthMotion()
        events = self.feed(gate, [0.0005] * 500)
        self.assertEqual([], events)

    def test_a_moving_mouth_opens_and_closes_an_utterance(self):
        gate = lipread.MouthMotion()
        quiet = [0.0005] * 10
        speech = [0.05] * 30
        events = self.feed(gate, quiet + speech + quiet)
        kinds = [event[0] for event in events]
        self.assertEqual(["start", "speech", "end"], kinds)
        # The kept utterance counts the moving frames, not the quiet ones:
        # the onset confirmation and the pause are not words.
        self.assertGreaterEqual(events[1][2], 20)
        self.assertLess(events[1][2], 35)

    def test_a_steady_hum_never_opens_an_utterance(self):
        """Motion that never rests is not speech, and does not grow a gate."""
        gate = lipread.MouthMotion()
        self.assertEqual([], self.feed(gate, [0.02] * 60))
        self.assertAlmostEqual(0.04, gate.threshold(), places=6)
        self.assertGreater(gate.threshold(), lipread.MOTION_FLOOR)

    def test_the_gate_reports_its_own_jitter(self):
        """The spread of a still camera is a fact the harness can show."""
        gate = lipread.MouthMotion()
        self.feed(gate, [0.001, 0.003, 0.002])
        self.assertAlmostEqual(0.002, gate.jitter(), places=6)

    def test_a_brief_twitch_is_dropped(self):
        gate = lipread.MouthMotion()
        events = self.feed(gate, [0.0005] * 10 + [0.1] * 6 + [0.0005] * 20)
        kinds = [event[0] for event in events]
        self.assertIn("cancel", kinds)
        self.assertIn("end", kinds)
        self.assertNotIn("speech", kinds)

    def test_the_longest_utterance_is_cut(self):
        gate = lipread.MouthMotion(max_seconds=1.0)
        events = self.feed(gate, [0.0005] * 5 + [0.1] * 200)
        speech = [event for event in events if event[0] == "speech"]
        self.assertTrue(speech)
        self.assertLessEqual(speech[0][2], gate.max_frames)
        self.assertEqual("longest", speech[0][3])

    def test_reset_forgets_the_room(self):
        gate = lipread.MouthMotion()
        self.feed(gate, [0.02] * 20)
        self.assertTrue(gate.recent)
        gate.reset()
        self.assertFalse(gate.recent)
        self.assertFalse(gate.active)
        self.assertEqual(lipread.MOTION_FLOOR, gate.threshold())


class DecodeTest(unittest.TestCase):
    """Greedy CTC decoding and the certainty bands."""

    def frames(self, path, vocab):
        """Return probability frames whose argmax follows PATH."""
        rows = []
        for index in path:
            row = [0.01] * vocab
            row[index] = 0.97
            rows.append(row)
        return rows

    def test_greedy_decode_collapses_and_breaks_words(self):
        tokens = ["<blank>", "A", "\u2581B", "<eos>"]
        # Two frames of A, a blank, then the word B.
        result = lipread.decode_ctc(self.frames([1, 1, 0, 2], 4), tokens)
        self.assertEqual("A B", result["text"])
        self.assertAlmostEqual(0.97, result["confidence"], places=2)

    def test_blank_and_end_are_not_text(self):
        tokens = ["<blank>", "A", "<eos>"]
        result = lipread.decode_ctc(self.frames([1, 0, 2], 3), tokens)
        self.assertEqual("A", result["text"])

    def test_all_blank_is_no_words(self):
        tokens = ["<blank>", "A", "<eos>"]
        result = lipread.decode_ctc(self.frames([0, 0, 0], 3), tokens)
        self.assertEqual("", result["text"])
        self.assertEqual(0.0, result["confidence"])

    def test_a_log_probability_input_decodes_the_same(self):
        """The real runtime hands over logs, not probabilities."""
        tokens = ["<blank>", "A", "<eos>"]
        rows = [[-4.6, -0.03, -4.6], [-4.4, -0.02, -4.6]]
        result = lipread.decode_ctc(rows, tokens)
        self.assertEqual("A", result["text"])
        self.assertGreater(result["confidence"], 0.9)

    def test_the_doubtful_frame_fraction_is_reported(self):
        tokens = ["<blank>", "A", "<eos>"]
        rows = [[0.0, 0.9, 0.0], [0.4, 0.45, 0.15]]
        result = lipread.decode_ctc(rows, tokens)
        self.assertAlmostEqual(0.5, result["low"], places=2)

    def test_the_bands_are_the_measured_ones(self):
        self.assertEqual("sure", lipread.certainty(0.90))
        self.assertEqual("sure", lipread.certainty(0.99))
        self.assertEqual("likely", lipread.certainty(0.85))
        self.assertEqual("unsure", lipread.certainty(0.84))
        self.assertEqual("rejected", lipread.certainty(0.79))

    def test_the_band_names_are_stable(self):
        """The band boundaries are facts the docs and the tests share."""
        self.assertEqual(0.90, lipread.SURE_CONFIDENCE)
        self.assertEqual(0.85, lipread.LIKELY_CONFIDENCE)
        self.assertEqual(0.80, lipread.DEFAULT_FLOOR_CONFIDENCE)


class GeometryTest(unittest.TestCase):
    """The crop the model was trained on."""

    def test_the_crop_is_the_trained_one(self):
        x, y, size = lipread.mouth_crop_geometry()
        self.assertEqual((81, 110, 96), (x, y, size))
        self.assertEqual(88, lipread.MODEL_SIZE)
        self.assertEqual(4, lipread.crop_center())
        # The patch at the crop origin still holds the mouth centre.
        mouth_x, mouth_y = lipread.ALIGNMENT_POINTS[3]
        self.assertTrue(x <= mouth_x <= x + size)
        self.assertTrue(y <= mouth_y <= y + size)

    def test_the_normalization_is_the_trained_one(self):
        self.assertEqual(0.421, lipread.PIXEL_MEAN)
        self.assertEqual(0.165, lipread.PIXEL_STD)
        self.assertEqual(25, lipread.FPS)


class ModelFilesTest(unittest.TestCase):
    """What a model directory must hold."""

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="lipread-model-")
        self.addCleanup(shutil.rmtree, self.directory, True)

    def write(self, name, body=b""):
        path = os.path.join(self.directory, name)
        with open(path, "wb") as handle:
            handle.write(body)
        return path

    def test_an_empty_directory_names_every_missing_file(self):
        reason = lipread.ModelFiles(self.directory).reason()
        self.assertIn("lipread_ctc.int8.onnx", reason)
        self.assertIn("tokens.json", reason)
        self.assertIn("face_detection_yunet_2023mar.onnx", reason)
        self.assertTrue(reason.startswith("Model unavailable"))

    def test_a_complete_directory_has_no_reason(self):
        for entry in lipread.MODEL_FILES:
            self.write(entry["name"])
        self.assertIsNone(lipread.ModelFiles(self.directory).reason())

    def test_a_wrong_size_is_reported(self):
        for entry in lipread.MODEL_FILES:
            self.write(entry["name"])
        problems = lipread.verify(self.directory)
        self.assertTrue(problems)
        self.assertTrue(all(problem.startswith("Model size") for problem in problems))

    def test_a_vocabulary_of_the_wrong_length_is_refused(self):
        self.write("tokens.json", json.dumps(["<blank>"]).encode("utf-8"))
        with self.assertRaises(ValueError) as raised:
            lipread.ModelFiles(self.directory).tokens()
        self.assertIn("Vocabulary", str(raised.exception))

    def test_a_download_is_atomic_and_leaves_nothing_partial(self):
        """An interrupted download never leaves a half model behind."""

        def broken(url, path):
            with open(path, "wb") as handle:
                handle.write(b"half")
            raise OSError("connection dropped")

        with self.assertRaises(OSError):
            lipread.download("tokens.json", self.directory, opener=broken)
        self.assertEqual([], os.listdir(self.directory))

    def test_a_download_lands_under_its_name(self):
        def fake(url, path):
            with open(path, "wb") as handle:
                handle.write(b"complete")

        path = lipread.download("tokens.json", self.directory, opener=fake)
        self.assertTrue(path.endswith("tokens.json"))
        with open(path, "rb") as handle:
            self.assertEqual(b"complete", handle.read())


class CameraStateTest(unittest.TestCase):
    """The camera's own words and fields."""

    def test_every_state_has_its_label(self):
        self.assertEqual("Camera · live · 1 face",
                         lipread.CameraState("live").measure(faces=1).label())
        self.assertEqual("Camera · live · no face",
                         lipread.CameraState("live").measure(faces=0).label())
        self.assertEqual("Camera · live · 2 faces",
                         lipread.CameraState("live").measure(faces=2).label())
        self.assertEqual("Camera · denied", lipread.CameraState("denied").label())
        self.assertEqual("Camera · failed · busy",
                         lipread.CameraState("failed", reason="busy").label())
        self.assertEqual("Camera · ended", lipread.CameraState("ended").label())
        self.assertEqual("Camera · paused", lipread.CameraState("paused").label())

    def test_the_fields_are_the_protocol(self):
        state = lipread.CameraState("live", device=0)
        state.measure(faces=1, fps=24.6)
        fields = state.fields()
        self.assertEqual("live", fields["state"])
        self.assertEqual("0", fields["device"])
        self.assertEqual(1, fields["faces"])
        self.assertEqual(24.6, fields["fps"])


class SidecarTest(unittest.TestCase):
    """The sidecar's lifecycle and what it does with a reading."""

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="lipread-sidecar-")
        self.addCleanup(shutil.rmtree, self.directory, True)
        for entry in lipread.MODEL_FILES:
            with open(os.path.join(self.directory, entry["name"]), "wb"):
                pass

    def args(self, **changes):
        args = sidecar_module.parse_args(
            ["lipread", "--model-dir", self.directory, "--camera-consent"])
        for key, value in changes.items():
            setattr(args, key, value)
        return args

    def build(self, motions, results=None, error=None, **changes):
        tracks = lipread.scripted_tracks(motions)
        camera = lipread.ScriptedCamera(frames=[object() for _ in tracks],
                                        error=error)
        tracker = lipread.ScriptedTracker(tracks)
        recognizer = lipread.ScriptedRecognizer(results=results)
        events = FakeEvents()
        sidecar = sidecar_module.LipreadSidecar(
            self.args(**changes), events=events, camera=camera,
            tracker=tracker, recognizer=recognizer, player=NullAudio())
        return sidecar, events, camera

    def pump(self, sidecar, events, name, count=1, seconds=6.0, **fields):
        """Run the loop until COUNT events of NAME with FIELDS have arrived."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            sidecar.tick()
            found = [e for e in events.sent if e.get("event") == name
                     and all(e.get(key) == value for key, value in fields.items())]
            if len(found) >= count:
                return True
            time.sleep(0.002)
        return False

    def utterance(self, moving=30):
        return [0.0005] * 8 + [0.05] * moving + [0.0005] * 14

    def test_interrupt_preserves_in_progress_mouth_gesture(self):
        sidecar, events, camera = self.build(self.utterance())
        try:
            sidecar.start_session({"event": "start", "protocol": 1})
            sidecar.speech_active = True
            before = len(events.sent)
            sidecar.handle({"event": "interrupt", "id": 7})
            self.assertTrue(sidecar.speech_active)
            self.assertEqual(events.sent[before:], [
                {"event": "interrupted", "interrupt_id": 7},
                {"event": "listening", "interrupt_id": 7},
            ])
            self.assertTrue(camera.opened())
        finally:
            sidecar.handle({"event": "stop"})

    def test_no_consent_means_no_device(self):
        sidecar, events, camera = self.build(self.utterance())
        sidecar.args.camera_consent = False
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertEqual([], camera.calls)
        self.assertEqual(["denied"],
                         [e.get("state") for e in events.sent if e.get("event") == "camera"])
        self.assertTrue(any(e.get("event") == "error"
                            and "permission" in e.get("message").lower()
                            for e in events.sent))

    def test_a_recording_needs_no_consent_and_no_camera(self):
        """A file source is not a camera: it starts without a grant."""
        sidecar, events, camera = self.build(self.utterance(), source="/tmp/face.mp4")
        sidecar.args.camera_consent = False
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertEqual(["opening", "live"],
                         [e.get("state") for e in events.sent if e.get("event") == "camera"])
        self.assertFalse(any(e.get("event") == "error" for e in events.sent))

    def test_a_missing_model_never_touches_the_camera(self):
        sidecar, events, camera = self.build(self.utterance(),
                                             model_dir="/nonexistent/lipread")
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertEqual([], camera.calls)
        self.assertTrue(any(e.get("event") == "error"
                            and "Model unavailable" in e.get("message")
                            for e in events.sent))

    def test_start_reports_opening_then_live(self):
        sidecar, events, camera = self.build(self.utterance())
        sidecar.start_session({"event": "start", "protocol": 1})
        states = [e.get("state") for e in events.sent if e.get("event") == "camera"]
        self.assertEqual(["opening", "live"], states)
        self.assertEqual(["open"], camera.calls)

    def test_a_sure_reading_becomes_a_delegation(self):
        sidecar, events, _camera = self.build(
            self.utterance(),
            results=[{"text": "add a docstring", "confidence": 0.96,
                      "low": 0.0, "pieces": [], "seconds": 0.02}])
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertTrue(self.pump(sidecar, events, "delegation"))
        delegation = [e for e in events.sent if e.get("event") == "delegation"][0]
        self.assertEqual("add a docstring", delegation["text"])
        self.assertEqual("sure", delegation["certainty"])
        caption = [e for e in events.sent if e.get("event") == "user_delta"][0]
        self.assertEqual("sure", caption["certainty"])

    def test_a_likely_reading_is_marked_likely(self):
        sidecar, events, _camera = self.build(
            self.utterance(),
            results=[{"text": "maybe the tests", "confidence": 0.87,
                      "low": 0.1, "pieces": [], "seconds": 0.02}])
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertTrue(self.pump(sidecar, events, "delegation"))
        delegation = [e for e in events.sent if e.get("event") == "delegation"][0]
        self.assertEqual("likely", delegation["certainty"])

    def test_an_unsure_reading_is_shown_and_never_sent(self):
        sidecar, events, _camera = self.build(
            self.utterance(),
            results=[{"text": "the second one", "confidence": 0.82,
                      "low": 0.4, "pieces": [], "seconds": 0.02}])
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertTrue(self.pump(sidecar, events, "user_delta"))
        caption = [e for e in events.sent if e.get("event") == "user_delta"][0]
        self.assertEqual("unsure", caption["certainty"])
        self.assertEqual([], [e for e in events.sent if e.get("event") == "delegation"])
        self.assertTrue(any("uncertain" in (e.get("message") or "")
                            for e in events.sent if e.get("event") == "notice"))

    def test_a_low_confidence_reading_is_not_shown_as_speech(self):
        sidecar, events, _camera = self.build(
            self.utterance(),
            results=[{"text": "worst guess", "confidence": 0.4,
                      "low": 0.8, "pieces": [], "seconds": 0.02}])
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertTrue(self.pump(sidecar, events, "notice"))
        self.assertEqual([], [e for e in events.sent if e.get("event") == "user_delta"])
        self.assertEqual([], [e for e in events.sent if e.get("event") == "delegation"])
        self.assertTrue(any("low confidence" in (e.get("message") or "")
                            for e in events.sent if e.get("event") == "notice"))

    def test_an_inference_failure_is_one_utterance(self):
        sidecar, events, camera = self.build(self.utterance() + [0.0005] * 400)

        class Broken:
            """A model that fails on every utterance."""

            def open(self):
                return None

            def __call__(self, crops):
                raise ValueError("boom")

        sidecar.recognizer = Broken()
        sidecar.start_session({"event": "start", "protocol": 1})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sidecar.tick()
            if any(e.get("event") == "segment" and e.get("state") == "failed"
                   for e in events.sent):
                break
            time.sleep(0.002)
        # The model failing is one utterance's: the camera is still on.
        self.assertTrue(camera.opened(), "a failed reading ended the camera")
        self.assertTrue(any(e.get("event") == "segment"
                            and e.get("state") == "failed" for e in events.sent))
        self.assertTrue(any(e.get("event") == "notice" for e in events.sent))

    def test_no_face_frames_do_not_become_words(self):
        motions = [0.0005] * 10 + [0.05] * 30 + [0.0005] * 14
        tracks = lipread.scripted_tracks(motions, faces=0)
        camera = lipread.ScriptedCamera(frames=[object() for _ in tracks])
        tracker = lipread.ScriptedTracker(tracks)
        events = FakeEvents()
        sidecar = sidecar_module.LipreadSidecar(
            self.args(), events=events, camera=camera, tracker=tracker,
            recognizer=lipread.ScriptedRecognizer(), player=NullAudio())
        sidecar.start_session({"event": "start", "protocol": 1})
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            sidecar.tick()
            time.sleep(0.002)
        self.assertEqual([], [e for e in events.sent if e.get("event") == "delegation"])
        self.assertTrue(any(e.get("event") == "notice"
                            and "no face" in (e.get("message") or "")
                            for e in events.sent))
        # Which of the two the frame is dropped as depends on whether the
        # two-second face notice fired first; both mean no words.
        self.assertIn([e for e in events.sent if e.get("event") == "segment"][-1]["reason"],
                      ("no face", "unusable frames"))

    def test_two_faces_are_ambiguous_and_dropped(self):
        motions = [0.0005] * 8 + [0.05] * 30 + [0.0005] * 14
        tracks = lipread.scripted_tracks(motions, faces=2, reason="multiple faces")
        camera = lipread.ScriptedCamera(frames=[object() for _ in tracks])
        events = FakeEvents()
        sidecar = sidecar_module.LipreadSidecar(
            self.args(), events=events, camera=camera,
            tracker=lipread.ScriptedTracker(tracks),
            recognizer=lipread.ScriptedRecognizer(), player=NullAudio())
        sidecar.start_session({"event": "start", "protocol": 1})
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            sidecar.tick()
            segments = [e for e in events.sent if e.get("event") == "segment"]
            if segments:
                break
            time.sleep(0.002)
        reasons = [e.get("reason") for e in segments if e.get("state") == "dropped"]
        self.assertTrue(any(reason in ("unusable frames", "too short") for reason in reasons),
                        reasons)
        self.assertEqual([], [e for e in events.sent if e.get("event") == "delegation"])

    def test_mute_closes_the_camera_and_resume_opens_it(self):
        sidecar, events, camera = self.build([0.0005] * 200)
        sidecar.start_session({"event": "start", "protocol": 1})
        sidecar.handle({"event": "mute", "on": True})
        self.assertFalse(camera.opened())
        self.assertEqual("paused",
                         [e for e in events.sent if e.get("event") == "camera"][-1]["state"])
        sidecar.handle({"event": "mute", "on": False})
        self.assertTrue(camera.opened())
        self.assertEqual("live",
                         [e for e in events.sent if e.get("event") == "camera"][-1]["state"])

    def test_stop_releases_the_device_and_says_ended(self):
        sidecar, events, camera = self.build([0.0005] * 50)
        sidecar.start_session({"event": "start", "protocol": 1})
        sidecar.handle({"event": "stop"})
        self.assertFalse(camera.opened())
        self.assertEqual("close", camera.calls[-1])
        self.assertEqual("ended",
                         [e for e in events.sent if e.get("event") == "camera"][-1]["state"])
        self.assertIn("closed", events.names())
        self.assertEqual([], sidecar.workers)

    def test_a_camera_that_dies_is_a_failure_and_closed(self):
        sidecar, events, camera = self.build(self.utterance(),
                                             error="Camera unavailable · 0")
        camera.error = "Camera unavailable · 0"
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertFalse(camera.opened())
        self.assertTrue(any(e.get("event") == "error" for e in events.sent))
        self.assertEqual("failed",
                         [e for e in events.sent if e.get("event") == "camera"][-1]["state"])

    def test_frames_stopping_mid_session_fails_and_releases(self):
        sidecar, events, camera = self.build(self.utterance()[:5])
        sidecar.start_session({"event": "start", "protocol": 1})
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and camera.opened():
            sidecar.tick()
            time.sleep(0.002)
        self.assertFalse(camera.opened())
        self.assertTrue(any(e.get("event") == "error"
                            and "no frames" in e.get("message")
                            for e in events.sent))

    def test_a_recording_that_ends_closes_cleanly(self):
        """A replayed recording's last frame ends the session, not fails it.

        A file is not a camera: reaching its end is the recording being
        over, so the session closes the way a stop closes it, and the
        last utterance still gets its words before it does.
        """
        sidecar, events, camera = self.build(
            self.utterance(),
            source="/tmp/face.mp4",
            results=[{"text": "close the window", "confidence": 0.96,
                      "low": 0.0, "pieces": [], "seconds": 0.02}])
        sidecar.args.camera_consent = False
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertTrue(self.pump(sidecar, events, "delegation"))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and "closed" not in events.names():
            sidecar.tick()
            time.sleep(0.002)
        self.assertIn("closed", events.names())
        self.assertFalse(any(e.get("event") == "error" for e in events.sent))
        self.assertFalse(camera.opened())
        self.assertEqual("ended",
                         [e for e in events.sent if e.get("event") == "camera"][-1]["state"])
        self.assertEqual("close", camera.calls[-1])

    def test_a_closed_pipe_ends_the_loop_and_the_session(self):
        """Emacs going away without a stop leaves no camera open.

        The real transport is exercised: the sidecar's stdin is a pipe
        whose writer disappears, which is what a killed Emacs looks like.
        """
        read_end, write_end = os.pipe()
        out = tempfile.TemporaryFile(mode="w+")
        events = sidecar_module.Events(os.fdopen(read_end, "r"), out)
        tracks = lipread.scripted_tracks([0.0005] * 500)
        camera = lipread.ScriptedCamera(frames=[object() for _ in tracks])
        sidecar = sidecar_module.LipreadSidecar(
            self.args(), events=events, camera=camera,
            tracker=lipread.ScriptedTracker(tracks),
            recognizer=lipread.ScriptedRecognizer(), player=NullAudio())
        loop = sidecar_module.Loop(events, tick=0.01)
        sidecar.loop = loop
        thread = threading.Thread(target=lambda: loop.run(sidecar.handle, sidecar.on_tick),
                                  daemon=True)
        thread.start()
        os.write(write_end, b'{"event":"start","protocol":1}\n')
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not camera.opened():
                time.sleep(0.01)
            self.assertTrue(camera.opened())
            # Emacs goes away: the write end closes and the loop ends.
            os.close(write_end)
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
        finally:
            sidecar.handle({"event": "stop"})
            out.close()
        self.assertFalse(camera.opened())

    def test_a_reading_without_words_is_dropped(self):
        sidecar, events, _camera = self.build(
            self.utterance(),
            results=[{"text": "", "confidence": 0.99, "low": 0.0,
                      "pieces": [], "seconds": 0.01}])
        sidecar.start_session({"event": "start", "protocol": 1})
        self.assertTrue(self.pump(sidecar, events, "segment", state="dropped"))
        segments = [e for e in events.sent if e.get("event") == "segment"]
        self.assertEqual("dropped", segments[-1]["state"])
        self.assertEqual("no words", segments[-1]["reason"])
        self.assertEqual([], [e for e in events.sent if e.get("event") == "delegation"])


class SelfTestCommandTest(unittest.TestCase):
    """The sidecar's own checks, run the way the repository runs them."""

    def test_self_test_passes_without_a_camera(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, SCRIPT, "--self-test", "--model-dir", directory],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("self-test ok", result.stdout)

    def test_check_names_the_licence_and_the_missing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, SCRIPT, "--check", "--model-dir", directory],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(1, result.returncode)
            self.assertIn("research and non-commercial", result.stdout)
            self.assertIn("Model unavailable · lipread_ctc.int8.onnx", result.stdout)

    def test_no_model_is_downloaded_by_the_sidecar(self):
        """The sidecar's source never fetches a model; setup does."""
        with open(SCRIPT, encoding="utf-8") as handle:
            source = handle.read()
        for forbidden in ("urlopen", "urllib.request", "MODEL_URLS", "http://",
                          "https://"):
            self.assertNotIn(forbidden, source)


class PrivacyTest(unittest.TestCase):
    """Frames stay in memory, and no file is written."""

    def test_the_sidecar_writes_no_frame(self):
        with open(SCRIPT, encoding="utf-8") as handle:
            source = handle.read()
        for forbidden in ("imwrite", "cv2.imwrite", "savefig", "tempfile.mkdtemp"):
            self.assertNotIn(forbidden, source)

    def test_the_library_writes_only_a_temp_model_dir_for_its_self_test(self):
        with open(os.path.join(ROOT, "scripts", "harness_voice_lipread.py"),
                  encoding="utf-8") as handle:
            source = handle.read()
        self.assertNotIn("imwrite", source)
        self.assertIn("def self_test_model_dir", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
