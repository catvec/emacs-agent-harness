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
and returns the commands above with the socket to use.  It runs the
checkout's own `scripts/dev.sh` and the Elisp its daemon loads outside the
sandbox, code the session may have written in its worktree, so it is an
`exec` call that the permission mode decides as it decides `bash` (asked in
ask and accept-edits mode, weighed by the judge in auto mode and for a user
who is away, allowed in yolo mode), not one that needs no approval.

If an existing instance's responsiveness probe times out, `open_harness`
and `dev.sh start` report that it may be busy rather than starting a second
daemon.  `open_harness` also catches a refused connection when it can see
the daemon is still running.  Cancel the operation in its frame with `C-g`
and retry, or explicitly call `open_harness` with `restart: true` to stop an
instance it opened and open a new one.  **Restart discards unsaved work in
the instance**, so use it only when that is acceptable; it never restarts the
harness that runs the tool itself, and requires a readable process table to
verify that the old daemon stopped.  The equivalent ACP call is
`harness-dev/open` with its third argument true.

`dev.sh status`, `stop` and `restart` likewise report a probe timeout instead
of claiming the daemon stopped.  A refused connection, however, is still
reported as not running by the script, even if a wedged daemon's listen queue
is full; verify its process before trying another start.  A daemon started
directly with `dev.sh` uses a different socket from `open_harness`: if `C-g`
cannot free it, identify and stop that daemon manually before retrying,
accepting the loss of unsaved work.  `HARNESS_DEV_PROBE_TIMEOUT` changes the
script's five-second responsiveness limit; `HARNESS_DEV_TIMEOUT` still bounds
other emacsclient commands.

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
run by default so both transports stay green.  The suite that runs the
Claude provider against the real `claude` binary runs only with
`HARNESS_REAL_CLAUDE` naming it: it talks to no model, only to
`test/fixtures/mock-anthropic.py` on 127.0.0.1, with a home directory
and a dummy key of its own, and a company's managed settings are
simulated in a private `/etc` with bubblewrap (those tests skip without
it).  Run it after a Claude Code upgrade, which is what the fake CLI the
other suites use cannot tell you:

```sh
HARNESS_REAL_CLAUDE=$(command -v claude) scripts/test.sh test/harness-provider-claude-real-cli-test.el
```

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

The runner uses at most four suites at once by default; set
`HARNESS_TEST_JOBS` to choose another limit. [Test performance](test-performance.md)
describes the shared fixtures, timing cache and remaining slow checks.

A run keeps every suite's whole output: `scripts/.dev/test-logs/<suite>.log`,
ending with `== FILE exit STATUS DATE ==` so a log left by an earlier run
is recognisable, and the run's own lines and summary in
`scripts/.dev/test-logs/last-run.txt` (`HARNESS_TEST_LOGS` moves them).
So **never pipe a test run through `grep`, `tail` or `head`**: what you
did not see is in the log, and reading it costs nothing where running
the suite again costs minutes.  A failing run prints each failing
suite's log path; quote that log, or the call that ran it, as the
evidence for what the run showed.

## The Flutter app's build check

`scripts/test.sh` and `scripts/lint.sh` are about Emacs Lisp.  Nothing in
them builds `harness_client/`, the Flutter app, and a task's sandbox has no
Flutter, no JDK and no Android SDK of its own, so tasks handed in apps that
did not compile (`tasks_screen.dart` used a name it had not defined), whose
own tests failed (31 fail on main today, unseen since a layout rewrite), and
whose release build died on the phone installer's machine (below).  The first a
person saw of each was a build that failed.

```sh
harness_client/tool/check_build.sh --accept-android-licenses   # the check; leaves a stamp
harness_client/tool/check_build.sh                             # the same, where an Android SDK is installed
harness_client/tool/check_build.sh --quick                     # analyze + test the working tree
harness_client/tool/check_build.sh --status                    # does the stamp cover the app as committed?
harness_client/tool/client_toolchain.sh                        # the toolchain on its own (prints exports)
```

