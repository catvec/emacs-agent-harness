;;; harness-ui-commit-msg.el --- Taking the commit-msg hook out of a repository  -*- lexical-binding: t; -*-

;;; Commentary:

;; The commit-msg module (lisp/modules/harness-commit-msg.el) installs a
;; `commit-msg' hook that takes Claude attribution out of commit
;; messages, in the repositories that turn
;; `harness-commit-msg-strip-attribution' on.  Turned off on the
;; settings page, the setting has the harness remove the hook at once;
;; turned off by hand in a .dir-locals.el, at its next start or reload.
;; `harness-commit-msg-uninstall' takes the hook out of one repository
;; now, through `_harness/commit-msg/uninstall', and says in the echo
;; area what happened.  A hook somebody else wrote is never touched.
;; While the setting still selects the repository the hook comes back,
;; and the message says the setting has to be turned off for it to stay
;; away.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defun harness-ui-commit-msg--describe (dir result)
  "Return in words what RESULT of `commit-msg/uninstall' for DIR says.
RESULT is (:repository MAIN :removed BOOL :reason REASON :selected
BOOL), as it comes over ACP: REASON a string, each BOOL t or :false."
  (let* ((main (plist-get result :repository))
         (where (abbreviate-file-name (directory-file-name (or main dir))))
         (reason (format "%s" (or (plist-get result :reason) ""))))
    (concat
     (if (harness-json-true-p (plist-get result :removed))
         (format "Removed the harness's commit-msg hook from %s" where)
       (pcase reason
         ("none" (format "%s has no commit-msg hook to remove" where))
         ("foreign" (format "Left the commit-msg hook of %s alone: the harness did not write it" where))
         ("hooks-path" (format "Left %s alone: its core.hooksPath puts the hooks elsewhere" where))
         ("remote" (format "%s is on another host, where the harness installs no hook" where))
         ("no-repository" (format "%s is in no local git repository" where))
         (_ (format "Removed nothing from %s: %s" where reason))))
     (if (harness-json-true-p (plist-get result :selected))
         (concat ".  harness-commit-msg-strip-attribution is still on for it, so the hook comes back:"
                 " turn the setting off for the hook to stay away")
       ""))))

;;;###autoload
(defun harness-commit-msg-uninstall (directory)
  "Take the harness's commit-msg hook out of the git repository of DIRECTORY.
Interactively, read DIRECTORY, defaulting to the root of the current
project.  Only a hook the harness installed goes, never one somebody
else wrote, and the harness forgets that it installed one there.  The
echo area says what happened.  While
`harness-commit-msg-strip-attribution' is still on for the repository
the harness installs the hook again, for a new worktree or session
there or at its next start: turn the setting off for the hook to stay
away."
  (interactive (list (read-directory-name "Remove the commit-msg hook of the repository at: "
                                          (harness-ui--default-directory) nil t)))
  (let ((dir (file-name-as-directory (expand-file-name directory))))
    (harness-ui-call "_harness/commit-msg/uninstall" (list :dir dir)
                     (lambda (result)
                       (message "%s" (harness-ui-commit-msg--describe dir result))))))

(harness-define-module 'ui-commit-msg
  :doc "M-x harness-commit-msg-uninstall: take the harness's commit-msg hook out of a repository."
  :requires '(ui))

(provide 'harness-ui-commit-msg)
;;; harness-ui-commit-msg.el ends here
