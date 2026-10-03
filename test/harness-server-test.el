;;; harness-server-test.el --- The harness in its own Emacs process  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness)
(require 'harness-server)

(defvar harness-ui--server)
(defvar harness-ui--server-address)
(defvar harness-ui--queue)
(defvar harness-ui-connection)
(defvar harness-ui-connection-address)
(defvar harness-server-init-file)
(defvar harness-model)
(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-elisp-allow-ui-eval)
(declare-function harness-ui-request "harness-ui")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp-close "harness-acp")
(declare-function harness-acp-connection-pending "harness-acp")
(declare-function harness-acp-set-handler "harness-acp")
(declare-function harness-acp-initialize "harness-acp")
(declare-function harness-acp-respond-error "harness-acp")

;; A batch Emacs, as the tests run in, dies of a broken pipe: a request
;; written to a harness process that is exiting, or was just killed,
;; takes the whole run down (exit 141).  What the UI asks on connecting
;; goes out in steps -- the providers, then each one's quota as their
;; list comes back -- so a test lets it settle before it kills the
;; process, and lets go of the connection before it stops it.

(defun harness-server-test--settle ()
  "Wait until nothing goes between the UI and the harness process.
Nothing awaited for several turns of the event loop in a row means
every answer's follow-up has gone out and come back."
  (let ((idle 0))
    (harness-test-wait
     (lambda ()
       (setq idle (if (zerop (hash-table-count (harness-acp-connection-pending harness-ui-connection)))
                      (1+ idle)
                    0))
       (>= idle 10))
     30 "the UI's requests to settle")))

(defun harness-server-test--stop ()
  "Stop the harness process and wait until it has exited.
The UI lets go of its connection first, so nothing it still sends on
its way out is written to a process that is exiting."
  (let ((proc harness-ui--server)
        (conn harness-ui-connection))
    (setq harness-ui-connection-address nil harness-ui-connection nil)
    (when conn (ignore-errors (harness-acp-close conn)))
    (harness-stop)
    (when proc (harness-test-wait (lambda () (not (process-live-p proc))) 10 "harness process exit"))))

(defconst harness-server-test--init
  (concat ";; -*- lexical-binding: t -*-\n"
          "(with-eval-after-load 'harness-config\n"
          "  (eval '(harness-defmethod config/test-block () \"Block 2 s.\" (sleep-for 2) \"done\") t))\n"
          "(with-eval-after-load 'harness-tools-shell\n"
          "  (eval '(harness-defmethod config/test-tool (name input) \"Run tool NAME with INPUT, allowed.\"\n"
          "     (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 1)\n"
          "     (harness-call 'tools/execute nil (list :id \"t1\" :name name :input input))) t))\n")
  "Init file of the harness process in these tests.
It defines `config/test-block', which blocks the process's thread for 2
seconds, and `config/test-tool', which runs a tool, any call allowed.")

(defun harness-server-test--tool (request name &rest input)
  "Run tool NAME with INPUT in the harness process; return its result.
REQUEST sends a request over a connection to the process, such as
`harness-ui-request'."
  (harness-test-await (funcall request "_harness/config/test-tool" (list :name name :input (or input :empty))) 30))

(defmacro harness-server-test-with-process (&rest body)
  "Run BODY after `harness-start' in process mode against a temp state dir.
The harness process loads `harness-server-test--init'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let* ((init (expand-file-name "server-init.el" harness-state-directory))
            (harness-process t)
            (harness-model "demo:scripted")
            (harness-server-init-file init))
       (with-temp-file init (insert harness-server-test--init))
       (unwind-protect
           (progn (harness-start) ,@body)
         (harness-server-test--stop)))))

(ert-deftest harness-server-runs-the-harness-out-of-process ()
  (harness-server-test-with-process
    (should (process-live-p harness-ui--server))
    ;; Asked before the process listens: queued, then answered.
    (let ((p (harness-ui-request "_harness/session/list")))
      (should (or harness-ui--queue (harness-promise-settled-p p) harness-ui-connection))
      (should (listp (harness-test-await p 30))))
    ;; The harness methods are not in this Emacs.
    (should-not (harness-method-exists-p 'session/create))))

(ert-deftest harness-server-blocking-work-never-blocks-the-ui ()
  (harness-server-test-with-process
    (harness-test-await (harness-ui-request "_harness/session/list") 30)
    (let* ((ticks nil)
           (timer (run-at-time 0 0.05 (lambda () (push (float-time) ticks))))
           (p (harness-ui-request "_harness/config/test-block")))
      (unwind-protect (should (equal "done" (harness-test-await p 10)))
        (cancel-timer timer))
      (let ((gaps (cl-loop for (a b) on (nreverse ticks) while b collect (- b a))))
        (should (> (length gaps) 20))
        (should (< (apply #'max gaps) 0.15))))))

(ert-deftest harness-server-loop-runs-timers-that-timers-start ()
  "In the harness process, a timer that a timer starts runs when it is due.
Emacs runs due timers from a copy of `timer-list' and then sleeps until
the next timer of that copy, so `accept-process-output' alone leaves a
timer added meanwhile -- every `harness-run-soon' of a request handler
-- waiting for an unrelated one: here the 2-second timer the parent
check runs on, for each of 20 hops."
  (let ((script (make-temp-file "harness-loop-" nil ".el"))
        (lisp (expand-file-name "lisp" harness-test-root)))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";; -*- lexical-binding: t -*-\n"
                    (prin1-to-string
                     '(progn
                        (require 'cl-lib)
                        (require 'harness-server)
                        (run-at-time 2 2 #'ignore)
                        (run-at-time 0.1 nil
                                     (lambda ()
                                       (let ((start (float-time)))
                                         (cl-labels ((hop (n)
                                                       (if (> n 0)
                                                           (run-at-time 0 nil #'hop (1- n))
                                                         (princ (format "took %.3f\n" (- (float-time) start)))
                                                         (kill-emacs 0))))
                                           (hop 20)))))
                        (run-at-time 15 nil (lambda () (princ "starved\n") (kill-emacs 1)))
                        (harness-server--event-loop)))))
          (with-temp-buffer
            (let* ((status (call-process (expand-file-name invocation-name invocation-directory)
                                         nil t nil "-Q" "--batch" "-L" lisp "-l" script))
                   (out (buffer-string)))
              (should (string-match "took \\([0-9.]+\\)" out))
              (should (< (string-to-number (match-string 1 out)) 1.0))
              (should (eq status 0)))))
      (delete-file script))))

