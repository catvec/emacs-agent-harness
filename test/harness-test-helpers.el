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

;;;; A web server

(defun harness-test-http-serve (routes)
  "Answer HTTP requests on 127.0.0.1 from ROUTES; return the server process.
ROUTES maps a path to (STATUS HEADERS BODY . OPTIONS): HEADERS an alist
sent as given, BODY a string of bytes.  OPTIONS is a plist: :chunks
splits the body in that many pieces sent :delay seconds apart (the
first one after :delay too), :no-length leaves Content-Length out.  A
path ROUTES lacks gets a 404.  `harness-test-http-url' makes addresses."
  (make-network-process
   :name "harness-test-http" :server t :host "127.0.0.1" :service t :family 'ipv4
   :coding 'binary :noquery t
   :log (lambda (_server connection _message) (set-process-query-on-exit-flag connection nil))
   :filter (lambda (proc data)
             (let ((text (concat (or (process-get proc 'text) "") data)))
               (process-put proc 'text text)
               (when (and (string-match-p "\r\n\r\n" text) (not (process-get proc 'answered)))
                 (process-put proc 'answered t)
                 (let ((path (nth 1 (split-string (car (split-string text "\r\n")) " "))))
                   (harness-test--http-answer
                    proc (or (cdr (assoc path routes))
                             (list 404 '(("Content-Type" . "text/plain")) "not found")))))))))

(defun harness-test--http-answer (proc route)
  "Send PROC the answer ROUTE describes (see `harness-test-http-serve')."
  (pcase-let* ((`(,status ,headers ,body . ,options) route)
               (chunks (max 1 (or (plist-get options :chunks) 1)))
               (delay (or (plist-get options :delay) 0))
               (size (length body))
               (step (max 1 (ceiling size chunks)))
               (pieces (let (out (i 0))
                         (while (< i size)
                           (push (substring body i (min size (+ i step))) out)
                           (setq i (+ i step)))
                         (nreverse out)))
               (send nil))
    (process-send-string
     proc (concat (format "HTTP/1.1 %d %s\r\n" status (if (< status 400) "OK" "Error"))
                  (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                  (if (plist-get options :no-length) "" (format "Content-Length: %d\r\n" size))
                  "Connection: close\r\n\r\n"))
    (setq send (lambda ()
                 (when (process-live-p proc)
                   (if pieces
                       (progn (ignore-errors (process-send-string proc (pop pieces)))
                              (if (> delay 0) (run-at-time delay nil send) (funcall send)))
                     (ignore-errors (process-send-eof proc))))))
    (if (> delay 0) (run-at-time delay nil send) (funcall send))))

(defun harness-test-http-url (server path)
  "Return the address of PATH on SERVER, from `harness-test-http-serve'."
  (format "http://127.0.0.1:%d%s" (process-contact server :service) path))

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

(defconst harness-test-png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DA8B+MgBgAHfAD/dPQfSYAAAAASUVORK5CYII=")
  "The bytes of a 2x2 PNG.")
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
(declare-function harness-acp-initialize "harness-acp")
(declare-function harness-emacs-endpoint-answer "harness-emacs-endpoint")
(declare-function harness-emacs-endpoint-client-capabilities "harness-emacs-endpoint")
(declare-function harness-emacs-endpoint-revert-visiting "harness-emacs-endpoint")
(declare-function harness-emacs-endpoint-customize-save "harness-emacs-endpoint")

(defun harness-test-connect-ui-client ()
  "Load the acp module and connect an in-process client acting as the UI.
Like lisp/ui, it lends this Emacs to the harness, so the tools about the
user's Emacs ask it (`_harness/emacs/...', answered by
`harness-emacs-endpoint-answer'); it answers
`_harness/client/customize-save', and reverts buffers on
`tools/file-written'.  Return the connection, initialized."
  (let ((harness-acp--server-enabled nil))
    (harness-test-load-module 'acp))
  (require 'harness-emacs-endpoint)
  (let ((conn (harness-acp-connect nil)))
    (harness-acp-set-handler
     conn
     (lambda (method params respond)
       (unless (harness-emacs-endpoint-answer method params respond)
         (pcase method
           ("_harness/client/customize-save"
            (funcall respond (harness-emacs-endpoint-customize-save (plist-get params :symbol) (plist-get params :value))))
           ("_harness/event"
            (when (equal (plist-get params :event) "tools/file-written")
              (harness-emacs-endpoint-revert-visiting (car (plist-get params :args)))))))))
    (harness-test-await (harness-acp-initialize conn (harness-emacs-endpoint-client-capabilities)))
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
