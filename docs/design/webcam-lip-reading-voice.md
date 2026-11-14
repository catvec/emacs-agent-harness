# Webcam lip reading as a live voice provider

Live voice had two kinds of input: a completed WAV recording, or a
microphone a sidecar keeps open. This adds a third: **a camera**. A
person mouths a request, a local model reads it from the mouth, and the
words enter the same session, with the same permissions, the same tools
and the same transcript as speech.

The research, the checkpoint and the measured numbers are in
[voice-lip-reading.md](../voice-lip-reading.md). This document is about
the decisions: what is a provider, where the camera permission lives,
how an uncertain reading is prevented from becoming an instruction, and
why the alternatives were rejected.

## The problem

The request was explicit about several things, and each is a decision:

* **Not assumed feasible.** Real-time webcam lip reading is not a solved
  problem. The first job was to find out whether a credible local
  checkpoint exists at all, and to say plainly what it can and cannot do.
* **Visual speech, not audio-assisted.** The model must read the mouth
  alone. A path that quietly requires a microphone, or a cloud model, is
  not the feature. Audio-assisted recognition is a different (much
  easier) feature and is not implemented.
* **No placeholder marketed as finished.** The chosen path runs a real
  checkpoint over real crops; the limits are measured, not guessed.

## Findings that shaped the design

1. **A credible local checkpoint exists**, but only as an int8 ONNX
   export of Auto-AVSR's LRS3 model. Its weights are research and
   non-commercial only (LRS3 terms). The alternative, AV-HuBERT, has a
   stricter licence (Meta's research-only agreement, which explicitly
   forbids biometric processing) and an archived toolchain. VALLR
   publishes no checkpoint. So the licence must be *shown*, at install
   time and in the docs, and the provider must be opt-in.
2. **The model is a sentence recogniser, not a streaming decoder.** It
   takes a fixed 25 fps sequence of 88x88 mouth crops and returns one
   transcript. There is no partial output. So the architecture is a
   *segmenting* one: decide where an utterance starts and ends, run the
   model once, then treat the transcript like a microphone transcript.
