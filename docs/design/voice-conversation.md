# The voice conversation and the request it sends

Design note, November 2026.  This page separates two records that live
voice used to treat as one: the **voice conversation** (what was said and
heard on the audio side) and the **session message** (what crosses into
the chat).  It states what happens to a transcript between the sidecar
and `session/prompt`, why the two records differ, and the limits that
keep the second from becoming a reformatting step with a latency cost.

## Two records, one pipe

Live voice has always had one text path:

```text
sidecar transcript -> delegation -> session/prompt -> agent turn
```

The transcript is the speech model's output.  It is what the person
said, with every false start, hesitation and repeated word the model
heard.  Sending it unchanged to the session is wrong in two directions:

- It carries noise the person did not mean: `uh`, `um`, a stutter, a
  false start, a cough annotation.  A chat message made of those is
  harder for the agent to act on than the sentence the person meant.
- It carries *too little*: a sentence such as "do that instead" depends
  on an exchange the voice had, and that exchange may never have reached
  the session.  The delegation is the only text bridge; a concept that
  stayed in the voice conversation is invisible to the agent.

At the same time, the transcript must not become a *summary*: an extra
model call would add seconds to every utterance, change what the person
said, and introduce a failure path between the microphone and the
session.  A fixed XML or JSON envelope on every message would cost
tokens and make an ordinary request read as a protocol event.

## Decision

There are two records with different jobs, and one local, deterministic
step between them.

### The voice conversation

The voice conversation is the audio-side record of one live call:

- every user utterance **as the speech model returned it** (`raw`);
- its distilled request, when one was sent (`text`), and the full
  message that crossed into the session (`sent`);
- every line the voice actually spoke: spoken commentary, a spoken
  result, a backchannel, or the provider's own transcript line.

It is kept by the client that owns the call (the Emacs live transport,
or the Flutter `VoiceController`), not by the chat session.  It is
bounded (40 turns by default, each at most 4000 characters), cleared
when a call starts or ends, and never edited back into a transcript that
was already shown.  The voice transcript and the captions are its
visible form.

The **session message** is a derived thing: a request distilled from one
delegation, with a short piece of the voice conversation when the
request cannot stand alone.

### Distillation is removal, not rewriting

The distiller takes the raw transcript and removes only what carries no
request.  It never replaces a word, reorders a sentence, summarizes a
paragraph, translates, or invents punctuation beyond tidying the spaces
its own removals left.

| Removed | Examples | Why it is safe |
| --- | --- | --- |
| Non-speech annotations | `[BLANK_AUDIO]`, `[laughter]`, `(coughs)`, `♪`, `*sighs*` | The speech model marked a sound, not words |
| Hesitation sounds | `um`, `uh`, `er`, `erm`, `ah`, `hmm` | No content; removing them leaves the sentence |
| Comma-set discourse markers | `, like,`, `, you know,`, `, I mean,` at the edges of a clause, `Actually,` | The commas show the speaker set the phrase aside; an unset `like` or `I mean` is kept |
| Stutters and repeated starts | `the the parser`, `I want to I want to add` | The repetition repeats the same words |
| An explicit self-correction | `..., no wait, X`, `..., sorry, I mean X`, `..., actually, X` | The speaker retracted what came before; only the correction is the request |
| Pure noise | an utterance that is only hesitations | There is no request to send |

Kept exactly as spoken: every content word, names, paths, numbers, code
fragments, punctuation, casing, a bare `yes`/`no`/`okay`, and
affirmation sounds when they are the whole utterance (`uh-huh` alone is
a yes, not noise).  The distiller does not add a period, expand an
abbreviation or capitalize a path.

It is local and synchronous: no process, no timer, no network, no model.
The delegation is sent in the same event that carried it.  The cost is
linear in the words of one utterance; nothing is batched across
utterances and nothing waits for a silence.

### Context travels only when the request needs it

A request that names what it is about travels alone.  When the request
cannot stand alone -- it points with a pronoun or deictic (`it`, `that`,
`the second one`, `the same`), continues (`also`, `again`, `then`, `and`,
`but`), or answers (`yes`, `no`, `okay`, `go ahead`) -- the message
carries the last few voice turns in plain text:

```text
Use a queue instead of polling.

Voice conversation before this request:
Person: the timer wakes it every 200 ms
Voice: that would keep the old poll alive
```

The block is the last turns that fit: four turns and about 700
characters by default, each turn cut at 240 characters, oldest first.
It is normal text with speaker labels, not an XML/JSON envelope, and it
is added only to the message that needed it.  Backchannels are not
context and are skipped.  The raw words are in the voice conversation,
so the block never has to be a paraphrase.

The two defaults are options: `harness-voice-distill` nil sends the
transcript as heard, and `harness-voice-conversation-carry-context` nil
never adds the earlier turns.  Either still keeps the voice conversation
itself.

### What crosses, in order

