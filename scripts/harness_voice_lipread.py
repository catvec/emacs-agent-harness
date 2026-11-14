#!/usr/bin/env python3
"""Local visual speech recognition (lip reading) for the harness's voice.

This module is the camera, mouth and model half of the ``lipread'' voice
provider.  ``scripts/harness-voice-live-lipread`` imports it and speaks
the harness's JSON-lines sidecar protocol; everything here stays on this
machine: frames are read from the camera, cropped to a mouth patch,
kept in memory and dropped, never written to disk and never sent
anywhere.

The model is Auto-AVSR's LRS3 visual-only recognizer (English, 25 fps,
88x88 grayscale mouth crops), exported to ONNX and quantized to int8 by
a third party.  The weights are research/non-commercial only because
LRS3 is; see ``docs/voice-lip-reading.md``.  Nothing in this module
downloads anything: ``scripts/harness-voice-lipread-setup`` fetches the
files and says where they go.

The module is stdlib-only on import.  numpy, OpenCV and onnxruntime are
loaded by :func:`load_runtime`, the function that actually reads frames
and runs the model, so the repository's tests, the sidecar's
``--self-test`` and the decision logic below run without them.

What the pure half decides, and the tests pin:

* :class:`MouthMotion` -- where an utterance starts and ends, from the
  movement of the mouth patch; a still face never becomes a sentence.
* :func:`decode_ctc` -- greedy CTC decode of the model's log
  probabilities, plus the confidence facts the certainty band reads.
* :func:`certainty` -- ``sure``, ``likely`` or ``unsure``, from the
  measured calibration in ``docs/voice-lip-reading.md``.
* :func:`mouth_crop_geometry` -- the alignment and crop the model was
  trained on, copied from Auto-AVSR's Apache-2.0 preprocessing.
* :class:`ModelFiles` -- what a model directory must hold.
"""

import collections
import json
import math
import os
import shutil
import sys
import tempfile
import time

#: The rate the model was trained at.  Auto-AVSR's preprocessing samples
#: every clip at 25 fps, and a camera that delivers fewer frames reads
#: worse (the ONNX exporter measured 38% -> 48% -> 60% WER at 25 -> 15 ->
#: 10 fps), so the sidecar resamples to this rate and says so when it
#: cannot keep up.
FPS = 25

#: Longest utterance fed to the model, in seconds.  The exported model
#: trims its position table to 500 frames (20 s); a fifth of that keeps
#: latency short and leaves the beam to the conversation.
MAX_SECONDS = 6.0

#: Shortest utterance worth a model call, in seconds.  A lip smack or a
#: nod moves the patch too briefly to be words.
MIN_SECONDS = 0.36

#: Mean absolute difference between consecutive mouth patches, on a
#: 0..1 scale, above which the mouth is moving.  Measured on LRS3 crops:
#: a speaking mouth averages 0.013-0.087 per frame, so this floor sits
#: under the quietest clip and well over sensor noise on a still face.
MOTION_FLOOR = 0.004

#: Seconds of still mouth that end an utterance.
HANGOVER = 0.32

#: The confidence bands, measured rather than guessed.  On 100 clips of
#: the LRS3 test set, greedy decode with this int8 ONNX export, the mean
#: top-1 probability over the non-blank frames separated good transcripts
#: from bad ones like this (``docs/voice-lip-reading.md`` has the table):
#:
#:   >= 0.90   30 of 100 clips kept, 6.6% WER
#:   >= 0.85   45 of 100 clips kept, 10.7% WER
#:   >= 0.80   55 of 100 clips kept, 13.9% WER
#:   <  0.80   45 of 100 clips kept, 58.4% WER
#:
#: So ``sure`` is the band the model reads under 10% WER, ``likely`` the
#: one under 15%, and below the floor the sidecar neither shows the text
#: as speech nor sends it.
SURE_CONFIDENCE = 0.90
LIKELY_CONFIDENCE = 0.85
DEFAULT_FLOOR_CONFIDENCE = 0.80

#: Below this top-1 probability a frame counts as a doubtful one.  It is
#: reported with the transcript; it does not move a band, because the
#: measured separation came from the mean, not from this fraction.
DOUBTFUL_FRAME = 0.50