3. **No audio means no audio gate and no audio confidence.** The voice
   gate and the confidence of the microphone path (`Vad`, the speech
   server's logits) do not apply. New measures are needed for both:
   mouth motion for segmentation, and the model's own top-1 probability
   for certainty.
4. **The certainty is good enough to act on.** Measured on 100 LRS3
   clips: readings with mean top-1 ≥ 0.90 have 6.6% WER, and readings
   below 0.80 have 58.4%. A confidence band is therefore a real signal,
   not decoration, and it is what keeps uncertain text from being
   presented as speech.
5. **`delegation` and `user_delta` already carry free-form text** into
   the session, so the integration point exists. What is missing is a
   way to say *how sure*, and a way to show the camera.

## Decision: a provider, not a fork of the loop

`lipread` is registered with `harness-define-voice-provider`, capability
`live`, like `chatgpt`, `unmute` and `fixture`. Its sidecar speaks the
same JSON-lines protocol, so the chat, the tools, the permission panels,
the held-output rules and the voice conversation are untouched. That is
the repository's existing architecture, and it is the reason the change
is small.

```text
camera -> face/mouth crop -> local ONNX model -> transcript + certainty
                                              -> delegation (sure/likely only)
                                              -> caption (unsure, marked)
```

### What the protocol gained

Three additions, all additive, none of which any existing provider sends:

| Event / field | Meaning |
| --- | --- |
| `camera` event, `state` ∈ `closed opening live paused denied failed ended`, with `device`, `faces`, `fps`, `reason` | The camera's own state, so an active camera is never invisible and a face that is not in view is said rather than guessed |
| `certainty` on `user_delta` | `sure`, `likely` or `unsure`; the caption says `You · likely` or `Uncertain · … · not sent` |
| `certainty` on `delegation` | Carried from the sidecar to the session message through `Sidecar.delegation(..., certainty=)`, so a hedged reading is never treated as certain speech |

Provider records also gained `:prepare`, `:stopped` and `:camera`:
`prepare` runs before a session starts and may refuse it (a user error
with no process and no device), `stopped` runs however a session ends
(so a permission cannot outlive it), and `camera` marks a provider whose
controls show a camera.

## Decision: the camera permission is per session, not a setting

There is no `harness-voice-lipread-camera-enabled` boolean that is saved
and forgotten. A persistent permission is the same hazard as a
persistent microphone: the next session, a reload or a script could
open a camera the person never granted for that session.

* `harness-voice-lipread--prepare` asks `Camera · this session?` each
  time a session starts, and holds the answer in
  `harness-voice-lipread--granted`, an ordinary variable, never a
  customizable one and never written anywhere.
* The grant is turned into `--camera-consent` in the sidecar's argv, so
  a sidecar started by anything else (a terminal, a test, another
  session) opens no device at all. The self-test proves the
  no-consent path never calls `open`.
* `harness-voice-lipread--stopped` runs from the transport's single
  ending path (`--dispose`, and `--reset` when no process is left), so
  the grant is dropped on stop, on failure, on a closed pipe, on a
  reload, on a redaction and on a killed buffer.
* The setup page shows `Camera · off`, `Camera · granted`
  or `Camera · live · 1 face`, with `[Grant]` and `[Revoke]`.
  `[Revoke]` also ends a running session.

Rejected: a `defcustom` for the camera (survives restarts and is a
directory-local risk), a system-level permission check (the task forbids
changing persistent camera permissions, and the harness has no business
editing them), and "ask on first start only" (one grant silently
covering every later session).

## Decision: an uncertain reading is not a request

Three bands and a floor, all from the measured table:

| Band | Rule | Behaviour |
| --- | --- | --- |
| `sure` | mean top-1 ≥ 0.90 | Caption `You`, delegated |
| `likely` | 0.85 ≤ mean < 0.90 | Caption `You · likely`, delegated, `certainty` carried |
| `unsure` | floor ≤ mean < 0.85 | Caption `Uncertain · … · not sent`, **not delegated**, not in the voice conversation |
| rejected | mean < 0.80 (configurable) | Notice `Lip reading · low confidence · not sent`, nothing shown as speech |

The session never sees an unsure reading as a request, so a wrong
reading cannot become an instruction — the difference between "the model
guessed *delete the branch*" and a prompt. A `likely` reading does cross
into the session, because refusing all but the top band would discard
about 80% of usable sentences; it is *marked*, in the transcript and in
the delegation.

Also rejected: silently dropping everything uncertain (hides what the
model thought the person said, which is useful when it is nearly right),
and showing it as ordinary speech (exactly the failure the request
warns about).

## Decision: segmentation from mouth motion

No audio means no energy gate. `MouthMotion` measures the mean absolute
change of the aligned mouth patch between frames and opens an utterance
when it stays above a gate for three frames, closing it after 0.32 s
below. The gate is twice the minimum of the last 50 frames, never below
`0.004`, so a noisy camera raises its own gate and a person further away
is not penalised for it.

Measured on LRS3 patches, a speaking mouth moves 0.013–0.087 per frame,
so the floor sits under real speech and over sensor noise. This is a
heuristic: it is calibrated for a near-frontal, reasonably lit face, and
`harness-voice-lipread-motion-floor` exposes it. The limitation is
stated in the docs rather than hidden.

Rejected: fixed-length chunks (cuts words at arbitrary points, and runs
the model on silence), and a face-landmark openness measure (needs a
second model and is less stable than the patch difference across the
whole mouth).

## Decision: what a bad frame does

| Situation | Behaviour |
| --- | --- |
| No face | The frame is unusable; two seconds of it say `Camera · no face` once; the utterance is dropped if more than 20% of it is unusable |
| Two comparable faces | Marked ambiguous, the frame is unusable: the harness never silently picks a bystander |
| A tiny or partly out-of-frame mouth | Unusable frame |
| A model failure on one utterance | `Lip reading failed · …` notice, the camera and the session go on |
| The camera dies | `Camera unavailable · no frames`, then the sidecar fails and releases the device |
| A model file is missing | `Model unavailable · <file>` before the device is touched |

The two-face rule is a privacy decision as much as an accuracy one:
reading the wrong person's lips is exactly the failure a camera in a
shared room invites.

## Decision: a camera's pipeline is not a microphone's

The pipeline strip (`lisp/ui/harness-ui-voice-pipeline.el`) was
written for a microphone: it said `Mic · live`, `Level · 56%`,
`Speech · heard`, and its control closed the microphone, `Mute`.
A camera provider that reused it unchanged told the person, in the
transcript and under the compose box, that a microphone it does not
have was open, and that speech it cannot hear had been heard.

The pipeline therefore carries the input it describes, `mic' or
`camera', set from the provider's own `:camera' flag at session
start. The same facts keep their own nouns:

| Fact | Microphone | Camera |
| --- | --- | --- |
| capture | `Mic · live` | `Camera · live` |
| measurement | `Level · 56%` | `Motion · 56%` |
| gate | `Speech · heard` | `Mouth · moving` |
| closed capture | `Mic · muted` | `Camera · paused` |
| control | `[Mute C-c v]` / `[Unmute C-c v]` | `[Pause C-c v]` / `[Resume C-c v]` |
| Input tooltip | `Microphone level before the speech filter` | `Mouth motion before the speech gate` |

The live capture was checked in the running harness and the screenshots it
left are `docs/media/voice-lipread-setup.png` (the setup list) and the strip
drawn above. The transcript screenshot taken before this change was
removed rather than shipped: it showed `Mic · live` for a camera session,
the very copy this fixes, and no display was reachable to retake it.

A closed camera is *paused*, not muted: there is no microphone to
mute, and the device is closed. The default input is `mic', so every
existing provider, its tests and its copy are unchanged; only the
camera's words differ, and the camera provider's tests assert them
exactly.

Rejected: leaving the microphone's words on a camera session (it
says something false), and a separate camera pipeline (two copies of
the same state machine, free to disagree).

