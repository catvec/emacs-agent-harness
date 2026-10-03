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

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-http--curl-program (executable-find "curl")
  "Path to curl.  When nil requests fail with an explanatory error.")

(defconst harness-http--default-timeout 600
  "Default maximum seconds a request may take, including streaming.")

(cl-defstruct (harness-http-handle (:copier nil))
  process url config-file body-file timeout timer
  (status nil) (headers nil) (header-buffer "")
  (headers-done nil) (body "")
  callback on-chunk on-headers
  (cancelled nil) (done nil) started)

(defvar harness-http--active nil "List of live handles.")

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
  (unless (process-live-p process)
    (let* ((code (process-exit-status process))
           (stderr-buf (process-get process 'harness-stderr))
           (stderr (and stderr-buf (buffer-live-p stderr-buf)
                        (with-current-buffer stderr-buf (buffer-string)))))
      (when (and stderr-buf (buffer-live-p stderr-buf)) (kill-buffer stderr-buf))
      (harness-http--finish
       handle
       (cond ((harness-http-handle-cancelled handle) '(cancelled "request cancelled"))
             ((and (zerop code) (harness-http-handle-headers-done handle)) nil)
             ((zerop code) (list 'protocol "no response headers received"))
             (t (list 'curl (format "curl exited %d (%s): %s" code (string-trim event)
                                    (string-trim (or stderr ""))))))))))

(defun harness-http--unibyte (data)
  "Return process output DATA as a unibyte string of the bytes received."
  (if (multibyte-string-p data) (encode-coding-string data 'binary t) data))

(defun harness-http--write-config (url method headers)
  "Write a curl config file for URL, METHOD and HEADERS; return its path."
  (let ((file (make-temp-file "harness-http-" nil ".curlrc")))
    (with-temp-file file
      (set-file-modes file #o600)
      (insert (format "url = %S\n" url))
      (insert (format "request = %S\n" method))
      (dolist (h headers)
        (insert (format "header = %S\n" (format "%s: %s" (car h) (cdr h))))))
    file))

(defun harness-http--write-body (body binary)
  "Write BODY to a mode 600 temp file; return its path.
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

(cl-defun harness-http-request (url &key (method "GET") headers body json binary
                                    callback on-chunk on-headers timeout)
  "Start an asynchronous HTTP request to URL.
METHOD, HEADERS (alist) and BODY (string) describe it; JSON, when
given, is encoded with `harness-json-encode' and sent as the body
with the right content type.  CALLBACK is called once with (STATUS
HEADERS BODY ERROR); when ON-CHUNK is given the body is streamed to it
instead of accumulated.  ON-HEADERS is called with (STATUS HEADERS) as
soon as they arrive.  BINARY non-nil exchanges raw bytes: a multibyte
BODY is sent encoded as UTF-8, and the response body reaches ON-CHUNK
and CALLBACK as unibyte strings, undecoded.  Return a handle usable
with `harness-http-cancel'."
  (unless harness-http--curl-program
    (error "harness-http: curl is not available"))
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
         (handle (make-harness-http-handle :url url :callback callback
                                           :on-chunk on-chunk :on-headers on-headers
                                           :config-file config :body-file body-file
                                           :timeout seconds :started (float-time)))
         (stderr (generate-new-buffer " *harness-http-stderr*" t))
         (args (append (list "--silent" "--show-error" "--no-buffer" "--include"
                             "--max-time" (number-to-string seconds)
                             "--config" config)
                       (when body-file (list "--data-binary" (concat "@" body-file)))))
         (process (make-process :name "harness-http"
                                :command (cons harness-http--curl-program args)
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
    (push handle harness-http--active)
    ;; Curl's own `--max-time' only counts the transfer; this watchdog is
    ;; what ends a request whose curl is stuck before it ever connects.
    (setf (harness-http-handle-timer handle)
          (run-at-time (+ seconds 5) nil (lambda () (harness-http--timed-out handle))))
    handle))

(defun harness-http-cancel (handle)
  "Abort the request HANDLE."
  (when (and handle (not (harness-http-handle-done handle)))
    (setf (harness-http-handle-cancelled handle) t)
    (let ((p (harness-http-handle-process handle)))
      (when (process-live-p p) (delete-process p)))
    (harness-http--finish handle '(cancelled "request cancelled"))))

(defun harness-http-request-json (url &rest args)
  "Like `harness-http-request' but resolve a promise with the parsed JSON body.
ARGS are passed through; a callback must not be supplied.  Rejects
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

(provide 'harness-http)
;;; harness-http.el ends here
