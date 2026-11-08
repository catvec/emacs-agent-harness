# Audio capture for voice

Voice needs raw PCM16 mono at 16 kHz (local pipeline) or 24 kHz (GPT-Live),
both to stream into a sidecar and to write a WAV for push-to-talk dictation.
This page records how the harness gets that audio, why it stopped naming ALSA
programs, and what happens when the first choice is not installed.

## The problem

Every audio path named `arecord` and `aplay`, from `alsa-utils`. A desktop that
runs PipeWire with its PulseAudio compatibility — the default on current Arch,
Fedora and Ubuntu — records perfectly well through `pw-record` or `parec` and
may never have installed `alsa-utils` at all. There, voice would not start: the
live providers declared `(executable "arecord")` as a need, so the setup list
said `Executable unavailable · arecord`, and the sidecars defaulted to the same
two programs, so even a forced start died with
`microphone command unavailable · arecord`.

## Decision

One table of audio backends, newest interface first, used by both Emacs and the
sidecars:

| Backend id | Record | Play |
| --- | --- | --- |
| `pipewire` | `pw-record` | `pw-play` |
| `pulse` | `parec` | `paplay` |
| `alsa` | `arecord` | `aplay` |
| `ffmpeg` | `ffmpeg -f pulse` | `ffmpeg -f pulse` |

Emacs keeps the table in `harness-ui-media-audio-backends`; the sidecars keep
the same order and ids in `AUDIO_BACKENDS` in `scripts/harness_voice_sidecar.py`.
The ids are the vocabulary both sides speak: `--audio pipewire` on a sidecar
pins one.

Three rules follow from the table:

1. **Detection, not configuration.** The first backend whose programs are both
   installed is the default. Nothing has to be set on a normal desktop, and
   `M-x harness-customize` remains available for a recorder of your own.
2. **A pre-flight check that agrees with what runs.** The live providers declare
   `harness-voice--audio-need`, which asks the same table, so the setup list
   says `Microphone unavailable · pw-record, parec, arecord or ffmpeg` only
   when no backend could open a microphone at all — not when ALSA is absent.
3. **Failover at run time.** A recorder that exits, or that sends no sample for
   five seconds, is dropped and the next backend is tried. A sidecar that runs
   out of backends reports `microphone unavailable · …` to Emacs and ends the
   session instead of waiting on a stream that will never speak. Before this,
   a dead `arecord` left a session that looked started and heard nothing.

## Pacing: the capture loop must outrun the sound server

PipeWire and PulseAudio cannot block a real-time capture. When the
application stops reading the capture pipe, the server's buffer overruns
and the microphone audio is dropped; the app then reads old audio and
misses the present. Two rules keep the sidecars reading:

- **A capture read takes up to 0.2 s (`CAPTURE_SECONDS`), not one tick's
  worth.** The loop ticks about every 20 ms. A tick-sized read leaves no
  room for a late tick: the deficit accumulates, the pipe fills, and the
  server drops audio. Ten ticks of headroom drains the backlog instead.
  A byte that ends a read in the middle of a PCM16 sample is carried to
  the next read, so a split write cannot shift every later sample.
- **Playback writes on its own thread.** A synthesized reply can be many
  seconds long; the player's pipe holds about two. Writing it from the
  sidecar's loop blocked that loop -- and the microphone and speech
  detector with it -- for the rest of the reply. `Player.play` now
  queues the audio and returns; the writer feeds the pipe. `stop`
  clears the queue and kills the process at once, so barge-in is heard
  while the assistant is speaking, and the selected backend is kept for
  the next reply rather than consumed by the stop.

[Why the capture loop and the player were changed](design/live-voice-capture-pacing.md)
has the measurements, the alternatives and the tests.

## What was rejected

- **A recorder of our own** (a ctypes binding to libpipewire or libpulse, or an
  Emacs dynamic module). It would remove the dependency on CLI programs, but
  every desktop that has the libraries also ships the tools — `pw-record` is in
  the `pipewire` package, `parec` in `pulseaudio-utils` — so it would add
  untestable code (no audio device in CI, no session bus in a task sandbox) to
  cover a case that does not happen. The failure the user hits is a *wrong
  program name*, not a missing installation.
