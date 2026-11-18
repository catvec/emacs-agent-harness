# Workspace thread mediation, provenance and message reassignment

Design note, November 2026. **Implemented.** This page is the design for a
workspace whose person stays in one conversation while the harness routes each
exchange to the thread that should handle it, shows where every message came
from, and lets a message be moved to the right thread after it was sent.

## The problem

A workspace already had threads, episodes and one timeline. Three things were
missing once the routing existed:

- A message the router put in another thread than the one the person picked
  read as if it had always belonged there. The timeline could not say which
  thread an exchange began in, through which surface it arrived, or which
  thread was answering it.
- What waits to be sent lived only in each session's queue, invisible to the
  person in the workspace: a message written while a turn ran could not be
  seen, so it could not be judged, withdrawn or moved.
- A message that went to the wrong thread could not be corrected. The only
  remedy was to write it again in the right thread, which left the wrong
  thread working on it.

## What this design decides

### One backend operation, two clients, one tool

Reassignment is one bus method, `workspace/reassign`. Emacs, Flutter and the
model-facing tool (`workspace_reassign`) all call it; none keeps its own idea
of where a message is. The tool resolves the words of a request into a node
and a thread id and refuses when a name fits more than one thread, so the
model asks rather than guessing. The inbox is one bus method, `workspace/inbox`,
read where the messages stand. No client keeps a second queue, and no operation
is implemented twice.

### Provenance is recorded, never inferred

When the harness records a user message it writes three facts onto the
timeline entry: `:origin` (the thread the words were addressed to), `:handling`
(the thread whose episode answers) and `:profile` (the surface they arrived
through, `text` by default). The router may put the words in another thread; a
reassignment changes `:handling` afterwards and records `:reassigned`, so the
original thread is still named. An assistant message takes the provenance of
the thread it answers in.

Nothing is guessed from the text. A client reads the entry it was given, and an
entry written before provenance existed reads as its own thread through its own
profile: the harness fills what an old entry does not say
(`harness-workspace--entry-provenance`), so a client sees one shape from every
entry and an honest legacy state rather than a wrong label.

### The words are nouns and noun phrases

The label is only drawn when there is something to say. A message from the
thread that handles it, through the workspace's own profile, says nothing: the
conversation is already plain. Otherwise the label names the origin thread by
its title, and the profile when it is not the default. A reassignment names the
thread it went to and who moved it, so a person's decision reads differently
from the mediator's.

### Moving a message

A reference is a plist with `:node` or `:queue`, the string `last`, or the text
itself. A client sends the node of the message under point, so a message with
the same words as another is never the one moved. `last` is resolved by the
harness to the last user message the workspace shows, not to the latest
assistant output.

What happens depends on what has read the message:

| State | What happens |
| --- | --- |
| In a session's queue | Leaves that queue and is queued in the target's, so the model never sees it in the wrong thread. |
| Held as steering by a running turn | Withdrawn and queued in the target's. |
| The transcript already holds it | Its text is forwarded to the target as a message that names the thread it came from; the origin keeps its own outcome. Nothing is deleted or claimed to have moved. |
| Nothing holds it any more | Answered `stale`, with `uncertain` delivery. No blind resend. |
| The target session cannot be read | Answered `unreachable`, with `uncertain` delivery. |
| The same request again | Answered as the first answer, with `repeated`: a second client does not send twice. |

The answer is `(:status :thread :session :node :text :origin :delivery :why)`.
The statuses are `queued`, `waiting`, `forwarded`, `repeated`, `stale` and
`unreachable`; the delivery is `queued`, `delivered` or `uncertain` and says
what became of the copy in the thread the message was written in.

"The same request" means the same message *and the same target*: the target is
part of the key a repeat is found by, so moving a message to a second thread is
a new reassignment that happens, not a repeat answered from the first one's
record. The 50 newest records are kept; a repeat older than that is resolved
from where the message stands now.

Reassignment does not pin future messages to the target, open another chat,
change the voice floor, undo work already done or transfer task ownership.

### The inbox

