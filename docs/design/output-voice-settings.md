# Output voice: selection, audition and the parameters a service declares

`M-x harness-voice-output` (Emacs) and **Settings → Voice settings → Output
voice** (Flutter) choose the voice spoken replies use, hear a draft before it is
kept, and set the pace and volume parameters the selected speech service really
accepts. This note records what the two pages decide: where a voice list comes
from, what a client may honestly show, where a choice is kept, and how an
audition is made safe.

## The problem

Before this, the output voice was a string in two option files and a text field
in each client. Nobody could see which voices their speech service had, nothing
verified that a value would be accepted, and the only way to hear a voice was to
send a message and wait for a reply. The tempting shape — a list of the "usual"
voices plus a slider for pace — is wrong for this codebase: the harness can be
pointed at a service of your own, and a list or a control invented here would
post a field a server ignores and look like a setting that works.

## What each provider can honestly offer

| Provider | Voice list | Audition | Where the choice is kept |
| --- | --- | --- | --- |
| `unmute` (local pipeline) | The service's own `/v1/audio/voices` answer | Yes, a real WAV from that service | `harness-voice-unmute-voice`, `harness-voice-unmute-parameters` |
| `chatgpt` (ChatGPT Live) | None: the provider's server defines the voice | No | `harness-voice-chatgpt-voice` |
| `wav` (device voice) | None: the device engine has no catalogue this client reads | No | — |
| `fixture` (scripted sidecar) | None: it speaks what the script says | No | — |
| `custom` (sidecar of your own) | None: this client knows nothing of it | No | — |
| a provider this client does not know | None, and the page says `Unknown voice provider` | No | — |

The page states the reason in one noun-phrase row rather than showing an empty
list: `Device voice · no catalogue`, `Scripted fixture · no catalogue`,
`Sidecar voice · no catalogue`, `Provider-managed voice · audition unavailable`.

![The Emacs output voice page over a real Kokoro-shaped service: the voices it reports, the drafted voice selected, the declared parameters and a failed audition in the page's own words](media/output-voice/emacs-output-voice.png)

The pictures are the live page over a service answering the bundled stack's own
routes: the ten voices it reports with their language labels, `bm_george`
drafted and `Speed 1.50×` not yet saved. The failed state is a real refusal,
not a mock: `Failed · British English · male · bm_george`, `[Retry]`, and the
harness's one-line reason.

## Where the voice list comes from

The list is the speech service's own. The Emacs page asks the harness over ACP
(`_harness/speech/voices` → `speech/voices`, `lisp/modules/harness-speech.el`),
which asks the service and passes its answer through. Nothing is hardcoded on
either side of that boundary.

`harness-speech--voices-url` derives the route from the configured speech route:
`…/v1/audio/speech` → `…/v1/audio/voices` (the bundled Kokoro-FastAPI stack,
whose router is mounted at `/v1`), `…/audio/speech` → `…/audio/voices`,
otherwise the speech URL with `/v1/audio/voices` appended.

`harness-speech--voice-names` reads the shapes services actually answer with,
verified against Kokoro-FastAPI v0.8.2's `api/src/routers/openai.py`:

- `{"voices": [{"id": "af_heart", "name": "af_heart", …}, …]}` (current)
- `{"voices": ["af_heart", …]}` (older)
- `{"data": [{"id": …}, …]}` (OpenAI-style)
- a plain array of names or objects

A name with no `id` is skipped rather than shown as a broken row; duplicates are
dropped, and the service's order is kept.

Each entry becomes `(:id NAME :label NOUN :language LANG :gender GENDER)`. A
Kokoro name carries its language and voice in the prefix (`af_` American English
female, `bm_` British English male, …); the label reads
`American English · female · af_heart`. A name this client cannot decode keeps
the service's own spelling as its label, with no invented language.

The states the answer can be in, each with its own row:

| `:state` | When | Row |
| --- | --- | --- |
| `running` | the service listed voices | the list |
| `stopped` | no speech URL: no service runs | `Local voice pipeline · stopped` |
| `unsupported` | no voice route (404/405), or a body that is no JSON list | `Voice list unsupported` |
| `failed` | the request failed, or the list was empty | `Voice list unavailable · …` |

The answer is cached for `harness-speech-voices-ttl` (60 s) and dropped whenever
the pipeline moves (`harness-speech--remember` bumps the generation), so a list
never survives the service it described.

## The parameters a service declares

Only the service the harness starts itself has a declaration this code can
vouch for. `harness-speech-kokoro-parameters` is verified against Kokoro-FastAPI
v0.8.2's `api/src/structures/schemas.py`:

| Key | Label | Range | Default | Unit |
| --- | --- | --- | --- | --- |
| `speed` | Speed | 0.25–4.0 | 1.0 | × |
| `volume_multiplier` | Volume | 0.0–10.0 | 1.0 | × |

Keys are the service's own field names, not this project's; the values are in
the service's units, which `:unit` names for a person. A service of your own
declares nothing, so the page offers no parameter for it and
`harness-speech-check-parameters` refuses one: posting a field a server ignores
would look like a setting that works.

`harness-speech-check-parameters` refuses an undeclared key
(`Speech parameter unsupported · pitch`), a value that is not a finite number
(`Speed · not a number`), and a value outside its range
(`Speed · 5.00 outside 0.25–4.00`). A value equal to its default is dropped, so
a request carries only the change. `harness-speech-parameters-json` turns the
survivors into the object the request carries.

## Persistence, precedence and the effective value

Both skills keep the choice in client configuration, not in harness settings:
`harness-voice-provider` already is client configuration, and the same file
should hold the voice that goes with it.

- **Emacs** saves into this Emacs's custom file through
  `harness-voice--save-choice`, exactly as the provider and speech-model choices
  are saved, so the next Emacs starts with them. An option a policy sets is
  refused before anything changes; a client with no custom file takes the value
  for the session, and Customize says so.
- **Flutter** saves into the device's settings document (`VoiceSettings`, JSON
  v2, key `voiceSettings`).

