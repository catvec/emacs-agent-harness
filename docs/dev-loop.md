# The live development loop

Code that merely looks implemented does not count.  Every feature is
verified in a running Emacs before the next one is started, and every
claim about a command is the command's own output.

```sh
scripts/dev.sh start                 # emacs -Q daemon "harness-v3" + a GUI frame that never takes focus
scripts/dev.sh eval '(harness-call (quote session/list))'
scripts/dev.sh keys 'C-c h n'        # real key sequence in the frame
scripts/dev.sh shot                  # PNG of the frame via x-export-frames → scripts/.dev/shot.png
scripts/dev.sh errors                # recent *Messages* + harness log warnings
scripts/dev.sh reload                # harness-reload (auto-reload also runs on save)
scripts/test.sh --changed            # the suites the working tree's changes touch
scripts/test.sh [FILE [SELECTOR]]    # ERT, one clean Emacs per suite
scripts/lint.sh [--checkdoc]         # byte-compile everything out of tree
```

A task's worktree can be driven the same way without leaving the board:
`[Open harness]` on a card in *Ready for review* starts that loop in
the worktree's checkout, under a socket and state directory of its own,
and raises its frame.  The agent's `open_harness` tool does the same
and returns the commands above with the socket to use.

The daemon's socket lives in the checkout, at
`scripts/.dev/run/SOCKET`, not where Emacs puts sockets by default
(`$XDG_RUNTIME_DIR/emacs/`).  So an agent's `bash` tool, whose sandbox
shows the checkout but not `$XDG_RUNTIME_DIR`, drives an instance the
harness started outside it: `scripts/dev.sh status`, `eval`, `keys`,
`shot` and the rest work from bash, as does `emacsclient -s
scripts/.dev/run/SOCKET` run in the checkout.  A Unix socket's path
holds 107 bytes at most, too few for a task's worktree, so the daemon
and `dev.sh` name the socket through `/proc/PID/cwd` of a process that
works in the checkout: the daemon's `server-socket-dir` reads like
`/proc/4242/cwd/scripts/.dev/run/`.  With no socket there, `dev.sh`
looks for a daemon an older `dev.sh` started, in the default place.

The daemon runs `emacs -Q` and loads only `scripts/harness-dev.el`, so
results are reproducible.  State lives in `scripts/.dev/state-SOCKET`
(`HARNESS_DEV_SOCKET` picks the socket, `HARNESS_DEV_STATE` the directory),
so several daemons can run side by side.  Its tasks stay there too
(`harness-tasks-store-in-repository` is nil in the daemon): it never
writes into a repository's `.git`, where the real harness keeps a git
project's task board.  The tests do the same, except those that make
repositories of their own.

The harness always runs byte-compiled code: `harness-start` and
`harness-reload` compile every source file into
`<state-directory>/elc/` and load the result, refusing the reload if any
file fails.  Interpreted closures over large values (a parsed model
catalogue, a 30k-character tool output) can exceed Emacs's evaluation
depth, so loading sources directly is not supported.  Set
`harness-log-level` to `debug` to log a backtrace whenever a promise
handler signals.
Integration suites that talk to real models run only with
`HARNESS_INTEGRATION=1`; the local ACP suites and the TCP suites both
run by default so both transports stay green.

## The fast test loop

A test run is minutes, an edit is seconds, so run the checks your
change can break while you work and save the whole suite for the end:

- `scripts/test.sh --changed` runs the suites the working tree's
  changes touch (a changed test file runs itself; a module runs the
  suite named after it and every suite that names it; a test helper,
  a fixture or `harness.el` runs them all).  Name the files yourself
  when you know them: `scripts/test.sh test/harness-tasks-test.el`,
  with an ERT selector to narrow it further.
- `scripts/test.sh` with no arguments runs every suite.  That is the
  run to make once, before handing work in, not after every edit; a
  plan step or a sub-agent does not each need their own.

A run keeps every suite's whole output: `scripts/.dev/test-logs/<suite>.log`,
ending with `== FILE exit STATUS DATE ==` so a log left by an earlier run
is recognisable, and the run's own lines and summary in
`scripts/.dev/test-logs/last-run.txt` (`HARNESS_TEST_LOGS` moves them).
So **never pipe a test run through `grep`, `tail` or `head`**: what you
did not see is in the log, and reading it costs nothing where running
the suite again costs minutes.  A failing run prints each failing
suite's log path; quote that log, or the call that ran it, as the
evidence for what the run showed.

## Evidence when there is no display

`scripts/dev.sh shot` exports the frame and that PNG is the evidence
for a view.  When the display or the sandbox refuses X, do not spend
calls on X plumbing (authority files, virtual servers, converters):
say in the report that a screenshot was not possible, and hand in what
does show the work -- a rendered image or chart, the harness log, or
the tool call that ran the command -- rather than describing it.

## Screenshots

`scripts/media.sh` takes the pictures in `docs/media` again, all of
them or the ones named (`scripts/media.sh chat tasks`), in an `emacs -Q`
of its own with a demo project and scripted agents, on a private
display.  [screenshots.md](screenshots.md) says how it works and how to
add or change a picture when a view changes.
