# worktree-assume

Assume a git worktree as the project, the way you assume a role: until
you reset, the project is that worktree.

A repository often has more than one working tree. `git worktree add`
makes another one, on another branch, in another directory: a change
under review, the checkout an agent works in, a hotfix. To look at its
files you used to find out where it is and open it in Dired. With
worktree-assume you pick it, and from then on it *is* the project:

```
~/src/app/                        the project, its main worktree
~/src/app/.worktrees/fix-login    another worktree of it, branch fix-login

M-x worktree-assume RET .worktrees/fix-login RET
C-x p f                           finds the files of fix-login
C-x p D                           opens fix-login in Dired
C-x p g                           greps fix-login
M-x worktree-assume-reset
C-x p f                           finds the files of ~/src/app/ again
```

That works from any buffer of the project: the one you were in when you
assumed, a file of `~/src/app/`, a buffer that is nowhere near a file. It
is the *project* that changes, not the buffers: a file you had open in
`~/src/app/` stays what it is, and `C-x p f` opens the worktree's copy
of a file beside it.

worktree-assume is developed inside the
[Emacs agent harness](https://git.sr.ht/~catvec/emacs-agent-harness)
repository for now, in `lisp/vendor/worktree-assume`, laid out as its own
repository will be once it is split out. It needs nothing of the
harness, and nothing but Emacs 29.1 or later and git (2.7 or later, which
lists worktrees in a form made for programs). The harness uses it to look
at the files of a task under review, through an adapter that lives on the
harness's side.

## Commands

| Command | Does |
| --- | --- |
| `worktree-assume` | Pick one of the other worktrees of the current project's repository and assume it. Assuming another one replaces it. |
| `worktree-assume-reset` | Go back: the project is its own worktree again. It resets the assumption of this buffer's project, or the only one there is, or asks; with `C-u`, all of them. |
| `worktree-assume-status` | Say which worktrees are assumed, for which projects. |
| `worktree-assume-mode` | The global mode that makes assumptions count. `worktree-assume` turns it on, turning it off resets every assumption. |

No key is bound. To bind them in the project map:

```elisp
(with-eval-after-load 'project
  (keymap-set project-prefix-map "a" #'worktree-assume)
  (keymap-set project-prefix-map "A" #'worktree-assume-reset))
```

While a worktree is assumed the mode line says so (`⇒fix-login`, or `⇒2`
when two projects have one), and hovering over it names them
(`worktree-assume-lighter`, `worktree-assume-lighter-width`).

## What changes

Everything that asks which project a directory is in:

- **project.el.** `worktree-assume-mode` puts a finder at the head of
  `project-find-functions`. It asks the others for the project of the
  directory, and when a worktree stands in for that project, answers with
  the project in the worktree instead. So `project-current`,
  `project-root`, `project-files`, `project-find-file`, `project-dired`,
  `project-find-regexp`, `project-compile`, `project-shell`,
  `project-switch-project` and the rest work on the worktree.
- **projectile.** `projectile-project-root` is filtered the same way, and
  so everything built on it.

Only the directories of the project assumed *for* change. The worktree's
own directories, those of any other worktree and of other projects are
found as ever, so a buffer in the assumed worktree is in a project, the
worktree, before and after.

A project that is only a directory of its repository (a `.projectile`
file, `project-vc-extra-root-markers`) has the same directory of the
worktree assumed: `~/src/mono/web/` becomes `.worktrees/fix/web/`.

If the assumed worktree disappears (`git worktree remove`, a deleted
directory), the assumption is forgotten the next time anyone asks for
the project, and the project is its own again.

## Keeping the parent

The project assumed for is still known, for whatever should go on seeing
it: a tool that keeps its data per project would lose it all otherwise.

| | |
| --- | --- |
| `(worktree-assume-assumed DIR)` | The root of the worktree assumed for DIR's project, or nil. |
| `(worktree-assume-parent DIR)` | The root of the project a worktree is assumed for, when DIR is in that worktree, else nil. |
| `(worktree-assume-assumptions)` | All of them, an alist of `(PARENT . ASSUMED)` roots. |
| `(worktree-assume-with-parent BODY...)` | Evaluate BODY as if nothing were assumed: `project-current` and `projectile-project-root` find the project itself. Binds `worktree-assume-inhibit`. |
| `worktree-assume-change-functions` | Abnormal hook, run with `PARENT` and `ASSUMED` (nil on reset) when an assumption comes or goes. |
| `(worktree-assume-worktrees DIR)` | The worktrees of DIR's repository, a list of plists: `:path`, `:branch`, `:head`, `:main`, `:detached`, `:bare`, `:locked`, `:prunable`. |

For instance, to keep a cache keyed by the real project:

```elisp
(defun my-project-key (dir)
  (worktree-assume-with-parent
    (when-let* ((project (project-current nil dir)))
      (project-root project))))
```

`worktree-assume` itself is `(worktree-assume WORKTREE &optional
PROJECT)`: WORKTREE is the top directory of another worktree of the
repository, PROJECT a directory of the project it stands in for
(`default-directory` by default). It returns `(PARENT . ASSUMED)`, and
signals a `user-error` where WORKTREE is not one, its directory is gone,
or PROJECT is no git project.

## Limits

- **Local git worktrees.** A remote (TRAMP) project is left alone.
- **One assumption for each project, for the whole Emacs.** It is not per
  frame, per tab or per buffer.
- **The project, not the files.** A language server started for a
  buffer of the project (Eglot, lsp-mode) asks for the project, so it
  gets the worktree while one is assumed. Reset before editing the
  project itself, or edit in the worktree.
- **Only what asks for the project.** `magit-status` and `vc-dir` run
  from `default-directory`: use `project-vc-dir` (`C-x p v`), or the
  magit command that asks project.el, to see the worktree.
- **Everything that asks, from a buffer of the project.** `C-x p b` and
  `C-x p k` list and kill the worktree's buffers, not the buffer's own
  project's, while a worktree is assumed, and project.el and projectile
  remember the worktree among their known projects as they do any project
  you use. A finder another package puts ahead of the library's (depth
  -90 in `project-find-functions`) is asked first and wins.
