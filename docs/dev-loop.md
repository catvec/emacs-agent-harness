# The live development loop

Code that merely looks implemented does not count.  Every feature is
verified in a running Emacs before the next one is started.

```sh
scripts/dev.sh start                 # emacs -Q daemon "harness-v3" + a GUI frame that never takes focus
scripts/dev.sh eval '(harness-call (quote session/list))'
scripts/dev.sh keys 'C-c h n'        # real key sequence in the frame
scripts/dev.sh shot                  # PNG of the frame via x-export-frames → scripts/.dev/shot.png
scripts/dev.sh errors                # recent *Messages* + harness log warnings
scripts/dev.sh reload                # harness-reload (auto-reload also runs on save)
scripts/test.sh [FILE [SELECTOR]]    # ERT, one clean Emacs per suite
scripts/lint.sh [--checkdoc]         # byte-compile everything out of tree
```

The daemon runs `emacs -Q` and loads only `scripts/harness-dev.el`, so
results are reproducible.  State lives in `scripts/.dev/state-SOCKET`
(`HARNESS_DEV_SOCKET` picks the socket, `HARNESS_DEV_STATE` the directory),
so several daemons can run side by side.  Its tasks stay there too
(`harness-tasks-store-in-repository` is nil in the daemon): it never
writes into a repository's `.git`, where the real harness keeps a git
project's task board, nor task files into its `docs/tasks/`.  The
tests do the same, except those that make repositories of their own.

The harness always runs byte-compiled code: `harness-start` and
`harness-reload` compile every source file into
`<state-directory>/elc/` and load the result, refusing the reload if any
file fails.  Interpreted closures over large values (a parsed model
catalogue, a 30k-character tool output) can exceed Emacs's evaluation
depth, so loading sources directly is not supported.  Set
`harness-debug-backtraces` to log a backtrace whenever a promise handler
signals.
Integration suites that talk to real models run only with
`HARNESS_INTEGRATION=1`; the local ACP suites and the TCP suites both
run by default so both transports stay green.
