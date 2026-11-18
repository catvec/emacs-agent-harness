# Voice where there is no conversation: the box says what it composes into

Design note, November 2026.  Two reports, one cause:

- the task board's compose box said `Voice · no session`, offered no Start,
  and `C-c v` refused — although the voice pipeline had started at login;
- a workspace's compose box showed Start, and pressing it only refreshed the
  controls; `C-c h V v` did not enable voice mode there.

Both are the same mistake: the live transport asked a box *who it was
talking to* by reading two buffer-locals (`harness-ui-session-id`,
`harness-ui-workspace--id`), and a box that has neither was declared
"no session".  But a compose box always composes into something.  A board's
box composes a task, a popout's box answers the item it shows, a workspace's
box composes into its selected thread.  Only one of those three is a session.

## What the change decides

**A box says what it composes into, and the transport asks the box.**
`harness-compose-context` returns a plist:

```text
(:kind session   :session S            :name "what the UI calls it")
(:kind workspace :workspace W :thread T :session S-or-nil :name ...)
(:kind draft     :name N)
```

- `:kind session` — the words are a message to that session.
- `:kind workspace` — the words go through `_harness/workspace/prompt` to that
  thread; the workspace's own agent does the work, and no second model is asked
  to interpret the words.
- `:kind draft` — there is no conversation behind the box.  The words are the
  box's own text, and its own submit is what sends them.

A host names its box with `harness-compose-setup :context` (the chat, the
workspace, the board, a popout).  A host that names nothing gets nil, and the
transport falls back to the buffer's own locals — which is how a chat and a
workspace have always said where their words go, and keeps every other host
working unchanged.

**A draft is a target.**  `harness-voice-live--target-p` asks the route, and
every live compose box has one, so the board's box and a popout's draw the same
controls a chat's does: `Live · Off · [Start] · [Transcript] · [Setup]`.
`Voice · no session`, its tooltip, and the two refusals in
`harness-voice-dictate` and `harness-voice-hold` are gone.

**A dictation into a draft is dictation, not delegation.**  A delegation whose
route is a draft is inserted at the end of that box, in the transcript's own
`Draft` section, and answered to the sidecar with no text and no turn: nothing
is sent to any session, no agent turn runs, and the call keeps listening.  This
is the WAV dictation's semantics — the words become the draft — with the live
sidecar in front of it.

**A draft that is gone loses nothing.** If the box closed, or stopped
composing a draft, before the transcript arrived, the words and a reason
(`Draft · no box`) go into the transcript instead of into a message
the person did not speak into, and the call goes on.

**A move between two drafts is a move.** Two drafts share a kind and name no
session, workspace or thread, so `--route-same-p` compares the box for a draft:
selecting the popout's box while the board's was the target raises the route's
generation, and a burst spoken in the board's box is dropped as `retargeted`
rather than landing in the popout.

**A draft of another purpose in the same box is another draft.** The board
reuses one buffer for every draft it composes: a new task, a search, an edit
of a task's prompt, an answer to its question, feedback on its write-up, a
message to its session. Comparing the buffer alone therefore calls a search
and a new task the same target, and a burst spoken for the task would be
inserted into the search that replaced it. A draft's context therefore carries
`:identity` — a value, compared with `equal`, naming *which* draft it is — and
a draft route carries it as `:draft`. `--route-same-p` requires the buffer and
the identity, `--draft-box` checks the identity before inserting, and a box
that now composes another draft reports the words as `replaced` rather than
`no box`. A popout's identity is its key. A host that names no identity keeps
the buffer-only comparison, so no other surface changes.

**The same purpose, replaced, is also another draft.** A purpose is not the
whole identity: submitting a new task empties the box back to a new task, so
the target after a submit is the one it had before, and a purpose-only identity
would call the empty box the very draft the spoken words went into — letting
them land in the next task. The board's identity therefore also carries a
lifecycle nonce, `harness-ui-tasks--compose-nonce`, raised by
`harness-ui-tasks--set-compose` and by nothing else. That is the one place the
board replaces what its box composes into: a submit, a reset (`C-c C-k`), a
search opening or leaving, an edit, a reply, feedback. Typing, a redraw and the
Submit / Refine / Plan toggle do not go through it, so they leave the identity
alone and dictation into the box that is still there is never dropped.

