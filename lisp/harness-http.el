;;; harness-http.el --- Asynchronous HTTP with streaming for the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; A tiny HTTP client on top of curl run as an asynchronous subprocess.
;; It never blocks the main thread: the response arrives in a process
;; filter and is handed to callbacks.  Server-sent events are parsed
;; incrementally so providers can stream tokens as they arrive.
;;
;; Secrets never appear on the command line: headers and the URL go
;; through a mode 600 curl config file that is deleted when the
;; request finishes, and the body goes through stdin.
;;
;; Text is exchanged as UTF-8.  A request made with `:binary' instead
;; sends and receives raw bytes, for binary framings such as AWS event
;; streams: the response reaches the callbacks as unibyte strings.
;;
;; Entry points:
;;   `harness-http-request'   -- start a request, returns a handle
;;   `harness-http-cancel'    -- abort it
;;   `harness-http-sse-parser' -- build an :on-chunk function for SSE
;;   `harness-http-download'  -- download a URL into a file, with progress
;;   `harness-http-download-cancel' -- abort a download
;;
;; A download never passes the body through Emacs: curl writes the file
;; itself, the response headers arrive as soon as they are sent (so a
;; caller can stop a download it does not want, a web page say), and the
;; progress is the size of the file so far against its Content-Length.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-http--curl-program (executable-find "curl")
  "Path to curl.  When nil requests fail with an explanatory error.")

(defconst harness-http--default-timeout 600
  "Default maximum seconds a request may take, including streaming.")

;;;; Retries
;;
;; A connection a proxy, a load balancer or a sleeping laptop drops is
;; not an answer: curl reports a reset, an empty reply or a timeout, and
;; the same request may well succeed at once.  A request whose failure
;; was such a connection-level one, and of which nothing reached the
;; caller yet, is tried again a bounded number of times, waiting a
;; little longer each time.  A request that already delivered body
;; bytes is never tried again here: the caller has seen a prefix it
;; could not unsee, and repeating it would duplicate content.  Retrying
;; such a request, or a model stream cut in the middle, is the agent
;; layer's business, where the partial output can be discarded.
;;
;; Curl's own `--retry' is not what does this: it cannot say what the
;; caller has already been handed, and the point is to repeat only a
;; request of which nothing was, so the retries are scheduled here, from
;; the sentinel, where each attempt's delivered state is known.

(defcustom harness-http-max-retries 3
  "How many times a request may be tried again after a transient failure.
See `harness-http-request' for which requests retry at all: a
request made with `:retry t' retries this many times, while without it
only an idempotent one (GET or HEAD) does.  A request whose body
already reached its caller's chunk function is never retried."
  :type 'integer :group 'harness)

(defcustom harness-http-retry-delay 0.5
  "Seconds to wait before the first retry of a request.
Each further retry waits twice as long, up to
`harness-http-retry-max-delay'."
  :type 'number :group 'harness)

(defcustom harness-http-retry-max-delay 15.0
  "Longest the harness waits before trying a request again, in seconds.
It caps both the growing backoff and a server's Retry-After: a wait
longer than this is better spent ending the request and letting the
caller decide."
  :type 'number :group 'harness)

(defcustom harness-http-retry-jitter 0.2
  "Fraction of the backoff a retry may be spread by, for randomness.
Several requests failing together (a provider that went down, say)
then do not all come back in the same instant.  Nil or 0 waits exactly
the backoff."
  :type 'number :group 'harness)

(defconst harness-http--transient-curl-exits '(6 7 18 28 35 52 55 56)
  "curl exit codes a retry can be expected to get past.
6 a DNS failure, 7 a refused or unreachable host, 18 a transfer cut
short, 28 a timeout, 35 a TLS failure, 52 an empty reply, 55 a failed
send and 56 a failed receive.")

(defconst harness-http--curl-explanations
  '((6 . "the host could not be resolved")
    (7 . "could not connect to the server")
    (18 . "the transfer was cut short")
    (28 . "the request timed out")
    (35 . "the TLS connection failed")
    (52 . "the server closed the connection without answering")
    (55 . "the request could not be sent")
    (56 . "the connection was reset by the peer"))
  "What a transient curl failure means, in the words a user reads.")

(defconst harness-http--retryable-statuses '(408 429 500 502 503 504)
  "HTTP statuses a request is tried again for.
A request's own timeout, a rate limit and the server-side failures a
retry can survive.  Only a response whose body was not streamed to the
caller is tried again: see `harness-http--retry-delay'.")

(cl-defstruct (harness-http-handle (:copier nil))
  process url config-file body-file timeout timer
  (status nil) (headers nil) (header-buffer "")
  (headers-done nil) (body "")
  callback on-chunk on-headers
  (cancelled nil) (done nil) started
  args binary (retry 0) (retries 0) retry-timer chunk-delivered)

(defvar harness-http--active nil "List of live handles.")

(defun harness-http--curl-failure (code stderr event)
  "Return the failure of a curl that exited CODE, saying what it means.
STDERR is what curl printed and EVENT how it ended.  A transient
connection failure reads as its meaning, the code curl gave it and what
curl said, so a turn ends with \"the connection was reset by the peer
\(curl 56: Recv failure: Connection reset by peer)\" rather than with a
bare exit code.  The error also carries `:code' and `:kind' (`transport'
for the failures a retry can survive), which providers read."
  (let* ((detail (string-trim (replace-regexp-in-string
                               "\\`curl: ([0-9]+) " "" (string-trim (or stderr "")))))
         (meaning (cdr (assq code harness-http--curl-explanations)))
         (transient (memq code harness-http--transient-curl-exits)))
    (list 'curl
          (cond ((and meaning (not (string-empty-p detail)))
                 (format "%s (curl %d: %s)" meaning code detail))
                (meaning (format "%s (curl %d)" meaning code))
                (t (format "curl exited %d (%s): %s" code (string-trim event) detail)))
          :code code
          :kind (if transient 'transport 'curl)
          :transient (and transient t))))

