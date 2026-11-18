# The message when every close is reviewed

## What was asked

The harness already leaves the agent a message of its own when the user
closes the last thread of a task's review that has a sent comment
(`harness-patch-review-last-close-message`). The ask is the same thing
one step later: when the user has marked every close the agent made
reviewed, the agent should hear it, once, by the same path.

## What "all closed" turned out to be

There is no "all-closed" string in the harness. The transition the task
means is **per task, per review**, not across the task board: closing
the last thread of *one task's* review leaves that review with nothing
to answer, and the module leaves the agent a message as a draft of that
task's session. Its scope is a review's threads, and its delivery is the
review's drafts (`patch-review/send-replies`), sent by the user, never by
the harness.

So "all reviewed" is the same scope and the same delivery path: the
closes of one task's review, waiting for the user's look
(`change-review-thread-unreviewed-p`), all marked.

"Reviewed" is not "closed", "verified", "merged" or "done":

| Term | What it means | Where it lives |
| --- | --- | --- |
| Closed | The agent ended a thread in its answer | The thread's status |
| Reviewed | The user says they looked at that close | `:reviewed TIME` on the close's history entry |
| Verified | The user accepts a handed-in task | The task board |
| Merged | The branch went into main | The merge queue |

A close marked reviewed is no verification and no merge, and the message
says so by saying only what changed.

## The transition

The offer is the *transition*, not the state: an operation is the one
that offers the message when it is a `mark-reviewed` whose close waited
for the user and was not the user's own, and no thread of the review
waits afterwards (`harness-patch-review--last-reviewed-p`). That gives
the properties the task asks for without extra bookkeeping:

- **Partial review offers nothing.** One close marked while another
  waits is no transition.
- **The final mark offers one message.** The bulk mark sends one
  `mark-reviewed` per close through `patch-review/apply`; only the one
  that leaves none waiting offers it, so a bulk mark of ten is still one
  message.
- **No duplicates.** A `mark-reviewed` of a close already marked changes
  nothing (`change-review-dispatch` reports no change), so no offer is
  made; and keeping a draft that is already there, saying the same,
  announces nothing (`harness-patch-review--set-draft`).
- **Reload is no second message.** The draft lives in the state
  directory, so a harness that reloads has it still, and reading it
  again does not announce it again.
- **A reset allows a new one.** A close the agent makes afterwards waits
  again, which makes the message untrue: reading the drafts drops it
  (`harness-patch-review--draft-here`), and the mark of that close is the
  next transition, so a second message is offered then — as it should
  be.

## The shape of the change

The last-close message was a one-off: a table, a store document, a
method, a discard method, an event, and the send path. Duplicating all
of it for a second message would have doubled the paths a bug could hide
in, so the two are one kind of thing:

- **A kind** (`harness-patch-review--kinds`) is a plist: its message,
  its option, its store directory, its event, its name for the log, the
  function saying whether the review still leaves it true, and the
  function saying whether an operation is the transition that offers it.
- **The drafts** are kept by `(KIND . TASK-ID)` in one table, saved and
  read by one pair of functions, and announced by one function whose
  `pcase` names each event literally — so the module pages still find
  who emits what.
- **The send** reads both drafts after marking the replies, prompts
  each, and drops it; the result is `(:sent N :last-close BOOL
  :last-reviewed BOOL)`, which is additive for clients that read only
  `:last-close`.
- **Revalidation** after any change reads every kind: one that is no
  longer true goes, one that still is stays.

The Emacs UI does the same: one table of drafts by kind, one kind plist
with the method, the discard method, the event and the words, one
[Discard] button, and the drafts note counting them. The report splices
each message in as its own line above the files.

## What is not in it

- **The Flutter app.** It draws the last-close draft with its own model,
  controller state and widgets. Adding the second message there is a
  parallel change in Dart, and this checkout has no Flutter toolchain, so
  it could not be built or tested. The app is not broken by the change:
  it ignores the event it does not know, and its [Send drafts] goes
  through `patch-review/send-replies`, which sends both messages. The
  message simply does not appear on the phone until the app learns it.
  This is a known, stated boundary, not an oversight.
- **A task-board-wide message.** "Every task marked reviewed" is not a
  state the harness has: there is no per-task reviewed flag, and marking
  a close reviewed does not touch the task. Adding one would be a new
  notion of review, not the analogue of what exists.
- **A new option name.** `harness-patch-review-draft-on-last-close`
  keeps its name (and a value set under it) for the old message;
  `harness-patch-review-draft-on-last-reviewed` is the new one, on by
  default, and each turns off only its own message.

## How it is verified

`lisp/modules/harness-patch-review-test.el` adds thirteen tests: the
transition and its draft (text, sender, session, task, and that it says
neither "hand in" nor "closed/verified/merged"), partial review,
the user's own close, the bulk mark, marking twice, a reload, a new
close resetting it, unmarking, dropping it, the option off, a task in
review, the two messages waiting and going together, and a send with
nothing left to send. `lisp/ui/harness-ui-patch-review-test.el` adds
three: the message drawn in the report and sent with the drafts, the
[Discard] that drops it unsent, and the exact rendered words of the
drafts line and the echo area, one message and two.
