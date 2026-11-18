# Off-by-default modules: supervisor and otel

## The problem

`harness-enabled-modules` decides what loads besides the core.  A list
names the modules to add, and `t` asks for every module.  Many users,
and this repository's own development harness, run with `t`, so the
whole harness loads: including the `supervisor` module, which makes a
session plan and delegate instead of doing the work itself, and the
`otel` module, which exports what sessions do to a collector.  Both are
features a user should choose, not behavior a harness takes on because
it was asked for every module.

Today the choice is all or nothing: `t` loads them, and a list has to
name every module the user wants if it is to leave them out.  There is
no way to say "every module except these two", and
`harness-disabled-modules` is the wrong tool: it means never, a veto
that also fails the modules requiring the one it names.

## The decision

Add `harness-off-by-default-modules`, a list of module names that
`harness-enabled-modules` `t` leaves out.  It ships as
`(supervisor otel)`.  Such a module loads when:

- `harness-enabled-modules` is a list naming it (an explicit list is
  the user saying what they want, so it overrides the default), or
- a module that loads requires it, or is its other half
  (`harness--module-closure`), or
- the user runs `M-x harness-enable-module` on it.  With `t`, that
  takes it off `harness-off-by-default-modules` for this Emacs
  session, and says to remove it from the option in the init file to
  keep it.

`harness-disabled-modules` keeps its meaning and still wins: a module
it names loads under no setting.  The option decides only what `t`
selects; the core always loads, and a list is explicit.

## Why this shape

**A default value of the disabled list.**  `(setq
harness-disabled-modules '(supervisor otel))` would also keep the two
out of `t`, but it changes the meaning of the option from "never load
this" to "off by default", and a user who customizes it to their own
short list silently re-enables both.  The veto should stay a veto.

**A per-module `:opt-in t` keyword.**  Having each module say it is
not part of the every-module set is tidy, and the loader already reads
a module's `harness-define-module` form from its source without loading
it.  But it still needs a way to express "t plus this one" for
`harness-enable-module`, and it puts a distribution decision inside
every module.  A single option is one place to read, customize and
document, and it can list a module of the user's own as well.

**Leaving it to `harness-enable-modules` in the init file.**  A list
naming all the other modules works today, but it is long, goes stale as
modules are added, and cannot express the user's actual request: "all
of them except these".  `t` with an exception list does.

## Shape of the change

- `harness.el`: the new defcustom; `harness-module-off-by-default-p`,
  which follows a module's other half as `harness--module-disabled-p`
  does; `harness--selected-modules` starts the `t` case from every
  module not off by default and closes over what they require;
  `harness-enable-module` takes a named off-by-default module off the
  list for the session; `harness--modules-not-loaded` lists them as
  available even under `t`, so `M-x harness-describe-modules` and the
  module list show them.
- `lisp/modules/harness-config.el`: `config/describe` hides the option
  with the other module-selection options; it decides how the harness
  starts, which a running harness cannot change under itself.
- `lisp/harness-module-docs.el`: a page says "only when named" for an
  off-by-default module, and the index says `t` leaves them out.
- `scripts/harness-dev.el` and `scripts/harness-media.el` set the
  option to nil: both are explicit all-features worlds, and their job
  is to show and try everything.
- README and `docs/architecture.md` say what `t` leaves out, and the
  README's example configurations no longer name `supervisor`.

## What is seen

- A harness started with `(setq harness-enabled-modules t)` no longer
  loads `supervisor` (nor `ui-supervisor`) or `otel`, so no session is
  judged into supervisor mode and nothing is exported unasked.
- `M-x harness-describe-modules` lists both as available; `M-x
  harness-enable-module` on one loads it at once, and `(setq
  harness-off-by-default-modules nil)` restores the old "t loads every
  module".
- A list that names them, as the README's module template does,
  still loads them with what they require and their UI halves.

## Verification

`test/harness-core-test.el` covers the selection with a tree of small
modules (t leaves an off-by-default module out, a name loads it, a
requiring module brings it, the disabled list still wins), the real
tree (supervisor and otel ship in the option, are not selected with t,
and are selected when named, with `ui-supervisor`), and the interactive
path (`harness-enable-module` under t).  The module-docs, config,
server, supervisor and policy suites run as they did, and the full
suite is run before hand-in.
