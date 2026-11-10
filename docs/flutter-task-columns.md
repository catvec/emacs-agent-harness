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
**Needs input lane first**, as a section of its own, then the **stages**,
one section per stage, every priority in each. The lane says why its tasks
are there; a card in it says the stage it stopped in and its priority. A
stage section holds the tasks of that stage that do not wait on the person,
and their cards say their priority.

The phone orders those sections by **what a person attends to first**, not
by the order a task travels:

  Needs input → Review → Active → Pending → Backlog → Merging → Done → Cancelled

A person opens the board to find what is blocked on them, then what is ready
for them, then what runs, then what waits for a slot, then what is over. The
workflow order (`Backlog → Pending → Active → Review → Merging → Done →
Cancelled`) is the wide board's, left to right.

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
lane the wide board already draws first: the two boards say the same thing
here, one with a row and one with a section.

The order of the sections under it is a phone's own question. A phone reads
down one list, and the list a person wants is in the order they act on it:
the work blocked on them, the work ready for their word, the work running,
the work waiting for a slot, the work that is over. The order a task travels
is how a wide board is read left to right, where every stage is beside the
others and the eye goes back and forth; read down a narrow screen, it puts
the finished work above the work at work, and the review a person has to
look at below both. The wide board is unchanged: its columns are still
`taskColumns`.

## What the board does

**Columns** are the seven stages in the order a task travels them. A
cancelled task is over, and is the last column. The order is
`taskColumns` in `lib/src/models/task.dart`.

**Phone sections** are `taskPhoneSections`: the Needs input lane, then
Review, Active, Pending, Backlog, Merging, Done, Cancelled. The stages are
the same ones `taskColumns` names, in the order a person attends to them;
the lane is not a stage. The two lists are separate on purpose: a wide
board's columns are the workflow, and its cells and drops follow
`taskColumns`, so the phone's order does not reach it.

Each stage keeps its own state in its section. Pending and Backlog are
presented one after the other, since both are work waiting rather than work
happening, but a task in the backlog is still a backlog task and one in the
queue is still queued: two sections, two `stageName`s, two sets of tasks.
Merging is a task in the merge queue: its work is done and nothing about it
is the person's to do, while the merge goes on without them. It follows the
stages that are being worked on or are waiting, and precedes Done.
Cancelled follows Done: both are over, and cancelled work is the least
urgent thing on the board.

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

The stages that hold a task come next, in the phone's order above, as
sections with every priority in each; a card dropped on a section moves its
task to that stage's state. A stage section holds only the tasks that do not
wait on the person, so the count beside a stage's name is the number of
cards under it. A stage whose tasks all wait on the person is not drawn
while no card is carried: the lane above says where they are, on their
cards. While a card is carried every stage is a section, so that one
holding nothing is a target too. There is no tab strip: the priority is a
fact about a task, not a way to look at the board, and the priority is on
each card.

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
- **Keep the workflow order on a phone.** Backlog and Pending above Active
  put two lists of untouched tasks over the work that is running, and Done
  above the backlog put the finished work in the middle of the scroll. The
  order a task travels says what happens to it; a phone's list is read for
  what to do next.
- **One "Waiting" section for Pending and Backlog.** They are different
  states to the harness, and a task's state is what the card and its drop
  targets act on: merged into one section, the count would be of two
  things, and moving a task between them would look like it had not
  moved. Adjacent sections say the same thing about their urgency and keep
  the states apart.
- **Put Merging with Review, before Active.** It is a task whose work is
  done and which the person has accepted, so it can read as "nearly
  finished" and sit by Review. But nothing is waiting for the person there
  — the merge queue runs on its own — while Pending and Backlog are still
  waiting for a slot. After them it reads as what it is: work in flight that
  the person is not holding up.
- **Change `taskColumns` to the phone's order.** That list is the wide
  board's columns and the order of the stages a card can be dropped on;
  reordering it for a phone would turn the desktop grid around, and the
  merges and drops with it. The phone has its own list,
  `taskPhoneSections`, and the wide board keeps the workflow's.

## What it gives up

- **The workflow order on a phone.** The sections are not the order a task
  travels, so a person who knows the workflow reads one list in another
  order. The wide board keeps the workflow, and the stage is on every card
  of the lane, so nothing is lost but the sequence: on a phone, Merging is
  after Pending and the backlog rather than between Review and Done.
- **The desktop grid's order on a phone.** The one scroll does not match
  the grid's columns, which is the price of a list read for what to do
  next; the two boards draw the same tasks and the same stages.
- **The Emacs board's order.** The Emacs task mode draws its sections "most
  urgent first" (`harness-ui-tasks--columns`): Requires your input, Ready
  for review, Merging, In progress, Pending, Backlog, Completed, Cancelled.
  The phone now agrees with it about the ends and differs in the middle:
  it leads with what waits on the person and ends with the finished and
  the cancelled work, but it puts the running work above the queue's and
  the backlog's where Emacs puts Merging first. The wide Flutter board is
  the workflow's. The Emacs board is unchanged.
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
  On a phone every finished task is in the Done or Cancelled section, last.

## The shape of the change

- `TaskController.forAttention` is the lane's tasks, the higher priority
  first (`forLane('needs-input')`); `forStage` is a stage's tasks that do
  not wait on the person, and `countForStage` still counts every lane of a
  stage, which is what the wide board's heading says.
- `TasksScreen`: `_TaskStages` draws `_AttentionLane` first and a
  `_StageSection` for each stage that holds a task, in `taskPhoneSections`'s
  order (`_SectionHeading` is their shared heading); `_StageSection` is
  still the phone's drop target, keyed `task-section-STAGE` so a test can
  say where it sits, and the lane is none. `_TaskBoard` takes the phone's
  `sections` as well as the wide board's `stages`, because the two orders
  are the two boards'.
- `TaskCard` says its priority when its board has no row for it
  (`showPriority`), and its stage when no heading above the card says it
  (`showStage`: the lane's cards). It no longer says `Needs input`: the
  lane does.
- `test/task_column_order_test.dart` pins the phone's order, the name and
  count of every section, the lane's place above the stages, the order of
  its cards, the card meta lines, that no card is drawn twice, that a
  section holding nothing is not drawn, and that the wide board is still
  the workflow's; `test/task_drag_test.dart` carries a card from the lane to
  a stage and onto a section that holds nothing;
  `test/task_board_order_screenshots_test.dart` draws both boards.