All of this is **this repository's**, not the harness's: the harness knows
no Flutter app and asks no task for any of it.  The pieces are
`harness_client/tool/` (the check and its toolchain) and a plugin,
`.harness/plugins/dev/harness-client-check.el`, that makes the sessions of
this repository's `hand_in` ask for it; a task of another project is asked
nothing, and neither is one that changed nothing of the app.

The check builds what is **committed**, in a copy under
`scripts/.dev/client-check/work/` (never in the checkout), and runs, in
order: `flutter pub get --enforce-lockfile` (`pubspec.lock` agrees with
`pubspec.yaml`), `flutter analyze`, `flutter test`, and `flutter build apk
--release`, from an empty `build/`, which is what `tool/qr_install.sh`
installs.  When `pubspec.yaml`, `pubspec.lock`, `.flutter-version` or
`android/` differ from the base's, it builds the base's tree first and then
the branch's tree over that `build/`: the build a person makes after
merging, over the one they made before (a base that does not build itself is
said, and skipped).  A build from scratch cannot see
what that finds (`shared_preferences_android` 2.5.0 -> 2.5.2 lost its plugin
class that way, and the installer's build stopped with `cannot find symbol`
in `GeneratedPluginRegistrant.java`; `android/gradle.properties` now compiles
Kotlin from scratch every time).  When `tool/` differs from the base's it runs
the tools' own tests too.  The whole output of each step is kept in
`scripts/.dev/client-check/logs/`, one file a step.

The app's tests are compared with the base's by name.  A test that fails
here and failed at the base too is somebody else's breakage: it is listed
and held against nobody, so a red main does not stop every branch; a test
that fails here and passed there fails the check, and so does a test file
that no longer loads.

When everything passed the check writes
`scripts/.dev/client-check/stamp.json`, naming the commit.  The plugin
reads it with git when a task of this repository hands in (it never runs
the worktree's script outside the sandbox): a task whose branch changed the
app (the paths in `harness-client-check--paths`) is refused, by the
filter `task/before-hand-in` that `hand_in` offers any project, unless the
stamp says `pass` for a commit in its history, the app's paths are as they
were in that commit, and nothing in them is uncommitted.  Notes, evidence
and the Emacs side may be committed after the check.  A task that cannot
continue, or has nothing to merge, is not held to it.  The sessions asked
are those whose plugin modules name `client-check`, as the repository's
directory-local variables have them do beside `tools-dev`: after you trust
that entry (Emacs asks again when the file changes: visit a file of the
checkout and answer `!`) the sessions that start are asked, and no other
session is.  A session keeps the list it started with, so a task already
running when you trust it is not.

The toolchain is the Flutter SDK pinned in `.flutter-version`, a JDK 17 to 21
and an Android SDK with the components `android/gradle.properties` pins.  A
machine that has them (`FLUTTER_VERSIONS_DIR`, `JAVA_HOME`, `ANDROID_HOME`)
uses them; otherwise `tool/client_toolchain.sh` installs them, pinned and
checksummed, under `.git/harness-client-toolchain` (every worktree of a
repository shares its `.git`, so only the first task pays for the gigabytes;
`HARNESS_CLIENT_TOOLCHAIN` moves it).  Installing an Android SDK means
accepting its licences, which `--accept-android-licenses` does, for that SDK
only and only when the script has to install one: where an SDK with the
components is installed already (`ANDROID_HOME`), the flag does nothing and
no licence is accepted.  A task's sandbox has none, which is why the plugin's
instructions to a task name the flag.  Pub's and Gradle's caches are the
toolchain's own, never `~/.pub-cache` (a sandboxed shell that sees part of it
makes pub delete real files there).

```sh
python3 harness_client/tool/test_check_build.py   # the check's own tests, with a fake flutter
```

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
