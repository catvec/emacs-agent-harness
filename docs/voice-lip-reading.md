# Webcam lip reading as a voice backend

The `lipread` voice provider reads lips from a webcam with a local
model and puts the words into the ordinary live-voice session. It is
**silent visual speech recognition**, not audio-assisted: there is no
microphone in this path, and the model sees only the mouth.

This page is the research record and the operating notes. The design,
the alternatives and the rejected paths are in
[the design document](design/webcam-lip-reading-voice.md).

**Read this first.** The weights are **research and non-commercial use
only**, because the model was trained on LRS3 (BBC/TED broadcast
video). Accuracy is far below audio speech recognition: on the benchmark
the model reads about a third of the words wrong on average, and about
1 in 10 in the readings the provider accepts as certain. It is usable
for dictating a short request when the words are in its vocabulary and
the camera sees a well-lit, near-frontal face; it is not a substitute
for a microphone.

## What was researched

Candidates were compared on whether a **local, released checkpoint**
exists, what it needs as input, and whether its licence lets a person
run it. Only primary sources are cited: the project's own repository,
the dataset's own licence page, the model card and the paper.

| Candidate | Checkpoint available | Input | Language | Code licence | Weight licence | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **Auto-AVSR** (`mpc001/auto_avsr`, [repo](https://github.com/mpc001/auto_avsr)) | Yes: `vsr_trlrs2lrs3vox2avsp_base.pth` (250 M parameters, 20.3% WER on LRS3), `vsr_trlrs3vox2_base.pth` (24.6%), `vsr_trlrs3_base.pth` (36.0%). LRS3 was 438 h of video | 25 fps face video, aligned on four points, 96x96 mouth crop centre-cropped to 88x88 grayscale | English (LRS3) | Apache-2.0 | Trained on LRS3, BBC/TED; the repo says the models "may have their own licenses or terms and conditions derived from the dataset used for training". LRS3's own terms are research-only | **Chosen** |
| **AV-HuBERT** (`facebookresearch/av_hubert`) | Yes, but the repository is archived (September 2024) and the setup wants Python 3.8 plus an old Fairseq | Same 96x96 mouth crops, 25 fps | English | Custom Meta licence: **non-commercial research only**, and it forbids surveillance and biometric processing | Same | Rejected: stricter licence, archived, heavier toolchain, no accuracy advantage |
| **VALLR** ([arXiv 2503.21408](https://arxiv.org/abs/2503.21408)) | **No released visual checkpoint**: the paper reports 18.7% WER on LRS3 but publishes no model | Phoneme CTC then an LLM | English | — | — | Rejected: nothing to run locally |
| **Visual_Speech_Recognition_for_Multiple_Languages** (`mpc001/...`) | Yes, including multilingual models (LRS2, CMLR, GRID, TCD-TIMIT, CMU-MOSEAS) | Same crops | Several | Apache-2.0 | Dataset terms per model | Viable alternative, not chosen: the multilingual set has no single sentence-level model better than LRS3 Auto-AVSR, and the English path is the same architecture |
| **Chaplin** (`amanvirparhar/chaplin`, MIT) | Wraps Auto-AVSR's LRS3 model, with an LLM correction step through Ollama | Same crops, webcam | English | MIT | Inherits Auto-AVSR/LRS3 | Reference for the whole-loop shape (webcam, hold a key, type the words); its LLM correction step is not part of this provider |
| **Third-party int8 ONNX export** (`eschmechel/auto-avsr-lrs3-vsr-int8-onnx`) | Yes: 203 MB, encoder + CTC head, int8 | float32 `[1,1,T,88,88]`, T ≤ 500 (20 s) | English | — | "lrs3-research-non-commercial", declared by the exporter | **Used as the runtime format**: identical tokens to `auto_avsr`'s own SentencePiece file (verified below), so it is Auto-AVSR's checkpoint in a CPU-friendly container |

Generic image captioning was rejected outright: it describes a scene, it
does not transcribe speech, and its confidence says nothing about what
was said. No cloud inference is used anywhere in this path.

### What this project verified itself

* The ONNX export's vocabulary is **exactly** Auto-AVSR's: 5049 pieces,
  identical list to `spm/unigram/unigram5000_units.txt` plus
  `<blank>`/`<eos>`, checked element by element.
* The published SHA-256 of the export matches the downloaded file
  (`da02d72e…f195b`), and the same for the YuNet detector.
* The crop geometry in `harness_voice_lipread.py` is Auto-AVSR's own
  `20words_mean_face.npy` mean-face points, with the same 96 → 88 centre
  crop and the same `(x/255 − 0.421)/0.165` normalization.

## The model, installed

| | |
| --- | --- |
| Model | Auto-AVSR LRS3 visual-only recognizer, encoder + CTC head, int8 ONNX |
| Files | `lipread_ctc.int8.onnx` (203 MB), `tokens.json` (78 KB), `face_detection_yunet_2023mar.onnx` (232 KB) |
| Install | `scripts/harness-voice-lipread-setup --model --runtime`, into `$XDG_DATA_HOME/harness/lipread` |
| Runtime | Python 3, `onnxruntime`, `numpy`, `opencv-python-headless` (CPU only) |
| Memory | about 400 MB resident after the model loads; a 6 s utterance peaks near 4 GB of address space while the session runs |
| Speed on this machine | 0.20–0.25 s per ~2.5 s utterance (16-core CPU, `intra_op_num_threads=4`), i.e. real-time factor ≈ 0.10; 0.83 s for a 7.1 s clip |
| Language | English, LRS3 broadcast vocabulary (SentencePiece unigram, 5000 pieces) |
| Input | 25 fps, 88x88 grayscale mouth crops aligned on the mean face |
| Video | `/dev/videoN` (or any OpenCV source), via `opencv-python-headless` |

The setup script prints the licence before it downloads anything:

```
Model · Auto-AVSR LRS3 visual-only · int8 ONNX export · English
Code · Apache-2.0 (mpc001/auto_avsr, Copyright Imperial College London)
Weights · LRS3 dataset terms · research and non-commercial use only
Export · community int8 export by eschmechel/auto-avsr-lrs3-vsr-int8-onnx
Detector · OpenCV YuNet · Apache-2.0
Voice output · the harness's own local speech stack, or none
```

## Measured accuracy

Two measurements were run locally with the installed checkpoint, the
provider's own preprocessing and the provider's own decoder. They are
**not** a claim about webcams or about silent mouthing; see the
limitations at the end.

### 1. The benchmark, greedy CTC

On the first 100 clips of the LRS3 test set (pre-cropped mouth patches,
`mattymchen/lrs3-test`), greedy decode, no language model:

| | |
| --- | --- |
| Mean WER | **33.9%** |
| Median WER | 25.0% |
| Best / worst clip | 0% / 100% |
| Inference | 26.5 s for 253 s of video (RTF 0.105) |

The checkpoint's own model card reports 28.5% on the same kind of
greedy decode, and 19.1% with beam search plus an RNN language model —
this provider runs the former. The difference from 28.5% is the model
card's evaluation on a different subset and its own crop pipeline.

### 2. Confidence separates the good readings from the bad

The provider reports the model's mean top-1 probability with every
transcript, and uses it to decide what to show and what to send. The
same 100 clips, split by that number:

| Mean top-1 probability | Clips kept | WER of the kept ones | WER of the rest |
| --- | --- | --- | --- |
| ≥ 0.95 | 13 / 100 | 2.4% | 38.6% |
| ≥ 0.90 | 30 / 100 | 6.6% | 45.7% |
| ≥ 0.85 | 45 / 100 | 10.7% | 52.9% |
| ≥ 0.80 | 55 / 100 | 13.9% | 58.4% |
| all | 100 | 33.9% | — |

So the bands are not arbitrary. `sure` is the ≥ 0.90 band, where the
measured WER is under 10%; `likely` is ≥ 0.85, under 15%; anything
between the floor (0.80) and 0.85 is `unsure` and is never sent; a
reading below 0.80 is not shown as speech at all. The provider accepts
about half of the benchmark readings, and what it accepts is about
three times better than the model's overall average.

## How the provider behaves

* **Camera permission is explicit and per session.** Starting the
  provider asks `Camera · this session?`; declining is a user error with
  no process and no device. The grant is never saved, and it is dropped
  when the session ends, fails, is reloaded or killed. The sidecar opens
  no device without `--camera-consent`, which Emacs passes only for a
  granted session.
* **The camera is visible.** The controls show `Camera · live · 1 face`,
  `Camera · live · no face`, `Camera · live · 2 faces`, `Camera ·
  paused`, `Camera · denied`, `Camera · failed`; the setup list has a
  `Camera` line with the device and a `[Grant]`/`[Revoke]` control.
* **The pipeline is a camera's.** The strip under the transcript and the
  compact line under the compose box read `Camera · live`, `Motion ·
  56%` (the mouth's movement, where a microphone reports a level) and
  `Mouth · moving` (its gate). No word of a camera session says `Mic`,
  `Microphone`, `Level` or `Speech`; a microphone provider's pipeline is
  unchanged.
* **The device is released** on stop, on pause (the device closes while
  paused, and `[Pause C-c v]`/`[Resume C-c v]` is the control, never
  `Mute`), on any failure, when frames stop arriving, and when Emacs'
  pipe closes. The sidecar's self-test holds it to each of those.
* **Frames stay local.** They are cropped in memory and dropped when the
  utterance ends; nothing is written to disk, nothing is uploaded, and
  the sidecar contains no URL and no file write. Only text crosses the
  pipe to Emacs.
* **An uncertain reading is not speech.** An `unsure` reading appears in
  the transcript as `Uncertain · … · not sent`, is not added to the
  voice conversation, and never becomes a request. A reading below the
  floor becomes a notice (`Lip reading · low confidence · not sent`).
* **Unusable frames are dropped, not guessed.** No face, or two faces of
  comparable size, marks an utterance unusable; more than 20% unusable
  frames drop it with `Lip reading · unusable frames · not sent`.
  A face that is missing for two seconds says `Camera · no face` once.
* **Missing pieces are named.** A missing model file is `Model
  unavailable · lipread_ctc.int8.onnx` in the setup list and refuses the
  start before the camera; a missing Python runtime is `Runtime
  unavailable · …`; a camera that will not open is `Camera unavailable
  · …`.
* **Replies** are spoken only when the harness's local speech pipeline
  is running (its Kokoro endpoint); otherwise the provider is
  caption-only. No hosted voice is used.

## Trying it without a camera

A recording replays through the same path at 25 fps, which is how the
pipeline was tried and how the screenshot in this document was taken:

```elisp
(setq harness-voice-lipread-model-dir "~/.local/share/harness/lipread")
(setq harness-voice-lipread-source "/path/to/a/face/video.mp4")
(setq harness-voice-provider 'lipread)
```

A file source needs no camera grant; the person chose the recording.
The sidecar reports it as `Camera · live · 1 face` with the file's
name as the device, because the camera state is about what frames are
arriving, not about which driver produced them.  The same thing from a
shell:

```sh
scripts/harness-voice-live-lipread --model-dir ~/.local/share/harness/lipread \
    --source face.mp4 --camera-consent --check
```

## What is not verified

Honest limits of this work, in order of importance:

1. **No real webcam was used.** This machine has no `/dev/video*` and the
   task forbade activating a camera. The end-to-end path was run with a
   **real face video file** (a 256x256 clip of a speaker, 178 frames at
   25 fps) through the real face detector, the real crop, the real model
   and the real sidecar; and with scripted frames for every lifecycle
   and failure case. A real camera's frame rate, exposure, colour and
   driver behaviour are untested.
2. **No live mouth motion was tested against a person.** The motion gate
   is calibrated on LRS3 mouth patches (0.013–0.087 mean per-frame
   change). A webcam's noise, a person sitting further away, or a
   jittery auto-exposure may need `harness-voice-lipread-motion-floor`
   or `--motion-floor` adjusted; the gate follows the still frames it
   sees, but that is a heuristic, not a measurement on your camera.
3. **Silent mouthing is harder than the benchmark.** Public VSR models
   are trained on *voiced* speech with the audio dropped, and silent
   articulation looks different. Independent measurements report WER
   rising from 20.3% (voiced, benchmark) to 73.6% on silent clips of the
   same sentences. Expect the provider to be much worse than the table
   above when you mouth words without speaking. No released checkpoint
   was found that is trained for silent articulation with terms usable
   here.
4. **English, broadcast vocabulary.** Names, code identifiers, paths and
   non-English speech read badly. The provider does not correct its text
   with a language model; an LLM correction step (as Chaplin does
   locally through Ollama) would be a separate, optional feature, and
   would still be a guess dressed as text.
5. **Latency is from the utterance end, not streaming.** The model runs
   once when an utterance ends: about 0.2–0.3 s for a 2.5 s sentence on
   this CPU, plus the end-of-speech hangover (0.32 s). There is no
   partial transcript while the person is still mouthing.
6. **Memory.** A session's peak address space is close to 4 GB (resident
   about 400 MB after load, growing with each run); a small machine
   should be tried before relying on it.
