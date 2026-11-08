# Live voice capture pacing

## The incident

The `unmute` provider ("Local pipeline") transcribed correctly only
sometimes. A person would speak, see a transcript, get a reply, speak
again, and the second transcript would be short or wrong rather than
empty: the speech service was being sent a burst with most of it
missing.

The report arrived after two earlier detector fixes (the noise floor and
the gate). Those explain silence from a quiet microphone; they do not
explain audio that reaches the speech service cut in half. This
investigation reproduced the symptom with a real sidecar process, fake
`pw-record`/`pw-play` programs that behave like a sound server, and
synthetic PCM. No microphone, model or network was used.

## What the reproduction shows

A sound server cannot block a real-time capture. When the application
stops reading the capture pipe, PipeWire or PulseAudio overruns its
buffer and drops the microphone; the app is then reading old audio and
missing the present. The fake `pw-record` does the same: it produces one
20 ms chunk every 20 ms and counts a chunk it cannot write as dropped.

Two properties of the sidecar made that happen:

1. **The capture read was tick-sized.** `tick()` asked the recorder for
   at most 320 samples (20 ms at 16 kHz) and the loop ticks about every
   20 ms. Python scheduling and the tick's own work make the loop a
   little slower than real time, so the pipe slowly filled. With the
   pipe full, the next chunks are dropped. Measured with a pipe
   prefilled with two seconds of voiced audio: 12 of 140 chunks dropped
   in 3.5 s, and the same test after the fix drops none.
2. **Playback blocked the loop.** `Player.play` wrote the whole PCM
   buffer into the player's pipe from `tick()`. The pipe holds about two
   seconds, so a longer reply blocked the sidecar's loop for the rest of
   the reply: no microphone read, no speech detector, no barge-in. A
   five-second synthesized reply dropped 53 of 280 capture chunks, and
   the person's next 1.2 s utterance reached the detector as a 1.54 s
   segment instead of the 2.32 s one it should have been.

A third, related defect surfaced in the same tests: `Player._start`
consumed the backend candidate list when it succeeded. After any
`stop()` -- a barge-in, mute or interrupt -- the next `play()` had no
candidate left and the assistant stayed mute for the rest of the
session. The player must keep the backend it started and restart it for
the next reply; only a failed start should advance the list.

## Decision

The capture loop must never be the thing that waits.

- **`Player` owns a writer thread.** `play()` enqueues PCM and returns;
  the writer feeds the player's pipe. The queue is bounded to 120 s of
  audio, and the oldest audio is dropped with a log line if a caller
  runs ahead. `stop()` clears the queue and kills the process;
  `close()` stops and joins the writer. The selected backend is kept
  across `stop()`, so the next reply starts it again. A start failure
  advances to the next backend and resets the list after it is
  exhausted, so a transient failure does not leave the session mute.
- **One capture read takes up to `CAPTURE_SECONDS` (0.2 s).** A tick is
  20 ms, so one read drains ten ticks of backlog instead of adding to
  it. The pipe is about two seconds long, which leaves ten times the
  margin for a late tick. Both live sidecars ask for
  `int(rate * CAPTURE_SECONDS)`.
- **A split sample is carried.** `Recorder.read` keeps a byte that ends
  a read in the middle of a PCM16 sample and prepends it to the next
  read. The old code dropped that byte in `tick()`, which would shift
  every later sample by one byte -- noise, not speech -- if a capture
  backend ever wrote an odd number of bytes.

## Alternatives considered

- **Read every available chunk in one tick, looped.** Equivalent to the
  larger read, but the recorder would need to distinguish "no data yet"
  from "end of the backlog" on every tick, and a fake recorder in a test
  is easier to reason about with one read. The larger bound has the same
  effect with less state.
- **A capture thread with a PCM queue.** The most robust shape: the
  reader never sleeps and the sidecar's loop only consumes frames.
  It adds a second queue, blocking and backpressure rules, and a wakeup
  protocol to a path that now has ten times the headroom it needs. The
  simpler read is measured to keep up; the thread remains the fallback
  if a real device proves otherwise.
- **Write playback in tick-sized pieces instead of a thread.** The loop
  would still spend time inside `write` whenever the player's pipe was
  full, and `stop()` would have to know how much was written. A writer
  that owns the pipe is simpler and makes interruption immediate.
- **Make the player pipe non-blocking and drop what does not fit.**
  Drops audible words on a slow player and reports nothing about why.
  The writer lets the pipe fill and drain at the player's own rate.
- **A bigger sound-server buffer.** It postpones the overrun and adds
  latency to every utterance; it does not make a loop that reads slower
  than real time keep up.

## Shape of the change

`scripts/harness_voice_sidecar.py`

- `CAPTURE_SECONDS = 0.2`, next to `LOCAL_RATE`/`GPT_RATE`.
- `Player`: a bounded deque, a writer thread, a wake event and
  `_closing`; `play` enqueues and updates the busy projection,
  `_write_loop` starts the backend and writes, `stop` clears, `close`
  stops and joins. `_start` keeps its successful candidate; `_candidate`
  advances on a failure and resets after the last one.
- `Recorder.read`: the docstring says FRAMES is a cap, not a wait; the
  read carries an odd trailing byte; `_carry` is reset when a backend
  starts, dies or closes.

`scripts/harness-voice-live-unmute`, `scripts/harness-voice-live-gpt`

- Both read `int(rate * CAPTURE_SECONDS)` per capture tick. The two
  sidecars share the player fix without a code change of their own.

`test/harness-voice-gate-test.py`

- Five regressions, each failing on the pre-change code and passing
  after it:
  `test_play_does_not_wait_for_a_slow_player`,
  `test_a_stopped_player_starts_again_for_the_next_reply`,
  `test_a_byte_between_reads_does_not_shift_the_stream`,
  `test_a_reply_does_not_stop_the_microphone`,
  `test_capture_keeps_up_when_the_pipe_is_full`.
- The existing player test waits for the writer's bytes instead of
  assuming `play` wrote them synchronously.

## What the user sees

Nothing changes in the interface. The microphone stays open while the
assistant speaks, so the next utterance is transcribed whole and a
person talking over a reply still takes the floor at the first word.
The pipeline's accepted-burst duration now matches what was said rather
than a fragment of it. An interrupted reply starts again for the next
answer instead of leaving the assistant silent for the rest of the
session.

## Testing

Deterministic, no microphone or speaker: fake programs on `PATH`, a
threaded fake speech service and the real sidecar process. The
pre-change measurements above are the failures printed by the new tests
(`play() waited 2.07s`, `playback did not restart after a stop`,
`53 of 280 capture chunks dropped`, `12 of 140`, and an odd first read).
The normal gate suite (57 tests), the voice ERT suites and the
repository's full test and lint runs are reported separately from these
focused checks.

## Risks and limits

- The task sandbox has no audio device and no PipeWire/PulseAudio graph.
  The fake capture is a model of a sound server's overrun, not a
  recording from the user's microphone. A live-device check remains
  manual.
- The writer queue is bounded, so a caller that enqueues more than two
  minutes of audio faster than real time loses the oldest audio. The
  local sidecar plays one synthesized piece at a time; GPT-Live streams
  near real time. Neither reaches the cap in normal use.
- `busy()` is a projection from the queued duration. If a player
  consumes slower than real time (a stalled service), the projection may
  end before the pipe drains; the queue still keeps it true until the
  last chunk is written.
- A writer thread per player is one more thread in the sidecar. It is a
  daemon, exits on `close`, and never touches the microphone.