(ert-deftest harness-server-emacs-tools-reach-the-emacs-the-ui-lends ()
  "The tools run in the harness process and reach the UI's Emacs, which
lent itself when it connected: its buffers, and evaluation in it when
it allows that."
  (harness-server-test-with-process
    (let ((buf (generate-new-buffer "harness-only-in-the-ui")))
      (unwind-protect
          (progn
            (should (string-search "harness-only-in-the-ui"
                                   (plist-get (harness-server-test--tool #'harness-ui-request "emacs_buffers") :content)))
            (with-current-buffer buf (insert "first\nsecond\n"))
            (should (string-prefix-p "     2\tsecond"
                                     (plist-get (harness-server-test--tool #'harness-ui-request "emacs_buffer"
                                                                           :name "harness-only-in-the-ui" :offset 2)
                                                :content)))
            ;; Model code stays out of the UI unless this Emacs allows it.
            (let ((r (harness-server-test--tool #'harness-ui-request "elisp" :code "(emacs-pid)" :emacs "user")))
              (should (harness-json-true-p (plist-get r :is-error)))
              (should (string-search "harness-elisp-allow-ui-eval" (plist-get r :content))))
            (let ((harness-elisp-allow-ui-eval t))
              (should (equal (format "=> %d" (emacs-pid))
                             (plist-get (harness-server-test--tool #'harness-ui-request "elisp"
                                                                   :code "(emacs-pid)" :emacs "user")
                                        :content))))
            ;; The background Emacs is neither the UI's nor the harness's.
            (let ((c (plist-get (harness-server-test--tool #'harness-ui-request "elisp" :code "(emacs-pid)") :content)))
              (should (string-prefix-p "=> " c))
              (should-not (equal (format "=> %d" (emacs-pid)) c))
              (should-not (equal (format "=> %d" (process-id harness-ui--server)) c))))
        (kill-buffer buf)))))

(ert-deftest harness-server-headless-runs-tools-with-no-emacs-lent ()
  "A harness process no Emacs is attached to -- headless, driven by a
client that is not an Emacs, such as a phone -- runs its tools: elisp
evaluates in the background, the tools about the user's Emacs say none
is attached, and the client is never sent a tool's request."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (setq harness-acp--server-enabled nil)
    (harness-test-load-module 'acp)
    (let* ((init (expand-file-name "server-init.el" harness-state-directory))
           (harness-model "demo:scripted")
           (harness-server-init-file init)
           (address nil) (token nil) (proc nil) (phone nil) (seen nil))
      (with-temp-file init (insert harness-server-test--init))
      (unwind-protect
          (progn
            (setq proc (harness-server-spawn :on-address (lambda (a tk) (setq address a token tk))))
            (harness-test-wait (lambda () address) 60 "the harness process's address")
            (setq phone (let ((harness-acp-token token)) (harness-acp-connect address)))
            (harness-acp-set-handler phone (lambda (method _params respond)
                                             (push method seen)
                                             (when respond (harness-acp-respond-error respond -32601 "a phone"))))
            ;; ACP's own capabilities only: this client lends no Emacs.
            (harness-test-await (harness-acp-initialize phone) 30)
            (let ((request (lambda (method params) (harness-acp-request phone method params))))
              (dolist (call '(("emacs_buffers") ("emacs_describe" :symbol "car")))
                (let ((r (apply #'harness-server-test--tool request call)))
                  (should (harness-json-true-p (plist-get r :is-error)))
                  (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))))
              (let ((r (harness-server-test--tool request "elisp" :code "(+ 1 2)")))
                (should-not (harness-json-true-p (plist-get r :is-error)))
                (should (equal "=> 3" (plist-get r :content))))
              (let ((r (harness-server-test--tool request "elisp" :code "(+ 1 2)" :emacs "user")))
                (should (harness-json-true-p (plist-get r :is-error)))
                (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))))
            (should-not (cl-some (lambda (m) (or (string-prefix-p "_harness/emacs/" m)
                                                 (equal m "_harness/client/tool")))
                                 seen)))
        (when phone (harness-acp-close phone))
        (when proc
          (harness-server-stop proc)
          (harness-test-wait (lambda () (not (process-live-p proc))) 10 "harness process exit"))))))

(ert-deftest harness-server-waits-for-init-to-finish ()
  "Started from an init file, the process spawns after `emacs-startup-hook',
so settings made later in the init file are forwarded."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let ((harness-process t)
          (harness-model "demo:scripted")
          (emacs-startup-hook nil))
      (unwind-protect
          (progn
            (let ((after-init-time nil))
              (harness-start)
              (should-not harness-ui--server)
              ;; Set later in the init file.
              (setq harness-model "demo:later"))
            (run-hooks 'emacs-startup-hook)
            (should (process-live-p harness-ui--server))
            (should (string-search "demo:later"
                                   (harness-read-file (expand-file-name "server-config.el" harness-state-directory))))
            (should (listp (harness-test-await (harness-ui-request "_harness/session/list") 30))))
        (harness-server-test--stop)))))

(ert-deftest harness-server-forwards-corporate-mode ()
  "`harness-corporate-mode' turned on reaches the harness process.
Its name ends in -mode, but it is an option, not a minor mode, so it is
forwarded as every `harness-' option the user sets."
  (harness-test-with-temp-state
    (should-not (fboundp 'harness-corporate-mode))
    (let ((harness-corporate-mode nil))
      (should-not (assq 'harness-corporate-mode (harness-server--forwarded))))
    (let ((harness-corporate-mode t)
          (file (expand-file-name "server-config.el" harness-state-directory)))
      (should (eq t (cdr (assq 'harness-corporate-mode (harness-server--forwarded)))))
      (harness-server--write-config file)
      (should (string-search "(customize-set-variable 'harness-corporate-mode 't)"
                             (harness-read-file file))))))

(ert-deftest harness-server-restarts-after-a-crash ()
  (harness-server-test-with-process
    (harness-test-await (harness-ui-request "_harness/session/list") 30)
    (harness-server-test--settle)
    (let ((old harness-ui--server))
      (signal-process old 'kill)
      (harness-test-wait (lambda () (and harness-ui--server (not (eq old harness-ui--server))
                                         harness-ui--server-address))
                         30 "restart")
      (should (listp (harness-test-await (harness-ui-request "_harness/session/list") 30))))))

(ert-deftest harness-server-requires-the-token ()
  (harness-server-test-with-process
    (harness-test-await (harness-ui-request "_harness/session/list") 30)
    (let ((conn (let ((harness-acp-token "wrong")) (harness-acp-connect (car harness-ui--server-address)))))
      (should (eq 'acp-error
                  (car (should-error (harness-test-await (harness-acp-request conn "_harness/session/list" nil) 10))))))))

(provide 'harness-server-test)
;;; harness-server-test.el ends here
