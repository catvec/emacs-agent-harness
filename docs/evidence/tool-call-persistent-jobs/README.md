# Evidence: a session's runtime outlives its calls

The runs behind the hand-in, kept whole so they can be read rather than
described.  All of them were made on this branch with the real `bwrap`
in this checkout.

| File | What it is |
|---|---|
| `jobs-game-01-launch-and-02-after-input.png` | Two frames a **game** drew, side by side, three times enlarged: the one call 2 copied (its own label `tick 0`, player at 160,100) and the one call 4 copied after call 3 had sent it input (`tick 18`, player moved to 178,112).  A frame carries the tick it was drawn at, which is one behind the status line the call read beside it (`tick 1` and `tick 20` in `jobs-game-demo.txt`), because the game draws the next frame after it writes the status.  The game was launched once, as call 1, and the calls that came after it are separate `tools/execute` calls with their own permission decisions. |
| `jobs-game-demo.txt` | `scripts/jobs-game/demo.sh`, whole: nine calls of one session.  Call 1 launches the game as a job.  Call 2 screenshots the frame it drew.  Call 3 sends it input.  Call 4 screenshots again, with the player moved and a higher tick, and reads the world file.  Call 5 writes the playtest's score where the harness's file tools read it.  Call 6 lists the job and the runtime holding it.  Call 7 stops it, and a second later no frame has been drawn and its files are all still there.  Call 8 shows the runtime went once nothing of the session was left in it, and that the next call builds another with the files intact (`pid-1: bwrap`).  Call 9 downgrades the session's working directory with `drop_access keep_read=true`; a write there is refused with `Read-only file system`, no file appears, and the runtime's profile says `cwd-writable=nil`. |
| `jobs-demo.txt` | `scripts/jobs-demo.sh`, whole: the HTTP form of the same workflow, one session and six calls.  Call 1 starts an HTTP server as a job.  Calls 2 and 3, separate calls, reach it.  Call 4 shows the file the job wrote, read by the harness's own tools.  Call 5 stops it; call 6 finds nothing on the port and the file still there.  Then the confinement of an ordinary call and a job's own report of what it cannot reach. |
| `jobs-section.png` | The access view's `Jobs` section, drawn from the exact string a live harness state produced (`lisp/ui/harness-ui-access.el`'s `harness-ui-access--insert-jobs`): a running job with its elapsed time of its timeout, its command and `[Stop]`; a second job that reached its timeout with the line saying so. |
| `shared-sandbox-settings.png` | A screenshot of a live harness frame drawing the access view's `Sandbox` and `Jobs` rows through the real insert functions (`harness-ui-access--insert-sandbox`, `--insert-jobs`), regenerated for this change because the old picture showed the row as it read before the runtime was held on demand: the row now says `Shared · bwrap · held · running · 2 processes · restart on permission change · processes stop`, and a session that keeps no runtime of its own reads `Not shared · read-only session`. |
| `module-docs-check.txt` | `scripts/module-docs.sh --check`, which names six pages out of date: `speech`, `ui-config`, `ui`, `ui-memory`, `ui-sessions`, `ui-supervisor`.  None of those modules is changed by this branch, so the drift is `main`'s, kept out of this change rather than swept in.  The pages this branch does touch — `sandbox-session`, `sandbox`, `tools-jobs`, `tools-shell` and the README — are regenerated and current. |
| `lint.txt` | `scripts/lint.sh` on the final commit: exit 0, only the repository's pre-existing warnings. |

The full suite is `scripts/test.sh` with no arguments, and it is quoted
as the tool call of the run at the tip of this branch rather than stored
here: each run's log names the commit it covered, and a commit cannot
hold the run of itself.  `scripts/test.sh --status` reports the same run
as a pass on that clean tree.

## What the game run does and does not show

It shows the workflow the review asked for, end to end: a game launched
once, driven and screenshotted by later separate calls, with retained
state and files, then stopped with its lifecycle and a permission
downgrade proved.

It does **not** show a real X11 or Wayland window.  No display server can
be started on this machine — there is no `Xvfb`, and the `Xorg` here has
no dummy driver — so the game renders its own frames to PNG with Pillow,
and a "screenshot" is the game's own frame copied by a later call.  The
persistence, the input, the retained files, the stop and the downgrade
are all real; a window manager path is not measured.

A screenshot is taken by copying the frame while the game is drawing the
next one, so the demo reads the copy back and takes it again unless it is
a whole PNG ending in its `IEND` chunk, and the game writes each frame
beside the old one and moves it into place.  Without both, a run
occasionally keeps a truncated copy — one did, at 0 bytes, before this.

## What the demos do not show

Any network isolation between sessions.  A job's server is on the
machine's network namespace, as a `bash` call's process is, so two
sessions can reach each other's listeners and cannot both bind one
address and port.  What keeps sessions apart is the mount set and the
ownership of the runtime and the job, not the network.

An idle runtime is destroyed at once by default, so what a session that
makes one call every few minutes pays in start-up is not measured here
beyond the demos themselves.
