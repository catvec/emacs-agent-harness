# Why the harness UI froze: a hidden worktree list redrawn for every session update (2026-10-22)

**Symptom.** The live Emacs was "really laggy", with long freezes. Even an
`emacs_eval` against it was refused with "that Emacs was busy".

**Cause.** One buffer: `*harness worktrees*`, 4 rows, shown in no window.
Every change of the session cache redrew it, and a redraw took 1.5-1.75 s of
the UI thread, so the redraws ran back to back and Emacs spent roughly four
fifths of its time on a list nobody was looking at.  Fixed in
`lisp/ui/harness-ui-worktree.el`.

## What was measured

All of this was read from the running Emacs, not inferred from the code.

**CPU profile** (`profiler-start 'cpu`, 32 s while it lagged).  29,480 ms of
CPU in about 32 s: the UI thread was ~100% busy.

| Share | What |
| ---: | :--- |
| 68% | one timer chain: `harness-ui-worktree--redraw` > `refresh-entries` > `entry` > `sessions-label` > `sessions-in` > `same-p` > `file-truename` |
| 20% | `Automatic GC`, the string churn of that same chain |
| 12% | everything else together: task board 3%, redisplay 4%, lsp-bridge's elisp-symbols timer 2% (the user's config, not the harness), the ACP poll 2% |

**Trace** of `harness-ui-worktree--redraw`: 1,741, 1,498, 1,750, 1,513, 1,483,
1,515, 1,500, 1,500, 1,742 ms.  The calls were about 2 s apart: the next one
started as soon as the last ended.  The buffer was `*harness worktrees*`, 4
rows, `(get-buffer-window buf t)` nil.

**GC counters** over 705 s: 467 collections, 130 s in GC (18.5% of the wall
clock), 279 ms each.  The live Lisp heap is about 305 MB (5.9 M conses, 1.14 M
strings, 137 MB of string bytes), which is why each collection is so long.
One redraw allocated tens of megabytes (about 1.0 M conses and 0.8-1.5 M
strings), so it caused a collection every redraw or two.

Nothing else was close.  Per call: task board render 1-15 ms (a few 70 ms),
notifier ~1 ms,
sessions list ~4 ms, chat spinner/activity line ~0.1 ms, the 15 s ticks
< 1 ms.  The harness process (a separate Emacs) used 4% CPU.  The 16
`harness-notify-send` processes are the designed cap
(`harness-notifications-desktop-max-waiting`), not a leak.

## Why it was slow

1. **Quadratic work with no memo.** `harness-ui-worktree--sessions-in` ran a
   predicate over *every* cached session for *every* row, and
   `harness-ui-worktree--same-p` called `file-truename` twice per session.
   `file-truename` walks the whole path (about 0.15 ms: 1.5 s over the
   9,584 calls of one redraw), and it was never remembered.  1,198 user
   sessions x 4 rows x 2 = 9,584 calls per redraw.  It also resolved remote
   (TRAMP) names, which reaches the host from the UI thread: running the old
   code over 16 paths, 3 of them remote, spent 74 s failing to open ssh
   connections.
2. **Redrawn while hidden.** The list listens to
   `harness-ui-sessions-changed-hook`, which runs for every `_harness/session`
   update, and the harness makes one session for every model call of its own
   (the permission judge and the like: created, running, idle, deleted).
   Nothing looked at whether a window showed the list.
3. **A trailing debounce turns that into a loop.** `harness-debounce` fires
   after 0.2 s without a change.  While a 1.5 s redraw blocks Emacs the
   updates queue in the socket; they are handled in one burst afterwards, then
   it is quiet for 0.2 s, and the debounce fires again.
4. **GC multiplies it**, as above: tens of MB allocated per redraw against a
   300 MB heap.

The code is old (2026-09-30).  What grew is what it multiplies: 1,298 cached
sessions and much more internal-session churn under auto mode; and, probably,
a list opened to try the new assume-worktree feature and left in the
background (that part is inference).  The list for this repository has 405
worktrees: the cost is linear in rows (140 s for 120 rows in the benchmark
below), so one redraw there would take several minutes.

## The fix

All in `lisp/ui/harness-ui-worktree.el`:

- **One true name per directory** (`harness-ui-worktree--true`, memoised, as
  `worktree-assume` already does), and remote names are never looked at.
- **A session index** built once per redraw (true name > sessions, newest
  first), so a row is a hash lookup: O(sessions + directories) instead of
  O(rows x sessions) file-system walks.
- **A list no window shows is not touched.**  It notes what it missed
  (`harness-ui-worktree--stale`) and catches up from
  `window-buffer-change-functions` when shown, as `harness-ui-access` and the
  chat module (`harness-chat--stale`) already do.  Worktree and merge events,
  `harness-ui-redraw-hook` and assumption changes go through the same gate.
- **A shown list redraws only when a sessions cell would read differently.**
  Tokens, costs and the harness's own records change nothing it shows.
- The hook is also given to a list that exists when the harness reloads.

