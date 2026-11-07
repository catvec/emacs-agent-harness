# How realtime voice stays in the conversation

Research and design note, November 2026, updated for the live provider. This
note explains why ChatGPT Voice feels continuous, what a comparable mode
requires, and the sidecar contract now implemented in `ui-voice`. The default
WAV provider keeps dictation push-to-talk, transcription editable and replies a
separate text-to-speech step; the live provider adds continuous audio only
through a sidecar. The bundled sidecar is scripted: no speech model, network
connection or key is included.

The short answer: ChatGPT's current **Live** voice is not a text model with an
extra "listening" token. It is a full-duplex speech-to-speech model, GPT-Live,
which listens and speaks at the same time and delegates reasoning and tools to
a separate backend. The backchannels ("mhmm", "yeah") are generated speech
under a prompt policy. The closest real control token is
`<|SpawnThinking|>`, and it requests **backend work**, not listening.

## Three generations of ChatGPT voice

| Generation | Shape | What it feels like | Why |
| --- | --- | --- | --- |
| **Standard** | Speech-to-text → text LLM → text-to-speech | A turn-by-turn question and answer | Each stage waits for the previous one; audio is lost at the text boundary |
| **Advanced** | One speech-to-speech model, but discrete turns | Smoother, still a rigid back-and-forth | A turn detector must decide when the user has stopped before the model may answer |
| **Live** | Full-duplex speech-to-speech model plus a delegated backend | Continuous conversation, overlap, backchannels, interruptions | The voice model consumes and produces audio continuously; deeper work runs asynchronously |