## The alternatives rejected

**Identify a draft by its purpose alone.** It reads as sufficient until the
box is reused for the same purpose: a submit returns to a new task, and the
empty box then looks like the draft the words were spoken into. The review's
probe — `Before=(draft)`, `After-submit-reset=(draft)`, `route-same=t` — is
exactly this. The purpose says *what* the box does; the nonce says *which*
time it has done it.

**Identify a draft by its text.** The text is empty both before the words are
spoken and after a submit, and a dictation changes it, so it would make every
utterance a move.

**Give the board and a popout a session.**  That would route a task's words
into an unrelated chat, which the report explicitly forbids, and the board's
submit would then have two paths to the same task.


**Keep the old refusal and only fix the workspace.**  That leaves the surface
the person actually reported — the board — unable to take voice, and it keeps
two predicates for "can this box start a call": the controls' and the start's.

**Make the draft route send through the session machinery with a nil session.**
It would run a turn with nowhere to go, and the pipeline's turn accounting
would report a turn that never existed.

**Insert at the onset's offset in the draft.**  A draft that changed while the
words were being transcribed has no offset to trust; appending is what a
dictation tool does, and the box is where the words go.

**Compare the draft's displayed name instead of an identity.** A name is copy,
not identity: two purposes can be titled alike, a title can change without the
draft changing (a popout's, for one), and a name is not stable enough to hold
a generation's worth of meaning. The identity is a value the host owns.

## The shape of the change

- `lisp/ui/harness-ui-compose.el`: `harness-compose-context-function` and
  `harness-compose-context` (a draft's `:identity`); `harness-compose-setup
  :context`.
- `lisp/ui/harness-ui-chat.el`, `harness-ui-workspace.el`, `harness-ui-tasks.el`,
  `harness-ui-popout.el`: each host's `--compose-context`, asked on every call so
  a target can move (a board's box composing a message to a task names that
  session; a workspace's box names its selected thread; a draft names which
  draft of its box it is).
- `lisp/ui/harness-ui-tasks.el`: `harness-ui-tasks--compose-identity` and
  `harness-ui-tasks--compose-nonce`, the board's one box's identity across the
  purposes it is reused for and the drafts it is replaced with.
- `lisp/ui/harness-ui-voice-live.el`: the `draft` route kind in `--route` and
  `--route-of-buffer` (with `--route-of-locals` as the fallback),
  `--route-draft` in `--route-set`, `--target-p`, `--route-same-p`,
  `--controls` (no non-target branch), `--dispatch` and `--delegate-next` (a
  draft job is inserted and answered, never queued as a turn),
  `--delegate-draft`, `--draft-box`, `--draft-lost-reason`, `--draft-lost`,
  and the `Draft` transcript section.
- `lisp/ui/harness-ui-voice.el`: `harness-voice--mode-available-p` replaces the
  session-id test in `harness-voice-mode`, `harness-voice` and
  `harness-voice-toggle`; the two "no session target" refusals are removed.

## Verification

- `harness-ui-voice-live-draft-box-is-a-target-with-start` pins the exact
  controls copy and both tooltips, and asserts no `no session` anywhere.
- `harness-ui-voice-live-draft-box-starts-the-call-here` starts through `C-c v`
  in a real sidecar process: the box is the target, no chat opens.
- `harness-ui-voice-live-draft-box-mouse-press-starts-the-call` starts it
  through the mouse press, the other entry point that used to refuse.
- `harness-ui-voice-live-running-pipeline-takes-the-board-dictation` is the
  reported case: a call on a pipeline already running, moved to the board's
  box, which dictates into the draft and never starts the pipeline again.
- `harness-ui-voice-live-draft-takes-the-dictation-as-its-text` speaks a
  delegation into the box and asserts the box's text, the empty result, no
  session prompt, and the `Draft` transcript section.
- `harness-ui-voice-live-draft-closed-keeps-the-words-in-the-transcript` and
  `harness-ui-voice-live-draft-switch-drops-the-burst` cover the two races.
- `harness-ui-voice-live-two-drafts-are-two-targets` covers a move between two
  drafts.
- `harness-ui-voice-live-same-buffer-drafts-are-two-targets` covers the same
  buffer composing another draft: the generation rises, and typing in one
  draft does not move the route.
- `harness-ui-voice-live-following-into-another-purpose-drops-the-burst` is the
  race the review reported: the person speaks at the board's new-task box,
  then switches that box to a search, and the burst is `retargeted` instead of
  being inserted.
- `harness-ui-voice-live-draft-replaced-keeps-the-burst-out` and
  `harness-ui-voice-live-draft-replaced-keeps-the-words-in-the-transcript`
  cover the same replacement from the other side: nothing is inserted, and
  words that arrive afterwards are kept with `replaced`.
- `harness-ui-voice-live-draft-kept-identity-takes-the-dictation` proves
  ordinary edits inside one target still take their dictation.
- `harness-ui-tasks-live-voice-box-switch-is-a-move` covers the real board:
  `harness-ui-tasks--set-compose` to a search, then to an edit, is a move in
  the board's own buffer.
- `harness-ui-tasks-live-voice-box-names-which-draft-it-is` pins the board's
  identity: a redraw, a keystroke and the mode toggle leave it alone, and each
  purpose of the box changes it.
- `harness-ui-tasks-live-voice-submit-reset-is-a-move` is the lifecycle race:
  after a submit the target is the one the box began with, and the nonce makes
  it another draft, so the route rises and pending speech is dropped.
- `harness-ui-tasks-live-voice-reset-keeps-typing-in-the-same-draft` is its
  other half: typing, a redraw and the mode toggle do not move the route, and
  the dictation still lands.
- `harness-ui-voice-live-submitted-draft-keeps-its-burst-out` covers the same
  submit at the transport: nothing enters the empty replacement, and the words
  are kept in the transcript with `replaced`.
- `harness-ui-compose-context-names-which-draft-of-one-box` covers the API:
  a host that names an identity gets it, a host that names none is unchanged.
- `harness-ui-tasks-live-voice-box-starts-and-dictates` and
  `harness-ui-tasks-live-voice-message-goes-to-the-task-session` cover the real
  board: Start and a dictation that becomes a submitted task, and a message to a
  task that routes to that task's session.
- `harness-ui-workspace-live-voice-*` covers the workspace: voice mode without a
  session id, the entry points starting in place, and a dispatch through
  `_harness/workspace/prompt`.
- `harness-ui-compose-context-*` covers the API itself: a host that names
  nothing answers nil, the host is asked each time, and a redraw does not move
  the target.

Every suite is synthetic: a scripted sidecar process and a demo provider, no
microphone and no speech model.

## Interface copy

The inventory, written before the code and checked against the rendered
text afterwards.  Every item is a noun, a noun phrase or an adjective;
the only prose is in this document.

| Where | Before | After |
| --- | --- | --- |
| Controls, a box that composes a draft | ` Voice · no session · [Setup]` | ` Live · Off · [Start] · [Transcript] · [Setup]` |
| Controls, status tooltip | `Live voice · no session target` | `Live voice status` |
| Controls, Start tooltip | (no Start) | `Live voice · sidecar session` |
| Echo area, `C-c v` and the press | `Live voice · no session target` | (removed: the call starts) |
| Status while a draft is the target | — | `Live · Listening · Task board` |
| Route names | `Session`, a thread title | `Task board`, `Task message`, `Search`, `Chat`, `Popout`, `Draft`, `Workspace` |
| Transcript section | — | `Draft` |
| Notice, a draft that is gone | — | `Live voice · Draft · no box` |
| Notice, a draft the box replaced | — | `Live voice · Draft · replaced` |

Exact rendered copy is pinned by `harness-ui-voice-live-draft-box-is-a-target-with-start`
(controls and both tooltips, and no `no session` in them),
`harness-ui-tasks-live-voice-box-starts-and-dictates`,
`harness-ui-workspace-live-voice-mode-without-a-session` (the same controls
line in a workspace's box),
`harness-ui-voice-live-draft-closed-keeps-the-words-in-the-transcript` (the
`no box` notice) and
`harness-ui-voice-live-draft-replaced-keeps-the-words-in-the-transcript` (the
`replaced` notice).  The live dev harness draws the same text; the screenshots
that show it are in the hand-in evidence, not in this repository.