The value in force, which speaks the next reply, is resolved by both clients the
same way:

1. the policy's value, when a policy sets the option (`policy`),
2. the saved custom value (`saved`),
3. the option's default (`default`).

The Emacs page names the source on the `Effective` row:
`Effective British English · male · bm_george · Speed 1.50× · saved`. The
Flutter sheet shows `Default` for a voice it has not been told to set, and the
rate is left out of the document when it is the engine's normal rate.

A saved value that the service no longer reports is **kept**, not replaced: a
service of your own may know a voice it does not list, and only an audition of
it is an honest test. The page marks it `Not in list · af_old` and still shows
it as what speaks. A saved parameter the current service does not declare is
set aside — never sent to it — and the page says `Set aside · pitch`.

Changing the provider clears the draft, the audition and the catalogue, and the
page asks the new service; a draft chosen for the old provider is not carried
over to one that may not have that voice.

## Save, and what a draft is

`[Save]` is the only control that changes what speaks. Selecting a voice,
changing a parameter and auditioning all change the draft only, which the page
marks `Unsaved changes`; `[Revert]` drops it. Saving validates first (so an
unsupported parameter or an out-of-range value is named, not written), drops the
defaults, and then restarts a running live session, because its sidecar was
started with the old `--voice` and `--tts-parameter` argv. The microphone and
the conversation are the session's own, and the restart ends that call the way a
provider change does.

## The audition

An audition asks the harness to say `harness-voice-output-audition-text` in the
**drafted** voice and parameter values — including changes not yet saved — and
plays the returned WAV with this machine's external player. It sends no prompt,
writes no transcript and speaks to no session; the microphone is untouched and a
live call keeps running.

The identity of the audition in flight is one immutable object
(`harness-voice-output--preview`, a `cl-defstruct`). Every asynchronous
completion — the HTTP answer, its failure, the deadline, the player's sentinel —
compares that object with the page's current one by identity and does nothing if
they differ. It is a struct rather than a plist because `setf` on a plist slot
copies the list: the old shape left each callback holding a copy that was no
longer the page's, so a failure, a timeout and the player's own end were all
being discarded as "stale".

