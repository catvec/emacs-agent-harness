# The hand-in is the call

## The problem

A task's session drew its hand-in twice.  The transcript had the
`hand_in` call, and under the transcript a review banner drew the same
report, the same changes and the same threads again.  The call was kept
folded while the banner showed, so the reader saw one copy of the work,
but it was the second one: the review sat at the bottom of the session,
apart from the call that made it, and it had a look of its own -- a panel
on the review's background, with the compose box under it.

The reader had to know that the two were the same thing, and the session
grew a special surface for one kind of call.

## What it is now

The `hand_in` call is the hand-in.  The call of the round a task waits
for review on opens expanded, and its body is the review:

    ▾ ◈ Hand in the finished work  The flaky test fails in a random order.
      reproduction: Run the suite twice and watch the order change.
      ⚑ Ready for review
         Fix the flaky test

      Problem
      ...

      Handed in ...

      ▾ Changes (6)  ...
      ▾ Threads  [open 1]
      ...
         [Verify]  C-c C-v   [Send back]  C-c C-x   [Keep working]  C-c C-g
         C-c C-c in the box: return with feedback

The words, the buttons, their tooltips and their keys are the banner's,
moved: nothing about the review reads differently.  What changed is
where it is drawn, and that it is drawn by the block the transcript
already has for the call.

Once the work is decided -- verified, sent back, or taken back to work
with [Keep working] -- the call folds.  Its report is still there, read
by opening the call, which draws the hand-in alone: no heading, no
buttons, since there is no decision left to make on it.  Every earlier
round's call folds too, for the same reason: its review is over.

The review's keys are on while the task waits for review, as before, and
the box's hint says what the box is for.  The report popout keeps the
banner at its end: it has no call of its own, and the work is accepted or
sent back where the report is read.

## How the chat knows

The chat knows nothing of tasks.  A hand_in call that succeeds opens only
when a function on `harness-chat-hand-in-open-functions' says its report
waits for the user's review; the review module answers with the one
thing it knows: the task's record names the report it waits on by
`:call-id', and the call that handed that report in is the review's.
With no module saying so, a successful hand_in call folds like any other
call, its report read when the reader opens it.

`harness-chat-sync-hand-in-folds` folds or opens the calls to what the
functions say now, and draws a call again when it opens it, so what it
shows is the review as it is at that moment -- the changes may have been
read after the call was drawn.  The review module calls it when its
task's record changes in a way the review shows: a new round, a
decision, a branch to read the changes from.

The hook is `harness-chat-hand-in-open-functions' and not the
`harness-chat-hand-in-fold-functions' it replaces: a module that says
"keep this folded" has to say something about every call it does not
know, and the review module knows only its own round.  Saying when a
call opens puts the default where it belongs, in the chat.

## A round that handed nothing in

A turn can end without `hand_in' -- the model replied instead, or could
not call the tool.  The harness records a report marked `:missing', and
there is no call in the transcript to hold the review: there is no
hand-in.  The session's tail says so in a line, "No report · turn ended
without hand_in", with the buttons under it and the last message of the
session right above; the line is not a hand-in's review, and it is the
only thing left that draws a panel there.

This is the one case where the tail still shows a review.  It is
documented here because it is the exception a reader of the diff will
find, and because the alternative -- no way to decide such a task from
its session -- loses the one place the decision was reachable.

## The changes and the threads

The patch review module draws the changes and threads of the task's
review through `harness-ui-review-changes-functions', wherever the review
is drawn: the call now, and the popout's banner.  Its folds, approvals
and comments draw the call again, through the redraw function the call
passes to its report.

Drawing a call again replaces the whole block, so the module keeps the
reader's place around that redraw as it did around the tail's: the row,
comment or thread at point, or, once that is gone, the line where it was
under the first line of the changes.  A chat can draw the changes more
than once -- one call per round that has some -- so an anchor also
records which of them it was in, and point goes back to that one.  A
section starts at its heading, which carries a property of its own: the
rows and the threads carry the task's, and a run of them is no section
boundary.

A review that has to be made again -- one an older layout made, which a
reload drops -- is made by drawing a surface that shows it.  The tail
alone no longer does: it holds no report, and a call that is never drawn
makes nothing.  So the surfaces drawn for a dropped review are drawn with
`harness-ui-patch-review--redraw-chat-with-hand-ins`, which draws the
calls and the tail, and the call the task waits on makes the review.

## What this decides against

- **Keeping the banner and folding the call.**  That is what the tree
  did, and it is what this change undoes: the work is drawn once, in the
  place that made it.
- **A dedicated hand-in block kind.**  The transcript already has a
  block for the call, its fold, its status and its place in the
  conversation.  A new kind would duplicate all of it to gain a heading.
- **A banner in the report popout only.**  Kept, not as a fallback: the
  popout is the report's own page, and the work is decided where it is
  read.
- **The no-report banner.**  Kept, for the reason above: with no call,
  the session is otherwise no place to decide the task.
