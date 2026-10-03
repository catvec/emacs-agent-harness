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

(defconst harness-test-png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DA8B+MgBgAHfAD/dPQfSYAAAAASUVORK5CYII=")
  "The bytes of a 2x2 PNG.")

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
