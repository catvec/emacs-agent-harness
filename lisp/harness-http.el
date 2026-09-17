;;; harness-http.el --- Asynchronous HTTP/1.1 and server-sent-events client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai, comm
;; URL: https://github.com/noahhuppert/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A small HTTP/1.1 client built specifically for streaming LLM APIs.  It is
;; deliberately not general purpose: POST/GET, one request per connection
;; (`Connection: close'), TLS, `Content-Length', `Transfer-Encoding: chunked'
;; and server-sent events.
;;
;; Everything is asynchronous.  Connections are opened with `:nowait t' so DNS
;; resolution, the TCP connect and the TLS handshake never block Emacs; the
;; request is written from the process sentinel once the connection is ready.
;; The process has no buffer, so no unbounded text accumulates anywhere
;; visible, and the parser consumes each network chunk immediately.
;;
;; See DESIGN.md section 4.

;;; Code:

(require 'cl-lib)
(require 'gnutls)
(require 'subr-x)
(require 'url-expand)
(require 'url-parse)
(require 'url-util)
(require 'harness-core)

(defcustom harness-http-timeout 180
  "Seconds of inactivity after which a request is aborted.
The timer is rescheduled every time data arrives, so this is an idle timeout
rather than a whole-request deadline."
  :type 'integer
  :group 'harness-providers)

(defcustom harness-http-max-body 8388608
  "Maximum response body size in characters before the request is aborted."
  :type 'integer
  :group 'harness-providers)

(defcustom harness-http-max-redirects 5
  "Maximum number of redirects followed for a single request."
  :type 'integer
  :group 'harness-providers)

(defcustom harness-http-tls-verify t
  "Whether TLS certificate chains and hostnames are verified.
Set to nil only for endpoints with self-signed certificates on a trusted
network; unlike `nsm', the harness cannot prompt during a handshake, so
verification is all-or-nothing."
  :type 'boolean
  :group 'harness-providers)

(defcustom harness-http-user-agent
  (format "harness/%s Emacs/%s" harness-version emacs-version)
  "User-Agent header sent with every request."
  :type 'string
  :group 'harness-providers)

(defconst harness-http--redirect-statuses '(301 302 303 307 308)
  "Status codes treated as redirects.")


;;; Errors

(cl-defstruct (harness-http-error (:constructor harness-http--make-error))
  "A failed HTTP request.

TYPE is `network' (could not connect, or lost the connection), `http' (a
non-2xx status), `timeout', `canceled', `too-large' or `redirect'."
  (type 'network)
  (message "")
  (status nil)
  (headers nil)
  (body nil)
  (url nil))

(defun harness-http-error-format (error)
  "Return a one-line human readable description of ERROR."
  (let ((type (harness-http-error-type error))
        (status (harness-http-error-status error))
        (body (harness-http-error-body error)))
    (if (eq type 'http)
        (format "HTTP %s: %s"
                status
                (let ((text (and body (string-trim body))))
                  (if (or (null text) (string-empty-p text))
                      (harness-http-error-message error)
                    (truncate-string-to-width text 500 nil nil "…"))))
      (or (harness-http-error-message error) "request failed"))))


;;; Request object

(cl-defstruct (harness-http-request (:constructor harness-http--make-request)
                                    (:copier nil))
  "State of one in-flight HTTP request."
  url method headers body
  on-chunk on-event on-complete on-error
  timeout max-body no-redirect redirects
  process timer
  ;; Parser.  STATE is one of `connecting', `headers', `body', `eof-body',
  ;; `chunk-size', `chunk-data', `chunk-crlf', `trailer', `done'.
  state pending
  status response-headers
  transfer-encoding content-length remaining
  body-buffer sse-buffer sse-event
  aborted done)

(defvar harness-http--live-requests nil
  "Requests currently in flight.  Used by tests and `harness-http-active-p'.")

(defun harness-http-active-p ()
  "Return non-nil when at least one request is in flight."
  (and harness-http--live-requests t))

(defun harness-http-request-done-p (request)
  "Return non-nil when REQUEST has finished, failed or been cancelled."
  (harness-http-request-done request))


;;; Public API

(defun harness-http-request (url &rest args)
  "Start an asynchronous HTTP request to URL.

Keyword arguments:

  :method       \"GET\" (default) or \"POST\"
  :headers      alist of (NAME . VALUE); NAME may be a symbol or string
  :body         request body string, encoded as UTF-8
  :on-chunk     called with raw, undecoded response bytes as they arrive
  :on-event     called with each server-sent-event data payload (decoded)
  :on-complete  called with (STATUS HEADERS BODY) on a 2xx response
  :on-error     called with a `harness-http-error' structure
  :timeout      idle timeout in seconds, default `harness-http-timeout'
  :max-body     body size limit in characters
  :no-redirect  do not follow redirects

Exactly one of `:on-complete' and `:on-error' is called, unless the request
is cancelled with `harness-http-cancel', in which case neither is.  Returns
the request object."
  (let ((request (harness-http--make-request
                  :url url
                  :method (upcase (or (plist-get args :method) "GET"))
                  :headers (plist-get args :headers)
                  :body (plist-get args :body)
                  :on-chunk (plist-get args :on-chunk)
                  :on-event (plist-get args :on-event)
                  :on-complete (plist-get args :on-complete)
                  :on-error (plist-get args :on-error)
                  :timeout (or (plist-get args :timeout) harness-http-timeout)
                  :max-body (or (plist-get args :max-body) harness-http-max-body)
                  :no-redirect (plist-get args :no-redirect)
                  :redirects 0
                  :state 'connecting
                  :pending ""
                  :body-buffer "")))
    (harness-http--start request url)
    request))

(defun harness-http-cancel (request)
  "Cancel REQUEST without calling any terminal callback."
  (when (and request (not (harness-http-request-done request)))
    (setf (harness-http-request-aborted request) t)
    (setf (harness-http-request-done request) t)
    (harness-http--cleanup request))
  request)


;;; Starting, finishing, cleaning up

(defun harness-http--start (request url)
  "Open a connection for REQUEST to URL and arrange to send the request."
  (setf (harness-http-request-url request) url
        (harness-http-request-state request) 'connecting
        (harness-http-request-pending request) ""
        (harness-http-request-status request) nil
        (harness-http-request-response-headers request) nil
        (harness-http-request-transfer-encoding request) nil
        (harness-http-request-content-length request) nil
        (harness-http-request-remaining request) nil
        (harness-http-request-body-buffer request) ""
        (harness-http-request-sse-buffer request) ""
        (harness-http-request-sse-event request) nil)
  (let* ((parsed (url-generic-parse-url url))
         (scheme (url-type parsed)))
    (if (not (member scheme '("http" "https")))
        (harness-http--fail
         request
         (harness-http--make-error
          :type 'network :url url
          :message (format "unsupported URL scheme %S" scheme)))
      (let* ((host (url-host parsed))
             (tls (equal scheme "https"))
             (port (or (url-port parsed) (if tls 443 80))))
        (cond
         ((and tls (not (gnutls-available-p)))
          (harness-http--fail
           request
           (harness-http--make-error
            :type 'network :url url
            :message "this Emacs was built without GnuTLS; https is unavailable")))
         (t
          (condition-case err
              (let ((process (harness-http--open host port tls)))
                (setf (harness-http-request-process request) process)
                (process-put process 'harness-request request)
                (push request harness-http--live-requests)
                (harness-http--touch request))
            (error
             (harness-http--fail
              request
              (harness-http--make-error
               :type 'network :url url
               :message (error-message-string err)))))))))))

(defun harness-http--open (host port tls)
  "Open an asynchronous connection to HOST:PORT.
TLS is negotiated by `make-network-process' when TLS is non-nil.  Note that
`open-network-stream' cannot be used here: its `:nowait' paths drop the
caller's filter and sentinel (see `network-stream-open-plain' and
`open-gnutls-stream')."
  (apply #'make-network-process
         :name "harness-http"
         :buffer nil
         :host host
         :service port
         :nowait t
         :coding 'binary
         :noquery t
         :sentinel #'harness-http--sentinel
         :filter #'harness-http--filter
         (when tls
           (list :tls-parameters
                 (cons 'gnutls-x509pki
                       (gnutls-boot-parameters
                        :type 'gnutls-x509pki
                        :hostname host
                        :verify-error harness-http-tls-verify))))))

(defun harness-http--touch (request)
  "Reschedule REQUEST's idle timeout."
  (when-let* ((timer (harness-http-request-timer request)))
    (cancel-timer timer))
  (setf (harness-http-request-timer request)
        (run-at-time (or (harness-http-request-timeout request)
                         harness-http-timeout)
                     nil #'harness-http--timeout request)))

(defun harness-http--timeout (request)
  "Abort REQUEST because nothing arrived in time."
  (when (and (not (harness-http-request-done request))
             (harness-http-request-process request))
    (let ((connecting (memq (harness-http-request-state request)
                            '(connecting headers))))
      (harness-http--fail
       request
       (harness-http--make-error
        :type (if connecting 'network 'timeout)
        :url (harness-http-request-url request)
        :message (if connecting
                     "timed out connecting to the server"
                   "timed out waiting for the server"))))))

(defun harness-http--cleanup (request)
  "Release REQUEST's process and timer."
  (when-let* ((timer (harness-http-request-timer request)))
    (cancel-timer timer))
  (setf (harness-http-request-timer request) nil)
  (let ((process (harness-http-request-process request)))
    (when (process-live-p process)
      (set-process-sentinel process #'ignore)
      (set-process-filter process #'ignore)
      (delete-process process)))
  (setf (harness-http-request-process request) nil)
  (setq harness-http--live-requests (delq request harness-http--live-requests)))

(defun harness-http--fail (request error)
  "Finish REQUEST by reporting ERROR."
  (unless (harness-http-request-done request)
    (setf (harness-http-request-done request) t)
    (harness-http--cleanup request)
    (unless (harness-http-request-aborted request)
      (when-let* ((callback (harness-http-request-on-error request)))
        (funcall callback error)))))

(defun harness-http--finish (request)
  "Finish REQUEST successfully, delivering status, headers and body."
  (unless (harness-http-request-done request)
    (setf (harness-http-request-done request) t)
    (let ((body (decode-coding-string
                 (or (harness-http-request-body-buffer request) "") 'utf-8-unix t))
          (status (harness-http-request-status request))
          (headers (harness-http-request-response-headers request)))
      (harness-http--cleanup request)
      (unless (harness-http-request-aborted request)
        (if (and status (>= status 400))
            (when-let* ((callback (harness-http-request-on-error request)))
              (funcall callback
                       (harness-http--make-error
                        :type 'http
                        :status status
                        :headers headers
                        :body body
                        :url (harness-http-request-url request)
                        :message (format "HTTP %s" status))))
          (when-let* ((callback (harness-http-request-on-complete request)))
            (funcall callback status headers body)))))))


;;; Process plumbing

(defun harness-http--sentinel (process event)
  "Handle PROCESS EVENT for the request attached to PROCESS."
  (let ((request (process-get process 'harness-request)))
    (when request
      (cond
       ((string-prefix-p "open" event)
        (harness-http--touch request)
        (harness-http--send request))
       ((string-prefix-p "failed" event)
        (harness-http--fail
         request
         (harness-http--make-error
          :type 'network
          :url (harness-http-request-url request)
          :message (string-trim event))))
       ((or (string-prefix-p "connection broken" event)
            (string-prefix-p "deleted" event))
        (harness-http--handle-eof request))
       (t nil)))))

(defun harness-http--handle-eof (request)
  "Handle the peer closing the connection for REQUEST."
  (when (not (harness-http-request-done request))
    ;; Run any buffered bytes through the parser before deciding.
    (when (not (string-empty-p (harness-http-request-pending request)))
      (harness-http--consume request ""))
    (when (not (harness-http-request-done request))
      (pcase (harness-http-request-state request)
        ('eof-body (harness-http--finish request))
        ('body
         (if (and (harness-http-request-remaining request)
                  (> (harness-http-request-remaining request) 0))
             (harness-http--fail
              request
              (harness-http--make-error
               :type 'network
               :url (harness-http-request-url request)
               :message "connection closed before the body was complete"))
           (harness-http--finish request)))
        ((or 'connecting 'headers 'chunk-size 'chunk-data 'chunk-crlf)
         (harness-http--fail
          request
          (harness-http--make-error
           :type 'network
           :url (harness-http-request-url request)
           :message (if (memq (harness-http-request-state request)
                              '(connecting headers))
                        "connection closed before a response was received"
                      "connection closed before the body was complete"))))
        (_ (harness-http--finish request))))))

(defun harness-http--send (request)
  "Write the request line, headers and body for REQUEST."
  (let* ((parsed (url-generic-parse-url (harness-http-request-url request)))
         (tls (equal (url-type parsed) "https"))
         (host (url-host parsed))
         (port (or (url-port parsed) (if tls 443 80)))
         (path (or (url-filename parsed) "/"))
         (body (harness-http-request-body request))
         (encoded-body (and body (encode-coding-string body 'utf-8-unix)))
         (headers (harness-http-request-headers request))
         (lines nil))
    (unless (or (and tls (= port 443)) (and (not tls) (= port 80)))
      (setq host (format "%s:%d" host port)))
    ;; The whole header block is built by `push'ing and reversed once at the
    ;; end, so the pieces cannot get out of order.
    (push (format "%s %s HTTP/1.1\r\n"
                  (harness-http-request-method request) path)
          lines)
    (push (format "Host: %s\r\n" host) lines)
    (push (format "User-Agent: %s\r\n" harness-http-user-agent) lines)
    (push "Accept: */*\r\n" lines)
    (push "Accept-Encoding: identity\r\n" lines)
    (push "Connection: close\r\n" lines)
    (when encoded-body
      (push (format "Content-Length: %d\r\n" (string-bytes encoded-body)) lines))
    (dolist (header headers)
      (let ((name (car header))
            (value (cdr header))
            (name-string (and (car header) (format "%s" (car header)))))
        (when (and name-string value
                   (not (string-prefix-p "content-length" (downcase name-string)))
                   (not (string-prefix-p "host" (downcase name-string)))
                   (not (string-prefix-p "connection" (downcase name-string))))
          (push (format "%s: %s\r\n"
                        (if (symbolp name) (capitalize (symbol-name name)) name)
                        value)
                lines))))
    (push "\r\n" lines)
    (condition-case err
        (progn
          (process-send-string
           (harness-http-request-process request)
           (encode-coding-string (apply #'concat (nreverse lines)) 'utf-8-unix))
          (when encoded-body
            (process-send-string (harness-http-request-process request)
                                 encoded-body)))
      (error
       (harness-http--fail
        request
        (harness-http--make-error
         :type 'network
         :url (harness-http-request-url request)
         :message (error-message-string err)))))))

(defun harness-http--filter (process chunk)
  "Feed CHUNK arriving on PROCESS into its request's state machine."
  (let ((request (process-get process 'harness-request)))
    (when (and request (not (harness-http-request-done request)))
      (harness-http--touch request)
      (harness-http--consume request chunk))))


;;; Response parsing

(defun harness-http--parse-response-head (string)
  "Parse the status line and headers in STRING.
Return a cons of (STATUS . HEADERS), with STATUS an integer and HEADERS an
alist of lowercased string keys."
  (let* ((lines (split-string string "\r?\n" t))
         (status-line (car lines))
         (status (when (and status-line
                            (string-match "\\`HTTP/[0-9.]+ +\\([0-9]+\\)" status-line))
                   (string-to-number (match-string 1 status-line))))
         (headers nil))
    (dolist (line (cdr lines))
      (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
        (push (cons (downcase (string-trim (match-string 1 line)))
                    (string-trim (match-string 2 line)))
              headers)))
    (cons status (nreverse headers))))

(defun harness-http--head-end (string)
  "Return (HEAD-END . SEPARATOR-LENGTH) for the header block in STRING, or nil."
  (let ((crlf (string-search "\r\n\r\n" string)))
    (if crlf
        (cons crlf 4)
      (let ((lf (string-search "\n\n" string)))
        (when lf (cons lf 2))))))

(defun harness-http--begin-body (request)
  "Decide how to read the body of REQUEST from its response headers."
  (let* ((headers (harness-http-request-response-headers request))
         (chunked (let ((te (harness-alist-get :transfer-encoding headers)))
                    (and te (string-match-p "chunked" (downcase te)))))
         (length (let ((cl (harness-alist-get :content-length headers)))
                   (and cl
                        (string-match-p "\\`[0-9]+\\'" (string-trim cl))
                        (string-to-number (string-trim cl))))))
    (setf (harness-http-request-transfer-encoding request)
          (and chunked 'chunked))
    (cond
     (chunked
      (setf (harness-http-request-state request) 'chunk-size))
     (length
      (setf (harness-http-request-content-length request) length)
      (setf (harness-http-request-remaining request) length)
      (setf (harness-http-request-state request) 'body))
     (t
      (setf (harness-http-request-state request) 'eof-body)))))

(defun harness-http--maybe-redirect (request)
  "Follow a redirect for REQUEST when appropriate.  Return non-nil when it did."
  (let ((status (harness-http-request-status request)))
    (when (and (memq status harness-http--redirect-statuses)
               (not (harness-http-request-no-redirect request))
               (< (harness-http-request-redirects request)
                  harness-http-max-redirects))
      (let ((location (harness-alist-get :location
                                         (harness-http-request-response-headers request))))
        (when (and location (not (string-empty-p location)))
          (let ((url (url-expand-file-name
                      location (harness-http-request-url request))))
            (harness--log "redirect %s -> %s" (harness-http-request-url request) url)
            (harness-http--cleanup request)
            (setf (harness-http-request-redirects request)
                  (1+ (harness-http-request-redirects request)))
            (harness-http--start request url)
            t))))))

(defun harness-http--consume (request chunk)
  "Advance REQUEST's parser with CHUNK."
  (let ((input (concat (harness-http-request-pending request) chunk)))
    (setf (harness-http-request-pending request) "")
    (while (and (not (string-empty-p input))
                (not (harness-http-request-done request)))
      (pcase (harness-http-request-state request)
        ((or 'connecting 'headers)
         (let ((sep (harness-http--head-end input)))
           (if (not sep)
               (progn
                 (setf (harness-http-request-pending request) input)
                 (setq input ""))
             (let* ((head (substring input 0 (car sep)))
                    (rest (substring input (+ (car sep) (cdr sep))))
                    (parsed (harness-http--parse-response-head head)))
               (setf (harness-http-request-status request) (car parsed))
               (setf (harness-http-request-response-headers request) (cdr parsed))
               (if (harness-http--maybe-redirect request)
                   (setq input "")
                 (harness-http--begin-body request)
                 (setq input rest))))))
        ('body
         (let* ((remaining (harness-http-request-remaining request))
                (take (if remaining (min (length input) remaining) (length input)))
                (part (substring input 0 take)))
           (setq input (substring input take))
           (when (> take 0)
             (harness-http--body-chunk request part))
           (when (and (harness-http-request-remaining request)
                      (not (harness-http-request-done request)))
             (setf (harness-http-request-remaining request)
                   (- (harness-http-request-remaining request) take))
             (when (<= (harness-http-request-remaining request) 0)
               (setf (harness-http-request-remaining request) nil)
               (harness-http--finish request)))))
        ('eof-body
         (harness-http--body-chunk request input)
         (setq input ""))
        ('chunk-size
         (let ((eol (string-search "\r\n" input)))
           (if (not eol)
               (progn
                 (setf (harness-http-request-pending request) input)
                 (setq input ""))
             (let* ((line (substring input 0 eol))
                    (size-text (car (split-string line ";")))
                    (size (condition-case nil
                              (string-to-number (string-trim size-text) 16)
                            (error 0))))
               (setq input (substring input (+ eol 2)))
               (if (or (not (integerp size)) (<= size 0))
                   (setf (harness-http-request-state request) 'trailer)
                 (setf (harness-http-request-remaining request) size)
                 (setf (harness-http-request-state request) 'chunk-data))))))
        ('chunk-data
         (let* ((remaining (or (harness-http-request-remaining request) 0))
                (take (min (length input) remaining))
                (part (substring input 0 take)))
           (setq input (substring input take))
           (when (> take 0)
             (harness-http--body-chunk request part)
             (setf (harness-http-request-remaining request) (- remaining take)))
           (when (<= (or (harness-http-request-remaining request) 0) 0)
             (setf (harness-http-request-remaining request) nil)
             (setf (harness-http-request-state request) 'chunk-crlf))))
        ('chunk-crlf
         (cond
          ((string-prefix-p "\r\n" input)
           (setq input (substring input 2))
           (setf (harness-http-request-state request) 'chunk-size))
          ((string-prefix-p "\n" input)
           (setq input (substring input 1))
           (setf (harness-http-request-state request) 'chunk-size))
          ((and (string-prefix-p "\r" input) (= (length input) 1))
           (setf (harness-http-request-pending request) input)
           (setq input ""))
          (t
           ;; Malformed chunk terminator; resynchronise at the next line.
           (let ((eol (string-search "\n" input)))
             (if eol
                 (progn
                   (setq input (substring input (1+ eol)))
                   (setf (harness-http-request-state request) 'chunk-size))
               (progn
                 (setf (harness-http-request-pending request) input)
                 (setq input "")))))))
        ('trailer
         (cond
          ((or (string-prefix-p "\r\n" input)
               (string-prefix-p "\n" input))
           (harness-http--finish request)
           (setq input ""))
          (t
           (let ((eol (string-search "\r\n" input)))
             (if eol
                 (setq input (substring input (+ eol 2)))
               (setf (harness-http-request-pending request) input)
               (setq input ""))))))
        ('done
         (setq input ""))))))

(defun harness-http--body-chunk (request string)
  "Handle STRING as body bytes of REQUEST."
  (let ((current (or (harness-http-request-body-buffer request) "")))
    (cond
     ((> (+ (length current) (length string))
         (or (harness-http-request-max-body request) most-positive-fixnum))
      (harness-http--fail
       request
       (harness-http--make-error
        :type 'too-large
        :url (harness-http-request-url request)
        :message "response body exceeded `harness-http-max-body'")))
     (t
      (setf (harness-http-request-body-buffer request) (concat current string))
      (when-let* ((callback (harness-http-request-on-chunk request)))
        (funcall callback string))
      (when-let* ((callback (harness-http-request-on-event request)))
        (harness-http--feed-sse request string callback))))))

(defun harness-http--feed-sse (request string callback)
  "Feed STRING into REQUEST's server-sent-events parser, calling CALLBACK."
  (let ((buffer (concat (or (harness-http-request-sse-buffer request) "") string))
        (draining t))
    (while draining
      (let ((eol (string-search "\n" buffer)))
        (if (not eol)
            (setq draining nil)
          (let* ((line (substring buffer 0 eol))
                 (clean (if (string-suffix-p "\r" line)
                            (substring line 0 -1)
                          line)))
            (setq buffer (substring buffer (1+ eol)))
            (cond
             ((string-empty-p clean)
              (let ((event (harness-http-request-sse-event request)))
                (when (and event (not (string-empty-p event)))
                  (funcall callback (decode-coding-string event 'utf-8-unix t)))
                (setf (harness-http-request-sse-event request) nil)))
             ((string-prefix-p ":" clean) nil)
             ((string-prefix-p "data:" clean)
              (let ((value (substring clean 5)))
                (when (string-prefix-p " " value)
                  (setq value (substring value 1)))
                (let ((prior (harness-http-request-sse-event request)))
                  (setf (harness-http-request-sse-event request)
                        (if prior (concat prior "\n" value) value)))))
             (t nil))))))
    (setf (harness-http-request-sse-buffer request) buffer)))

(provide 'harness-http)
;;; harness-http.el ends here
