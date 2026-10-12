;;; harness-redact.el --- Take a secret out of everything the harness stored  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A secret that got into a transcript is in more places than the
;; transcript: the node log of the session, its nodes in memory, its
;; record, the search index and its vectors, the conversation log of a
;; hosted provider's CLI, the records of the tasks that ran in it.
;; `secrets/redact' takes it out of all of them, and records that it did,
;; without the secret ever passing through the session that asked: the
;; request names the secret by where it can be read, never by its value.
;;
;; The secret.  A reference (:file PATH :json-path P), (:file PATH
;; :regexp RE) or (:env NAME) says where the value is, and the engine
;; reads it itself (`harness-redaction-resolve').  A literal or a command
;; (which would put the value in the call, or run something the model
;; chose) is refused unless the caller, the UI or Lisp, says it is safe
;; to allow them with `:allow-unsafe-sources'.  The values live in memory
;; for the length of the request, and in `harness-redact--pending' for a
;; session that was running.  Everything the engine writes, emits or
;; returns -- the record in the session, its hint, the events, the report
;; -- is made of labels, fingerprints (the first 8 hex digits of the
;; SHA-256 of the value), ids, paths and counts, and is checked for the
;; values before it leaves (a label or a reason that holds one is
;; replaced first).  So the request and its answer hold no secret, and
;; the session that redacts never has to be redacted itself.  The one
;; exception is a call that carried the secret in its input anyway: the
;; session that made it is added to the scope.
;;
;; The scope is a session (and its forks, unless left out), a project, or
;; every session.  A scan counts and changes nothing; a redaction takes
;; the stores in turn, in `harness-redact--store-functions': the node
;; logs, memory and records of the sessions (`session/redact-text'), the
;; search index (`session/search-redact'), the logs of Claude Code
;; (`provider/claude-redact-logs') and Copilot, and the task records
;; (`task/redact').  Then the sessions whose provider conversation held a
;; secret start over from their redacted transcript
;; (`session/reset-provider'), the search index gives back the pages that
;; held the old text (`session/search-purge'), and every session that
;; changed gets a record in its `ext' (`:redactions') and a hint in its
;; transcript, and is announced (`session/redacted').  A session outside
;; the scope that shares a conversation with one inside it, and whose own
;; transcript still holds the secret, keeps its conversation (`kept'): the
;; log they share is clean, and a new conversation would be made from the
;; transcript.
;;
;; The conversation and its cache.  Only a session whose nodes (the node
;; log, or the nodes in memory) or whose provider's own log held the
;; secret starts a new conversation.  A hit only in its record (queue,
;; name, todos, plan, ext, pending, move) was sent to no provider
;; conversation, and a new one is made from the nodes, so it resets
;; nothing.  A reset costs the prompt cache: a hosted provider (Claude
;; Code, Copilot) caches the conversation it keeps, and the new one opens
;; with the transcript as text, which is another prefix.  The old cache
;; could not be used again anyway: it holds the secret.
;; `session/reset-provider' marks the cache dropped when it drops one,
;; and the session's `:cache' says so from then on (`:dropped'), so that
;; its next message meets the cold-cache question (harness-cowboy.el)
;; instead of sending the whole transcript uncached, unasked.  The report
;; says whose cache went (`:cache-dropped', and the tokens it held,
;; `:context'), and a scan says whose conversation a redaction would start
;; over and whose cache it would drop (`:would-reset',
;; `:cache-would-drop', from `session/reset-drops-cache-p'), so that the
;; cost is known before the redaction is confirmed.  A session on a
;; provider that is sent the whole transcript with every request is not
;; marked: its next request is built from the redacted transcript and
;; still reads the cache up to the first spot that was redacted.
;;
;; Critical sections.  The harness process has one thread.  Each store
;; reads, cleans and replaces its file in one step that never yields
;; (see `session/redact-text'), and files are replaced by a rename, so a
;; reader sees the old file or the new one and an append of this process
;; never falls between the read and the write: no append is lost and no
;; log is torn.  The engine itself is one synchronous call; a search
;; index of hundreds of megabytes makes the purge (a VACUUM) take its
;; time, and the process does nothing else meanwhile.
;;
;; The plain files and the buffers.  Five more stores follow the tasks:
;; the transcript files that compaction and handoff write into the
;; directories of the sessions' projects (`harness-redact--stage-transcripts'),
;; the files in which cut tool outputs are saved
;; (`harness-redact--stage-spill'), the sessions' temporary directories
;; (`harness-redact--stage-temp'), for the scope all everything else
;; under the state directory (`harness-redact--stage-state'), and the log
;; buffers of this process (`harness-redact--stage-buffers').  A file is
;; counted by its bytes first and rewritten as text, JSON or JSON lines
;; only when it holds a secret; one that is binary, a SQLite database or
;; over 64 MiB cannot be rewritten safely, so it is counted and reported
;; as found, not redacted.  A file that is a link is never followed, and
;; neither is the file the secret was read from.
;;
;; Verification.  A redaction ends by scanning the same scope and the same
;; stores again, as a scan does, and by counting the secret in the files
;; of the search index (search.db and its write-ahead log and shared
;; memory).  The report says what is left store by store
;; (`:verification'), and whatever a deferred, busy or binary file does
;; not explain is listed under `:remaining': a redaction that something
;; wrote back, or that missed a copy, is never reported as done.  A log of
;; a provider that no session owns and that was written lately (`busy') is
;; left alone and listed under `:remaining' too.  A request for some
;; sessions leaves the others' rows in the index, whose files then hold the
;; secret: that is expected, and not a copy the request missed.
;;
;; The log.  Every redaction adds a line to redactions.jsonl in the state
;; directory -- when, who asked, why, the secrets by label and
;; fingerprint, the totals per store, the sessions and files that
;; changed, the sessions that wait and the verification, never a value
;; (`harness-redact--log-run') -- and `secrets/log' reads it back.
;;
;; A running turn.  A session that runs a turn is cleaned at once -- its
;; log, nodes and record -- but its provider conversation cannot be
;; dropped under it, and what the turn writes next can bring the secret
;; back.  So the rest waits for the end of the turn: the request is kept
;; in memory (`harness-redact--pending', the session's `ext' only says
;; that a redaction is `:redaction-pending', by label and fingerprint),
;; tool output is masked of the pending secrets meanwhile, and when
;; `agent/turn-ended' announces the end the stores of that session are
;; gone over again, its provider is reset, and a second record and hint
;; say "after its turn ended".  Its prompt cache is dropped then, not
;; before, so its next message meets the cold-cache question from the end
;; of the turn on.  A harness that stops first loses the secret from
;; memory with the rest: when it starts, a flagged session has its
;; provider reset and a hint saying the redaction should be run again
;; (`harness-redact--init').
;;
;; Extending.  A store that is not the sessions' own adds a function to
;; `harness-redact--store-functions', called with the run: it finds its
;; copies with `harness-redact-run-secrets' (and says what it only
;; counts when `harness-redact-run-dry-p'), reports with
;; `harness-redact-add-store', and credits the sessions it can attribute
;; its copies to with `harness-redact-entry-put' and
;; `harness-redact-entry-add'.  Checks of the result go in
;; `harness-redact--verify-functions', and what has to happen last in
;; `harness-redact--finish-functions'.
;;
;; The tool.  An agent redacts with `redact_secret' (see "The
;; redact_secret tool" below), whose call and result are kept in its
;; transcript like any other.  So the call names the secret by where it
;; is read -- never by its value: the tool takes no literal and no
;; command -- and everything it gets back is made of the report of
;; `secrets/redact', labels, fingerprints, ids and counts.  The call
;; carries `:origin' and `:input-text', so a model that put the value in
;; the call anyway has its own session added to the scope.  A scan and a
;; look at the shape of a file are reads to the permission chain, a
;; redaction is not (`harness-perms--call-kind').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-redaction)
(require 'harness-files)
;; For `harness-define-tool' and the tool results.  The tools module is not
;; a requirement of this one: registering a tool needs the library only.
(require 'harness-tools)

(defvar harness-state-directory)

(declare-function harness-session--save "harness-session" (id))

;;;; State and constants

(defconst harness-redact--records-limit 50
  "Most redaction records a session keeps in its `ext' (`:redactions').")

(defconst harness-redact--nodes-limit 200
  "Most node ids a redaction record names.")

(defconst harness-redact--files-limit 40
  "Most files of one store that the text of a report lists.")

(defconst harness-redact--param-keys
  '(:source :label :scope :sessions :include-forks :project :mode :reason
    :origin :input-text :allow-unsafe-sources)
  "The parameters `secrets/redact' accepts.")

(defconst harness-redact--withheld-reason "(withheld: it contained the secret)"
  "What stands in for a reason that held the value of a secret.")

(defconst harness-redact--withheld-output
  "[output withheld: it could not be checked for secrets]"
  "What stands in for tool output that holding could not check.")

(defvar harness-redact--pending (make-hash-table :test 'equal)
  "Session id -> the redactions waiting for the end of its running turn.
Each is a plist (:secrets SECRETS :ref REF :origin ORIGIN :reason REASON
:claude-ids IDS :copilot-ids IDS).  The secrets hold their values: this
table is the one place a value outlives the request that named it, and
it is in memory only.")

(defconst harness-redact--store-functions
  '(harness-redact--stage-sessions
    harness-redact--stage-search
    harness-redact--stage-claude
    harness-redact--stage-copilot
    harness-redact--stage-tasks
    harness-redact--stage-transcripts
    harness-redact--stage-spill
    harness-redact--stage-temp
    harness-redact--stage-state
    harness-redact--stage-buffers)
  "The stores, in the order a request takes them, each a function of the run.
They run before the providers are reset (the checkpoints that name a
CLI conversation are still on the nodes), in either mode: a store only
counts when `harness-redact-run-dry-p'.  The verification of a
redaction runs them again, on a scan of the same scope.")

(defconst harness-redact--verify-functions '(harness-redact--verify-stores)
  "Functions of the run that check the stores after a redaction.
They run after the records are written and before the report is made,
in either mode, and add their findings with `harness-redact-add-store',
`harness-redact-add-lines' and `harness-redact-run-set-prop'.  The one
here scans again and does nothing for a scan.")

(defconst harness-redact--finish-functions '(harness-redact--log-run)
  "Functions of the run and its report called last, after the report is made.
They keep what has to outlive the request, such as the log of
redactions; they run in redact mode only, and add nothing to the report.")

(defconst harness-redact--sweep-limit (* 64 1024 1024)
  "Largest file, in bytes, that a redaction reads into memory to rewrite.
A larger one is counted by its bytes, as a binary file is, and reported
as found, not redacted.")

(defconst harness-redact--file-counts
  '((:transcripts . "transcript files") (:spill . "spill files") (:temp . "session temp files"))
  "The counts of occurrences in files that a session is credited with.
Each is the key of the count in the session's entry, with what the
report calls the files: the transcripts it wrote, the outputs it cut and
saved whole, and what it left in its temporary directory.")

(defconst harness-redact--quiet-seconds 60
  "Seconds a scratch file has to be left alone to be rewritten.
A file in a session's temporary directory that was written more recently
may have a process at work in it, which a rewrite by rename would leave
writing into the old file, and is left as it is (`busy').")

(defconst harness-redact--transcript-directories '(".harness/transcripts" ".harness/handoff")
  "Where in a session's directory transcript files are, relative to it.
`session/write-transcript' writes to the first, as compaction into a
transcript does, and a handoff to the second.")

(defconst harness-redact--state-skipped '("sessions" "outputs" "elc" "elc-server" "recordings" "clips" "thumbs")
  "Directories of the state directory that the sweep of state files leaves out.
The sessions' own files are the first store's, the tool outputs the spill
files', and the others hold compiled code, recordings and pictures.")

(defconst harness-redact--runs-file "redactions.jsonl"
  "Store document that gets a line for each redaction.")

(defconst harness-redact--runs-limit 50
  "How many redactions `secrets/log' gives when it is not told.")

(defconst harness-redact--runs-names-limit 1000
  "Most session ids, and files, that a line of the log of redactions names.")

;;;; The run

(cl-defstruct (harness-redact-run (:copier nil) (:constructor harness-redact--make-run))
  "One request to take secrets out of the stores, and what came of it."
  (mode 'scan)                          ; `scan' or `redact'
  secrets                               ; plists with :value, in memory only
  ref                                   ; the reference as it may be shown
  scope                                 ; `session', `project' or `all'
  scope-text                            ; a description of the scope
  project                               ; the directory of a project scope
  ids                                   ; the session ids in scope
  origin                                ; (:kind user) or (:kind session :id ID)
  origin-note                           ; why the origin session is in scope, or nil
  reason                                ; why, safe to show, or nil
  (skipped 0)                           ; values too short to be secrets
  after-turn                            ; non-nil: a re-run after a running turn ended
  (entries (make-hash-table :test 'equal)) ; session id -> its entry, a plist
  order                                 ; the session ids of the entries, newest first
  stores                                ; (:store NAME ...) plists, newest first
  lines                                 ; (KEY . LINE) text of the report, newest first
  props)                                ; a plist for the stores' own use

(defun harness-redact-run-dry-p (run)
  "Non-nil when RUN only scans: nothing is changed."
  (not (eq (harness-redact-run-mode run) 'redact)))

(defun harness-redact-run-prop (run key)
  "Return what RUN keeps under KEY, a keyword the stores choose."
  (plist-get (harness-redact-run-props run) key))

(defun harness-redact-run-set-prop (run key value)
  "Keep VALUE in RUN under KEY; return it."
  (setf (harness-redact-run-props run) (plist-put (harness-redact-run-props run) key value))
  value)

(defun harness-redact-entry (run sid)
  "Return the entry RUN keeps for session SID, a plist, or nil.
An entry says what was found in the stores of a session and what was
done: `:log', `:memory', `:record', `:search', `:claude', `:copilot' and
`:tasks' count occurrences (rows, for the index), `:nodes', `:fields'
and `:record-fields' say where in the transcript and the record,
`:files' which files, `:provider' what happened to the provider
conversation, `:error' what could not be done.  `:provider-target' says
the session's provider conversation held the secret and starts over.
`:cache-dropped' says the reset dropped its prompt cache; in a scan,
`:would-reset' says a redaction would start the conversation over and
`:cache-would-drop' that it would drop the cache with it."
  (gethash sid (harness-redact-run-entries run)))

(defun harness-redact-entry-put (run sid key value)
  "Set KEY to VALUE in the entry of session SID of RUN, made if need be."
  (let ((entries (harness-redact-run-entries run)))
    (unless (gethash sid entries)
      (puthash sid (list :id sid) entries)
      (push sid (harness-redact-run-order run)))
    (puthash sid (plist-put (gethash sid entries) key value) entries)
    value))

(defun harness-redact-entry-add (run sid key items)
  "Add the list ITEMS to the list at KEY of the entry of SID in RUN, once each."
  (harness-redact-entry-put
   run sid key
   (delete-dups (append (plist-get (harness-redact-entry run sid) key) items nil))))

(defun harness-redact-entry-incr (run sid key n)
  "Add the number N to the count at KEY of the entry of SID in RUN."
  (harness-redact-entry-put
   run sid key (+ (or (plist-get (harness-redact-entry run sid) key) 0) n)))

(defun harness-redact--count (run sid key)
  "Return the count at KEY in the entry of SID of RUN, 0 when there is none."
  (or (plist-get (harness-redact-entry run sid) key) 0))

(defun harness-redact-add-store (run store &optional lines)
  "Report the shared STORE, a plist (:store NAME ...), in RUN.
NAME says which store it is; a `:count' is the occurrences in it that
the request found, which the report adds to its total.  LINES, a list of
strings, are what the text of the report says of it, in the order the
stores were added.  Values and snippets never go in either."
  (push store (harness-redact-run-stores run))
  (dolist (line lines)
    (push (cons 'store line) (harness-redact-run-lines run)))
  store)

(defun harness-redact-add-lines (run lines)
  "Add LINES, strings, to the end of the text of the report of RUN."
  (dolist (line lines)
    (push (cons 'extra line) (harness-redact-run-lines run))))

(defun harness-redact-update-store (run name &rest props)
  "Set PROPS, keys and values, on the store of RUN called NAME; return it."
  (let ((cell (cl-find name (harness-redact-run-stores run)
                       :key (lambda (s) (plist-get s :store)) :test #'equal)))
    (when cell
      (let ((new cell))
        (cl-loop for (k v) on props by #'cddr do (setq new (plist-put (copy-sequence new) k v)))
        (setf (harness-redact-run-stores run) (cl-substitute new cell (harness-redact-run-stores run) :test #'eq))
        new))))

(defun harness-redact--note-error (run what err)
  "Note in RUN that WHAT failed with the error ERR; log it, without data."
  (let ((text (format "%s failed: %s" what (harness-redact--error-text err))))
    (harness-log 'warn "redact: %s" text)
    (harness-redact-run-set-prop run :errors
                                 (append (harness-redact-run-prop run :errors) (list text)))
    text))

(defun harness-redact--error-text (err)
  "Describe ERR without the data it carries, which could quote a file's text.
Only the errors of the harness and of files, whose data are messages and
names, are described in full."
  (let ((conditions (get (car err) 'error-conditions)))
    (cond ((and (memq 'harness-error conditions) (stringp (cadr err)) (null (cddr err)))
           (cadr err))
          ((or (memq 'harness-error conditions) (memq 'file-error conditions))
           (harness-error-message err))
          (t (symbol-name (car err))))))

(defun harness-redact--fail (fmt &rest args)
  "Signal a `harness-error' with the message FMT formats with ARGS.
Callers pass names, labels and counts, never a value."
  (signal 'harness-error (list (apply #'format fmt args))))

;;;; Naming the request

(defun harness-redact--keyword (key)
  "Return KEY, a key as a client may spell it, as a keyword in kebab case.
`include_forks' and `includeForks' are `:include-forks'."
  (let* ((case-fold-search nil)
         (name (string-remove-prefix ":" (if (symbolp key) (symbol-name key) (format "%s" key))))
         (name (replace-regexp-in-string "\\([a-z0-9]\\)\\([A-Z]\\)" "\\1-\\2" name t)))
    (intern (concat ":" (downcase (string-replace "_" "-" name))))))

(defun harness-redact--plist (value what)
  "Return VALUE, a client's plist, with its keys as keywords in kebab case.
WHAT names it in the error signalled when VALUE is no plist."
  (cond ((null value) nil)
        ((and (consp value) (proper-list-p value) (keywordp (car value)) (cl-evenp (length value)))
         (cl-loop for (k v) on value by #'cddr append (list (harness-redact--keyword k) v)))
        (t (harness-redact--fail "%s must be a plist" what))))

(defun harness-redact--symbol (value what allowed)
  "Return VALUE, a string or a symbol, as the symbol of ALLOWED it names.
Signal an error naming WHAT and the symbols allowed otherwise."
  (let ((symbol (cond ((and value (symbolp value) (not (keywordp value))) value)
                      ((stringp value) (intern (downcase (string-trim value)))))))
    (if (memq symbol allowed)
        symbol
      (harness-redact--fail "%s must be one of %s" what
                            (mapconcat #'symbol-name allowed ", ")))))

(defun harness-redact--short-id (id)
  "Return the first 8 characters of the session id ID."
  (substring id 0 (min 8 (length id))))

(defun harness-redact--origin (value)
  "Return VALUE, who asks, as (:kind user) or (:kind session :id ID)."
  (if (null value)
      (list :kind 'user)
    (let* ((o (harness-redact--plist value "The origin"))
           (kind (harness-redact--symbol (or (plist-get o :kind) 'user) "The origin's kind"
                                         '(user session)))
           (id (plist-get o :id)))
      (if (eq kind 'user)
          (list :kind 'user)
        (unless (and (stringp id) (not (string-empty-p id)))
          (harness-redact--fail "A session origin needs the :id of the session"))
        (list :kind 'session :id id)))))

(defun harness-redact--origin-by (origin)
  "Return who asked, ORIGIN, as a record names them."
  (if (eq (plist-get origin :kind) 'session)
      (format "session %s" (harness-redact--short-id (plist-get origin :id)))
    "user"))

(defun harness-redact--origin-phrase (origin)
  "Return who asked, ORIGIN, as a hint says it after \"at\"."
  (if (eq (plist-get origin :kind) 'session)
      (format "the request of session %s" (harness-redact--short-id (plist-get origin :id)))
    "your request"))

(defun harness-redact--reference (source label allow-unsafe)
  "Return SOURCE, the reference to the secret, with LABEL, checked.
A reference that holds the value or runs something -- a literal, a
command -- is refused unless ALLOW-UNSAFE."
  (unless (and (consp source) (keywordp (car source)))
    (harness-redact--fail
     "The source is a reference to the secret: :file with :json-path or :regexp, or :env"))
  (let ((ref (harness-redact--plist source "The source")))
    (when (and (or (plist-member ref :literal) (plist-member ref :command))
               (not allow-unsafe))
      (harness-redact--fail
       "A secret given as its text or as a command is not accepted here: name where it can be read (:file with :json-path or :regexp, or :env)"))
    (when (and (stringp label) (not (string-blank-p label)))
      (setq ref (plist-put ref :label label)))
    ref))

(defun harness-redact--public-ref (ref secrets)
  "Return REF as it may be shown: nothing of a literal or a command, and no value.
SECRETS are the values to keep out of it."
  (cond ((plist-member ref :literal) (list :kind 'literal))
        ((plist-member ref :command) (list :kind 'command))
        (t (car (harness-redaction-value
                 (cl-loop for k in '(:file :json-path :regexp :env :label)
                          when (plist-member ref k) append (list k (plist-get ref k)))
                 secrets)))))

(defun harness-redact--safe-secrets (secrets)
  "Return SECRETS with a label that holds a value of them made safe.
Its placeholder would hold the value, so the label becomes secret-FP,
FP being the fingerprint."
  (mapcar (lambda (secret)
            (if (> (harness-redaction-count (plist-get secret :label) secrets) 0)
                (plist-put (copy-sequence secret) :label
                           (format "secret-%s" (plist-get secret :fingerprint)))
              secret))
          secrets))

(defun harness-redact--safe-reason (reason secrets)
  "Return REASON, a string, on one line, or nil.
It is withheld when it holds a value of SECRETS."
  (when (and (stringp reason) (not (string-blank-p reason)))
    (if (> (harness-redaction-count reason secrets) 0)
        harness-redact--withheld-reason
      (truncate-string-to-width
       (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " reason)) 500 nil nil "…"))))

;;;; The scope

(defun harness-redact--all-ids ()
  "Return the ids of every session, of any status and kind."
  (mapcar (lambda (s) (plist-get s :id)) (harness-call 'session/list)))

(defun harness-redact--session-id (name)
  "Return the id of the session NAME names: an id, or the start of one."
  (cond
   ((not (and (stringp name) (not (string-empty-p name))))
    (harness-redact--fail "A session is named by its id"))
   ((harness-call 'session/exists-p name) name)
   (t (let ((matches (cl-remove-if-not (lambda (id) (string-prefix-p name id))
                                       (harness-redact--all-ids)))
            (shown (truncate-string-to-width name 40 nil nil "…")))
        (cond ((null matches) (harness-redact--fail "No session %s" shown))
              ((cdr matches) (harness-redact--fail "Several sessions start with %s" shown))
              (t (car matches)))))))

(defun harness-redact--id-list (value)
  "Return VALUE, a session id or a list or vector of them, as a list of strings."
  (cond ((null value) nil)
        ((stringp value) (list value))
        ((or (listp value) (vectorp value))
         (let ((ids (append value nil)))
           (unless (cl-every #'stringp ids) (harness-redact--fail "The sessions are a list of ids"))
           ids))
        (t (harness-redact--fail "The sessions are a list of ids"))))

(defun harness-redact--family (ids include-forks)
  "Return IDS, session ids, each followed by its forks when INCLUDE-FORKS."
  (let ((seen (make-hash-table :test 'equal)) out)
    (dolist (id ids)
      (dolist (member (if include-forks (harness-call 'session/family-ids id) (list id)))
        (unless (gethash member seen)
          (puthash member t seen)
          (push member out))))
    (nreverse out)))

(defun harness-redact--dir (dir)
  "Return DIR as a directory name, expanded, with a slash."
  (file-name-as-directory (expand-file-name dir)))

(defun harness-redact--main-dir (dir cache)
  "Return the main checkout of the project of DIR, in the table CACHE."
  (let ((dir (harness-redact--dir dir)))
    (or (gethash dir cache)
        (puthash dir (or (ignore-errors (harness-redact--dir (harness-files-main-root dir))) dir)
                 cache))))

(defun harness-redact--project-ids (project)
  "Return the ids of the sessions of the project at PROJECT.
A session belongs to it when its project, or the main checkout of that
project (a task's worktree belongs to the project it merges into), is
PROJECT's, or its working directory lies under PROJECT."
  (let* ((cache (make-hash-table :test 'equal))
         (root (harness-redact--dir project))
         (main (harness-redact--main-dir root cache))
         (ids nil))
    (dolist (s (harness-call 'session/list))
      (let ((p (plist-get s :project))
            (cwd (plist-get s :cwd)))
        (when (or (and (stringp p)
                       (or (equal (harness-redact--dir p) root)
                           (equal (harness-redact--main-dir p cache) main)))
                  (and (stringp cwd) (not (file-remote-p cwd))
                       (file-in-directory-p (harness-redact--dir cwd) root)))
          (push (plist-get s :id) ids))))
    (nreverse ids)))

(defun harness-redact--scope-ids (scope params include-forks)
  "Return (IDS . TEXT): the sessions of SCOPE as PARAMS name them, and TEXT.
TEXT describes the scope.  INCLUDE-FORKS says whether the forks of those
sessions are in it too.  TEXT then says \"and its forks\" of the one
session named, \"and their forks\" of several: a session named twice is
one.  Signal an error when PARAMS lack what SCOPE needs."
  (pcase scope
    ('all (let ((ids (harness-redact--all-ids)))
            (cons ids (format "all sessions (%s)" (harness-redact--n (length ids) "session")))))
    ('project
     (let ((project (plist-get params :project)))
       (unless (and (stringp project) (not (string-blank-p project)))
         (harness-redact--fail "The scope project needs the project's directory (:project)"))
       (let ((ids (harness-redact--family (harness-redact--project-ids project) include-forks)))
         (cons ids (format "project %s (%s)" (abbreviate-file-name (harness-redact--dir project))
                           (harness-redact--n (length ids) "session"))))))
    (_
     (let ((named (cl-remove-duplicates
                   (mapcar #'harness-redact--session-id
                           (harness-redact--id-list (plist-get params :sessions)))
                   :test #'equal :from-end t)))
       (unless named
         (harness-redact--fail "The scope session needs the sessions (:sessions)"))
       (let ((ids (harness-redact--family named include-forks)))
         (cons ids (format "%s%s (%s)"
                           (mapconcat (lambda (id) (format "session %s" (harness-redact--short-id id)))
                                      (take 5 named) ", ")
                           (concat (if (> (length named) 5) (format " and %d more" (- (length named) 5)) "")
                                   (cond ((not include-forks) ", forks left out")
                                         ((cdr named) " and their forks")
                                         (t " and its forks")))
                           (harness-redact--n (length ids) "session"))))))))

;;;; Preparing a request

(defun harness-redact--prepare (params)
  "Return the run that PARAMS ask for; signal when they ask for nothing sound.
The secrets are read here, from where PARAMS say they are."
  (let* ((p (harness-redact--plist params "The redaction parameters"))
         (unknown (cl-remove-if (lambda (k) (memq k harness-redact--param-keys))
                                (harness-plist-keys p))))
    (when unknown
      (harness-redact--fail "Unknown redaction parameter(s): %s"
                            (mapconcat (lambda (k) (truncate-string-to-width
                                                    (substring (symbol-name k) 1) 40))
                                       (take 5 unknown) ", ")))
    (unless (plist-get p :scope)
      (harness-redact--fail "The scope is required: session, project or all"))
    (let* ((mode (harness-redact--symbol (or (plist-get p :mode) 'scan) "The mode" '(scan redact)))
           (scope (harness-redact--symbol (plist-get p :scope) "The scope" '(session project all)))
           (include-forks (if (plist-member p :include-forks)
                              (harness-json-true-p (plist-get p :include-forks))
                            t))
           (origin (harness-redact--origin (plist-get p :origin)))
           (ref (harness-redact--reference (plist-get p :source) (plist-get p :label)
                                           (harness-json-true-p (plist-get p :allow-unsafe-sources))))
           (resolved (harness-redaction-resolve ref))
           (secrets (harness-redact--safe-secrets (plist-get resolved :secrets)))
           (reason (harness-redact--safe-reason (plist-get p :reason) secrets))
           (input (plist-get p :input-text))
           (scoped (harness-redact--scope-ids scope p include-forks))
           (ids (car scoped))
           (text (cdr scoped))
           (origin-id (and (eq (plist-get origin :kind) 'session) (plist-get origin :id)))
           (note nil))
      ;; The call that asked may have carried the secret in its input: it
      ;; is in the transcript of the session that made it.
      (when (and origin-id (stringp input) (> (harness-redaction-count input secrets) 0)
                 (harness-call 'session/exists-p origin-id))
        (setq note (format "The request itself held the secret, so session %s, which made it, is included"
                           (harness-redact--short-id origin-id)))
        (unless (member origin-id ids)
          (setq ids (harness-redact--family (append ids (list origin-id)) include-forks)
                text (format "%s and session %s" text (harness-redact--short-id origin-id)))))
      (harness-redact--make-run
       :mode mode :secrets secrets :ref (harness-redact--public-ref ref secrets)
       :scope scope :scope-text text :project (plist-get p :project) :ids ids
       :origin origin :origin-note note :reason reason
       :skipped (or (plist-get resolved :skipped) 0)))))

;;;; Sessions: node logs, memory, records

(defun harness-redact--running-p (sid)
  "Non-nil when session SID runs a turn."
  (and (harness-method-exists-p 'agent/running) (harness-call 'agent/running sid) t))

(defun harness-redact--names (keys)
  "Return the keywords KEYS as names, without the colon, sorted."
  (sort (mapcar (lambda (k) (string-remove-prefix ":" (format "%s" k))) keys) #'string<))

(defun harness-redact--session-result (run sid)
  "Return the result of `session/redact-text' on session SID for RUN.
With several secrets, one of them found, the count of each on its own
comes with it, as `:secret-counts': conses of a fingerprint and a count."
  (let* ((secrets (harness-redact-run-secrets run))
         (several (cdr secrets))
         (dry (harness-redact-run-dry-p run))
         (probe (and (or dry several) (harness-call 'session/redact-text sid secrets t)))
         (counts (and probe several (plist-get probe :hit)
                      (mapcar (lambda (s)
                                (cons (plist-get s :fingerprint)
                                      (plist-get (harness-call 'session/redact-text sid (list s) t)
                                                 :count)))
                              secrets)))
         (result (cond (dry probe)
                       ((and probe (not (plist-get probe :hit))) probe)
                       (t (harness-call 'session/redact-text sid secrets nil)))))
    (append result (and counts (list :secret-counts counts)))))

(defun harness-redact--stage-sessions (run)
  "Take the secrets out of the node log, memory and record of each session of RUN."
  (dolist (sid (harness-redact-run-ids run))
    (when (harness-call 'session/exists-p sid)
      (condition-case err
          (let ((result (harness-redact--session-result run sid)))
            (when (plist-get result :hit)
              (harness-redact--credit-session run sid result)))
        (error
         (harness-redact-entry-put
          run sid :error (format "its stores could not be cleaned: %s" (harness-redact--error-text err)))
         (harness-redact--note-error run (format "session %s" (harness-redact--short-id sid)) err))))))

(defun harness-redact--credit-session (run sid result)
  "Put RESULT, what `session/redact-text' found in SID, in its entry in RUN."
  (cl-flet ((put (key value) (harness-redact-entry-put run sid key value)))
    (put :log (plist-get result :log-count))
    (put :memory (plist-get result :memory-count))
    (put :record (plist-get result :record-count))
    (put :nodes (plist-get result :nodes))
    (put :kinds (plist-get result :kinds))
    (put :fields (plist-get result :fields))
    (put :record-fields (plist-get result :record-fields))
    (put :running (plist-get result :running))
    (put :secret-counts (plist-get result :secret-counts))
    (put :checkpoints (plist-get result :checkpoints))
    (put :spill-files (plist-get result :spill-files))
    (when (plist-get result :file)
      (put :log-file (plist-get result :file)))
    ;; The nodes are what a new conversation is made from, and what a
    ;; provider conversation may hold: when the node log or the nodes in
    ;; memory held the secret, it starts over.  A hit only in the record
    ;; (queue, name, todos, plan, ext, pending, move) is no reason: no
    ;; provider conversation was sent those, and a new one is made from the
    ;; nodes, so a reset would only throw the conversation and its prompt
    ;; cache away for nothing.
    (when (> (+ (or (plist-get result :log-count) 0) (or (plist-get result :memory-count) 0))
             0)
      (put :provider-target t))))

;;;; The search index

(defun harness-redact--stage-search (run)
  "Find the secrets of RUN in the search index: the rows, by session.
Reading the logs again comes after the providers are reset
\(`harness-redact--stage-reindex'), which rewrites logs too."
  (when (harness-method-exists-p 'session/search-redact)
    (let* ((scope (if (eq (harness-redact-run-scope run) 'all) t (harness-redact-run-ids run)))
           (probe (harness-call 'session/search-redact scope (harness-redact-run-secrets run) t)))
      (if (not (plist-get probe :available))
          (harness-redact-add-store
           run (list :store "search index" :available :false :reason (plist-get probe :reason))
           (list (format "Search index: not available (%s)." (plist-get probe :reason))))
        (let ((rows (plist-get probe :sessions)))
          (dolist (row rows)
            (harness-redact-entry-put run (car row) :search (cdr row)))
          (harness-redact-run-set-prop run :search-rows (mapcar #'car rows))
          (harness-redact-run-set-prop run :search-available t)
          (when (> (plist-get probe :rows) 0)
            (harness-redact-run-set-prop run :search-touched t))
          (harness-redact-add-store
           run (list :store "search index" :available t :rows (plist-get probe :rows)
                     :sessions (mapcar (lambda (c) (list :session (car c) :rows (cdr c))) rows))
           (list (format "Search index: %s %s, in %s."
                         (harness-redact--n (plist-get probe :rows) "row")
                         (if (eql (plist-get probe :rows) 1) "holds a secret" "hold secrets")
                         (harness-redact--n (length rows) "session")))))))))

(defun harness-redact--stage-reindex (run)
  "Have the search index read the logs RUN rewrote again, from their start.
These are the logs the secrets were taken out of, and those the provider
reset rewrote without checkpoints, and the sessions the index held a
secret of: the offset the index recorded for each is wrong now."
  (when (and (harness-redact-run-prop run :search-available)
             (harness-method-exists-p 'session/search-redact))
    (let ((again (cl-remove-if-not
                  (lambda (sid) (harness-call 'session/exists-p sid))
                  (delete-dups
                   (append (cl-remove-if-not
                            (lambda (sid) (or (> (harness-redact--count run sid :log) 0)
                                              (plist-get (harness-redact-entry run sid) :log-rewritten)))
                            (reverse (harness-redact-run-order run)))
                           (harness-redact-run-prop run :search-rows)
                           nil)))))
      (when again
        (let ((result (harness-call 'session/search-redact again (harness-redact-run-secrets run) nil)))
          (harness-redact-update-store
           run "search index"
           :reindexed (plist-get result :reindexed)
           :failed (mapcar (lambda (f) (list :session (car f) :reason (cdr f)))
                           (plist-get result :failed)))
          (when (plist-get result :reindexed)
            (harness-redact-run-set-prop run :search-touched t))
          (harness-redact-add-lines
           run (list (format "Search index: the logs of %s were read again."
                             (harness-redact--n (length (plist-get result :reindexed)) "session")))))))))

;;;; The CLI logs of hosted providers

(defun harness-redact--log-checkpoint-ids (sid)
  "Return the CLI session ids the checkpoints on the nodes of session SID name.
They are read from the node log as text, without parsing it."
  (let ((path (expand-file-name (format "sessions/%s.nodes.jsonl" sid) harness-state-directory))
        (needle "\"cli-session-id\":\"")
        ids)
    (when (file-regular-p path)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path)
        (goto-char (point-min))
        (while (search-forward needle nil t)
          (let ((start (point)))
            (when (re-search-forward "\\=[^\"\\\\]+\"" nil t)
              (cl-pushnew (buffer-substring-no-properties start (1- (point))) ids :test #'equal))))))
    (nreverse ids)))

(defun harness-redact--session-cli-ids (run sid key)
  "Return the CLI conversations session SID has, for the provider state KEY.
That is the one its provider state names, and for KEY `:cli-session-id'
those its nodes' checkpoints name (a fork's, until it forks).  RUN has the
checkpoints of a session in which a secret was found."
  (let ((ids nil))
    (when-let* ((state (ignore-errors (plist-get (harness-call 'session/get sid) :provider-state)))
                ((consp state))
                (id (plist-get state key))
                ((stringp id)))
      (push id ids))
    (when (eq key :cli-session-id)
      (dolist (id (append (harness-redact--log-checkpoint-ids sid)
                          (cl-loop for cp in (plist-get (harness-redact-entry run sid) :checkpoints)
                                   for id = (and (consp cp) (plist-get cp :cli-session-id))
                                   when (stringp id) collect id)))
        (push id ids)))
    (nreverse (delete-dups ids))))

(defun harness-redact--cli-table (run key)
  "Return a table: session id -> its CLI conversations, for the sessions of RUN.
KEY says which provider's (see `harness-redact--session-cli-ids').
Nil for the scope all, where the files are not picked by id."
  (unless (eq (harness-redact-run-scope run) 'all)
    (let ((table (make-hash-table :test 'equal)))
      (dolist (sid (harness-redact-run-ids run))
        (puthash sid (harness-redact--session-cli-ids run sid key) table))
      table)))

(defun harness-redact--cli-ids (run table prop)
  "Return the CLI conversations to look in for RUN: t for all, else a list of ids.
They are those of TABLE, the sessions in scope (nil: the scope is all),
and those a re-run remembered under PROP."
  (if (null table)
      t
    (let (ids)
      (maphash (lambda (_sid cli) (setq ids (append cli ids))) table)
      (delete-dups (append (harness-redact-run-prop run prop) ids)))))

(defun harness-redact--file-lines (store files)
  "Return the lines of a report about the log FILES of the store called STORE."
  (let ((shown (take harness-redact--files-limit files)))
    (append
     (mapcar (lambda (f)
               (format "  %s: %s, %s%s" (abbreviate-file-name (plist-get f :file))
                       (harness-redact--n (plist-get f :count) "occurrence")
                       (plist-get f :status)
                       (if (plist-get f :error) (format " (%s)" (plist-get f :error)) "")))
             shown)
     (and (> (length files) (length shown))
          (list (format "  and %d more %s file(s)" (- (length files) (length shown)) store))))))

(defun harness-redact--stage-cli (run method name ids-key ids-prop attribution)
  "Take the secrets of RUN out of the log files of a hosted provider, by METHOD.
NAME is the store's, IDS-KEY the key of its conversation id in a provider
state, IDS-PROP where a re-run keeps the ids it remembers, and
ATTRIBUTION the key of the entries that count its occurrences."
  (when (harness-method-exists-p method)
    (let* ((table (harness-redact--cli-table run ids-key))
           (ids (harness-redact--cli-ids run table ids-prop))
           (dry (harness-redact-run-dry-p run)))
      ;; Remembered, so that the verification looks in the same conversations
      ;; after the sessions that held them were reset, and name them no more.
      (unless (eq ids t) (harness-redact-run-set-prop run ids-prop ids))
      (when (or (eq ids t) ids)
        (let* ((result (harness-call method (harness-redact-run-secrets run) ids dry))
               (files (plist-get result :files))
               (unowned nil))
          (dolist (f files)
            (unless (harness-redact--credit-file run f attribution table)
              (push f unowned)))
          (harness-redact-add-store
           run (append (list :store name :directory (plist-get result :directory)
                             :scanned (plist-get result :scanned) :count (plist-get result :count)
                             :files (mapcar #'harness-redact--file-view files))
                       (let ((left (and (not dry) (harness-redact--cli-left (nreverse unowned)))))
                         (and left (list :left left))))
           (cons (format "%s (%s): %s looked at, %s in %s."
                         name (abbreviate-file-name (or (plist-get result :directory) ""))
                         (harness-redact--n (or (plist-get result :scanned) 0) "file")
                         (harness-redact--n (or (plist-get result :count) 0) "occurrence")
                         (harness-redact--n (length files) "file"))
                 (harness-redact--file-lines name files))))))))

(defun harness-redact--file-view (f)
  "Return F, a file entry of a CLI log store, as the report shows it."
  (list :file (plist-get f :file) :cli-session (plist-get f :cli-session)
        :owners (plist-get f :owners) :count (plist-get f :count)
        :status (plist-get f :status) :error (plist-get f :error)))

(defun harness-redact--credit-file (run f attribution table)
  "Credit the sessions the log file entry F belongs to in RUN with its occurrences.
ATTRIBUTION is the key to count under; TABLE says which conversations
each session in scope has (`harness-redact--cli-table'), nil for the
scope all.  The owners of a file that holds a secret, and the sessions
whose nodes name its conversation, are sessions whose provider
conversation held it: their provider starts over, in or out of the
scope.  Return non-nil when a session was credited."
  (let ((count (or (plist-get f :count) 0))
        (status (plist-get f :status))
        (file (plist-get f :file))
        (cli (plist-get f :cli-session))
        (owners (plist-get f :owners))
        (credited nil))
    (when (> count 0)
      ;; A list of its own: `cl-remove-if-not' answers the list it was given when
      ;; it takes nothing out of it, and `delete-dups' would then cut the
      ;; sessions of the run itself, and the stores after this one would
      ;; skip them.
      (let ((sessions (delete-dups
                       (append owners
                               (and table cli
                                    (cl-remove-if-not (lambda (sid) (member cli (gethash sid table)))
                                                      (harness-redact-run-ids run)))
                               nil))))
        (dolist (sid sessions)
          (when (harness-call 'session/exists-p sid)
            (setq credited t)
            (harness-redact-entry-incr run sid attribution count)
            (harness-redact-entry-add run sid :cli-files (list file))
            (when (eq status 'redacted)
              (harness-redact-entry-add run sid :files (list file)))
            (when (memq status '(deferred busy binary error))
              (harness-redact-entry-add run sid :left (list file)))
            (harness-redact-entry-put run sid :provider-target t)))))
    credited))

(defun harness-redact--cli-left (files)
  "Return what a redaction left in the provider log FILES no session owns.
FILES are the entries (`harness-redact--file-view') of those still
holding a secret.  A file a session owns is counted in that session's
entry (`harness-redact--credit-file'); one nobody owns, which is busy
\(a process may be writing it), binary or unreadable, would be forgotten
otherwise and the redaction called done with the secret in it."
  (delq nil
        (mapcar (lambda (f)
                  (when (memq (plist-get f :status) '(deferred busy binary error))
                    (format "%s: found, left alone (%s); no session of the harness owns it"
                            (abbreviate-file-name (plist-get f :file))
                            (pcase (plist-get f :status)
                              ('busy "written in the last minute, so a process may be writing it")
                              ('binary "a binary file")
                              ('deferred "its session runs a turn")
                              (_ (or (plist-get f :error) "it could not be cleaned"))))))
                files)))

(defun harness-redact--stage-claude (run)
  "Take the secrets of RUN out of the conversation logs of Claude Code."
  (harness-redact--stage-cli run 'provider/claude-redact-logs "Claude Code logs"
                             :cli-session-id :claude-ids :claude))

(defun harness-redact--stage-copilot (run)
  "Take the secrets of RUN out of the session state of the Copilot CLI."
  (harness-redact--stage-cli run 'provider/copilot-redact-logs "Copilot logs"
                             :copilot-session-id :copilot-ids :copilot))

;;;; Task records

(defun harness-redact--task-session (id)
  "Return the id of the session of task ID, or nil."
  (condition-case nil
      (plist-get (harness-call 'task/get id) :session)
    (error nil)))

(defun harness-redact--stage-tasks (run)
  "Take the secrets of RUN out of the task records: all, or a project's.
A scope of sessions leaves the tasks alone."
  (when (and (harness-method-exists-p 'task/redact)
             (memq (harness-redact-run-scope run) '(all project)))
    (let* ((project (and (eq (harness-redact-run-scope run) 'project) (harness-redact-run-project run)))
           (result (harness-call 'task/redact (harness-redact-run-secrets run) project
                                 (harness-redact-run-dry-p run)))
           (tasks (plist-get result :tasks))
           (files (plist-get result :files))
           (scoped (harness-redact-run-ids run)))
      (dolist (task tasks)
        (when-let* ((sid (harness-redact--task-session (plist-get task :id)))
                    ((member sid scoped)))
          (harness-redact-entry-incr run sid :tasks (or (plist-get task :count) 0))))
      (harness-redact-add-store
       run (list :store "task records" :count (plist-get result :count)
                 :tasks (mapcar (lambda (task)
                                  (list :id (plist-get task :id) :count (plist-get task :count)
                                        :fields (harness-redact--names (plist-get task :fields))))
                                tasks)
                 :files (mapcar (lambda (f) (list :file (plist-get f :file) :count (plist-get f :count))) files)
                 :stores (mapcar (lambda (s) (list :file (plist-get s :file) :count (plist-get s :count)
                                                   :foreign (and (plist-get s :foreign) t)))
                                 (plist-get result :stores)))
       (list (format "Task records: %s in %s%s."
                     (harness-redact--n (or (plist-get result :count) 0) "occurrence")
                     (harness-redact--n (length tasks) "task")
                     (if files (format ", and %s of a copy of the task store"
                                       (harness-redact--n (apply #'+ (mapcar (lambda (f) (plist-get f :count)) files))
                                                          "occurrence"))
                       "")))))))

;;;; Transcript, spill and state files

;; A file is counted by its bytes first (`harness-redaction-file-count'),
;; which clears nearly all of them without decoding a character, and read
;; and rewritten (`harness-redaction-file') only when it holds a copy: the
;; read and the write have nothing between them that can yield, and the
;; file is replaced by a rename, so a reader of the file, and an append of
;; this process, never see half of it.  A module that keeps a file's
;; content in memory (the task board's records, say) may write it again
;; later; the verification at the end of the request is what shows it.

(defun harness-redact--under-p (file dir)
  "Non-nil when FILE lies under the directory DIR, links resolved."
  (file-in-directory-p (file-truename file) (file-truename dir)))

(defun harness-redact--walk (root &optional skip)
  "Return (FILES . UNREADABLE): what lies under the directory ROOT, however deep.
FILES are the files, links to files and to directories among them (a link
is never followed, so it is for the caller to count); UNREADABLE are the
directories that could not be listed, which do not stop the walk.  SKIP,
a function of a directory's name, says that one is left out."
  (let ((stack (list root)) files unreadable)
    (while stack
      (let ((dir (pop stack)))
        (condition-case nil
            (dolist (entry (directory-files dir t directory-files-no-dot-files-regexp t))
              (cond ((file-symlink-p entry) (push entry files))
                    ((file-directory-p entry)
                     (unless (and skip (funcall skip entry)) (push entry stack)))
                    (t (push entry files))))
          (file-error (push dir unreadable)))))
    (cons (sort files #'string<) (nreverse unreadable))))

(defun harness-redact--own (owners file sid)
  "Note in the table OWNERS that FILE is named by session SID, which may be nil.
OWNERS maps the true name of a file to the ids of the sessions that name
it.  Return t when FILE is noted, `link' when it is a link, which is
never followed (it may lead to a file that is the secret's own home), and
nil when it is no regular file."
  (cond ((file-symlink-p file) 'link)
        ((not (file-regular-p file)) nil)
        (t (let ((key (file-truename file)))
             (puthash key (if sid
                              (cl-adjoin sid (gethash key owners) :test #'equal)
                            (gethash key owners))
                      owners)
             t))))

(defun harness-redact--source-file (run)
  "Return the true name of the file the secrets of RUN were read from, or nil."
  (let ((file (plist-get (harness-redact-run-ref run) :file)))
    (and (stringp file) (file-truename file))))

(defun harness-redact--binary-reason (file)
  "Return what to call FILE, which cannot be rewritten as text."
  (if (string-match-p "\\.\\(?:db\\|sqlite3?\\)\\(?:-wal\\|-shm\\|-journal\\)?\\'" file)
      "a SQLite database"
    "a binary file"))

(defun harness-redact--written-lately-p (file seconds)
  "Non-nil when FILE was written less than SECONDS seconds ago."
  (let ((time (file-attribute-modification-time (file-attributes (file-truename file)))))
    (and time (< (float-time (time-since time)) seconds))))

(defun harness-redact--sweep-file (run file style &optional quiet)
  "Look in FILE for the secrets of RUN, and take them out unless RUN only scans.
STYLE is how FILE is read: `text', `json' or `jsonl'.  Return nil when
FILE holds none, else its entry, (:file FILE :count N :status STATUS),
with :error WHY when the status has a reason.  STATUS is `redacted';
`found' (a scan: the file would be); `busy' (it was written in the last
QUIET seconds, so a process may be at work in it: it is left alone);
`not-redacted' (found, but it cannot be rewritten: it is binary, a SQLite
database, over 64 MiB, or not text that can be written again) or `failed'
\(it could not be read or written).  Nothing of the file's text goes in
the entry."
  (let ((secrets (harness-redact-run-secrets run))
        (dry (harness-redact-run-dry-p run))
        (count 0))
    (condition-case err
        (progn
          (setq count (harness-redaction-file-count file secrets))
          (when (> count 0)
            (cond
             ((> (or (harness-file-size file) 0) harness-redact--sweep-limit)
              (list :file file :count count :status 'not-redacted
                    :error (format "larger than %s"
                                   (file-size-human-readable harness-redact--sweep-limit 'iec " "))))
             ((and quiet (harness-redact--written-lately-p file quiet))
              (list :file file :count count :status 'busy
                    :error (format "written in the last %d seconds; a process may be writing it" quiet)))
             (t
              (let* ((result (harness-redaction-file file secrets :style style :dry-run dry))
                     (found (plist-get result :count)))
                (cond
                 ((plist-get result :binary)
                  (list :file file :count found :status 'not-redacted
                        :error (harness-redact--binary-reason file)))
                 (dry (list :file file :count (if (> found 0) found count) :status 'found))
                 ((plist-get result :changed)
                  (list :file file :count found :status 'redacted))
                 (t (list :file file :count count :status 'not-redacted
                          :error "not text that can be written again"))))))))
      (harness-redaction-changed
       (list :file file :count count :status 'failed :error "it kept changing while it was processed"))
      (error
       (list :file file :count count :status 'failed :error (harness-redact--error-text err))))))

(defun harness-redact--sweep-left (entry)
  "Return what a redaction left in the file of ENTRY, a string, or nil if nothing."
  (pcase (plist-get entry :status)
    ('not-redacted (format "%s: found, not redacted (%s)"
                           (abbreviate-file-name (plist-get entry :file)) (plist-get entry :error)))
    ('busy (format "%s: left alone, found (%s)"
                   (abbreviate-file-name (plist-get entry :file)) (plist-get entry :error)))
    ('failed (format "%s: could not be read or written (%s)"
                     (abbreviate-file-name (plist-get entry :file)) (plist-get entry :error)))))

(defun harness-redact--sweep-lines (entries)
  "Return the lines of a report about the file ENTRIES of a sweep."
  (let ((shown (take harness-redact--files-limit entries)))
    (append
     (mapcar (lambda (e)
               (format "  %s: %s, %s%s"
                       (abbreviate-file-name (plist-get e :file))
                       (harness-redact--n (plist-get e :count) "occurrence")
                       (pcase (plist-get e :status)
                         ('redacted "redacted")
                         ('found "found")
                         ('not-redacted "found, not redacted")
                         ('busy "found, left alone")
                         (_ "not cleaned"))
                       (if (plist-get e :error) (format " (%s)" (plist-get e :error)) "")))
             shown)
     (and (> (length entries) (length shown))
          (list (format "  and %d more file(s)" (- (length entries) (length shown))))))))

(defun harness-redact--credit-sweep (run entry sids key)
  "Credit SIDS, which name the file of ENTRY, with its occurrences in RUN.
KEY is the count to credit, a keyword.  A file that was redacted is among
the files each session changed."
  (when (> (plist-get entry :count) 0)
    (dolist (sid sids)
      (when (harness-call 'session/exists-p sid)
        (harness-redact-entry-incr run sid key (plist-get entry :count))
        (when (eq (plist-get entry :status) 'redacted)
          (harness-redact-entry-add run sid :files (list (plist-get entry :file))))))))

(defun harness-redact--file-store (run name owners style key &optional notes extras)
  "Look in the files of OWNERS for the secrets of RUN; report store NAME.
OWNERS maps the true name of each file to the sessions that name it
\(`harness-redact--own').  STYLE is how a file is read -- `text', `json'
or `jsonl' -- or a function of the file name that says.  KEY, a keyword
or nil, is the count with which the sessions that name a file that holds
a secret are credited.  NOTES are lines for the text of the report, after
the store's own -- or a function of the file entries that gives them --
and EXTRAS more keys for the store; `:unreadable' among them lists the
directories that could not be looked in, which a redaction leaves unclean,
and `:quiet' (not kept) the seconds a file has to be left alone to be
rewritten (`harness-redact--sweep-file').  Return the store."
  (let ((source (harness-redact--source-file run))
        (dry (harness-redact-run-dry-p run))
        (quiet (plist-get extras :quiet))
        (extras (harness-plist-remove extras :quiet))
        (scanned 0) (entries nil) (kept nil))
    (dolist (file (sort (hash-table-keys owners) #'string<))
      (if (equal file source)
          (setq kept t)
        (cl-incf scanned)
        (when-let* ((entry (harness-redact--sweep-file
                            run file (if (memq style '(text json jsonl)) style (funcall style file))
                            quiet)))
          (let ((sids (gethash file owners)))
            (push (if sids (append entry (list :sessions sids)) entry) entries)
            (when key (harness-redact--credit-sweep run entry sids key))))))
    (setq entries (nreverse entries))
    (let ((count (apply #'+ (mapcar (lambda (e) (plist-get e :count)) entries)))
          (unreadable (plist-get extras :unreadable)))
      (harness-redact-add-store
       run
       (append (harness-redact--compact
                (list :store name :scanned scanned :count count :files entries
                      :left (and (not dry)
                                 (append (delq nil (mapcar #'harness-redact--sweep-left entries))
                                         (mapcar (lambda (d) (format "%s: could not be looked in"
                                                                     (abbreviate-file-name d)))
                                                 unreadable)))
                      :source-kept kept))
               extras)
       (append
        (list (format "%s: %s looked at, %s in %s."
                      (concat (upcase (substring name 0 1)) (substring name 1))
                      (harness-redact--n scanned "file") (harness-redact--n count "occurrence")
                      (harness-redact--n (length entries) "file")))
        (harness-redact--sweep-lines entries)
        (and kept (list "  The file the secret was read from is left as it is."))
        (and unreadable
             (list (format "  %s could not be looked in: %s." (harness-redact--n (length unreadable) "directory" "directories")
                           (mapconcat #'abbreviate-file-name (take 5 unreadable) ", "))))
        (if (functionp notes) (funcall notes entries) notes))))))

;;;; Transcript files

(defun harness-redact--note-line-p ()
  "Non-nil when the log line at point is the node of a compaction or a handoff.
Those are the nodes that name a transcript file they wrote; a tool result
that lists a path, as the report of a scan does, is not one, and a
session is not the owner of every file its tools printed the name of.
The line is searched as bytes for the keys of such a node.  Quotes in a
string are escaped in the log, so neither key can come from text."
  (let ((beg (pos-bol)) (end (pos-eol)))
    (save-excursion
      (or (progn (goto-char beg) (search-forward "\"kind\":\"compaction\"" end t))
          (progn (goto-char beg) (search-forward "\"handoff\":{" end t))))))

(defun harness-redact--scan-log-references (sid)
  "Return (TRANSCRIPTS . SPILLS): the files the node log of session SID names.
TRANSCRIPTS are the paths of transcript files in a `.harness/transcripts/'
or `.harness/handoff/' directory, which the note of a compaction or a
handoff gives (`harness-redact--note-line-p'); SPILLS those a cut tool
output says it was saved to.  The log is read as bytes and searched for
the places where such a path is, without parsing a line, so looking
through a thousand sessions is quick.  A path with a quote, a backslash
or a line break in it is not found."
  (let ((log (expand-file-name (format "sessions/%s.nodes.jsonl" sid) harness-state-directory))
        transcripts spills)
    (when (file-regular-p log)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally log)
        (goto-char (point-min))
        (while (search-forward "/.harness/" nil t)
          (let ((marker (match-beginning 0)))
            (when (looking-at "\\(?:transcripts\\|handoff\\)/[^\"\\\\/\n \t]+\\.md")
              (let ((end (match-end 0)))
                (when (save-excursion (goto-char marker) (harness-redact--note-line-p))
                  (let ((start (save-excursion
                                 (goto-char marker)
                                 (skip-chars-backward "^\"\\\\\n \t" (max (point-min) (- marker 4096)))
                                 (search-forward "/" (1+ marker) t)
                                 (1- (point)))))
                    (cl-pushnew (decode-coding-string (buffer-substring-no-properties start end) 'utf-8)
                                transcripts :test #'equal)))))))
        (goto-char (point-min))
        (while (search-forward "The full output was saved to " nil t)
          (let ((start (point)))
            (when (search-forward ". Read it in ranges" (min (point-max) (+ start 4096)) t)
              (let ((raw (buffer-substring-no-properties start (match-beginning 0))))
                (unless (string-match-p "[\"\\\\\n]" raw)
                  (cl-pushnew (decode-coding-string raw 'utf-8) spills :test #'equal))))))))
    (cons (nreverse transcripts) (nreverse spills))))

(defun harness-redact--references (run sid)
  "Return (TRANSCRIPTS . SPILLS) that the node log of SID names, kept in RUN."
  (let ((cache (or (harness-redact-run-prop run :references)
                   (harness-redact-run-set-prop run :references (make-hash-table :test 'equal)))))
    (or (gethash sid cache)
        (puthash sid
                 (condition-case err
                     (harness-redact--scan-log-references sid)
                   ;; The files it names are not looked for; the other sessions' are.
                   (error (harness-redact--note-error
                           run (format "reading the node log of session %s for the files it names"
                                       (harness-redact--short-id sid))
                           err)
                          (cons nil nil)))
                 cache))))

(defun harness-redact--transcript-files (sid cwd)
  "Return the transcript files named for session SID in the directories under CWD."
  (let ((pattern (format "\\`%s-.*\\.md\\'" (regexp-quote (harness-redact--short-id sid))))
        files)
    (dolist (relative harness-redact--transcript-directories)
      (let ((dir (expand-file-name relative cwd)))
        (when (file-directory-p dir)
          (setq files (append files (directory-files dir t pattern))))))
    files))

(defun harness-redact--stage-transcripts (run)
  "Take the secrets of RUN out of the transcript files of its sessions.
Compaction into a transcript and a handoff write the whole conversation
to a file in the directory of the session (`session/write-transcript'),
and the model is told to read it.  The files are those named for each
session in its directory, and those its nodes name, which a session that
moved and a fork, copying the nodes, have in another directory.  A
session on another host, or with a remote directory, has its files there:
they are not looked at, and the report says so."
  (let ((owners (make-hash-table :test 'equal)) (skipped nil) (links 0))
    (dolist (sid (harness-redact-run-ids run))
      (when (harness-call 'session/exists-p sid)
        (let* ((session (harness-call 'session/get sid))
               (cwd (plist-get session :cwd)))
          (if (or (plist-get session :host) (not (stringp cwd)) (file-remote-p cwd))
              (push sid skipped)
            (dolist (file (append (harness-redact--transcript-files sid cwd)
                                  (cl-remove-if #'file-remote-p (car (harness-redact--references run sid)))))
              (when (eq (harness-redact--own owners file sid) 'link) (cl-incf links)))))))
    (setq skipped (nreverse skipped))
    (let* ((who (and skipped
                     (format "%s on another host were not looked at: %s%s"
                             (harness-redact--n (length skipped) "session")
                             (mapconcat #'harness-redact--short-id (take 5 skipped) ", ")
                             (if (> (length skipped) 5) (format " and %d more" (- (length skipped) 5)) ""))))
           (store (harness-redact--file-store
                   run "transcript files" owners 'text :transcripts
                   (append
                    (and who (list (format "Transcript files of %s." who)))
                    (and (> links 0)
                         (list (format "  Links are never followed: %s skipped."
                                       (harness-redact--n links "transcript file")))))
                   (and skipped (list :skipped-sessions skipped)))))
      ;; What lies on another host may hold the secret: the redaction is not done.
      (when (and who (not (harness-redact-run-dry-p run)))
        (harness-redact-update-store
         run "transcript files"
         :left (append (plist-get store :left) (list (format "transcript files of %s" who)))))
      store)))

;;;; Spill files

(defun harness-redact--stage-spill (run)
  "Take the secrets of RUN out of the files that hold cut tool outputs whole.
A tool output longer than `harness-tools-max-output-chars' is cut in the
transcript and saved whole in a file in the outputs directory of the
state directory.  The files are those the nodes of the sessions of RUN
say they are saved to -- the whole output may hold what the cut one does
not -- and, for the scope all, every file under that directory.  A path
that is not under it is not touched."
  (let* ((outputs (file-name-as-directory (expand-file-name "outputs" harness-state-directory)))
         (owners (make-hash-table :test 'equal))
         (outside 0) (links 0) (unreadable nil))
    (cl-flet ((own (file sid)
                (cond ((file-remote-p file) (cl-incf outside))
                      ;; Before the place it leads to is looked at: a link is never followed.
                      ((file-symlink-p file) (cl-incf links))
                      ((not (harness-redact--under-p file outputs)) (cl-incf outside))
                      (t (harness-redact--own owners file sid)))))
      (dolist (sid (harness-redact-run-ids run))
        (dolist (file (append (plist-get (harness-redact-entry run sid) :spill-files)
                              (cdr (harness-redact--references run sid))))
          (when (stringp file) (own (expand-file-name file) sid))))
      (when (and (eq (harness-redact-run-scope run) 'all) (file-directory-p outputs))
        (pcase-let ((`(,files . ,bad) (harness-redact--walk outputs)))
          (setq unreadable bad)
          (dolist (file files)
            (own file nil)))))
    (harness-redact--file-store
     run "spill files" owners 'text :spill
     (append
      (and (> outside 0)
           (list (format "  %s outside the outputs directory, not touched."
                         (harness-redact--n outside "path is" "paths are"))))
      (and (> links 0)
           (list (format "  Links are never followed: %s skipped." (harness-redact--n links "spill file")))))
     (and unreadable (list :unreadable unreadable)))))

;;;; Session temp files

(defun harness-redact--session-temp-dir (sid)
  "Return the temporary directory of session SID to look in, or nil.
That is harness-UID/ID in the temporary directory, where the tools of the
session are told to put their scratch files (`session/tmp-dir').  It is
looked in only when it is there already -- nothing is made for a look --
and is a directory of the user's own, not a link."
  (when (and (fboundp 'harness-session-tmp-root)
             (string-match-p "\\`[A-Za-z0-9_-]+\\'" sid))
    (let* ((dir (expand-file-name sid (harness-session-tmp-root)))
           (attrs (file-attributes dir 'integer)))
      (and attrs
           (eq t (file-attribute-type attrs))
           (eql (file-attribute-user-id attrs) (user-uid))
           (file-name-as-directory dir)))))

(defun harness-redact--stage-temp (run)
  "Take the secrets of RUN out of the temporary directories of its sessions.
A tool is told to keep its scratch files there, and a command that
saved what it printed (`terraform output > out.txt') left a copy.  The
files are read as text; a link is never followed, and a file written in
the last minute, which a process may be writing, is left alone (`busy').
Rewriting it by rename would leave that process writing into the old file."
  (let ((owners (make-hash-table :test 'equal)) (links 0) (unreadable nil))
    (dolist (sid (harness-redact-run-ids run))
      (when-let* ((dir (harness-redact--session-temp-dir sid)))
        (pcase-let ((`(,files . ,bad) (harness-redact--walk dir)))
          (setq unreadable (append unreadable bad))
          (dolist (file files)
            (when (eq (harness-redact--own owners file sid) 'link) (cl-incf links))))))
    (harness-redact--file-store
     run "session temp files" owners 'text :temp
     (and (> links 0)
          (list (format "  Links are never followed: %s skipped." (harness-redact--n links "file"))))
     (append (list :quiet harness-redact--quiet-seconds)
             (and unreadable (list :unreadable unreadable))))))

;;;; State files

(defun harness-redact--state-style (file)
  "Return how the state file FILE is read: `jsonl', `json' or `text'."
  (cond ((string-suffix-p ".jsonl" file) 'jsonl)
        ((string-suffix-p ".json" file) 'json)
        (t 'text)))

(defun harness-redact--orphan-session-files (root)
  "Return the files in the sessions directory under ROOT that no session owns.
A node log, or a record, of a session the harness did not load -- its
record would not parse, say -- is no session's to the first store, and
the sweep skips the directory (`harness-redact--state-skipped'): it would
keep its copy, and a redaction would be called done.  A file belongs to
the session its name starts with, up to the first dot."
  (let ((dir (expand-file-name "sessions/" root)))
    (when (file-directory-p dir)
      (cl-remove-if
       (lambda (file)
         (or (file-directory-p file)
             (harness-call 'session/exists-p
                           (car (split-string (file-name-nondirectory file) "\\.")))))
       (directory-files dir t directory-files-no-dot-files-regexp t)))))

(defun harness-redact--state-files ()
  "Return (FILES . UNREADABLE): the state files the sweep looks in.
Every file under it but those of the directories in
`harness-redact--state-skipped' and the search index's (search.db and
its write-ahead log, which the search module purges); and the files in
the sessions directory that no session owns
\(`harness-redact--orphan-session-files').  Links are for the caller to
count (`harness-redact--walk'); UNREADABLE are the directories that
could not be listed."
  (let* ((root (file-name-as-directory (expand-file-name harness-state-directory)))
         (skipped (mapcar (lambda (d) (directory-file-name (expand-file-name d root)))
                          harness-redact--state-skipped)))
    (when (file-directory-p root)
      (let ((walked (harness-redact--walk
                     root (lambda (dir) (member (directory-file-name dir) skipped)))))
        (cons (append
               (cl-remove-if
                (lambda (file)
                  (and (equal (file-name-directory file) root)
                       (string-match-p "\\`search\\.db" (file-name-nondirectory file))))
                (car walked))
               (harness-redact--orphan-session-files root))
              (cdr walked))))))

(defun harness-redact--stage-state (run)
  "Take the secrets of RUN out of the other files of the state directory.
Only for the scope all: a file there is no session's.  A `.json' file is
read as a document, a `.jsonl' file by its lines, and any other as text;
binary files, SQLite databases (usage.db) and files over 64 MiB are
counted and reported as found, not redacted."
  (when (eq (harness-redact-run-scope run) 'all)
    (let ((owners (make-hash-table :test 'equal)) (links 0)
          (walked (harness-redact--state-files)))
      (dolist (file (car walked))
        (when (eq (harness-redact--own owners file nil) 'link) (cl-incf links)))
      (harness-redact--file-store
       run "state files" owners #'harness-redact--state-style nil
       (lambda (entries)
         (append
          (and (> links 0)
               (list (format "  Links are never followed: %s skipped." (harness-redact--n links "file"))))
          ;; A module that has the file's content in memory writes that, not this.
          (and (cl-some (lambda (e) (eq (plist-get e :status) 'redacted)) entries)
               (list "  A module that keeps such a file in memory may write it again: scan again later to check."))))
       (and (cdr walked) (list :unreadable (cdr walked)))))))

;;;; Log buffers

(defun harness-redact--log-buffers ()
  "Return the buffers of this process that hold its logs.
That is *harness-log*, *Messages*, and every live buffer whose name
starts with \"*harness\" and that visits no file."
  (cl-remove-if-not
   (lambda (buffer)
     (let ((name (buffer-name buffer)))
       (and name
            (or (equal name "*Messages*") (string-prefix-p "*harness" name))
            (null (buffer-file-name buffer)))))
   (buffer-list)))

(defun harness-redact--stage-buffers (run)
  "Take the secrets of RUN out of the log buffers of this process.
A secret that a log line quoted stays in *harness-log* and *Messages*
until the buffer is cleaned (`harness-redaction-buffer').  Their text
properties stay, and so does a read-only buffer's mode."
  (let ((secrets (harness-redact-run-secrets run))
        (dry (harness-redact-run-dry-p run))
        (scanned 0) (found nil))
    (dolist (buffer (harness-redact--log-buffers))
      (cl-incf scanned)
      (let ((name (buffer-name buffer)))
        (condition-case err
            (let ((n (harness-redaction-buffer buffer secrets dry)))
              (when (> n 0)
                (push (list :buffer name :count n :status (if dry 'found 'redacted)) found)))
          (error (push (list :buffer name :count 0 :status 'failed :error (harness-redact--error-text err))
                       found)))))
    (setq found (nreverse found))
    (let ((count (apply #'+ (mapcar (lambda (b) (plist-get b :count)) found))))
      (harness-redact-add-store
       run
       (harness-redact--compact
        (list :store "log buffers" :scanned scanned :count count :buffers found
              :left (and (not dry)
                         (delq nil (mapcar (lambda (b)
                                             (when (eq (plist-get b :status) 'failed)
                                               (format "buffer %s: could not be cleaned (%s)"
                                                       (plist-get b :buffer) (plist-get b :error))))
                                           found)))))
       (cons (format "Log buffers: %s looked at, %s in %s."
                     (harness-redact--n scanned "buffer") (harness-redact--n count "occurrence")
                     (harness-redact--n (length found) "buffer"))
             (mapcar (lambda (b)
                       (format "  %s: %s, %s%s" (plist-get b :buffer)
                               (harness-redact--n (plist-get b :count) "occurrence")
                               (pcase (plist-get b :status) ('redacted "redacted") ('found "found") (_ "not cleaned"))
                               (if (plist-get b :error) (format " (%s)" (plist-get b :error)) "")))
                     (take harness-redact--files-limit found)))))))

;;;; The provider conversation

(defun harness-redact--session-keys (sid)
  "Return the names of the secrets pending for SID, (:label L :fingerprint F) each."
  (let (out)
    (dolist (item (gethash sid harness-redact--pending))
      (dolist (s (plist-get item :secrets))
        (cl-pushnew (list :label (plist-get s :label) :fingerprint (plist-get s :fingerprint))
                    out :test #'equal)))
    (nreverse out)))

(defun harness-redact--flag-pending (sid)
  "Tell the record of session SID which redactions wait for its turn to end."
  (harness-call 'session/set-ext sid :redaction-pending
                (and (gethash sid harness-redact--pending) (harness-redact--session-keys sid))))

(defun harness-redact--defer (run sid)
  "Keep the redaction of RUN for session SID until its running turn ends."
  (let ((item (list :secrets (harness-redact-run-secrets run)
                    :ref (harness-redact-run-ref run)
                    :origin (harness-redact-run-origin run)
                    :reason (harness-redact-run-reason run)
                    :claude-ids (harness-redact--session-cli-ids run sid :cli-session-id)
                    :copilot-ids (harness-redact--session-cli-ids run sid :copilot-session-id)))
        (fingerprints (lambda (item) (sort (mapcar (lambda (s) (plist-get s :fingerprint))
                                                   (plist-get item :secrets))
                                           #'string<))))
    ;; The same request twice waits once.
    (unless (cl-find (funcall fingerprints item) (gethash sid harness-redact--pending)
                     :key fingerprints :test #'equal)
      (puthash sid (append (gethash sid harness-redact--pending) (list item)) harness-redact--pending))
    (harness-redact--flag-pending sid)))

(defun harness-redact--uncovered-dirty-p (run sid)
  "Non-nil when session SID is outside the scope of RUN and holds a secret.
That is, its own stores hold one.  A session outside the request that
shares a provider conversation with one in it -- a fork left out, say --
has that conversation cleaned with the log they share, but its own
transcript is not.  A new conversation of it would be made from that
transcript, and send the secret again."
  (and (not (member sid (harness-redact-run-ids run)))
       (plist-get (harness-call 'session/redact-text sid (harness-redact-run-secrets run) t) :hit)
       t))

(defun harness-redact--stage-providers (run)
  "Reset the provider conversation of each session of RUN that may hold a secret.
A session running a turn waits for its end (`harness-redact--defer').
One whose transcript could not be cleaned is left alone: a new
conversation would be made from that transcript.  So is one that the
request did not cover, whose own transcript still holds the secret
\(`harness-redact--uncovered-dirty-p'), which keeps the conversation
as it is -- the log it shares was cleaned.  A reset that dropped the
session's prompt cache with the conversation says so
\(`session/reset-provider' answers `:cache-dropped'), and the entry keeps
that as `:cache-dropped'."
  (dolist (sid (reverse (harness-redact-run-order run)))
    (let ((entry (harness-redact-entry run sid)))
      (when (and (plist-get entry :provider-target) (harness-call 'session/exists-p sid))
        (cond
         ((plist-get entry :error)
          (harness-redact-entry-put run sid :provider 'failed))
         ((harness-redact--uncovered-dirty-p run sid)
          (harness-redact-entry-put run sid :provider 'kept))
         ((harness-redact--running-p sid)
          (harness-redact--defer run sid)
          (harness-redact-entry-put run sid :provider 'deferred))
         (t
          (condition-case err
              (let ((reset (harness-call 'session/reset-provider sid)))
                ;; Without its checkpoints the log is another file to the index.
                (when (> (or (plist-get reset :checkpoints) 0) 0)
                  (harness-redact-entry-put run sid :log-rewritten t))
                (when (harness-json-true-p (plist-get reset :cache-dropped))
                  (harness-redact-entry-put run sid :cache-dropped t))
                (harness-redact-entry-put run sid :provider 'reset))
            (error
             (harness-redact-entry-put run sid :provider 'failed)
             (harness-redact--note-error
              run (format "resetting the provider of session %s" (harness-redact--short-id sid)) err)))))))))

(defun harness-redact--stage-scan-providers (run)
  "Find in the scan RUN whose provider conversation a redaction would start over.
That is what `harness-redact--stage-providers' decides for a redaction,
without resetting anything: a session whose provider conversation held
the secret (`:provider-target'), that exists, whose stores could be read
\(no `:error'), and that the request covers, or whose own transcript is
clean.  Each gets `:would-reset' in its entry, and `:cache-would-drop'
when the reset would drop its prompt cache with it
\(`session/reset-drops-cache-p').  A session that runs a turn is counted:
its conversation starts over when the turn ends.  Nothing is changed.  A
session this cannot be asked of is left unmarked and logged, as the scan
goes on without it."
  (dolist (sid (reverse (harness-redact-run-order run)))
    (let ((entry (harness-redact-entry run sid)))
      (when (and (plist-get entry :provider-target) (not (plist-get entry :error)))
        (condition-case err
            (when (and (harness-call 'session/exists-p sid)
                       (not (harness-redact--uncovered-dirty-p run sid)))
              (harness-redact-entry-put run sid :would-reset t)
              (when (harness-json-true-p (harness-call 'session/reset-drops-cache-p sid))
                (harness-redact-entry-put run sid :cache-would-drop t)))
          (error
           (harness-log 'warn "redact: could not tell whether a reset of session %s drops its cache: %s"
                        (harness-redact--short-id sid) (harness-redact--error-text err))))))))

;;;; The search index, purged

(defun harness-redact--search-outside (run)
  "Return how many search index rows outside the scope of RUN hold its secrets.
A request for a session, or a project, leaves the other sessions as they
are, and their rows are in the files of the index: the secrets that
remain in those files after the index was purged are theirs.  It is 0 for
the scope all, which has no other session, and without an index.  The
number is asked once, and kept in RUN."
  (or (harness-redact-run-prop run :search-outside)
      (harness-redact-run-set-prop
       run :search-outside
       (if (or (eq (harness-redact-run-scope run) 'all)
               (not (harness-method-exists-p 'session/search-redact)))
           0
         (let ((probe (condition-case nil
                          (harness-call 'session/search-redact t (harness-redact-run-secrets run) t)
                        (error nil))))
           (if (plist-get probe :available)
               (cl-loop for cell in (plist-get probe :sessions)
                        unless (member (car cell) (harness-redact-run-ids run))
                        sum (cdr cell))
             0))))))

(defun harness-redact--search-explained-p (run)
  "Non-nil when the secrets left in the index files are other sessions' rows.
That is so when rows of sessions outside the scope of RUN hold them
\(`harness-redact--search-outside') and the purge, if it ran, emptied the
write-ahead log: nothing of the sessions in scope is left in the files,
so what is there is what those rows are."
  (and (> (harness-redact--search-outside run) 0)
       (let ((purge (harness-redact-run-prop run :search-purge)))
         (or (null purge) (and (plist-get purge :wal-truncated) t)))))

(defun harness-redact--purge-view (purge)
  "Return PURGE, what `session/search-purge' answered, as the report shows it."
  (list :seconds (plist-get purge :seconds)
        :bytes-before (plist-get purge :bytes-before) :bytes-after (plist-get purge :bytes-after)
        :wal-truncated (and (plist-get purge :wal-truncated) t)
        :left (+ (apply #'+ (mapcar #'cdr (plist-get purge :file-counts)))
                 (apply #'+ (mapcar #'cdr (plist-get purge :term-counts))))
        :files (mapcar (lambda (c) (list :file (car c) :count (cdr c))) (plist-get purge :file-counts))))

(defun harness-redact--stage-purge (run)
  "Take the old text out of the search index files, if RUN found a secret there."
  (when (and (harness-method-exists-p 'session/search-purge)
             (harness-redact-run-prop run :search-touched))
    (condition-case err
        (let* ((purge (harness-call 'session/search-purge (harness-redact-run-secrets run))))
          (if (not (plist-get purge :available))
              (harness-redact-update-store run "search index" :purge-error (plist-get purge :reason))
            (let* ((view (harness-redact--purge-view purge))
                   (left (plist-get view :left))
                   (outside 0))
              (harness-redact-run-set-prop run :search-purge view)
              (when (and (> left 0) (harness-redact--search-explained-p run))
                ;; What is in the files is what the rows of the sessions out of scope are.
                (setq outside (harness-redact--search-outside run)
                      view (plist-put (plist-put (copy-sequence view) :left 0) :outside-rows outside)))
              (harness-redact-update-store run "search index" :purge view)
              (harness-redact-add-lines
               run (list (format "Search index purged in %.1fs: %d bytes before, %d after, write-ahead log %s; %s of the secrets left in its files%s."
                                 (or (plist-get view :seconds) 0.0) (or (plist-get view :bytes-before) 0)
                                 (or (plist-get view :bytes-after) 0)
                                 (if (plist-get view :wal-truncated) "emptied" "NOT emptied")
                                 (harness-redact--n left "occurrence")
                                 (if (> outside 0)
                                     (format ", which are %s of sessions outside the scope"
                                             (harness-redact--n outside "row"))
                                   "")))))))
      (error
       (harness-redact-update-store run "search index" :purge-error (harness-redact--error-text err))
       (harness-redact--note-error run "purging the search index" err)))))

;;;; Records and hints

(defun harness-redact--n (n singular &optional plural)
  "Return N and the word SINGULAR, or PLURAL (SINGULAR and an s) unless N is 1."
  (format "%d %s" n (if (= n 1) singular (or plural (concat singular "s")))))

(defun harness-redact--secret-names (secrets)
  "Return SECRETS as a phrase naming each by label and fingerprint."
  (let ((shown (take 6 secrets)))
    (concat (harness-redact--n (length secrets) "secret")
            " ("
            (mapconcat (lambda (s) (format "%s sha256:%s" (plist-get s :label) (plist-get s :fingerprint)))
                       shown ", ")
            (if (> (length secrets) (length shown)) (format " and %d more" (- (length secrets) (length shown))) "")
            ")")))

(defun harness-redact--changed-p (run sid)
  "Non-nil when session SID changed in RUN, or had its provider reset."
  (let ((entry (harness-redact-entry run sid)))
    (or (cl-some (lambda (key) (> (or (plist-get entry key) 0) 0))
                 (append '(:log :memory :record :search :claude :copilot :tasks)
                         (mapcar #'car harness-redact--file-counts)))
        (memq (plist-get entry :provider) '(reset deferred failed)))))

(defun harness-redact--session-files (run sid)
  "Return the files RUN changed for session SID: its log, record and CLI logs."
  (let ((entry (harness-redact-entry run sid)))
    (delete-dups
     (delq nil (append (and (> (or (plist-get entry :log) 0) 0) (list (plist-get entry :log-file)))
                       (and (> (or (plist-get entry :record) 0) 0)
                            (list (expand-file-name (format "sessions/%s.json" sid)
                                                    harness-state-directory)))
                       (plist-get entry :files)
                       nil)))))

(defun harness-redact--secret-records (run sid)
  "Return the secrets of RUN as the record of session SID names them, with counts."
  (let* ((entry (harness-redact-entry run sid))
         (counts (plist-get entry :secret-counts))
         (secrets (harness-redact-run-secrets run))
         (total (+ (or (plist-get entry :log) 0) (or (plist-get entry :record) 0))))
    (mapcar (lambda (s)
              (list :label (plist-get s :label) :fingerprint (plist-get s :fingerprint)
                    :source (plist-get s :source)
                    :count (cond ((cdr (assoc (plist-get s :fingerprint) counts)))
                                 ((null (cdr secrets)) total)
                                 (t 0))))
            secrets)))

(defun harness-redact--record (run sid)
  "Return the record of the redaction of RUN in session SID, for its `ext'.
It holds who asked, why, the secrets by label and fingerprint, where
they were and how many, and what became of the provider conversation
\(`:cache-dropped' t when its prompt cache went with it); every value is
a string, a number, t or a list of them, as the store of a record keeps
them."
  (let* ((entry (harness-redact-entry run sid))
         (nodes (plist-get entry :nodes))
         (provider (plist-get entry :provider)))
    (append
     (list :ts (float-time)
           :by (harness-redact--origin-by (harness-redact-run-origin run)))
     (and (harness-redact-run-reason run) (list :reason (harness-redact-run-reason run)))
     (list :secrets (harness-redact--secret-records run sid)
           :nodes (take harness-redact--nodes-limit nodes)
           :fields (harness-redact--names (plist-get entry :fields))
           :record-fields (harness-redact--names (plist-get entry :record-fields))
           :files (harness-redact--session-files run sid)
           :counts (append (list :log (harness-redact--count run sid :log)
                                 :memory (harness-redact--count run sid :memory)
                                 :record (harness-redact--count run sid :record)
                                 :search (harness-redact--count run sid :search)
                                 :cli (+ (harness-redact--count run sid :claude)
                                         (harness-redact--count run sid :copilot))
                                 :tasks (harness-redact--count run sid :tasks))
                           (cl-loop for cell in harness-redact--file-counts
                                    append (list (car cell) (harness-redact--count run sid (car cell)))))
           :provider (if provider (symbol-name provider) "none"))
     (and (plist-get entry :cache-dropped) (list :cache-dropped t))
     (and (harness-redact-run-after-turn run) (list :after-turn t))
     (and (> (length nodes) harness-redact--nodes-limit) (list :nodes-total (length nodes))))))

(defun harness-redact--where (run sid)
  "Return a phrase saying where in the stores of session SID RUN found secrets."
  (let ((parts nil)
        (log (harness-redact--count run sid :log))
        (record (harness-redact--count run sid :record))
        (search (harness-redact--count run sid :search))
        (claude (harness-redact--count run sid :claude))
        (copilot (harness-redact--count run sid :copilot))
        (tasks (harness-redact--count run sid :tasks)))
    (when (> log 0)
      (push (format "%s in %s" (harness-redact--n log "occurrence")
                    (harness-redact--n (length (plist-get (harness-redact-entry run sid) :nodes)) "node"))
            parts))
    (when (> record 0) (push (format "%s in the session record" (harness-redact--n record "occurrence")) parts))
    (when (> search 0) (push (format "%s in the search index" (harness-redact--n search "row")) parts))
    (when (> claude 0) (push (format "%s in the Claude Code log" (harness-redact--n claude "occurrence")) parts))
    (when (> copilot 0) (push (format "%s in the Copilot log" (harness-redact--n copilot "occurrence")) parts))
    (when (> tasks 0) (push (format "%s in task records" (harness-redact--n tasks "occurrence")) parts))
    (dolist (cell harness-redact--file-counts)
      (let ((n (harness-redact--count run sid (car cell))))
        (when (> n 0) (push (format "%s in %s" (harness-redact--n n "occurrence") (cdr cell)) parts))))
    (if parts
        (mapconcat #'identity (nreverse parts) ", ")
      "no occurrence left")))

(defun harness-redact--sentence (text)
  "Return TEXT, a reason, ending in a full stop unless it ends in punctuation."
  (if (string-match-p "[.!?…)]\\'" text) text (concat text ".")))

(defun harness-redact--hint (run sid)
  "Return the text of the hint that tells session SID what RUN redacted from it."
  (let* ((entry (harness-redact-entry run sid))
         (provider (plist-get entry :provider))
         (error-text (plist-get entry :error)))
    (concat
     (if error-text
         (format "Redacting %s at %s failed for this session: %s. What it could not clean still holds the secret: run the redaction again."
                 (harness-redact--secret-names (harness-redact-run-secrets run))
                 (harness-redact--origin-phrase (harness-redact-run-origin run))
                 error-text)
       (format "Redacted %s: %s, at %s%s."
               (harness-redact--secret-names (harness-redact-run-secrets run))
               (harness-redact--where run sid)
               (harness-redact--origin-phrase (harness-redact-run-origin run))
               (if (harness-redact-run-after-turn run) ", after its turn ended" "")))
     (if (harness-redact-run-reason run)
         (format " Reason: %s" (harness-redact--sentence (harness-redact-run-reason run)))
       "")
     (pcase provider
       ('reset " The provider conversation starts over from the redacted transcript.")
       ('deferred " The session runs a turn: its provider conversation starts over from the redacted transcript once the turn ends.")
       ('failed (if error-text
                    " Its provider conversation was left as it was."
                  " The provider conversation could not be reset and still holds the secret; run the redaction again."))
       ('kept " The session was outside the request and its own transcript still holds the secret, so its provider conversation was left as it is, with the log it shares cleaned: a new one would be made from that transcript.")
       (_ "")))))

(defun harness-redact--append-record (sid record)
  "Add RECORD to the redactions in the `ext' of session SID, keeping the last ones."
  (let* ((ext (plist-get (harness-call 'session/get sid) :ext))
         (old (plist-get ext :redactions))
         (old (if (keywordp (car-safe old)) (list old) old))
         (all (append (and (listp old) old) (list record))))
    (harness-call 'session/set-ext sid :redactions (last all harness-redact--records-limit))))

(defun harness-redact--stage-records (run)
  "Record the redaction in each session of RUN that changed, and in its transcript."
  (let ((secrets (harness-redact-run-secrets run)))
    (dolist (sid (reverse (harness-redact-run-order run)))
      (when (and (harness-call 'session/exists-p sid) (harness-redact--changed-p run sid))
        (condition-case err
            (let* ((checked (harness-redaction-value (harness-redact--record run sid) secrets))
                   (record (car checked))
                   (hint (harness-redaction-string (harness-redact--hint run sid) secrets)))
              (when (> (+ (cdr checked) (cdr hint)) 0)
                (harness-log 'warn "redact: %d occurrence(s) of a secret were taken out of the record of session %s"
                             (+ (cdr checked) (cdr hint)) (harness-redact--short-id sid)))
              (setq hint (car hint))
              (harness-redact--append-record sid record)
              (harness-call 'session/hint sid hint)
              (when (fboundp 'harness-session--save) (harness-session--save sid))
              (harness-redact-entry-put run sid :recorded t)
              (harness-emit 'session/redacted sid record))
          (error
           (harness-redact--note-error
            run (format "recording the redaction in session %s" (harness-redact--short-id sid)) err)))))))

(defun harness-redact--stage-announce (run)
  "Announce that RUN redacted: `secrets/redacted', once, with labels and ids."
  (unless (harness-redact-run-after-turn run)
    (harness-emit 'secrets/redacted
                  (list :source (harness-redact-run-ref run)
                        :secrets (mapcar (lambda (s) (list :label (plist-get s :label)
                                                           :fingerprint (plist-get s :fingerprint)))
                                         (harness-redact-run-secrets run))
                        :sessions (cl-remove-if-not
                                   (lambda (sid) (plist-get (harness-redact-entry run sid) :recorded))
                                   (reverse (harness-redact-run-order run)))))))

;;;; The report

(defun harness-redact--compact (plist)
  "Return PLIST without the keys whose value is nil."
  (cl-loop for (k v) on plist by #'cddr when v append (list k v)))

(defun harness-redact--cache-context (session)
  "Return the tokens of context SESSION, a session plist, holds, or nil.
That is what its prompt cache holds, and what carrying on without it
sends again."
  (let ((context (plist-get (plist-get session :usage) :context)))
    (and (numberp context) (> context 0) context)))

(defun harness-redact--session-report (run sid)
  "Return the report of RUN about session SID: ids, counts and places, no value.
`:cache-dropped' (a redaction), or `:would-reset' and `:cache-would-drop'
\(a scan), say what the provider conversation costs, and `:context' is the
tokens of context the prompt cache of such a session holds."
  (let* ((entry (harness-redact-entry run sid))
         (session (and (harness-call 'session/exists-p sid) (harness-call 'session/get sid)))
         (secrets (harness-redact-run-secrets run))
         (cache-dropped (plist-get entry :cache-dropped))
         (cache-would-drop (plist-get entry :cache-would-drop)))
    (harness-redact--compact
     (append
      (list :id sid
            :name (and (stringp (plist-get session :name))
                       (truncate-string-to-width (car (harness-redaction-string (plist-get session :name) secrets))
                                                 80 nil nil "…"))
            :project (plist-get session :project)
            :count (+ (harness-redact--count run sid :log) (harness-redact--count run sid :record))
            :log (harness-redact--count run sid :log)
            :memory (harness-redact--count run sid :memory)
            :record (harness-redact--count run sid :record)
            :search (harness-redact--count run sid :search)
            :claude (harness-redact--count run sid :claude)
            :copilot (harness-redact--count run sid :copilot)
            :tasks (harness-redact--count run sid :tasks))
      (cl-loop for cell in harness-redact--file-counts
               append (list (car cell) (harness-redact--count run sid (car cell))))
      (list :nodes (take harness-redact--nodes-limit (plist-get entry :nodes))
            :fields (harness-redact--names (plist-get entry :fields))
            :record-fields (harness-redact--names (plist-get entry :record-fields))
            :files (harness-redact--session-files run sid)
            :running (plist-get entry :running)
            :out-of-scope (not (member sid (harness-redact-run-ids run)))
            :provider (plist-get entry :provider)
            :would-reset (plist-get entry :would-reset)
            :cache-dropped cache-dropped
            :cache-would-drop cache-would-drop
            :context (and (or cache-dropped cache-would-drop) (harness-redact--cache-context session))
            :error (plist-get entry :error))))))

(defun harness-redact--session-line (report)
  "Return the line of the text of a report about one session, REPORT."
  (let ((id (plist-get report :id)))
    (format "  %s%s%s: %s%s%s"
            (harness-redact--short-id id)
            (if (plist-get report :name) (format " %S" (plist-get report :name)) "")
            (if (plist-get report :project)
                (format " (%s)" (file-name-nondirectory (directory-file-name (plist-get report :project))))
              "")
            (let ((parts nil))
              (when (> (plist-get report :log) 0)
                (push (format "%s in the node log (%d node%s; %s)" (harness-redact--n (plist-get report :log) "occurrence")
                              (length (plist-get report :nodes))
                              (if (= (length (plist-get report :nodes)) 1) "" "s")
                              (or (mapconcat #'identity (plist-get report :fields) ", ") "no field"))
                      parts))
              (when (> (plist-get report :memory) 0)
                (push (format "%s in memory" (harness-redact--n (plist-get report :memory) "occurrence")) parts))
              (when (> (plist-get report :record) 0)
                (push (format "%s in the record (%s)" (harness-redact--n (plist-get report :record) "occurrence")
                              (mapconcat #'identity (plist-get report :record-fields) ", "))
                      parts))
              (when (> (plist-get report :search) 0)
                (push (format "%s in the search index" (harness-redact--n (plist-get report :search) "row")) parts))
              (when (> (plist-get report :claude) 0)
                (push (format "%s in Claude Code logs" (harness-redact--n (plist-get report :claude) "occurrence")) parts))
              (when (> (plist-get report :copilot) 0)
                (push (format "%s in Copilot logs" (harness-redact--n (plist-get report :copilot) "occurrence")) parts))
              (when (> (plist-get report :tasks) 0)
                (push (format "%s in task records" (harness-redact--n (plist-get report :tasks) "occurrence")) parts))
              (dolist (cell harness-redact--file-counts)
                (when (> (or (plist-get report (car cell)) 0) 0)
                  (push (format "%s in %s" (harness-redact--n (plist-get report (car cell)) "occurrence") (cdr cell))
                        parts)))
              (cond (parts (mapconcat #'identity (nreverse parts) "; "))
                    ((plist-get report :out-of-scope)
                     "outside the scope: only its provider conversation held the secret")
                    (t "nothing left in its own stores")))
            (if (plist-get report :running) "; it runs a turn" "")
            (if (plist-get report :provider) (format "; provider: %s" (plist-get report :provider)) ""))))

(defun harness-redact--leftovers (run)
  "Return what a redaction of RUN left, as strings: files, sessions and stages."
  (let (left)
    (dolist (sid (reverse (harness-redact-run-order run)))
      (let ((entry (harness-redact-entry run sid)))
        (dolist (file (plist-get entry :left))
          (push (format "%s: %s (a provider's log that is running, busy, binary or unreadable)"
                        (harness-redact--short-id sid) (abbreviate-file-name file))
                left))
        (when (plist-get entry :error)
          (push (format "session %s: %s" (harness-redact--short-id sid) (plist-get entry :error)) left))
        (when (eq (plist-get entry :provider) 'failed)
          (push (format "session %s: its provider conversation was not reset" (harness-redact--short-id sid)) left))))
    (dolist (store (harness-redact-run-stores run))
      (dolist (line (plist-get store :left))
        (push line left))
      (when (plist-get store :failed)
        (push (format "%s: %s could not be read again" (plist-get store :store)
                      (harness-redact--n (length (plist-get store :failed)) "session"))
              left))
      (when (plist-get store :purge-error)
        (push (format "%s: the purge failed (%s)" (plist-get store :store) (plist-get store :purge-error)) left))
      (let ((purge (plist-get store :purge)))
        (when (and purge (> (or (plist-get purge :left) 0) 0))
          (push (format "%s: %s of the secrets %s still in its files" (plist-get store :store)
                        (harness-redact--n (plist-get purge :left) "occurrence")
                        (if (= (plist-get purge :left) 1) "is" "are"))
                left))))
    (dolist (line (harness-redact-run-prop run :verification-left))
      (push line left))
    (nreverse (delete-dups left))))

(defun harness-redact--short-ids (reports)
  "Return the short ids of the session REPORTS, joined with commas."
  (mapconcat (lambda (r) (harness-redact--short-id (plist-get r :id))) reports ", "))

(defun harness-redact--cache-tokens (reports)
  "Return \" (~T tokens)\" for the context the session REPORTS hold, or \"\".
T is the sum of their `:context', the tokens their prompt caches held."
  (let ((total (apply #'+ (mapcar (lambda (r) (let ((c (plist-get r :context))) (if (numberp c) c 0)))
                                  reports))))
    (if (> total 0)
        (format " (~%s %s)" (harness-format-tokens total) (if (= total 1) "token" "tokens"))
      "")))

(defun harness-redact--cache-line (reports redact)
  "Return the line of a report's text that says whose prompt cache goes.
REPORTS are the reports of the sessions whose prompt cache a redaction
dropped (REDACT non-nil) or a scan says it would drop.  The sessions are
named by short id, with the tokens their caches held, and the line says
what their next message does: it asks what goes first, as for a cold
cache, rather than sending the whole conversation again uncached."
  (let ((n (length reports)))
    (format (concat (if redact
                        "The prompt cache of %s went with it: %s%s.  "
                      "It would drop the prompt cache of %s: %s%s.  ")
                    "%s what goes first, as for a cold cache, "
                    "instead of sending the whole conversation again uncached.")
            (harness-redact--n n "session")
            (harness-redact--short-ids reports)
            (harness-redact--cache-tokens reports)
            (cond ((and redact (= n 1)) "Its next message asks")
                  (redact "Their next messages ask")
                  ((= n 1) "Its next message would then ask")
                  (t "Their next messages would then ask")))))

(defun harness-redact--text (run sessions total deferred errors left)
  "Return the text of the report of RUN, for a person or a model to read.
SESSIONS are the session reports, TOTAL the occurrences found, DEFERRED
the sessions that wait, ERRORS and LEFT what failed and what remains.
It names secrets by label and fingerprint, never by value.  It says
whose provider conversation starts over, or in a scan would, and whose
prompt cache goes with it: the cost of the reset."
  (let* ((redact (not (harness-redact-run-dry-p run)))
         (secrets (harness-redact-run-secrets run))
         (lines nil))
    (cl-flet ((add (&rest strings) (dolist (s strings) (push s lines))))
      (add (format "%s of %s for %s%s."
                   (if redact (if (harness-redact-run-after-turn run) "Redaction, after the turn ended," "Redaction") "Scan")
                   (harness-redact-run-scope-text run)
                   (harness-redact--n (length secrets) "secret")
                   (if redact "" " (nothing was changed)")))
      (dolist (s secrets)
        (add (format "  - %s (sha256:%s): %s" (plist-get s :label) (plist-get s :fingerprint)
                     (or (plist-get s :source) "unknown source"))))
      (when (> (harness-redact-run-skipped run) 0)
        (add (format "%s shorter than %d characters %s not treated as %s."
                     (harness-redact--n (harness-redact-run-skipped run) "value") harness-redaction-min-length
                     (if (= (harness-redact-run-skipped run) 1) "was" "were")
                     (if (= (harness-redact-run-skipped run) 1) "a secret" "secrets"))))
      (when (harness-redact-run-reason run)
        (add (format "Reason: %s" (harness-redact-run-reason run))))
      (when (harness-redact-run-origin-note run)
        (add (concat (harness-redact-run-origin-note run) ".")))
      (add (format "%s %s in %s." (if redact "Found and redacted" "Found") (harness-redact--n total "occurrence")
                   (harness-redact--n (length sessions) "session")))
      (dolist (report sessions) (add (harness-redact--session-line report)))
      (dolist (line (reverse (harness-redact-run-lines run)))
        (add (cdr line)))
      ;; What a redaction would cost, which a scan can say before it is paid.
      (unless redact
        (let ((would (cl-remove-if-not (lambda (r) (plist-get r :would-reset)) sessions)))
          (when would
            (add (format "A redaction would start the provider conversation of %s over from the redacted transcript: %s."
                         (harness-redact--n (length would) "session")
                         (harness-redact--short-ids would))))
          (let ((drop (cl-remove-if-not (lambda (r) (plist-get r :cache-would-drop)) would)))
            (when drop
              (add (harness-redact--cache-line drop nil))))))
      (when redact
        (let ((reset (cl-remove-if-not (lambda (r) (eq (plist-get r :provider) 'reset)) sessions)))
          (when reset
            (add (format "The provider conversation of %s starts over from the redacted transcript: %s."
                         (harness-redact--n (length reset) "session")
                         (harness-redact--short-ids reset)))
            (let ((dropped (cl-remove-if-not (lambda (r) (plist-get r :cache-dropped)) reset)))
              (when dropped
                (add (harness-redact--cache-line dropped t))))))
        (let ((kept (cl-remove-if-not (lambda (r) (eq (plist-get r :provider) 'kept)) sessions)))
          (when kept
            (add (format "The provider conversation of %s was left as it is (outside the scope, and its transcript still holds the secret; the log it shares was cleaned): %s."
                         (harness-redact--n (length kept) "session")
                         (mapconcat (lambda (r) (harness-redact--short-id (plist-get r :id))) kept ", ")))))
        (when deferred
          (add (format "Waiting for a running turn to end (the redaction goes on by itself then): %s."
                       (mapconcat #'harness-redact--short-id deferred ", ")))))
      (when errors
        (add "FAILED:") (dolist (e errors) (add (concat "  " e))))
      (when (and redact left)
        (add "NOT everything is clean:") (dolist (l left) (add (concat "  " l))))
      (when (and redact (null errors) (null left) (null deferred))
        (add "Nothing found by this request is left in the stores it covers.")))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun harness-redact--report (run)
  "Return the report of RUN: secrets, counts, places and a text, no value.
The shape is described at `secrets/redact'.  The report is checked for the
values of the secrets before it is returned: a name or a path that holds
one is replaced."
  (let* ((secrets (harness-redact-run-secrets run))
         (sessions (mapcar (lambda (sid) (harness-redact--session-report run sid))
                           (reverse (harness-redact-run-order run))))
         (stores (reverse (harness-redact-run-stores run)))
         (total (+ (apply #'+ (mapcar (lambda (r) (plist-get r :count)) sessions))
                   (apply #'+ (mapcar (lambda (s) (or (plist-get s :count) 0)) stores))))
         (deferred (cl-remove-if-not (lambda (sid) (eq (plist-get (harness-redact-entry run sid) :provider) 'deferred))
                                     (reverse (harness-redact-run-order run))))
         (errors (harness-redact-run-prop run :errors))
         (left (and (not (harness-redact-run-dry-p run)) (harness-redact--leftovers run)))
         (report (harness-redact--compact
                  (list :mode (harness-redact-run-mode run)
                        :secrets (mapcar (lambda (s) (list :label (plist-get s :label)
                                                           :fingerprint (plist-get s :fingerprint)
                                                           :source (plist-get s :source)))
                                         secrets)
                        :skipped (harness-redact-run-skipped run)
                        :scope (harness-redact-run-scope-text run)
                        :sessions sessions
                        :stores stores
                        :total total
                        :deferred deferred
                        :errors errors
                        :remaining left
                        :complete (and (not (harness-redact-run-dry-p run)) (null errors) (null left)
                                       (null deferred))
                        :origin-session (and (harness-redact-run-origin-note run) t)
                        :verification (harness-redact-run-prop run :verification)
                        :text (harness-redact--text run sessions total deferred errors left)))))
    ;; Kept even when empty: they say that nothing was found.
    (setq report (plist-put (plist-put (plist-put report :total total) :sessions sessions)
                            :stores stores))
    (let ((checked (harness-redaction-value report secrets)))
      (when (> (cdr checked) 0)
        (harness-log 'warn "redact: %d occurrence(s) of a secret were taken out of the report" (cdr checked)))
      (car checked))))

;;;; Checking the result

(defconst harness-redact--explained '(deferred busy binary not-redacted)
  "Statuses of a file that still holds a secret for a reason the report gives.
A provider's log that a running turn or someone else is writing is left
alone (`deferred', `busy'), and a file that is binary, a database, or too
large to be rewritten is reported as found, not redacted (`binary',
`not-redacted'): the verification does not count their secrets as lost.")

(defconst harness-redact--search-files '("search.db" "search.db-wal" "search.db-shm")
  "The files of the search index in the state directory.
The database, its write-ahead log and its shared memory: the secrets are
counted in each of them as bytes, after the index was purged.")

(defun harness-redact--explained-count (store)
  "Return the occurrences in STORE that sit in files left alone for a reason."
  (apply #'+ (mapcar (lambda (f)
                       (if (memq (plist-get f :status) harness-redact--explained)
                           (or (plist-get f :count) 0)
                         0))
                     (plist-get store :files))))

(defun harness-redact--search-file-counts (run)
  "Return ((FILE . N) ...): the secrets of RUN counted in the index's files.
A file that is not there is left out; one that cannot be read is noted
in RUN as an error and counted as none."
  (let (counts)
    (dolist (name harness-redact--search-files)
      (let ((file (expand-file-name name harness-state-directory)))
        (when (file-regular-p file)
          (push (cons file
                      (condition-case err
                          (harness-redaction-file-count file (harness-redact-run-secrets run))
                        (error (harness-redact--note-error
                                run (format "counting the secrets in %s" name) err)
                               0)))
                counts))))
    (nreverse counts)))

(defun harness-redact--verify-run (run)
  "Return a scan of the scope and stores of RUN, to check them afterwards.
It reads the same references and looks in the same provider conversations
as RUN did, those the redaction has made the sessions forget included."
  (let ((again (harness-redact--make-run
                :mode 'scan :secrets (harness-redact-run-secrets run) :ref (harness-redact-run-ref run)
                :scope (harness-redact-run-scope run) :scope-text (harness-redact-run-scope-text run)
                :project (harness-redact-run-project run) :ids (harness-redact-run-ids run)
                :origin (harness-redact-run-origin run))))
    (dolist (key '(:references :claude-ids :copilot-ids))
      (when-let* ((value (harness-redact-run-prop run key)))
        (harness-redact-run-set-prop again key value)))
    again))

(defun harness-redact--verification-rows (again &optional run)
  "Return the rows of the verification of the scan AGAIN, a plist per store.
Each is (:store NAME :count N :expected E), N the occurrences found and E
those in files left alone for a stated reason, with :files for the files
that still hold one.  The files of the search index come last; what they
hold is expected when it belongs to the rows of sessions outside the
scope of RUN, the request that is verified
\(`harness-redact--search-explained-p')."
  (let (rows)
    (cl-flet ((sum (key)
                (apply #'+ (mapcar (lambda (sid) (harness-redact--count again sid key))
                                   (harness-redact-run-order again)))))
      (push (list :store "node logs" :count (sum :log)) rows)
      (push (list :store "nodes in memory" :count (sum :memory)) rows)
      (push (list :store "session records" :count (sum :record)) rows))
    (dolist (store (reverse (harness-redact-run-stores again)))
      (let ((files (cl-remove-if-not (lambda (f) (> (or (plist-get f :count) 0) 0))
                                     (plist-get store :files))))
        (push (harness-redact--compact
               (list :store (plist-get store :store)
                     :count (or (plist-get store :count) (plist-get store :rows) 0)
                     :expected (harness-redact--explained-count store)
                     :files (mapcar (lambda (f) (harness-redact--compact
                                                 (list :file (plist-get f :file) :count (plist-get f :count)
                                                       :status (plist-get f :status))))
                                    files)))
              rows)))
    (let* ((counts (harness-redact--search-file-counts again))
           (total (apply #'+ (mapcar #'cdr counts))))
      (push (harness-redact--compact
             (list :store "search index files" :count total
                   :expected (and run (> total 0) (harness-redact--search-explained-p run) total)
                   :files (mapcar (lambda (c) (list :file (car c) :count (cdr c))) counts)))
            rows))
    (nreverse rows)))

(defun harness-redact--verification-lines (verification)
  "Return the lines of a report about VERIFICATION, what the second scan found."
  (let* ((rows (plist-get verification :stores))
         (total (plist-get verification :total))
         (unexplained (plist-get verification :unexplained))
         (search (cl-find "search index files" rows :key (lambda (r) (plist-get r :store)) :test #'equal))
         (what "Verification (the same scope and stores scanned again, and the search index's files counted)"))
    (append
     (list (if (= total 0)
               (format "%s: nothing is left." what)
             (format "%s: %s left: %s." what (harness-redact--n total "occurrence")
                     (mapconcat (lambda (r) (format "%s %d" (plist-get r :store) (plist-get r :count)))
                                (cl-remove-if-not (lambda (r) (> (plist-get r :count) 0)) rows) ", "))))
     (and (> (- total unexplained (or (plist-get search :expected) 0)) 0)
          (list (format "  In files that were left alone (deferred, busy, binary or too large; listed above): %d."
                        (- total unexplained (or (plist-get search :expected) 0)))))
     (and (> (or (plist-get search :expected) 0) 0)
          (list (format "  In the files of the search index: %d, the rows of sessions outside the scope, which hold the secret too."
                        (plist-get search :expected))))
     (and (> unexplained 0)
          (list (format "  Not explained by that (the redaction missed them, or something wrote them back): %d."
                        unexplained)))
     (and search (plist-get search :files)
          (list (format "  Search index files, in bytes: %s."
                        (mapconcat (lambda (f) (format "%s %s" (file-name-nondirectory (plist-get f :file))
                                                       (harness-redact--n (plist-get f :count) "occurrence")))
                                   (plist-get search :files) ", ")))))))

(defun harness-redact--verify-stores (run)
  "After a redaction of RUN, scan its scope and stores again and say what is left.
It is the scan the request would be, run on the stores as they are now
\(`harness-redact--store-functions' on a new run), plus the secrets
counted in the files of the search index.  What a deferred, busy or
binary file holds is expected; the rest, which the redaction should have
removed, goes in the report as `:remaining'.  Nothing is done for a scan."
  (unless (harness-redact-run-dry-p run)
    (let ((started (float-time))
          (again (harness-redact--verify-run run)))
      (dolist (fn harness-redact--store-functions)
        (harness-redact--stage again fn))
      (let* ((rows (harness-redact--verification-rows again run))
             (total (apply #'+ (mapcar (lambda (r) (plist-get r :count)) rows)))
             (explained (apply #'+ (mapcar (lambda (r) (or (plist-get r :expected) 0)) rows)))
             (unexplained (- total explained))
             (errors (harness-redact-run-prop again :errors))
             (verification (harness-redact--compact
                            (list :total total :explained explained :unexplained unexplained
                                  :ok (if (and (= unexplained 0) (null errors)) t :false)
                                  :stores rows
                                  :errors errors
                                  :seconds (/ (round (* 10 (- (float-time) started))) 10.0)))))
        (harness-redact-run-set-prop run :verification verification)
        (harness-redact-run-set-prop
         run :verification-left
         (cl-loop for r in rows
                  for n = (- (plist-get r :count) (or (plist-get r :expected) 0))
                  when (> n 0)
                  collect (format "%s: %s left, found by the verification"
                                  (plist-get r :store) (harness-redact--n n "occurrence"))))
        ;; A failure the redaction itself reported is not reported twice.
        (let* ((known (harness-redact-run-prop run :errors))
               (new (cl-remove-if (lambda (e) (member e known)) errors)))
          (when new
            (harness-redact-run-set-prop
             run :errors (append known (mapcar (lambda (e) (concat "verification: " e)) new)))))
        (harness-redact-add-lines run (harness-redact--verification-lines verification))))))

;;;; The log of redactions

(defun harness-redact--origin-line (origin)
  "Return ORIGIN, who asked, as the log of redactions has it."
  (if (eq (plist-get origin :kind) 'session)
      (list :kind "session" :id (plist-get origin :id))
    (list :kind "user")))

(defun harness-redact--run-files (report)
  "Return the files the redaction of REPORT changed: the sessions' and the stores'."
  (delete-dups
   (append
    (apply #'append (mapcar (lambda (s) (plist-get s :files)) (plist-get report :sessions)))
    (cl-loop for store in (plist-get report :stores)
             append (cl-loop for f in (plist-get store :files)
                             when (or (eq (plist-get f :status) 'redacted)
                                      (and (null (plist-get f :status)) (> (or (plist-get f :count) 0) 0)))
                             collect (plist-get f :file))))))

(defun harness-redact--run-line (run report)
  "Return the line of the log of redactions for RUN, whose report is REPORT.
It is made of labels, fingerprints, ids, paths and counts, and checked
for the values of the secrets before it is returned."
  (let* ((secrets (harness-redact-run-secrets run))
         (sessions (plist-get report :sessions))
         (ids (mapcar (lambda (s) (plist-get s :id)) sessions))
         (files (harness-redact--run-files report))
         (limit harness-redact--runs-names-limit)
         (sum (lambda (key) (apply #'+ (mapcar (lambda (s) (or (plist-get s key) 0)) sessions))))
         (totals (append
                  (list (list :store "node logs" :count (funcall sum :log))
                        (list :store "nodes in memory" :count (funcall sum :memory))
                        (list :store "session records" :count (funcall sum :record)))
                  (mapcar (lambda (store)
                            (list :store (plist-get store :store)
                                  :count (or (plist-get store :count) (plist-get store :rows) 0)))
                          (plist-get report :stores))))
         (verification (plist-get report :verification))
         (line (harness-redact--compact
                (list :ts (float-time)
                      :time (format-time-string "%Y-%m-%dT%H:%M:%S%z")
                      :origin (harness-redact--origin-line (harness-redact-run-origin run))
                      :reason (harness-redact-run-reason run)
                      :mode "redact"
                      :scope (plist-get report :scope)
                      :scope-kind (symbol-name (harness-redact-run-scope run))
                      :after-turn (and (harness-redact-run-after-turn run) t)
                      :secrets (harness-json-array
                                (mapcar (lambda (s) (harness-redact--compact
                                                     (list :label (plist-get s :label)
                                                           :fingerprint (plist-get s :fingerprint)
                                                           :source (plist-get s :source))))
                                        (plist-get report :secrets)))
                      :skipped (plist-get report :skipped)
                      :total (plist-get report :total)
                      :totals (harness-json-array totals)
                      :sessions (harness-json-array (take limit ids))
                      :sessions-total (and (> (length ids) limit) (length ids))
                      :files (harness-json-array (take limit files))
                      :files-total (and (> (length files) limit) (length files))
                      :deferred (harness-json-array (plist-get report :deferred))
                      :errors (harness-json-array (plist-get report :errors))
                      :remaining (harness-json-array (plist-get report :remaining))
                      :complete (if (plist-get report :complete) t :false)
                      :verification (and verification
                                         (harness-redact--compact
                                          (list :ok (plist-get verification :ok)
                                                :total (plist-get verification :total)
                                                :explained (plist-get verification :explained)
                                                :unexplained (plist-get verification :unexplained)
                                                :stores (harness-json-array
                                                         (mapcar (lambda (r) (harness-redact--compact
                                                                              (list :store (plist-get r :store)
                                                                                    :count (plist-get r :count)
                                                                                    :expected (plist-get r :expected))))
                                                                 (plist-get verification :stores)))
                                                :seconds (plist-get verification :seconds))))))))
    (when (harness-redact-run-origin-note run)
      (setq line (plist-put line :origin-session t)))
    (car (harness-redaction-value line secrets))))

(defun harness-redact--log-run (run report)
  "Add a line for the redaction RUN, with REPORT, to the log of redactions.
The log is `harness-redact--runs-file' in the state directory, one JSON
object a line, the newest last; `secrets/log' reads it.  A line says
when, who asked, why, the secrets by label and fingerprint, the scope,
the totals per store, the sessions and files that changed, the sessions
that wait for a turn to end, and the verification -- never a value."
  (harness-call 'store/append harness-redact--runs-file (harness-redact--run-line run report)))

(harness-defmethod secrets/log (&optional limit)
  "Return the last LIMIT redactions this harness ran (50 by default), newest first.
Each is a plist the redaction wrote into redactions.jsonl in the state
directory when it was done (:ts :time :origin :reason :mode :scope
:scope-kind :after-turn :secrets :skipped :total :totals :sessions
:files :deferred :errors :remaining :complete :verification).  The
secrets are named by label, fingerprint and source, the sessions by id,
the totals by store; there is no value in it, nor a snippet of text."
  (let ((n (cond ((null limit) harness-redact--runs-limit)
                 ((and (numberp limit) (>= limit 1)) (floor limit))
                 ((and (stringp limit) (string-match-p "\\`[0-9]+\\'" limit) (>= (string-to-number limit) 1))
                  (string-to-number limit))
                 (t (harness-redact--fail "The limit is a number of redactions, 1 or more")))))
    (reverse (last (harness-call 'store/read-all harness-redact--runs-file) n))))

;;;; Running a request

(defun harness-redact--stage (run fn &rest args)
  "Call the stage FN of RUN with ARGS; a failure is noted in RUN, not signalled.
The other stages go on: what could be cleaned is, and the report says
what could not."
  (condition-case err
      (apply fn run args)
    (error (harness-redact--note-error
            run (string-remove-prefix "harness-redact--stage-" (symbol-name fn)) err))))

(defun harness-redact--execute (run)
  "Take the stores of RUN in turn, as the mode asks, and return the report."
  (let ((redact (not (harness-redact-run-dry-p run))))
    (dolist (fn harness-redact--store-functions)
      (harness-redact--stage run fn))
    (if redact
        (progn
          (harness-redact--stage run #'harness-redact--stage-providers)
          (harness-redact--stage run #'harness-redact--stage-reindex)
          (harness-redact--stage run #'harness-redact--stage-purge)
          (harness-redact--stage run #'harness-redact--stage-records))
      ;; What a redaction would cost, which no store counts.
      (harness-redact--stage run #'harness-redact--stage-scan-providers))
    (dolist (fn harness-redact--verify-functions)
      (harness-redact--stage run fn))
    (when redact
      (harness-redact--stage run #'harness-redact--stage-announce))
    (let ((report (harness-redact--report-safely run)))
      (when redact
        (dolist (fn harness-redact--finish-functions)
          (harness-redact--stage run fn report))
        (harness-log 'info "redact: %s of %s: %d occurrence(s) in %d session(s)"
                     (if (harness-redact-run-after-turn run) "redacted, after a turn ended," "redacted")
                     (harness-redact-run-scope-text run) (or (plist-get report :total) 0)
                     (length (plist-get report :sessions))))
      report)))

(defun harness-redact--report-safely (run)
  "Return the report of RUN; one that cannot be made is replaced by a short one.
The stores are cleaned by now, and the caller has to be told so rather
than see an error."
  (condition-case err
      (harness-redact--report run)
    (error
     (let ((text (format "The request ran, but its report could not be made: %s"
                         (harness-redact--error-text err))))
       (harness-log 'error "redact: %s" text)
       (list :mode (harness-redact-run-mode run) :scope (harness-redact-run-scope-text run)
             :total 0 :sessions nil :stores nil
             :errors (append (harness-redact-run-prop run :errors) (list text))
             :text text)))))

(harness-defmethod secrets/redact (params)
  "Take a secret out of everything the harness stored; return a report.
PARAMS is a plist; the secret is named by where it can be read, so its
value is never in the call or in the answer:

  :source REF        required.  (:file PATH :json-path P) a string, or the
                     strings under an object or array, in a JSON file;
                     (:file PATH :regexp RE) group 1 of each match;
                     (:env NAME) a variable of the harness process.
                     A (:literal TEXT) or (:command STRING) only with
                     :allow-unsafe-sources.
  :label TEXT        what the secret is called in its placeholder.
  :scope SCOPE       required.  `session' (the :sessions, a list of
                     session ids or the starts of them), `project' (the
                     sessions of the directory :project) or `all' (every
                     session, of every project and kind).
  :include-forks     whether the forks of the sessions are in scope too
                     (default t); `:false' or nil leaves them out.
  :mode MODE         `scan' (the default) counts and changes nothing;
                     `redact' takes the secret out.
  :reason TEXT       why, kept in the records.
  :origin ORIGIN     who asks: (:kind user), the default, or (:kind
                     session :id ID).
  :input-text TEXT   the JSON of the tool call that asks.  When it holds
                     the secret (it should not), the session that made
                     the call is added to the scope.
  :allow-unsafe-sources  t from the UI or Lisp only.

A redaction takes the secret out of the node logs, nodes in memory and
records of the sessions in scope (`session/redact-text'), the search
index (`session/search-redact', then `session/search-purge'), the logs
of Claude Code and Copilot, and for the scopes all and project the
records of tasks; out of the transcript files of the sessions in scope
\(compaction and handoff write them), the files that hold their cut tool
outputs whole, and what they left in their temporary directories; for
the scope all, out of every other file of the state directory but the
sessions', the outputs', the compiled and recorded ones and the search
index's; and out of the log buffers of the process.  A file that is
binary, a database or over 64 MiB is counted and reported as found, not
redacted.  It resets the provider conversation of the sessions whose
nodes (the node log or memory) or whose provider's log held the secret
\(`session/reset-provider'; a hit only in a session's record resets
nothing), waits for a session running a turn and does these then; and
writes a record into the `ext' of each session that changed, in
`:redactions', a hint into its transcript, and emits `session/redacted'
for it and `secrets/redacted' once.  It ends by scanning the same scope
and stores again and counting the secret in the files of the search
index (`:verification'), and adds a line to the log of redactions
\(`secrets/log').

A reset of a session on a hosted loop that reported a prompt cache drops
that cache with the conversation (`session/reset-provider' answers
`:cache-dropped'): the new conversation opens with the transcript as
text, which the old cache does not hold.  The session's next message
then meets the cold-cache question.  A scan says what a redaction would
cost in this way, before it is paid.

The report is (:mode :secrets ((:label :fingerprint :source) ...)
:skipped N :scope TEXT :sessions SESSIONS :stores STORES :total N
:deferred IDS :errors STRINGS :remaining STRINGS :complete BOOL
:verification V :text TEXT).
SESSIONS lists the sessions with something found or changed, each (:id
:name :project :count :log :memory :record :search :claude :copilot
:tasks :nodes :fields :record-fields :files :running :provider
:would-reset :cache-dropped :cache-would-drop :context :error);
:count is the occurrences in its node log and record.  `:cache-dropped'
is t on a session whose reset dropped its prompt cache.  In a scan,
`:would-reset' is t on a session whose provider conversation a
redaction would start over, and `:cache-would-drop' on one whose
prompt cache it would drop with it (`session/reset-drops-cache-p').
`:context' is the tokens that cache holds, on those sessions only.
STORES lists the stores that are not a session's, each (:store NAME
...).  ERRORS are the stages that failed and REMAINING what a redaction
left (a log that is busy, a purge that failed, a file found but not
redacted, whatever the verification found beyond that ...); COMPLETE is
t when it was a redaction, nothing failed, nothing remains and no
session waits for the end of its turn.  V, for a redaction, is (:total N
:explained N :unexplained N :ok BOOL :stores ROWS ...): what the scan
after it found, each row (:store NAME :count N :expected N), N being the
occurrences in that store and `:expected' those in files left alone as
deferred, busy or binary, and, in the files of the search index, those
that are the rows of sessions outside the scope (a request for some
sessions leaves the others' rows, and their text is in those files).  A
session of the report whose `:provider' is `kept' was outside the scope
with its own transcript still holding the secret, and shares a
conversation with one in it: the conversation is left as it is, as a new
one would be made from that transcript.  TEXT says it all for a person
or a model to read.
Nothing in the report, or anywhere else this method writes, is a value, a
snippet of text around one, or a name that holds one."
  (harness-redact--execute (harness-redact--prepare params)))

;;;; Waiting for a running turn

(defun harness-redact--rerun (sid items)
  "Redact again the stores of session SID for the redactions ITEMS waited for.
Each item is one request that was deferred; SID's turn has ended."
  (dolist (item items)
    (let ((run (harness-redact--make-run
                :mode 'redact :secrets (plist-get item :secrets) :ref (plist-get item :ref)
                :scope 'session :ids (list sid) :origin (plist-get item :origin)
                :reason (plist-get item :reason) :after-turn t
                :scope-text (format "session %s" (harness-redact--short-id sid)))))
      (harness-redact-run-set-prop run :claude-ids (plist-get item :claude-ids))
      (harness-redact-run-set-prop run :copilot-ids (plist-get item :copilot-ids))
      ;; The provider conversation was not reset yet, whatever is found now.
      (harness-redact-entry-put run sid :provider-target t)
      (harness-redact--execute run))))

(defun harness-redact--on-turn-ended (sid &rest _)
  "Go on with the redactions that waited for the turn of session SID, now it ended."
  (when-let* ((items (gethash sid harness-redact--pending)))
    (unless (harness-redact--running-p sid)
      (remhash sid harness-redact--pending)
      (condition-case err
          (progn
            (if (harness-call 'session/exists-p sid)
                (harness-redact--rerun sid items)
              (harness-log 'info "redact: session %s was deleted before its redaction went on"
                           (harness-redact--short-id sid)))
            ;; Re-deferred by the run, the flag stays; otherwise it goes.
            (when (and (not (gethash sid harness-redact--pending))
                       (harness-call 'session/exists-p sid))
              (harness-call 'session/set-ext sid :redaction-pending nil)))
        (error
         (harness-log 'error "redact: going on with the redaction of session %s failed: %s"
                      (harness-redact--short-id sid) (harness-redact--error-text err))
         (puthash sid items harness-redact--pending))))))

(defun harness-redact--on-session-deleted (sid &rest _)
  "Forget the redactions that waited for session SID, which is gone."
  (remhash sid harness-redact--pending))

(defun harness-redact--settle-flagged ()
  "Settle the sessions flagged `:redaction-pending' that no memory remembers.
A harness that stopped before a running turn ended lost the secrets with
the rest of its memory.  The provider conversation of such a session is
dropped anyway, which needs no value, and a hint says the redaction
should be run again."
  (dolist (s (harness-call 'session/list))
    (let ((sid (plist-get s :id))
          (flag (plist-get (plist-get s :ext) :redaction-pending)))
      (when (and flag (not (gethash sid harness-redact--pending)) (not (harness-redact--running-p sid)))
        (condition-case err
            (progn
              (harness-call 'session/reset-provider sid)
              (harness-call 'session/set-ext sid :redaction-pending nil)
              (harness-call 'session/hint sid
                            (format "The harness stopped before the redaction of %s finished. The provider conversation was dropped, but the secret may still be in what the turn that was running wrote: run the redaction again."
                                    (mapconcat (lambda (k) (format "%s sha256:%s" (plist-get k :label) (plist-get k :fingerprint)))
                                               (if (keywordp (car-safe flag)) (list flag) flag) ", "))))
          (error (harness-log 'warn "redact: settling the pending redaction of session %s failed: %s"
                              (harness-redact--short-id sid) (harness-redact--error-text err))))))))

;;;; Masking while a redaction waits

;; A session whose redaction waits is running, and what it reads next can
;; bring the secret back into its transcript.  Until its turn ends, tool
;; output is masked of the pending secrets (the secrets module masks the
;; registered ones the same way, at priority 5).

(defun harness-redact--held-secrets ()
  "Return the secrets that redactions wait with, without duplicates."
  (let ((seen (make-hash-table :test 'equal)) out)
    (maphash (lambda (_sid items)
               (dolist (item items)
                 (dolist (s (plist-get item :secrets))
                   (unless (gethash (plist-get s :value) seen)
                     (puthash (plist-get s :value) t seen)
                     (push s out)))))
             harness-redact--pending)
    (nreverse out)))

(defun harness-redact--hold-mask (text)
  "Return (MASKED . HITS) for TEXT, the pending secrets taken out of it."
  (let ((hits nil))
    (dolist (secret (harness-redact--held-secrets))
      (let* ((needles (mapcar (lambda (n) (list :value n :label (plist-get secret :label)
                                                :fingerprint (plist-get secret :fingerprint)))
                              (harness-redaction-needles secret)))
             (r (harness-redaction-string text needles)))
        (when (> (cdr r) 0)
          (setq text (car r))
          (push (list :label (plist-get secret :label) :fingerprint (plist-get secret :fingerprint)
                      :count (cdr r))
                hits))))
    (cons text (nreverse hits))))

(defun harness-redact--filter-output (result &rest _)
  "Take the pending secrets out of the output of RESULT; the `tools/output' filter."
  (let ((content (plist-get result :content)))
    (if (or (zerop (hash-table-count harness-redact--pending))
            (not (stringp content)) (string-empty-p content))
        result
      (condition-case err
          (pcase-let ((`(,masked . ,hits) (harness-redact--hold-mask content)))
            (if (null hits)
                result
              (let ((meta (plist-get result :meta))
                    (new (plist-put (copy-sequence result) :content masked)))
                (plist-put new :meta (plist-put (copy-sequence meta) :masked
                                                (append (plist-get meta :masked) hits))))))
        (error
         (harness-log 'error "redact: masking a tool result failed (%s); its output is withheld"
                      (car err))
         (plist-put (plist-put (copy-sequence result) :content harness-redact--withheld-output)
                    :is-error t))))))

(defun harness-redact--filter-text (text &rest _)
  "Take the pending secrets out of TEXT; the `tools/output-text' filter."
  (if (or (zerop (hash-table-count harness-redact--pending))
          (not (stringp text)) (string-empty-p text))
      text
    (condition-case err
        (car (harness-redact--hold-mask text))
      (error
       (harness-log 'error "redact: masking tool text failed (%s); it is withheld" (car err))
       harness-redact--withheld-output))))

;;;; The redact_secret tool

;; The call and the result of a tool are kept in the transcript of the
;; session that made them, so a tool that redacts must not need the
;; secret in either.  The call names it by where it is read (a file with
;; a JSON path or a regexp, or an environment variable), the tool takes
;; no literal and no command, and a key it does not know is refused
;; without being named: it could be the secret in the wrong place.
;; What comes back is made from the report of `secrets/redact', which
;; holds labels, fingerprints, ids and counts and was checked for the
;; values before it left, and every failure the tool reports is reduced
;; to a message that quotes nothing of the input or of the stores.
;;
;; A model that put the value in the call anyway -- in a regexp, say --
;; is not made safe by that, but its session is: the call goes on to
;; the engine as `:input-text' and `:origin', and the engine adds the
;; session that made a call holding the secret to the scope.
;;
;; The permission chain and the jail look at the call before the tool
;; runs: the first at its `:mode' (a scan and a shape are reads, a
;; redaction is not: `harness-perms--call-kind'), the second at the file
;; of its source (`:paths').  They must see what the tool sees, so the
;; tool reads its keys the way they do: the exact keys of the schema,
;; with the kebab spellings of a Lisp caller, and no other.  A key
;; spelled another way -- `:Mode', say, which a case-blind reading would
;; take for the mode -- is refused rather than read, and the tool opens
;; the very name `:paths' gave the jail, resolved by
;; `harness-tools-resolve-path' against the session's directory.

(defconst harness-redact--tool-modes '(scan redact shape)
  "The modes of `redact_secret': count, take out, or show the shape of a file.
`scan' is the default.")

(defconst harness-redact--tool-scopes '(self sessions project all)
  "The scopes of `redact_secret'.
`self', the session that makes the call and its forks, is the default.")

(defconst harness-redact--tool-input-spellings
  '((:mode . :mode) (:source . :source) (:label . :label) (:scope . :scope)
    (:sessions . :sessions) (:project . :project) (:reason . :reason)
    (:include_forks . :include-forks) (:include-forks . :include-forks))
  "The input keys of `redact_secret' as calls spell them, with the tool's own.
Nothing else is taken, and the keys are not read case-blind: see above.")

(defconst harness-redact--tool-source-spellings
  '((:file . :file) (:json_path . :json-path) (:json-path . :json-path)
    (:regexp . :regexp) (:env . :env))
  "The source keys of `redact_secret' as calls spell them, with the tool's own.")

(defconst harness-redact--tool-source-help
  "The source says where the secret can be read, never what it is: {file, json_path}, {file, regexp} (group 1 of each match is the secret) or {env}."
  "What the tool answers when its source is not a reference.")

(defconst harness-redact--tool-input-help
  "The input takes mode, source, label, scope, sessions, project, include_forks and reason, and nothing else: the secret is never given, only where it can be read."
  "What the tool answers when its input has a key it does not take.")

(defconst harness-redact--tool-description
  (concat "Take a secret out of every copy the harness stored, or count the copies first. "
          "Refer to the secret by where it is, never by its value: source is {file, json_path}, "
          "{file, regexp} (an Emacs regexp; group 1 of each match is the secret, as in "
          "token=\\([A-Za-z0-9]+\\)) or {env}, a variable of the harness process. "
          "mode shape lists the keys and types of source.file, with the json_path to each, so you can pick "
          "a json_path without seeing a value. "
          "mode scan (the default) only counts, by session. "
          "mode redact (needs a reason) replaces every copy with [redacted: LABEL sha256:XXXXXXXX] in "
          "transcripts and forks, session records, the search index and its embeddings, Claude Code and Copilot "
          "logs, transcript and spill files, task records and the log; starts the affected provider "
          "conversations over from the redacted transcript, waits for a session that is running a turn, and "
          "records the redaction in each session it changed. "
          "scope: self (this session and its forks; the default), sessions (ids in sessions), project "
          "(directory in project) or all; include_forks (default true) adds the forks of the sessions named. "
          "The result holds counts, session ids, labels and fingerprints, never a value or a snippet. "
          "A redaction cannot recall what the model provider already received.")
  "What the model reads about the `redact_secret' tool.")

(defun harness-redact--tool-plist (value spellings help)
  "Return VALUE, a plist of a call, with its keys as SPELLINGS maps them.
Signal HELP, without quoting any of VALUE, when it is no plist or has a
key SPELLINGS lacks: such a key could be the secret itself, in the wrong
place."
  (cond ((null value) nil)
        ((and (consp value) (proper-list-p value) (keywordp (car value)) (cl-evenp (length value)))
         (cl-loop for (k v) on value by #'cddr
                  for key = (alist-get k spellings)
                  do (unless key (harness-redact--fail "%s" help))
                  append (list key v)))
        (t (harness-redact--fail "%s" help))))

(defun harness-redact--tool-input (input)
  "Return INPUT, the input of a call, with its keys as the tool names them."
  (harness-redact--tool-plist input harness-redact--tool-input-spellings harness-redact--tool-input-help))

(defun harness-redact--tool-file (input)
  "Return the file that the source of the call INPUT names, or nil.
The keys are read as the tool reads them, so that the jail checks the
very file the tool then opens.  Nothing signals: a call the tool will
refuse names no file."
  (let* ((p (ignore-errors (harness-redact--tool-input input)))
         (source (plist-get p :source))
         (s (and (consp source)
                 (ignore-errors (harness-redact--tool-plist source harness-redact--tool-source-spellings
                                                            harness-redact--tool-source-help))))
         (file (plist-get s :file)))
    (and (stringp file) (not (string-blank-p file)) file)))

(defun harness-redact--tool-paths (input)
  "Return the files the `redact_secret' call INPUT reads, for the jail."
  (let ((file (harness-redact--tool-file input)))
    (and file (list file))))

(defun harness-redact--tool-subject (input)
  "Return what the call INPUT is about: its mode, then what it names.
That is the label, else the file's name, else the variable's.  Nothing
signals."
  (let* ((p (ignore-errors (harness-redact--tool-input input)))
         (given (plist-get p :mode))
         (mode (cond ((null given) "scan")
                     ((and (stringp given) (member (downcase (string-trim given)) '("scan" "redact" "shape")))
                      (downcase (string-trim given)))
                     ((memq given harness-redact--tool-modes) (symbol-name given))
                     (t "?")))
         (source (let ((s (plist-get p :source)))
                   (and (consp s)
                        (ignore-errors (harness-redact--tool-plist s harness-redact--tool-source-spellings
                                                                   harness-redact--tool-source-help)))))
         (label (let ((l (plist-get p :label)))
                  (and (stringp l) (not (string-blank-p l)) (string-trim l))))
         (file (let ((f (plist-get source :file)))
                 (and (stringp f) (not (string-empty-p (file-name-nondirectory f))) (file-name-nondirectory f))))
         (env (let ((e (plist-get source :env))) (and (stringp e) (not (string-blank-p e)) e)))
         (what (or label file env)))
    (string-trim (format "%s %s" mode (if what (truncate-string-to-width what 60 nil nil "…") "")))))

(defun harness-redact--tool-mode (p)
  "Return the mode of the call whose input is P: `scan' unless it says."
  (if (null (plist-get p :mode))
      'scan
    (harness-redact--symbol (plist-get p :mode) "The mode" harness-redact--tool-modes)))

(defun harness-redact--tool-string (plist key what &optional trim)
  "Return the string at KEY of PLIST, or nil when it has none.
A blank string has none, as a model that fills in every field of a form
means by an empty one.  Signal that WHAT is a string when the value is
something else.  With TRIM the string is trimmed."
  (let ((value (plist-get plist key)))
    (cond ((null value) nil)
          ((not (stringp value)) (harness-redact--fail "%s is a string" what))
          ((string-blank-p value) nil)
          (trim (string-trim value))
          (t value))))

(defun harness-redact--tool-parts (p)
  "Return the parts of the source that the input P of a call names.
They are a plist of `:file', `:json-path', `:regexp' and `:env', each nil
when the source gives none.  Signal, without quoting the source, when it
is no reference: a literal and a command are refused here, however the
call spells them, and so is any key the tool does not know."
  (let ((source (plist-get p :source)))
    (unless (and (consp source) (keywordp (car source)))
      (harness-redact--fail "%s" harness-redact--tool-source-help))
    (when (cl-loop for (k _v) on source by #'cddr thereis (memq k '(:literal :command)))
      (harness-redact--fail "%s A secret's text or a command that prints it is not accepted."
                            harness-redact--tool-source-help))
    (let ((s (harness-redact--tool-plist source harness-redact--tool-source-spellings
                                         harness-redact--tool-source-help)))
      (let ((parts (list :file (harness-redact--tool-string s :file "source.file")
                         :json-path (harness-redact--tool-string s :json-path "source.json_path")
                         :regexp (harness-redact--tool-string s :regexp "source.regexp")
                         :env (harness-redact--tool-string s :env "source.env"))))
        (when (and (plist-get parts :env)
                   (or (plist-get parts :file) (plist-get parts :json-path) (plist-get parts :regexp)))
          (harness-redact--fail "source.env stands alone: give it, or a file, not both"))
        (unless (or (plist-get parts :env) (plist-get parts :file))
          (harness-redact--fail "%s" harness-redact--tool-source-help))
        (when (and (plist-get parts :json-path) (plist-get parts :regexp))
          (harness-redact--fail "Give source.json_path or source.regexp, not both"))
        parts))))

(defun harness-redact--tool-reference (parts ctx)
  "Return the reference to the secret that PARTS name, for the call made in CTX.
A file is the one the jail was shown, resolved against CTX's directory.
A variable is looked at here, so that the engine never has to quote its
name in an error."
  (if-let* ((name (plist-get parts :env)))
      (progn
        (unless (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" name)
          (harness-redact--fail "source.env is the name of a variable, such as DO_TOKEN"))
        (unless (let ((value (getenv name))) (and value (not (string-empty-p value))))
          (harness-redact--fail "The variable named in source.env is not set in the harness process"))
        (list :env name))
    (let ((file (harness-tools-resolve-path (plist-get parts :file) ctx)))
      (cond ((plist-get parts :json-path) (list :file file :json-path (plist-get parts :json-path)))
            ((plist-get parts :regexp) (list :file file :regexp (plist-get parts :regexp)))
            (t (harness-redact--fail
                "A file source needs a json_path or a regexp, which says where in it the secret is; mode shape shows the keys of a JSON file"))))))

(defun harness-redact--tool-scope (p ctx)
  "Return the scope parameters of `secrets/redact' for the call P made in CTX.
`self' is the session that made the call, `sessions' the ones named, and
a project's directory is read relative to CTX's."
  (let* ((scope (if (null (plist-get p :scope))
                    'self
                  (harness-redact--symbol (plist-get p :scope) "The scope" harness-redact--tool-scopes)))
         (sessions (plist-get p :sessions))
         (project (harness-redact--tool-string p :project "project"))
         (sid (plist-get ctx :session-id)))
    (when (and sessions (not (eq scope 'sessions)))
      (harness-redact--fail "sessions goes with the scope sessions: say scope sessions, or leave sessions out"))
    (when (and project (not (eq scope 'project)))
      (harness-redact--fail "project goes with the scope project: say scope project, or leave project out"))
    (pcase scope
      ('self
       (unless (and (stringp sid) (not (string-empty-p sid)))
         (harness-redact--fail "The scope self is the session that makes the call, and this call has none: name sessions, a project or all"))
       (list :scope 'session :sessions (list sid)))
      ('sessions
       (let ((ids (harness-redact--id-list sessions)))
         (unless ids
           (harness-redact--fail "The scope sessions needs sessions: a list of session ids"))
         (list :scope 'session :sessions ids)))
      ('project
       (unless project
         (harness-redact--fail "The scope project needs project: the project's directory"))
       (list :scope 'project
             :project (expand-file-name project (or (plist-get ctx :cwd) default-directory))))
      (_ (list :scope 'all)))))

(defun harness-redact--tool-forks (p)
  "Return (:include-forks VALUE) when the call P says, else nil."
  (let ((value (plist-get p :include-forks)))
    (cond ((null value) nil)
          ((eq value t) (list :include-forks t))
          ((eq value :false) (list :include-forks :false))
          (t (harness-redact--fail "include_forks is true or false")))))

(defun harness-redact--tool-input-text (input)
  "Return INPUT, the input of a call, as the JSON text its node keeps.
The engine looks in it for the secret, which should not be there."
  (condition-case nil
      (harness-json-encode-text input)
    (error (let ((print-length nil) (print-level nil))
             (prin1-to-string input t)))))

(defun harness-redact--tool-summary (report)
  "Return what the result of a call keeps of REPORT, a `secrets/redact' report.
Counts, ids, labels and fingerprints, with no value and none of the text."
  (harness-redact--compact
   (list :mode (format "%s" (plist-get report :mode))
         :scope (plist-get report :scope)
         :total (or (plist-get report :total) 0)
         :secrets (mapcar (lambda (s) (list :label (plist-get s :label)
                                            :fingerprint (plist-get s :fingerprint)))
                          (plist-get report :secrets))
         :sessions (mapcar (lambda (s) (plist-get s :id)) (plist-get report :sessions))
         :deferred (plist-get report :deferred)
         :errors (length (plist-get report :errors))
         :remaining (length (plist-get report :remaining))
         :complete (if (plist-get report :complete) t :false))))

(defun harness-redact--tool-text (report mode)
  "Return the text a `redact_secret' call in MODE answers with, from REPORT.
The report's own text, and for a redaction what no redaction can do, and
for a scan that found something how to go on."
  (let ((text (plist-get report :text)))
    (pcase mode
      ('redact
       (concat text "\n\nRedaction cannot recall what the model provider already received;"
               " whether to rotate the secret is the owner's decision."))
      ((and 'scan (guard (> (or (plist-get report :total) 0) 0)))
       (concat text "\n\nCall again with mode redact, and a reason, to take these out."))
      (_ text))))

(defun harness-redact--tool-redact (p mode ctx input)
  "Scan or redact in MODE for the call made in CTX, whose input is P.
INPUT is the input as it came.  Return the result of the tool: the text
of the report, and its summary for the node."
  (let* ((parts (harness-redact--tool-parts p))
         (ref (harness-redact--tool-reference parts ctx))
         (scope (harness-redact--tool-scope p ctx))
         (label (harness-redact--tool-string p :label "label" t))
         (reason (harness-redact--tool-string p :reason "reason" t))
         (sid (plist-get ctx :session-id)))
    (when (and (eq mode 'redact) (null reason))
      (harness-redact--fail "A redaction needs a reason: say in a sentence why the secret is taken out"))
    (let ((report (harness-call
                   'secrets/redact
                   (append (list :source ref :mode mode
                                 :input-text (harness-redact--tool-input-text input))
                           (and label (list :label label))
                           (and reason (list :reason reason))
                           (and (stringp sid) (not (string-empty-p sid))
                                (list :origin (list :kind 'session :id sid)))
                           scope
                           (harness-redact--tool-forks p)))))
      (let ((text (harness-redact--tool-text report mode))
            (meta (list :redaction (harness-redact--tool-summary report))))
        ;; A request that failed in a store, or left a copy behind, is an
        ;; error to the model: it is never told a redaction is done when it
        ;; is not.  The text is the same report either way.
        (if (or (plist-get report :errors) (plist-get report :remaining))
            (harness-tool-error text :meta meta)
          (harness-tool-ok text :meta meta))))))

(defun harness-redact--tool-shape (p ctx)
  "Show the keys and types of the JSON file that the source of the call P names.
CTX is the call's context.  A value is never shown, nor how long it is."
  (let* ((parts (harness-redact--tool-parts p))
         (file (plist-get parts :file)))
    (when (or (plist-get parts :env) (plist-get parts :regexp) (null file))
      (harness-redact--fail
       "Mode shape reads the keys and types of a JSON file: give source.file, and source.json_path to look at a part of it"))
    (let* ((path (harness-tools-resolve-path file ctx))
           (json-path (plist-get parts :json-path))
           (shape (harness-call 'secrets/shape path json-path))
           (entries (append (plist-get shape :paths) nil)))
      (harness-tool-ok
       (concat (format "Shape of %s%s: %s%s.\nEach line is a path, which source.json_path takes as it is, and the type of what is there; no value is shown.\n"
                       (abbreviate-file-name (plist-get shape :file))
                       (if json-path (format " under %s" json-path) "")
                       (harness-redact--n (length entries) "path")
                       (if (plist-get shape :truncated)
                           " (there are more: give json_path to look at a part)"
                         ""))
               (mapconcat (lambda (e) (format "  %s  %s" (plist-get e :path) (plist-get e :type)))
                          entries "\n"))
       :meta (list :shape (list :file (plist-get shape :file) :paths (length entries)
                                :truncated (if (plist-get shape :truncated) t :false)))))))

(defun harness-redact--tool (input ctx)
  "Handler of redact_secret for the call INPUT made in CTX.
It scans, redacts or shows the shape of a file.  A failure answers with a
message that quotes nothing of INPUT or of the stores
\(`harness-redact--error-text'), whatever signalled it."
  (condition-case err
      (let* ((p (harness-redact--tool-input input))
             (mode (harness-redact--tool-mode p)))
        (if (eq mode 'shape)
            (harness-redact--tool-shape p ctx)
          (harness-redact--tool-redact p mode ctx input)))
    (error (harness-tool-error (harness-redact--error-text err)))))

(harness-define-tool "redact_secret"
  :label "Redact secret"
  :description harness-redact--tool-description
  :schema '(:type "object"
            :properties (:mode (:type "string" :enum ("scan" "redact" "shape")
                                :description "scan (default) counts and changes nothing; redact takes the secret out; shape lists the keys and types of source.file.")
                         :source (:type "object"
                                  :properties (:file (:type "string"
                                                      :description "A file that holds the secret, such as a Terraform state; relative to this session's directory.")
                                               :json_path (:type "string"
                                                           :description "Where in the JSON file: outputs.keys.value, with * for every key or element and [\"a.b\"] for a key with dots. A string, or an object or array whose strings are all secrets.")
                                               :regexp (:type "string"
                                                        :description "An Emacs regexp over the file's text; group 1 of each match is the secret. Instead of json_path.")
                                               :env (:type "string"
                                                     :description "The name of an environment variable of the harness process. Instead of file."))
                                  :description "Where the secret can be read, never the secret itself: file with json_path or regexp, or env.")
                         :label (:type "string"
                                 :description "What the secret is called in its placeholder and the records, such as spaces-key.")
                         :scope (:type "string" :enum ("self" "sessions" "project" "all")
                                 :description "Which sessions: self (default), sessions (the ids in sessions), project (the sessions of the directory in project) or all.")
                         :sessions (:type "array" :items (:type "string")
                                    :description "Session ids, or the start of them, for the scope sessions.")
                         :project (:type "string"
                                   :description "The project's directory, for the scope project.")
                         :include_forks (:type "boolean"
                                         :description "Whether the forks of the sessions in scope are included (default true).")
                         :reason (:type "string"
                                  :description "Why the secret is taken out; required for redact, and kept in the records."))
            :required ("source"))
  :kind 'meta
  :paths #'harness-redact--tool-paths
  :subject #'harness-redact--tool-subject
  :timeout 1800
  :handler #'harness-redact--tool)

;;;; Init

(defun harness-redact--install ()
  "Subscribe to what the engine follows, and add its filters.  Safe to call again."
  (harness-on 'agent/turn-ended #'harness-redact--on-turn-ended 5)
  (harness-on 'session/deleted #'harness-redact--on-session-deleted)
  (harness-add-filter 'tools/output #'harness-redact--filter-output 4)
  (harness-add-filter 'tools/output-text #'harness-redact--filter-text 4))

(defun harness-redact--uninstall ()
  "Stop following, and forget the secrets that redactions wait with."
  (harness-off (cons 'agent/turn-ended #'harness-redact--on-turn-ended))
  (harness-off (cons 'session/deleted #'harness-redact--on-session-deleted))
  (harness-remove-filter 'tools/output #'harness-redact--filter-output)
  (harness-remove-filter 'tools/output-text #'harness-redact--filter-text)
  (clrhash harness-redact--pending))

(defun harness-redact--init ()
  "Start the module: follow turns, mask while a redaction waits, settle flags."
  (harness-redact--install)
  (harness-redact--settle-flagged))

;; A reload does not run `:init' again for a ready module, so the
;; subscriptions are made here too.
(harness-redact--install)

(harness-declare-event 'secrets/redacted
  "(SUMMARY) after a redaction took secrets out of the stores; SUMMARY is (:source REF :secrets ((:label :fingerprint)...) :sessions IDS): labels, fingerprints and ids, never a value")

(harness-define-module 'redact
  :doc "Takes a secret out of the transcripts and every other copy the harness keeps."
  :requires '(secrets session store)
  :init #'harness-redact--init
  :shutdown #'harness-redact--uninstall)

(provide 'harness-redact)
;;; harness-redact.el ends here
