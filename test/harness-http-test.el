;;; harness-http-test.el --- Tests for the asynchronous HTTP client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Commentary:

;; End-to-end tests against a local server plus parser tests that feed
;; deliberately fragmented byte streams to `harness-http--consume'.

;;; Code:

(require 'ert)
(require 'harness-http)
(require 'harness-test-util)

(defun harness-http-test--collect (responder &optional request-args)
  "Perform a request against a server using RESPONDER and return the result.
The result is a plist with `:complete', `:error', `:events' and `:chunks'."
  (harness-http-test-with-server
   responder
   (let ((result (list :complete nil :error nil :events nil :chunks nil)))
     (harness-http-request
      (format "http://127.0.0.1:%d/test" port)
      :method (or (plist-get request-args :method) "GET")
      :body (plist-get request-args :body)
      :headers (plist-get request-args :headers)
      :on-chunk (lambda (chunk)
                  (setq result (plist-put result :chunks
                                          (cons chunk (plist-get result :chunks)))))
      :on-event (lambda (event)
                  (setq result (plist-put result :events
                                          (cons event (plist-get result :events)))))
      :on-complete (lambda (status headers body)
                     (setq result (plist-put result :complete
                                             (list status headers body))))
      :on-error (lambda (error)
                  (setq result (plist-put result :error error))))
     (harness-test-wait-for
      (lambda () (or (plist-get result :complete) (plist-get result :error))))
     (plist-put result :events (nreverse (plist-get result :events)))
     (plist-put result :chunks (nreverse (plist-get result :chunks)))
     result)))

(ert-deftest harness-http-test-content-length ()
  "A response with Content-Length is delivered whole."
  (let ((result (harness-http-test--collect
                 (lambda (_request)
                   (list :status 200
                         :headers '(("Content-Type" . "application/json"))
                         :body "{\"ok\":true}")))))
    (should (plist-get result :complete))
    (should (equal (car (plist-get result :complete)) 200))
    (should (equal (nth 2 (plist-get result :complete)) "{\"ok\":true}"))
    (should (equal (harness-alist-get :content-type (nth 1 (plist-get result :complete)))
                   "application/json"))))

(ert-deftest harness-http-test-content-length-utf8 ()
  "Content-Length is measured in bytes, so multibyte bodies survive."
  (let* ((body "héllo wörld — ünïcode")
         (result (harness-http-test--collect
                  (lambda (_request) (list :body body)))))
    (should (equal (nth 2 (plist-get result :complete)) body))))

