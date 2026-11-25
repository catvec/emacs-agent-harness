;;; harness-state-lock.el --- Exclusive backend state ownership -*- lexical-binding: t; -*-

;;; Commentary:
;; Sockets are addresses, not state ownership.  Use Emacs's atomic file
;; locks (host, PID and boot identity, with dead-owner recovery) before
;; starting backend modules.  Keep ownership for the process lifetime:
;; stopping/reloading modules does not prove their old callbacks are gone.
;; In particular, do not unlock in an early kill-emacs-hook while other
;; shutdown hooks may still save state.  A successor reclaims the dead lock.

;;; Code:
(require 'cl-lib)

(define-error 'harness-state-owned "Harness state directory already owned")

(defun harness-state-lock-acquire (directory)
  "Exclusively own canonical DIRECTORY for this backend process's lifetime.
Repeated starts and reloads in the same Emacs retain ownership.  Another
live owner is an error, never an interactive request to steal its lock.
Emacs reclaims a dead owner's lock automatically, including after SIGKILL.
The UI process must not call this: its child owns the backend state."
  (make-directory directory t)
  (let* ((directory (file-name-as-directory (file-truename directory)))
         (file (expand-file-name ".harness-owner" directory))
         ;; Ownership is mandatory even if the user's editor disables or
         ;; relocates its usual visiting-buffer locks.
         (create-lockfiles t)
         (lock-file-name-transforms nil))
    (cl-letf (((symbol-function 'ask-user-about-lock)
               (lambda (_file opponent)
                 (signal 'harness-state-owned (list directory opponent)))))
      (lock-file file))
    (unless (eq t (file-locked-p file))
      ;; A filesystem that cannot create locks must fail closed too.
      (signal 'harness-state-owned (list directory "Unable to acquire state lock")))
    t))

(provide 'harness-state-lock)
;;; harness-state-lock.el ends here