The prompt is the distilled request, then the voice-conversation block
when needed, then the existing `<voice-turn-context>` block for
assistant output that was held while the person spoke.  The request is
the first thing in the message; a model that reads only the opening has
the request.  No file/line or related-session block is added to a
delegation, and no other session is looked up for one: the session voice
mode is used in is the context, and a workflow that really spans
sessions or projects belongs to the workspaces feature.  The held-output
block is unchanged: it is a safety contract about what was *not* heard,
not a wrapper around the request.

An utterance that distils to nothing sends no session prompt and
answers its delegation with empty text, so the sidecar is not left
waiting.  The transcript says `Not sent · no request` beside what was
heard, and the pipeline's burst stops at `dropped · no request`.  A
request that changed in distillation is shown under `Sent` in the voice
transcript, so the person can see exactly what crossed while the raw
caption stays as heard.

## The voice conversation is not the session transcript

The session's own transcript already holds the agent's text and the
distilled requests it answered.  The voice conversation is the other
side of the same call: what the person actually said, what the voice
actually spoke, and which request crossed.  It is per call, not per
session: a new call starts a new voice conversation, while the session
keeps its history.  Mute, pause and interrupt do not clear it; ending or
restarting the call does.  It is bounded so a long call does not grow a
second unbounded transcript in memory.

## Latency and cost

| Step | Cost | Basis |
| --- | --- | --- |
| Distillation | microseconds, linear in words | one regexp pass per rule, no I/O |
| Dependency check | one word-set and a few phrase patterns | no model |
| Context assembly | at most 4 turns and 700 characters | bounded |
| Added wait before `session/prompt` | 0 ms | same event; no timer, no batching |

The distiller does not make the transcript wait for the next utterance.
Consecutive utterances stay separate session messages; joining them
would either delay the first one or conflate two requests.

## Alternatives considered

- **A small model rewrites the transcript.**  The best possible
  distillation, but it adds a network round trip before every request,
  a second failure path, and a new place where the person's words can be
  changed.  It also cannot run in the local pipeline without another
  hosted model.  The rules above get the mumbles out deterministically;
  a provider that has a conversation model can still do more on its own
  side without changing this contract.
- **Batch utterances for a short window.**  A 600 ms join window would
  make two fragments one message, and make every request 600 ms slower.
  The person already hears the 850 ms end-of-speech hangover; adding to
  it is the wrong trade.  Requests that need to be one message can be
  said as one sentence.
- **Send the whole voice conversation with every delegation.**  Removes
  the dependency guess, but sends the same paragraphs again and again,
  grows with the call, and pushes the session's context window toward
  the audio side's small talk.
- **A fixed request envelope.**  A stable `<voice-request>` block would
  be easy to parse in a test and wrong for a chat: it costs tokens on
  every turn, makes an ordinary request look like an event, and adds a
  format the agent has to be taught.  The plain request plus an optional
  labelled exchange is enough.
- **Keep only the distilled text and discard the raw.**  Makes the
  voice transcript lie about what was heard and leaves no way to audit a
  bad distillation.  The raw words are cheap and are the record.
- **Let the sidecar distil.**  It belongs to the provider: GPT-Live has
  a conversation model, the local pipeline has only an STT service.  A
  client rule keeps the behaviour the same across both and keeps chat
  formatting out of the audio process.

## Shape of the change

`lisp/ui/harness-ui-voice-conversation.el` (new)

- `harness-voice-distilled-text`: the removal rules above.
- `harness-voice-conversation`: turns, bounded; `-hear` records a user
  utterance with its raw and distilled forms and the message sent;
  `-say` records what the voice actually spoke; `-clear` starts a call.
- `harness-voice-conversation-needs-context-p` and
  `harness-voice-conversation-request`: the dependency check, the
  bounded block and the message.

`lisp/ui/harness-ui-voice-live.el`

- One conversation per call, reset on start.
- `delegate` distils; `delegate-next` sends the composed request; an
  empty distillation answers the delegation without a prompt and marks
  its pipeline burst `dropped · no request`.
- The transcript marks `Sent` and `Not sent`; commentary, released held
  text, results, backchannels and the provider's own transcript lines
  feed the voice side.
- The raw text and the held-output block are unchanged where they were;
  the per-delegation origin and related-session prefix is gone.

`harness_client/lib/src/voice/voice_conversation.dart` (new)

- The same pure rules and bounds in Dart, wired into
  `VoiceController._sendPrompt` and its captions, so the Flutter client
  sends the same distilled request and marks a no-request burst in its
  pipeline.

Docs and tests

- This page, `docs/voice-turn-taking.md` (the message shape),
  `docs/voice.md` and `docs/voice-realtime.md` (the two records).
- `lisp/ui/harness-ui-voice-conversation-test.el` (rules, context,
  bounds) and `lisp/ui/harness-ui-voice-live-test.el` (one delegation
  through the real transport), plus the Flutter
  `voice_conversation_test.dart` and controller tests.
