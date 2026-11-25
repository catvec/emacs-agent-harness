;;; harness-state-lock-test.el --- Backend ownership tests -*- lexical-binding: t; -*-
;;; Code:
(require 'harness-test-helpers)
(require 'harness-state-lock)

(defun harness-state-lock-test--command (directory &optional hold)
  "Return a clean Emacs command acquiring DIRECTORY, waiting if HOLD."
  (list (expand-file-name invocation-name invocation-directory) "-Q" "--batch"
        "-L" (file-name-directory (locate-library "harness-state-lock"))
        "--eval"
        (prin1-to-string
         `(progn (require 'harness-state-lock)
                 (harness-state-lock-acquire ,directory)
                 (princ "OWNER-READY\n")
                 ,(when hold '(while t (sleep-for 0.05)))))))

(ert-deftest harness-state-lock-excludes-live-owners-and-recovers-after-kill ()
  "Independent ports and symlink aliases cannot evade backend ownership."
  (let* ((root (make-temp-file "harness-ownership-" t))
         (directory (expand-file-name "state" root))
         (alias (expand-file-name "alias" root))
         (other (expand-file-name "other" root))
         (output (generate-new-buffer " *harness-owner-test*"))
         owner)
    (unwind-protect
        (progn
          (make-directory directory)
          (make-symbolic-link directory alias)
          (setq owner (make-process :name "harness-owner-test" :buffer output
                                    :command (harness-state-lock-test--command directory t)
                                    :noquery t))
          (harness-test-wait (lambda () (with-current-buffer output
                                         (string-search "OWNER-READY" (buffer-string))))
                             10 "state owner")
          (dolist (path (list directory alias))
            (with-temp-buffer
              (should-not (zerop (apply #'call-process
                                        (car (harness-state-lock-test--command path))
                                        nil t nil (cdr (harness-state-lock-test--command path)))))
              (should (string-search "Harness state directory already owned" (buffer-string)))))
          ;; A different state directory is independent, and returns 0.
          (should (zerop (apply #'call-process
                               (car (harness-state-lock-test--command other))
                               nil nil nil (cdr (harness-state-lock-test--command other)))))
          ;; No cleanup hook runs on SIGKILL.  Native locks still recover.
          (signal-process owner 'SIGKILL)
          (harness-test-wait (lambda () (not (process-live-p owner))) 10 "owner death")
          (should (zerop (apply #'call-process
                               (car (harness-state-lock-test--command alias))
                               nil nil nil (cdr (harness-state-lock-test--command alias))))))
      (when (and owner (process-live-p owner)) (delete-process owner))
      (kill-buffer output)
      (delete-directory root t))))

(ert-deftest harness-state-lock-survives-reload-and-editor-lock-settings ()
  "Editor preferences cannot disable or relocate state exclusion."
  (let* ((directory (make-temp-file "harness-ownership-" t))
         (create-lockfiles nil)
         (lock-file-name-transforms '((".*" "/missing/locks/" t))))
    (unwind-protect
        (progn
          (should (harness-state-lock-acquire directory))
          (load "harness-state-lock" nil t)
          (should (harness-state-lock-acquire directory))
          (let ((lock-file-name-transforms nil))
            (should (eq t (file-locked-p (expand-file-name ".harness-owner" directory))))))
      ;; Tests may unlock their own lease after all work is finished.
      (let ((lock-file-name-transforms nil))
        (unlock-file (expand-file-name ".harness-owner" directory)))
      (delete-directory directory t))))

(ert-deftest harness-state-lock-fails-closed-when-locking-is-unavailable ()
  (let ((directory (make-temp-file "harness-ownership-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'lock-file) #'ignore))
          (should-error (harness-state-lock-acquire directory) :type 'harness-state-owned))
      (delete-directory directory t))))

(provide 'harness-state-lock-test)
;;; harness-state-lock-test.el ends here
