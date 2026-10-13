# Vendored libraries

Libraries the harness uses that are not part of it. Each subdirectory
holds one library, laid out as its own repository would be -- its source,
tests, README and LICENSE -- so that it can move to a repository of its
own without moving a file (see [Splitting a library
out](#splitting-a-library-out)).

| Library | Upstream | Vendored commit |
|---|---|---|
| [compose-quote](compose-quote/README.md) | not split out yet: this directory is its source | -- |

## The rule

A vendored library needs nothing of the harness and never mentions it in
its Emacs Lisp files: no `harness` name, no `(require 'harness-...)`, not
even in a comment or a docstring. The harness depends on the library,
never the other way round. What ties the two together lives on the
harness's side, in its own files, which set the library's variables and
bind its commands: the compose box sets compose-quote's
`compose-quote-source-function` to `harness-ui-markdown-source`, say.

Its README may say where it comes from. Its tests run with nothing else:
`emacs -Q --batch -L DIR -l NAME-test.el -f ert-run-tests-batch-and-exit`.

`harness-vendored-libraries-stand-alone` in `test/harness-core-test.el`
checks the rule: it reads every `.el` file of every library for the word
"harness", and runs every `*-test.el` suite in an Emacs with nothing but
the library's own directory on its load path.

## How the harness loads it

- **The load path.** `harness.el` puts each directory of `lisp/vendor` on
  `load-path` as it loads (`harness--vendored-directories`), and
  `harness--setup-load-path` does so again whenever the harness starts or
  reloads. So any Emacs that loads `harness.el` finds the libraries: the
  tests, the harness process, and the update check of a harness older
  than this one, which loads the new `harness.el` before it compiles the
  new files and so can `require` a library they need.
- **Loading.** A library the harness needs is listed in
  `harness--library-files` (compose-quote is, last): it loads compiled,
  before any module, when the harness starts, and `harness-reload`
  checks that it compiles and loads it again. One that is only on the
  load path is loaded from its source on its first `require`, and not
  reloaded.
- **The update check.** `harness-update` checks a version out and
  compiles it elsewhere before it installs it (`harness--verify-program`).
  The check puts the libraries' directories on its load path too and
  compiles every `.el` file of a library except its tests
  (`NAME-test.el`), so a library that does not compile is refused like
  any other file.
- **The linter.** `scripts/lint.sh` does the same: each library is on its
  load path, and its files, tests aside, are compiled.
- **The tests.** `scripts/test.sh` runs `lisp/vendor/*/*-test.el` with the
  harness's suites, each in a clean Emacs with the harness loaded.
- **Auto reload.** `harness-auto-reload-mode` watches the libraries'
  directories with the harness's own.

## Adding a library

1. Put it in `lisp/vendor/NAME/`, laid out as its own repository: `NAME.el`
   with the usual header and `Package-Requires`, `NAME-test.el`, a
   `README.md`, a `LICENSE`. Keep to the rule above.
2. If the harness needs it at start, add `"lisp/vendor/NAME/NAME.el"` to
   `harness--library-files` in `harness.el`. Nothing else lists it: the
   load path, the update check, `scripts/lint.sh` and `scripts/test.sh`
   find a library by its directory.
3. Add it to the table above.

## Splitting a library out

While the library is developed here, this directory is its source. To
give it a repository of its own with its history, split its commits off
the harness's:

```sh
git subtree split --prefix=lisp/vendor/compose-quote -b compose-quote
git push URL compose-quote:main
```

URL is the new repository's (an empty one). Then record URL in the table
above as the library's upstream, and the commit just pushed
(`git rev-parse compose-quote`) as the vendored commit.

From then on the library is taken from its repository. But
`git subtree pull --squash` refuses a directory that was only split off
("was never added"): it looks for the library commit last taken in the
message of a squash commit, which only `git subtree add --squash` makes.
So take the directory again, from the repository, once:

```sh
git rm -r lisp/vendor/compose-quote
git commit -m "Take compose-quote from its repository"
git subtree add --prefix=lisp/vendor/compose-quote URL main --squash
```

The files end up as they were, as the repository holds what was just
pushed. The squash commit names the library's commit in its message
(`git-subtree-split: COMMIT`), which `git log --grep git-subtree-split
-- lisp/vendor/compose-quote` finds.

## Updating a library

Take what its repository has gained, and record the commit in the table
above (the `git-subtree-split:` line of the new squash commit has it):

```sh
git subtree pull --prefix=lisp/vendor/compose-quote URL main --squash
```

A change made here, in the harness's checkout, goes upstream with:

```sh
git subtree push --prefix=lisp/vendor/compose-quote URL main
```

If the repository has moved on since, the push is refused: pull first,
then push.

## Installing

Nothing to install. The harness ships its libraries: the recipes in the
main README for Doom, straight.el and elpaca take the whole `lisp`
directory, the one this directory is in, and the harness runs from its
clone, where `harness.el` finds `lisp/vendor`. A library that lives in its
own repository can also be installed on its own, by its README, to use
without the harness.
