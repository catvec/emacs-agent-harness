# VAD noise-floor recovery after an utterance

## The incident

The local voice pipeline transcribed the first utterance of a session and
then stayed at `Listening` while later speech produced nothing. The user
also reported that a reply had been interrupted by speech and that the
next speech was never heard. A read-only investigation reproduced the
symptom with synthetic PCM, not with the user's microphone recording.

With the detector as it stood, this stream

```python
SpeechDetector().feed(voiced(2, amplitude=0.30)   # first utterance
                      + silence(2)                # digital silence
                      + voiced(2, amplitude=0.08))  # later, quieter speech
```

produced one `start` and one `end`: the first utterance but not the
second. After the first utterance the noise floor had been learned up to
`0.017097`, so the threshold was `0.042742` instead of the configured
`0.02`; the later utterance peaks at frame energies around `0.032` and
never crosses it. Feeding the missed speech then raised the floor again
to `0.020099` (threshold `0.050248`): the failure fed itself. A fresh
detector accepted the quieter fixture.

## The defect

`SpeechDetector.classify` decided `loud` with the current threshold and
then offered every frame that was not loud to `_learn_noise`. Two
consequences combined:

- The quiet edge frames of a speech envelope are below the threshold and
  not loud, but they are voice-shaped. They are part of the utterance, yet
  the estimator counted them as room noise.
- `_learn_noise` returned early on zero energy, so true digital silence
  never brought the estimate back down. Only a nonzero quieter frame could
  lower it, and an exponential weight of `0.02` per 10 ms frame made that
  recovery very slow.

A missed quieter utterance was therefore not just unheard: its
below-threshold, voice-shaped frames were learned as additional noise,
which made the next utterance harder still.

## Decision

The noise floor is a property of the room, not of the classifier's
current threshold. The estimator now learns only from frames that do not
look voiced, and it counts silence as a measurement:

- `classify` computes the zero-crossing and first-difference features
  once. A frame is `loud` when its energy is at or above the current
  threshold and it looks voiced. A frame that looks voiced but is below
  the threshold is a quiet or missed word, not noise, and does not update
  the floor.
- `_learn_noise` follows a quieter frame down at `0.1` per 10 ms frame and
  a louder one up at `0.02`. Zero energy is no longer a special case that
  returns early: digital silence decays the floor by 10% per frame, so a
  second of silence takes any learned value back to the configured base.
- Learning is frozen while the gate is open and while the player is
  audible. The microphone is then hearing the person or the assistant,
  not the room. This is what keeps speech envelope edges and speaker echo
  out of the estimate even if their features are ambiguous.
- The existing threshold formula is unchanged:
  `max(configured, noise * 2.5)`, raised above the player level while
  the assistant speaks. The configured default stays `0.02`. Nothing in
  onset hold, hangover, echo hold, pre-roll, speech gating or the utterance
  state machine changed.

The adaptation is deliberately kept, not disabled: steady non-voiced
background (a fan, a room, a hum) still raises the floor up to its `0.05`
cap, and the floor still protects the gate in a noisy room. It simply
cannot be raised by the very speech it failed to detect, and it recovers
when the noise stops.

## Alternatives considered

- **Disable noise adaptation.** Removes the feedback loop but also the
  reason the threshold exists: a fan or a TV would sit on the configured
  `0.02` and the gate would be less robust in a real room. The task
  explicitly rules this out.
- **Lower the global threshold.** Makes the quieter fixture pass at the
  cost of false onsets on background noise everywhere. It treats the
  symptom (the threshold is too high) instead of the cause (why it is
  too high), and the task rules it out too.
- **Learn only during hangover.** Would keep edges out in this fixture,
  but a missed utterance while the gate is closed would still be learned,
  and a long dictation would never learn its room.
- **Minimum-statistics noise tracking over a sliding window.** Recovers
  from silence and ignores louder speech, but it is a larger rewrite of a
  small, latency-sensitive detector, and it still has to decide whether a
  steady voice-shaped background is noise or a person. The chosen rule
  answers that with the voicing features the detector already trusts.