#: The crop and alignment Auto-AVSR trains on: a 256x256 aligned face
#: with the mouth patch cut 96x96 around the mouth centre, then centre
#: cropped to 88x88 for the model.  The four points are the mean face's
#: right eye, left eye, nose tip and mouth centre, taken from
#: ``20words_mean_face.npy`` in mpc001/auto_avsr (Apache-2.0, Copyright
#: Imperial College London).
ALIGN_SIZE = 256
CROP_SIZE = 96
MODEL_SIZE = 88
ALIGNMENT_POINTS = ((102.07394305706590, 94.27230352389712),
                    (156.36130541621310, 93.57815605186966),
                    (129.00373787023733, 135.90343028603127),
                    (129.31337322587925, 157.82299634918854))

#: Pixel normalization the model expects, from Auto-AVSR's
#: ``VideoTransform`` (test subset).
PIXEL_MEAN = 0.421
PIXEL_STD = 0.165

#: The model's vocabulary size, so a wrong ``tokens.json`` is caught
#: before a model call rather than decoded into nonsense.
VOCAB_SIZE = 5049

#: The rate a reply is played at, which is the local pipeline's rate.
RATE = 16000

#: Where ``scripts/harness-voice-lipread-setup`` puts the files by
#: default, relative to the user's data directory.
DEFAULT_MODEL_SUBDIR = os.path.join("harness", "lipread")

#: The files a model directory must hold, with the size and SHA-256 of
#: the published copies.  ``required`` files decide whether the provider
#: can run; ``tokens.json`` is part of every usable model.
MODEL_FILES = (
    {"name": "lipread_ctc.int8.onnx", "required": True, "bytes": 203357712,
     "sha256": "da02d72ee472eb3d7d50f7dd309bfe81973acb4cac8bb770dd86aa97872f195b",
     "what": "Auto-AVSR visual recognizer, int8 ONNX"},
    {"name": "tokens.json", "required": True, "bytes": 78452,
     "sha256": "97f0f20cfebadaf51f7cdb9e7a26835fa0fbd6a956701434e899a4f9934d979c",
     "what": "SentencePiece unigram vocabulary"},
    {"name": "face_detection_yunet_2023mar.onnx", "required": True, "bytes": 232589,
     "sha256": "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
     "what": "OpenCV YuNet face detector"},
)


def log(text):
    """Write a diagnostic line to stderr, where the protocol cannot see it."""
    sys.stderr.write("%s\n" % text)
    sys.stderr.flush()


#; ------------------------------------------------------------------
#; The model directory
#; ------------------------------------------------------------------

class ModelFiles:
    """The files a lip-reading model directory needs, and what is missing.

    ``problems`` is what the setup list and the sidecar's ``error`` say:
    one line per missing file, named as the file rather than as a path,
    so a notice fits a controls line.
    """

    def __init__(self, directory, files=MODEL_FILES):
        self.directory = directory
        self.files = list(files)

    def path(self, name):
        """Return the full path of model file NAME."""
        return os.path.join(self.directory, name)

    def missing(self):
        """Return the required files that are not there."""
        return [entry for entry in self.files
                if entry["required"] and not os.path.isfile(self.path(entry["name"]))]

    def reason(self):
        """Return why the model directory cannot run, or nil."""
        missing = self.missing()
        if missing:
            names = ", ".join(entry["name"] for entry in missing)
            return "Model unavailable · %s" % names
        return None

    def tokens(self):
        """Return the vocabulary as a list, or signal a one-line reason."""
        try:
            with open(self.path("tokens.json"), encoding="utf-8") as handle:
                tokens = json.load(handle)
        except (OSError, ValueError) as error:
            raise ValueError("Vocabulary · %s" % error)
        if not isinstance(tokens, list) or len(tokens) != VOCAB_SIZE:
            raise ValueError("Vocabulary · %d pieces" % (len(tokens)
                                                        if isinstance(tokens, list) else 0))
        return tokens


#; ------------------------------------------------------------------
#; Utterances from a moving mouth
#; ------------------------------------------------------------------

