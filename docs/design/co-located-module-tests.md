# Tests beside their modules

## The change

A module's tests now live beside it: `harness-NAME-test.el` next to
`harness-NAME.el`, in `lisp/`, `lisp/modules/`, `lisp/ui/`, and a
project plugin's directory under `.harness/plugins/NAME/`. Moving or
deleting a module file therefore moves or deletes its tests with it,
instead of leaving them behind in a central `test/` directory.

This is the rule the vendored libraries already follow:
`lisp/vendor/NAME/` holds `NAME.el`, `NAME-test.el`, its README and its
LICENSE, so the directory can move to a repository of its own without
moving a file ([lisp/vendor/README.md](../../lisp/vendor/README.md)).

## Why

Most suites in `test/` were named after their modules, but a module
lived in `lisp/modules/` or `lisp/ui/` and its tests somewhere else.
Renaming, moving or deleting a module left a test file that no longer
had a module to test, and nothing noticed: the suite kept passing
against whatever module still happened to be there. The distance also
made it easy to forget the tests when the module is a plugin, or to
add a suite to `test/` that no module owns.

Colocation makes the association visible in a directory listing, lets
`git mv` and `rm` carry both files together, and gives the test runner
a mechanical rule for which suites a module change touches.

## Layout

| Source | Tests |
|---|---|
| `lisp/harness-NAME.el` | `lisp/harness-NAME-test.el` |
| `lisp/modules/harness-NAME.el` | `lisp/modules/harness-NAME-test.el` |
| `lisp/ui/harness-ui-NAME.el` | `lisp/ui/harness-ui-NAME-test.el` |
| `.harness/plugins/NAME/harness-NAME.el` | `.harness/plugins/NAME/harness-NAME-test.el` |
| `lisp/vendor/NAME/NAME.el` | `lisp/vendor/NAME/NAME-test.el` (already) |

A module may have more than one suite: `harness-cache.el` has
`harness-cache-test.el`, `harness-cache-compact-test.el`,
`harness-cache-dropped-test.el` and `harness-cache-warm-test.el`. The
file name carries the module's name as a prefix, and the longest
matching module beside it is the one it belongs to.

A suite that spans modules belongs beside the module it mainly tests,
with that module's name as its prefix. `test/harness-internal-test.el`
became `lisp/modules/harness-session-internal-test.el`; the ACP client
and TCP suites stay beside `harness-acp.el` as
`harness-acp-client-test.el` and `harness-acp-tcp-test.el`.

## What stays in `test/`

`test/` keeps what belongs to the repository rather than to one module:

- the shared helpers (`harness-test-helpers.el`) and fixtures under
  `test/fixtures/`, the ACP client `.mjs` and the Python voice fixtures;
- the suites that test the repository itself: the dev loop's frames,
  the README's pictures, the test runner, `harness-update` (which lives
  in `harness.el`), and the Python voice gate.

`test/harness-test-layout-test.el` names those repository suites
explicitly and fails when a module suite is added back to `test/`, or
when a suite beside a module names no module there. Adding a module's
suite to `test/` is therefore a decision, not a slow drift.

## Not modules

The harness enumerates module files to load, document and reload them.
A test file is not a module, even though `harness-cache-test.el`
matches the old `harness-NAME.el` pattern. The places that enumerate
modules now filter `-test.el` out:

- `harness--module-sources` (which also covers user module
  directories) and thus `harness-start`, `harness-reload`, module
  selection and `harness-describe-module`;
- the update check's byte-compilation of every source file;
- `harness-module-docs-files`;
- `harness-auto-reload-mode`, which does not reload the harness when a
  test file is saved;
- `scripts/lint.sh`, which compiles production sources only.

Tests that read the tree themselves (prompt registry, config options,
UI call sites, version headers, frame audit, patch-review ownership)
also skip `*-test.el`, so a test's own source cannot satisfy a check
about production code.