## Decision: frames never leave the process

The camera, the detector and the model live in the sidecar (Python,
OpenCV, onnxruntime). Frames are cropped in memory and dropped when the
utterance ends. The sidecar contains no URL, no file write and no
download; a regression test asserts the source holds no `imwrite`,
no `urlopen` and no model URL. Only text crosses the pipe to Emacs, as
for any sidecar.

The model is installed by `scripts/harness-voice-lipread-setup`, which
prints the licence, downloads into `$XDG_DATA_HOME/harness/lipread`
atomically, and checks each file's SHA-256. Nothing is fetched at
session start, and the provider's `:needs` names a missing file.

## Shape of the change

```
scripts/harness_voice_lipread.py          the gate, the decoder, the crop,
                                          the camera, the model directory
scripts/harness-voice-live-lipread        the sidecar, on the shared protocol
scripts/harness-voice-lipread-setup       the one installer, with the licence
lisp/ui/harness-ui-voice-lipread.el       the provider, the grant, the copy
lisp/ui/harness-ui-voice-live.el          prepare/stopped hooks, the camera
                                          event, uncertain captions, the
                                          camera's Pause/Resume control
lisp/ui/harness-ui-voice-pipeline.el     the input a pipeline describes:
                                          a camera's words, not a mic's
lisp/ui/harness-ui-voice-providers.el     :prepare, :stopped, :camera; the
                                          setup list's camera line
scripts/harness_voice_sidecar.py          `delegation(..., certainty=)`
test/harness-voice-lipread-test.py        47 tests: gate, decoder, geometry,
                                          model files, lifecycle, privacy
test/harness-voice-lipread-test.el        20 ERT tests: registry, command,
                                          exact copy, captions, hooks
docs/voice-lip-reading.md                 the research and the measurements
```

## What would be built next

1. **A real-camera pass.** No camera exists on this machine, so the
   frame path was exercised with a face video and scripted frames only.
   The motion floor and the face thresholds need a person in front of a
   real webcam before they can be called calibrated.
2. **A silent-articulation model.** The released checkpoints are trained
   on voiced speech, and silent mouthing is measurably much worse. A
   model trained for it, with usable terms, is the single biggest
   improvement available.
3. **Streaming decode.** The model is sentence-level. A streaming
   visual encoder (the torchaudio real-time AV-ASR recipe) could cut the
   wait from 0.2–0.3 s plus the hangover.
4. **An optional local correction step.** A local LLM (Ollama, as
   Chaplin does) can repair obviously wrong words. It would have to keep
   the certainty marking: a corrected guess is still a guess.
