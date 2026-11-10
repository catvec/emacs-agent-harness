# Dragging a task between the columns of the board

The task board of the Flutter client is a swimlane board: its columns are
the stages a task travels, and its lanes are what a task waits on and the
priorities ([flutter-task-columns.md](flutter-task-columns.md)). A wide
screen draws every column side by side, one lane a row; a phone draws the
lane of what waits on the person above the stages, and the stages as one
scroll of sections with every priority in each. Until now a card
was only a way into the task's conversation, and the actions that move a
task were on the bar of that conversation. This change lets a person carry
a card with a long press and drop it on another column, which runs the
harness action that puts the task in that column's state.

## The columns are states, not places

The harness derives a task's column from its record (`harness-tasks--column`):
Pending, Backlog, Needs input, Active, Review, Merging, Done and Cancelled.
A column is therefore not a box a card can be put in by hand; it is what
the harness says of the task. A drop is an action, and the board offers a
drop only where an action the harness offers can reach the column.

| From | To | Action | What it means |
|---|---|---|---|
| Pending | Active | `task/start` (Start now) | start it now, whatever the limit |
| Pending | Backlog | `task/park` (Move to backlog) | out of the queue, not started |
| Backlog | Pending | `task/queue` (Queue it) | let the queue start it |
| Backlog | Active | `task/start` (Start now) | start it now |
| Needs input (stopped) | Active | `task/retry` (Retry) | carry on where it stopped |
| Needs input (stopped) | Pending | `task/pause` (Pause) | back in the queue, held |
| Needs input (stopped) | Review | `task/force-review` (Put in review) | hand the work in by hand |
| Active | Pending | `task/return-to-pending` (Return to queue) | stop the turn, keep the work |
| Active | Review | `task/force-review` (Put in review) | hand the work in by hand |
| Active | Done | `task/complete` (Mark complete) | accept it without a merge |
| Merging | Done | `task/complete` (Mark complete) | accept it without the merge |
| Review | Active | `task/reject` (Send back) | feedback, then work again |
| Review | Merging | `task/verify` (Verify and merge) | accept it into the merge queue |
| Review | Done | `task/complete` (Mark complete) | accept it without a merge |

The action chosen for a target is the first one that `TaskActions` offers
for the task, so the board keeps one source of truth: if the harness does
not have the method, or the task's state does not offer the action, the
move does not exist and the column refuses the card. The mapping lives in
`lib/src/models/task_move.dart` (`TaskMove`), and
`test/task_move_test.dart` is its table.

**Needs input and Cancelled are not targets.** A task needs input because
its session waits on a permission or a question, or stopped part way: that
is its lane, not a column, and a person cannot put a task there by
dragging, and should not be able to. A task that waits on the person is
carried to a column like any other, and on a phone it is carried from the
lane above the stages. That lane is no target for the same reason: a card
dropped on it would have nowhere to go.
Cancelled is a task that was stopped and then marked done; the Stop action
leaves it in Needs input until the person marks it done, so a drop there
would not land where it was dropped.

**Review to Active is Send back, not Keep working.** The harness has both
(`task/reject` and `task/return-to-work`). Keep working leaves the task's
outcome as `conversing`, which the harness shows in Needs input until the
person writes to the session, and it keeps no feedback. A card dropped on
Active is meant to go back to work, so the drop is Send back: it asks for
the feedback, which the conversation's bar also asks for, and the harness
starts the turn.

## Carrying a card

Cards are `LongPressDraggable<HarnessTask>`; a column is a
`DragTarget<HarnessTask>`, which on a wide screen is every cell of the grid
(`_LaneCell`) and on a phone is a stage section (`_StageSection`). On a wide
screen a card is carried along the lane it is drawn in, so the cells it can
be dropped on are that lane's, and the drop reads the column it is over, not
the lane; a phone draws no lane rows, so every stage section takes any card,
and the lane of what waits on the person above them takes none. On a phone
the sections come in the order a person attends to the work rather than the
order a task travels ([flutter-task-columns.md](flutter-task-columns.md)),
which changes where a drop target is, not what a drop does: a section is the
same stage's target wherever it sits, and a section that holds nothing is
drawn as one while a card is carried. A long
press is the gesture on every platform: an immediate drag would take the
mouse drag that scrolls the board out from under the list, and a tap still
has to open the conversation. A carried card is drawn smaller than nothing
(exactly its size) and anchored below the finger (`_belowFinger`), so the
column it is over, and the word of the drop, stay in sight; the card where
it came from is dimmed.