class MouthMotion:
    """Decide where a spoken utterance starts and ends, from mouth motion.

    There is no audio in this path, so the trigger is movement of the
    aligned mouth patch: above the gate for :data:`ONSET_FRAMES`
    consecutive frames opens an utterance, below it for the hangover
    closes one.  The gate follows the quietest recent frames, so a camera
    with more sensor noise, or a person further away, does not need a
    different setting -- only a few still frames to learn from.

    The floor is the minimum motion over the last :data:`WINDOW` frames,
    doubled, and never below :data:`MOTION_FLOOR`.  The minimum rather
    than an average is what makes this work on the measured data: speech
    has pauses, so the quietest recent frame is a quiet frame, while a
    jittery camera has no quiet frames at all and raises its own gate.
    It is a heuristic, and a real webcam may need the setting adjusted;
    that is one of the limitations ``docs/voice-lip-reading.md`` states.

    ``feed`` returns events the way the sidecar's loop wants them:
    ``("start", uid)``, ``("speech", uid, frames, why)`` for a kept
    utterance, ``("cancel", uid, reason)`` for one too short to be words,
    and ``("end", uid)`` when the mouth stops.
    """

    ONSET_FRAMES = 3
    WINDOW = 50
    RISE = 2.0

    def __init__(self, fps=FPS, floor=MOTION_FLOOR, hangover=HANGOVER,
                 min_seconds=MIN_SECONDS, max_seconds=MAX_SECONDS):
        self.fps = float(fps)
        self.floor = float(floor)
        self.hangover = max(1, int(round(hangover * self.fps)))
        self.min_frames = max(1, int(round(min_seconds * self.fps)))
        self.max_frames = max(self.min_frames, int(round(max_seconds * self.fps)))
        self.reset()

    def reset(self):
        """Forget the running utterance and the frames the gate learned from."""
        self.recent = collections.deque(maxlen=self.WINDOW)
        self.active = False
        self.above = 0
        self.below = 0
        self.frames = 0
        self.moving = 0
        self.uid = 0

    def threshold(self):
        """Return the motion level that counts as a moving mouth now."""
        if not self.recent:
            return self.floor
        return max(self.floor, self.RISE * min(self.recent))

    def jitter(self):
        """Return the frame-to-frame variation of the recent motion.

        A still camera's mouth patch still changes a little, and that
        noise differs between cameras; the spread of the recent frames
        makes the gate rise above it.  It is reported, not acted on by
        itself: a speaking mouth's own variation is larger.
        """
        if len(self.recent) < 2:
            return 0.0
        return max(self.recent) - min(self.recent)

    def feed(self, motion):
        """Feed one frame's MOTION in [0, 1]; return the events it decides."""
        events = []
        motion = float(motion or 0.0)
        moving = motion > self.threshold()
        if not self.active:
            self.recent.append(motion)
            self.above = self.above + 1 if moving else 0
            if self.above >= self.ONSET_FRAMES:
                self.uid += 1
                self.active = True
                self.below = 0
                self.frames = 0
                self.moving = 0
                events.append(("start", self.uid))
            return events
        # An utterance counts the frames that moved; the hangover that
        # ends it is a pause, not words.
        self.frames += 1
        if moving:
            self.moving = self.frames
            self.below = 0
        else:
            self.below += 1
            self.recent.append(motion)
        if self.frames >= self.max_frames:
            events.append(("speech", self.uid, self.moving, "longest"))
            self.end_utterance()
            return events
        if self.below >= self.hangover:
            if self.moving < self.min_frames:
                events.append(("cancel", self.uid, "too short"))
            else:
                events.append(("speech", self.uid, self.moving, "pause"))
            events.append(("end", self.uid))
            self.end_utterance()
        return events

    def end_utterance(self):
        """Close the running utterance and keep listening."""
        self.active = False
        self.frames = 0
        self.moving = 0
        self.below = 0
        self.above = 0


#; ------------------------------------------------------------------
#; Decoding and certainty
#; ------------------------------------------------------------------

def _argmax(row):
    """Return the index of the largest value in ROW."""
    best, index = None, 0
    for position, value in enumerate(row):
        if best is None or value > best:
            best, index = value, position
    return index


