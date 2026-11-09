# The local voice gate's floor

## The incident

The `unmute` provider ("Local pipeline") appeared not to hear a person
at all: pressing Start left the pipeline line at `Level · 0%`, the meter
never rose above a brief 1–3%, and no transcript, delegation or reply
followed. The same session had frozen Emacs once, which is a separate
fault; this document is about the microphone that was never heard.

## What the capture actually held

`scripts/harness-voice-probe listen --seconds 10 --wav scripts/.dev/mic.wav`
recorded ten seconds of the same microphone through the same backend the
sidecar uses, while the person spoke (`probe · 78 chunks, 0 kept, 0
dropped`). The file is a real capture, not a fixture:

| measurement | value |
| --- | --- |
| peak sample | 0.031 (−30 dBFS) |
| 10 ms frame energy, median | 0.0002 |
| 10 ms frame energy, loudest | 0.0070 |
| learned room noise (chunk level) | 0.0015 |
| gate threshold | 0.02 |

Replayed through the sidecar's own filter, the recording kept nothing.
Pushed through speech to text anyway, whisper transcribed it as
"Hello, goodbye" without hesitation — at a quarter of that level it
still does. The words were there; the gate was not looking.

The same is true of clean speech from the bundled stack: Kokoro's reply
for the same phrase has a mean absolute level of **0.028**, only 1.4×
the old threshold. A gate set at 0.02 was one loud mouth away from
missing every microphone with its gain low, and a person cannot tell
that apart from a broken pipeline.

## What decides a frame

`SpeechDetector` reads 10 ms PCM16 frames. A frame is speech when its
energy is at or above the gate threshold, its zero-crossing rate is
voice-like, and its first difference shows change above a steady hum.
Three such frames (30 ms) open the gate.

The threshold was `max(0.02, noise × 2.5)`: an absolute floor twice as
high as a quiet interface's speech, with the room's learned noise floor
able to raise it further. The noise term is the part that adapts; the
absolute floor was the part that did not.

## The decision

`threshold` is a floor, not a level speech must reach:

```
threshold = max(threshold, noise × 2.5, playback × 1.8 while playing)
```

The default floor is **0.004**, the room's own noise still raises the
gate to 2.5× itself, and the echo margin while the assistant speaks is
unchanged. With the recorded microphone that is a threshold of 0.004
against speech frames of 0.007: the words open the gate, the room at
0.0015 does not. In a louder room the noise term dominates exactly as
before, so nothing gets more sensitive where it matters.

The Emacs option keeps its meaning and name, `harness-voice-unmute-threshold`,
with the new default and a docstring that says it is a floor. The
sidecar's `--threshold` and the probe's `listen`/`replay` follow it. A
user who has already set the option keeps their value, as a `defcustom`
requires.

## Alternatives

- **A gain or AGC stage before the detector.** It would raise speech and
  the room by the same factor, so the gate's job is unchanged; it only
  helps speech to text, which the measurement above shows does not need
  it. It also pumps, and a gain chosen on a silent room amplifies noise
  into the next gate decision.
- **Scaling the UI's `Level · N%`.** The number is the mean absolute
  level of a 100 ms chunk as a percentage of full scale — honest, if
  small, for a quiet interface. The gate works per 10 ms frame, where
  the same voice reads five to ten times higher; changing the display
  would hide the quantity the detector actually uses.
- **Advice: turn the interface's gain up.** True for this machine, and
  still worth saying, but it is not a fix: a pipeline that only works at
  one gain setting is a pipeline that reports "not working" the next
  time someone plugs a different microphone in. Both can be true — the
  gain should go up, and the gate should not depend on it.

## Verification

- `scripts/harness-voice-probe replay scripts/.dev/mic.wav --transcribe`
  with the default floor keeps one 1.65 s utterance and prints
  `Hello, goodbye`; with the old 0.02 it keeps none.
- The same recording driven through the whole sidecar in a real Emacs
  (the file standing in for the microphone) shows one accepted
  utterance, the transcript `You · Hello, goodbye`, the delegation, and
  the reply `Voice · Hello! I can hear you now.` spoken back.
- `test/harness-voice-gate-test.py`: a quiet room at 0.0015 and a voice
  whose frames sit near 0.006 open the gate and the room alone does not;
  a missed utterance below the floor does not teach the estimator to
  miss the next one; the sidecar's default is asserted.
- `harness-ui-voice-providers-test.el` asserts the provider command
  passes the new floor from the option.

## What this does not decide

The start-time freeze is still unreproduced: the same start path, event
stream and full speech round trip run in a development Emacs without it.
It needs the backtrace from the machine where it happens.
