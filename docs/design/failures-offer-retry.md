# Failures offer [Retry]

## The problem

The harness server is slow under load, restarts, or goes away.  A view
that loads something over ACP then shows what failed and stops: the task
board says `Loading tasks failed: …` above its compose box, the chat puts
an error block where the transcript would be, the tree says it could not
load, and the settings page, the slots page, usage, insights, the
worktree list, the boards, the computers page, the server page and the
provider check each say their own version of it.

Every one of them left the reader to work out how to ask again.  The
commands existed -- `g`, `M-x harness-ui-tasks-refresh`, a redraw -- but
nothing on the failure line said so, and some failures were shown where
no command reaches, such as the chat's older history, which said it only
in the echo area and lost that line as soon as the next message printed.

The user's report: the board, session history and other pages fail when
the harness stalls, and the failure text has no way to try again.

## The rule

**A view that loads something over ACP shows what failed, and beside it
`[Retry]`.**

- The button is the imperative `[Retry]`, as `docs/action-buttons.md`
  says of every control that acts.
- Its tooltip says what it loads again, in the imperative:
  `Load the tasks again`, `Load the session again`, `Load the tree again`.
  The default, for a failure with nothing better to say, is `Ask again`.
- The view keeps its own words for what failed.  The button follows them,
  two spaces apart, on the same line where the line has room.
- A failure in a header line or a mode line carries the button in that
  line, where the header's other buttons live.
- A line fitted to a narrow window that cuts the button offers it again
  in its overflow control (`harness-ui-overflow-mark`), as it does for
  every button it cuts.

The helper lives in the UI foundation, `lisp/ui/harness-ui.el`, which
every view already requires:

| function | for |
| --- | --- |
| `harness-ui-retry` | the button string, running a function or a command |
| `harness-ui-retry-header` | the same in a header line or a mode line, where keys come from `local-map` |
| `harness-ui-failure-string` | a view's failure text, then the button |

## The copy inventory

Every surface that shows a load failure, what it says, and what its
button says.

| surface | the failure's own words | button tooltip |
| --- | --- | --- |
| task board (`harness-ui-tasks.el`) | `Loading tasks failed: …` | `Load the tasks again` |
| chat, the transcript (`harness-ui-chat.el`) | `could not load the session: …` | `Load the session again` |
| chat, older history (`harness-ui-chat.el`) | `Could not load the earlier messages: …` | `Load the earlier messages again` |
| session tree (`harness-ui-tree.el`) | `Could not load the tree: …` | `Load the tree again` |
| task slots (`harness-ui-slots.el`) | `Could not load the task slots: …` | `Load the task slots again` |
| access (`harness-ui-access.el`) | `Access unreadable: …` | `Load the access again` |
| usage (`harness-ui-usage.el`) | `Could not load usage: …` | `Load the usage again` |
| usage history (`harness-ui-usage-history.el`) | `History unavailable` | `Load the history again` |
| settings (`harness-ui-config.el`) | `Could not load the settings: …` | `Load the settings again (g)` |
| insights (`harness-ui-insights.el`) | `Report failure · …` | `Gather the report again` |
| cost comparison (`harness-ui-cost-compare.el`) | `Could not compare costs: …` | `Compare the costs again` |
| worktree list (`harness-ui-worktree.el`) | `Worktree list failure: …` | `List the worktrees again` |
| computers (`harness-ui-computers.el`) | `…` in the header | `Load the computers again` |
| server page (`harness-ui-server.el`) | `…` in the header | `Load the server again` |
| boards (`harness-ui-board.el`) | `…`, list and page | `Load the boards again` / `Load the board again` |
| provider check (`harness-ui-provider-check.el`) | `Could not start the checks: …` | `Start the checks again` |
| session search (`harness-ui-search.el`) | `The search failed: …` | `Search again` |
| remote access (`harness-ui-acp-remote.el`) | `This harness cannot serve other devices: …` | `Load the server again` |

The button is `[Retry]` in all of them: the same word in the same place,
so a reader who has found it once finds it everywhere.

## What was already right, and is kept

The memories page, the workspace selector, the task search, the voice
output page and the review's inbox already offered a way to try again.
They keep their own buttons and wording; this change adds the button to
the failures that had none, and does not rewrite what already worked.

## How it is checked

- `lisp/ui/harness-ui-test.el` holds the button itself: its exact
  `[Retry]` copy, its tooltip, that it runs a plain function and a
  command alike, that a header's button is bound in `local-map`, and that
  a fitted line which cuts it still offers it in the overflow.
- Each view's own suite asserts the failure's rendered copy and tooltip:
  the board, the chat (both the transcript and the older history), the
  tree, the slots, access, usage history, settings, insights, the
  worktree list, the boards, the computers page, the server page, the
  search, the remote page and the provider check.
- The board's and the chat's tests press the button and check that what
  failed is loaded again.

# A message on its way, and a button that waits

Two other things the same slow harness made plain, from the task that
asked for this work.

## A sent message says it is sending

The box gives a message up the moment it is sent, and the harness
records it as a node of the transcript only when its turn reaches it.
On a harness that is slow, restarting or busy that is a while, and the
message was nowhere on screen: the box was empty and the transcript had
nothing, so it looked lost in the ether.

A message sent is drawn above the compose box from the send until the
harness records it, as the user message it will be -- the queued
message's UI, for a message that waits on the harness rather than on the
turn -- with the word `sending` where a queued one says `queued`.

| state | the line | tooltip |
| --- | --- | --- |
| sent, not yet recorded | `● sending` | `Sent · not yet recorded by the harness` |
| queued | `● queued` | `Not sent yet: the model does not have this message` |
| waiting for the turn | `● queued` | `Not delivered yet: the model gets this message at its next step` |

It goes when the harness records it: the node that arrives with its
words, or the session's own list of what waits for the turn, whichever
comes first.  A send that fails takes it away too, and the error block
says why, so a message that never made it cannot read `sending`
forever.  Two messages that read alike come out in the order they went
out.

## A button that acts says it is working

A button that asks the harness something gave no sign that it had: on a
slow harness a click on a setting's choice, or a page's button, looked
as though nothing happened until the answer came and the view was drawn
again.  The task board drew its own buttons held down; nothing else did.

`harness-ui-held-button` is the same thing for the views whose buttons
are strings: a click holds the button down -- the same label, dim in a
sunk slot, no hover -- until every request the action made through
`harness-ui-request-held` is answered or has failed, and no sooner than
a quarter second.  Its tooltip while it waits is `<what it does> ·
waiting for the harness`; a second click runs nothing and says `Still
working on that`; an answer that never comes lets it go after two
minutes, so a button cannot stick.

The jail and permissions page is the first to use it: its choices and
setting buttons are held from the click, and the page is drawn again
when one is pushed and when it is let go.  A choice is named by its row
and its words, so the network's `On` and writing's `On` are two buttons,
not one.

## How it is checked

- `lisp/ui/harness-ui-chat-test.el`: a message sent is drawn above the
  box reading `sending` with its tooltip, and goes when the node that
  records it arrives; a send that fails stops saying it; two messages
  that read alike come out in their order.
- `lisp/ui/harness-ui-test.el`: the held button's exact copy and
  tooltip, that it is held for every request its action made, that a
  second click runs nothing, and that an answer that never came lets it
  go.
- `lisp/ui/harness-ui-access-test.el`: a choice pushed on the page is
  drawn held down with its tooltip while its request waits, keeps its
  words, and is drawn as the choice in effect once the harness answers.
