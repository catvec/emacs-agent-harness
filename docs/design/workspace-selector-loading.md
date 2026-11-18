# The workspace selector: loading feedback, one choice at a time

## The problem

`harness-workspace` (`C-c h Y`) asked the harness for its workspaces and
then opened the choice.  Both halves were invisible: the command sent
`_harness/workspace/list` and returned, and the menu appeared whenever
the answer came back, from a promise callback, with no line saying
anything was happening.  On a harness that was still starting that is a
long silence -- Noah measured about twenty seconds -- and it read as a
command that had not worked.

Three things were wrong, and they are separable:

1. **No acknowledgment.** Nothing was said before the request went out,
   so every millisecond of the wait was silent.
2. **No way to give the wait up.** There was no command running to
   cancel: the answer opened a minibuffer from a process filter, so
   `C-g` had nothing to abort, and a person who changed their mind got a
   menu anyway, later, over whatever they were doing.
3. **Two invocations, two menus.** Each invocation made its own request
   and its own callback, so pressing the key twice answered the same
   question twice.

## What was measured, and what was not

The report named a latency, so the first question was which phase is
slow.  `scripts/analysis/bench-workspace-phases.sh` starts a throwaway
harness on a state directory of its own, seeds it through the harness's
own methods, and times a fresh client's phases against it.  These are
aggregate seconds from one machine, and they establish where the time
goes rather than what any one person's cold start cost.

| Phase | Empty state | 3 workspaces × 8 threads |
| --- | --- | --- |
| connect (object made) | 0.000 s | 0.000 s |
| authenticate (second, on purpose) | 0.031 s | 0.011 s |
| initialize | 0.018 s | 0.015 s |
| `session/list` (lean) | 0.010 s | 0.010 s |
| `workspace/list` | 0.010 s | 0.011–0.012 s |
| client total | 0.071 s | 0.047 s |
| harness exec → listening | 6.58 s | 4.80–6.19 s, three runs |

So the list is not the latency, and loading the workspace records is not
either: three workspaces of eight threads answer in about 11 ms, warm or
cold, and the number does not move with the record count in any way this
bench could see.  The one large phase is the harness process starting,
which the client cannot shorten and which the selector cannot see.  The
honest conclusion is that **the fix reduces no server-side work**; it
makes the wait visible, cancellable, and bounded, and it removes the
duplicate menus.  A cold start is still a cold start.

What this bench does not measure, and says so in its own header: the
`connect` line is the cost of making the connection object, since a TCP
connection opens in the background; `harness-acp-connect` authenticates
by itself when it has a token and the bench authenticates a second time
on purpose, so the first round trip is inside `connect`; and each phase
starts its clock after its request is built, so the per-phase lines are
round-trip and queue time and do not add up to the total.

## What the selector does now

The wait is a `recursive-edit`, which is the command loop's own: process
filters, timers, redisplay and `C-g` all arrive as they do for any
command, and nothing polls.  The shape is:

1. Say `Workspace selector · loading` **before** the request goes out.
2. Send `_harness/workspace/list`, and have its callback record the
   answer on the choice and end the wait.
3. If the answer is already here -- the in-process harness answers
   inside the call -- go straight on; a wait for an answer already in
   hand waits for nothing.
4. Otherwise wait in the `recursive-edit`.  At 0.2 s say `waiting`, so a
   slow harness does not look like a hung one, and at 60 s give up with
   `timed out · try again`.
5. When the wait ends, the **command** reads the choice and opens the
   menu.  A menu never opens from a filter, so it opens where a command
   opens one.

The choice is a struct (`harness-ui-workspace--choice`), not a plist,
because the guard is an identity check: `eq` on a plist stops working
the moment `setf` on one of its keys builds a new list.  That was a real
bug in the first draft of this change, and the tests caught it.

An answer is dropped, and no menu opens, when:

- the person gave the wait up with `C-g` (the `recursive-edit` ends with
  a quit, and the command says `cancelled`);
- a second invocation took over -- though by design a second invocation
  **joins** the first rather than taking over, so this is the path for a
  choice replaced some other way;
- the frame that asked is gone, so the menu would open where nobody is
  looking;
- a minibuffer of the person's own is in use when the answer arrives: a
  menu there would take it from them, so the command says `cancelled`
  instead.

A failure says what failed and that it can be asked again:
`Workspace selector · <what the harness said> · try again`, or
`connection replaced · try again` for the rejection of a connection the
UI let go of on purpose, which is not a failure to report.

The single-workspace and no-workspace paths are unchanged: one workspace
opens it, none creates the first.  Both are still reached through
`harness-ui-workspace--read-workspace`, which the tests hold.

## Copy

Every line is a noun phrase with a state, per `docs/ui-guide.md`:

| Line | When |
| --- | --- |
| `Workspace selector · loading` | on invocation, before the request; also for a second invocation that joins the first |
| `Workspace selector · waiting` | 0.2 s in, when the harness has not answered |
| `Workspace selector · timed out · try again` | 60 s in, with nothing to show |
| `Workspace selector · cancelled` | after `C-g`, or when a minibuffer of the person's own is in use |
| `Workspace selector · connection replaced · try again` | the connection was replaced on purpose |
| `Workspace selector · <message> · try again` | the harness answered with an error |
| `Workspace: ` | the minibuffer prompt, unchanged |

`try again` is the one imperative, and it names what the person can do
rather than describing the failure.

## Tests

`lisp/ui/harness-ui-workspace-test.el` holds the exact words and the
behaviour, one case per claim: the acknowledgment comes before the
request; the wait is the command loop's and nothing polls; `C-g` drops
the late answer; a second invocation asks once and says it is loading
twice; an answer for a dead frame opens nothing; a failure says so and
the selector can be asked again at once; the timeout ends the wait and
drops the answer that comes later; the menu opens with what the answer
holds and the choice opens it; a minibuffer in use is not taken; and the
single and none paths are unchanged.

## Alternatives considered

- **A timer that opens the menu when the answer arrives**, which is what
  the code did.  Rejected: it opens a minibuffer from a filter, and
  there is no command left to cancel.
- **Polling with `sit-for`/`accept-process-output`**, which
  `harness-await` does.  Rejected: it is for tests and batch use, and in
  the UI it holds the command loop instead of running it.
- **A message and nothing else**, which is what several pickers in this
  repository do (`Model catalogue loading…`).  Rejected as insufficient
  for the report: it leaves the surprise menu and the duplicate menus.
- **Making the list lean or cached**, to shorten the wait.  Rejected on
  measurement: the list is about 11 ms, so there is nothing to win, and
  a cache would answer with workspaces that may have changed.
- **A shorter timeout.**  60 s is chosen to be longer than a cold start
  on a busy machine (about 6 s here) and short enough that a broken
  harness does not hold the command indefinitely.  It is a `defconst`,
  so a person can change it.