What cancels an audition: another audition, `[Stop]`, choosing a voice, changing
a parameter, `[Revert]`, saving, closing the page, killing its buffer, a
`speech/changed` event, a reconnect, and a provider change. Cancelling aborts
the request's handle, cancels the timer, kills the player, deletes the private
temporary directory and marks the record so its callbacks cannot act.

The states, each one word plus the voice: `Idle`, `Loading`, `Playing`,
`Stopped`, `Failed`. `[Stop]` replaces `[Audition]` while a preview is in
flight; `[Retry]` replaces it after a failure. A failure shows one row — the
harness's own message, or `Audition · no audio` / `Audition · timeout` /
`Audition unavailable · local voice pipeline stopped` — and
`Voice player unavailable · mpv, pw-play, ffplay or paplay` when this machine
has no player.

Both clients keep the preview and the saved choice separate: an audition never
writes an option, a custom file or a settings document.

## What was rejected

- **A list of usual voices in each client.** Untrue for a service of your own,
  and the reason this feature exists. The service is asked instead.
- **A pace slider for every provider.** A native engine reports its accepted
  rate range (Flutter reads `getSpeechRateValidRange`), but no service of your
  own declares anything, so the Emacs page shows a parameter only when the
  service declares it. Flutter shows no rate control at all when the platform's
  range is unusable, rather than guessing one.
- **Saving on selection.** Makes an audition indistinguishable from a
  commitment, and the requirement is explicit that a preview must not overwrite
  a preference.
- **A universal voice list for ChatGPT Live.** No verified catalogue exists for
  an arbitrary endpoint, so the page says `Provider-managed` and keeps only the
  free-text name the client already had: an invented list would be a promise
  nothing keeps.
- **A separate harness setting for the voice.** The harness holds the service
  and its model; the voice is the client's own, like the provider, and belongs
  in the client's configuration where the provider choice already lives.

## The shape of the change

- `lisp/modules/harness-speech.el` — `speech/voices`, the voice-route
  derivation, the answer shapes, the declared parameters, validation and
  serialization, `speech/synthesize`'s optional `voice` and `params`.
- `lisp/ui/harness-ui-voice-output.el` — the page: capability, draft,
  validation, save, audition, rendering, keys and menu.
- `lisp/ui/harness-ui-voice-providers.el` — `harness-voice-unmute-parameters`,
  the sidecar's `--tts-parameter` argv, the `Output voice … [Select]` line in
  the setup list, `o` on that list, and `V` in the session menu.
- `harness_client/lib/src/voice/voice_output.dart` — the catalogue, its
  parser, the rate range, the parameter drafts and their problems.
- `harness_client/lib/src/voice/voice_audition.dart` — the audition engine and
  its controller, with the generation that makes a stale completion harmless.
- `harness_client/lib/src/services/voice_output_io.dart` — the device's own
  engine: `getVoices`, `getSpeechRateValidRange`, `setVoice`,
  `setSpeechRate`, `setPitch`, `setVolume`, `speak`, `stop`.
- `harness_client/lib/src/ui/widgets/voice_settings_sheet.dart` — the Output
  voice section, keyboard and semantics labels.
- Tests: `lisp/ui/harness-ui-voice-output-test.el`, the speech additions in
  `lisp/modules/harness-speech-test.el`, `harness_client/test/voice_output_test.dart`
  and the voice UI and screenshot suites; `test/harness-speech-service.py`
  answers a real voice route so the Emacs tests use a service, not a stub.

## Limits worth knowing

- The Emacs page auditions through `speech/synthesize`, so a service behind a
  remote harness is auditioned on the harness's machine — the audio travels back
  as base64, and the player is the one this client has.
- Flutter can only read a catalogue the device's own engine reports. A platform
  whose engine reports none (the desktop `flutter_tts` backends) gets the
  `Voice list unavailable` path with a typed name, which is what that engine
  really offers.
- The Emacs page's tests use a scripted WAV and `true` as the player: the states,
  the cancellation and the payload are verified, not audible output. The live
  check plays real audio from a real Kokoro service.
