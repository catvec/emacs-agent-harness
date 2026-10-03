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

(defvar harness-session--tmp-root)
;; So do the sessions' temporary directories: never the real
;; /tmp/harness-UID, which the user's own harness hands out.
(setq harness-session--tmp-root (expand-file-name "session-tmp/" harness-test-state-root))

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

(defun harness-test-real-home ()
  "Return the user's home directory as the password database has it.
Not $HOME: a suite run from a harness session's shell runs in that
session's sandbox, where $HOME is the sandbox's own empty home."
  (directory-file-name (expand-file-name (concat "~" (user-real-login-name)))))

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

(defvar harness-acp--server-enabled)
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
  (let ((harness-acp--server-enabled nil))
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
(declare-function harness-compose-pad-window "harness-ui-compose")
(declare-function harness-compose-repad "harness-ui-compose")

(defconst harness-test-crossing-line 3
  "Lines high the line is that `harness-test-with-display-measures' leaves out.")

(defun harness-test--display-text-pixel-size (orig &optional window from to x-limit y-limit &rest rest)
  "Call ORIG, `window-text-pixel-size', as a graphical frame would answer.
WINDOW, FROM, TO, X-LIMIT, Y-LIMIT and REST are its arguments.  Text
taller than Y-LIMIT measures `harness-test-crossing-line' lines less
than Y-LIMIT: the line that crossed it is left out."
  (let ((size (apply orig window from to x-limit nil rest)))
    (if (and (numberp y-limit) (> (cdr size) y-limit))
        (cons (car size) (max 0 (- y-limit (* harness-test-crossing-line (frame-char-height)))))
      size)))

(defmacro harness-test-with-display-measures (&rest body)
  "Run BODY with text measured as on a graphical frame.
There a line is many pixels high, and `window-text-pixel-size' leaves
out the line that crosses its Y-LIMIT, so text taller than Y-LIMIT can
measure less than Y-LIMIT.  A batch frame's lines are one pixel high
and none ever crosses it: here such text measures a few lines less than
Y-LIMIT, as if a taller line, an image say, had crossed it."
  (declare (indent 0))
  (let ((orig (make-symbol "orig")))
    `(let ((,orig (symbol-function 'window-text-pixel-size)))
       (cl-letf (((symbol-function 'window-text-pixel-size)
                  (lambda (&rest args) (apply #'harness-test--display-text-pixel-size ,orig args))))
         ,@body))))

(defun harness-test-compose-grows-past-the-window (buffer window spare)
  "Check BUFFER's box in WINDOW as it grows a line at a time past the window.
Text is measured as on a graphical frame (see
`harness-test-with-display-measures').  While the text from the
buffer's start to the box's end fits, WINDOW shows the buffer from its
start; once it does not, the box's last line stays on the window's last
line, above SPARE empty lines, and point, at the end of the box, stays
in view.  The window's start is never forced: redisplay would then move
point, out of the box, rather than scroll."
  (let ((forced nil)
        (body (window-body-height window t))
        (line (frame-char-height (window-frame window))))
    (cl-letf* ((set-start (symbol-function 'set-window-start))
               ((symbol-function 'set-window-start)
                (lambda (w pos &optional noforce)
                  (unless noforce (push pos forced))
                  (funcall set-start w pos noforce))))
      (harness-test-with-display-measures
        (with-current-buffer buffer
          (goto-char harness-compose-end)
          (insert "a line")
          (dotimes (i (+ 5 (window-body-height window)))
            (insert (format "\nline %d" i))
            (set-window-point window (point))
            ;; Measured without the padding, which is sized again next.
            (harness-compose-repad window)
            (let ((height (cdr (window-text-pixel-size window (point-min) harness-compose-end))))
              (harness-compose-pad-window window)
              (if (<= height (- body (* spare line)))
                  (should (= (point-min) (window-start window)))
                ;; Point, at the box's end, is in view: from the window's
                ;; start to there takes the window, but for SPARE lines.
                ;; (`pos-visible-in-window-p' says nil in batch.)
                (should (< (point-min) (window-start window) (point)))
                (should (= (- body (* spare line))
                           (cdr (window-text-pixel-size window (window-start window) harness-compose-end))))))))))
    (should-not forced)))

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
