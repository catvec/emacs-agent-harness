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

(defcustom harness-http-curl-program (executable-find "curl")
  "Path to curl.  When nil requests fail with an explanatory error."
  :type '(choice file (const nil)) :group 'harness)

(defcustom harness-http-default-timeout 600
  "Default maximum seconds a request may take, including streaming."
  :type 'integer :group 'harness)

(cl-defstruct (harness-http-handle (:copier nil))
  process url config-file
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
    (when-let* ((f (harness-http-handle-config-file handle)))
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
  (unless harness-http-curl-program
    (error "harness-http: curl is not available"))
  (when json
    (setq body (harness-json-encode json))
    (unless (assoc "Content-Type" headers)
      (push (cons "Content-Type" "application/json") headers)))
  (when (and binary body (multibyte-string-p body))
    (setq body (encode-coding-string body 'utf-8 t)))
  (when body
    (push (cons "Content-Length" (number-to-string (string-bytes body))) headers))
  (let* ((config (harness-http--write-config url method headers))
         (handle (make-harness-http-handle :url url :callback callback
                                           :on-chunk on-chunk :on-headers on-headers
                                           :config-file config :started (float-time)))
         (stderr (generate-new-buffer " *harness-http-stderr*" t))
         (args (append (list "--silent" "--show-error" "--no-buffer" "--include"
                             "--max-time" (number-to-string (or timeout harness-http-default-timeout))
                             "--config" config)
                       (when body (list "--data-binary" "@-"))))
         (process (make-process :name "harness-http"
                                :command (cons harness-http-curl-program args)
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
    (when body
      (process-send-string process body))
    (when (process-live-p process)
      (process-send-eof process))
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

;;;; Downloads into a file

(defcustom harness-http-download-user-agent "Mozilla/5.0 (X11; Linux x86_64) emacs-agent-harness"
  "User agent `harness-http-download' sends; some hosts refuse curl's own."
  :type 'string :group 'harness)

(defun harness-http-clean-url (url)
  "Return URL without the junk a drop or a clipboard can carry.
Control characters, NULs, byte order marks and the invisible spaces
(no-break space, soft hyphen, zero width and bidi marks, ideographic
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
  callback on-headers on-progress max-size)

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
                   (when (harness-download-on-headers dl)
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
    (when-let* ((f (harness-download-config-file dl))) (ignore-errors (delete-file f)))
    (when error (ignore-errors (delete-file (harness-download-file dl))))
    (when (harness-download-callback dl)
      (condition-case err
          (funcall (harness-download-callback dl) dl error)
        (error (harness-log 'error "download callback failed: %S" err))))))

(defun harness-http--download-sentinel (dl process stderr-buf)
  "Settle DL once curl's PROCESS has exited; STDERR-BUF holds what it said.
A signal here (a callback that fails, say) settles the download with an
error rather than leaving it running for good."
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
            (harness-http--download-finish
             dl (cond ((harness-download-cancelled dl) "cancelled")
                      ((and (eq (process-status process) 'exit) (zerop code)) nil)
                      (t (harness-http--download-error dl code summary stderr))))))
      (error (harness-log 'error "download sentinel failed: %S" err)
             (harness-http--download-finish
              dl (format "download failed: %s" (error-message-string err)))))))

(cl-defun harness-http-download (url file &key callback on-headers on-progress max-size timeout headers)
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
alist of extra request headers."
  (unless harness-http-curl-program
    (error "harness-http: curl is not available"))
  (setq url (harness-http-clean-url url))
  (unless (harness-http-link-p url)
    (error "harness-http: not a link with a host to fetch: %S" url))
  (harness-ensure-directory (file-name-directory (expand-file-name file)))
  (let* ((config (make-temp-file "harness-download-" nil ".curlrc"))
         (dl (harness-http--make-download :url url :file (expand-file-name file) :config-file config
                                          :callback callback :on-headers on-headers
                                          :on-progress on-progress :max-size max-size))
         (stderr (generate-new-buffer " *harness-download-stderr*" t)))
    (with-temp-file config
      (set-file-modes config #o600)
      (insert (format "url = %S\n" url)
              (format "user-agent = %S\n" harness-http-download-user-agent))
      (dolist (h headers)
        (insert (format "header = %S\n" (format "%s: %s" (car h) (cdr h))))))
    (let ((process
           (make-process
            :name "harness-download"
            :command (append (list harness-http-curl-program
                                   "--silent" "--show-error" "--location" "--fail" "--max-redirs" "10"
                                   "--proto" "=http,https,ftp,ftps" "--proto-redir" "=http,https,ftp,ftps"
                                   "--connect-timeout" "30" "--speed-limit" "1" "--speed-time" "60"
                                   "--max-time" (number-to-string (or timeout 3600))
                                   "--dump-header" "-" "--output" (harness-download-file dl)
                                   "--write-out" "\n%{json}\n"
                                   "--config" config)
                             (and max-size (list "--max-filesize" (number-to-string max-size))))
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
      dl)))

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