## Updating from a version before the move

An installed harness checks an update before installing it, and a
harness built before this move has a check that knows nothing of it:
it byte-compiles every `harness-*.el` under `lisp/`, the suites among
them, with the tree's `lisp` directories and no `test/` on
`load-path`.  Each suite then fails to load `harness-test-helpers`,
and the update is refused as broken.

That check loads the new `harness.el` first, so `harness.el` puts the
tree's `test/` on `load-path` as it loads, at the end and only when the
directory exists.  The helper is found and the suites compile.
`harness-loading-harness-el-finds-the-test-helper`
\(`lisp/harness-core-test.el`) holds this: it loads `harness.el` with
the older check's `load-path` and compiles a suite that requires the
helper.

What that check compiles, it also checks for what a test run does not:
a suite is loaded, never byte-compiled, by `scripts/test.sh`, and
`scripts/lint.sh` compiles production sources only.  A lambda list the
compiler refuses -- `(lambda (t) ...)` binds a constant -- therefore
passed every test and was found only when an older harness's update
check compiled the suite and refused the update.
`harness-suites-have-lambda-lists-the-byte-compiler-accepts` reads
every suite and holds its lambda lists to the compiler's own
`byte-compile-check-lambda-list', which finds such a list in seconds
where compiling every suite would take a minute.

A harness from before the move that is already running, with
`harness-enabled-modules` t, still takes every file under the module
directories for a module when it reloads after such an update -- its
module list leaves out only what its code knew to leave out -- and
compiles the suites before it loads the new `harness.el`.  Its reload is
refused, and the update does not end there: the tree it installed was
checked by another Emacs, so its own `harness.el` is loaded and its
reload, which leaves the tests out, finishes the update in place
\(`harness--update-reload`, see
[reload-with-the-installed-tree.md](reload-with-the-installed-tree.md)).
Making the old reload find the helper instead would load the suites into
the running harness as if they were modules, which is what this change
makes sure never happens.

## Test runner

`scripts/test.sh` discovers suites in `lisp/`, `lisp/modules/`,
`lisp/ui/`, `.harness/plugins/*/` and `test/`, not from one glob.
The vendored suites are not run there: `harness-core-test` runs each in
an Emacs that has only its library, as before.

`--changed` maps a changed module to its sibling test, the suites whose
names begin with the module's name, and any suite that names it. A
changed test runs itself, a test helper or fixture runs every suite,
and a changed vendor file runs `lisp/harness-core-test.el`.

`scripts/test.sh` remains the only entry point. The ERT test names and
selectors in existing commands still work: only the file paths change,
and the seven files whose old names carried no module name were renamed
to carry one (`harness-internal-test.el` to
`harness-session-internal-test.el`, and so on).

## Alternatives

- **A mirrored `test/modules/` and `test/ui/` tree.** Still a second
  tree: deleting a module leaves its test behind, and moving a module
  between `lisp/modules` and `lisp/ui` means moving its test between
  two test directories.
- **A directory per module** (`lisp/modules/harness-cache/` holding the
  module and its test), as the vendored libraries do. That is the
  strongest colocation, but it changes the module loader, the public
  file layout and every `require` path; the sibling-file rule gives the
  association the task asks for without that change.
- **Only colocate tests whose file name equals a module name.** That
  leaves the forty suites whose names carry an aspect
  (`harness-provider-claude-native-test.el`) or a different module name
  (`harness-thread-test.el`) in `test/`, so deleting a provider or
  thread module would still leave tests behind.

## Verification

- `test/harness-test-layout-test.el` checks the rule over every suite
  in the tree, including the vendored libraries.
- `test/harness-test-runner-test.el` checks that a test beside a module
  is discovered, that a repository suite in `test/` still is, and that
  `--changed` on a module runs the test beside it.
- `scripts/test.sh` on the moved suites, `scripts/lint.sh`, and a full
  run of the committed tree.
