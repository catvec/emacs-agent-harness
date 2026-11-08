# The task board's columns and lanes

The Flutter app's task board is a swimlane board. Its **columns** are the
workflow a task travels, left to right:

  Backlog → Pending → Active → Review → Merging → Done → Cancelled

Its **rows** are lanes, top to bottom:

  Needs input → High priority → Medium priority → Low priority

A task is drawn in exactly one lane: what waits on the person is in the
Needs input lane whatever its priority; every other task is in the lane of
its priority. A task that waits on the person still has a workflow stage —
the one it stopped in, derived from the harness's `state` — and is drawn
under that stage's column.

## Why

The board used to be one row of columns only, with `needs-input` as the
first of them. That mixed two different things:

- **A stage** is where a task is in the workflow: queued, at work, waiting
  for review, merging, over. It is what a person reads left to right.
- **What a task waits on** is not a stage. A task can wait on the person
  while it is at work (a permission, a question), while it is queued (a
  pause), or while its write-up stopped. Drawing it as a column hid that it
  was still somewhere in the workflow, and put it beside stages it was not
  in.

Priorities had the same problem in the other direction: the board sorted
tasks by priority inside each column, so a person could not see a whole
priority at once, and a low-priority task at work sat under a high-priority
one with no lane to tell them apart.

## What the board does

**Columns** are the seven stages in the order a task travels them. A
cancelled task is over, and is the last column. The order is
`taskColumns` in `lib/src/models/task.dart`.

**Lanes** are `taskLanes`: Needs input, then High, Medium and Low priority.
A task's lane is `laneName` (`needs-input` first, else its priority), and
its stage is `stageName` (its column, except that a needs-input task takes
the stage of the state it stopped in: a paused or returned task waits in
Pending, a stopped turn is Active, a stopped write-up is in the Backlog or
Pending).

**On a wide screen** the board is a grid: the stage headings across the top,
one row per lane, and a cell for each lane and stage. The grid scrolls
horizontally through the stages and vertically through the lanes. Every
lane and every stage is drawn, empty or not, so the board always says what
its shape is.

**On a phone** the lanes are the tabs — Needs input, High priority, Medium
priority, Low priority — and the lane shown lists its stages as sections in
workflow order. The board opens on the Needs input lane when it holds a
task, else on the first lane that does; a task made from the sheet selects
its own lane.

The words are unchanged stage names (`Backlog`, `Pending`, `Active`,
`Review`, `Merging`, `Done`, `Cancelled`) and new noun phrases for the lanes
(`Needs input`, `High priority`, `Medium priority`, `Low priority`). A test
pins every rendered label and the order it is drawn in.

## What it gives up

- **The Emacs board's order.** The Emacs task mode draws its sections "most
  urgent first" (`harness-ui-tasks--columns`): Requires your input, Ready
  for review, Merging, In progress, Pending, Backlog, Completed, Cancelled.
  The Flutter board now follows the workflow instead, because that is what
  the board is for here; the two clients no longer draw the same order,
  though they draw the same tasks and the same columns. The Emacs board is
  unchanged.
- **One board for both shapes.** A phone cannot show a grid, so it shows one
  lane at a time and the stages as sections. The trade is a tap on a lane
  tab instead of a glance at every priority at once.
- **A needs-input card is not in its priority lane.** It is in the Needs
  input lane, because that is what it needs. Its priority is still on its
  card and in the harness's record.
- **Done and cancelled tasks sit in their priority lanes.** A finished
  low-priority task is in the Low priority row's Done column, not in a
  separate "over" row. That keeps one rule for every lane.