- **Special-case only zero energy.** Fixes digital-silence recovery but
  leaves envelope edges and missed speech poisoning the floor, which is
  the more common real-room path.

## Shape of the change

`scripts/harness_voice_sidecar.py`

- `SpeechDetector.noise_rise = 0.02`, `noise_decay = 0.1`: the per-frame
  tracking rates.
- `_learn_noise(energy)`: clamps to `[0, 0.05]`, initialises from the
  first measurement, and moves toward `energy` with the direction's rate.
  Zero energy decays instead of returning early.
- `classify(frame)`: computes the voicing decision once, uses it for both
  the loud decision and the learning guard, and learns only from
  non-voiced frames while the gate and the player are quiet.

`test/voice_fixtures.py`

- `mix(*parts)`: sums PCM fragments sample by sample, so a quiet
  utterance can be tested over room noise rather than before or after it.

`test/harness-voice-gate-test.py`

- Eight detector regressions and three sidecar regressions, listed under
  Testing.

`docs/voice-turn-taking.md`

- The local-pipeline bullet describes the floor and its recovery, and the
  deterministic-test list names the new cases.

## What the user sees

Nothing changes in the interface. The live status stays `Listening`; the
difference is that later, quieter speech now produces `Hearing`, a
`transcribing` event and a delegation after the first utterance, rather
than being silently absorbed into the noise floor. No new sidecar event,
stage or setting was added, so the separately coordinated voice UI work
does not need to render a detector stage.

## Testing

Deterministic synthetic audio only; no microphone, speaker, speech model
or network is used. The detector tests assert the exact event sequence,
the threshold and floor values, and the sidecar tests assert that two
utterances reach the fake STT in order.

- louder then quieter speech separated by digital silence: two starts
  and two ends, the second after 4 s;
- a missed quiet utterance does not raise the floor for the next one:
  only the next `start` appears and the floor stays at zero;
- repeated utterances at `0.30`, `0.08`, `0.25`, `0.06`, `0.30`: five
  starts and five ends;
- low-level room noise (`0.012` amplitude) mixed under a quiet utterance:
  one start and one end, threshold stays configured; four seconds of the
  same room noise alone: no event;
- the same decisions for chunk sizes `1`, `3`, `160`, `320`, `999`,
  `4096` and the whole stream;
- digital silence decays a floor raised by white noise back to the
  configured threshold;
- a hum and a click neither trigger nor leave a raised floor;
- assistant playback echo does not trigger or raise the floor, and a
  quieter voice after it is detected;
- end to end: `voiced(0.30)` then `voiced(0.08)` produce two STT requests
  and two delegations, `first words` then `second words`;
- end to end through the real sidecar process with fake `pw-record` and
  `pw-play` programs and a fake HTTP speech service: the same two
  utterances transcribe in order;
- end to end: echo during playback, white noise, hum and a click produce
  no `speech`, `transcribing` or `delegation` event and no
  `speech_active`.

Nine of the eleven new regression tests fail on the pre-change
implementation: seven detector tests and both two-utterance sidecar
tests. The low-level room-noise test and the noise/hum/echo preservation
test pass on both implementations, as guards should. The full suite,
`scripts/test.sh --status`, and `scripts/lint.sh` are run on the
committed tree; their results are reported separately from the focused
runs.

## Risks and limits

- This is a synthetic reproduction of a likely cause, not the user's
  recording. The incident could also involve microphone gain, a device
  change or the speech service; those are not tested here. A live-device
  check remains manual.
- Steady background that looks voiced (music, a TV) no longer raises the
  floor while it is below the threshold. If it later gets louder, it can
  produce an onset; a person talking over it can too. The gate is a
  turn-taking guard, not a speaker identification model.
- Echo still needs the player's level to be reported. The sidecar does
  that every capture tick; a caller that feeds echo without
  `set_playback` is outside this path.
- The floor cap of `0.05` and the `2.5` multiplier are unchanged, so a
  room loud enough to raise the floor still needs a voice above it; that
  is the existing tradeoff, documented in `docs/voice-turn-taking.md`.
