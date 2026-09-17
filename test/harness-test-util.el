;;; harness-test-util.el --- Test helpers for the agent harness -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Helpers shared by the ERT suites.  Nothing here may be loaded by the
;; runtime code: `harness-test-wait-for' deliberately blocks the main thread,
;; which is fine in a test and forbidden in the harness itself.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defmacro harness-test-with-env (bindings &rest body)
  "Evaluate BODY with BINDINGS bound, restoring them afterwards.
Like `let' but tolerant of variables that are not yet defined."
  (declare (indent 1))
  `(let ,bindings
     (unwind-protect
         (progn ,@body))))

(defun harness-test-reset-index ()
  "Close the session index and forget cached session headers."
  (when (and (boundp 'harness--index-db) harness--index-db)
    (ignore-errors (sqlite-close harness--index-db))
    (setq harness--index-db nil))
  (when (boundp 'harness-session-header-cache)
    (clrhash harness-session-header-cache)))

(defmacro harness-test-with-temp-session-dir (&rest body)
  "Run BODY with session storage in a throwaway directory."
  (declare (indent 0))
  `(let* ((harness-test--directory (make-temp-file "harness-test" t))
          (default-directory (file-name-as-directory harness-test--directory))
          (harness-session-directory (expand-file-name "sessions" harness-test--directory))
          (harness-session-index-file (expand-file-name "index.sqlite" harness-test--directory))
          (harness-session-header-cache (make-hash-table :test #'equal))
          (harness--index-db nil))
     (unwind-protect
         (progn ,@body)
       (harness-test-reset-index)
       ;; Tests never share a session with each other, and leaving them in the
       ;; registry would change the counts the mode line and the browser show.
       (when (boundp 'harness--sessions) (clrhash harness--sessions))
       (when (boundp 'harness--session-tails) (clrhash harness--session-tails))
       (when (boundp 'harness--message-ids) (clrhash harness--message-ids))
       (ignore-errors (delete-directory harness-test--directory t)))))

(defun harness-test-wait-for (predicate &optional timeout interval)
  "Run the event loop until PREDICATE returns non-nil, or TIMEOUT seconds pass.
Return the last value of PREDICATE.  Blocks on purpose: this is the one place
where blocking the main thread is correct."
  (let ((deadline (+ (float-time) (or timeout 5)))
        (interval (or interval 0.01))
        result)
    (while (and (not (setq result (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil interval))
    result))

(defun harness-test-wait-for-value (place &optional timeout)
  "Wait until PLACE (a symbol) holds a non-nil value; return it."
  (harness-test-wait-for (lambda () (symbol-value place)) timeout))


;;; A minimal HTTP server

(defvar harness-test--servers nil
  "Servers started by `harness-test-start-server', for cleanup.")

(defun harness-test-start-server (responder)
  "Start an HTTP server on 127.0.0.1 and return its port.

RESPONDER is called with the raw request text once a complete request has
arrived (headers and, when `Content-Length' is present, the whole body).  It
must return a plist:

  :status   integer, default 200
  :reason   string, default \"OK\"
  :headers  alist of extra headers
  :body     string, sent with Content-Length
  :chunks   list of strings, sent with Transfer-Encoding: chunked
  :junk     string written verbatim before the response (for malformed tests)

The port is returned; call `harness-test-stop-servers' to clean up."
  (let* ((pending (make-hash-table :test #'eq))
         (filter (harness-test--make-filter pending responder))
         (server
          (make-network-process
           :name "harness-test-server"
           :server t
           :host "127.0.0.1"
           :service 0
           :family 'ipv4
           :coding 'binary
           :noquery t
           :log (lambda (_server client _message)
                  (puthash client "" pending)
                  (set-process-filter client filter)
                  (set-process-sentinel
                   client
                   (lambda (process _event) (remhash process pending)))))))
    (push server harness-test--servers)
    (process-contact server :service)))

(defmacro harness-http-test-with-server (responder &rest body)
  "Run BODY with an HTTP server responding via RESPONDER.
BODY can refer to the variable `port'."
  (declare (indent 1))
  `(let ((port (harness-test-start-server ,responder)))
     (unwind-protect
         (progn ,@body)
       (harness-test-stop-servers))))

(defun harness-test--make-filter (pending responder)
  "Return a process filter accumulating into PENDING and calling RESPONDER.
A nil return value from RESPONDER means: do not answer.  Tests use that to
exercise timeouts."
  (lambda (process chunk)
    (let ((buffer (concat (gethash process pending)
                          (decode-coding-string chunk 'utf-8-unix t))))
      (puthash process buffer pending)
      (when (harness-test--request-complete-p buffer)
        (puthash process "" pending)
        (when-let* ((response (funcall responder buffer)))
          (condition-case err
              (harness-test--send-response process response)
            (error
             (message "test server responder failed: %S" err)
             (delete-process process))))))))

(defun harness-test-stop-servers ()
  "Delete every server started by `harness-test-start-server'."
  (dolist (server harness-test--servers)
    (when (process-live-p server) (delete-process server)))
  (setq harness-test--servers nil))

(defun harness-test--request-complete-p (buffer)
  "Return non-nil when BUFFER holds a complete HTTP request."
  (when-let* ((end (string-search "\r\n\r\n" buffer)))
    (let* ((head (substring buffer 0 end))
           (length (let ((case-fold-search t))
                     (when (string-match "^content-length:[ \t]*\\([0-9]+\\)" head)
                       (string-to-number (match-string 1 head)))))
           (body (substring buffer (+ end 4))))
      (or (null length) (>= (string-bytes body) length)))))

(defun harness-test--send-response (process response)
  "Send RESPONSE to PROCESS."
  (let* ((status (or (plist-get response :status) 200))
         (reason (or (plist-get response :reason) "OK"))
         (headers (plist-get response :headers))
         (body (or (plist-get response :body) ""))
         (chunks (plist-get response :chunks))
         (junk (plist-get response :junk))
         (lines (list (format "HTTP/1.1 %d %s\r\n" status reason))))
    (when junk (process-send-string process (encode-coding-string junk 'utf-8-unix)))
    (dolist (header headers)
      (push (format "%s: %s\r\n" (car header) (cdr header)) lines))
    (if chunks
        (push "Transfer-Encoding: chunked\r\n" lines)
      (push (format "Content-Length: %d\r\n"
                    (string-bytes (encode-coding-string body 'utf-8-unix)))
            lines))
    (push "Connection: close\r\n\r\n" lines)
    (process-send-string process
                         (encode-coding-string (apply #'concat (nreverse lines)) 'utf-8-unix))
    (if chunks
        (progn
          (dolist (chunk chunks)
            (process-send-string
             process
             (encode-coding-string
              (format "%x\r\n%s\r\n" (string-bytes (encode-coding-string chunk 'utf-8-unix)) chunk)
              'utf-8-unix)))
          (process-send-string process "0\r\n\r\n"))
      (process-send-string process (encode-coding-string body 'utf-8-unix)))
    ;; Close the write side rather than deleting the process outright, so that
    ;; buffered output cannot be discarded before the client reads it.
    (ignore-errors (process-send-eof process))))

(provide 'harness-test-util)
;;; harness-test-util.el ends here