The column under a card says what leaving it there would do, with the
action's own label (`Start now`, `Verify and merge`, `Send back`, …) beside
its name in place of its count, and a wash of the column's colour. A column
that has no action for the task draws nothing and refuses the card; the
drop is cancelled and the card goes back. The words are the labels of the
actions (no new sentence), and a screen reader hears `Move to another
column` as the card's hint.

A drop runs through `TaskActionRunner`, the same way the conversation's bar
runs an action: `Mark complete` asks first, `Send back` opens the feedback
sheet, and a refusal from the harness is shown in the board's error banner,
in the harness's words, while the board reads itself again. No action is
run directly from the board.

On a phone the stage sections are the targets; the lane above them, of what
waits on the person, is not one. While a card is carried the board shows
every column, including those that hold nothing, so a task can be moved to
an empty column; the sections the board does not build (a column below the
fold) are reached by scrolling the board before the card is lifted, since a
carried card holds the finger.

## Alternatives considered

- **Immediate `Draggable` with a drag handle.** A handle on every card
  adds chrome to a board whose cards are otherwise a way in, and the whole
  card is the target a person reaches for. `LongPressDraggable` keeps the
  mouse drag for scrolling and works on touch.
- **Accept every drop and say why it cannot happen.** A target that would
  say `Cannot move to Done` must accept the card first, which highlights
  every column as a target and makes an impossible drop look possible. A
  quiet refusal is the Kanban convention, and the valid targets are the
  ones that answer.
- **Wide screens only.** A phone shows its columns as sections one under
  the other, but they are still the columns, and the same drop works there;
  leaving it out would make the feature invisible on the client's first
  platform.
- **A "Move to…" menu on the card.** That is a menu, not a drag, and the
  card's tap already opens the conversation where every action is. The
  actions that the bar gained (`Move to backlog`, `Put in review`) are
  there for a task whose card is not being carried.

## What changed

- `TaskAction.park` (`task/park`) and `TaskAction.putInReview`
  (`task/force-review`), with their methods, controller calls, icons and
  runner cases. They are offered where the board in Emacs offers them:
  Pending gets `Move to backlog`, Active and a task that stopped part way
  get `Put in review`.
- `TaskMove` maps a target column to the action, for the board and for the
  tests; `TaskActions` remains the source of what the harness offers a
  task.
- `TasksScreen`: `_TaskBoard` knows the carried task (so a phone can show
  every column), `_LaneCell` and `_StageSection` are the two kinds of drop
  target, `_DraggableTaskCard` carries a card, and `_moveTask` runs the
  chosen action through `TaskActionRunner`.
- `HarnessTabStrip` lost its optional `tabWrapper`, which existed for the
  board's lane tabs: the board has no tabs now, and nothing else wrapped a
  tab.

## Pictures and checks

The test `task_drag_test.dart` carries cards between columns with real
long-press gestures, checks the calls the harness receives, the refused
drops, the send-back sheet and the phone's sections.
`task_drag_screenshots_test.dart` draws the wide board and the phone's
board with a card in flight, and writes `task-board.png`, `task-board-drag.png`
and `android-task-drag.png` to the client's `screenshots/` directory; their
drop labels are the only new interface words.

To carry a card oneself, `scripts/demo-task-drag.sh` serves the client,
built for the web, against the preview harness
(`tool/mock_harness_server.dart`), at `http://127.0.0.1:8090/demo.html`,
with the board already connected. A long press there is a mouse press
held still, and the column under the pointer says what the drop does.
