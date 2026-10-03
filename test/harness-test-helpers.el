;;; harness-test-helpers.el --- Shared ERT helpers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by scripts/test.sh before every suite.  Provides isolation
;; (a throwaway state directory, a fresh bus), waiting primitives for
;; asynchronous code, the integration-test switch, and checks shared by
;; the buffers that host a compose box (chat and the task board).

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

(defun harness-test-harness-checkout ()
  "Make a directory that looks like a checkout of the harness.
harness.el and an executable scripts/dev.sh are there; the script
appends its cwd, arguments and HARNESS_DEV_SOCKET to invocation.log in
the checkout and exits 0.  Return the directory."
  (let* ((dir (file-name-as-directory (make-temp-file "harness-checkout-" t)))
         (scripts (expand-file-name "scripts/" dir))
         (script (expand-file-name "dev.sh" scripts)))
    (make-directory scripts t)
    (with-temp-file (expand-file-name "harness.el" dir) (insert ";; fake harness\n"))
    (with-temp-file script
      (insert "#!/bin/sh\n"
              "printf '\\n' >> \"$PWD/invocation.log\"\n"
              "printf 'cwd=%s\\n' \"$PWD\" >> \"$PWD/invocation.log\"\n"
              "printf 'args=%s\\n' \"$*\" >> \"$PWD/invocation.log\"\n"
              "printf 'socket=%s\\n' \"$HARNESS_DEV_SOCKET\" >> \"$PWD/invocation.log\"\n"
              "exit 0\n"))
    (set-file-modes script #o755)
    dir))

(defun harness-test-dev-invocations (dir)
  "Return the fake dev loop's invocations recorded in DIR, oldest first.
Each invocation is an alist of the script's fields (cwd, args, socket)."
  (let ((log (expand-file-name "invocation.log" dir)))
    (when (file-exists-p log)
      (with-temp-buffer
        (insert-file-contents log)
        (let (out)
          (dolist (block (split-string (buffer-string) "\n\n" t))
            (push (mapcar (lambda (line)
                            (let ((eq (string-match "=" line)))
                              (cons (substring line 0 eq) (substring line (1+ eq)))))
                          (split-string block "\n" t))
                  out))
          (nreverse out))))))

;;;; Customize types

(defun harness-test-fits-p (type value)
  "Non-nil when VALUE fits the customize TYPE."
  (widget-apply (widget-convert type) :match value))

(defun harness-test-option-keys (type)
  "Return the keys the plist TYPE names in its `:options'."
  (mapcar (lambda (o) (if (consp o) (car o) o)) (plist-get (cdr type) :options)))

(defun harness-test-documented-keys (symbol)
  "Return the plist keys the documentation of option SYMBOL lists.
They are the keywords that start an indented line, as in
\"  :base-url   API root\"."
  (let ((doc (documentation-property symbol 'variable-documentation t))
        (start 0) keys)
    (while (string-match "^  +\\(:[a-z][a-z-]*\\)\\s-" doc start)
      (push (intern (match-string 1 doc)) keys)
      (setq start (match-end 0)))
    (nreverse (delete-dups keys))))

(defun harness-test-check-record-type (type)
  "Check that every key of the record TYPE has a name and starts from a value that fits."
  (dolist (option (plist-get (cdr type) :options))
    (let ((vtype (cadr option)))
      (unless (eq (car-safe vtype) 'const)
        (should (plist-get (cdr vtype) :tag)))
      (when (plist-member (cdr vtype) :value)
        (should (harness-test-fits-p vtype (plist-get (cdr vtype) :value)))))))

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

;;;; The compose box, in each buffer that hosts it

(defvar harness-compose-start)
(defvar harness-compose-end)
(declare-function harness-compose-set "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")

(defun harness-test-compose-c-a-c-k (buffer)
  "Check C-a and C-k, typed as keys, in BUFFER's compose box.
C-a stops after the read-only prompt, also when pressed again, so
C-a C-k clears a one-line box.  On a later line of the box C-a goes
to the start of that line, as anywhere else; on the first line C-a
C-k clears that line only."
  (save-window-excursion
    ;; Keys reach the buffer of the selected window.
    (set-window-buffer nil buffer)
    (with-current-buffer buffer
      (cl-flet ((keys (k) (execute-kbd-macro (kbd k))))
        (should-not inhibit-field-text-motion)
        (harness-compose-set "a message to drop")
        (goto-char harness-compose-end)
        (keys "C-a C-k")
        (should (equal "" (harness-compose-text)))
        (should (= harness-compose-start (point)))
        ;; The prompt stays, and the box takes typing again.
        (should (equal "\N{U+276F} " (buffer-substring-no-properties (- harness-compose-start 2) harness-compose-start)))
        (keys "hi")
        (should (equal "hi" (harness-compose-text)))
        (keys "C-a")
        (should (= harness-compose-start (point)))
        (keys "C-a")
        (should (= harness-compose-start (point)))
        ;; Doom's C-a finds the line's start with `line-beginning-position'.
        (should (= harness-compose-start (save-excursion (goto-char harness-compose-end) (line-beginning-position))))
        ;; Several lines: C-a on a later one goes to its start.
        (harness-compose-set "first line\nsecond line")
        (goto-char harness-compose-end)
        (keys "C-a")
        (should (looking-at-p "second line"))
        (keys "C-a")
        (should (looking-at-p "second line"))
        (goto-char (+ harness-compose-start 5))
        (keys "C-a C-k")
        (should (= harness-compose-start (point)))
        (should (equal "\nsecond line" (harness-compose-text)))))))

(provide 'harness-test-helpers)
;;; harness-test-helpers.el ends here