(ert-deftest harness-http-test-chunked-sse ()
  "Chunked responses are dechunked and SSE events are framed."
  (let ((result (harness-http-test--collect
                 (lambda (_request)
                   (list :chunks '("data: {\"a\":1}\n\n"
                                   "data: {\"b\":2}\n\ndata: [DONE]\n\n"))))))
    (should (plist-get result :complete))
    (should (equal (plist-get result :events)
                   '("{\"a\":1}" "{\"b\":2}" "[DONE]")))))

(ert-deftest harness-http-test-sse-multiline-data ()
  "Multiple data lines in one event are joined with newlines."
  (let ((result (harness-http-test--collect
                 (lambda (_request)
                   (list :chunks '("data: line one\ndata: line two\n\n"))))))
    (should (equal (plist-get result :events) '("line one\nline two")))))

(ert-deftest harness-http-test-error-status ()
  "A 4xx/5xx response calls the error callback with the body."
  (let ((result (harness-http-test--collect
                 (lambda (_request)
                   (list :status 500 :reason "Boom" :body "{\"error\":\"nope\"}")))))
    (should-not (plist-get result :complete))
    (should (plist-get result :error))
    (should (eq (harness-http-error-type (plist-get result :error)) 'http))
    (should (equal (harness-http-error-status (plist-get result :error)) 500))
    (should (string-match-p "nope" (harness-http-error-format (plist-get result :error))))))

(ert-deftest harness-http-test-redirect ()
  "Redirects are followed and the final response is delivered."
  (let ((result (harness-http-test--collect
                 (lambda (request)
                   (if (string-match-p "GET /final" request)
                       (list :body "arrived")
                     (list :status 302 :headers '(("Location" . "/final"))))))))
    (should (plist-get result :complete))
    (should (equal (nth 2 (plist-get result :complete)) "arrived"))))

(ert-deftest harness-http-test-post-body ()
  "The request body is sent with a correct Content-Length and arrives intact."
  (let ((result (harness-http-test--collect
                 (lambda (request)
                   (if (string-match-p "\"hello\"" request)
                       (list :body "{\"received\":true}")
                     (list :status 400 :body "wrong body")))
                 '(:method "POST" :body "{\"hello\":\"wörld\"}"
                   :headers (("Content-Type" . "application/json"))))))
    (should (equal (nth 2 (plist-get result :complete)) "{\"received\":true}"))))

(ert-deftest harness-http-test-request-format ()
  "The request line is first and the header block is CRLF terminated.
This is a regression test: the header block used to be assembled by mixing
`list' and `push', which put the request line in the middle."
  (let ((captured nil)
        (done nil))
    (harness-http-test-with-server
     (lambda (request)
       (setq captured request)
       (list :body "ok"))
     (harness-http-request
      (format "http://127.0.0.1:%d/path?q=1" port)
      :headers '(("X-Test" . "yes"))
      :on-complete (lambda (&rest _) (setq done t))
      :on-error (lambda (_error) (setq done t)))
     (harness-test-wait-for (lambda () done)))
    (should captured)
    (should (string-prefix-p "GET /path?q=1 HTTP/1.1\r\n" captured))
    (should (string-match-p "\r\nHost: 127\\.0\\.0\\.1:[0-9]+\r\n" captured))
    (should (string-match-p "\r\nX-Test: yes\r\n" captured))
    (should (string-suffix-p "\r\n\r\n" captured))))

(ert-deftest harness-http-test-connection-refused ()
  "Connecting to a closed port reports a network error, asynchronously."
  (let ((result (list :error nil :complete nil)))
    (harness-http-request
     "http://127.0.0.1:1/nothing"
     :on-complete (lambda (&rest _) (setq result (plist-put result :complete t)))
     :on-error (lambda (error) (setq result (plist-put result :error error))))
    (harness-test-wait-for (lambda () (plist-get result :error)))
    (should (plist-get result :error))
    (should (eq (harness-http-error-type (plist-get result :error)) 'network))))

(ert-deftest harness-http-test-unsupported-scheme ()
  "A file:// URL fails without touching the network."
  (let ((result (list :error nil)))
    (harness-http-request
     "ftp://example.com/x"
     :on-error (lambda (error) (setq result (plist-put result :error error))))
    (should (plist-get result :error))))

(ert-deftest harness-http-test-timeout ()
  "A server that never responds triggers the idle timeout."
  (let* ((harness-http-timeout 0.3)
         (result (list :error nil)))
    (harness-http-test-with-server
     (lambda (_request) nil)            ; never answer
     (harness-http-request
      (format "http://127.0.0.1:%d/slow" port)
      :on-error (lambda (error) (setq result (plist-put result :error error))))
     (harness-test-wait-for (lambda () (plist-get result :error)) 3)
     (should (plist-get result :error))
     (should (memq (harness-http-error-type (plist-get result :error))
                   '(network timeout))))))

(ert-deftest harness-http-test-cancel ()
  "Cancelling a request suppresses both terminal callbacks."
  (let ((result (list :error nil :complete nil)))
    (harness-http-test-with-server
     (lambda (_request) (list :body "never"))
     (let ((request (harness-http-request
                     (format "http://127.0.0.1:%d/x" port)
                     :on-complete (lambda (&rest _) (setq result (plist-put result :complete t)))
                     :on-error (lambda (error) (setq result (plist-put result :error error))))))
       (harness-http-cancel request)
       (accept-process-output nil 0.3)
       (should-not (plist-get result :error))
       (should-not (plist-get result :complete))
       (should (harness-http-request-done-p request))))))


;;; Parser unit tests: no sockets involved

(defun harness-http-test--parser ()
  "Return a request object wired to record events, plus a state holder."
  (let* ((state (list :events nil :chunks nil :complete nil :error nil))
         (request (harness-http--make-request
                   :url "http://example.com/x"
                   :method "GET"
                   :on-event (lambda (event)
                               (setq state (plist-put state :events
                                                      (cons event (plist-get state :events)))))
                   :on-chunk (lambda (chunk)
                               (setq state (plist-put state :chunks
                                                      (cons chunk (plist-get state :chunks)))))
                   :on-complete (lambda (status _headers body)
                                  (setq state (plist-put state :complete (list status body))))
                   :on-error (lambda (error)
                               (setq state (plist-put state :error error)))
                   :state 'headers
                   :pending ""
                   :body-buffer "")))
    (cons request state)))

(ert-deftest harness-http-test-parse-response-head ()
  "Status lines and headers parse, with lowercase keys and folding."
  (let* ((parsed (harness-http--parse-response-head
                  "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nX-Y: a\r\n")))
    (should (equal (car parsed) 201))
    (should (equal (harness-alist-get :content-type (cdr parsed)) "text/plain"))
    (should (equal (harness-alist-get :x-y (cdr parsed)) "a"))))

(ert-deftest harness-http-test-head-end ()
  "The header terminator is found for both CRLF and bare LF."
  (should (equal (harness-http--head-end "A: b\r\n\r\nbody") '(4 . 4)))
  (should (equal (harness-http--head-end "A: b\n\nbody") '(4 . 2)))
  (should-not (harness-http--head-end "A: b\r\n")))

(ert-deftest harness-http-test-fragmented-headers ()
  "Headers split at arbitrary byte boundaries still parse."
  (let* ((cell (harness-http-test--parser))
         (request (car cell))
         (state (cdr cell)))
    (dolist (piece '("HTTP/1.1 200 OK\r\nCont" "ent-Length: 5\r" "\n\r" "\nhello"))
      (harness-http--consume request piece))
    (should (equal (plist-get state :complete) '(200 "hello")))))

(ert-deftest harness-http-test-fragmented-chunks ()
  "A chunked body split mid-chunk-size and mid-data still parses."
  (let* ((cell (harness-http-test--parser))
         (request (car cell))
         (state (cdr cell)))
    (dolist (piece '("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                     "5\r\nhel" "lo\r\n" "6\r\n world" "\r\n0\r" "\n\r\n"))
      (harness-http--consume request piece))
    (should (equal (plist-get state :complete) '(200 "hello world")))))

(ert-deftest harness-http-test-fragmented-sse ()
  "SSE lines split across network reads are reassembled."
  (let* ((cell (harness-http-test--parser))
         (request (car cell))
         (state (cdr cell)))
    (dolist (piece '("HTTP/1.1 200 OK\r\nContent-Length: 30\r\n\r\ndata: {\"a\""
                     ":1}\n\ndata: [DO" "NE]\n\n"))
      (harness-http--consume request piece))
    (should (equal (nreverse (plist-get state :events))
                   '("{\"a\":1}" "[DONE]")))))

(ert-deftest harness-http-test-eof-body ()
  "A response without Content-Length is read until the connection closes."
  (let* ((cell (harness-http-test--parser))
         (request (car cell))
         (state (cdr cell)))
    (harness-http--consume request "HTTP/1.1 200 OK\r\n\r\npar")
    (harness-http--consume request "tial")
    (should-not (plist-get state :complete))
    (harness-http--handle-eof request)
    (should (equal (plist-get state :complete) '(200 "partial")))))

(ert-deftest harness-http-test-truncated-body-is-an-error ()
  "Closing the connection mid-body is reported as an error, not a short read."
  (let* ((cell (harness-http-test--parser))
         (request (car cell))
         (state (cdr cell)))
    (harness-http--consume request "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc")
    (harness-http--handle-eof request)
    (should (plist-get state :error))
    (should (eq (harness-http-error-type (plist-get state :error)) 'network))))

(provide 'harness-http-test)
;;; harness-http-test.el ends here
