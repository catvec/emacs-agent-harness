# Why the harness UI froze again: a hidden session list of 942 rows, redrawn back to back (2026-10-23)

**Symptom.** "The harness is being really laggy", a day after the worktree list
was fixed ([ui-thread-blocking-2026-10-22.md](ui-thread-blocking-2026-10-22.md)),
with that fix loaded in the running Emacs.

**Cause.** Another buffer nobody was looking at: `*harness sessions*`, the
session list of this project and its task worktrees, 942 rows, shown in no
window.  Every change of the session cache, every growing token count, every
output rate and every pet footer redrew all of it, and a redraw took 520-715 ms
of the UI thread, so the redraws ran one after the other.  The list and the
garbage it made were 94% of the thread's busy time, and the thread was busy 74%
of the time.  Fixed in
`lisp/ui/harness-ui.el`, `harness-ui-sessions.el` and `harness-ui-tasks.el`.

## What was measured

All of this was read from the running Emacs while it lagged.

**CPU profile** (`profiler-start 'cpu`, 70 s).  51,752 samples at 1 ms: the UI
thread was about 74% busy.

| Share | What |
| ---: | :--- |
| 58% | `Automatic GC`, the garbage of the chain below |
| 36% | `harness-ui-sessions--redraw`: entries 66% of it (`harness-ui-format-context` and its `substitute-command-keys` / `where-is-internal` 29%, `harness-ui-format-spend` 16%, `--ordered` 10%, of which `cl-member` 9%), printing the rows 34% |
| 6% | redisplay, the task board, the ACP poll, everything else |

**Trace** of `harness-ui-sessions--redraw`: 25 calls in about 20 s, 526, 682,
694, 536, 691, ... 715 ms each.  The buffer was in no window
(`emacs_windows`, `get-buffer-window` nil), not paused, not filtered: 942 rows.
The callers were the 0.15 s debounce, the 0.5 s token timer and once the pet
(`harness-ui-pet--sync-panels` > `harness-ui-sessions-redraw`).

**GC counters** over those 70 s: 207 collections, 30.0 s in GC (43% of the wall
clock), 145 ms each.  Allocated: 104.8 M conses, 279 M characters of strings,
28 M strings, 7.5 M text-property intervals.  One redraw made about 1.2 M conses,
3.2 M string characters, 320 k strings and 86 k intervals: a collection every
redraw or two against a heap of about 300 MB.

**With the list paused** (its own pause flag, `P`; the stopgap below): 83 s,
11,000 samples, 13% busy, 20 collections, 3.0 s in GC, 16 M conses.  What is
left: redisplay 36%, the task board 22% (`harness-ui-tasks--render` > `fit-board`
> `window-text-pixel-size`; sorting every session to build the board key
included), GC 27%.

## Why it was slow

1. **Drawn for nobody.**  Nothing looked at whether a window showed the list.  The
   session cache changes many times a second while agents work (the harness
   makes a session for every model call of its own, and a trace of
   `harness-ui-cache-session` showed 9 of 18 updates were such records; the rest
   are real sessions, this one included).
2. **A redraw is a thousand rows of string work.**  Every row built the tooltips
   of its Context, Output, Avg tok/s, Cost and Last msg cells whether anyone
   hovered or not: `format`, `string-join`, `string-trim`,
   `replace-regexp-in-string`, and for the context cell `substitute-command-keys`
   (a `where-is-internal` each).  Thirteen thousand cells, each with a fresh
   aligning-space string and a copy of the label for its default tooltip.
3. **Quadratic.**  `--ordered` searched the whole list (`cl-member`) for each
   session's parent; `--entry` recomputed the list of shown columns for every
   row.
4. **Nothing bounded the loop.**  The debounce fires after 0.15 s of quiet, the
   token timer every 0.5 s, so a redraw longer than that is followed by the next
   at once: the list took what the redraws left.  The same loop as the worktree
   list's, with a slower redraw.