OpenAI describes the first shape as a chain of three models that made responses
"slow and stilted", and the second as a speech-to-speech model that still had
to wait for the user to stop speaking. It attributes false endpoints to
silence-based turn detection: a brief pause or background noise could be taken
for the end of a turn. GPT-Live instead makes "interaction decisions many times
per second: whether to speak, continue listening, pause, interrupt, or invoke a
tool." See [Introducing
GPT-Live](https://openai.com/index/introducing-gpt-live/).

The ChatGPT help center now lists three choices under **Settings > Voice**:

- **Live**, powered by GPT-Live-1.1 (or GPT-Live-1.1 Quip on some plans);
- **Advanced**, the previous real-time experience, still used where mobile video
  or screen sharing is required;
- **Standard**, the turn-by-turn experience that transcribes first.

It also states plainly that Live "can listen and speak at the same time", so a
user can interrupt or keep speaking while ChatGPT responds. See [ChatGPT
Voice](https://help.openai.com/en/articles/20001274-chatgpt-voice).

### The turn detector is gone from the audio path

OpenAI's engineering account is unusually direct: GPT-Live "removes the turn
detector from the audio path." Earlier systems used a small detector to guess
whether the user had finished; guessing too early cut the user off, guessing
too late felt sluggish. GPT-Live streams audio into a stateful voice model and
streams speech back, while delegation runs on a separate asynchronous path.
WebRTC carries the media, and the server keeps the live path small enough to
deliver every frame on schedule.

The same account explains why a full-duplex transcript is not a clean sequence
of turns. The server uses partial transcripts and timing signals to infer who
has the floor. A brief assistant acknowledgement such as "mm hmm" or "okay"
"should not necessarily become its own message", while a substantive
interjection often should. ChatGPT therefore keeps a speculative conversation
view and an authoritative record rather than forcing the live audio into
request/response turns. See [How we built a realtime system for responsive
voice AI in six
months](https://openai.com/index/continuous-voice-interaction-with-gpt-live/).

## What GPT-Live actually does

### Continuous audio, not a hidden text turn

The API model page calls `gpt-live-1` "a full-duplex voice model for real-time
conversations. It can listen and speak at the same time, and delegate reasoning
and tool use to a backend agent." Sessions are billed per minute; backend model
and tool usage is billed separately. See [GPT-Live
1](https://developers.openai.com/api/docs/models/gpt-live-1).

The migration guide's instruction to Realtime API users is the key sentence:
"Stream audio continuously. GPT-Live decides when to speak; remove manual audio
commits and voice-turn triggers." There is no `response.create` needed to make
it answer, and no VAD stop event that authorizes a response. See [Migrate to
GPT-Live](https://developers.openai.com/api/docs/guides/live-migration).

This is different from the Realtime API, which remains available and is still
turn-gated. Realtime sessions configure `session.audio.input.turn_detection`
with `server_vad` (silence) or `semantic_vad` (a classifier over the words), and
`create_response` / `interrupt_response` decide whether a detected stop creates
or interrupts a response. Semantic VAD reduces false cutoffs but still decides
when a turn ends. See [Voice activity
detection](https://developers.openai.com/api/docs/guides/realtime-vad) and the
[voice-agent architecture
comparison](https://developers.openai.com/api/docs/guides/voice-agents).

### Backchannels are a prompt policy, not a tool call

GPT-Live's prompting guide keeps three headings in the conversation prompt:

```text
Backchannel policy: Use moderate backchannels. Acknowledge naturally
without competing with the main response.

Interruption policy: Stop speaking when the user interrupts. Listen to
what they say.

Delegation policy:
Backend tools:
- [capability]: [what the backend can do]

Generate <|SpawnThinking|> when:
- The request needs a backend capability or careful reasoning.
- A correction changes the work already requested.
```

The guide defines backchannels as "brief listening sounds, such as 'mm-hmm,'
while the user is speaking" and says to tune them separately from
acknowledgements such as "Got it" at the start of an answer. It offers none,
frequent and very frequent policies, and warns that a rule forbidding all
overlapping speech suppresses them. See [Prompting
GPT-Live](https://developers.openai.com/api/docs/guides/live-prompting).

Always engaged does not mean always talking. The launch post also describes
GPT-Live as able to "just stay quiet when you need a moment to think", and the
help center says it waits instead of jumping in. The point is that it keeps
processing the audio and decides continuously, not that it fills every silence.

So a listening-token model is close but not exact:

- The audio does go to a multimodal speech model, not through a text-only LLM.
- There is a real special token, `<|SpawnThinking|>`, but it is the delegation
  control, not a listening marker.
- "mhmm" is generated audio by the voice model under the backchannel policy. It
  is not a tool call, a separate model invocation, or a token that a text model
  emits so a TTS engine can say "hm".
- The model can also decide to stay silent, keep listening, pause, or interrupt.
  Those are continuous decisions, not a turn-level prompt branch.

### Interruption is a policy plus playback control

The prompting guide is honest about the limit: GPT-Live is full duplex and can
speak while the user speaks, but instructions "do not provide precise control
over when it stops speaking. The model may keep speaking briefly after an
interruption." An interruption instruction is therefore not a hard cancel.
Applications that need exact playback control stop or drop output audio in
their player and then steer the model. See [Interruption
policy](https://developers.openai.com/api/docs/guides/live-prompting#interruptions)
and [server-side
controls](https://developers.openai.com/api/docs/guides/voice-server-controls).

This matters for a coding voice mode: "stop talking" and "cancel the task" are
different requests. Stopping playback should not cancel an agent turn by
itself; cancelling work should be an explicit, separate action.

### Delegation preserves the text agent

GPT-Live does not replace the coding model. It delegates work through one of
two modes:

- **Responses delegation:** GPT-Live calls a configured Responses model with
  tools and context.
- **Client delegation:** the application runs any model, agent or service and
  returns results. GPT-Live keeps the spoken conversation going meanwhile.

With client delegation, the application receives `session.delegation.created`
with an ID and timestamp, but **not** the user's utterance. It must collect
`session.input_transcript.delta` and `session.output_transcript.delta` itself.
It returns a spoken result with `session.commentary.append`, quiet context with
`session.thinking.append`, and steering with `session.instructions.append`.
See [Delegation and
tools](https://developers.openai.com/api/docs/guides/live-delegation) and
[Managing GPT-Live
sessions](https://developers.openai.com/api/docs/guides/live-conversations).

This is the architectural match for the harness: keep the existing session,
tools, permissions, worktrees and review flow; put a full-duplex voice model in
front of it and let that model delegate to the session. The voice model gets a
short conversation prompt, not the coding prompt and not direct tool access.

### Transcripts and playback are separate

GPT-Live's transcript deltas have no item ID and no event that marks a completed
conversational turn; the application groups them for display. Both speakers'
captions can grow at once during overlap. Output audio has no end-of-response
event, so the speaking indicator must follow the audio player, not the model's
generation. These are not implementation details: they are why a client that
tries to reuse a turn-based chat UI will look wrong even when the audio is
right.

The ChatGPT help center also notes that Live responses appear as text while
they are spoken, and that spoken approval for an action is not supported: the
user approves or declines on screen. That is a useful safety rule for the
harness, whose permission panels already work this way.

## Why the WAV provider does not feel like this

The default WAV provider is deliberately the **Standard** shape:

```text
microphone -> completed WAV -> STT -> editable compose text -> text agent
speakers   <- player       <- TTS <- assistant text, by sentence
```

It has no continuous audio input, no full-duplex model, no echo cancellation,
no overlap detection and no backchannel audio. Removing the "send" key would
only add one more turn to a turn-based loop. Auto-sending a transcript would
also make misheard coding requests more dangerous: a sentence can start a tool
call, and the existing permission panels are the right place to catch that.

Auto-send is therefore not the missing piece. ChatGPT Live's voice model
answers without a send key because it is the conversational participant, not
because a transcript is submitted faster. Its backend actions still require
on-screen approval. The live provider likewise owns the spoken
conversation while the compose draft stays an explicit, editable text path.

A text prompt cannot fix the missing audio path. A token such as
`<listening>` would have nothing to listen to while the text model is running,
and playing a canned "mm-hmm" from a timer would not be grounded in what the
user said. The continuous feel comes from the model receiving and producing
audio at the same time, plus an application that keeps playback and work
independent.

## Open-source and hosted options

There is no drop-in package that combines full-duplex speech, an arbitrary
coding agent, and the harness's permission model. The closest options are:

| Option | Shape | Fit and limit |
| --- | --- | --- |
| [GPT-Live](https://developers.openai.com/api/docs/guides/live) | Hosted full-duplex voice model with client or Responses delegation | Closest to ChatGPT Live and preserves the harness agent as the backend. Needs an OpenAI API key, network, per-minute billing and a WebRTC/WebSocket sidecar. |
| [OpenAI Realtime API](https://developers.openai.com/api/docs/guides/realtime) | Hosted speech-to-speech with VAD turn detection and in-session tools | Lower-level than GPT-Live and still turn-gated. Useful if the voice model itself should call tools; less clean for delegating to an existing coding agent. |
| [Moshi](https://github.com/kyutai-labs/moshi) | Local full-duplex speech-text model; two audio streams, no explicit speaker turns | A genuine local full-duplex conversation, with a reported 160 ms theoretical / 200 ms practical latency. It is its own dialogue brain, not a voice skin for the selected coding agent; it needs a suitable GPU and a separate integration. See the [paper](https://arxiv.org/abs/2410.00037). |
| [Kyutai Unmute](https://github.com/kyutai-labs/unmute) | Streaming STT → any text LLM → streaming TTS | Preserves a text model, but waits for the user to stop before generating; its README also lists tool calling as unfinished. The full stack needs Linux/WSL, x86-64 and at least 16 GB of VRAM. |
| [Pipecat](https://github.com/pipecat-ai/pipecat) | Orchestration for VAD, turn detection, STT, LLM, TTS and transports; `OpenAILiveLLMService` adds GPT-Live with client delegation | A practical sidecar framework, not a speech model. Client delegation matches this design: the backend gets the transcript since the previous delegation, and its output returns as commentary or quiet context. Its [backchannel detector](https://huggingface.co/pipecat-ai/backchannel-detector) shows that even turn-based stacks need a separate classifier to avoid treating "uh huh" as barge-in. |
| [LiveKit Agents](https://github.com/livekit/agents) | Open-source agent framework with an OpenAI GPT-Live plugin | Another way to own the audio path and run a GPT-Live session; it fits the same sidecar contract. |
| [Gemini Live API](https://ai.google.dev/gemini-api/docs/live-api) | Hosted native-audio conversation with automatic VAD, barge-in and optional proactive audio | Another hosted route, with different tool, auth and data terms. Proactive audio is the closest analogue to deciding when to speak rather than answering every VAD trigger. |

The important distinction is between a **voice model** and a **voice
pipeline**. Moshi and GPT-Live are voice models that decide when to speak.
Unmute is a pipeline around a text model. Pipecat and LiveKit are ways to
build and orchestrate such a pipeline, and both now offer a GPT-Live service.
None of them supplies the harness's session, tools, permissions, worktrees or
review flow; that integration is what the sidecar protocol here provides.

### Recommendation

The Emacs side is implemented. For the ChatGPT Live feel while preserving the
harness agent, put a GPT-Live client-delegation sidecar behind
`harness-voice-live-command`. Pipecat's `OpenAILiveLLMService` and LiveKit's
GPT-Live plugin are the shortest credible starting points; a small stdio
adapter translates their delegation and transcript events to the protocol
below. If audio must stay local, Moshi is the only researched full-duplex
option, but it is the dialogue model itself; a local text-agent bridge does not
exist off the shelf. Unmute and Pipecat can improve turn-taking and
interruption, but they cannot remove the turn boundary.

## The live provider in this tree

This is no longer only a proposal. Voice providers declare a capability,
`wav` or `live`, the way model providers do; `harness-voice-provider` names one,
and every command dispatches on the capability rather than the name. The WAV
provider remains the default.

Three live providers ship here:

| Provider | Sidecar | Verified |
| --- | --- | --- |
| `chatgpt` | `scripts/harness-voice-live-gpt`, a GPT-Live WebSocket client with client delegation and PCM16 audio at 24 kHz | Framing, the event mapping and the delegation round trip run in `--self-test`; a real session needs a key and network, and is not exercised by the suite |
| `unmute` | `scripts/harness-voice-live-unmute`, a local pipeline over Kyutai Unmute's OpenAI-compatible STT and TTS endpoints | The pipeline, its delegation and its TTS mapping run in `--self-test`; real audio needs a microphone and a running server |
| `fixture` | `scripts/harness-voice-live-fixture`, a scripted transcript, one delegation and a spoken reply | The whole Emacs-side loop, with no microphone, key or model |

`custom` runs any sidecar in `harness-voice-live-command`, so a Pipecat, Moshi
or other stack can be attached without changing Emacs. The shared plumbing
lives in `scripts/harness_voice_sidecar.py`: the event loop, the audio
backends (PipeWire, PulseAudio, ALSA or ffmpeg), an energy voice detector, HTTP
helpers and a small RFC 6455 client, all in the Python standard library.

### Audio ownership

Emacs cannot provide WebRTC, acoustic echo cancellation, jitter buffering or a
reliable playback clock. The audio lives in the sidecar:

- a small WebRTC sidecar (browser page or native libwebrtc/Pion) for GPT-Live;
- a Python/Node sidecar for a local Moshi or Pipecat stack;
- a stdio JSON-lines control channel between the sidecar and Emacs.

The sidecar owns microphone capture, speaker output and the live session. Emacs
owns the visible state, the transcript, the agent session and every permission
decision. The API key stays in the sidecar's environment or secret store, never
in a buffer or a prompt. The sidecar is started on the UI client, like the WAV
recorder and player.

### Event protocol

One JSON object per line on stdin and stdout, UTF-8, diagnostics on stderr.
Audio never crosses the pipe. This is small enough to test without a speech
model, and the test sidecars do exactly that.

| Direction | Event | Fields | Meaning |
| --- | --- | --- | --- |
| sidecar → Emacs | `ready` | `provider`, `voice` | Session connected; microphone may start |
| sidecar → Emacs | `listening` / `speaking` | — | Audio state for the indicator |
| sidecar → Emacs | `level` | `input` | The microphone's level before the speech filter, 0..1, at most ten times a second; the capture loop measures it on the PCM it just read |
| sidecar → Emacs | `hearing` | `utterance` | The user started speaking (a stage, not the gate) |
| sidecar → Emacs | `speech` | `active`, `utterance`, `reason` | The low-latency gate: true at speech onset, before any transcript; false at speech end |
| sidecar → Emacs | `segment` | `id`, `state`, `seconds`, `reason` | One burst's own decision: `accepted` when the gate kept it, `dropped` with `too short` or `no words`, `failed` when its transcription failed |
| sidecar → Emacs | `transcribing` | `utterance` | A completed utterance is being transcribed |
| sidecar → Emacs | `user_delta` / `assistant_delta` | `text`, `final` | Caption fragments; `final` ends the caption line |
| sidecar → Emacs | `backchannel` | `text` | Brief listening sound |
| sidecar → Emacs | `delegation` | `id`, `text`, `utterance`, `pending`, `speech_active` | Backend request, the transcript, and assistant output held while the person spoke |
| sidecar → Emacs | `interrupted` | — | Playback stopped |
| sidecar → Emacs | `error` | `message` | Visible failure |
| sidecar → Emacs | `closed` | `reason` | Clean end |
| Emacs → sidecar | `start` | `protocol`, `context` | Session start and visible context |
| Emacs → sidecar | `context` | `text` | Context update, if a sidecar asks for one |
| Emacs → sidecar | `mute` | `on` | Microphone off or on |
| Emacs → sidecar | `interrupt` | — | Stop playback now, without ending the session |
| Emacs → sidecar | `stop` | — | End the session |
| Emacs → sidecar | `commentary` | `text` | Speakable agent text |
| Emacs → sidecar | `thinking` | `text` | Quiet progress, not to be spoken immediately |
| Emacs → sidecar | `delegate_result` | `id`, `text`, `error`, `message` | Final answer or failure for a delegation |

The protocol version is 1. Unknown events are ignored, so a sidecar can add
fields without breaking the client.  A sidecar that reports `level` and
`segment` fills the pipeline the Emacs voice transcript draws; one that sends
neither leaves the meter at `Level · no data` rather than drawing silence.  A
sidecar must not print anything but its JSON lines to stdout; diagnostics go
to stderr, which the UI shows, shortened, when the process fails or exits
unexpectedly.

### Mapping to the harness

The implemented loop:

1. `delegation` becomes a prompt in the current chat through `session/prompt`.
   The prompt carries the visible file/line and related-session context of the
   quick voice chat. A second delegation waits for the running turn.
2. Assistant chunks stream back as `commentary`, sentence by sentence, with
   fenced code and markup filtered out. The turn's full text is sent as
   `delegate_result`; an announcement-only provider still produces one result.
3. Tool calls, questions and permissions stay in the harness. The voice model
   may say that approval is needed; the user approves on screen. Spoken
   approval is not supported, as in ChatGPT Live.
4. **Interrupt** (`C-c V`) sends `interrupt` and stops playback only. **Cancel
   work** is a separate control that sends `session/cancel`. The two are never
   conflated.
5. The live transcript is its own read-only buffer (`*harness voice*`) with
   `You`, `Coding agent` and `Voice` sections. Headings carry their time, tool
   calls read `▸ Read · file.py`, backchannels are italic and the header line
   keeps the animated stage and the provider in view while the transcript
   scrolls. The editable compose draft is untouched. Redaction and UI reload
   stop the sidecar and clear the transcript.

### The pipeline in Emacs

The stage line says what the session is doing; the pipeline under it says what
reached the microphone, what the speech filter kept and dropped, what was
transcribed, and what the speaker is doing.  It is fed by the events above and
drawn by `harness-ui-voice-pipeline.el`:

```text
Pipeline
Input                     Filter            Words          Turn         Speaker
████▃··· Level · 56%      ● 1 accepted      ≡ in turn      ✓ done       ▷ speaking
Mic · live                × 1 dropped                      1 utterance
                                                           1 reply
Mic · live · Level · 56% · 1 accepted · 1 dropped · Turn · done · Speaker · speaking
[Pipeline details]
```

The transcript shows the wide strip, its summary and a control that lists
every marker by id (`d`); a live chat's controls carry the compact line under
them, which keeps the speaker and the turn when the window is narrow.  The
words, the states and the reasons are the Flutter client's
([Voice pipeline](voice-pipeline-visualization.md)), with `Speaker ·` for the
output because the transcript's header already says `Voice · <provider>`.  No
part of the strip moves on a clock: it redraws when an event arrives, and a
stage that has not reported says it is waiting.  The meter moves with the
sound because that is the measurement; the stage line's spinner is decoration,
and `harness-voice-live-motion` nil stops it while every fact stays.

[How the pictures are made and what they do not show](voice-pipeline-visualization.md#in-emacs).

### UI states

Exact status copy, from `harness-voice-live--status`:

```text
Live · Off
Live · Starting
Live · Listening
Live · Hearing you
Live · Transcribing
Live · Working
Live · Holding reply
Live · Speaking
Live · Interrupted
Live · Muted
Live · Ending
Live · Failed
```

The indicator follows the sidecar's audio state, not text generation. A
microphone on/off control and a visible **End** control remain mandatory.
**Interrupt** is reachable without a keyboard. **Speaking** is reported by the
sidecar when its own player is playing, so generation finishing early does not
claim the agent is still talking. **Holding reply** is the gate: assistant
text is waiting for the person to finish, and it will travel with the next
transcript rather than being spoken late.

[Voice turn-taking](voice-turn-taking.md) covers the speech signal, the
pending-update context, the live-conversation controls and their latency
budget.

### What is implemented and tested

- The Emacs transport, state machine, transcript, delegation, commentary,
  delegate result, mute, interrupt, cancel, startup timeout, protocol error,
  unexpected exit, redaction and cleanup.
- The provider registry: capabilities, the five bundled providers, selection,
  availability reasons and the setup list, with exact copy.
- Three sidecars: the scripted fixture, the GPT-Live adapter and the local
  pipeline, each with a `--self-test` that runs in the suite without a
  microphone, key or network. The GPT-Live self-test also round-trips the
  WebSocket handshake and framing through a loopback echo server.
- Exact status, control and tooltip copy, and live dev-instance screenshots.

Not verified here: a real GPT-Live session (needs a project key and network),
real speech models and a real microphone, acoustic echo cancellation, and
overlapping speech under load.

### Phases

1. **Protocol and fixture sidecar.** Done. The JSON-lines event loop, scripted
   listening/speaking/delegation events, UI states and cancellation tests run
   without a model or microphone.
2. **Hosted GPT-Live adapter.** Done as a WebSocket client with client
   delegation (`scripts/harness-voice-live-gpt`). Remaining: a real key and a
   measured first-audio latency, plus the WebRTC route if a browser page is
   preferred; Pipecat's `OpenAILiveLLMService` or LiveKit's plugin remain the
   shortest alternative.
3. **Local adapter.** Done as the `unmute` provider: Kyutai Unmute's
   OpenAI-compatible endpoints, or whisper.cpp and Piper behind the same shape,
   with an energy detector in front. Still turn-based. Moshi (full-duplex, own
   brain) remains the only researched option that removes the turn boundary.
4. **Acoustic barge-in and evaluation.** Test echo cancellation, overlapping
   speech, backchannel frequency, false interruptions, network loss and
   long-running sessions on real hardware.

Do not claim full-duplex behavior for the WAV provider, and do not auto-send
compose text to imitate it. The value of Live voice is the audio loop, not the
absence of a send key.

### Writing a sidecar

A GPT-Live sidecar owns the audio path and speaks this protocol on stdio. The
mapping from the hosted session is direct:

| GPT-Live event or command | Sidecar protocol |
| --- | --- |
| `session.started` | `ready`, then `listening` |
| `session.input_transcript.delta` | `user_delta` with `final` at the application's boundary |
| `session.output_transcript.delta` | `assistant_delta` |
| `session.output_audio.delta` | Play it in the sidecar; report `speaking`/`listening` from the player |
| `session.delegation.created` | `delegation` with the transcript since the previous one |
| `session.commentary.append` | Send Emacs's `commentary` text |
| `session.thinking.append` | Send Emacs's `thinking` text |
| `session.instructions.append` | Steer the live model, e.g. a corrected delegation |
| `session.input_audio.append` | Microphone audio, inside the sidecar |
| `session.close` / `session.closed` | `stop` / `closed` |

The WebSocket transport carries raw mono PCM16 at 24 kHz in JSON events;
WebRTC carries the same audio on media tracks and events on a data channel.
Either belongs in the sidecar. The sidecar must report playback itself because
GPT-Live has no event that marks the end of a spoken response. The fixture is
a compact example of the event shapes, and `test/harness-voice-live-sidecar-test.py`
shows the failure cases.

## Sources

- [Introducing GPT-Live](https://openai.com/index/introducing-gpt-live/)
- [How we built a realtime system for responsive voice AI in six months](https://openai.com/index/continuous-voice-interaction-with-gpt-live/)
- [ChatGPT Voice help center](https://help.openai.com/en/articles/20001274-chatgpt-voice)
- [Getting started with GPT-Live](https://developers.openai.com/api/docs/guides/live)
- [Prompting GPT-Live](https://developers.openai.com/api/docs/guides/live-prompting)
- [Delegation and tools in GPT-Live](https://developers.openai.com/api/docs/guides/live-delegation)
- [Managing GPT-Live sessions](https://developers.openai.com/api/docs/guides/live-conversations)
- [Migrate to GPT-Live](https://developers.openai.com/api/docs/guides/live-migration)
- [GPT-Live 1 model](https://developers.openai.com/api/docs/models/gpt-live-1)
- [Realtime API voice activity detection](https://developers.openai.com/api/docs/guides/realtime-vad)
- [Realtime API conversations](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [Voice agents architecture comparison](https://developers.openai.com/api/docs/guides/voice-agents)
- [Moshi paper](https://arxiv.org/abs/2410.00037)
- [Kyutai Unmute](https://github.com/kyutai-labs/unmute)
- [Pipecat OpenAI GPT-Live service](https://docs.pipecat.ai/api-reference/server/services/s2s/openai-live)
- [LiveKit Agents GPT-Live plugin](https://docs.livekit.io/agents/models/realtime/gpt-live/)
- [OpenAI Live Console](https://github.com/openai/openai-live-console)
- [Pipecat speech input and turn detection](https://docs.pipecat.ai/pipecat/learn/speech-input)
- [Pipecat backchannel detector](https://huggingface.co/pipecat-ai/backchannel-detector)
- [Gemini Live API capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities)