(defun harness-http-transient-error-p (err)
  "Non-nil when ERR, as a request callback gets it, is worth another try.
That is a connection-level failure curl can be expected to get past: a
reset, an empty reply, a refused or unreachable host, a timeout before
the response began, a TLS or DNS failure.  A cancelled request, a
timeout of the transfer itself, a server that refused the request and a
malformed answer are not transient."
  (and (consp err)
       (eq (car err) 'curl)
       (let ((code (plist-get err :code)))
         (and (integerp code) (memq code harness-http--transient-curl-exits) t))))

(defun harness-http--retryable-status-p (status)
  "Non-nil when STATUS is one a request may be tried again for."
  (and (integerp status) (memq status harness-http--retryable-statuses) t))

(defun harness-http--backoff (attempt)
  "Seconds to wait before ATTEMPT, counting 1 for the first retry.
The delay doubles per attempt, up to `harness-http-retry-max-delay',
and is spread by up to `harness-http-retry-jitter' of itself."
  (let* ((base (* harness-http-retry-delay (expt 2 (1- (max 1 attempt)))))
         (jitter (max 0 (* base (or harness-http-retry-jitter 0) (/ (random 1000) 1000.0)))))
    (min harness-http-retry-max-delay (+ base jitter))))

(defun harness-http-retry-after (headers)
  "Return the seconds a Retry-After header among HEADERS asks to wait.
Only the delay-seconds form is read; an HTTP-date is ignored, since a
wait the harness would have to compute is better left to the caller.
The name is matched whatever its case: a parsed response downcases it,
a caller's own list need not."
  (let ((value (cdr (assoc-string "retry-after" headers t))))
    (when (and (stringp value) (string-match-p "\\`[ \t]*[0-9]+[ \t]*\\'" value))
      (string-to-number value))))

(defun harness-http--retries (method retry)
  "How many times a request with METHOD may be tried again, under RETRY.
RETRY nil is the default policy: an idempotent request (GET or HEAD)
may be tried again `harness-http-max-retries' times, any other not at
all.  RETRY t says the same for any method -- a provider's POST is
repeatable, and a retry is worth it -- a number that many tries, and 0
none.  A negative number counts as none."
  (cond ((null retry) (if (member (upcase (or method "GET")) '("GET" "HEAD"))
                          harness-http-max-retries
                        0))
        ((eq retry t) harness-http-max-retries)
        ((integerp retry) (max 0 retry))
        (t 0)))

(defun harness-http--retry-delay (handle status err)
  "Return the seconds to wait before trying HANDLE again, or nil not to.
A transient connection failure (ERR; see
`harness-http-transient-error-p') is retried when none of the body
reached the caller yet, and a retryable response (STATUS) when the body
was accumulated for the final callback rather than streamed: the caller
has then seen nothing a second attempt could duplicate.  Headers the
caller already saw are delivered again by the next attempt.  A request
that timed out after its response began, meaning a stalled transfer
rather than a lost connection, is not retried."
  (when (and (not (harness-http-handle-done handle))
             (not (harness-http-handle-cancelled handle))
             (< (harness-http-handle-retries handle)
                (harness-http-handle-retry handle))
             (or (and (harness-http-transient-error-p err)
                      (not (harness-http-handle-chunk-delivered handle))
                      (not (and (eq (plist-get err :code) 28)
                                (harness-http-handle-headers-done handle))))
                 (and (harness-http--retryable-status-p status)
                      (null (harness-http-handle-on-chunk handle)))))
    (let* ((attempt (1+ (harness-http-handle-retries handle)))
           (asked (and (harness-http--retryable-status-p status)
                       (harness-http-retry-after (harness-http-handle-headers handle)))))
      (max (harness-http--backoff attempt) (or asked 0) 0))))

(defun harness-http--retry-now (handle)
  "Start another attempt of HANDLE, unless it settled meanwhile."
  (setf (harness-http-handle-retry-timer handle) nil)
  (unless (or (harness-http-handle-done handle) (harness-http-handle-cancelled handle))
    (condition-case err
        (harness-http--attempt handle)
      (error (harness-http--finish
              handle (list 'curl (format "trying the request again failed: %s"
                                         (error-message-string err))))))))

(defun harness-http--retry (handle delay reason)
  "Try HANDLE again in DELAY seconds, because REASON; nil when scheduled.
The attempt count is bounded by the request's `:retry', so nothing
loops for ever.  The watchdog of the attempt that failed is stopped, so
it cannot end the request while the retry waits."
  (when-let* ((timer (harness-http-handle-timer handle)))
    (cancel-timer timer)
    (setf (harness-http-handle-timer handle) nil))
  (cl-incf (harness-http-handle-retries handle))
  (harness-log 'info "http: %s failed (%s); trying again in %.1fs (%d of %d)"
               (harness-http-handle-url handle) reason delay
               (harness-http-handle-retries handle) (harness-http-handle-retry handle))
  (setf (harness-http-handle-retry-timer handle)
        (run-at-time delay nil (lambda () (harness-http--retry-now handle))))
  t)