def decode_ctc(log_probs, tokens, blank=0):
    """Decode CTC LOG_PROBS into text, with the confidence facts.

    ``log_probs`` is one row of log probabilities per frame, over the
    vocabulary ``tokens`` (``<blank>`` first, ``<eos>`` last).  Greedy
    decode: take each frame's best piece, collapse repeats, drop blanks
    and the end piece, and join the pieces with ``▁`` as a word break.

    Return a dict with ``text``, ``confidence`` (the mean top-1
    probability over the frames that are not blank), ``low`` (the
    fraction of those frames below :data:`DOUBTFUL_FRAME`) and
    ``pieces``.  Those are the facts :func:`certainty` reads; this is
    the whole of the model's own statement about how sure it is.
    """
    pieces = []
    previous = None
    confidence = []
    total = 0.0
    for row in log_probs:
        index = _argmax(row)
        best = row[index]
        # A log probability can arrive as 0 for a saturated piece.
        probability = math.exp(best) if best < 0 else min(1.0, best)
        if index != blank:
            total += probability
            confidence.append(probability)
        if index != previous and index != blank and index != len(tokens) - 1:
            if 0 <= index < len(tokens):
                pieces.append(tokens[index])
        previous = index
    text = "".join(pieces).replace("\u2581", " ").strip()
    if confidence:
        mean = total / len(confidence)
        low = sum(1 for value in confidence if value < DOUBTFUL_FRAME) / len(confidence)
    else:
        mean, low = 0.0, 1.0
    return {"text": text, "confidence": mean, "low": low, "pieces": pieces}


def certainty(confidence, low=None, floor=DEFAULT_FLOOR_CONFIDENCE):
    """Return the certainty band for a transcript's CONFIDENCE.

    ``sure`` is the band the measured calibration puts under 10% WER,
    ``likely`` the one under 15%, and ``unsure`` is a transcript the
    model read but with less confidence than either.  Below ``floor`` the
    band is ``rejected``: the sidecar neither shows those words as speech
    nor sends them.  ``LOW`` is accepted for callers that carry the
    doubtful-frame fraction, which is a reported fact, not a band.
    """
    confidence = float(confidence or 0.0)
    if confidence < floor:
        return "rejected"
    if confidence >= SURE_CONFIDENCE:
        return "sure"
    if confidence >= LIKELY_CONFIDENCE:
        return "likely"
    return "unsure"


#: The words the harness shows for each certainty band.  `sure` says
#: nothing, since the ordinary transcript is already the certain case.
CERTAINTY_LABELS = {"sure": "", "likely": "likely", "unsure": "uncertain"}


#; ------------------------------------------------------------------
#; The mouth crop
#; ------------------------------------------------------------------

def mouth_crop_geometry(size=CROP_SIZE, target=ALIGN_SIZE):
    """Return the crop's origin and size on the aligned face, as (x, y, w).

    Auto-AVSR aligns the face so the four :data:`ALIGNMENT_POINTS` land
    where the mean face has them, then cuts a ``size`` patch around the
    transformed mouth centre and centre crops it to :data:`MODEL_SIZE`.
    The offsets are what both halves of that need.
    """
    x, y = ALIGNMENT_POINTS[3]
    half = size // 2
    return (max(0, min(target - size, int(round(x - half)))),
            max(0, min(target - size, int(round(y - half)))),
            size)


def crop_center(size=CROP_SIZE):
    """Return the offset of the model crop inside the mouth patch."""
    return (size - MODEL_SIZE) // 2


#; ------------------------------------------------------------------
#; The runtime: camera, face detector, model
#; ------------------------------------------------------------------

class Track:
    """What one frame says: the faces it holds, and the mouth patch.

    ``faces`` is how many faces the detector found, ``crop`` the aligned
    grayscale mouth patch as a 2-D sequence (a numpy array in the real
    path), ``motion`` the mean absolute change of the patch against the
    previous frame in [0, 1], and ``reason`` why there is no crop when
    there is none.
    """

    __slots__ = ("faces", "crop", "motion", "reason")

    def __init__(self, faces=0, crop=None, motion=0.0, reason=None):
        self.faces = faces
        self.crop = crop
        self.motion = motion
        self.reason = reason


