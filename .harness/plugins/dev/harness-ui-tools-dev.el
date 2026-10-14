;;; harness-ui-tools-dev.el --- Open harness on the task board  -*- lexical-binding: t; -*-

;;; Commentary:

;; The half of this repository's dev plugin that lives in the user's
;; Emacs (harness-tools-dev.el beside it is the harness's half).  The
;; repository's .dir-locals.el loads it once a file of the repository
;; is visited and Emacs was told to trust that file's entries; see
;; harness-dev-plugin.el beside it for how.
;;
;; A card waiting for review whose worktree is a checkout of the harness
;; -- harness.el and scripts/dev.sh side by side -- has Open harness in
;; its menu (`mouse-3'): it opens an Emacs running that worktree's
;; harness in an instance of its own, its frame raised, so the work can
;; be tried before it is verified.  The harness's `harness-dev/open'
;; starts that Emacs, and stops it once the task is done, archived or
;; deleted.  It is not one of the card's buttons, which the board keeps
;; for its own actions (`harness-ui-tasks-action-functions').

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

(defvar harness-ui-tasks-action-functions)
(declare-function harness-ui-tasks-task-at-point "harness-ui-tasks" (&optional noerror))
(declare-function harness-ui-tasks-request "harness-ui-tasks" (method params what &optional callback))

(defun harness-ui-tools-dev-checkout-p (dir)
  "Non-nil when DIR is a checkout of the harness: harness.el and scripts/dev.sh."
  (and (stringp dir)
       (not (file-remote-p dir))
       (file-exists-p (expand-file-name "harness.el" dir))
       (file-exists-p (expand-file-name "scripts/dev.sh" dir))))

(defun harness-ui-tools-dev-open-p (task)
  "Non-nil when TASK's worktree can be run as a harness of its own.
That is a task waiting for review, not archived, whose worktree is a
checkout of the harness (`harness-ui-tools-dev-checkout-p'): the work
it handed in can then be tried live before verifying it."
  (and (equal (plist-get task :state) "review")
       (not (harness-json-true-p (plist-get task :archived)))
       (harness-ui-tools-dev-checkout-p (plist-get task :worktree))))

(defun harness-ui-tools-dev--actions (task)
  "Return Open harness when TASK's worktree can run as a harness, else nil.
One of `harness-ui-tasks-action-functions'."
  (and (harness-ui-tools-dev-open-p task)
       '(("Open harness" harness-ui-tools-dev-open-harness))))

(defun harness-ui-tools-dev-open-harness ()
  "Open an Emacs running the harness from the worktree of the task at point.
The task waits for your review, and its worktree is a checkout of the
harness; the card's menu (`mouse-3') offers it then.  This is not the
task's session, which a click on the card's title opens."
  (interactive)
  (let* ((task (harness-ui-tasks-task-at-point))
         (dir (plist-get task :worktree)))
    (unless (equal (plist-get task :state) "review")
      (user-error "This task is not waiting for your review"))
    (unless (harness-ui-tools-dev-open-p task)
      (user-error "This task's worktree is not a checkout of the harness"))
    (harness-ui-tasks-request
     "_harness/harness-dev/open" (list :path dir :focus t)
     "Opening the worktree harness"
     (lambda (info)
       (message "Harness from %s is open in Emacs (socket %s)"
                (abbreviate-file-name dir) (plist-get info :socket))))))

(defun harness-ui-tools-dev--init ()
  "Offer Open harness in the menu of the cards it applies to."
  (add-hook 'harness-ui-tasks-action-functions #'harness-ui-tools-dev--actions))

(defun harness-ui-tools-dev--shutdown ()
  "Offer Open harness no more."
  (remove-hook 'harness-ui-tasks-action-functions #'harness-ui-tools-dev--actions))

(harness-define-module 'ui-tools-dev
  :doc "Open harness on the task board (this repository's plugin)."
  :requires '(ui-tasks)
  :init #'harness-ui-tools-dev--init
  :shutdown #'harness-ui-tools-dev--shutdown)

;; A reload does not initialise a running module again.
(when (harness-module-ready-p 'ui-tools-dev)
  (harness-ui-tools-dev--init))

(provide 'harness-ui-tools-dev)
;;; harness-ui-tools-dev.el ends here