(defun harness-http--parse-headers (text)
  "Parse the header block TEXT into (STATUS . ALIST) with downcased names."
  (let* ((lines (split-string text "\r?\n" t))
         (status (and (car lines)
                      (string-match "^HTTP/[0-9.]+ \\([0-9]+\\)" (car lines))
                      (string-to-number (match-string 1 (car lines)))))
         (headers nil))
    (dolist (l (cdr lines))
      (when (string-match "^\\([^:]+\\):[ \t]*\\(.*\\)$" l)
        (push (cons (downcase (match-string 1 l)) (match-string 2 l)) headers)))
    (cons status (nreverse headers))))

(defun harness-http--filter (handle data)
  "Process DATA arriving for HANDLE."
  (unless (harness-http-handle-cancelled handle)
    (if (harness-http-handle-headers-done handle)
        (harness-http--body handle data)
      (setf (harness-http-handle-header-buffer handle)
            (concat (harness-http-handle-header-buffer handle) data))
      (let ((buf (harness-http-handle-header-buffer handle))
            (done nil))
        (while (and (not done) (string-match "\r?\n\r?\n" buf))
          (let* ((end (match-end 0))
                 (block (substring buf 0 (match-beginning 0)))
                 (parsed (harness-http--parse-headers block)))
            (setq buf (substring buf end))
            ;; Skip informational responses (100 Continue and friends).
            (if (and (car parsed) (< (car parsed) 200))
                nil
              (setf (harness-http-handle-status handle) (car parsed)
                    (harness-http-handle-headers handle) (cdr parsed)
                    (harness-http-handle-headers-done handle) t)
              (setq done t)
              (when (harness-http-handle-on-headers handle)
                (funcall (harness-http-handle-on-headers handle)
                         (car parsed) (cdr parsed))))))
        (setf (harness-http-handle-header-buffer handle) buf)
        (when (and done (not (string-empty-p buf)))
          (setf (harness-http-handle-header-buffer handle) "")
          (harness-http--body handle buf))))))

