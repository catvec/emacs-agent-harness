;;; Directory Local Variables         -*- no-byte-compile: t; -*-
;;; For more information see (info "(emacs) Directory Variables")

;; This repository's own harness plugin (.harness/plugins/dev/): the
;; open_harness tool and the task board's Open harness, for trying
;; harness work live.  Emacs asks before applying these entries; answer
;; `!' to trust them, and the harness then gives the plugin's tool to
;; this repository's sessions.  The plugin loads from the main checkout
;; only, never from a checkout nested in another, such as a task's
;; worktree in .worktrees/, whose files an agent writes: Emacs trusts
;; these entries wherever this file is.  See README.md, "A project's
;; own plugins".
((nil . ((eval . (let ((top (locate-dominating-file default-directory ".dir-locals.el")))
                   (unless (locate-dominating-file
                            (file-name-directory (directory-file-name top))
                            (lambda (dir) (and (not (file-equal-p dir "~"))
                                               (file-exists-p (expand-file-name ".git" dir)))))
                     (require 'harness-dev-plugin
                              (expand-file-name ".harness/plugins/dev/harness-dev-plugin" top)))))
         (harness-plugin-modules . (tools-dev)))))
