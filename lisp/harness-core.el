;;; harness-core.el --- Core data model, registries and hooks for the agent harness -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; Author: the emacs-agent-harness authors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai, convenience
;; URL: https://git.sr.ht/~catvec/emacs-agent-harness

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

;; This is the bottom of the dependency graph: it defines the data structures
;; every other module shares, the registries they populate, and the hooks they
;; use to talk to each other.  It must not `require' any other `harness-'
;; module, so that `harness-core', `harness-http', `harness-provider' and
;; `harness-agent' remain usable without any UI loaded.
;;
;; See DESIGN.md sections 3 (data model) and 9 (extensibility).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mule-util)
(require 'subr-x)
(require 'time-date)

(defconst harness-version "0.1.0"
  "Version of the agent harness.")

(defgroup harness nil
  "A coding agent harness implemented natively in Emacs."
  :group 'tools
  :prefix "harness-")

(defgroup harness-faces nil
  "Faces used by the agent harness."
  :group 'harness
  :prefix "harness-")

(defgroup harness-sessions nil
  "Session storage and browsing."
  :group 'harness
  :prefix "harness-")

(defgroup harness-providers nil
  "Inference providers."
  :group 'harness
  :prefix "harness-")

(defgroup harness-tools nil
  "Tool definitions and permissions."
  :group 'harness
  :prefix "harness-")

(defgroup harness-ui nil
  "Buffers and user interface."
  :group 'harness
  :prefix "harness-")


;;; Globals and debugging

(defcustom harness-debug nil
  "When non-nil, log harness internals to the *Messages* buffer.
This is intentionally cheap to check; nothing else in the code base may
`message' on a hot path."
  :type 'boolean
  :group 'harness)