(defun harness-http--body (handle data)
  "Hand body DATA of HANDLE to its chunk function, or add it to its body.
An error in the chunk function is logged, not signalled.  Data handed
to the caller's chunk function is remembered: a retry must never hand
the same content over twice, and a request that already streamed some
is not retried at all."
  (when (and (harness-http-handle-on-chunk handle) (not (string-empty-p data)))
    (setf (harness-http-handle-chunk-delivered handle) t))
  (if (harness-http-handle-on-chunk handle)
      (condition-case err
          (funcall (harness-http-handle-on-chunk handle) data)
        (error (harness-log 'error "http on-chunk failed: %S" err)))
    (setf (harness-http-handle-body handle)
          (concat (harness-http-handle-body handle) data))))

(defun harness-http--finish (handle err)
  "Complete HANDLE, calling its callback once with ERR or the response."
  (unless (harness-http-handle-done handle)
    (setf (harness-http-handle-done handle) t)
    (setq harness-http--active (delq handle harness-http--active))
    (when-let* ((timer (harness-http-handle-timer handle))) (cancel-timer timer))
    (when-let* ((timer (harness-http-handle-retry-timer handle)))
      (cancel-timer timer)
      (setf (harness-http-handle-retry-timer handle) nil))
    (when-let* ((f (harness-http-handle-config-file handle)))
      (ignore-errors (delete-file f)))
    (when-let* ((f (harness-http-handle-body-file handle)))
      (ignore-errors (delete-file f)))
    (let ((cb (harness-http-handle-callback handle)))
      (when cb
        (condition-case cerr
            (funcall cb (harness-http-handle-status handle)
                     (harness-http-handle-headers handle)
                     (harness-http-handle-body handle)
                     err)
          (error (harness-log 'error "http callback failed: %S" cerr)))))))

(defun harness-http--sentinel (handle process event)
  "Finish HANDLE once PROCESS, its curl, has exited; EVENT says how.
The request fails when it was cancelled, when curl exited 0 before any
response headers came, and when curl failed: its error then gives the
exit status, what it means, EVENT and what curl printed on stderr.  A
transient failure of which nothing reached the caller, and a retryable
response that was not streamed, are tried again instead (see
`harness-http--retry-delay')."
  (unless (process-live-p process)
    (let* ((code (process-exit-status process))
           (stderr-buf (process-get process 'harness-stderr))
           (stderr (and stderr-buf (buffer-live-p stderr-buf)
                        (with-current-buffer stderr-buf (buffer-string)))))
      (when (and stderr-buf (buffer-live-p stderr-buf)) (kill-buffer stderr-buf))
      (let* ((status (harness-http-handle-status handle))
             (err (cond ((harness-http-handle-cancelled handle) '(cancelled "request cancelled"))
                        ((and (zerop code) (harness-http-handle-headers-done handle)) nil)
                        ((zerop code) (list 'protocol "no response headers received"))
                        (t (harness-http--curl-failure code stderr event))))
             (delay (harness-http--retry-delay handle status err)))
        (if (and delay (harness-http--retry handle delay
                                            (or (and err (cadr err))
                                                (format "HTTP %s" status))))
            nil
          (harness-http--finish handle err))))))

(defun harness-http--unibyte (data)
  "Return process output DATA as a unibyte string of the bytes received."
  (if (multibyte-string-p data) (encode-coding-string data 'binary t) data))

(defun harness-http--write-config (url method headers)
  "Write a curl config file for URL, METHOD and HEADERS; return its path.
Every line is written without text properties: a propertized URL (a
link off a selection) would be printed as #(\"https://...\" 0 84
\(foreign-selection STRING)) and read as a fragment by curl."
  (let ((file (make-temp-file "harness-http-" nil ".curlrc")))
    (with-temp-file file
      (set-file-modes file #o600)
      (insert (format "url = %S\n" (substring-no-properties url)))
      (insert (format "request = %S\n" (substring-no-properties method)))
      (dolist (h headers)
        (insert (format "header = %S\n"
                        (substring-no-properties (format "%s: %s" (car h) (cdr h)))))))
    file))

(defun harness-http--write-body (body binary)
  "Write BODY to a mode 600 temp file; return its path.
BODY is written as raw bytes when BINARY is non-nil, else as UTF-8.
A request body never goes through `process-send-string': a body big
enough to fill the pipe can be left half-written in Emacs's process
write queue, which only another send would drain, and curl then waits
forever for the rest of its stdin.  A file has neither problem."
  (let ((file (make-temp-file "harness-http-" nil ".body"))
        (coding-system-for-write (if binary 'binary 'utf-8-unix)))
    (set-file-modes file #o600)
    (write-region body nil file nil 'silent)
    file))

(defun harness-http--timed-out (handle)
  "Fail HANDLE because the request outlived its timeout.
`--max-time' cannot stop a curl that is still waiting for its stdin, so
the request is stopped here, where the timer does run."
  (unless (harness-http-handle-done handle)
    (let ((process (harness-http-handle-process handle)))
      (when (process-live-p process) (delete-process process)))
    (harness-http--finish handle
                          (list 'timeout
                                (format "request timed out after %ss"
                                        (harness-http-handle-timeout handle))))))

(defun harness-http--attempt (handle)
  "Start curl for HANDLE, whose config, body and options are written.
Called for a first attempt and for every retry, so it forgets what the
previous attempt left: the response, its headers, and the watchdog,
which counts from this attempt on."
  (when-let* ((timer (harness-http-handle-timer handle)))
    (cancel-timer timer)
    (setf (harness-http-handle-timer handle) nil))
  (setf (harness-http-handle-status handle) nil
        (harness-http-handle-headers handle) nil
        (harness-http-handle-header-buffer handle) ""
        (harness-http-handle-headers-done handle) nil
        (harness-http-handle-body handle) ""
        (harness-http-handle-chunk-delivered handle) nil)
  (let* ((binary (harness-http-handle-binary handle))
         (seconds (harness-http-handle-timeout handle))
         (stderr (generate-new-buffer " *harness-http-stderr*" t))
         (process (make-process
                   :name "harness-http"
                   :command (cons harness-http--curl-program (harness-http-handle-args handle))
                   :coding (if binary 'binary '(utf-8 . utf-8))
                   :connection-type 'pipe
                   :noquery t
                   :stderr stderr
                   :filter (if binary
                               (lambda (_p data)
                                 (harness-http--filter handle (harness-http--unibyte data)))
                             (lambda (_p data) (harness-http--filter handle data)))
                   :sentinel (lambda (p e) (harness-http--sentinel handle p e)))))
    (process-put process 'harness-stderr stderr)
    (set-process-query-on-exit-flag (get-buffer-process stderr) nil)
    (set-process-sentinel (get-buffer-process stderr) #'ignore)
    (setf (harness-http-handle-process handle) process)
    (cl-pushnew handle harness-http--active :test #'eq)
    ;; Curl's own `--max-time' only counts the transfer; this watchdog is
    ;; what ends a request whose curl is stuck before it ever connects.
    (setf (harness-http-handle-timer handle)
          (run-at-time (+ seconds 5) nil (lambda () (harness-http--timed-out handle))))
    handle))

(cl-defun harness-http-request (url &key (method "GET") headers body json binary
                                    callback on-chunk on-headers timeout retry)
  "Start an asynchronous HTTP request to URL.
METHOD, HEADERS (alist) and BODY (string) describe it; JSON, when
given, is encoded with `harness-json-encode' and sent as the body
with the right content type.  CALLBACK is called once with (STATUS
HEADERS BODY ERROR); when ON-CHUNK is given the body is streamed to it
instead of accumulated.  ON-HEADERS is called with (STATUS HEADERS) as
soon as they arrive.  BINARY non-nil exchanges raw bytes: a multibyte
BODY is sent encoded as UTF-8, and the response body reaches ON-CHUNK
and CALLBACK as unibyte strings, undecoded.  Return a handle usable
with `harness-http-cancel'.

A request that fails transiently -- a connection reset, an empty reply,
a refused host, a timeout before the response began, a TLS or DNS
failure -- is tried again, `harness-http-max-retries' times by default,
waiting longer before each try, and so is a retryable response (408,
429, 500, 502, 503, 504) whose body was not streamed.  RETRY says how
many times the request may be tried again: nil (the default) retries an
idempotent request, a GET or a HEAD, and no other; t retries any method
as often as the default; a number is that many tries and 0 none.  A
request of which some body already reached ON-CHUNK, one that was
cancelled, and one whose own timeout fired are never retried: the
caller has seen what a retry would repeat."
  (unless harness-http--curl-program
    (error "The curl program harness-http needs is not available"))
  (when json
    (setq body (harness-json-encode json))
    (unless (assoc "Content-Type" headers)
      (push (cons "Content-Type" "application/json") headers)))
  (when (and binary body (multibyte-string-p body))
    (setq body (encode-coding-string body 'utf-8 t)))
  (when body
    (push (cons "Content-Length" (number-to-string (string-bytes body))) headers))
  (let* ((seconds (or timeout harness-http--default-timeout))
         (config (harness-http--write-config url method headers))
         (body-file (and body (harness-http--write-body body binary)))
         (args (append (list "--silent" "--show-error" "--no-buffer" "--include"
                             "--max-time" (number-to-string seconds)
                             "--config" config)
                       (when body-file (list "--data-binary" (concat "@" body-file)))))
         (handle (make-harness-http-handle :url url :callback callback
                                           :on-chunk on-chunk :on-headers on-headers
                                           :config-file config :body-file body-file
                                           :binary binary :args args
                                           :retry (harness-http--retries method retry)
                                           :timeout seconds :started (float-time))))
    (harness-http--attempt handle)))

(defun harness-http-cancel (handle)
  "Abort the request HANDLE, and any retry it is waiting to make."
  (when (and handle (not (harness-http-handle-done handle)))
    (setf (harness-http-handle-cancelled handle) t)
    (when-let* ((timer (harness-http-handle-retry-timer handle)))
      (cancel-timer timer)
      (setf (harness-http-handle-retry-timer handle) nil))
    (let ((p (harness-http-handle-process handle)))
      (when (process-live-p p) (delete-process p)))
    (harness-http--finish handle '(cancelled "request cancelled"))))

(defun harness-http-request-json (url &rest args)
  "Like `harness-http-request' but resolve a promise with the parsed JSON body.
URL and ARGS are passed through; a callback must not be supplied.  Rejects
with (STATUS BODY-OR-ERROR) on HTTP or transport errors."
  (harness-with-promise (resolve reject)
    (apply #'harness-http-request url
           :callback (lambda (status _headers body err)
                       (cond (err (funcall reject (list 'http-error status err)))
                             ((and status (>= status 200) (< status 300))
                              (condition-case perr
                                  (funcall resolve (harness-json-parse body))
                                (error (funcall reject (list 'json-error status (format "%S" perr))))))
                             (t (funcall reject (list 'http-error status body)))))
           args)))

;;;; Server-sent events

(defun harness-http-sse-parser (on-event)
  "Return a chunk function that parses server-sent events.
ON-EVENT is called with (EVENT-NAME DATA-STRING) for every complete
event.  Multi-line data fields are joined with newlines per the spec."
  (let ((buffer ""))
    (lambda (chunk)
      (setq buffer (concat buffer chunk))
      (let (pos)
        (while (setq pos (string-match "\r?\n\r?\n" buffer))
          (let ((block (substring buffer 0 pos))
                (event nil) (data nil))
            (setq buffer (substring buffer (match-end 0)))
            (dolist (line (split-string block "\r?\n"))
              (cond ((string-prefix-p ":" line))
                    ((string-match "^event:[ ]?\\(.*\\)$" line) (setq event (match-string 1 line)))
                    ((string-match "^data:[ ]?\\(.*\\)$" line) (push (match-string 1 line) data))))
            (when data
              (condition-case err
                  (funcall on-event event (string-join (nreverse data) "\n"))
                (error (harness-log 'error "sse handler failed: %S" err))))))))))

(defun harness-http-active-count ()
  "Number of in-flight requests."
  (length harness-http--active))

;;;; Downloads into a file

(defcustom harness-http-download-user-agent "Mozilla/5.0 (X11; Linux x86_64) emacs-agent-harness"
  "User agent `harness-http-download' sends; some hosts refuse curl's own."
  :type 'string :group 'harness)

(defun harness-http-clean-url (url)
  "Return URL without the junk a drop or a clipboard can carry.
Control characters, NULs, byte order marks and the invisible spaces
\(no-break space, soft hyphen, zero width and bidi marks, ideographic
space) make curl read an address differently from how it prints -- a
link that looks whole can come back as \"URL rejected: No host
present\" -- and browsers strip tabs and newlines from URLs
themselves.  A leading byte order mark, in bytes or as a character,
goes too, as does surrounding whitespace."
  (let ((clean (or url "")))
    (when (string-prefix-p "\357\273\277" clean)      ; a UTF-8 BOM, unibyte
      (setq clean (substring clean 3)))
    ;; The same invisible characters as they are spelled in UTF-8 bytes,
    ;; for a unibyte string straight off a selection.
    (setq clean (replace-regexp-in-string
                 "\\(?:\302\240\\|\302\255\\|\342\200[\213-\217\250-\257]\\|\343\200\200\\|\357\273\277\\)+"
                 "" clean))
    (setq clean (replace-regexp-in-string "[\0-\37\177]+" "" clean))
    (when (multibyte-string-p clean)
      (setq clean
            (replace-regexp-in-string
             "[\ufeff\u00a0\u00ad\u1680\u2000-\u200f\u2028-\u202f\u205f\u2060-\u206f\u3000]+" "" clean)))
    ;; Text properties go too: a link off a selection carries
    ;; `foreign-selection', and `%S' (the curl config, say) would print it
    ;; as #("https://..." 0 84 (foreign-selection STRING)), which curl
    ;; reads as nothing but a fragment.
    (substring-no-properties (string-trim clean))))

(defun harness-http--host-ok-p (url)
  "Non-nil when the host of URL is made of characters a host may hold.
This is what tells a link that only looks whole (invisible junk in the
authority, say) from one that can be fetched."
  (when (string-match "\\`[a-zA-Z][a-zA-Z0-9+.-]*://\\([^/?#]*\\)" url)
    (let* ((authority (match-string 1 url))
           (host (if (string-match "@" authority)
                     (substring authority (1+ (match-beginning 0)))
                   authority))
           (host (if (string-prefix-p "[" host)
                     (if (string-match "\\`\\[[0-9a-fA-F:.]*\\]" host) (match-string 0 host) host)
                   (car (split-string host ":")))))
      (and (not (string-empty-p host))
           (string-match-p "\\`\\(?:\\[[0-9a-fA-F:.]*\\]\\|[A-Za-z0-9._~-]+\\)\\'" host)))))

(defun harness-http-link-p (url)
  "Non-nil when URL is a link the harness can fetch: a scheme and a sane host."
  (and (stringp url)
       (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" url)
       (harness-http--host-ok-p url)))

(defvar harness-http-download-progress-interval 0.25
  "Seconds between the progress reports of a download.")

(cl-defstruct (harness-download (:constructor harness-http--make-download) (:copier nil))
  "A download started by `harness-http-download'.
STATUS, HEADERS, MIME, TOTAL (the Content-Length) and NAME (the file
name the server gave) describe the final response once it arrived;
URL-EFFECTIVE is the address after redirects, once done."
  url file process config-file
  (stdout "") (parsed 0)
  status headers mime total name url-effective
  done cancelled timer
  callback on-headers on-progress max-size
  timeout retry (retries 0) retry-timer headers-reported)

(defun harness-http-unhex-bytes (string)
  "Return the bytes STRING spells with its %XX escapes decoded."
  (replace-regexp-in-string "%[[:xdigit:]]\\{2\\}"
                            (lambda (m) (unibyte-string (string-to-number (substring m 1) 16)))
                            (encode-coding-string string 'utf-8) t t))

(defun harness-http--unhex (string &optional coding)
  "Decode the %XX escapes of STRING, as CODING (default UTF-8)."
  (decode-coding-string (harness-http-unhex-bytes string) (or coding 'utf-8)))

(defun harness-http--disposition-filename (value)
  "Return the file name a Content-Disposition header VALUE gives, or nil."
  (let ((case-fold-search t))
    (cond ((null value) nil)
          ((string-match "filename\\*[ \t]*=[ \t]*\\([^';]*\\)'[^']*'\\([^;]+\\)" value)
           (let ((charset (downcase (match-string 1 value)))
                 (name (string-trim (match-string 2 value))))
             (harness-http--unhex name (or (and (not (string-empty-p charset))
                                                (ignore-errors (check-coding-system (intern charset))))
                                           'utf-8))))
          ((string-match "filename[ \t]*=[ \t]*\"\\(\\(?:[^\"\\]\\|\\\\.\\)*\\)\"" value)
           (replace-regexp-in-string "\\\\\\(.\\)" "\\1" (match-string 1 value) t))
          ((string-match "filename[ \t]*=[ \t]*\\([^; \t]+\\)" value)
           (match-string 1 value)))))

(defun harness-http-url-file-name (url)
  "Return the file name at the end of URL's path, decoded, or nil."
  (when (string-match "\\`[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*\\(/[^?#]*\\)?" url)
    (let* ((path (or (match-string 1 url) ""))
           (name (harness-http--unhex (file-name-nondirectory path))))
      (and (not (string-blank-p name)) name))))

(defun harness-http-download-received (download)
  "Return the bytes DOWNLOAD has written to its file so far."
  (or (harness-file-size (harness-download-file download)) 0))

(defun harness-http--download-parse (dl)
  "Take the complete response header blocks off DL's output.
The final response, the first that is neither informational nor a
redirect, sets DL's status, headers, MIME type, size and name and
is reported to its ON-HEADERS."
  (let ((out (harness-download-stdout dl)) (done nil))
    (while (and (not done) (not (harness-download-done dl))
                (eq t (compare-strings "HTTP/" nil nil out (harness-download-parsed dl)
                                       (min (length out) (+ 5 (harness-download-parsed dl))))))
      (let ((end (string-search "\r\n\r\n" out (harness-download-parsed dl))))
        (if (not end)
            (setq done t)
          (let* ((parsed (harness-http--parse-headers
                          (decode-coding-string (substring out (harness-download-parsed dl) end) 'utf-8)))
                 (status (car parsed))
                 (headers (cdr parsed)))
            (setf (harness-download-parsed dl) (+ end 4))
            (cond ((null status))
                  ((or (< status 200) (and (>= status 300) (< status 400))))
                  ((>= status 400) (setf (harness-download-status dl) status))
                  (t
                   (let ((type (cdr (assoc "content-type" headers)))
                         (length (cdr (assoc "content-length" headers))))
                     (setf (harness-download-status dl) status
                           (harness-download-headers dl) headers
                           (harness-download-mime dl)
                           (and type (downcase (string-trim (car (split-string type ";")))))
                           (harness-download-total dl)
                           (and length (string-match-p "\\`[ \t]*[0-9]+[ \t]*\\'" length)
                                (string-to-number length))
                           (harness-download-name dl)
                           (harness-http--disposition-filename (cdr (assoc "content-disposition" headers)))))
                   (when (and (harness-download-on-headers dl)
                              (not (harness-download-headers-reported dl)))
                     (setf (harness-download-headers-reported dl) t)
                     (condition-case err
                         (funcall (harness-download-on-headers dl) dl)
                       (error (harness-log 'error "download on-headers failed: %S" err))))))))))))

(defun harness-http--download-summary (dl)
  "Return the JSON curl wrote after DL's headers, as a plist, or nil."
  (let ((rest (substring (harness-download-stdout dl) (min (harness-download-parsed dl)
                                                           (length (harness-download-stdout dl))))))
    (when (string-match "^{.*}[ \t\r\n]*\\'" rest)
      (ignore-errors (harness-json-parse (decode-coding-string (match-string 0 rest) 'utf-8))))))

(defun harness-http--download-error (dl code summary stderr)
  "Describe why DL failed with curl exit CODE, its SUMMARY and STDERR."
  (let ((http (plist-get summary :http_code)))
    (pcase code
      (22 (format "the server answered HTTP %s" (or (harness-download-status dl)
                                                     (and (numberp http) (> http 0) http) "error")))
      (63 (format "it is larger than %s" (harness-format-bytes (harness-download-max-size dl))))
      (_ (let ((msg (or (plist-get summary :errormsg)
                        (and (not (string-blank-p stderr))
                             (string-trim (replace-regexp-in-string "\\`curl: ([0-9]+) " "" (string-trim stderr))))
                        (format "curl exited %s" code))))
           msg)))))

(defun harness-http--download-finish (dl error)
  "Settle DL with ERROR, a string, or nil when it succeeded; once."
  (unless (harness-download-done dl)
    (setf (harness-download-done dl) t)
    (when (harness-download-timer dl) (cancel-timer (harness-download-timer dl)))
    (when-let* ((timer (harness-download-retry-timer dl)))
      (cancel-timer timer)
      (setf (harness-download-retry-timer dl) nil))
    (when-let* ((f (harness-download-config-file dl))) (ignore-errors (delete-file f)))
    (when error (ignore-errors (delete-file (harness-download-file dl))))
    (when (harness-download-callback dl)
      (condition-case err
          (funcall (harness-download-callback dl) dl error)
        (error (harness-log 'error "download callback failed: %S" err))))))

(defun harness-http--download-restart (dl)
  "Start DL again, unless it was settled or cancelled meanwhile."
  (setf (harness-download-retry-timer dl) nil)
  (unless (or (harness-download-done dl) (harness-download-cancelled dl))
    (condition-case err
        (harness-http--download-start dl)
      (error (harness-http--download-finish
              dl (format "trying the download again failed: %s" (error-message-string err)))))))

(defun harness-http--download-retry (dl code)
  "Try DL again after its curl exited CODE, when that can help; nil else.
Only a transient connection failure is retried, the partial file is
deleted first (curl writes it from the start, and half a file is not a
download), and the attempt count is bounded by the download's `:retry'
so nothing loops for ever."
  (when (and (not (harness-download-done dl))
             (not (harness-download-cancelled dl))
             (memq code harness-http--transient-curl-exits)
             (< (harness-download-retries dl) (harness-download-retry dl)))
    (let ((delay (harness-http--backoff (cl-incf (harness-download-retries dl)))))
      (ignore-errors (delete-file (harness-download-file dl)))
      (harness-log 'info "download: %s failed (curl %d); trying again in %.1fs (%d of %d)"
                   (harness-download-url dl) code delay
                   (harness-download-retries dl) (harness-download-retry dl))
      (setf (harness-download-retry-timer dl)
            (run-at-time delay nil (lambda () (harness-http--download-restart dl))))
      t)))

(defun harness-http--download-sentinel (dl process stderr-buf)
  "Settle DL once curl's PROCESS has exited; STDERR-BUF holds what it said.
A transient failure is tried again when the attempts allow it (see
`harness-http--download-retry'); a signal here (a callback that fails,
say) settles the download with an error rather than leaving it running
for good."
  (unless (process-live-p process)
    (condition-case err
        (let ((stderr (if (buffer-live-p stderr-buf) (with-current-buffer stderr-buf (buffer-string)) "")))
          (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf))
          (unless (harness-download-done dl)
            (harness-http--download-parse dl))
          (let* ((summary (harness-http--download-summary dl))
                 (code (process-exit-status process)))
            (when summary
              (setf (harness-download-url-effective dl) (plist-get summary :url_effective))
              (unless (harness-download-mime dl)
                (when-let* ((type (plist-get summary :content_type)))
                  (setf (harness-download-mime dl) (downcase (string-trim (car (split-string type ";"))))))))
            (if (harness-http--download-retry dl code)
                nil
              (harness-http--download-finish
               dl (cond ((harness-download-cancelled dl) "cancelled")
                        ((and (eq (process-status process) 'exit) (zerop code)) nil)
                        (t (harness-http--download-error dl code summary stderr)))))))
      (error (harness-log 'error "download sentinel failed: %S" err)
             (harness-http--download-finish
              dl (format "download failed: %s" (error-message-string err)))))))

(defun harness-http--download-start (dl)
  "Start curl for DL, forgetting what an attempt before left.
Called for the first attempt and for every retry: the response state
is reset, the partial file the retry deleted is written from the start,
and ON-HEADERS, already told the response it was asked about, is not
called again."
  (when-let* ((timer (harness-download-retry-timer dl)))
    (cancel-timer timer)
    (setf (harness-download-retry-timer dl) nil))
  (setf (harness-download-stdout dl) ""
        (harness-download-parsed dl) 0
        (harness-download-status dl) nil
        (harness-download-headers dl) nil
        (harness-download-mime dl) nil
        (harness-download-total dl) nil
        (harness-download-name dl) nil)
  (let* ((stderr (generate-new-buffer " *harness-download-stderr*" t))
         (process
          (make-process
           :name "harness-download"
           :command (append (list harness-http--curl-program
                                  "--silent" "--show-error" "--location" "--fail" "--max-redirs" "10"
                                  "--proto" "=http,https,ftp,ftps" "--proto-redir" "=http,https,ftp,ftps"
                                  "--connect-timeout" "30" "--speed-limit" "1" "--speed-time" "60"
                                  "--max-time" (number-to-string (harness-download-timeout dl))
                                  "--dump-header" "-" "--output" (harness-download-file dl)
                                  "--write-out" "\n%{json}\n"
                                  "--config" (harness-download-config-file dl))
                            (and (harness-download-max-size dl)
                                 (list "--max-filesize" (number-to-string (harness-download-max-size dl)))))
           :coding 'binary :connection-type 'pipe :noquery t :stderr stderr
           :filter (lambda (_p data)
                     (unless (harness-download-done dl)
                       (setf (harness-download-stdout dl) (concat (harness-download-stdout dl) data))
                       (harness-http--download-parse dl)))
           :sentinel (lambda (p _e) (harness-http--download-sentinel dl p stderr)))))
    (when-let* ((ep (get-buffer-process stderr)))
      (set-process-query-on-exit-flag ep nil)
      (set-process-sentinel ep #'ignore))
    (setf (harness-download-process dl) process)
    dl))

(cl-defun harness-http-download (url file &key callback on-headers on-progress max-size timeout headers retry)
  "Download URL into FILE asynchronously with curl; return the download.
Only http, https, ftp and ftps are fetched, redirects included.
ON-HEADERS is called with the download once the final response's
headers arrived (see `harness-download'; a proxy's answer to CONNECT
may come first), and may cancel it; ON-PROGRESS every
`harness-http-download-progress-interval' seconds with the download,
the bytes received and the expected total (nil when the server did not
say).  CALLBACK is called once, with the download and nil when FILE
holds the body, or with a message saying what went wrong (\"cancelled\"
after `harness-http-download-cancel'); FILE is deleted then.  MAX-SIZE
caps the body in bytes, TIMEOUT the whole transfer in seconds (default
one hour; a transfer stalled for a minute fails anyway).  HEADERS is an
alist of extra request headers.

A download cut by a transient failure (a reset, a broken connection, a
timeout) is started over, the partial file deleted first, at most
`harness-http-max-retries' times by default: RETRY says how many tries
are allowed, 0 none."
  (unless harness-http--curl-program
    (error "The curl program harness-http needs is not available"))
  (setq url (harness-http-clean-url url))
  (unless (harness-http-link-p url)
    (error "Not a link with a host for harness-http to fetch: %S" url))
  (harness-ensure-directory (file-name-directory (expand-file-name file)))
  (let* ((config (make-temp-file "harness-download-" nil ".curlrc"))
         (dl (harness-http--make-download :url url :file (expand-file-name file) :config-file config
                                          :callback callback :on-headers on-headers
                                          :on-progress on-progress :max-size max-size
                                          :timeout (or timeout 3600)
                                          :retry (cond ((eq retry t) harness-http-max-retries)
                                                       ((integerp retry) (max 0 retry))
                                                       (t harness-http-max-retries)))))
    (with-temp-file config
      (set-file-modes config #o600)
      (insert (format "url = %S\n" url)
              (format "user-agent = %S\n" harness-http-download-user-agent))
      (dolist (h headers)
        (insert (format "header = %S\n" (format "%s: %s" (car h) (cdr h))))))
    (harness-http--download-start dl)
    (when on-progress
      (setf (harness-download-timer dl)
            (run-at-time harness-http-download-progress-interval harness-http-download-progress-interval
                         (lambda ()
                           (if (harness-download-done dl)
                               (when (harness-download-timer dl) (cancel-timer (harness-download-timer dl)))
                             (condition-case err
                                 (funcall on-progress dl (harness-http-download-received dl)
                                          (harness-download-total dl))
                               (error (harness-log 'error "download progress failed: %S" err))))))))
    dl))

(defun harness-http-download-cancel (download)
  "Abort DOWNLOAD: its callback is told \"cancelled\" and its file deleted.
The download is settled before the process is killed, so neither the
kill nor a sentinel that runs with it can leave it half-settled."
  (when (and download (not (harness-download-done download)))
    (setf (harness-download-cancelled download) t)
    (harness-http--download-finish download "cancelled")
    (let ((p (harness-download-process download)))
      (when (process-live-p p) (ignore-errors (delete-process p))))))

(provide 'harness-http)
;;; harness-http.el ends here
