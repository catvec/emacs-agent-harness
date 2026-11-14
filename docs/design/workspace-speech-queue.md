# The workspace's speech floor

## The problem

A workspace has many threads. While the person is away from the
screen they all want to say something, and a phone and a desktop may
both be open on the same workspace. Two threads that speak at once are
unintelligible; two clients that speak the same thread's words are the
same words twice. The person also needs to keep one thread talking
while the others keep working -- the transcript evidence was "you can
also like solo one for a second so that the other ones like don't
interrupt".

The work is therefore in two halves that must not become two
implementations:

1. **One authoritative floor.** Which thread speaks, in what order the
   others wait, what a solo holds back, what a hold keeps, what became
   of every utterance. It lives in the harness, beside the workspace,
   and every client reads and acts on that one record.
2. **Presentation and playback per client.** Emacs draws the floor in a
   side panel and in the workspace buffer and speaks it through the
   voice module's player; Flutter draws it in the workspace page and
   speaks it through the platform's speech engine.

## Ownership, and why

Task `t-kukui0q7` (session `2f986bed`) owns workspace mediation,
continuous conversation, inbox and message reassignment. It had
received speech waiting/solo steering of its own, and the instruction
for this task was to agree the smallest shared API with it before
competing edits rather than to duplicate a backend.

At the start of this task that worktree had no commits beyond the base
commit, and its session answered that the backend floor was not begun.
The agreed division, recorded here and in the module commentary:

- This task owns `lisp/modules/harness-workspace-speech.el` -- module
  `workspace-speech` -- and the `workspace/speech*` methods and the
  `workspace/speech-changed` event. It also owns both clients'
  presentation, both clients' playback, and the end-to-end coverage.
- `t-kukui0q7` keeps provenance, inbox and reassignment in
  `harness-workspace.el` and calls these methods behind
  `harness-method-exists-p` guards. It defines no floor.

That is a decision about *where the record lives*, not about who may
change it later: the floor is a separate module and a separate store
file (`workspaces/ID.speech.json`), so the workspace module needed no
change to carry it and the two tasks do not edit the same file.

## Alternatives considered

**A client-side queue.** Each client keeps the queue and plays it. It
is the obvious first shape and it is wrong here: the queue is shared
state -- a solo set on the phone must hold the desktop's queue too, and
an utterance the desktop played must not be played again by the phone.
Two clients with two queues cannot agree on whose turn it is without a
record between them, and that record is the floor.

**The queue inside the workspace record.** Tempting (the workspace
already has a record) but it puts a fast-changing queue and a
slow-changing workspace in one file, so every enqueue rewrites the
workspace and every workspace write risks the queue; it also makes
`t-kukui0q7`'s module the owner of this task's state. A separate store
file, keyed by workspace, keeps both records independent.

**No claim: the floor decides who speaks.** The floor could name a
speaker (`:speaking` with a `:client`) itself. But the floor cannot see
whether a client is alive, whether its speaker is playing, or whether
the person has muted the room, and a client that dies mid-utterance
would hold the floor for good. The claim is a *lease* the client
renews: a dead client's claim expires
(`harness-workspace-speech-claim-seconds`) and the entry is cancelled
`:why "Speaker lost"`, so the floor moves on.

**Solo lets the playing utterance finish.** The other reading of
"solo": the words already playing are not cut off, and only the *next*
utterance is restricted. Rejected: the one thing the person asked solo
for is that the other threads *do not interrupt*, and a thread that is
mid-sentence when the person solos another one is exactly the
interruption. Solo therefore yields the playing entry of another thread
(`:state "cancelled"`, `:outcome "interrupted"`, `:why "Solo"`) and the
soloed thread's own utterance always finishes. This is tested
(`harness-workspace-speech-solo-holds-the-others-and-interrupts`).

**Solo as a mute.** Solo is not a mute of the client's audio, not a stop
of the other threads' work, and not a reroute of input: the other
threads keep computing and their utterances stay in `:waiting`, marked
`:held "Solo"`, visible and recoverable. Clearing solo releases only the
head of the queue, so leaving solo is never a burst.

