# A test file is never a module, and another harness's task store is never taken over

Two defects let a test or development harness hide the user's task
board.  They compound: the second hid what the first moved, and either
alone is enough to lose the board.

## What went wrong

### 1. A fixtures file was loaded as a module

The harness enumerates every `harness-NAME.el` in `lisp/modules`,
`lisp/ui` and the user's module directories, and loads the ones
`harness-enabled-modules` selects.  A module's suite is left out by
name: `harness--module-file-p` rejected anything matching `-test\.el\'`.

That rule missed a suite's *fixtures*.  The OpenRouter suites share
`lisp/modules/harness-provider-openrouter-test-helpers.el`, which
matches `harness-NAME.el` and does not end in `-test.el`, so the loader
counted it as module `provider-openrouter-test-helpers`.  It is not in
`harness-core-modules`, so a default harness never loaded it -- but
`harness-enabled-modules` t loads every module that is not
off-by-default, and that is exactly what a development daemon,
`scripts/media.sh`, `tool/with_real_harness.sh` and this repository's
own `.harness/plugins/dev` set.  Under that setting the file loaded in
a **live** harness.

The file begins `(require 'harness-test-helpers)`.  That helper is the
suites' shared setup, and it does three things the moment it loads:

- `(setq harness-state-directory harness-test-state-root)`, a fresh
  `make-temp-file "harness-test-state-"`;
- `(setq harness-session--tmp-root <that dir>/session-tmp/)`;
- `(add-hook 'kill-emacs-hook ... (delete-directory harness-test-state-root t))`.

So a harness that loaded it restated itself into a throwaway directory
it had just made, and the reverse of the helper's own protection --
"nothing a run writes may reach the user's real `harness-state-directory'"
-- became the opposite: the user's real harness started writing
everywhere else.  Its sessions, its task board and its session
temporary directories were all in the state directory it had been
using, which it no longer looked at.  On exit, the kill hook deleted
the only state it did look at.

### 2. A repository store with an invisible owner was taken over

Each git project keeps its tasks in `.git/harness/tasks.json`, of the
form `{"state-directory": DIR, "tasks": [...]}`, where `DIR` names the
harness that owns the store.  `harness-tasks--open-store` decided
ownership as:

> a store naming another state directory **that still exists** is
> another harness's; one whose owner is gone is taken over.

The "still exists" test is `file-directory-p`, which is a question
about *this* process's view of the filesystem.  A suite runs in a
sandbox that hides `~/.emacs.d`, so the real harness's state directory
is invisible there; a store read from such a process is judged
ownerless and adopted.  The next save then rewrote the file with
`"state-directory": <the test run's temporary dir>`, and with its own
records.  The user's board was replaced in place, and from then on the
real harness saw a store belonging to a harness that no longer existed
-- and each test run repeated the takeover.

## What the fix decides

### The loader: one predicate for "this file holds tests"

`harness--test-file-p` now answers the question once, and everything
that enumerates modules uses it:

- `harness--module-file-p`, and through it `harness--module-sources`,
  `harness--module-files`, `harness-start`, `harness-reload`, module
  selection, `harness-describe-module` and the update check;
- `harness-module-docs-files`, so a fixtures file is not documented as
  a module either.

A file holds tests or their fixtures when its name matches
`-test\(?:-[a-z0-9-]+\)?\.el\'`: `harness-NAME-test.el`,
`harness-NAME-ASPECT-test.el` (`harness-acp-tcp-test.el`), and
`harness-NAME-test-helpers.el`.  Production names that merely contain
"test" -- there are none today, and `harness-testiness.el` is the
control in the test -- are unaffected.

As a second line of defence the helper itself now refuses to load into
a harness that is already running: it signals an error when
`harness-started` is non-nil.  That makes the helper safe even if some
future path requires it by name from a live process.

### The store: the owner's name is the whole of the ownership

`harness-tasks--store-mine-p` replaces the filesystem question with a
pure one:

> a store belongs to this harness when it names this harness's state
> directory, or when it names none (a bare array of records from before
> repository stores).  A store naming any other state directory is
> another harness's, whether or not that directory can be seen from
> here.

Consequences, all deliberately conservative:

- Another harness's store is never read for records, so its tasks never
  appear on this harness's board.
- It is never written, so `"state-directory"` is never rewritten and
  the owner's records stay where the owner put them.
- It is never dropped by `harness-tasks--drop-store`, so an empty
  foreign store survives this harness.
- Nothing is ever "taken over", so the old "the owner is gone" path --
  which cannot be told apart from "the owner is hidden from me" -- is
  gone.

## Alternatives considered

- **Check the owner's liveness rather than its visibility.** Tempting,
  but no test distinguishes "the directory is gone" from "this sandbox
  cannot see `~/.emacs.d`" -- which is exactly the confusion that
  caused the bug.  A store nobody can prove ownership of is better left
  untouched than adopted.
- **Keep takeover, but copy the store aside first.** It still rewrites
  the file the owner reads, and the owner's next save would then land
  on top of the takeover.
- **Rename the fixtures file.** That fixes today's instance and leaves
  the rule wrong: the next `NAME-test-helpers.el` or `NAME-fixtures.el`
  reopens it under a new name.  The predicate is the durable fix, and
  the helper's guard covers what the predicate cannot.
- **Refuse to load any file that `require`s `harness-test-helpers`.**
  Reads every module's source to decide, and the loader already reads
  headers; a name rule plus a helper guard does the same job without a
  new dependency on source scanning.

## What is tested

A live harness with every module enabled, run against the base commit
and this branch, is recorded in
[docs/evidence/not-a-module/before-after.md](../evidence/not-a-module/before-after.md)
with the probe it used: before, the chosen state directory is replaced
by a throwaway test directory and the shared helper is loaded into the
live harness; after, the chosen directory stands, the helper is never
loaded, and the task module keeps its repository store.

- `harness-loader-never-loads-a-test-file-as-a-module` (in
  `lisp/harness-core-test.el`) holds `harness--test-file-p`,
  `harness--module-file-p`, the sources with every module enabled, and
  the absence of `provider-openrouter-test-helpers` from them.  It
  fails on the old predicate.
- `harness-tasks-leave-another-harness-store-alone` (in
  `lisp/modules/harness-tasks-test.el`) writes a store owned by a
  *visible* other state directory and one owned by a *missing* one, and
  asserts both are byte-for-byte unchanged through a submit, a save and
  a restart, that neither's records appear, and that the missing
  owner's store is not registered as this harness's.
- `harness-tasks-kept-in-the-main-repository`,
  `harness-tasks-move-into-their-repositories`,
  `harness-tasks-unwritable-repository-store-falls-back` and the rest
  of the store suite still pass, so the ordinary paths are unchanged.
- `harness-skills-scan-bounds-what-it-lists` failed at the base commit,
  for an unrelated reason found while running the full suite (a
  skill's own `SKILL.md` took a place of its supporting-files bound);
  it is fixed here and now states which three files a bound of 3
  leaves.
