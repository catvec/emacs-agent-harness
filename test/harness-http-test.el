;;; harness-http-test.el --- Tests for the async HTTP client -*- lexical-binding: t; -*-

;;; Commentary:

;; A tiny canned HTTP server (a raw TCP listener) verifies the client end
;; to end: status lines, headers, content-length, chunked encoding,
;; close-delimited bodies, SSE line delivery, redirects and failures.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-http)
(require 'harness-test-helpers)

(harness-module-load 'harness-http)

(defvar harness-http-test--processes nil)

(defalias 'harness-http-test--server #'harness-test-http-server)
(defalias 'harness-http-test--url #'harness-test-http-url)
(defalias 'harness-http-test--response #'harness-test-http-response)

(defun harness-http-test--fetch-sync (url &rest options)
  "Fetch URL, wait, and return the response or signal the rejection."
  (let ((deferred (apply #'harness-http-fetch url options)))
    (harness-test-settle deferred 5)
    (when (harness-deferred-rejected-p deferred)
      (signal 'harness-http-error (list (harness-deferred-value deferred))))
    (harness-deferred-value deferred)))

(defun harness-http-test--cleanup ()
  "Delete every process created by a test."
  (harness-test-http-cleanup)
  (setq harness-http-test--processes nil))

(defmacro harness-http-test--with-processes (&rest body)
  "Run BODY, cleaning up all processes afterwards."
  (declare (indent 0))
  `(unwind-protect (progn ,@body)
     (harness-http-test--cleanup)))

(ert-deftest harness-http-content-length-and-utf8 ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server
                    (lambda (_process _request)
                      (list (harness-http-test--response
                             200 '(("Content-Type" . "application/json"))
                             "{\"text\":\"hëllo\"}")))))
           (response (harness-http-test--fetch-sync (harness-http-test--url server))))
      (should (= (harness-http-response-status response) 200))
      (should (equal (cdr (assoc "content-type" (harness-http-response-headers response)))
                     "application/json"))
      (should (equal (harness-http-response-body response) "{\"text\":\"hëllo\"}")))))

(ert-deftest harness-http-post-body-reaches-the-server ()
  (harness-http-test--with-processes
    (let* ((seen nil)
           (server (harness-http-test--server
                    (lambda (_process request)
                      (setq seen request)
                      (list (harness-http-test--response 200 '() "ok")))))
           (response (harness-http-test--fetch-sync
                      (harness-http-test--url server)
                      :method "POST"
                      :body "{\"hello\":\"world\"}")))
      (should (= (harness-http-response-status response) 200))
      (should (string-match-p "POST / HTTP/1.1" seen))
      (should (string-match-p "\r\n\r\n{\"hello\":\"world\"}\\'" seen))
      (should (string-match-p "Content-Length: 17" seen)))))

(ert-deftest harness-http-chunked-response ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server
                    (lambda (_process _request)
                      (list (encode-coding-string
                             (concat "HTTP/1.1 200 OK\r\n"
                                     "Transfer-Encoding: chunked\r\n\r\n"
                                     "5\r\nhello\r\n")
                             'utf-8)
                            (cons 0.02 (encode-coding-string "6\r\n world\r\n" 'utf-8))
                            (cons 0.02 (encode-coding-string "0\r\n\r\n" 'utf-8))))))
           (response (harness-http-test--fetch-sync (harness-http-test--url server))))
      (should (equal (harness-http-response-body response) "hello world")))))

(ert-deftest harness-http-close-delimited-response ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server
                    (lambda (process _request)
                      (run-at-time 0.05 nil
                                   (lambda ()
                                     (when (process-live-p process)
                                       (delete-process process))))
                      (list (encode-coding-string
                             (concat "HTTP/1.1 200 OK\r\n"
                                     "Connection: close\r\n\r\n"
                                     "body until close")
                             'utf-8)))))
           (response (harness-http-test--fetch-sync (harness-http-test--url server))))
      (should (equal (harness-http-response-body response) "body until close")))))

(ert-deftest harness-http-sse-line-delivery ()
  (harness-http-test--with-processes
    (let* ((lines nil)
           (server (harness-http-test--server
                    (lambda (process _request)
                      (run-at-time 0.08 nil
                                   (lambda ()
                                     (when (process-live-p process)
                                       (delete-process process))))
                      (list (encode-coding-string
                             (concat "HTTP/1.1 200 OK\r\n"
                                     "Content-Type: text/event-stream\r\n\r\n"
                                     "data: one\n\n")
                             'utf-8)
                            (cons 0.02 (encode-coding-string "data: two\n\n" 'utf-8))))))
           (response (harness-http-test--fetch-sync
                      (harness-http-test--url server)
                      :on-line (lambda (line) (push line lines)))))
      (should (= (harness-http-response-status response) 200))
      (should (equal (nreverse lines) '("data: one" "" "data: two" ""))))))

(ert-deftest harness-http-redirect-is-followed ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server
                    (lambda (_process request)
                      (if (string-match-p "GET /b " request)
                          (list (harness-http-test--response 200 '() "redirected"))
                        (list (encode-coding-string
                               "HTTP/1.1 302 Found\r\nLocation: /b\r\nContent-Length: 0\r\n\r\n"
                               'utf-8))))))
           (response (harness-http-test--fetch-sync (harness-http-test--url server "/a"))))
      (should (= (harness-http-response-status response) 200))
      (should (equal (harness-http-response-body response) "redirected")))))

(ert-deftest harness-http-empty-content-length ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server
                    (lambda (_process _request)
                      (list (encode-coding-string
                             "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
                             'utf-8)))))
           (response (harness-http-test--fetch-sync (harness-http-test--url server))))
      (should (= (harness-http-response-status response) 204))
      (should (equal (harness-http-response-body response) "")))))

(ert-deftest harness-http-timeout-rejects ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server (lambda (_process _request) nil)))
           (deferred (harness-http-fetch (harness-http-test--url server) :timeout 0.1)))
      (harness-test-settle deferred 2)
      (should (harness-deferred-rejected-p deferred))
      (should (eq (car (harness-deferred-value deferred)) 'harness-http-error)))))

(ert-deftest harness-http-connection-refused-rejects ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server (lambda (_process _request) nil)))
           (url (harness-http-test--url server))
           (deferred nil))
      (delete-process server)
      (setq deferred (harness-http-fetch url :timeout 2))
      (harness-test-settle deferred 3)
      (should (harness-deferred-rejected-p deferred))
      (should (eq (car (harness-deferred-value deferred)) 'harness-http-error)))))

(ert-deftest harness-http-cancel-rejects ()
  (harness-http-test--with-processes
    (let* ((server (harness-http-test--server (lambda (_process _request) nil)))
           (deferred (harness-http-fetch (harness-http-test--url server) :timeout 30)))
      (harness-deferred-cancel deferred)
      (should (harness-deferred-rejected-p deferred))
      (should (eq (car (harness-deferred-value deferred)) 'harness-cancelled)))))

(provide 'harness-http-test)
;;; harness-http-test.el ends here
