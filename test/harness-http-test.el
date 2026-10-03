;;; harness-http-test.el --- Tests for the curl HTTP client  -*- lexical-binding: t -*-

;; This file is part of the Emacs agent harness (v3).

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

(ert-deftest harness-http-body-uses-a-file-and-is-cleaned-up ()
  "A request body travels in a mode 600 file, not through stdin.
`process-send-string' can leave a big body half-written in Emacs's
process write queue, where only another send would ever drain it, and
curl then waits for the rest of its stdin forever."
  (skip-unless (executable-find "curl"))
  (harness-test-with-temp-state
    (let* ((body "{\"hello\":\"world\"}")
           (handle (harness-http-request "http://127.0.0.1:1/" :method "POST" :body body
                                         :callback (lambda (&rest _) nil))))
      (unwind-protect
          (let ((file (harness-http-handle-body-file handle))
                (args (process-command (harness-http-handle-process handle))))
            (should (stringp file))
            (should (file-exists-p file))
            (should (equal body (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (member (concat "@" file) args))
            (should-not (member "@-" args))
            (should (timerp (harness-http-handle-timer handle)))
            (harness-http-cancel handle)
            (should-not (file-exists-p file)))
        (harness-http-cancel handle)))))

(ert-deftest harness-http-watchdog-fails-a-live-request ()
  "The watchdog ends a request whose curl is alive and silent.
Curl's own `--max-time' never fires while it waits for its stdin, so a
Lisp-side timer is what keeps requests bounded."
  (harness-test-with-temp-state
    (let* ((proc (make-process :name "harness-http-test-stuck"
                               :command (list "sleep" "60")
                               :connection-type 'pipe :noquery t))
           (handle (make-harness-http-handle :process proc :timeout 1))
           (result nil))
      (unwind-protect
          (progn
            (should (process-live-p proc))
            (setf (harness-http-handle-callback handle)
                  (lambda (status _headers _body err) (setq result (list status err))))
            (harness-http--timed-out handle)
            (should (equal '(nil timeout) (list (car result) (car (cadr result)))))
            (should (string-search "timed out after 1s" (cadr (cadr result))))
            (should-not (process-live-p proc)))
        (when (process-live-p proc) (delete-process proc))))))

(provide 'harness-http-test)
;;; harness-http-test.el ends here
