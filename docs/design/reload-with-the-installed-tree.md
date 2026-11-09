# Reload with the tree an update installed

## The problem

An update installs a tree that another Emacs checked: `harness.el'
loads, every source compiles, no conflict marker is in the code
(`harness--verify-commit').  The checkout is fast-forwarded to it, and
then the harness reloads -- with the code that is **running**, which is
the version from before the update.

What that older code loads is what it believed its tree holds:
`harness--module-files' of its own version, its own list of core and
library files, its own idea of where a required library lives.  When
the update changes any of that, the running reload checks files the
installed tree does not load, or looks for a helper the tree puts
somewhere the running `load-path' does not have.  Its check fails, the
reload is refused, and the update stops one step short: the checkout is
new, the Emacs still runs the old code, and the message says to restart
Emacs.

The case that prompted this: `cf174aa` moved every module's tests beside
the module (`docs/design/co-located-module-tests.md`).  A harness from
before the move, with `harness-enabled-modules' t, took
`lisp/ui/harness-ui-*-test.el' for modules when it reloaded, compiled
them, and each requires `harness-test-helpers' from `test/', which only
the new tree's `harness.el' puts on `load-path'.  All 63 suites failed to
compile, and a 27-commit update ended in "restart Emacs".

## The change

`harness--update-reload' runs after an update in place of the bare
`harness--reload'.  It calls the running code's reload first, and

- when that succeeds, returns it unchanged;
- when it is refused, **and the update installed a commit it fetched**,
  loads the installed tree's `harness.el' and calls `harness--reload'
  again -- now the new definition, which knows what the tree holds;
- when that first reload is refused and nothing was installed (a
  checkout that moved on by itself), returns the refusal: no Emacs
  checked that tree;
- when the tree's `harness.el' cannot load, logs it and returns the
  first refusal, so the message is the one that already says how to
  restart or how to go back.

`harness--updated' passes `(> count 0)` as "installed": a non-zero count
means `harness--update-result' fast-forwarded the checkout to a commit
`harness--verify-commit' checked.  Straight.el's pull is the same: it
lands on a commit `harness--update-result' verified, and a commit that
fails the check is reset.  The retry calls the tree's `harness--reload'
with NO-PROCESS only where its arity takes it, so a tree whose reload
has no such argument still runs, as it is.

## The harness process

With `harness-process' on, the reload also asks the harness process to
load the tree (`harness-ui-reload-server', the `harness/reload' method of
harness-server.el).  That process runs the same pre-update code and would
refuse the same tree, so the retry does not ask it: `harness--reload'
takes NO-PROCESS for that, and the result carries `:process-stale'.  Only
a restart teaches the process the tree, so the version page keeps its
`[Restart]' for an update whose reload left it behind
(`harness-ui-version--restart-action'), and the message says the restart
loads it.  A retry the installed tree refuses asks for no restart on
that account, as before: the first refusal's own message says what
still runs.

## Why loading the new `harness.el' is safe here

The reload's design is check-before-load: nothing is loaded while a file
fails to compile.  Loading `harness.el' before a check looks like a
breach of that, so it is worth being precise about what the check buys.

`harness--verify-commit' runs the new tree's `harness.el' in a fresh
Emacs and byte-compiles every source in the tree.  A tree that passes
that check has a `harness.el' that loads, every file after it included,
so loading it into the running Emacs is the same act the check already
performed on the same bytes -- with the difference that here the old
modules are loaded alongside, which is the state every reload leaves
anyway.  What the check cannot promise is that the new modules' `init'
succeeds in this Emacs; the reload reports those as `:errors` without
refusing, as it always has.

What makes this safe is exactly the restriction: only a tree the update
installed is loaded, and only after its own reload was refused.  A
checkout that moved on by itself -- a package manager's pull, or one by
hand -- was checked by nobody, and the running code's refusal stands.

## Alternatives

- **Make the new tree compile under the old loader.**  Keep
  `harness-test-helpers` somewhere the old `load-path` already has, e.g.
  `lisp/`.  It works for this one transition, but not in general: a
  future update that moves a file, renames a module or changes what the
  reload checks would fail the same way, and each such move would need
  the old release to have predicted it.  It also makes the helper a
  module or a permanent special case.
- **Keep the old reload from seeing test files.**  It cannot be done
  from the new tree: the old code's module scan is what it is, and
  teaching it to skip tests is what `cf174aa` already did for every
  release from then on.  Putting the helper on `load-path` early would
  load the suites as modules, which is what the co-location work was
  careful not to do.
- **Roll the checkout back when the reload is refused.**  Leaves a
  consistent tree, but throws away a verified update, and a restart is
the only way to get it back.  The message already offers the reset for
  whoever wants it (`git -C DIR reset --keep FROM`).
- **Restart Emacs for them.**  `harness-restart' restarts the harness
  process, not the user's Emacs, and the user's Emacs is where the old
  code runs.

## What the user sees

One echo-area status, and only when the harness process was left
behind: `Harness updated from A to B (N commits) and reloaded ·
harness process: restart`, in the version page's existing
`[Restart]` there and the same nouns and status as the rest of the
page.  An update that finishes this way and runs its own process in
this Emacs says what a reload that worked always said -- "Harness
updated from A to B (N commits) and reloaded" -- because it did
reload.  A refusal that stands keeps its message and the version
page's `[Restart]`.  The harness log gets one line naming the refusal
that was retried.

## Verification

- `test/harness-update-test.el`:
  `harness-update-reload-of-an-installed-tree-loads-its-harness-el`
  (the retry runs the tree's reload, whose result is the update's, and
  leaves the harness process marked for a restart),
  `harness-update-reload-of-a-tree-that-moved-on-keeps-the-refusal`
  (nothing installed: no `harness.el` is loaded),
  `harness-update-reload-of-an-installed-tree-that-does-not-load-keeps-the-refusal`
  (a broken installed entry point leaves the first refusal).
- `lisp/ui/harness-ui-version-test.el`:
  `harness-ui-version-restarts-for-a-process-left-behind` (the restart
  the stale process needs, and only on this Emacs's own process).
- The existing suite still holds the messages for a refusal that stands
  (`harness-update-command-reports-a-refused-reload',
  `harness-update-reload-of-a-checkout-that-moved-on-refused').
- Checked by hand on a tree built for it: a checkout whose own
  `harness.el' puts a directory the running one does not know on
  `load-path', with a module that requires its helper.  The running
  reload refused it (`harness-newmod.el: Byte compilation failed');
  after the retry the same process reloaded all 190 files with no
  refusal, and with `harness-process' on it came back marked
  `:process-stale`.  The 7c45441 harness against the whole current
  tree refuses the reload with 180 problems, every one of them a
  suite; the same tree's own `harness.el' reloads it, 189 files.
- Focused runs of the update suite, `lisp/harness-core-test.el`'s
  loader and reload tests, and the version page's; every production
  source byte-compiles, as `scripts/lint.sh' does it.  The full
  `scripts/test.sh' run is what remains, and it needs the shell.