## The record

Stored per workspace, `:revision` monotonic:

```
:revision N  :solo THREAD|nil  :hold T|nil  :counter N
:entries [ ENTRY... ]   live: queued | speaking | held
:recent  [ ENTRY... ]   finished | failed | cancelled, bounded
```

An `ENTRY` is `:id :workspace :thread :thread-title :session :node
:source :text :preview :state :at :why :outcome :played :claimed
:claimed-at`. `:node` is what makes enqueue idempotent: two clients
seeing the same assistant node, or one seeing it twice, make one entry.

The methods, all answered as the floor after the change:

| method | does |
| --- | --- |
| `workspace/speech` (id) | the floor as clients read it |
| `workspace/speech/enqueue` (id thread text opts) | a thread has something to say |
| `workspace/speech/claim` (id entry client) | this client will say that entry |
| `workspace/speech/advance` (id entry outcome why) | it finished, failed or was stopped |
| `workspace/speech/solo` (id thread) | only this thread speaks |
| `workspace/speech/unsolo` (id) | every thread is eligible again |
| `workspace/speech/hold` (id opts) | stop, keeping the playing words |
| `workspace/speech/resume` (id opts) | go on from where they stopped |
| `workspace/speech/cancel` (id target) | drop an entry, a thread's entries or all |
| `workspace/speech/clear` (id) | forget the finished entries a client showed |
| `workspace/speech/update` (id plist) | turn the floor on or off |

and every change is `workspace/speech-changed (ID FLOOR)`.

The view adds what a client draws and does not store: `:count`,
`:active`, `:solo-title`, `:thread-title` on each entry, `:held "Solo"`
on a waiting entry a solo keeps back, `:why "Hold"` on one a hold keeps
back.

## Hold, and why it is not solo

Hold is the person's own pause, and the difference is the whole point:
solo *yields* another thread's utterance, hold *keeps* it. The words
playing when the hold starts stay `:speaking` with state `held` and the
seconds played, so taking an earbud out and putting it back finds the
same sentence where it was. A client that can seek resumes from
`:played`; one that cannot asks for `:restart`, and the floor puts the
entry back at its place so the words are said again rather than lost.
Hold and solo are separate facts: `unsolo` never clears the hold,
`resume` never clears the solo, and a held floor's `:waiting` is still
the whole queue in the order it will be spoken.

## The clients

**Emacs** (`ui-workspace-speech`, `C-c w v`). A left side window by
default (`harness-workspace-speech-side`), shown and never selected, so
the waiting threads are beside the chat rather than inside it; the
workspace buffer carries the same lines inline, which is what a narrow
frame shows. The speaker is the existing voice path, not a second one:
`speech/synthesize` over ACP when the client has no synthesis command of
its own, the voice module's player, one cancellable process at a time.
It claims before it synthesizes and reports what happened, so the queue
moves only when the words really ended.

**Flutter** (`WorkspaceSpeech`, `WorkspaceSpeechPlayer`,
`WorkspaceSpeechPanel`). The controller reads the floor with the rest of
the workspace and follows `workspace/speech-changed`; a stale revision
is dropped. The player claims, says the entry through the `VoiceSpeech`
seam the clip provider already speaks through, and advances. A platform
test replaces the speech engine and the floor, so no audio is played and
no platform channel is loaded.

The panel is drawn as the last row of the chat column, between the
conversation and the message field -- not as a card above the chat. It
was a card first, and a review rejected it: on a page of its own it read
as a widget dropped onto the screen, with a gap between its heading and
its speaker and actions stranded at the far edge of a wide block. As a
band of the page it answers the question the composer below it answers
-- what does this message join -- and costs the conversation only the
height of its rows.

