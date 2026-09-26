;;; harness-http.el --- Asynchronous HTTP/1.1 and SSE -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A small async HTTP/1.1 client for the completion providers.  Everything
;; is filter/sentinel driven: connecting (including DNS and TLS with
;; `:nowait'), sending, header parsing, chunked decoding and streaming
;; callbacks all happen without waiting for the network.
;;
;; `harness-http-fetch' returns a deferred resolving to a
;; `harness-http-response'.  Streaming consumers pass `:on-line' to receive
;; complete, decoded lines (this is what SSE parsing wants) or `:on-chunk'
;; for raw decoded text.
;;
;; Not implemented (yet, and deliberately): proxies, HTTP/2, gzip.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gnutls)
(require 'harness-core)

(define-error 'harness-http-error "HTTP error" 'harness-error)

(cl-defstruct (harness-http-response (:constructor harness-http-response--make))
  url status headers body)

(defcustom harness-http-default-timeout 300
  "Default total request timeout in seconds."
  :type 'number)

(defcustom harness-http-default-user-agent
  (format "emacs-agent-harness/%s (Emacs %s)" harness-version emacs-version)
  "User-Agent header sent with requests."
  :type 'string)

;;; URL parsing

(defun harness-http-parse-url (url)
  "Parse URL into a plist with :tls, :host, :port and :path."
  (unless (string-match "\\`\\(https?\\)://\\([^/:?#]+\\)\\(?::\\([0-9]+\\)\\)?\\([^?#]*\\)\\(\\?[^#]*\\)?" url)
    (signal 'harness-http-error (list (format "Unsupported URL: %s" url))))
  (let* ((scheme (match-string 1 url))
         (host (match-string 2 url))
         (port (if (match-string 3 url)
                   (string-to-number (match-string 3 url))
                 (if (equal scheme "https") 443 80)))
         (path (let ((raw (match-string 4 url)))
                 (if (or (null raw) (string-empty-p raw)) "/" raw)))
         (query (match-string 5 url)))
    (list :tls (equal scheme "https")
          :host host
          :port port
          :path (if query (concat path query) path))))

;;; Request state

(cl-defstruct (harness-http--state (:constructor harness-http--state-create))
  url options deferred
  process timeout-timer
  (pending "")                ; unibyte bytes not yet parsed
  (headers nil)
  status
  ;; headers, content-length, chunked-size, chunked-data, chunked-crlf,
  ;; chunked-trailers, close
  (phase 'headers)
  (remaining 0)
  (body-parts nil)
  (line-buffer "")
  (redirects 0)
  (settled nil))

(defun harness-http--deliver (state text)
  "Deliver decoded TEXT to the state's callbacks and body."
  (when (and text (not (string-empty-p text)))
    (push text (harness-http--state-body-parts state))
    (when-let* ((on-chunk (plist-get (harness-http--state-options state) :on-chunk)))
      (funcall on-chunk text))
    (when-let* ((on-line (plist-get (harness-http--state-options state) :on-line)))
      (let ((buffer (concat (harness-http--state-line-buffer state) text)))
        (while (string-match "\n" buffer)
          (let ((line (substring buffer 0 (match-beginning 0))))
            (setq buffer (substring buffer (match-end 0)))
            (funcall on-line (if (string-suffix-p "\r" line)
                                 (substring line 0 -1)
                               line))))
        (setf (harness-http--state-line-buffer state) buffer)))))

(defun harness-http--deliver-last-line (state)
  "Deliver whatever is left in the line buffer as a final line."
  (let ((rest (harness-http--state-line-buffer state)))
    (when (and rest (not (string-empty-p rest)))
      (setf (harness-http--state-line-buffer state) "")
      (when-let* ((on-line (plist-get (harness-http--state-options state) :on-line)))
        (funcall on-line (if (string-suffix-p "\r" rest) (substring rest 0 -1) rest))))))

(defun harness-http--close-process (state)
  "Detach and delete STATE's process, if any."
  (when (harness-http--state-process state)
    (let ((process (harness-http--state-process state)))
      (set-process-filter process #'ignore)
      (set-process-sentinel process #'ignore)
      (when (process-live-p process)
        (delete-process process)))))

(defun harness-http--abort (state)
  "Stop STATE's transfer without settling its deferred.
Used for cancellation, where the deferred's own cancel handling settles it."
  (unless (harness-http--state-settled state)
    (setf (harness-http--state-settled state) t)
    (when (harness-http--state-timeout-timer state)
      (cancel-timer (harness-http--state-timeout-timer state)))
    (harness-http--close-process state)))

(defun harness-http--finish (state)
  "Settle STATE's deferred with the response."
  (unless (harness-http--state-settled state)
    (setf (harness-http--state-settled state) t)
    (when (harness-http--state-timeout-timer state)
      (cancel-timer (harness-http--state-timeout-timer state)))
    (harness-http--deliver-last-line state)
    (let* ((options (harness-http--state-options state))
           (body (apply #'concat (nreverse (harness-http--state-body-parts state))))
           (response (harness-http-response--make
                      :url (harness-http--state-url state)
                      :status (harness-http--state-status state)
                      :headers (harness-http--state-headers state)
                      :body (if (plist-get options :binary)
                                body
                              (decode-coding-string body 'utf-8)))))
      (harness-http--close-process state)
      (when-let* ((on-done (plist-get options :on-done)))
        (ignore-errors (funcall on-done response)))
      (harness-deferred-resolve (harness-http--state-deferred state) response))))

(defun harness-http--fail (state message)
  "Reject STATE's deferred with MESSAGE and clean up."
  (unless (harness-http--state-settled state)
    (setf (harness-http--state-settled state) t)
    (when (harness-http--state-timeout-timer state)
      (cancel-timer (harness-http--state-timeout-timer state)))
    (harness-http--close-process state)
    (harness-deferred-reject (harness-http--state-deferred state)
                             (cons 'harness-http-error (list message)))))

;;; Headers and body framing

(defun harness-http--parse-headers (state header-text)
  "Parse HEADER-TEXT into STATE.  Returns non-nil on success."
  (let ((lines (split-string header-text "\r\n" t)))
    (if (or (null lines)
            (not (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\)" (car lines))))
        (progn
          (harness-http--fail state (format "Bad HTTP status line: %S" (car lines)))
          nil)
      (setf (harness-http--state-status state)
            (string-to-number (match-string 1 (car lines))))
      (setf (harness-http--state-headers state)
            (mapcar (lambda (line)
                      (if (string-match "\\`\\([^:]+\\): *\\(.*\\)\\'" line)
                          (cons (downcase (string-trim (match-string 1 line)))
                                (string-trim (match-string 2 line)))
                        (cons (downcase line) "")))
                    (cdr lines)))
      t)))

(defun harness-http--header (state name)
  "Return header NAME of STATE, case-insensitively, or nil."
  (cdr (assoc (downcase name) (harness-http--state-headers state))))

(defun harness-http--set-body-phase (state)
  "Choose the body reader for STATE after its headers were parsed.
Returns non-nil when the response is already complete."
  (let ((transfer (harness-http--header state "transfer-encoding"))
        (length (harness-http--header state "content-length")))
    (cond
     ((and transfer (string-match-p "chunked" (downcase transfer)))
      (setf (harness-http--state-phase state) 'chunked-size)
      nil)
     (length
      (setf (harness-http--state-remaining state) (string-to-number length)
            (harness-http--state-phase state) 'content-length)
      (zerop (harness-http--state-remaining state)))
     (t
      (setf (harness-http--state-phase state) 'close)
      nil))))

(defun harness-http--consume (state chunk)
  "Feed CHUNK (unibyte) into STATE's parser."
  (setf (harness-http--state-pending state)
        (concat (harness-http--state-pending state) chunk))
  (catch 'done
    (while (not (harness-http--state-settled state))
      (pcase (harness-http--state-phase state)
        ('headers
         (let ((pending (harness-http--state-pending state)))
           (if (not (string-match "\r\n\r\n" pending))
               (throw 'done nil)
             (let* ((header-end (match-end 0))
                    (header-text (substring pending 0 (match-beginning 0)))
                    (tail (substring pending header-end)))
               (setf (harness-http--state-pending state) tail)
               (when (harness-http--parse-headers state header-text)
                 (if (harness-http--set-body-phase state)
                     (harness-http--complete-response state)
                   nil))))))
        ('content-length
         (let ((pending (harness-http--state-pending state)))
           (if (string-empty-p pending)
               (throw 'done nil)
             (let* ((take (min (length pending) (harness-http--state-remaining state)))
                    (piece (substring pending 0 take)))
               (setf (harness-http--state-pending state) (substring pending take))
               (cl-decf (harness-http--state-remaining state) take)
               (harness-http--deliver state (decode-coding-string piece 'utf-8))
               (when (zerop (harness-http--state-remaining state))
                 (harness-http--complete-response state))))))
        ('chunked-size
         (let ((pending (harness-http--state-pending state)))
           (if (not (string-match "\r\n" pending))
               (throw 'done nil)
             (let ((size-line (substring pending 0 (match-beginning 0))))
               (setf (harness-http--state-pending state) (substring pending (match-end 0)))
               (let ((size (string-to-number (string-trim size-line) 16)))
                 (if (zerop size)
                     (setf (harness-http--state-phase state) 'chunked-trailers)
                   (setf (harness-http--state-remaining state) size
                         (harness-http--state-phase state) 'chunked-data)))))))
        ('chunked-data
         (let ((pending (harness-http--state-pending state)))
           (if (string-empty-p pending)
               (throw 'done nil)
             (let* ((take (min (length pending) (harness-http--state-remaining state)))
                    (piece (substring pending 0 take)))
               (setf (harness-http--state-pending state) (substring pending take))
               (cl-decf (harness-http--state-remaining state) take)
               (harness-http--deliver state (decode-coding-string piece 'utf-8))
               (when (zerop (harness-http--state-remaining state))
                 (setf (harness-http--state-phase state) 'chunked-crlf))))))
        ('chunked-crlf
         (let ((pending (harness-http--state-pending state)))
           (if (< (length pending) 2)
               (throw 'done nil)
             (setf (harness-http--state-pending state) (substring pending 2)
                   (harness-http--state-phase state) 'chunked-size))))
        ('chunked-trailers
         (let ((pending (harness-http--state-pending state)))
           (cond
            ((string-match "\\`\r\n" pending)
             (setf (harness-http--state-pending state) (substring pending 2))
             (harness-http--complete-response state))
            ((string-match "\r\n\r\n" pending)
             (setf (harness-http--state-pending state) (substring pending (match-end 0)))
             (harness-http--complete-response state))
            (t (throw 'done nil)))))
        ('close
         (let ((pending (harness-http--state-pending state)))
           (setf (harness-http--state-pending state) "")
           (harness-http--deliver state (decode-coding-string pending 'utf-8))
           (throw 'done nil)))))))

(defun harness-http--complete-response (state)
  "Either follow a redirect for STATE or finish it."
  (let ((status (harness-http--state-status state))
        (location (harness-http--header state "location")))
    (if (and location (memq status '(301 302 303 307 308)))
        (harness-http--redirect state location)
      (harness-http--finish state))
    (throw 'done nil)))

(defun harness-http--redirect (state location)
  "Restart STATE at LOCATION, sharing its deferred."
  (let* ((options (harness-http--state-options state))
         (redirects (1+ (harness-http--state-redirects state)))
         (parsed (harness-http-parse-url (harness-http--state-url state)))
         (url (if (string-match-p "\\`https?://" location)
                  location
                (format "%s://%s%s%s"
                        (if (plist-get parsed :tls) "https" "http")
                        (plist-get parsed :host)
                        (if (memq (plist-get parsed :port) '(80 443))
                            ""
                          (format ":%s" (plist-get parsed :port)))
                        location))))
    (cond
     ((> redirects (or (plist-get options :max-redirects) 5))
      (harness-http--fail state "Too many redirects"))
     (t
      ;; Abandon this state without settling; the new one owns the deferred.
      (setf (harness-http--state-settled state) t)
      (when (harness-http--state-timeout-timer state)
        (cancel-timer (harness-http--state-timeout-timer state)))
      (harness-http--close-process state)
      (let ((new-options (if (memq (harness-http--state-status state) '(301 302 303))
                             (plist-put (plist-put (copy-sequence options)
                                                   :method "GET")
                                        :body nil)
                           options)))
        (harness-log "http redirect %s -> %s" (harness-http--state-url state) url)
        (harness-http-fetch-into state url new-options redirects))))))

;;; Connecting and sending

(defun harness-http--tls-parameters (host insecure)
  "Return `:tls-parameters' for HOST.  INSECURE disables verification."
  (cons 'gnutls-x509pki
        (gnutls-boot-parameters :hostname host
                                :verify-error (if insecure nil t))))

(defun harness-http--connect (host port tls insecure)
  "Start a connection to HOST:PORT and return the process."
  (let ((name (format "harness-http-%s:%s" host port)))
    (condition-case err
        (if tls
            (open-network-stream
             name nil host port
             :type 'tls
             :nowait t
             :coding 'binary
             :noquery t
             :tls-parameters (harness-http--tls-parameters host insecure))
          (make-network-process
           :name name :host host :service port :family 'ipv4
           :nowait t :coding 'binary :noquery t))
      (error
       (signal 'harness-http-error
               (list (format "Cannot connect to %s:%s: %s" host port (error-message-string err))))))))

(defun harness-http--request-string (state)
  "Build the HTTP request string for STATE."
  (let* ((options (harness-http--state-options state))
         (parsed (harness-http-parse-url (harness-http--state-url state)))
         (method (or (plist-get options :method) "GET"))
         (body (plist-get options :body))
         (headers (copy-sequence (plist-get options :headers)))
         (host (plist-get parsed :host)))
    (unless (assoc "Host" headers)
      (push (cons "Host" (if (memq (plist-get parsed :port)
                                   (if (plist-get parsed :tls) '(443) '(80)))
                             host
                           (format "%s:%s" host (plist-get parsed :port))))
            headers))
    (unless (assoc "User-Agent" headers)
      (push (cons "User-Agent" harness-http-default-user-agent) headers))
    (unless (assoc "Accept" headers)
      (push (cons "Accept" "*/*") headers))
    (unless (assoc "Accept-Encoding" headers)
      (push (cons "Accept-Encoding" "identity") headers))
    (unless (assoc "Connection" headers)
      (push (cons "Connection" "close") headers))
    (when body
      (unless (assoc "Content-Type" headers)
        (push (cons "Content-Type" "application/json") headers))
      (unless (assoc "Content-Length" headers)
        (push (cons "Content-Length" (number-to-string (string-bytes body))) headers)))
    (concat
     (format "%s %s HTTP/1.1\r\n" method (plist-get parsed :path))
     (mapconcat (lambda (header) (format "%s: %s\r\n" (car header) (cdr header))) headers)
     "\r\n"
     (or body ""))))

(defun harness-http-fetch-into (state url options redirects)
  "Restart STATE against URL with OPTIONS, after REDIRECTS redirects.
The new request shares STATE's deferred."
  (let ((new-state (harness-http--state-create
                    :url url
                    :options options
                    :deferred (harness-http--state-deferred state)
                    :redirects redirects)))
    (harness-http--start new-state (harness-http-parse-url url))
    (harness-http--state-deferred new-state)))

;;;###autoload
(defun harness-http-fetch (url &rest options)
  "Fetch URL asynchronously.  Returns a deferred of `harness-http-response'.

OPTIONS:

  :method        HTTP method, defaults to GET
  :headers       alist of header names and values
  :body          request body string
  :timeout       total timeout in seconds
  :on-chunk      called with decoded body text as it arrives
  :on-line       called with complete decoded lines instead
  :max-redirects redirect limit, default 5
  :insecure      skip TLS verification when non-nil

Use `harness-http-response-body', `-status' and `-headers' on the
resolved value."
  (let* ((state (harness-http--state-create
                 :url url :options options :deferred (harness-deferred-new))))
    (harness-http--start state (harness-http-parse-url url))
    (harness-http--state-deferred state)))

(defun harness-http--start (state parsed)
  "Open the connection and send the request for STATE to PARSED."
  (let* ((options (harness-http--state-options state))
         (host (plist-get parsed :host))
         (port (plist-get parsed :port))
         (tls (plist-get parsed :tls))
         (timeout (or (plist-get options :timeout) harness-http-default-timeout))
         (process (harness-http--connect host port tls (plist-get options :insecure))))
    (setf (harness-http--state-process state) process)
    (setf (harness-http--state-timeout-timer state)
          (run-at-time timeout nil
                       (lambda ()
                         (harness-http--fail
                          state (format "Request timed out after %ss: %s"
                                        timeout (harness-http--state-url state))))))
    (harness-deferred-on-cancel (harness-http--state-deferred state)
                                (lambda () (harness-http--abort state)))
    (set-process-sentinel
     process
     (lambda (proc event)
       (cond
        ((string-prefix-p "open" event)
         (condition-case err
             (process-send-string proc (harness-http--request-string state))
           (error (harness-http--fail state (error-message-string err)))))
        ((string-prefix-p "failed" event)
         (harness-http--fail state (format "Connection failed: %s (%s)"
                                           (harness-http--state-url state) event)))
        ((string-match-p "\\`\\(closed\\|connection broken\\|deleted\\|exited\\)" event)
         (unless (harness-http--state-settled state)
           (pcase (harness-http--state-phase state)
             ((or 'close 'chunked-trailers) (harness-http--finish state))
             ('headers (harness-http--fail state "Connection closed before response"))
             (_ (harness-http--fail state "Connection closed mid-response")))))
        (t nil))))
    (set-process-filter process
                        (lambda (_proc chunk)
                          (unless (harness-http--state-settled state)
                            (harness-http--consume state chunk))))
    process))

(defun harness-http-setup ()
  "Set up the HTTP module."
  (harness-service-register
   "http"
   :module 'harness-http
   :doc "Asynchronous HTTP client."
   :methods '((fetch . harness-http-fetch))))

(harness-module-define 'harness-http
  :version harness-version
  :description "Asynchronous HTTP/1.1 client with SSE-friendly streaming."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-http)
  :setup #'harness-http-setup)

(provide 'harness-http)
;;; harness-http.el ends here
