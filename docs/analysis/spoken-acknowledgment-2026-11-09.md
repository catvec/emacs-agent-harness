# The spoken receipt of an accepted request: what it costs (2026-11-09)

**Question.**  A request that reaches a voice session is heard in silence
until the agent's first sentence.  The harness now plays one short receipt
for it ("On it").  Does that cost the request anything, and how long does
the receipt take to start?

**Short answer.**  No, and very little.  On this machine the request's own
`harness-ui-call-turn` returns in **0.55 ms p95** with the receipt installed
against **0.04 ms p95** without it; the receipt's player starts **4.1 ms
p95** after the request went out in Emacs's own path, and **22 ms p95** in
the shipped local sidecar, whose receipt is played on the next 20 ms tick.
A receipt that has no phrase generated yet is **silence** -- never a wait,
never a synthesis on the request's path.

## What was measured, and what was not

`scripts/analysis/bench-acknowledgment.sh` runs a batch Emacs on this
checkout and counts:

| Measure | What it is |
| --- | --- |
| **submission-to-player-start (warm)** | From the prompt's request going out to the receipt's player program having started and marked the time. |
| **dispatch** | How long `harness-ui-call-turn` takes to return: with the receipt's hook installed, with no hook, and with the hook and no phrase generated. |
| **cold** | Requests sent with no phrase generated: how long dispatch takes, whether a receipt played (it must not), and how long the background pass behind them took. |

The player is a shell script that `date +%s%N`s into a file and exits; the
speech command is a stand-in that writes a WAV immediately.  So these
numbers are the harness's scheduling and process handling, **not** a
speech model and **not** device audio.  The real remainder of "audible" --
an audio backend opening a device, the sound card's buffer -- is outside
this measurement; with PipeWire's `pw-play` that is tens of milliseconds on
a warm server, and it is the same cost every reply already pays.

No microphone, speaker, speech model or network was used, and none is
claimed.  The sandbox this ran in has no audio server (`pactl` and `pw-cli`
refuse the connection), so a real audible check could not be made here, and
none is claimed in the handoff.

`scripts/analysis/bench-acknowledgment-sidecar.sh` measures the other
half of the path, in the shipped sidecar: `scripts/harness-voice-live-unmute`
started exactly as Emacs starts it, a stub microphone speaking into its
gate, a stub speaker that logs each write and throws the audio away, and a
stand-in speech service answering with a tone instead of a model.  The
time is from the `acknowledge` event Emacs sends to the stub speaker's
first write for the receipt, both wall clock.  Run twice with 20 samples
each, on the same busy machine:

| Measure | p50 | p95 | max |
| --- | ---: | ---: | ---: |
| `acknowledge`-to-player-start, shipped sidecar, run 1 | 21.5 ms | 22.3 ms | 35.5 ms |
| `acknowledge`-to-player-start, shipped sidecar, run 2 | 21.1 ms | 21.7 ms | 38.0 ms |

The bank was generated 21-23 ms after `ready` in both runs, and **no
phrase was synthesized during a request**: three synthesis requests
before the first request and three by the end of the run.  20 requests,
20 receipts started.  The ~21 ms floor is the sidecar's 20 ms tick: the
receipt is played on the next tick, not from inside the event handler, so
that a reply that starts or a cancellation in between is seen before the
receipt is heard.  That delay is the design's price for never talking
over the answer, and it is 14 times inside the 300 ms budget.

## Environment

- GNU Emacs 31.1 (build 2, x86_64-pc-linux-gnu, GTK+ 3.24.52), x86_64 Linux.
- Load average 10.5-10.6 at the start of each run (a busy machine: other
  work ran beside these measurements, which is why the maxima are far
  above p95).
- Three separate runs of the Emacs benchmark, each with its own state
  directory under `scripts/.dev/bench-acknowledgment/`, 200 warm samples
  and 500 dispatch samples per run.
- Two separate runs of the sidecar benchmark, each in its own directory
  under `scripts/.dev/bench-acknowledgment-sidecar/`, 20 samples per run,
  a stub microphone, a stub speaker and a stand-in speech service.