(defun harness--log (format-string &rest args)
  "Log FORMAT-STRING with ARGS when `harness-debug' is non-nil."
  (when harness-debug
    (apply #'message (concat "[harness] " format-string) args)))

(defvar harness-after-reload-hook nil
  "Hook run after the harness or a plugin is reloaded.
The UI uses this to re-render, so a changed renderer takes effect without
restarting Emacs.  See DESIGN.md section 13.1.")

(defvar harness--sessions (make-hash-table :test #'equal)
  "Registry of live sessions, keyed by session id.")

(defvar harness--session-tails (make-hash-table :test #'equal)
  "Cache of the last cons cell of each session's message list.
Keyed by session id.  Kept in sync by `harness-session-append-message' so
appending a message is O(1) instead of O(n); invalidated by
`harness-session-set-messages' and `harness-session-remove'.")

(defvar harness--message-ids (make-hash-table :test #'equal)
  "Counter used to generate unique message ids, keyed by session id.")


;;; JSON helpers

;; The provider layer speaks JSON constantly.  `json-serialize' is implemented
;; in C and is markedly faster than `json-encode' from json.el, so everything
;; in the harness goes through these two functions and nothing else.
;;
;; Representation: alists (`(:key . "value")'), lists for arrays, `nil' for
;; JSON null, `:false' for JSON false.  Keys may be symbols.

(defun harness-json-read (string)
  "Parse STRING as JSON into alists, lists, nil and :false."
  (json-parse-string string
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object :false))

(defun harness-json-write (object &optional pretty)
  "Serialise OBJECT to JSON text.

Objects are alists or plists with symbol keys, arrays are lists, `nil' is
JSON null and `:false' is JSON false.  `json-encode' is used rather than
`json-serialize' because the latter cannot tell a list-of-scalars (an array)
from a plist (an object); requests are encoded once per turn, so the
pure-Lisp encoder is not on any hot path.
When PRETTY is non-nil, produce indented output."
  (let ((json-encoding-pretty-print (and pretty t))
        (json-null nil)
        (json-false :false)
        (json-array-type 'list))
    (json-encode object)))

(defun harness-json-array (list)
  "Return LIST as a JSON array (a vector).

`json-encode' cannot tell an array of objects from an object when the array
has exactly one element, so any array whose elements are themselves objects
or arrays must be passed through here.  Arrays of scalars are unambiguous and
may stay lists."
  (vconcat list))

(defun harness-json-write-line (object)
  "Serialise OBJECT to one line of JSON, terminated by a newline."
  (concat (harness-json-write object) "\n"))

(defun harness-json-true-p (value)
  "Return non-nil when JSON VALUE is true (neither nil nor :false)."
  (not (memq value '(nil :false))))

(defun harness-alist-get (key alist)
  "Return the value of KEY in ALIST.

KEY may be a symbol, keyword or string, and ALIST keys may be symbols,
keywords or strings; comparison is case sensitive.  The provider layer needs
this because JSON keys arrive as symbols while configuration may use strings."
  (let ((name (cond ((stringp key) key)
                    ((keywordp key) (substring (symbol-name key) 1))
                    (t (symbol-name key)))))
    (cdr (or (assoc name alist)
             (assq (intern name) alist)
             (assoc (concat ":" name) alist)
             (assq (intern (concat ":" name)) alist)))))

(defun harness-plist-or-alist-get (key collection)
  "Return the value of symbol KEY in COLLECTION, a plist or an alist."
  (cond
   ((null collection) nil)
   ((keywordp (car collection)) (plist-get collection key))
   ((consp (car collection)) (harness-alist-get key collection))
   (t (plist-get collection key))))


;;; Ids

(defun harness--random-hex (n)
  "Return N random hex characters."
  (let ((out (make-string n ?0))
        (chars "0123456789abcdef"))
    (dotimes (i n)
      (aset out i (aref chars (random 16))))
    out))

(defun harness-generate-id ()
  "Generate a session id: sortable timestamp plus randomness."
  (concat (format-time-string "%Y%m%dT%H%M%S")
          "-"
          (harness--random-hex 8)))

(defun harness--next-message-id (session)
  "Return the next unique message id for SESSION."
  (let* ((id (harness-session-id session))
         (n (1+ (gethash id harness--message-ids 0))))
    (puthash id n harness--message-ids)
    (format "m-%d" n)))

(defun harness-reset-message-ids (session count)
  "Set SESSION's message id counter to COUNT (used when loading a session)."
  (puthash (harness-session-id session) count harness--message-ids))


;;; Message

(cl-defstruct (harness-message (:constructor harness--make-message)
                               (:copier harness-message-copy))
  "One entry in a session transcript.

CONTENT is the assistant or user text.  THINKING is a reasoning trace when
the provider exposes one.  Assistant messages carry TOOL-CALLS, tool result
messages carry TOOL-CALL-ID and TOOL-NAME.  META is free for plugins."
  (id nil)
  (role nil)
  (content "")
  (thinking nil)
  (tool-calls nil)
  (tool-call-id nil)
  (tool-name nil)
  (status 'complete)
  (error nil)
  (timestamp nil)
  (duration nil)
  (usage nil)
  (meta nil))

(defun harness-message-create (session role &optional content)
  "Create a message for SESSION with ROLE and CONTENT, with id and time set."
  (harness--make-message
   :id (harness--next-message-id session)
   :role role
   :content (or content "")
   :timestamp (float-time)))

(defun harness-message-finalize (message)
  "Mark MESSAGE complete and record how long it took."
  (when (and (harness-message-timestamp message)
             (not (harness-message-duration message)))
    (setf (harness-message-duration message)
          (- (float-time) (harness-message-timestamp message))))
  (unless (eq (harness-message-status message) 'error)
    (setf (harness-message-status message) 'complete))
  message)

(defun harness-message-text (message)
  "Return the plain text of MESSAGE, including tool calls as a short trailer."
  (string-join
   (delq nil
         (list (harness-message-content message)
               (when-let* ((calls (harness-message-tool-calls message)))
                 (mapconcat (lambda (tc)
                              (format "[tool %s]"
                                      (harness-tool-call-name tc)))
                            calls " "))))
   "\n"))


;;; Tool call

(cl-defstruct (harness-tool-call (:constructor harness--make-tool-call)
                                 (:copier harness-tool-call-copy))
  "A tool invocation requested by the model and its outcome.

STATUS is one of `pending', `awaiting-approval', `running', `ok', `error',
`denied', `aborted'."
  (id nil)
  (name nil)
  (args-string "")
  (args nil)
  (status 'pending)
  (result nil)
  (error nil)
  (detail nil)
  (started nil)
  (finished nil)
  (meta nil))

(defun harness-tool-call-create (&rest args)
  "Create a tool call from ARGS, which are passed to the struct constructor.
A fresh id is generated when none is supplied."
  (let ((call (apply #'harness--make-tool-call args)))
    (unless (harness-tool-call-id call)
      (setf (harness-tool-call-id call) (concat "tc-" (harness--random-hex 8))))
    call))

(defun harness-tool-call-parse-args (tool-call)
  "Parse TOOL-CALL's argument string into `args' when possible.
Returns the parsed value, or nil when the string is empty or malformed."
  (let ((string (harness-tool-call-args-string tool-call)))
    (when (and (stringp string) (not (string-empty-p (string-trim string))))
      (condition-case nil
          (setf (harness-tool-call-args tool-call)
                (harness-json-read string))
        (error
         (harness--log "could not parse args for %s: %s"
                       (harness-tool-call-name tool-call) string)
         nil)))))

(defun harness-tool-call-arg (tool-call key &optional default)
  "Return argument KEY of TOOL-CALL (a symbol), or DEFAULT."
  (or (harness-plist-or-alist-get key (harness-tool-call-args tool-call))
      default))

(defun harness-tool-call-summary (tool-call)
  "Return a one line summary of TOOL-CALL for the mode line and headers."
  (let ((name (harness-tool-call-name tool-call))
        (args (harness-tool-call-args tool-call)))
    (format "%s%s"
            name
            (if-let* ((s (and (listp args)
                             (or (harness-plist-or-alist-get :command args)
                                 (harness-plist-or-alist-get :file_path args)
                                 (harness-plist-or-alist-get :path args)
                                 (harness-plist-or-alist-get :pattern args)
                                 (harness-plist-or-alist-get :query args)
                                 (harness-plist-or-alist-get :prompt args)
                                 (harness-plist-or-alist-get :description args)))))
                (concat "(" (truncate-string-to-width
                             (replace-regexp-in-string "\n" " " (format "%s" s))
                             60 nil nil "…")
                        ")")
              ""))))


;;; Queued message

(cl-defstruct (harness-queued-message (:constructor harness--make-queued-message)
                                      (:copier harness-queued-message-copy))
  "A user message waiting for the current run to finish."
  (id nil)
  (text "")
  (created nil)
  (meta nil))

(defun harness-queued-message-create (text)
  "Create a queued message holding TEXT."
  (harness--make-queued-message
   :id (concat "q-" (harness--random-hex 8))
   :text text
   :created (float-time)))


;;; Approval

(cl-defstruct (harness-approval (:constructor harness--make-approval)
                                (:copier harness-approval-copy))
  "A decision the run loop is waiting for.

KIND is `tool' (permission for a tool call) or `question' (the model asked
the user something).  CALLBACK is called with the decision; it is the only
thing that resumes the run."
  (id nil)
  (session nil)
  (tool-call nil)
  (kind 'tool)
  (prompt "")
  (detail nil)
  (choices nil)
  (callback nil)
  (created nil))

(defun harness-approval-create (&rest args)
  "Create an approval from ARGS.
An id and creation time are filled in when absent."
  (let ((approval (apply #'harness--make-approval args)))
    (unless (harness-approval-id approval)
      (setf (harness-approval-id approval) (concat "ap-" (harness--random-hex 8))))
    (unless (harness-approval-created approval)
      (setf (harness-approval-created approval) (float-time)))
    approval))


;;; Session

(cl-defstruct (harness-session (:constructor harness--make-session)
                               (:copier harness-session-copy))
  "One agent conversation.

MESSAGES is oldest-first.  TAIL is an internal pointer to the last cons of
MESSAGES, maintained by `harness-session-append-message' so that appending is
O(1); it is never serialised."
  (id nil)
  (name nil)
  (project-root nil)
  (project-name nil)
  ;; The directory every tool, `@' attachment and command resolves against.
  ;; It starts at the project root and can be moved -- to a git worktree, for
  ;; example -- without changing which project the session belongs to.
  (working-directory nil)
  (file nil)
  (provider nil)
  (model nil)
  (messages nil)
  (tail nil)
  (status 'idle)
  (status-detail nil)
  (queue nil)
  (approvals nil)
  (usage nil)
  (parent nil)
  (children nil)
  (created nil)
  (updated nil)
  (buffer nil)
  (run nil)
  (title-generated nil)
  (meta nil))

(defun harness-session-get (id)
  "Return the session with ID, or nil."
  (gethash id harness--sessions))

(defun harness-session-all ()
  "Return all live sessions as a list."
  (let (sessions)
    (maphash (lambda (_id session) (push session sessions)) harness--sessions)
    sessions))

(defun harness-session-list (&optional predicate)
  "Return live sessions sorted by last update, most recent first.
When PREDICATE is non-nil, only sessions for which it returns non-nil are
included."
  (let ((sessions (harness-session-all)))
    (when predicate
      (setq sessions (cl-remove-if-not predicate sessions)))
    (sort sessions
          (lambda (a b)
            (> (or (harness-session-updated a) 0)
               (or (harness-session-updated b) 0))))))

(defun harness-session-put (session &optional quiet)
  "Register SESSION in the live registry.
Unless QUIET, run `harness-session-created-hook'."
  (puthash (harness-session-id session) session harness--sessions)
  (setf (harness-session-updated session) (float-time))
  (unless quiet
    (run-hook-with-args 'harness-session-created-hook session))
  session)

(defun harness-session-remove (session)
  "Remove SESSION from the live registry.
Does not touch the session file; see `harness-session-delete'."
  (remhash (harness-session-id session) harness--sessions)
  (remhash (harness-session-id session) harness--session-tails)
  (remhash (harness-session-id session) harness--message-ids)
  (run-hook-with-args 'harness-session-deleted-hook session))

(defun harness-session-append-message (session message)
  "Append MESSAGE to SESSION's transcript, in O(1)."
  (let ((tail (harness-session-tail session)))
    (cond
     ((null tail)
      (setf (harness-session-messages session) (list message))
      (setf (harness-session-tail session) (harness-session-messages session)))
     ((null (cdr tail))
      (setcdr tail (list message))
      (setf (harness-session-tail session) (cdr tail)))
     (t
      ;; The tail pointer is stale (something replaced the list); fall back to
      ;; a linear scan rather than corrupting the transcript.
      (let ((new-tail (last (harness-session-messages session))))
        (setcdr new-tail (list message))
        (setf (harness-session-tail session) (cdr new-tail))))))
  message)

(defun harness-session-set-messages (session messages)
  "Replace SESSION's transcript with MESSAGES.
Maintains the tail pointer and resets the message id counter."
  (setf (harness-session-messages session) messages)
  (setf (harness-session-tail session) (last messages))
  (harness-reset-message-ids session (length messages))
  (run-hook-with-args 'harness-session-updated-hook session '(messages))
  session)

(defun harness-session-last-message (session)
  "Return SESSION's most recent message, or nil."
  (car (harness-session-tail session)))

(defun harness-session-messages-by-role (session role)
  "Return SESSION's messages whose role is ROLE."
  (cl-remove-if-not (lambda (m) (eq (harness-message-role m) role))
                    (harness-session-messages session)))

(defun harness-session-system-message (session)
  "Return the first system message of SESSION, or nil."
  (car (harness-session-messages-by-role session 'system)))


;;; Status

(defconst harness-status-list
  '(idle working streaming awaiting-approval awaiting-answer classifying
         aborted exited)
  "All session statuses.")

(defconst harness-status-blocked-list
  '(awaiting-approval awaiting-answer)
  "Statuses meaning the harness is waiting on the user.")

(defconst harness-status-active-list
  '(working streaming classifying)
  "Statuses meaning the model is doing work.")

(defun harness-status-blocked-p (status)
  "Return non-nil when STATUS means a session waits for the user."
  (memq status harness-status-blocked-list))

(defun harness-status-active-p (status)
  "Return non-nil when STATUS means a session is busy."
  (memq status harness-status-active-list))

(defun harness-session-blocked-p (session)
  "Return non-nil when SESSION waits for the user."
  (harness-status-blocked-p (harness-session-status session)))

(defun harness-session-active-p (session)
  "Return non-nil when SESSION is busy."
  (harness-status-active-p (harness-session-status session)))

(defun harness-session-notify (session &rest events)
  "Notify the world that SESSION changed; EVENTS describes what changed.
See DESIGN.md section 3.1 for the event symbols.  This is the single funnel
for change notification, so a plugin only needs to add one hook function."
  (setf (harness-session-updated session) (float-time))
  (run-hook-with-args 'harness-session-updated-hook session events))

(defun harness-session-set-status (session status &optional detail)
  "Set SESSION's STATUS to STATUS, with optional DETAIL plist.
Runs the status hook and notifies listeners."
  (let ((old (harness-session-status session)))
    (unless (eq old status)
      (setf (harness-session-status session) status)
      (setf (harness-session-status-detail session) detail)
      (run-hook-with-args 'harness-status-changed-hook session old status))
    (harness-session-notify session 'status))
  status)

(defun harness-session-status-string (session)
  "Return a human readable status for SESSION, including detail."
  (let ((status (harness-session-status session))
        (detail (harness-session-status-detail session)))
    (format "%s%s"
            (capitalize (symbol-name status))
            (if-let* ((extra (and detail (plist-get detail :label))))
                (format " (%s)" extra)
              ""))))


;;; Usage and cost

;; NOTE: cl-defstruct defines `harness-session-usage' as the accessor for the
;; `usage' slot, so the summarising helper must use a different name.

(defun harness-usage-add (a b)
  "Add usage plists A and B, returning a new plist."
  (let (out)
    (dolist (key '(:in :out :cache-read :cache-write :cost :requests))
      (let ((sum (+ (or (plist-get a key) 0) (or (plist-get b key) 0))))
        (when (or (plist-get a key) (plist-get b key))
          (setq out (plist-put out key sum)))))
    ;; Preserve any other keys (plugins may add some) by preferring the newer.
    (let (extra)
      (dolist (pl (list a b))
        (cl-loop for (k v) on pl by #'cddr
                 unless (memq k '(:in :out :cache-read :cache-write :cost :requests))
                 do (setq extra (plist-put extra k v))))
      (cl-loop for (k v) on extra by #'cddr
               do (setq out (plist-put out k v))))
    out))

(defun harness-session-usage-total (session)
  "Return SESSION's accumulated usage plist, defaulting to zeroes."
  (or (harness-session-usage session)
      '(:in 0 :out 0 :cost 0.0)))

(defun harness-session-add-usage (session usage)
  "Add USAGE to SESSION's accumulator and notify listeners."
  (setf (harness-session-usage session)
        (harness-usage-add (harness-session-usage session) usage))
  (harness-session-notify session 'usage)
  (harness-session-usage session))

(defun harness-usage-format (usage)
  "Format USAGE for the mode line: tokens and money when known."
  (let ((in (or (plist-get usage :in) 0))
        (out (or (plist-get usage :out) 0))
        (cost (plist-get usage :cost)))
    (concat (format "%s↑ %s↓" (harness-format-count in) (harness-format-count out))
            (when (and cost (> cost 0))
              (format " %s" (harness-format-cost cost))))))

(defun harness-format-count (n)
  "Format token count N compactly."
  (cond
   ((null n) "0")
   ((>= n 1000000) (format "%.1fM" (/ n 1000000.0)))
   ((>= n 1000) (format "%.1fk" (/ n 1000.0)))
   (t (number-to-string (truncate n)))))

(defun harness-format-cost (cost)
  "Format COST in US dollars."
  (cond
   ((null cost) "")
   ((>= cost 1) (format "$%.2f" cost))
   ((> cost 0) (format "$%.4f" cost))
   (t "$0")))


;;; Text helpers

(defcustom harness-truncate-chars 65536
  "Maximum number of characters of tool output kept in a message.
The full output stays available on the tool call struct for the UI to
expand.  Truncating here is what keeps a runaway `cat' from freezing redisplay."
  :type 'integer
  :group 'harness-tools)

(defcustom harness-truncate-lines 2000
  "Maximum number of lines of tool output kept in a message."
  :type 'integer
  :group 'harness-tools)

(defun harness-truncate-string (string &optional max-chars max-lines tail)
  "Truncate STRING, noting how much was dropped.

When TAIL is non-nil keep the end of STRING instead of the beginning, which
is what command output wants.  MAX-CHARS defaults to `harness-truncate-chars'
and MAX-LINES to `harness-truncate-lines'; a nil value means no limit."
  (if (or (null string) (string-empty-p string))
      (or string "")
    (let* ((max-chars (or max-chars harness-truncate-chars))
           (max-lines (or max-lines harness-truncate-lines))
           (lines (1+ (cl-count ?\n string)))
           (truncated nil))
      (when (and max-lines (> lines max-lines))
        ;; Keep the first (or last) MAX-LINES lines.  `string-match' returns the
        ;; start of the match, so the head case needs `match-end'.
        (setq string
              (if tail
                  (substring string
                             (or (save-match-data
                                   (when (string-match
                                          (format "\\(?:[^\n]*\n\\)\\{%d\\}\\'"
                                                  (- lines max-lines))
                                          string)
                                     (match-beginning 0)))
                                 0))
                (substring string 0 (save-match-data
                                      (string-match
                                       (format "\\(?:[^\n]*\n\\)\\{%d\\}"
                                               max-lines)
                                       string)
                                      (match-end 0)))))
        (setq truncated t))
      (when (> (length string) max-chars)
        (setq string
              (if tail
                  (substring string (- (length string) max-chars))
                (substring string 0 max-chars)))
        (setq truncated t))
      (if truncated
          (if tail
              (format "[output truncated: showing last %s characters]\n%s"
                      (harness-format-count (length string)) string)
            (format "%s\n[output truncated: showing first %s characters]"
                    string (harness-format-count (length string))))
        string))))

(defun harness-string-empty-p (string)
  "Return non-nil when STRING is nil or contains only whitespace."
  (or (null string) (string-empty-p (string-trim string))))

(defun harness-relative-path (path &optional directory)
  "Return PATH relative to DIRECTORY (default `default-directory') when it is
inside that directory; otherwise return PATH unchanged."
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory default-directory))))
         (expanded (expand-file-name path dir)))
    (if (string-prefix-p dir expanded)
        (substring expanded (length dir))
      expanded)))

(defun harness-format-time (time)
  "Format TIME (a float) for display, relative when recent."
  (when time
    (let ((seconds (- (float-time) time)))
      (cond
       ((< seconds 60) "now")
       ((< seconds 3600) (format "%dm" (/ (truncate seconds) 60)))
       ((< seconds 86400) (format "%dh" (/ (truncate seconds) 3600)))
       ((< seconds 604800) (format "%dd" (/ (truncate seconds) 86400)))
       (t (format-time-string "%Y-%m-%d" (seconds-to-time time)))))))

(defun harness-make-temp-file (prefix &optional suffix)
  "Create an empty temporary file named PREFIX...SUFFIX and return its name."
  (make-temp-file prefix nil suffix))

(defun harness-shell-quote (string)
  "Quote STRING for safe inclusion in a POSIX shell command."
  (shell-quote-argument string))

(provide 'harness-core)
;;; harness-core.el ends here