- **Projectile's roots are projectile's.** The assumption is of the
  project's root as it is found: where projectile and project.el disagree
  on it (a `.projectile` file below the repository's top, say), the one
  that finds the root the assumption was made for sees it, and the other
  finds a project that nothing stands in for.

## Installing

If you use the Emacs agent harness, you have it already: the harness
ships it and loads it.

Otherwise, until it has a repository of its own, install it from the
harness's, taking only its file.

With [Doom Emacs](https://github.com/doomemacs/doomemacs), in
`packages.el`:

```elisp
(package! worktree-assume
  :recipe (:host sourcehut :repo "catvec/emacs-agent-harness"
           :files ("lisp/vendor/worktree-assume/worktree-assume.el")))
```

With [straight.el](https://github.com/radian-software/straight.el):

```elisp
(straight-use-package
 '(worktree-assume :host sourcehut :repo "catvec/emacs-agent-harness"
                   :files ("lisp/vendor/worktree-assume/worktree-assume.el")))
```

With [Elpaca](https://github.com/progfolio/elpaca):

```elisp
(elpaca (worktree-assume :host sourcehut :repo "catvec/emacs-agent-harness"
                         :files ("lisp/vendor/worktree-assume/worktree-assume.el")))
```

Or by hand, from a clone:

```elisp
(add-to-list 'load-path "~/src/emacs-agent-harness/lisp/vendor/worktree-assume")
(require 'worktree-assume)
```

`M-x worktree-assume` loads it and turns it on by itself; to have the
mode on from the start, `(worktree-assume-mode 1)` in your init file does
no harm: with nothing assumed it changes nothing.

Once it is split out into a repository of its own, the recipes name that
repository instead, with no `:files`.

## Developing

```sh
make test      # the tests, in an Emacs with nothing but this directory
make compile   # byte-compile, warnings as errors
```

The tests make real repositories with real worktrees in a temporary
directory, so they need git.

## License

GPL-3.0-or-later: see [LICENSE](LICENSE).