def load_runtime():
    """Import numpy, OpenCV and onnxruntime, or raise one readable line."""
    try:
        import numpy  # noqa: F401
        import cv2  # noqa: F401
        import onnxruntime  # noqa: F401
    except ImportError as error:
        raise RuntimeError("Runtime unavailable · %s" % error)
    return {"numpy": numpy, "cv2": cv2, "onnxruntime": onnxruntime}


class Camera:
    """A frame source: a V4L2 camera, or a video file for a test.

    OpenCV owns the device, which is why the camera is not opened until
    the harness has asked for it: :func:`open` is the only place a
    device is touched, and :meth:`close` is idempotent so every error
    path can call it.  Nothing is written anywhere; ``source`` being a
    file is only how the fixtures are replayed.
    """

    def __init__(self, device=0, source=None, width=640, height=480):
        self.device = device
        self.source = source
        self.width = width
        self.height = height
        self.capture = None
        self.cv2 = None
        self.error = None
        self.started = None
        self.frames = 0
        self.fps = None
        self.last_frame = 0.0
        self.stamps = collections.deque(maxlen=50)

    def open(self, cv2=None):
        """Open the device or file, or return one line saying why not."""
        if cv2 is not None:
            self.cv2 = cv2
        cv2 = self.cv2
        if cv2 is None:
            self.error = "Runtime unavailable · cv2"
            return self.error
        target = self.source if self.source else self.device
        try:
            capture = cv2.VideoCapture(target)
        except Exception as error:  # noqa: BLE001 - shown in Emacs
            self.error = "Camera unavailable · %s" % error
            return self.error
        if not capture or not capture.isOpened():
            if capture:
                capture.release()
            what = os.path.basename(str(target)) if self.source else str(target)
            self.error = "Camera unavailable · %s" % what
            return self.error
        if not self.source:
            capture.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
            capture.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
            capture.set(cv2.CAP_PROP_FPS, FPS)
        self.capture = capture
        self.started = time.monotonic()
        self.last_frame = self.started
        self.stamps = collections.deque(maxlen=50)
        return None

    def read(self):
        """Return the next frame, or nil when the source has no more.

        A file is paced to :data:`FPS`, so a replayed fixture arrives at
        the rate the model was trained on rather than as fast as it
        decodes.
        """
        if self.capture is None:
            return None
        ok, frame = self.capture.read()
        if not ok or frame is None:
            return None
        self.frames += 1
        if self.source:
            # Pace from the previous frame, not from the start: a slow
            # model call must not be followed by a burst of catch-up
            # frames, which would read at the wrong rate and then stall.
            now = time.monotonic()
            due = max(now, self.last_frame + 1.0 / FPS)
            if due > now:
                time.sleep(due - now)
            self.last_frame = due
        self.stamps.append(time.monotonic())
        # A rate from two frames is noise: a device that has read a few
        # reports a measured one, and before that it reports none.
        if len(self.stamps) >= 10:
            span = self.stamps[-1] - self.stamps[0]
            self.fps = (len(self.stamps) - 1) / span if span > 0 else None
        return frame

    def close(self):
        """Release the device; safe to call twice, and after an error."""
        capture, self.capture = self.capture, None
        if capture is not None:
            try:
                capture.release()
            except Exception:  # noqa: BLE001 - release must not raise
                pass
        self.fps = None

    def opened(self):
        """Return whether the device is open now."""
        return self.capture is not None


