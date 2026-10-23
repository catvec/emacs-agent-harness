;;; harness-dev-plugin.el --- The harness repository's own plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; What the repository's .dir-locals.el requires, from the main
;; checkout only: not from a checkout nested in another, such as a
;; task's worktree in .worktrees/, whose files an agent writes.  It
;; names tools-dev in `harness-plugin-modules' beside.
;;
;; Emacs asks before applying those entries, as it does for any
;; project's `eval' entry and for a variable that is not safe as it is;
;; answering `!' trusts them for good.  See lisp/modules/harness-plugins.el
;; for how the harness process applies them too, with what you trust.
;;
;; The harness runs in two Emacsen, and each takes its half of the
;; plugin, once the part of the harness that half needs has loaded:
;;
;; - harness-tools-dev.el, module tools-dev: the open_harness tool, in
;;   the Emacs where the harness's tools are (the harness process);
;; - harness-ui-tools-dev.el, module ui-tools-dev: Open harness on the
;;   task board, in the Emacs that shows the board (yours);
;; - harness-client-check.el, module client-check: what this repository
;;   asks of a task before it hands in a change to its Flutter app --
;;   that the app was built -- in the harness process, where hand_in
;;   runs.
;;
;; The sessions that name tools-dev in `harness-plugin-modules', as the
;; repository's .dir-locals.el does, get the tool; no other does.  The
;; sessions that name client-check, as that file does too, are asked for
;; the app's build check when they hand in, and no other session is.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (with-eval-after-load 'harness-tools
    (require 'harness-tools-dev (expand-file-name "harness-tools-dev" dir)))
  (with-eval-after-load 'harness-tools-handin
    (require 'harness-client-check (expand-file-name "harness-client-check" dir)))
  (with-eval-after-load 'harness-ui-tasks
    (require 'harness-ui-tools-dev (expand-file-name "harness-ui-tools-dev" dir))))

(provide 'harness-dev-plugin)
;;; harness-dev-plugin.el ends here