## Results

| Measure | p50 | p95 | max |
| --- | ---: | ---: | ---: |
| submission-to-player-start (warm), run 1 | 3.79 ms | 4.16 ms | 29.55 ms |
| submission-to-player-start (warm), run 2 | 3.50 ms | 4.08 ms | 28.65 ms |
| submission-to-player-start (warm), run 3 | 3.78 ms | 4.16 ms | 26.69 ms |
| dispatch, receipt hook installed, run 1 | 0.38 ms | 0.55 ms | 24.59 ms |
| dispatch, no receipt hook, run 1 | 0.03 ms | 0.04 ms | 0.10 ms |
| dispatch, receipt hook installed, run 3 | 0.33 ms | 0.43 ms | 24.09 ms |
| dispatch, no receipt hook, run 3 | 0.03 ms | 0.04 ms | 0.10 ms |
| dispatch, phrase missing (cold), run 1 | 0.17 ms | 0.18 ms | 23.25 ms |
| dispatch, phrase missing (cold), run 3 | 0.17 ms | 0.20 ms | 21.97 ms |

**Cold path.**  With no phrase generated, a request is heard in silence and
the background pass fills the bank: 75 ms (run 1), 69 ms (run 2) and 58 ms
(run 3) after the last of 25 requests.  The requests themselves were sent
in 0.30, 0.20 and 0.20 ms p95, and **no receipt played** in any run.  The
first request after a cold start is the one that pays nothing: silence is
the fallback, exactly as the design says.

**What the receipt adds to sending a request.**  ~0.3-0.5 ms p95 of the
hook's own decisions and a zero-delay timer setup; the player is started
from that timer, after `harness-ui-call-turn` has returned, so the process
spawn is not in the request's path at all.  The maximums (24 ms) are one
`make-process` landing on a loaded machine, not a cost the request waits
for.

## The budget

**300 ms from the request going out to the receipt's player starting, on a
warm bank.**  It is justified by the gap it fills: the first token of a
real turn takes hundreds of milliseconds to seconds, so a receipt that
starts inside 300 ms still precedes it, and a receipt that would arrive
after the answer must not play at all -- which is enforced separately
(a reply that starts drops a receipt that has not started).  Measured p95
is 4.1 ms in Emacs's own path and 22 ms in the shipped sidecar's, two
orders of magnitude inside the budget, which is deliberate headroom for a
slower machine, a cold page cache and a real audio backend.  The sidecar's
floor is its 20 ms tick, spent so a reply or a cancellation that lands
between the request and the tick is seen before the receipt is heard.

## Cache misses and deadlines

- The bank is generated before a request is expected: the live sidecar's
  when the call starts, the WAV client's on the first accepted request.
- A request whose phrase does not exist plays **nothing**, and the pass is
  started for the next one.  There is no deadline to miss and no fallback
  to time out: the phrase is either a file that is there or it is silence.
- A phrase that cannot be generated at all (a stopped pipeline, a speech
  server with no audio) leaves that phrase out of the bank; the other
  phrases are still used and the pass still ends.  This was a real bug
  found by the benchmark's cold path: a failed phrase left the priming
  flag set and no later pass could fill the bank.  It is fixed, and
  `harness-ui-voice-acknowledgment-a-failed-phrase-does-not-stop-the-pass`
  holds it.

## What is *not* claimed

- No device or audio-backend timing.  The last leg to a speaker is not
  measured here.
- No speech model timing.  A real Kokoro synthesis of a two-word phrase is
  hundreds of milliseconds; it is paid once, in the background, and the
  benchmark's stand-in is not a model.
- The Python sidecar's own path (event handler to the player call) is
  measured in-process by `AcknowledgmentLatencyTest` in
  `test/harness-voice-gate-test.py`: **p50 0.005 ms, p95 0.013 ms over 20
  samples** on this machine, which is a bank lookup and a queue append, not
  audio.  That is the handler alone; the ~21 ms end-to-end figure above
  adds the tick the receipt waits for.
