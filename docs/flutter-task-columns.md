# The task board's columns and lanes

The Flutter app's task board is a swimlane board on a wide screen. Its
**columns** are the workflow a task travels, left to right:

  Backlog → Pending → Active → Review → Merging → Done → Cancelled

Its **rows** are lanes, top to bottom:

  Needs input → High priority → Medium priority → Low priority

A task is drawn in exactly one lane: what waits on the person is in the
Needs input lane whatever its priority; every other task is in the lane of
its priority. A task that waits on the person still has a workflow stage —
the one it stopped in, derived from the harness's `state` — and is drawn
under that stage's column.

A phone has no room for that grid, and a board a person reads down a screen
is not improved by tabs for the rows. It draws one tabless scroll: the
**Needs input lane first**, as a section of its own, then the **workflow
stages** under it, one section per stage, every priority in each. The lane
says why its tasks are there; a card in it says the stage it stopped in and
its priority. A stage section holds the tasks of that stage that do not
wait on the person, and their cards say their priority.

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
one with no lane to tell them apart. The lanes are the answer on a screen
wide enough to draw them as rows; on a phone they were drawn as tabs, and
that is the part this board gave up (see
[why the phone has no priority tabs](#why-the-phone-has-no-priority-tabs)).

What waits on the person is a lane too, and it is the one a phone keeps. A
person opens the board to find what needs them; mixed into the stages it
was a card among the waiting work, sometimes below the fold, and the board
said `Needs input` on a card instead of leading with it. It is also the
lane the wide board already draws first: the two boards now say the same
thing, one with a row and one with a section.

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
its shape is. A card in the grid does not repeat its priority: its row
says it; a card in the Needs input row does, because its row is the lane
and not its priority's.

**On a phone** the board is one scroll. The Needs input lane is its first
section, drawn when it holds a task: a band the width of the screen in the
lane's colour, faintly, with a hairline above and below it and the page's
gutter for its content; then a heading with the lane's dot, its name and its
count, and its cards. The tasks in it are every task that waits on the
person, the higher priority first, then as the harness sent them. A card
there says its stage (`Active`, `Review`, …), so the workflow it is in is not
lost, and its priority; it is carried to a stage like any other card.

The stages that hold a task come next, in workflow order, as sections with
every priority in each; a card dropped on a section moves its task to that
stage's state. A stage section holds only the tasks that do not wait on the
person, so the count beside a stage's name is the number of cards under it.
A stage whose tasks all wait on the person is not drawn while no card is
carried: the lane above says where they are, on their cards. While a card
is carried every stage is a section, so that one holding nothing is a
target too. There is no tab strip: the priority is a fact about a task,
not a way to look at the board, and the priority is on each card.

The words are unchanged stage names (`Backlog`, `Pending`, `Active`,
`Review`, `Merging`, `Done`, `Cancelled`), the lane name (`Needs input`)
and the lane names as card words (`High priority`, `Medium priority`, `Low
priority`). A test pins every rendered label, the order it is drawn in, and
the whole meta line of a card.

## Why the phone has no priority tabs

The phone used to draw the lanes as a tab strip — Needs input, High
priority, Medium priority, Low priority — and one lane at a time under it.
That read as a way to look at the board rather than as where a task is
filed: a person opened the board, saw one priority's tasks, and could not
tell whether the others were empty or hidden behind a tab. A tab strip
elsewhere in the app does filter a list (the sessions list's `All`,
`Active`, `Needs you`), so the same shape said the wrong thing here.

Every priority is there at once now, in the stages. The priority is on the
card, which is where a person reads the task anyway.

## Alternatives considered

- **Keep the lane tabs.** The board already opened on the first lane that
  held a task, which is usually Needs input. That hid every other priority
  behind a tap and made the board's count look wrong; it did not make the
  tabs less confusing.
- **Mix what waits on the person into the stage sections.** That is what
  the board did before: a needs-input card came first in its stage, with
  `Needs input` on it. It left the lane with no place of its own, spread
  the person's work down the scroll by stage, and made the one thing the
  board exists for a detail on a card. The lane above the stages is what
  replaced it.
- **Stack the lanes as sections, the stages under each.** It keeps the
  swimlane words but repeats the stage headings once per lane, nests two
  kinds of section, and makes a long board of short lists. The lanes are a
  grid idea; a phone reads them badly. Only Needs input earns a section of
  its own, because it is the only lane a person acts on as a whole.
- **Show a task twice: in the lane and in its stage.** The same card in two
  places, two ways into it, and a stage that moves a task would have to
  move it out of a list it is also in. The stage is on the card instead.
- **Draw the Needs input lane empty too.** It would say "nothing needs
  you" at the top of every phone board. The tab badge already says zero,
  and a phone's board does not draw empty stages either; the lane appears
  when there is something in it.
- **Filter by priority with chips or a menu.** A filter hides tasks by
  default, which is the same complaint: the board no longer says whether
  the other priorities are empty. `All` would have to be the default, and
  the control would do nothing until it was changed.

## What it gives up

- **The Emacs board's order.** The Emacs task mode draws its sections "most
  urgent first" (`harness-ui-tasks--columns`): Requires your input, Ready
  for review, Merging, In progress, Pending, Backlog, Completed, Cancelled.
  The Flutter board follows the workflow instead, because that is what the
  board is for here; the two clients no longer draw the same order, though
  they draw the same tasks and the same columns. The Emacs board is
  unchanged.
- **A stage section shows a task out of its place.** A task that waits on
  the person is in the lane, not under its stage, so its stage's section
  does not hold it (and is not drawn when it holds nothing else). Its card
  says the stage, and the lane says it needs the person.
- **The lane is one list, not one per stage.** Its tasks are ordered by
  priority, not by where they stopped; the stage is on each card. A person
  who wants a stage's shape reads the stages below.
- **The lane rows on a phone.** A whole priority at once is still visible
  (the board shows every task), but not as a row of its own: the priority
  is on each card. A task that waits on the person is at the top of the
  board, above everything else.
- **A needs-input card is not in its priority's row on a wide screen.** It
  is in the Needs input row, because that is what it needs. Its priority is
  still on the harness's record, and on its card on a phone.
- **Done and cancelled tasks sit in their priority lanes on a wide
  screen.** A finished low-priority task is in the Low priority row's Done
  column, not in a separate "over" row. That keeps one rule for every lane.
  On a phone every finished task is in the Done or Cancelled section.

## The shape of the change

- `TaskController.forAttention` is the lane's tasks, the higher priority
  first (`forLane('needs-input')`); `forStage` is a stage's tasks that do
  not wait on the person, and `countForStage` still counts every lane of a
  stage, which is what the wide board's heading says.
- `TasksScreen`: `_TaskStages` draws `_AttentionLane` first and a
  `_StageSection` for each stage that holds a task (`_SectionHeading` is
  their shared heading); `_StageSection` is still the phone's drop target,
  and the lane is none.
- `TaskCard` says its priority when its board has no row for it
  (`showPriority`), and its stage when no heading above the card says it
  (`showStage`: the lane's cards). It no longer says `Needs input`: the
  lane does.
- `test/task_column_order_test.dart` pins the lane above the stages, its
  count, the order of its cards, the card meta lines, and that no card
  repeats the lane's name; `test/task_drag_test.dart` carries a card from
  the lane to a stage.