class MouthTracker:
    """Find the face and cut the mouth patch the model was trained on.

    YuNet returns five face points -- both eyes, the nose and both mouth
    corners -- which are exactly the four stable points Auto-AVSR
    aligns on.  The largest face wins; a second face of comparable size
    is reported as ambiguity rather than guessed at, so a bystander is
    never read as the person using the harness.
    """

    #: Score above which a detection counts, and the NMS threshold.
    SCORE = 0.6
    NMS = 0.3

    #: A second face at least this fraction of the largest's area is
    #: treated as ambiguity: the harness must not silently pick a person.
    AMBIGUOUS = 0.35

    def __init__(self, model_path, numpy=None, cv2=None):
        self.model_path = model_path
        self.numpy = numpy
        self.cv2 = cv2
        self.detector = None
        self.previous = None
        self.error = None

    def open(self):
        """Build the detector, or return one line saying why not."""
        try:
            self.detector = self.cv2.FaceDetectorYN.create(
                self.model_path, "", (320, 320), self.SCORE, self.NMS, 5000)
        except Exception as error:  # noqa: BLE001 - shown in Emacs
            self.error = "Face detector unavailable · %s" % error
            return self.error
        return None

    def __call__(self, frame):
        """Return the :class:`Track` for FRAME."""
        np, cv2 = self.numpy, self.cv2
        height, width = frame.shape[:2]
        self.detector.setInputSize((width, height))
        try:
            count, faces = self.detector.detect(frame)
        except Exception as error:  # noqa: BLE001 - one bad frame is not a failure
            return Track(0, None, 0.0, "detector · %s" % error)
        if faces is None or not len(faces):
            self.previous = None
            return Track(0, None, 0.0, "no face")
        areas = sorted((float(face[2]) * float(face[3]) for face in faces), reverse=True)
        faces = sorted(faces, key=lambda face: float(face[2]) * float(face[3]),
                       reverse=True)
        ambiguous = len(areas) > 1 and areas[1] >= self.AMBIGUOUS * max(areas[0], 1.0)
        face = faces[0]
        points = np.array(face[4:14], dtype=np.float32).reshape(5, 2)
        right_eye, left_eye, nose = points[0], points[1], points[2]
        mouth = (points[3] + points[4]) / 2.0
        source = np.vstack([right_eye, left_eye, nose, mouth])
        target = np.array(ALIGNMENT_POINTS, dtype=np.float32)
        matrix = cv2.estimateAffinePartial2D(source, target, method=cv2.LMEDS)[0]
        if matrix is None:
            self.previous = None
            return Track(len(faces), None, 0.0, "alignment")
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        aligned = cv2.warpAffine(gray, matrix, (ALIGN_SIZE, ALIGN_SIZE))
        x, y, size = mouth_crop_geometry()
        crop = aligned[y:y + size, x:x + size]
        if crop.shape[0] != size or crop.shape[1] != size:
            self.previous = None
            return Track(len(faces), None, 0.0, "mouth outside frame")
        keep = crop_center()
        model = crop[keep:keep + MODEL_SIZE, keep:keep + MODEL_SIZE]
        motion = self._motion(model)
        self.previous = model
        return Track(len(faces), model, motion,
                     "multiple faces" if ambiguous else None)

    def _motion(self, model):
        """Return the mean absolute change against the previous patch."""
        if self.previous is None or getattr(self.previous, "shape", None) != model.shape:
            return 0.0
        np = self.numpy
        return float(np.abs(model.astype(np.float32)
                            - self.previous.astype(np.float32)).mean() / 255.0)


class Recognizer:
    """Run the ONNX recognizer on one utterance's mouth crops.

    The crops are kept in a bounded list and turned into one input
    tensor when the utterance ends, so the model runs once per sentence
    rather than once per frame.  ``run`` returns the dict
    :func:`decode_ctc` produces plus the time the model took.
    """

    def __init__(self, model_path, tokens, numpy=None, onnxruntime=None, threads=4):
        self.model_path = model_path
        self.tokens = tokens
        self.numpy = numpy
        self.ort = onnxruntime
        self.threads = threads
        self.session = None
        self.error = None

    def open(self):
        """Load the model, or return one line saying why not."""
        try:
            options = self.ort.SessionOptions()
            options.intra_op_num_threads = max(1, int(self.threads))
            options.inter_op_num_threads = 1
            self.session = self.ort.InferenceSession(
                self.model_path, options, providers=["CPUExecutionProvider"])
        except Exception as error:  # noqa: BLE001 - shown in Emacs
            self.error = "Lip-read model unavailable · %s" % error
            return self.error
        return None

    def __call__(self, crops):
        """Return the transcript of CROPS (one mouth patch per frame)."""
        np = self.numpy
        if not crops:
            return {"text": "", "confidence": 0.0, "low": 1.0, "pieces": [],
                    "seconds": 0.0}
        frames = np.stack([np.asarray(crop, dtype=np.float32) / 255.0
                           for crop in crops[:500]])
        frames = (frames - PIXEL_MEAN) / PIXEL_STD
        started = time.monotonic()
        log_probs = self.session.run(
            ["log_probs"], {"video": frames[None, None]})[0]
        seconds = time.monotonic() - started
        rows = log_probs.tolist()
        result = decode_ctc(rows, self.tokens)
        result["seconds"] = seconds
        return result


