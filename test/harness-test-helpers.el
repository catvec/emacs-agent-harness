;;; harness-test-helpers.el --- Shared ERT helpers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by scripts/test.sh before every suite.  Provides isolation
;; (a throwaway state directory, a fresh bus), waiting primitives for
;; asynchronous code, and the integration-test switch.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar harness-test-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(add-to-list 'load-path harness-test-root)
(dolist (d '("lisp" "lisp/modules" "lisp/ui" "test"))
  (add-to-list 'load-path (expand-file-name d harness-test-root)))

(require 'harness)
(require 'harness-core)
(require 'harness-util)

(defvar harness-test-state-root (file-name-as-directory (make-temp-file "harness-test-state-" t))
  "State directory of the whole test run.
Nothing a run writes outside `harness-test-with-temp-state' -- compiled
files, or what the sessions and tasks modules flush when Emacs exits --
may reach the user's real `harness-state-directory'.")

(setq harness-state-directory harness-test-state-root)

(defvar harness-tasks-store-in-repository)
;; Tasks stay in the throwaway state directory whatever directory a test
;; submits them in, so no test writes into a real repository's .git.
;; Tests of repository stores bind it in repositories of their own.
(setq harness-tasks-store-in-repository nil)

(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-directory harness-test-state-root t)))
          ;; Appended, so the modules' exit flushes write here first.
          t)

(defun harness-test-integration-p ()
  "Non-nil when integration tests that use real models should run."
  (and (getenv "HARNESS_INTEGRATION") t))

(defmacro harness-test-skip-unless-integration ()
  "Skip the current test unless HARNESS_INTEGRATION is set."
  `(skip-unless (harness-test-integration-p)))

(defun harness-test-fixture (name)
  "Return the path of fixture NAME under test/fixtures."
  (expand-file-name (concat "fixtures/" name) (file-name-directory (locate-library "harness-test-helpers"))))

(defun harness-test-reset-bus ()
  "Forget every method, subscriber, filter and module registration."
  (clrhash harness--methods)
  (clrhash harness--subscribers)
  (clrhash harness--filters)
  (clrhash harness--modules))

(defun harness-test-load-module (name)
  "Load module NAME from lisp/modules or lisp/ui, as `harness-start' would."
  (let ((file (cl-some (lambda (dir)
                         (let ((f (expand-file-name (format "%s/harness-%s.el" dir name) harness-test-root)))
                           (and (file-exists-p f) f)))
                       '("lisp/modules" "lisp/ui"))))
    (unless file (error "No module %s" name))
    (let ((harness--defining-module name))
      (harness-load-compiled file))
    (harness-module-start name)))

(defmacro harness-test-with-temp-state (&rest body)
  "Run BODY with `harness-state-directory' pointing at a fresh temp dir."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "harness-test-" t)))
          (harness-state-directory dir))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory dir t)))))

(defun harness-test-wait (pred &optional timeout message)
  "Spin the event loop until PRED returns non-nil or TIMEOUT seconds pass.
Signal an error mentioning MESSAGE on timeout.  Return PRED's value."
  (let ((deadline (+ (float-time) (or timeout 10))) result)
    (while (and (not (setq result (funcall pred)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sit-for 0.005))
    (or result (error "Timed out waiting for %s" (or message "condition")))))

(defun harness-test-await (promise &optional timeout)
  "Block until PROMISE settles; return its value or signal."
  (harness-await promise (or timeout 10)))

(defun harness-test-temp-dir ()
  "Create and return a fresh temporary directory."
  (file-name-as-directory (make-temp-file "harness-tmp-" t)))

(defvar harness-acp-server-enabled)
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-set-handler "harness-acp")
(declare-function harness-client-tools-run "harness-client-tools")
(declare-function harness-client-tools-revert-visiting "harness-client-tools")
(declare-function harness-client-tools-customize-save "harness-client-tools")

(defun harness-test-connect-ui-client ()
  "Load the acp module and connect an in-process client acting as the UI.
It answers `_harness/client/tool' and `_harness/client/customize-save',
and reverts buffers on
`tools/file-written', like lisp/ui does.  Return the connection."
  (let ((harness-acp-server-enabled nil))
    (harness-test-load-module 'acp))
  (require 'harness-client-tools)
  (let ((conn (harness-acp-connect nil)))
    (harness-acp-set-handler
     conn
     (lambda (method params respond)
       (pcase method
         ("_harness/client/tool"
          (funcall respond (harness-client-tools-run (plist-get params :name) (plist-get params :input))))
         ("_harness/client/customize-save"
          (funcall respond (harness-client-tools-customize-save (plist-get params :symbol) (plist-get params :value))))
         ("_harness/event"
          (when (equal (plist-get params :event) "tools/file-written")
            (harness-client-tools-revert-visiting (car (plist-get params :args))))))))
    conn))

(provide 'harness-test-helpers)
;;; harness-test-helpers.el ends here