The band's first line is the speaker itself, so no heading sits above it;
the queue's size is a count at the end of that line, not a heading of its
own. A waiting thread is one compact row: its name, the amber word the
harness gives for why it waits (`Solo`), its words under it, and its own
`Solo` at the row's end, so an action is never further from its thread
than the row it belongs to. Every label is a short action; the states are
the person's words, not category nouns.

Every row's actions are one right-hand column, not each row's own offset:
`Skip` and `Hold` on the speaker's line, a waiting thread's `Solo` or
`Leave`, and the solo line's `Leave` all end on the band's right edge, and
a row with one action puts it under the speaker's `Hold` rather than
under its `Skip`. The column is one action cell wide -- the widest label
the band may show, measured from the text and the button's own padding at
the text size in force, so it follows a larger font instead of a guessed
number -- and every action is drawn in a cell of that width. Equal cells,
not a fixed row width: `Hold` and `Solo` are not the same word, and only
one width per action makes both edges of the last action line up. A long
thread name ellipsizes into what is left. A band too narrow to give the
words most of its width drops the shared cell and lets each row's actions
take what they need -- they still end on the same edge, and the words
keep their room. The phone's sheet is the same rows and holds the same
column.

A solo whose thread is in the queue shows its way out in that thread's
row; a solo whose thread is not in the queue gets a line of its own, so a
solo is never a state the person cannot leave. On a phone the band is one
strip line -- the speaker, `Solo` when the speaker holds it, the count
and `Skip` -- with the queue behind a tap, and the sheet names every
waiting thread with its own `Solo`.

## What the floor does not promise

The floor is one record with one speaker, and the claim serializes two
clients that claim in the same instant, so exactly one of them says the
words. It does **not** promise that a person with two devices hears
each utterance once *in time*: a device that reconnects after its claim
expired finds the entry cancelled `:why "Speaker lost"` and does not
replay it, but a device that was merely slow may still be finishing an
utterance the floor has already moved past. Nor does it promise
anything across harnesses: two harnesses each have their own floor.
There is no cross-device position: a hold keeps `:played` for the client
that held it, and a client that reconnects during a hold and cannot seek
starts the words over.

A thread the client may not see is not named: the panel draws what the
harness answered for this client's floor, and a thread that is not in
the workspace is not in the panel.

## Verification

- `lisp/modules/harness-workspace-speech-test.el`: 27 cases -- one
  speaker and a stable order, idempotent enqueue, monotonic revision,
  solo holding the others and interrupting, solo not interrupting the
  soloed thread, changing the solo target, advance and stale reports,
  visible cancellation, a removed thread, a removed thread's solo, the
  bounded queue, a lost speaker, one client claiming, clear, a restart
  reading the same floor, a reply offered once, a disabled floor, empty
  text, hold keeping the playing words, hold starting nothing, resume
  releasing one in order, restart on resume, hold and solo separate,
  hold surviving a cancel, a held utterance not aging out, resume
  recovering a lost holder, and the hold round-tripping through the
  store.
- `lisp/ui/harness-ui-workspace-speech-test.el`: 12 cases of rendered
  copy and tooltips, exactly, and the rules that keep a stale answer, a
  hold and another client's claim from talking.
- `harness_client/test/workspace_speech_test.dart`: 24 cases of the
  model, the player's claim/advance/hold/interrupt/failure paths, and
  the band's copy, keys, sheet and tooltips -- including the band's
  density (no heading gap over the speaker, a waiting row under 20
  points), every control's 36-point target, and the one action column:
  `Skip`/`Hold` and every waiting `Solo` share both edges at the
  ordinary and at a 150% text size.
  `workspace_speech_screenshots_test.dart` draws the real workspace page
  -- rail, conversation, band and composer -- on a desktop and a phone,
  in the populated, soloed, held, crowded and narrow states and at 150%
  text, and writes the pictures in `docs/evidence/workspace-speech/`.
- The full Emacs suite (`scripts/test.sh`), `scripts/lint.sh`, and the
  Flutter build check (`harness_client/tool/check_build.sh`), which
  compares its test run against the branch's base so a test that already
  failed there is not counted against this change.
