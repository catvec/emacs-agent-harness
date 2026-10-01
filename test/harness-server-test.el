;;; harness-server-test.el --- The harness in its own Emacs process  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness)

(defvar harness-ui--server)
(defvar harness-ui--server-address)
(defvar harness-ui--queue)
(defvar harness-ui-connection)
(defvar harness-ui-connection-address)
(defvar harness-server-init-file)
(defvar harness-model)
(defvar harness-acp-token)
(declare-function harness-ui-request "harness-ui")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-request "harness-acp")

(defmacro harness-server-test-with-process (&rest body)
  "Run BODY after `harness-start' in process mode against a temp state dir.
The harness process also defines `config/test-block', which blocks its
thread for 2 seconds."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let* ((init (expand-file-name "server-init.el" harness-state-directory))
            (harness-process t)
            (harness-model "demo:scripted")
            (harness-server-init-file init))
       (with-temp-file init
         (insert ";; -*- lexical-binding: t -*-\n"
                 "(with-eval-after-load 'harness-config\n"
                 "  (eval '(harness-defmethod config/test-block () \"Block 2 s.\" (sleep-for 2) \"done\") t))\n"))
       (unwind-protect
           (progn (harness-start) ,@body)
         (let ((proc harness-ui--server))
           (harness-stop)
           (when proc (harness-test-wait (lambda () (not (process-live-p proc))) 10 "harness process exit")))
         (setq harness-ui-connection-address nil harness-ui-connection nil)))))

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

(ert-deftest harness-server-restarts-after-a-crash ()
  (harness-server-test-with-process
    (harness-test-await (harness-ui-request "_harness/session/list") 30)
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
