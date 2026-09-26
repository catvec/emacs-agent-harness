;;; harness-test-helpers.el --- Shared test utilities -*- lexical-binding: t; -*-

;;; Commentary:

;; Small helpers every suite can use.  Kept free of state so that loading
;; it cannot affect a module under test.

;;; Code:

(require 'harness-core)

(defun harness-test-wait-for (predicate &optional seconds)
  "Wait up to SECONDS (default 2) for PREDICATE to return non-nil.
Processes timers and process output while waiting."
  (let ((end (+ (float-time) (or seconds 2))))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (accept-process-output nil 0.02)
      (sit-for 0.01))
    (funcall predicate)))

(defun harness-test-settle (deferred &optional seconds)
  "Wait up to SECONDS for DEFERRED to settle, and return it."
  (harness-test-wait-for (lambda () (not (harness-deferred-pending-p deferred))) seconds)
  deferred)

(defun harness-test-rejection (deferred &optional seconds)
  "Wait for DEFERRED to settle and return its rejection value."
  (harness-test-settle deferred seconds)
  (harness-deferred-value deferred))

(defun harness-test-resolved (value)
  "Return a deferred already resolved with VALUE."
  (let ((deferred (harness-deferred-new)))
    (harness-deferred-resolve deferred value)
    deferred))

;;; A canned HTTP server, for tests that need a real socket

(defvar harness-test-http-processes nil
  "Processes created by `harness-test-http-server' for cleanup.")

(defun harness-test-http-cleanup ()
  "Delete every process created by `harness-test-http-server'."
  (dolist (process harness-test-http-processes)
    (when (process-live-p process)
      (delete-process process)))
  (setq harness-test-http-processes nil))

(defun harness-test-http-request-complete-p (request)
  "Return non-nil when REQUEST has received its whole body."
  (when (string-match "\r\n\r\n" request)
    (let ((header-end (match-end 0))
          (length 0))
      (when (string-match "Content-Length: \\([0-9]+\\)" request)
        (setq length (string-to-number (match-string 1 request))))
      (>= (- (length request) header-end) length))))

(defun harness-test-http-server (responder)
  "Start a canned HTTP server on an ephemeral port.
RESPONDER receives (PROCESS REQUEST) once the request is complete and
returns a list of response parts: a string to send now, or a cons
(DELAY . STRING) to send later.  Returns the server process."
  (let ((server nil))
    (setq server
          (make-network-process
           :name "harness-test-http-server"
           :server t
           :host "127.0.0.1"
           :service 0
           :family 'ipv4
           :coding 'binary
           :noquery t
           :filter (lambda (process chunk)
                     (let ((request (concat (or (process-get process 'request) "")
                                            chunk)))
                       (process-put process 'request request)
                       (when (and (not (process-get process 'responded))
                                  (harness-test-http-request-complete-p request))
                         (process-put process 'responded t)
                         (dolist (part (funcall responder process request))
                           (if (consp part)
                               (run-at-time
                                (car part) nil
                                (lambda ()
                                  (when (process-live-p process)
                                    (process-send-string process (cdr part)))))
                             (process-send-string process part))))))))
    (push server harness-test-http-processes)
    server))

(defun harness-test-http-url (server &optional path)
  "Return a URL for SERVER."
  (format "http://127.0.0.1:%s%s" (process-contact server :service) (or path "/")))

(defun harness-test-http-response (status headers body)
  "Build an HTTP response string with STATUS, HEADERS and BODY."
  (encode-coding-string
   (concat (format "HTTP/1.1 %d OK\r\n" status)
           (mapconcat (lambda (header) (format "%s: %s\r\n" (car header) (cdr header)))
                      headers)
           (format "Content-Length: %d\r\n\r\n" (string-bytes body))
           body)
   'utf-8))

(provide 'harness-test-helpers)
;;; harness-test-helpers.el ends here