5. **GC multiplies it**: the garbage of a redraw is about 15 MB, and a collection
   is 145 ms at this heap.

## The fix

- **Views follow the harness only while a window shows them**
  (`harness-ui-view-follow-p`, `harness-ui-view-install`, in `harness-ui.el`).
  The idiom is Emacs's own: Proced updates only the buffers a window shows
  (`proced-auto-update-flag` `visible`).  A view asks before it draws for a
  change that came by itself; with no window the answer is no and it notes that
  it missed something (`harness-ui-view-stale`); a buffer-local function on
  `window-buffer-change-functions` catches it up, once, soon after a window shows
  it.  The chat, the worktree list, the access page and the slots page already
  did this, each by a copy of its own; this is the shared version, used by the
  session list and the task boards.  The four older copies keep their own logic
  and use the helper only for the mark below (`harness-ui-view-adopt`).
- **A suspended view says so.**  If a window shows a view that missed changes and
  the catch-up has not run (a display path that does not run
  `window-buffer-change-functions`), its mode line reads `[Suspended: resume]`
  (`harness-ui-view-indicator`), the same orange mark in every view that follows
  the harness only while shown (the session list, the task boards, the chat, the
  worktree list, the access page, the slots page), drawn by the one helper in
  `mode-line-misc-info`; a click on it, or RET there, wakes the view
  (`harness-ui-view-wake`), as `[Paused: resume]` resumes a paused list.
- **The session list** draws nothing for sessions, rates, token counts, requests,
  tasks, a reload or the pet's footer while hidden, starts no timer, and draws
  once when shown again.  A paused list still holds still, shown or not.  Its
  own commands (filter, scope, columns, `g`) draw as before.
- **Tooltips on hover.**  The Context, Output, Avg tok/s, Cost and Last msg cells
  carry `help-echo` functions (`harness-ui-session-help-function`), as the task
  board's card titles already did; the text is made when it is asked for, from
  the session as the cache has it then.  The formatters take an optional `lazy`
  argument; every other caller still gets the string.
- **A redraw leaves room.**  `harness-ui-sessions--due` is the end of the last
  redraw plus four times what it took.  The changes that come all the time (the
  debounce, the token timer) wait for it, one timer at a time, and draw everything
  that changed meanwhile; a reload of the UI does not wait.  The list can never
  take more than a fifth of Emacs's time, whatever its size.
- **Cheaper rows.**  The aligning spaces of a row are made once per width and
  column (`harness-ui-sessions--space`), the default tooltip is put on the text
  once inserted instead of on a copy of it, `--ordered` uses a table, and the
  shown columns are worked out once for the list.
- **Task boards** no window shows are not drawn for session changes and do not
  reload for events; they use the same helper, so they reload when a window shows
  them (`harness-ui-tasks--catch-up`, beside the reload they always did,
  `harness-ui-tasks--on-window-change`, which shares its timer) and say
  `[Suspended: resume]` if that did not happen.  The key that says whether a board
  needs drawing no longer sorts every session by when it changed (that order
  changed with every update, so the board drew again for changes none of its
  cards show).

## Verification

**Batch, byte-compiled**, 942 sessions in 40 projects in trees of three, 20% of
them running (`scripts/analysis/bench-sessions.sh`, one `harness-ui-sessions--redraw`):

| | Before | After |
| :--- | ---: | ---: |
| time | 240 ms | 106 ms |
| conses | 1,073,080 | 611,513 |
| characters of strings | 2,663,065 | 516,778 |
| strings | 350,377 | 49,318 |
| intervals | 109,830 | 64,322 |

**Live GUI Emacs** (the dev harness, 942 synthetic sessions in the UI's cache,
real redisplay, `scripts/analysis/live-check.el`).  Churn as the harness would send
it: 6 session updates, 15 token ticks and 3 internal sessions made and deleted a
second, 12 s for each row; a 50 ms heartbeat timer measures the stalls.

