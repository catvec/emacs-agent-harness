# The phone's board reads in the order a person attends to the work

## The decision

A phone's task board is one scroll of sections. They were drawn in the order
a task travels — Backlog, Pending, Active, Review, Merging, Done, Cancelled,
under the Needs input lane. They are drawn in the order a person acts on
them now:

```
Needs input → Review → Active → Pending → Backlog → Merging → Done → Cancelled
```

The wide board is untouched: its columns stay `taskColumns`, left to right in
workflow order, one lane a row. The phone has a list of its own,
`taskPhoneSections` in `lib/src/models/task.dart`, and `TasksScreen` hands
the phone board that list and the wide board `taskColumns`. `_TaskBoard`
takes both, so neither board derives its order from the other's.

## Why

The board exists to answer "what do I do now?", and a phone shows it as a
list read top to bottom. In workflow order that list led with two kinds of
work that nothing is happening to (Backlog, Pending), put the work that is
running under them, put the review a person has to look at under that, and
put the finished work above the last stage. On a wide board the same order
is right, because the eye compares columns side by side and the lane rows
carry the priority; down a narrow screen a person reads a sequence, and the
sequence should be the urgency.

The requested order is that urgency, and it is close to what the Emacs task
board already does with its "most urgent first" sections. The phone and Emacs
now agree on the ends -- what waits on the person first, the finished and
cancelled work last -- and differ in the middle: Emacs puts Merging before
the work at work, the phone after the waiting work (see "The states, and
what each section is" below).

## The states, and what each section is

A section is a stage of the harness's task record (`HarnessTask.stageName`),
except the first: Needs input is a **presentation of tasks waiting on the
person**, whatever stage they stopped in (`HarnessTask.needsInput`). The two
never overlap. `TaskController.forAttention()` returns the waiting tasks and
`forStage(stage)` returns the stage's tasks *that do not wait on the person*,
so a blocked task appears once, in the lane, and never in Review, Active or
Pending as well. A stage whose tasks all wait on the person therefore draws
no section at all while no card is carried.

| Section | What it holds | Why here |
|---|---|---|
| Needs input | every task waiting on the person | it is what the board is opened for |
| Review | tasks whose work is ready for the person's word | second only to being blocked |
| Active | tasks whose agent is working | nothing is needed from the person; they run |
| Pending | tasks in a project's queue, waiting for a slot | waiting, but the harness will start them |
| Backlog | tasks written up but not queued | waiting until a person queues them |
| Merging | tasks whose branch is in the merge queue | under way, but the queue runs it, not the person |
| Done | finished, verified work | over |
| Cancelled | stopped, then marked done, never merged | over, and of least use |

Pending and Backlog are presented one after the other but stay two sections:
they are two states of the harness, `stageName` reports each, and a card
dropped on one is the action of that state (`TaskMove`). Merging sits after
them rather than beside Review: its work is not waiting for a person, and
nothing in its section is anything but the queue's own progress. Cancelled is
after Done, as the requested order says, because finished-and-merged is worth
more than stopped-and-dropped.

Empty sections are not drawn, exactly as before: the board says nothing
about a stage that holds nothing (except while a card is carried, when every
stage is a drop target and must be visible). The Needs input lane is drawn
only when something waits on the person.

## What does not change

- **`taskColumns`.** It is the wide board's columns, and the stages a card can
  be dropped on reach the harness through `TaskMove`, which is keyed by stage
  name, not by position. Reordering it for a phone would turn the desktop grid
  around; the phone gets a second list instead.
- **Membership, counts and order within a section.** `forStage`, `forCell`,
  `countForStage`, `countForLane` and `_priorityFirst` are unchanged: every
  priority is in every section, highest first, ties in the harness's order.
  Only the sequence of the sections is different.
- **Drops and navigation.** A section is still `_StageSection`, a
  `DragTarget<HarnessTask>` for its stage wherever it is drawn; a tap still
  opens the task's conversation. The only new thing is a `ValueKey` of
  `task-section-STAGE` on each stage section, so that a test can assert where
  a section is rendered.
- **The wide board.** `_TaskGrid`, `_SwimLane`, `_LaneCell` and `_StageHeading`
  are untouched, and a wide-screen test pins the column order and the lane
  rows to `taskColumns` and `taskLanes`.
- **The Emacs board.** `harness-ui-tasks--columns` is untouched.

## Verification

- `test/task_column_order_test.dart`: `taskPhoneSections` is the requested
  order, covers `taskColumns` exactly once each, and `taskColumns` is still the
  workflow's. On a phone tall enough to draw everything: every section is in
  the order, with its exact label and count; within a section the higher
  priority is first; the waiting task is drawn once, in the lane; empty
  stages and the empty lane draw nothing; the board says `No tasks` when it
  holds nothing.
- `test/task_drag_test.dart`: a card carried from the lane to a stage, and one
  carried onto a stage section that holds nothing, with the section order
  asserted while the card is in the air.
- `test/task_board_order_screenshots_test.dart`: the phone's board (top and
  end) and the wide board, drawing the order and the grid.
- `test/layout_test.dart`: the one edge the sections and their cards keep,
  with the first section now Review.

## Alternatives

See the "Alternatives considered" section of
[flutter-task-columns.md](../flutter-task-columns.md), which this change
extends: keeping the workflow order on a phone, one combined "waiting"
section, Merging beside Review, and changing `taskColumns` itself are the
ones weighed and rejected.