#; ------------------------------------------------------------------
#; What the camera is doing
#; ------------------------------------------------------------------

class CameraState:
    """The camera's own state, as the harness shows it.

    The states are the ones the sidecar reports in its ``camera`` event:
    ``closed`` before anything opened it, ``opening`` while the device
    starts, ``live`` while frames arrive, ``paused`` while the person
    paused reading (the device stays open), ``denied`` when the harness
    did not grant it, ``failed`` when it could not be opened or died,
    and ``ended`` once it was released.  ``faces`` and ``fps`` are facts
    measured on the last frames; they are nil when nothing measured
    them.
    """

    def __init__(self, state="closed", device=None, reason=None):
        self.state = state
        self.device = device
        self.reason = reason
        self.faces = None
        self.fps = None
        self.frames = 0
        self.since = time.monotonic()

    def set(self, state, reason=None):
        """Move to STATE, keeping the device and its measurements."""
        if state != self.state:
            self.state = state
            self.since = time.monotonic()
        self.reason = reason
        return self

    def measure(self, faces=None, fps=None):
        """Record the last frame's FACES and FPS."""
        if faces is not None:
            self.faces = faces
        if fps:
            self.fps = round(float(fps), 1)
        self.frames += 1
        return self

    def label(self):
        """Return the one-line words for this state, as Emacs shows them."""
        base = "Camera · %s" % self.state
        if self.state == "live":
            if self.faces is not None and self.faces == 0:
                return base + " · no face"
            if self.faces is not None and self.faces > 1:
                return base + " · %d faces" % self.faces
            if self.faces:
                return base + " · 1 face"
        if self.reason:
            return base + " · %s" % self.reason
        return base

    def fields(self, **extra):
        """Return the ``camera`` event's fields."""
        fields = {"state": self.state}
        if self.device is not None:
            fields["device"] = str(self.device)
        if self.faces is not None:
            fields["faces"] = self.faces
        if self.fps:
            fields["fps"] = self.fps
        if self.reason:
            fields["reason"] = self.reason
        fields.update(extra)
        return fields


#; ------------------------------------------------------------------
#; Self-test support: a scripted camera and recognizer
#; ------------------------------------------------------------------

class ScriptedCamera:
    """A camera that hands out scripted frames and records its lifecycle.

    ``calls`` is the lifecycle in order, so a test can hold the sidecar
    to releasing the device on stop, on error and on denial.  This is
    the fixture the repository's tests run; no device is opened.
    """

    def __init__(self, frames, error=None):
        self.frames = list(frames)
        self.error = error
        self.calls = []
        self.opened_flag = False
        self.fps = 25.0

    def open(self, cv2=None):
        self.calls.append("open")
        if self.error:
            return self.error
        self.opened_flag = True
        return None

    def read(self):
        if not self.opened_flag:
            return None
        if not self.frames:
            return None
        return self.frames.pop(0)

    def close(self):
        self.calls.append("close")
        self.opened_flag = False

    def opened(self):
        return self.opened_flag


class ScriptedTracker:
    """A mouth tracker that replays :class:`Track` values."""

    def __init__(self, tracks):
        self.tracks = list(tracks)
        self.error = None
        self.calls = 0
        self.cv2 = None

    def open(self):
        return None

    def __call__(self, frame):
        self.calls += 1
        if not self.tracks:
            return Track(0, None, 0.0, "no face")
        return self.tracks.pop(0)


class ScriptedRecognizer:
    """A recognizer that answers a scripted transcript per utterance."""

    def __init__(self, results=None, error=None):
        self.results = list(results or [])
        self.error = error
        self.utterances = []

    def open(self):
        return self.error

    def __call__(self, crops):
        self.utterances.append(len(crops))
        if self.results:
            return self.results.pop(0)
        return {"text": "add a docstring", "confidence": 0.97, "low": 0.0,
                "pieces": [], "seconds": 0.01}


