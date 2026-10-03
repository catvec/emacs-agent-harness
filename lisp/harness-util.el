;;; harness-util.el --- Small shared helpers for the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; JSON conventions used everywhere in the harness:
;;
;; - Parsed JSON objects are plists with keyword keys, arrays are
;;   lists, `null' is nil and `false' is `:false'.
;; - When encoding, a list whose first element is a keyword is an
;;   object, any other list is an array, `nil' is null, `t' is true,
;;   `:false' is false, `:empty' is an empty object, and vectors are
;;   arrays.  Use `harness-json-array' for an empty array.
;; - `harness-json-encode' returns bytes for a process, a file or an
;;   HTTP body: since Emacs 30 `json-serialize' gives unibyte UTF-8.
;;   JSON that goes inside other text (a prompt, a tool result) or
;;   inside other JSON as a string value comes from
;;   `harness-json-encode-text': the bytes would turn into raw-byte
;;   characters there, which the next `json-serialize' rejects.
;;
;; Everything else here is plumbing: ids, time, paths and formatting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

;;;; JSON

(defun harness--json-prepare (obj)
  "Convert OBJ from the harness plist convention into `json-serialize' input."
  (cond
   ((null obj) :null)
   ((eq obj t) t)
   ((eq obj :false) :false)
   ((eq obj :null) :null)
   ((eq obj :empty) (make-hash-table :test 'equal :size 1))
   ((stringp obj) obj)
   ((numberp obj) obj)
   ((symbolp obj) (symbol-name obj))
   ((hash-table-p obj)
    (let ((h (make-hash-table :test 'equal :size (hash-table-count obj))))
      (maphash (lambda (k v) (puthash (if (symbolp k) (string-remove-prefix ":" (symbol-name k)) k)
                                      (harness--json-prepare v) h))
               obj)
      h))
   ((vectorp obj) (apply #'vector (mapcar #'harness--json-prepare (append obj nil))))
   ((and (consp obj) (keywordp (car obj)))
    (let ((h (make-hash-table :test 'equal :size (/ (length obj) 2))))
      (cl-loop for (k v) on obj by #'cddr
               do (puthash (string-remove-prefix ":" (symbol-name k))
                           (harness--json-prepare v) h))
      h))
   ((consp obj)
    ;; Improper lists such as (2 . 30) become two-element arrays.
    (let (items)
      (while (consp obj) (push (harness--json-prepare (car obj)) items) (setq obj (cdr obj)))
      (when obj (push (harness--json-prepare obj) items))
      (apply #'vector (nreverse items))))
   (t (format "%s" obj))))

(defun harness-json-encode (obj)
  "Encode OBJ (plist/list convention, see Commentary) as a JSON string.
Since Emacs 30 the string is unibyte, the UTF-8 bytes, ready for a
process, a file or an HTTP body.  Use `harness-json-encode-text' for
JSON that goes inside other text or inside other JSON."
  (json-serialize (harness--json-prepare obj)))

(defun harness-json-encode-text (obj)
  "Encode OBJ like `harness-json-encode', as text rather than bytes.
The result is a multibyte string of characters, so it can be put into
other text with `format' or `concat', and into other JSON as a string
value.  The bytes `harness-json-encode' returns would turn into
raw-byte characters there (\"\\342\\234\\227\" for U+2717), which
`json-serialize' rejects."
  (let ((json (harness-json-encode obj)))
    (if (multibyte-string-p json) json (decode-coding-string json 'utf-8-unix))))

(defun harness-json-parse (string)
  "Parse JSON STRING into the plist convention.  Return nil on empty input."
  (unless (or (null string) (string-empty-p (string-trim string)))
    (json-parse-string string :object-type 'plist :array-type 'list
                       :null-object nil :false-object :false)))

(defun harness-json-parse-buffer ()
  "Parse the JSON value after point in the current buffer, advancing point."
  (json-parse-buffer :object-type 'plist :array-type 'list
                     :null-object nil :false-object :false))

(defun harness-json-array (list)
  "Return LIST as a vector so it encodes as a JSON array even when empty."
  (apply #'vector list))

(defun harness-json-true-p (value)
  "Non-nil when parsed JSON VALUE is truthy (not nil and not :false)."
  (and value (not (eq value :false))))

;;;; Plists

(defun harness-plist-get-in (plist path)
  "Get the value at PATH (a list of keywords) inside nested PLIST."
  (let ((v plist))
    (dolist (k path v)
      (setq v (and (listp v) (plist-get v k))))))

(defun harness-plist-merge (&rest plists)
  "Merge PLISTS left to right; later keys win.  Return a fresh plist."
  (let (out)
    (dolist (pl plists)
      (cl-loop for (k v) on pl by #'cddr
               do (setq out (plist-put out k v))))
    out))

(defun harness-plist-remove (plist &rest keys)
  "Return a copy of PLIST without KEYS."
  (let (out)
    (cl-loop for (k v) on plist by #'cddr
             unless (memq k keys) do (setq out (plist-put out k v)))
    out))

(defun harness-plist-keys (plist)
  "Return the keys of PLIST."
  (cl-loop for (k _) on plist by #'cddr collect k))

(defun harness-alist-to-plist (alist)
  "Convert ALIST with symbol or string keys into a keyword plist."
  (let (out)
    (dolist (cell alist out)
      (let ((k (car cell)))
        (setq out (plist-put out (if (keywordp k) k
                                   (intern (concat ":" (if (symbolp k) (symbol-name k) k))))
                             (cdr cell)))))))

;;;; Ids and time

(defun harness-uuid ()
  "Return a random version 4 UUID string."
  (let ((f (lambda (n) (random (expt 2 n)))))
    (format "%08x-%04x-4%03x-%04x-%012x"
            (funcall f 32) (funcall f 16) (funcall f 12)
            (logior #x8000 (funcall f 14)) (funcall f 48))))

(defun harness-short-id (&optional len)
  "Return a short random alphanumeric id of LEN characters (default 8)."
  (let ((chars "abcdefghijklmnopqrstuvwxyz0123456789") (out ""))
    (dotimes (_ (or len 8) out)
      (setq out (concat out (string (aref chars (random (length chars)))))))))

(defun harness-now ()
  "Return the current time as a float."
  (float-time))

(defun harness-iso-time (&optional time)
  "Format TIME (default now) as an ISO 8601 UTC string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))

(defun harness-relative-time (time)
  "Describe TIME (float seconds) relative to now, like \"3m ago\"."
  (let ((d (- (float-time) time)))
    (cond ((< d 5) "just now")
          ((< d 60) (format "%ds ago" (truncate d)))
          ((< d 3600) (format "%dm ago" (truncate (/ d 60))))
          ((< d 86400) (format "%dh ago" (truncate (/ d 3600))))
          ((< d (* 7 86400)) (format "%dd ago" (truncate (/ d 86400))))
          (t (format-time-string "%Y-%m-%d" time)))))

(defun harness-format-duration (seconds)
  "Format SECONDS as a compact duration."
  (cond ((< seconds 1) (format "%dms" (truncate (* seconds 1000))))
        ((< seconds 60) (format "%.1fs" seconds))
        ((< seconds 3600) (format "%dm%02ds" (truncate (/ seconds 60)) (truncate (mod seconds 60))))
        (t (format "%dh%02dm" (truncate (/ seconds 3600)) (truncate (/ (mod seconds 3600) 60))))))

;;;; Formatting

(defun harness-format-tokens (n)
  "Format token count N compactly: 950, 12.3k, 1.2M."
  (let ((n (or n 0)))
    (cond ((< n 1000) (format "%d" n))
          ((< n 100000) (format "%.1fk" (/ n 1000.0)))
          ((< n 1000000) (format "%dk" (round (/ n 1000.0))))
          (t (format "%.2fM" (/ n 1000000.0))))))

(defun harness-format-cost (usd)
  "Format USD amount compactly."
  (let ((usd (or usd 0)))
    (cond ((zerop usd) "$0")
          ((< usd 0.01) (format "$%.4f" usd))
          ((< usd 1) (format "$%.3f" usd))
          (t (format "$%.2f" usd)))))

;;;; Billing

(defun harness-billing-of (usage)
  "Return how USAGE was paid: `api', `subscription', `extra-usage' or nil.
USAGE is a usage record, a session's usage totals or a usage row; the
value may have travelled over the wire as a string.  nil means the
provider did not say, which reads as per-token billing."
  (let ((b (plist-get usage :billing)))
    (cond ((and b (symbolp b) (not (eq b :false))) b)
          ((and (stringp b) (not (string-empty-p b))) (intern b)))))

(defun harness-plan-name (plan)
  "Return the display name of subscription PLAN (\"max\" gives \"Max\"), or nil."
  (and (stringp plan) (not (string-empty-p plan))
       (capitalize (replace-regexp-in-string "_" " " plan))))

(defun harness-usage-list-cost (usage)
  "Return what USAGE costs at API list prices: its `:list-cost', else its `:cost'."
  (let ((list-cost (plist-get usage :list-cost)) (cost (plist-get usage :cost)))
    (float (cond ((numberp list-cost) list-cost) ((numberp cost) cost) (t 0)))))

(defun harness-usage-covered (usage)
  "Return the part of USAGE a subscription paid for, at API list prices."
  (max 0.0 (- (harness-usage-list-cost usage) (float (or (plist-get usage :cost) 0)))))

(defun harness-format-spend (usage)
  "Describe in words what USAGE cost, saying when a subscription paid.
Per-token billing reads \"$1.20\"; usage a plan paid for reads
\"$3.40 at API prices, covered by the Max plan\"."
  (let* ((cost (float (or (plist-get usage :cost) 0)))
         (covered (harness-usage-covered usage))
         (name (harness-plan-name (plist-get usage :plan)))
         (payer (if name (format "the %s plan" name) "the subscription")))
    (cond ((<= covered 0) (harness-format-cost cost))
          ((> cost 0) (format "%s billed, plus %s at API prices covered by %s"
                              (harness-format-cost cost) (harness-format-cost covered) payer))
          (t (format "%s at API prices, covered by %s" (harness-format-cost covered) payer)))))

(defun harness-format-bytes (n)
  "Format byte count N as a human readable size."
  (file-size-human-readable (or n 0) 'iec " "))

(defun harness-truncate-middle (string max)
  "Shorten STRING to at most MAX characters by eliding the middle."
  (if (<= (length string) max)
      string
    (let* ((ell "…")
           (keep (- max (length ell)))
           (head (ceiling keep 2))
           (tail (floor keep 2)))
      (concat (substring string 0 head) ell (substring string (- (length string) tail))))))

(defun harness-truncate-end (string max)
  "Shorten STRING to at most MAX characters, eliding the end."
  (if (<= (length string) max) string
    (concat (substring string 0 (max 0 (1- max))) "…")))

(defun harness-first-line (string &optional max)
  "Return the first non-blank line of STRING, truncated to MAX characters."
  (let* ((lines (split-string (or string "") "\n" t "[ \t]+"))
         (line (or (car lines) "")))
    (if max (harness-truncate-end line max) line)))

(defun harness-estimate-tokens (string)
  "Cheap token estimate for STRING (about four characters per token)."
  (ceiling (length (or string "")) 4))

;;;; Senders
;;
;; A user message the user did not write says who sent it: its node's
;; `:meta' holds `:from', a sender plist.  Kind `system' is the harness
;; itself, with `:source' naming the part of it that sent the message
;; ("tasks", "merge queue"); kind `session' is the agent of another
;; session, with its `:id' and its `:name' at the time.  No `:from'
;; means the user wrote the message.  The kind may have travelled as a
;; string (over the wire, or through a node log), so read it with
;; `harness-sender-kind'.

(defun harness-sender-system (source)
  "Return the sender of a message the harness sends on its own.
SOURCE names the part of the harness that sends it, in words people
read, such as \"tasks\" or \"merge queue\"."
  (list :kind 'system :source source))

(defun harness-sender-session (session)
  "Return the sender of a message the agent of SESSION (a plist) sends."
  (list :kind 'session :id (plist-get session :id) :name (plist-get session :name)))

(defun harness-sender-kind (from)
  "Return the kind of sender FROM, `system' or `session', or nil.
FROM is who sent a message (see `harness-node-sender'); nil, or a value
without a kind, means the user did."
  (let ((kind (and (consp from) (plist-get from :kind))))
    (cond ((and (stringp kind) (not (string-empty-p kind))) (intern kind))
          ((and kind (symbolp kind) (not (eq kind :false))) kind))))

(defun harness-node-sender (node)
  "Return who sent NODE, a user message, when it was not the user, or nil.
That is NODE's `:meta' `:from': (:kind system :source SOURCE) for the
harness itself, made by `harness-sender-system', or (:kind session :id
ID :name NAME) for another session's agent, made by
`harness-sender-session'."
  (let ((from (plist-get (plist-get node :meta) :from)))
    (and (harness-sender-kind from) from)))

(defun harness-sender-description (from)
  "Describe FROM, who sent a message, in a few words, as transcripts read.
The harness reads \"the harness (SOURCE)\", another session's agent
\"session ID \\\"NAME\\\"\", and nil, the user, \"the user\"."
  (pcase (harness-sender-kind from)
    ('system (let ((source (plist-get from :source)))
               (if (and (stringp source) (not (string-blank-p source)))
                   (format "the harness (%s)" source)
                 "the harness")))
    ('session (format "session %s%s" (or (plist-get from :id) "?")
                      (if (and (stringp (plist-get from :name)) (not (string-blank-p (plist-get from :name))))
                          (format " %S" (plist-get from :name))
                        "")))
    ('nil "the user")
    (kind (format "the %s" kind))))

;;;; Paths

(defun harness-path-normalize (path)
  "Return PATH expanded and with symlinks resolved when local."
  (let ((expanded (expand-file-name path)))
    (if (file-remote-p expanded)
        expanded
      (condition-case nil (file-truename expanded) (error expanded)))))

(defun harness-path-within-p (dir path)
  "Non-nil when PATH is DIR or lies inside it (after normalisation)."
  (let ((dir (file-name-as-directory (harness-path-normalize dir)))
        (path (harness-path-normalize path)))
    (or (string= (file-name-as-directory path) dir)
        (string-prefix-p dir path))))

(defun harness-relative-path (root path)
  "Return PATH relative to ROOT when inside it, else PATH abbreviated."
  (if (and root (harness-path-within-p root path))
      (let ((rel (file-relative-name (expand-file-name path) (expand-file-name root))))
        (if (string= rel ".") "" rel))
    (abbreviate-file-name path)))

(defun harness-file-size (path)
  "Return the size of PATH in bytes, or nil."
  (let ((attrs (file-attributes path)))
    (and attrs (file-attribute-size attrs))))

(defun harness-ensure-directory (dir)
  "Create DIR if needed and return it."
  (unless (file-directory-p dir) (make-directory dir t))
  dir)

(defun harness-write-file-atomically (path string)
  "Write STRING to PATH via a temporary file and rename."
  (harness-ensure-directory (file-name-directory path))
  (let ((tmp (concat path ".tmp" (harness-short-id 4)))
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file tmp (insert string))
    (rename-file tmp path t)))

(defun harness-read-file (path)
  "Return the contents of PATH as a string, or nil when unreadable."
  (when (file-readable-p path)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents path))
      (buffer-string))))

;;;; Strings

(defun harness-fuzzy-score (query candidate)
  "Score how well QUERY matches CANDIDATE as a subsequence, or nil.
Higher is better; consecutive and word-start matches score more."
  (let ((qi 0) (ci 0) (score 0) (prev -2)
        (ql (length query)) (cl (length candidate))
        (query (downcase query)) (cand (downcase candidate)))
    (while (and (< qi ql) (< ci cl))
      (when (eq (aref query qi) (aref cand ci))
        (cl-incf score (cond ((= ci (1+ prev)) 3)
                             ((or (= ci 0) (memq (aref cand (1- ci)) '(?/ ?- ?_ ?. ?\s))) 2)
                             (t 1)))
        (setq prev ci)
        (cl-incf qi))
      (cl-incf ci))
    (when (= qi ql)
      (- score (/ cl 100.0)))))

(defun harness-fuzzy-filter (query candidates &optional key limit)
  "Return CANDIDATES fuzzy-matching QUERY, best first.
KEY extracts the string to match; LIMIT caps the result count."
  (let ((scored nil))
    (dolist (c candidates)
      (let ((s (harness-fuzzy-score query (if key (funcall key c) c))))
        (when s (push (cons s c) scored))))
    (let ((sorted (mapcar #'cdr (sort scored (lambda (a b) (> (car a) (car b)))))))
      (if limit (seq-take sorted limit) sorted))))

(defun harness-string-blank-p (s)
  "Non-nil when S is nil or only whitespace."
  (or (null s) (string-blank-p s)))

(defun harness-safe-substring (string from &optional to)
  "Like `substring' but clamps FROM and TO into range."
  (let* ((len (length string))
         (from (max 0 (min from len)))
         (to (if to (max from (min to len)) len)))
    (substring string from to)))

;;;; Processes

(defvar harness--process-kill-grace 3
  "Seconds between TERM and KILL when a timed-out command is killed.
Internal, not an option (see docs/configuration-audit.md).  A command
runs in its own process group, so a timeout kills its children too: the
group gets TERM, then KILL when anything in it is still alive after
this many seconds.")

(defun harness--process-children (pid)
  "Return the direct children of PID, from the system process table.
Empty when the table cannot be read (no /proc, a sandbox, a remote
host), which leaves the group kill in `harness-process-tree' as the
only mechanism."
  (when (fboundp 'list-system-processes)
    (let (children)
      (dolist (candidate (ignore-errors (list-system-processes)))
        (let ((attrs (ignore-errors (process-attributes candidate))))
          (when (eql pid (alist-get 'ppid attrs))
            (push candidate children))))
      children)))

(defun harness-process-tree (pid group)
  "Return the process tree rooted at PID as a plist.
The plist is (:pid PID :group GROUP :children PIDS): the descendants are
collected now, before anything is signalled, because a killed parent
cannot be asked for them again and they are reparented as it dies.
Every command Emacs spawns gets its own process group, so a group kill
alone misses a grandchild that a child Emacs spawned with `call-process';
walking the process table catches it."
  (let (children queue)
    (setq queue (list pid))
    (while queue
      (dolist (child (harness--process-children (pop queue)))
        (push child children)
        (push child queue)))
    (list :pid pid :group group :children (nreverse children))))

(defun harness-kill-process-tree (tree &optional signal)
  "Send SIGNAL (TERM by default) to every process in TREE.
TREE is what `harness-process-tree' returned: the root and its group
(when local) and the descendants collected with it.  Best-effort: a
process that is already gone is not an error."
  (let ((sig (or signal 'term))
        (pid (plist-get tree :pid))
        (group (plist-get tree :group)))
    (when (and (integerp pid) (> pid 0))
      (dolist (child (plist-get tree :children))
        (ignore-errors (signal-process child sig)))
      (when group
        (ignore-errors (signal-process (- pid) sig)))
      (ignore-errors (signal-process pid sig)))))

(cl-defun harness-run-command (command &key cwd (timeout 120) stdin on-output name env)
  "Run COMMAND (a list of strings) asynchronously and return a promise.
The promise resolves to (:exit CODE :stdout STRING :stderr STRING).
CWD defaults to `default-directory'; a remote (TRAMP) CWD runs the
command on that host.  STDIN, when given, is sent to the process.  ENV,
an alist, is prepended to `process-environment' for the command.
ON-OUTPUT is called with every chunk of standard output as it arrives.
After TIMEOUT seconds the process is killed -- its whole process group
on a local CWD, so children cannot outlive it -- and :exit is
`timeout'."
  (harness-with-promise (resolve reject)
    (ignore reject)
    (let* ((default-directory (file-name-as-directory (expand-file-name (or cwd default-directory))))
           (group (not (file-remote-p default-directory)))
           (chunks nil)
           (stderr-buf (generate-new-buffer " *harness-cmd-stderr*" t))
           (done nil) (timer nil) (kill-timer nil) (pid nil) (proc nil) (tree nil)
           (finish (lambda (code)
                     (unless done
                       (setq done t)
                       (when timer (cancel-timer timer))
                       (when kill-timer (cancel-timer kill-timer))
                       (let ((err (and (buffer-live-p stderr-buf)
                                       (with-current-buffer stderr-buf (buffer-string)))))
                         (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf))
                         (funcall resolve (list :exit code
                                                :stdout (apply #'concat (nreverse chunks))
                                                :stderr (or err ""))))))))
      (let ((process-environment (if env
                                     (append (mapcar (lambda (pair)
                                                       (format "%s=%s" (car pair) (cdr pair)))
                                                     env)
                                             process-environment)
                                   process-environment)))
        (setq proc (make-process :name (or name "harness-cmd")
                                 :command command
                                 :connection-type 'pipe
                                 :noquery t
                                 :file-handler t
                                 :stderr stderr-buf
                                 :filter (lambda (_p chunk)
                                           (push chunk chunks)
                                           (when on-output (funcall on-output chunk)))
                                 :sentinel (lambda (p _e)
                                             (unless (process-live-p p)
                                               (funcall finish (process-exit-status p))))))
        (setq pid (process-id proc)))
      (when-let* ((ep (get-buffer-process stderr-buf)))
        (set-process-query-on-exit-flag ep nil)
        (set-process-sentinel ep #'ignore))
      (setq timer (run-at-time timeout nil
                               (lambda ()
                                 (setq tree (harness-process-tree pid group))
                                 (funcall finish 'timeout)
                                 (harness-kill-process-tree tree 'term)
                                 (setq kill-timer
                                       (run-at-time harness--process-kill-grace nil
                                                    (lambda ()
                                                      (harness-kill-process-tree tree 'kill)))))))
      (when stdin (process-send-string proc stdin))
      (when (process-live-p proc) (process-send-eof proc)))))

;;;; User options

(defun harness-save-user-option (symbol value)
  "Set SYMBOL to VALUE here and persist it in the user's custom file.
The custom file belongs to the Emacs showing the UI, which may not be
this one (see harness-server.el), so the save is asked of the UI over
`client/request'; without a UI it is done here when a custom file is
in use.  Returns nothing useful; failures are logged."
  (customize-set-variable symbol value)
  (if (and (fboundp 'harness-method-exists-p) (harness-method-exists-p 'client/request))
      (harness-catch (harness-call-async 'client/request "_harness/client/customize-save"
                                         (list :symbol (symbol-name symbol)
                                               :value (let ((print-length nil) (print-level nil))
                                                        (prin1-to-string value))))
                     (lambda (e) (harness-log 'warn "could not save %s: %s" symbol (harness-error-message e))))
    (when (and custom-file (not noninteractive))
      (condition-case err
          (customize-save-variable symbol value)
        (error (harness-log 'warn "could not save %s: %S" symbol err)))))
  nil)

;;;; Errors

(defun harness-error-message (err)
  "Return a readable message for ERR (an error data list or string).
An ACP error, (acp-error CODE MESSAGE DATA), reads as its MESSAGE."
  (cond ((stringp err) err)
        ((and (eq (car-safe err) 'acp-error) (stringp (nth 2 err)) (not (string-empty-p (nth 2 err))))
         (nth 2 err))
        ((and (consp err) (symbolp (car err)))
         (condition-case nil (error-message-string err)
           (error (format "%S" err))))
        (t (format "%S" err))))

(defmacro harness-ignore-errors-logged (context &rest body)
  "Run BODY, logging any error with CONTEXT instead of signalling."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (harness-log 'error "%s: %S" ,context err) nil)))

(provide 'harness-util)
;;; harness-util.el ends here
