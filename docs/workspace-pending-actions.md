# Pending actions and episode status in the workspace

## The problem

A workspace episode could be running, or blocked on a permission or a
question, while its thread looked parked or silently stopped.  The
Emacs workspace buffer drew the divider, brief and messages, and the
Flutter screen did the same; neither drew the request the episode was
waiting on.  A user who saw no answer from a workspace message had to
discover *Open episode* to find the prompt that held the turn.

## What the workspace now shows

- Each thread names its live episode's state: `Running`, `Blocked ·
  Permission`, `Blocked · Question`, `Idle`, `Failed`, `Stopped`,
  `Inactive`, `Live` or `Parked`.
- The selected thread's pending requests are drawn above the composer
  in both clients, as the chat draws them: a permission prompt with
  its answers, or a question with its options.
- A blocked episode says what it waits on even before its request
  reaches that client.
- On a phone, where the header has no room for the thread subtitle,
  the state sits above the chat in the same words.
- A failed or cancelled last turn stays marked `Failed` or `Stopped`
  until the episode starts another turn.

## The shape of the change

### Harness view

`workspace/get` and `workspace/list` already read each live thread's
session.  They now add two keys to every thread:

- `:episode-status`: `running`, `blocked`, `idle`, `failed`, `stopped`,
  `inactive` or `parked`.
- `:pending`: the session's pending list, unchanged, so a client can
  draw what the episode waits on without opening its transcript.

The old `:state` (`live`, `waiting`, `parked`, `done`) stays, so older
clients keep working.  The episode's last stop reason is kept on the
thread and cleared when another turn starts or a new episode is made.
Only `error` becomes `failed` and `cancelled` becomes `stopped`; a
normal end is `idle`.

### Emacs

The workspace buffer reuses the shared pending module: the same panels,
answers, tooltips and keys as a chat.  It binds
`harness-ui-pending-session-id` to the selected thread's live episode,
so a panel answers that episode and never one selected before it.  The
buffer joins `harness-ui-pending-drawn-predicates`, which lets the
pending module own the ACP request for that episode and show it without
waiting for a list round trip.

`C-c C-c` or `harness-ui-workspace-send` answers a waiting question
first, as a chat's compose box does, instead of sending a new workspace
prompt that would only queue behind the blocked turn.

Reconciliation:

- `session/pending-changed` fills the store and sets the thread blocked
  or clears its card; a following fetch settles the exact status.
- `session/status`, `agent/turn-started`, `agent/turn-ended` and
  `session/deleted` refetch the thread's status.
- Every `workspace/get` reconciles the store with the view's
  `:pending`, so an answer from another client leaves no stale card.
- A reconnect runs the same session sync before the refetch.
- A thread switch rebinds the pending session and redraws; the card is
  keyed by request, and an answer after a switch is ignored unless the
  same request is still the selected episode's.

### Flutter

The workspace models `episode-status` and `pending`.  The screen gets
the app's `SessionController` for the active thread's live episode,
listens to it, and reads its pending list on attach and after a
reconnect.  The card itself is the extracted `PendingActionCard` that
`InteractionCard` now wraps, so the workspace and a conversation draw
and answer with one widget.

The card is fixed above the composer with a bounded height, so it
cannot push the composer under the keyboard.  It is keyed by the
request and only calls the session that showed it; a stale card after
a thread switch or another client's answer does nothing.

### Task board lookup

`task_list` gains an optional `project` directory.  It resolves the
path against the call's own directory and passes it to the existing
`task/list`, the same authorized read the board uses.  `all_projects`
still wins.  No filesystem access or directory grant is involved.

## Alternatives considered

- **Draw the cards only from the workspace view's `:pending`.**  That
  is enough after a fetch, but slow to show a request that arrives
  while the view is open; the session's pending list also lags an
  answer by a round trip.  The session controller and shared store
  give the card immediately and reconcile the view's list.
- **Open the episode behind the thread and draw that chat.**  It
  works, but loses the workspace's own thread context and asks the
  user to discover a separate view for a decision the chat already
  knows how to present.
- **Put the status only in the thread list.**  A phone hides the list
  behind a sheet; the selected episode's state must be visible without
  opening anything.
- **Treat every thread without a live session as parked.**  It is the
  old behavior; a failed or cancelled last turn then looks stopped with
  no explanation.  The last-stop mark keeps the reason until the next
  attempt.

## Safety

- No automatic answer: a request is only answered by a tap or key on
  its card, through the existing decision path.
- No broader grant, provider, credential, mode or global setting is
  changed by this work.
- A card is bound to one request and one episode; a stale card never
  answers another request or another episode.
- On reconnect and on every view fetch the client reconciles what the
  harness holds; a stale card is removed rather than left answerable.

## Tests

- Emacs: statuses, blocked labels, permission and question panels,
  thread switching, resolved cards, fetched and event reconciliation,
  send-as-answer, and the new-episode last-stop rule in
  `test/harness-ui-workspace-test.el` and `test/harness-workspace-test.el`.
- Flutter: preview statuses at desktop and phone widths, pending cards
  and their answers, thread switching, and exact copy in
  `test/workspace_screen_test.dart`; a connected fake harness covers
  held permissions and questions, another client's answer, reconnect,
  and exact status copy in `test/workspace_pending_test.dart`.
- Task board: the project filter and `all_projects` precedence in
  `test/harness-tools-sessions-test.el`.
