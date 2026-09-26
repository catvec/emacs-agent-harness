;;; harness-acp-tcp-test.el --- Tests for the TCP ACP transport -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'harness-core)
(require 'harness-acp)
(require 'harness-acp-tcp)
(require 'harness-test-helpers)

(defvar harness-acp-tcp-test--processes nil)

(defun harness-acp-tcp-test--cleanup ()
  "Delete every process created by a test."
  (dolist (process harness-acp-tcp-test--processes)
    (when (process-live-p process)
      (delete-process process)))
  (setq harness-acp-tcp-test--processes nil))

(defmacro harness-acp-tcp-test--with-processes (&rest body)
  "Run BODY, cleaning up all processes afterwards."
  (declare (indent 0))
  `(unwind-protect (progn ,@body)
     (harness-acp-tcp-test--cleanup)))

(defun harness-acp-tcp-test--remember (process)
  "Track PROCESS for cleanup and return it."
  (push process harness-acp-tcp-test--processes)
  process)

(ert-deftest harness-acp-tcp-request-response ()
  (harness-acp-tcp-test--with-processes
    (let* ((server (harness-acp-tcp-test--remember
                    (harness-acp-tcp-server 0)))
           (port (process-contact server :service))
           (client (harness-acp-tcp-test--remember
                    (harness-acp-tcp-connect "127.0.0.1" port)))
           (result nil))
      (harness-deferred-then
       (harness-acp-connection-request client "_harness/ping" nil)
       (lambda (value) (setq result value)))
      (should (harness-test-wait-for (lambda () result)))
      (should (harness-acp-json-true-p (plist-get result :pong))))))

(ert-deftest harness-acp-tcp-role-is-client ()
  (harness-acp-tcp-test--with-processes
    (let* ((server (harness-acp-tcp-test--remember (harness-acp-tcp-server 0)))
           (port (process-contact server :service))
           (client (harness-acp-tcp-test--remember
                    (harness-acp-tcp-connect "127.0.0.1" port))))
      (should (eq (harness-acp-connection-role client) 'client)))))

(ert-deftest harness-acp-tcp-framing-multiple-messages-per-chunk ()
  (harness-acp-tcp-test--with-processes
    (let* ((server (harness-acp-tcp-test--remember
                    (harness-acp-tcp-server
                     0
                     (lambda (connection)
                       (harness-acp-connection-register-method
                        connection "test/echo"
                        (lambda (_connection params) (plist-get params :n)))))))
           (port (process-contact server :service))
           (raw (harness-acp-tcp-test--remember
                 (open-network-stream "harness-acp-test-raw" nil "127.0.0.1" port
                                      :coding 'utf-8-unix)))
           (received ""))
      (set-process-filter raw (lambda (_process chunk) (setq received (concat received chunk))))
      (process-send-string
       raw
       (concat (harness-acp-serialize (harness-acp-request-message 1 "test/echo" (list :n 1))) "\n"
               (harness-acp-serialize (harness-acp-request-message 2 "test/echo" (list :n 2))) "\n"))
      (should (harness-test-wait-for
               (lambda () (and (string-match-p "\"id\":1" received)
                               (string-match-p "\"id\":2" received)))))
      ;; Both responses must be complete, newline-terminated lines.
      (let ((lines (seq-filter (lambda (line) (not (string-empty-p line)))
                               (split-string received "\n"))))
        (should (= (length lines) 2))
        (should (equal (plist-get (harness-acp-parse (nth 0 lines)) :result) 1))
        (should (equal (plist-get (harness-acp-parse (nth 1 lines)) :result) 2))))))

(ert-deftest harness-acp-tcp-close-notifies-connection ()
  (harness-acp-tcp-test--with-processes
    (let* ((server-connection nil)
           (server (harness-acp-tcp-test--remember
                    (harness-acp-tcp-server
                     0
                     (lambda (connection)
                       (setq server-connection connection)))))
           (port (process-contact server :service))
           (raw (harness-acp-tcp-test--remember
                 (open-network-stream "harness-acp-test-raw" nil "127.0.0.1" port
                                      :coding 'utf-8-unix))))
      ;; The server creates an ACP connection on the first message.
      (process-send-string
       raw (concat (harness-acp-serialize (harness-acp-request-message 1 "_harness/ping" nil)) "\n"))
      (should (harness-test-wait-for (lambda () server-connection)))
      (delete-process raw)
      (should (harness-test-wait-for
               (lambda () (harness-acp-connection-closed-p server-connection)))))))

(provide 'harness-acp-tcp-test)
;;; harness-acp-tcp-test.el ends here