def scripted_tracks(motions, faces=1, size=MODEL_SIZE, reason=None):
    """Return tracks whose mouth patches move with MOTIONS.

    A patch is a list of rows, so nothing here needs numpy: the sidecar
    and its tests treat a crop as an opaque value it stacks when the
    utterance ends.  ``reason`` marks every frame unusable, which is how
    the ambiguity of two faces is replayed without a camera.  The
    recognizer used with these is scripted too.
    """
    tracks = []
    for motion in motions:
        crop = None if (faces == 0 or reason) else [[0] * size for _ in range(size)]
        tracks.append(Track(faces, crop, float(motion),
                            reason or ("no face" if faces == 0 else None)))
    return tracks


def self_test_model_dir():
    """Return a temporary model directory with the right file names.

    The files are empty: the self-test replaces the runtime and the
    recognizer, and only checks that a complete directory is accepted
    and an incomplete one is named.
    """
    directory = tempfile.mkdtemp(prefix="harness-lipread-self-test-")
    for entry in MODEL_FILES:
        with open(os.path.join(directory, entry["name"]), "wb") as handle:
            handle.write(b"")
    return directory


def file_sha256(path):
    """Return the SHA-256 of PATH, reading it in blocks."""
    import hashlib
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify(model_dir, hashes=False):
    """Return the problems of MODEL_DIR, with HASHES to check every file.

    Without ``hashes`` this is the quick check the setup list and the
    sidecar run: the required files are there and are the right size.
    With it, each file's SHA-256 is compared with the published copy,
    which is what ``--check --hashes`` does after a download.
    """
    model = ModelFiles(model_dir)
    problems = []
    for entry in model.files:
        path = model.path(entry["name"])
        if not os.path.isfile(path):
            if entry["required"]:
                problems.append("Model unavailable · %s" % entry["name"])
            continue
        size = os.path.getsize(path)
        if size != entry["bytes"]:
            problems.append("Model size · %s · %d bytes" % (entry["name"], size))
            continue
        if hashes and file_sha256(path) != entry["sha256"]:
            problems.append("Model checksum · %s" % entry["name"])
    return problems


def default_model_dir():
    """Return the model directory the setup script installs into."""
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, DEFAULT_MODEL_SUBDIR)


#; ------------------------------------------------------------------
#; Downloading the model, once, on request
#; ------------------------------------------------------------------

#: The published locations of the model files.  The recognizer and the
#: vocabulary come from the int8 ONNX export of Auto-AVSR's LRS3 visual
#: model (research/non-commercial, because LRS3 is); the detector is
#: OpenCV's YuNet, Apache-2.0.
MODEL_URLS = {
    "lipread_ctc.int8.onnx":
        "https://huggingface.co/eschmechel/auto-avsr-lrs3-vsr-int8-onnx/resolve/main/lipread_ctc.int8.onnx",
    "tokens.json":
        "https://huggingface.co/eschmechel/auto-avsr-lrs3-vsr-int8-onnx/resolve/main/tokens.json",
    "face_detection_yunet_2023mar.onnx":
        "https://github.com/opencv/opencv_zoo/raw/main/models/"
        "face_detection_yunet/face_detection_yunet_2023mar.onnx",
}

#: The Python packages the runtime needs, and the versions the model was
#: validated with.
RUNTIME_PACKAGES = ("onnxruntime", "numpy", "opencv-python-headless")


def download(name, directory, opener=None):
    """Download model file NAME into DIRECTORY, atomically.

    ``opener`` is the function that fetches a URL to a path, so a test
    can stand in for the network.  The file lands under a temporary
    name and is renamed when complete, so an interrupted download never
    leaves a half model that looks installed.
    """
    opener = opener or _urlretrieve
    url = MODEL_URLS[name]
    os.makedirs(directory, exist_ok=True)
    target = os.path.join(directory, name)
    partial = target + ".part"
    try:
        opener(url, partial)
        os.replace(partial, target)
    finally:
        if os.path.exists(partial):
            os.unlink(partial)
    return target


def _urlretrieve(url, path):
    """Fetch URL into PATH, with the standard library."""
    import urllib.request
    request = urllib.request.Request(url, headers={"User-Agent": "harness-lipread-setup"})
    with urllib.request.urlopen(request, timeout=120) as response, open(path, "wb") as out:
        shutil.copyfileobj(response, out)
