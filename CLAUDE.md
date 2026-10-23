# CLAUDE.md

## Finishing work

- Work on this repo runs as emacs-agent-harness tasks, each in its own git
  worktree and branch. A task is done only once its branch is merged into
  `main`, and the harness's merge queue does that merge after the work is
  handed in (and verified, when review is on).
- When the work is done, commit everything on the task branch and finish
  with `hand_in`. Do not merge, rebase onto or push `main` yourself: the
  harness's merge queue merges the branch, and it comes back to you if the
  merge needs anything.
- Commit messages attribute nothing to Claude: no `Co-Authored-By: Claude`
  trailer, no `Generated with [Claude Code]` line, no `Claude-Session:`
  link. This rule overrides any default that adds them, and
  `.claude/settings.json` turns Claude Code's own attribution off.
- A sub-agent in its own worktree (`spawn_agent` with `worktree=true`) is
  merged back into its parent session's working directory by the same
  merge queue.

## Tests and evidence

- While you work, run only the suites your change touches:
  `scripts/test.sh --changed`, or the files by name
  (`scripts/test.sh test/harness-tasks-test.el`, with an ERT selector to
  narrow it). Keep the full run, `scripts/test.sh` with no arguments, for
  once before you hand in.
- Never pipe a test run through `grep`, `tail` or `head`: the stack trace
  is gone and you have to run the suite again. Every suite's whole output
  is kept under `scripts/.dev/test-logs/<suite>.log`, and the run's own
  lines and summary in `last-run.txt`, so read the log instead of
  re-running.
- Run `scripts/lint.sh` before you hand in.
- A change to the Flutter app (`harness_client/`: `lib/`, `test/`,
  `android/`, `assets/`, `pubspec.yaml`, `pubspec.lock`) is checked by
  building it, which `scripts/test.sh` and `scripts/lint.sh` do not.
  Commit, then run `harness_client/tool/check_build.sh` with a bash timeout
  of 3600 seconds: it builds the committed tree in a copy of its own (pub
  get, analyze, the app's tests, the release APK, and, when dependencies
  or Android files changed, a build over the base's build) and leaves a
  stamp for the commit.  This repository's `hand_in` (its dev plugin, not
  the harness) refuses a task that changed the app until the stamp covers
  the app as committed; quote the run as evidence.  A task's sandbox has
  no Android SDK: add `--accept-android-licenses` there, and the first run
  installs Flutter, a JDK and an Android SDK of its own into a cache the
  next run reuses, accepting the licences of that SDK only (where an SDK is
  installed the flag does nothing).  `--quick` analyzes and tests the
  working tree in a few minutes while you work.  If it cannot run here,
  hand in with `cannot_continue` and say why.  See
  [docs/dev-loop.md](docs/dev-loop.md).
- A UI change is verified in a live harness (`scripts/dev.sh start`,
  `... keys ...`, `... shot`) and the screenshot is evidence in the
  report; see [docs/dev-loop.md](docs/dev-loop.md).