- **Emacs recording audio itself.** Emacs Lisp has no capture API; a module
  would be the previous point with a compile step.
- **`ffmpeg` for everything.** It works, but it costs a process start and a
  resampler where the platform's own tool is one `pw-record` away.
- **Documenting `alsa-utils` as a dependency.** It makes the default desktop
  install something it does not need, to satisfy a program name we chose.

## Shape of the change

`scripts/harness_voice_sidecar.py`

- `Backend` (name, label, capture argv, play argv, programs) and the ordered
  `AUDIO_BACKENDS` table, plus `audio_backends()` (installed, in order) and
  `audio_missing_reason()` (the one line naming what would fix it).
- `Recorder` and `Player` take a backend name or `auto`. The recorder reads its
  pipe with `select` so a dead or stalled program is noticed instead of
  blocking the sidecar's tick, and asks for up to `CAPTURE_SECONDS` (0.2 s)
  so one late tick cannot leave the pipe full; `Player` starts the next
  backend when a write breaks, writes on a thread of its own so a long reply
  never stops the capture loop, and keeps its backend across a `stop` so the
  next reply plays.
- `Recorder.exhausted()` tells a sidecar that nothing is left to try, so it can
  fail with a reason.
- `self_test_audio()` checks the table and the failover with fake programs, so
  `--self-test` still runs without a microphone (both sidecars call it).

`scripts/harness-voice-live-gpt`, `scripts/harness-voice-live-unmute`

- `--audio {auto,pipewire,pulse,alsa,ffmpeg}`, passed to the recorder and
  player.
- A recorder that runs out of backends during a session ends it with the
  recorder's reason.

`lisp/ui/harness-ui-media.el`

- `harness-ui-media-audio-backends`, `harness-ui-media-audio-backend` (per side
  or for both), `harness-ui-media-audio-programs`,
  `harness-ui-media-audio-missing`.
- The WAV recorder picks its command from the same table (`parec` writes WAV
  with `--file-format=wav`), and the player list gains `pw-play`.

`lisp/ui/harness-ui-voice-providers.el`, `lisp/ui/harness-ui-voice.el`

- The live providers need `harness-voice--audio-need` instead of two program
  names, and the setup list has an `Audio` line naming the backend that voice
  records and plays through (`Audio  PipeWire · pw-record, pw-play`), or what
  is missing.

## What the user sees

- `M-x harness-voice-setup`: `Audio  PipeWire · pw-record, pw-play`; no
  `arecord` complaint when only the PipeWire tools are installed.
- A provider that still cannot run says which side is missing:
  `Microphone unavailable · pw-record, parec, arecord or ffmpeg` or
  `Speaker unavailable · pw-play, paplay, aplay or ffmpeg`.
- The sidecar's `*harness-voice-live-errors*` buffer names the command it
  started (`capture · pw-record --rate 24000 --channels 1 --format s16 --raw -`)
  and the one it fell back from.

## Testing

- `lisp/ui/harness-ui-media-test.el`: the table, the per-side choice, the WAV
  recorder argv for each backend, the player order.
- `lisp/ui/harness-ui-voice-providers-test.el`: the needs reason per side, the
  exact setup-list copy with and without a backend, both sidecars' `--self-test`
  (which include the backend table and a failover through real subprocesses).
- `test/harness-voice-gate-test.py`: the recorder's failover from a dead
  `pw-record` to a working `parec`, the recorder carrying a split sample,
  the player writing through a backend, returning before a slow player
  consumes a reply, and restarting after a stop, capture keeping up with
  a full pipe, a reply not stopping the microphone, and the real
  `harness-voice-live-unmute` process running the whole loop -- capture,
  detector, speech to text, delegation, text to speech, playback --
  against fake `pw-record`/`pw-play` and a fake speech service.

A task sandbox has no audio device and no working PipeWire graph, so the live
microphone and speaker are the one thing these tests do not claim; the user's
desktop is where that is checked.