`workspace/inbox ID OPTS` reads each session's own queue and the messages its
running turn has not taken. Nothing is copied. The scope is `workspace` (every
thread), `thread`, `session` or `all` (every workspace's threads). Each item is
`:session :workspace :workspace-name :thread :title :text :at :state :why`, and
the state is `queued`, `waiting` or `unavailable`.

An unreadable session is one item in the `unavailable` state, not an empty
inbox: an empty inbox and an unreadable one are different facts, and a person
acting on the first would miss the second. The answer carries `:name` (the
workspace's own name), `:counts`, `:threads` (each thread with items and its
counts) and `:revision`, which moves with every change a client should notice.

`workspace/inbox-changed` is emitted when a session's queue or steering
changes, so a client showing the inbox reads it again. A client not showing it
does nothing.

### Notifications at a cutoff

Several threads can finish within moments of each other. One notification per
reply would stack up in the notification centre and say the same thing twice.
A reply that is ready waits for `harness-workspace-notification-cutoff` and the
workspace sends one notification naming every thread whose reply is ready; a
thread that finishes after it goes notifies on its own. A reply whose episode
the person is already reading is not news and is left out of the words.

### Opening a thread is not routing

Ordinary routing and clarification change the handling thread inside the one
conversation; they call no display tool. An explicit request such as "open the
kitchen thread" invokes the `workspace_open_thread` tool, which asks the user's
Emacs to show that workspace with that thread selected. Opening starts no
episode, sends no message, copies no state and transfers nothing. It is offered
to workspace episodes only.

## Alternatives considered

**A routing judge on every message.** Refused. The workspace agent is already a
model reading the message; a second model deciding what to do with it doubles
the cost and the latency and can disagree with the first. Triage is the
agent's ordinary work, and an irrelevant snippet can produce no dispatch.

**A separate inbox store.** Refused. A copy of each queue would have to be
reconciled with the real one on every send, withdraw and answer, and the
reconciliation is where duplicate sends come from. Reading the queues where
they stand makes the inbox correct by construction.

**A client-side reassignment.** Refused. Two clients acting on the same message
would each send it. One method, with the repeat answered from its own record,
is what makes a second client harmless.

**Replaying a delivered message into the target.** Refused. The transcript
cannot be retracted, so a delivered message is forwarded as corrected context
that names the thread it came from; pretending it had moved would claim an
outcome the harness cannot deliver.

**Inferring provenance from the text.** Refused. A message naming a thread is
not a message from it, and a profile is not a model or a provider. Only the
recorded facts are drawn.

## The shape of the change

- `lisp/modules/harness-workspace.el`: provenance on recorded messages
  (`harness-workspace--record-message`, `--entry-provenance`,
  `--origin-label`, `--reassigned-label`), `workspace/inbox`,
  `workspace/reassign`, the reassignment record, the notification cutoff,
  `workspace_open_thread` and `workspace_reassign`.
- `lisp/modules/harness-agent.el`: a caller's `:meta` travels onto the queued,
  steering and held node it becomes, so provenance survives the queue.
- `lisp/ui/harness-ui-workspace.el`: the origin and reassignment lines in the
  timeline, `C-c w i` and the `Inbox` button for the inbox buffer, `C-c w r`
  for `Reassign`, and the fixed `workspace` view a tool opens.
- `harness_client/lib/src/models/workspace.dart`: the entry's provenance and
  `WorkspaceInbox`, `WorkspaceInboxItem` and `WorkspaceReassignment`.
- `harness_client/lib/src/services/harness_api.dart`: `workspaceInbox` and
  `reassignWorkspaceMessage`.
- `harness_client/lib/src/state/workspace_controller.dart`: `loadInbox`,
  `reassign`, and reading the inbox again when `workspace/inbox-changed`
  arrives.
- `harness_client/lib/src/ui/screens/workspace_screen.dart`: the origin and
  reassignment labels, the `Inbox` sheet with its scopes and states, and
  `Reassign` on a message's own row.

## Copy inventory

Interface copy is nouns, noun phrases and adjectives; these are the exact
strings the tests assert.

**Workspace header (Emacs):** `Inbox` (tooltip `The messages waiting in each
thread's queue`), beside the existing `Tasks`, `New thread`, `Episode`, `Stop`,
`Refresh`, `Graph`, `Workspace computer`, `Resources`.

**Timeline labels (both clients):**

| State | Words |
| --- | --- |
| Own thread, own profile | nothing |
| Another thread began it | `From <thread>` |
| Another profile as well | `From <thread> · <profile>` |
| Another profile only | `From <profile>` |
| Moved afterwards | `Reassigned to <thread> · <by>` |
| Reassignment line (Emacs) | `Reassigned <from> → <to> · <delivery>` |
| Reassignment line (Flutter) | `Reassigned from <from> to <to> · <delivery>` |

**Inbox (Emacs):** header `Inbox · <workspace name>`, `Scope · <scope>`, the
counts `<n> queued · <n> waiting · <n> unavailable` (only the non-zero parts),
the scope buttons `Workspace` `Thread` `Session` `All`, the row state words
`Queued` `Waiting` `Unavailable`, a row of another workspace prefixed
`<workspace> · `, the empty state `No messages waiting`, the loading state
`Inbox · loading` with `Loading…`, the failure state `Inbox · unavailable` with
the reason and `Retry`. Keys: `g` refresh, `s` scope, `q` bury. Tooltips:
`Read the inbox again`, `Choose what the inbox covers`, and on each scope
button what that scope covers: `Every thread of this workspace`, `The thread in
view`, `The episode of the thread in view`, `Every workspace`.

**Inbox (Flutter):** title `Inbox · <workspace name>`, `Refresh`, the scope
chips `Workspace` `Thread` `Session` `All`, the row state words `Queued`
`Waiting` `Unavailable`, a row of another workspace prefixed
`<workspace> · `, the unavailable reason `Session unavailable`, the empty state
`No messages waiting`, the failure state `Inbox · unavailable` with the reason
and `Retry`. Each chip's tooltip names what that scope covers, in the same
words as the Emacs buttons: `Every thread of this workspace`, `The thread in
view`, `The episode of the thread in view`, `Every workspace`.

**Reassignment results (both clients):**

| Status | Words |
| --- | --- |
| `queued` | `Queued · <thread>` |
| `waiting` | `Waiting · <thread>` |
| `forwarded` | `Forwarded · <thread> · <delivery>` |
| `repeated` | `Repeated · <thread>` |
| `stale` | `Stale · <reason>` |
| `unreachable` | `Unreachable · <reason>` |

The Flutter client writes the reassignment line with the word `to` rather
than an arrow: the bundled fonts do not all carry `→`, and a missing glyph
reads as a box. Emacs draws it in a text buffer whose font has the glyph.

**Refusals:** `No message here`, `No thread`, `Already in <thread>`.

**The open-thread tool:** label `Open thread`; a success reads
`Opened <thread> · <status>`; a failure names why nothing opened.

**The reassign tool:** label `Reassign message`. Its answer is the status and
thread a client shows, followed by one clause saying what became of the
message: `Queued · <thread>. The target reads it next; the origin never did.`,
`Forwarded · <thread> · <delivery>. The origin already read it, so its text was
sent on as corrected context; nothing was retracted.`, `Repeated · <thread>. An
earlier request for this message already answered; nothing was sent again.`,
`Stale · <reason>. Nothing holds the message any more, so it was not sent
again.` A name that fits two threads is refused: `No thread <name> in workspace
<workspace>.` A tool's description and answer are what the model reads, not
interface copy, so they are prose; the status word and the thread in the answer
are the same words the two clients draw.

## What is not built

- The thread-opening tool asks the user's Emacs. The Flutter client has no
  endpoint a tool can ask, so an explicit open there is the navigation the app
  already does, and the tool answers honestly when no Emacs is attached.
- Reassignment does not replay a delivered message, undo a turn, or move a
  message between workspaces.
- Voice routing and speech output are unchanged: the audio pipeline delivers
  the recognised transcript to the destination it was given, and the workspace
  agent interprets it as ordinary input.
- The multi-thread speech floor, its waiting area and solo controls belong to
  t-5d513tj3, not here; this branch adds no speech queue, no waiting-speaker UI
  and no second playback path.

## How it was checked

- The full suite and the lint run on the committed tree; the Flutter build
  check (`harness_client/tool/check_build.sh`) passes for the commit the
  branch ends on, with the app's own 21 pre-existing test failures unchanged
  from `53f55679c6d1`.
- The pictures in `docs/evidence/workspace-thread-mediation/` are of two kinds
  and each file says which: two are photographs of a running Emacs frame, the
  rest are drawn from the buffers and widget tests themselves.
- What the live frame could not show here: the dev instance's module chain did
  not start `provider`, `session`, `agent`, `logseq`, `tools` and
  `workspace-knowledge` by itself, so the workspace module reported
  "requirements not ready" until they were started by hand. The inbox therefore
  read the workspace record of a process that held no live episode, and drew
  `No messages waiting` while the queue that was read by hand held two items.
  The inbox's three states, its scopes and its counts are covered by the
  suite and by the drawn pictures; the live picture shows the header, the
  scopes and the empty state only.