## Verification

Batch benchmark: 1,298 sessions (100 internal) in 150 directories, one
`harness-ui-worktree--refresh-entries`.

| Rows | Before | After, first | After, again |
| ---: | ---: | ---: | ---: |
| 4 | 3.2 s, 103,120 `file-truename` calls, 1.0 M conses + 1.5 M strings | 76 ms, 1,500 calls | 2 ms, 0 calls, 4 k conses + 212 strings |
| 120 | 140 s | 93 ms | 17 ms |

(The calls counted include `file-truename`'s own recursion over the parts of
a name; "first" finds the 150 directories once.)

Same output as before: an oracle test against the old implementation over 15
rows and 512 sessions (links, trailing slashes, `..`, missing and remote
paths, internal sessions, `:worktree` against `:cwd`) found no difference,
nor did `same-p` over all 225 pairs.

End to end: 1,298 sessions, a 4-row list, Poisson session updates (about
5 a second, queued like the ACP inbox), a 50 ms heartbeat timer, 30 s.

| Code | List | CPU busy | Redraws | Longest stall | Stalls > 100 ms | Time stalled |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| before | hidden | 88% | 10 | 2,888 ms | 10 | 26.6 s |
| before | shown | 87% | 10 | 2,789 ms | 10 | 26.7 s |
| after | hidden | 1% | 0 | 3 ms | 0 | 0 |
| after | shown | 2% | 11 | 50 ms | 0 | 0 |

A visible list of 405 rows (1,298 sessions over 1,000 directories): 6% busy
and 17 redraws with the skip, 15% and 57 without it.

In a live dev harness (GUI frame, 405 worktrees, 1,298 sessions) through real
redisplay: shown, 100 session updates caused 1 redraw; hidden, 100 updates and
a worktree event caused 0 redraws, 0 loads and no timers, and the list noted
`reload`; shown again, the redisplay hook reloaded it once.

**The live Emacs, with the cause removed.**  The fix reaches a running Emacs
only after a merge and `M-x harness-reload`, so as a stopgap the two listeners
of the (hidden) list were unhooked there with `remove-hook`, nothing killed or
redefined; the module's init puts them back on the next reload.  The UI
thread's CPU went from 64% busy (25.0 s in 39.1 s, 22 collections, 5.9 s of
GC) to 11% busy (4.2 s in 38.5 s, 4 collections, 1.2 s of GC).  A profile of
the 53 s after: 4,912 ms of CPU, 9% busy, of which GC 25% (2% of the wall
time), redisplay 28%, the task board 20%, the chat spinner 14%, ACP message
handling 7%.

Tests (`test/harness-ui-worktree-test.el`, 6 new, none measures time): the
`file-truename` calls per redraw are bounded by the directories and are zero
on the second redraw; a link is its target, the internal sessions are nobody's,
a remote name is never resolved; a hidden list starts no timer and a shown one
catches up; an unchanged cell costs no redraw.

## Not fixed, and worth knowing

- **GC.** At ~300 MB live, every collection is ~280 ms, however rare.  How
  much of that heap is the harness's I did not measure.  Each chat buffer
  keeps per-block state (`harness-chat-block`: node, result, content) beside
  its text, and 50 were open (up to 1.2 MB of text each), so closing the ones
  you are done with is the first thing to try.
- **A visible list of hundreds of rows** still costs 0.1-0.25 s when a cell
  does change.  An incremental update of the changed rows would remove that.
- `lsp-bridge-elisp-symbols-update` (`all-completions` over the obarray from a
  timer) was ~2% of the profile; it is in the user's configuration.
- The module pages `docs/modules/README.md` and `tools-review.md` were already
  out of date before this change (`scripts/module-docs.sh --check`).

## If you are on a build without the fix

Until `harness-reload` loads it, kill `*harness worktrees*` (`C-x k`; `C-c h w`
makes it again) or run

```elisp
(remove-hook 'harness-ui-sessions-changed-hook #'harness-ui-worktree--on-sessions-changed)
(remove-hook 'harness-ui-event-functions #'harness-ui-worktree--on-event)
```

## Diagnosing the next one

Profile the live Emacs while it lags, with deep stacks:

```elisp
(require 'profiler)
(setq profiler-max-stack-depth 60 profiler-log-size 1500)
(profiler-start 'cpu)
;; ... 30 s of the lag ...
(profiler-write-profile
 (profiler-make-profile :type 'cpu :timestamp (current-time)
                        :log (profiler-cpu-log))
 "/tmp/prof.eld")
(profiler-stop)
```

Read it in another Emacs with `profiler-read-profile`, and count samples per
function over the whole stack: one sample is a millisecond of CPU, so the
total against the wall time says how busy the thread was.  Then
`(trace-function 'SUSPECT)` shows each call's duration in `*trace-output*`,
and `gcs-done`, `gc-elapsed` and `(memory-use-counts)`, read twice, give the
GC share.  A view that does work per session change must not do it while
nothing shows it.
