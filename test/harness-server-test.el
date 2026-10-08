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
    (when proc (harness-test-wait (lambda () (not (process-live-p proc))) 30 "harness process exit"))))

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
        ;; A UI the harness blocked would miss its 2 s of ticks; a busy
        ;; machine, running other suites meanwhile, delays one by a
        ;; tenth or two.
        (should (< (apply #'max gaps) 0.5))))))

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
lent itself when it connected: its buffers and windows, never an
evaluation, which it never runs."
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
            ;; Model code never runs in the UI: a call that asks for it
            ;; is refused, whatever anyone sets.
            (let ((r (harness-server-test--tool #'harness-ui-request "elisp" :code "(emacs-pid)" :emacs "user")))
              (should (harness-json-true-p (plist-get r :is-error)))
              (should (string-search "never evaluates in the user's Emacs" (plist-get r :content)))
              (should (string-search "emacs_* tools" (plist-get r :content))))
            ;; The background Emacs is neither the UI's nor the harness's.
            (let ((c (plist-get (harness-server-test--tool #'harness-ui-request "elisp" :code "(emacs-pid)") :content)))
              (should (string-prefix-p "=> " c))
              (should-not (equal (format "=> %d" (emacs-pid)) c))
              (should-not (equal (format "=> %d" (process-id harness-ui--server)) c))))
        (kill-buffer buf)))))

(ert-deftest harness-server-headless-runs-tools-with-no-emacs-lent ()
  "A harness process no Emacs is attached to -- headless, driven by a
client that is not an Emacs, such as a phone -- runs its tools: elisp
evaluates in the background (never in a client, and a call that asks
for one is refused), the tools about the user's Emacs say none is
attached, and the client is never sent a tool's request."
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
              ;; A call that asks for the user's Emacs is refused for
              ;; that reason, headless or not: no request evaluates code.
              (let ((r (harness-server-test--tool request "elisp" :code "(+ 1 2)" :emacs "user")))
                (should (harness-json-true-p (plist-get r :is-error)))
                (should (string-search "never evaluates in the user's Emacs" (plist-get r :content)))))
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

(defvar harness-policy-file)

(ert-deftest harness-server-holds-to-the-policy-it-reads ()
  "The harness process reads the policy itself and holds to it: the
settings it describes are locked and a change over ACP is refused.
The options it sets for itself stay its own whatever the policy says:
were they the policy's, it would take itself for a UI, load the UI's
modules and listen beyond this machine."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let* ((init (expand-file-name "server-init.el" harness-state-directory))
           (policy (expand-file-name "policy.el" harness-state-directory))
           (harness-process t)
           (harness-model "demo:scripted")
           (harness-server-init-file init))
      ;; Where the process looks is its own business, as /etc would be:
      ;; this Emacs has no policy, and forwards none.
      (harness-test-write-policy policy '((harness-permission-mode . ask)
                                          (harness-process . t)
                                          (harness-module-directories . ("lisp/ui"))
                                          (harness-acp-host . "192.0.2.1")))
      (with-temp-file init
        (insert harness-server-test--init (format "(setq harness-policy-file %S)\n" policy)))
      (unwind-protect
          (progn
            (harness-start)
            (let* ((described (harness-test-await (harness-ui-request "_harness/config/describe"
                                                                      (list :cwd harness-state-directory))
                                                  30))
                   (mode (cl-find "harness-permission-mode" (plist-get described :settings)
                                  :key (lambda (s) (plist-get s :key)) :test #'equal)))
              (should (eq t (plist-get mode :locked)))
              (should (equal "policy" (plist-get mode :source)))
              (should (equal "ask" (plist-get mode :value)))
              (should (equal policy (plist-get (plist-get described :policy) :file))))
            (should-error (harness-test-await (harness-ui-request "_harness/config/set"
                                                                  (list :key "harness-permission-mode"
                                                                        :value "yolo" :scope "global"))
                                              30))
            ;; Its sessions are the policy's, whatever they ask for.
            (let ((session (harness-test-await (harness-ui-request "_harness/session/create"
                                                                   (list :cwd harness-state-directory
                                                                         :permission-mode "yolo"))
                                               30)))
              (should (equal "ask" (format "%s" (plist-get session :permission-mode)))))
            (harness-server-test--settle))
        (harness-server-test--stop)))))

(ert-deftest harness-server-keeps-the-policy-file-behind ()
  "Where this Emacs reads the policy never reaches the harness process,
which reads the administrator's file itself: not even when it was set
before harness-policy.el defined it, as an init file may."
  (harness-test-with-temp-state
    (let ((harness-policy-file (expand-file-name "my-policy.el" harness-state-directory))
          (symbol-file (symbol-function 'symbol-file)))
      (cl-letf (((symbol-function 'symbol-file)
                 (lambda (symbol &optional type native)
                   (unless (eq symbol 'harness-policy-file)
                     (funcall symbol-file symbol type native)))))
        (should (harness-server--user-set-p 'harness-policy-file))
        (should-not (assq 'harness-policy-file (harness-server--forwarded)))))))

(ert-deftest harness-server-forwards-tramp-settings ()
  "The TRAMP options the user set reach the harness process, which
reaches remote hosts through a TRAMP of its own; those left alone stay
behind, and the harness process has TRAMP's own defaults."
  (require 'tramp)
  (require 'tramp-sh)
  (harness-test-with-temp-state
    (should-not (assq 'tramp-remote-path (harness-server--forwarded)))
    (should-not (assq 'tramp-default-method (harness-server--forwarded)))
    (let ((tramp-remote-path (cons 'tramp-own-remote-path tramp-remote-path))
          (tramp-default-method "sshx")
          (file (expand-file-name "server-config.el" harness-state-directory)))
      (should (equal tramp-remote-path (cdr (assq 'tramp-remote-path (harness-server--forwarded)))))
      (should (equal "sshx" (cdr (assq 'tramp-default-method (harness-server--forwarded)))))
      (harness-server--write-config file)
      (let ((config (harness-read-file file)))
        (should (string-search "(customize-set-variable 'tramp-default-method '\"sshx\")" config))
        (should (string-search "(customize-set-variable 'tramp-remote-path '(tramp-own-remote-path " config))))))

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

(ert-deftest harness-server-a-stopped-process-ending-late-changes-nothing ()
  "A harness process stopped and started again at once: the old one,
whose end is heard once the new one runs, neither takes the new one's
place nor starts yet another."
  (harness-server-test-with-process
    (harness-test-await (harness-ui-request "_harness/session/list") 30)
    (let ((old harness-ui--server)
          (ended nil))
      (add-function :after (process-sentinel old) (lambda (&rest _) (setq ended t)))
      ;; Nothing in between reads the old process's end.
      (harness-ui--stop-server)
      (harness-ui--ensure-server)
      (let ((new harness-ui--server))
        (should (process-live-p new))
        (should-not (eq new old))
        (harness-test-wait (lambda () ended) 10 "the old process's end to be heard")
        (should (eq new harness-ui--server))
        (should (listp (harness-test-await (harness-ui-request "_harness/session/list") 30)))
        (should (eq new harness-ui--server))))))

(ert-deftest harness-server-requires-the-token ()
  (harness-server-test-with-process
    (harness-test-await (harness-ui-request "_harness/session/list") 30)
    (let ((conn (let ((harness-acp-token "wrong")) (harness-acp-connect (car harness-ui--server-address)))))
      (should (eq 'acp-error
                  (car (should-error (harness-test-await (harness-acp-request conn "_harness/session/list" nil) 10))))))))

;;;; The Insights report

(defvar harness-ui-insights--buffer-name)
(defvar harness-ui-insights--data)
(defvar harness-ui-insights--loading)
(defvar harness-ui-insights--writing)
(defvar harness-ui-insights--narrative)
(declare-function harness-insights "harness-ui-insights")

(ert-deftest harness-server-insights-out-of-process ()
  "The Insights report is made in the harness process and comes as JSON.
Its child Emacs reads the transcript there, the demo model writes the
summary, and this Emacs goes on meanwhile."
  (harness-server-test-with-process
    (let* ((now (float-time))
           (sid (plist-get (harness-test-await (harness-ui-request "_harness/session/create"
                                                                   (list :cwd harness-state-directory :name "Parser work"))
                                               30)
                           :id)))
      (dolist (node (list (list :kind "user" :ts (- now 600) :content "Fix the parser")
                          (list :kind "tool-call" :ts (- now 590) :tool "bash" :call-id "c1" :input (list :command "make"))
                          (list :kind "tool-result" :ts (- now 580) :call-id "c1" :output "error" :is-error t)
                          (list :kind "assistant" :ts (- now 570) :content "Fixed")))
        (harness-test-await (harness-ui-request "_harness/session/append" (list :args (list sid node))) 30))
      (let* ((ticks nil)
             (timer (run-at-time 0 0.05 (lambda () (push (float-time) ticks)))))
        (unwind-protect
            (progn
              (harness-insights)
              (with-current-buffer harness-ui-insights--buffer-name
                (should (string-match-p "Gathering insights" (buffer-string)))
                (harness-test-wait (lambda () (and harness-ui-insights--data (not harness-ui-insights--loading)
                                                   harness-ui-insights--narrative (not harness-ui-insights--writing)))
                                   60 "the report and its summary")
                (let ((data harness-ui-insights--data))
                  (should (= 1 (plist-get (plist-get data :sessions) :active)))
                  (should (= 1 (plist-get (plist-get data :tool-totals) :errors)))
                  (should (equal "Parser work" (plist-get (car (plist-get data :busiest-sessions)) :name))))
                (should (string-match-p "You ran 1 session," (buffer-string)))
                (should (string-match-p "Fix the parser" (buffer-string)))))
          (cancel-timer timer)
          (when (get-buffer harness-ui-insights--buffer-name) (kill-buffer harness-ui-insights--buffer-name)))
        (let ((gaps (cl-loop for (a b) on (nreverse ticks) while b collect (- b a))))
          (should (> (length gaps) 2))
          (should (< (apply #'max gaps) 0.5)))
        (harness-server-test--settle)))))

(provide 'harness-server-test)
;;; harness-server-test.el ends here