| Code | List | CPU busy | Redraws | Longest stall | Time stalled |
| :--- | :--- | ---: | ---: | ---: | ---: |
| before | shown | 88% | 7 | 1,607 ms | 10.75 s of 12.4 s |
| before | hidden | 95% | 8 | 1,568 ms | 11.92 s of 12.7 s |
| after | shown | 27% | 7 | 349 ms | 2.38 s |
| after | hidden | 4% | 0 | under 20 ms | none |

Hidden again shown: one redraw within 1.5 s, the list no longer stale.  A window
configuration restored (what a workspace or tab switch does): the same, one
redraw.  (The first run of this check drove the daemon's own frame, which never
redisplays and so never runs `window-buffer-change-functions`: drive the GUI
frame.)

**The live Emacs, with the cause removed.**  The fix reaches a running Emacs only
after a merge and `M-x harness-reload`, so the hidden list was paused there with
its own flag (`harness-ui-sessions--paused`, the `P` key: nothing killed,
unhooked or redefined).  The profile above, 74% busy to 13%, is that.  After the
reload the list follows its windows by itself; press `P` in it once to take the
pause off.

Tests: `test/harness-ui-test.el` (the shared helper: follow, note, catch up once,
nothing for a window that left; the suspended mark, once in each view's mode line,
and the click that wakes it; the hover function; lazy figures say what the
eager ones do), `test/harness-ui-sessions-test.el` (a hidden list draws nothing
for everything that follows the sessions and draws once when shown; hidden and
paused stays still; the cost spacing; tooltips are made on hover and are never
older than it; an old list gets the hook on reload; a list shown without catching
up says it is suspended and a click redraws it), `test/harness-ui-tasks-test.el`
(a hidden board schedules nothing, is marked, and is woken; the board key ignores
the order sessions change in).  The existing session list tests show the list in a window, as
opening it does.  None measures time.

## Not fixed, and worth knowing

- **GC.**  At ~300 MB live, every collection is ~145 ms, however rare.  The
  heap itself is the thing to look at next (50 chat buffers, each with per-block
  state).
- **A shown list** still takes ~100 ms of CPU and ~12 MB of garbage per redraw at
  942 rows (the spacing keeps that to a fifth of the time).  Drawing only the
  rows that changed would remove it: the order is unchanged for token ticks, and
  half the cache updates are the harness's own internal sessions, which the list
  does not show.
- **The visible task board** costs about 3% (`fit-board`, `window-text-pixel-size`).
- The chat, worktree list, access page and slots page keep their own copies of the
  hidden-view idiom (they draw the shared mark, though); they could use
  `harness-ui-view-install` altogether.
- Two chat tests fail on `main` as it is (`harness-ui-chat-moves-between-the-agents-answers-in-a-thread`,
  `harness-ui-chat-c-c->-without-a-region-replies-to-the-message`), with and
  without this change.
- A timer that killed a buffer took 0.5 s once in the first profile (`kill-buffer`
  itself, 541 samples); not looked into.

## If you are on a build without the fix

Press `P` in `*harness sessions*` (the mode line reads `[Paused: resume]`; `P`
again resumes it), or kill the buffer (`C-x k`; `C-c h l` makes it again), or
from Lisp

```elisp
(with-current-buffer "*harness sessions*"
  (setq harness-ui-sessions--paused t))
```

## Diagnosing the next one

As last time: profile the live Emacs while it lags, read `profiler-cpu-log`
**after** `profiler-stop` (it moves the samples into that variable: asking
`(profiler-cpu-log)` afterwards returns an empty log), and count samples per
function over the whole stack.  Then `emacs_trace` / `trace-function` on the
suspect gives each call's duration and callers, and `gcs-done`, `gc-elapsed` and
`(memory-use-counts)` read twice give the GC share and what a call allocates.
A view that does work per session change must do it only while a window shows it.
