;;; harness-session.el --- Sessions and transcripts -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A session is one conversation: identity, project scope, configuration,
;; status, transcript and usage.  Sessions live on disk under the XDG data
;; directory and stay "active" in memory once opened, even when idle.
;;
;; The transcript is a vector of entries shaped like ACP `session/update'
;; payloads plus `:id' and `:time'.  Streaming content is coalesced: the
;; agent calls `stream-begin'/`stream-chunk'/`stream-end' and only the
;; materialized entry reaches the transcript file, while every chunk is
;; emitted as `session-entry-added' for the UI to consume.
;;
;; Deletion rule: entries are appended in finalization order; live entries
;; are always after materialized ones.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'xdg)
(require 'harness-core)
(require 'harness-config)

(defgroup harness-session nil
  "Sessions and their transcripts."
  :group 'harness)

(defcustom harness-session-storage-directory
  (expand-file-name "harness/sessions" (xdg-data-home))
  "Directory holding persisted sessions."
  :type 'directory)

(defcustom harness-session-save-delay 0.5
  "Seconds to wait after a change before writing a session to disk."
  :type 'number)

(defcustom harness-session-page-size 50
  "Maximum number of sessions returned by one `session/list' call."
  :type 'natnum)

(define-error 'harness-session-not-found "Session not found" 'harness-user-error)

;;; Session structure

(cl-defstruct (harness-session (:constructor harness-session--make))
  id
  title
  cwd
  project-root
  additional-directories
  parent-id
  fork-entry-id
  created-at
  updated-at
  updated-float
  model
  thinking
  permission-mode
  mode
  (status 'idle)
  (unread 0)
  usage                     ; plist (:input :output :cache-read :cache-write)
  context-used
  context-size
  cost                      ; plist (:amount :currency)
  worktree
  (entries [])
  (persisted 0)
  entries-loaded
  (live (make-hash-table :test #'equal))
  (state (make-hash-table :test #'equal))
  file)

(defun harness-session-ensure-entry (entry)
  "Return ENTRY with an :id and :time, adding them when missing.
The id and time are mirrored in _meta so the ACP projection can strip the
root-level fields (which the protocol reserves) without losing them."
  (let ((id (or (plist-get entry :id) (harness-uuid)))
        (time (or (plist-get entry :time) (harness-iso-time))))
    (append (list :id id :time time
                  :_meta (list :harness (list :entryId id :time time)))
            (seq-remove (lambda (key) (memq key '(:id :time :_meta)))
                        (cl-loop for (key value) on entry by #'cddr
                                 append (list key value))))))

(defun harness-session-thinking-string (session)
  "Return SESSION's thinking level as a JSON-safe value."
  (let ((thinking (harness-session-thinking session)))
    (cond ((null thinking) nil)
          ((symbolp thinking) (symbol-name thinking))
          (t thinking))))

(defun harness-session-info (session)
  "Return the JSON-able info plist for SESSION."
  (list :sessionId (harness-session-id session)
        :cwd (harness-session-cwd session)
        :additionalDirectories (or (harness-session-additional-directories session) [])
        :title (harness-session-title session)
        :createdAt (harness-session-created-at session)
        :updatedAt (harness-session-updated-at session)
        :updatedEpoch (harness-session-updated-float session)
        :projectRoot (harness-session-project-root session)
        :parentId (harness-session-parent-id session)
        :forkEntryId (harness-session-fork-entry-id session)
        :model (harness-session-model session)
        :thinking (harness-session-thinking session)
        :permissionMode (harness-session-permission-mode session)
        :mode (harness-session-mode session)
        :status (symbol-name (harness-session-status session))
        :unread (harness-session-unread session)
        :usage (harness-session-usage session)
        :contextUsed (harness-session-context-used session)
        :contextSize (harness-session-context-size session)
        :cost (harness-session-cost session)
        :worktree (harness-session-worktree session)
        :messageCount (length (harness-session-entries session))))

;;; Project scope and paths

(defvar harness-session--project-ids (make-hash-table :test #'equal)
  "Project root -> storage directory name.")

(defun harness-session--project-id (project-root)
  "Return the storage directory name for PROJECT-ROOT."
  (or (gethash project-root harness-session--project-ids)
      (puthash project-root
               (format "%s-%s"
                       (replace-regexp-in-string
                        "[^[:alnum:]._-]" "_"
                        (file-name-nondirectory (directory-file-name project-root)))
                       (substring (secure-hash 'md5 project-root) 0 8))
               harness-session--project-ids)))

(defun harness-session-directory (session)
  "Return the storage directory of SESSION."
  (expand-file-name (harness-session-id session)
                    (expand-file-name (harness-session--project-id
                                       (harness-session-project-root session))
                                      harness-session-storage-directory)))

(defun harness-session--metadata-file (session)
  "Return the metadata file of SESSION."
  (expand-file-name "session.json" (harness-session-directory session)))

(defun harness-session--transcript-file (session)
  "Return the transcript file of SESSION."
  (expand-file-name "transcript.jsonl" (harness-session-directory session)))

(defun harness-session--write-atomic (file content)
  "Write CONTENT to FILE atomically."
  (make-directory (file-name-directory file) t)
  (let ((temporary (concat file ".tmp"))
        (create-lockfiles nil)
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file temporary
      (insert content))
    (rename-file temporary file t)))

;;; Active registry

(defvar harness-session--active (make-hash-table :test #'equal)
  "Session id -> `harness-session' for sessions open in this Emacs.")

(defvar harness-session--by-project nil
  "Cache of project root -> session ids found on disk; cleared on writes.")

(defun harness-session-active (id)
  "Return the active session for ID, or nil."
  (gethash id harness-session--active))

(defun harness-session-active-list ()
  "Return all active sessions."
  (hash-table-values harness-session--active))

(defun harness-session--remember (session)
  "Add SESSION to the active registry."
  (puthash (harness-session-id session) session harness-session--active)
  session)

(defun harness-session--forget (session)
  "Remove SESSION from the active registry."
  (remhash (harness-session-id session) harness-session--active))

;;; Persistence

(defun harness-session--state-plist (session)
  "Return SESSION's arbitrary state as a plist."
  (let ((plist nil))
    (maphash (lambda (key value)
               (setq plist (plist-put plist (intern (concat ":" (symbol-name key))) value)))
             (harness-session-state session))
    plist))

(defun harness-session--state-key (key)
  "Normalize state KEY to a plain symbol.
State keys are stored as symbols and projected as keywords; accepting
`:foo' and `foo' alike avoids the `::foo' entries a keyword would
otherwise create."
  (if (keywordp key)
      (intern (substring (symbol-name key) 1))
    key))

(defun harness-session-state-get (session key &optional default)
  "Return SESSION's state value for KEY, or DEFAULT."
  (gethash (harness-session--state-key key) (harness-session-state session) default))

(defun harness-session-state-set (session key value)
  "Set SESSION's state KEY to VALUE."
  (puthash (harness-session--state-key key) value (harness-session-state session))
  (harness-session--schedule-save session)
  value)

(defun harness-session-state-delete (session key)
  "Remove KEY from SESSION's state."
  (remhash (harness-session--state-key key) (harness-session-state session))
  (harness-session--schedule-save session))

(defun harness-session--metadata-plist (session)
  "Return the on-disk metadata plist for SESSION."
  (harness-plist-omit-nil
   (list :sessionId (harness-session-id session)
        :cwd (harness-session-cwd session)
        :title (harness-session-title session)
        :createdAt (harness-session-created-at session)
        :updatedAt (harness-session-updated-at session)
        :updatedEpoch (harness-session-updated-float session)
        :projectRoot (harness-session-project-root session)
        :additionalDirectories (or (harness-session-additional-directories session) [])
        :parentId (harness-session-parent-id session)
        :forkEntryId (harness-session-fork-entry-id session)
        :model (harness-session-model session)
        :thinking (harness-session-thinking-string session)
        :permissionMode (symbol-name (or (harness-session-permission-mode session) 'ask))
        :mode (harness-session-mode session)
        :status (symbol-name (harness-session-status session))
        :unread (harness-session-unread session)
        :usage (harness-session-usage session)
        :contextUsed (harness-session-context-used session)
        :contextSize (harness-session-context-size session)
        :cost (harness-session-cost session)
        :worktree (harness-session-worktree session)
        :state (let ((state (harness-session--state-plist session)))
                 (unless (null state) state)))))

(defun harness-session--session-from-metadata (metadata)
  "Create an inactive (no transcript) session from METADATA."
  (harness-session--make
   :id (plist-get metadata :sessionId)
   :title (plist-get metadata :title)
   :cwd (plist-get metadata :cwd)
   :project-root (plist-get metadata :projectRoot)
   :additional-directories (plist-get metadata :additionalDirectories)
   :parent-id (plist-get metadata :parentId)
   :fork-entry-id (plist-get metadata :forkEntryId)
   :created-at (plist-get metadata :createdAt)
   :updated-at (plist-get metadata :updatedAt)
   :updated-float (plist-get metadata :updatedEpoch)
   :model (plist-get metadata :model)
   :thinking (plist-get metadata :thinking)
   :permission-mode (let ((mode (plist-get metadata :permissionMode)))
                      (cond ((symbolp mode) mode)
                            ((stringp mode) (intern mode))
                            (t 'ask)))
   :mode (plist-get metadata :mode)
   :status (intern (or (plist-get metadata :status) "idle"))
   :unread (or (plist-get metadata :unread) 0)
   :usage (plist-get metadata :usage)
   :context-used (plist-get metadata :contextUsed)
   :context-size (plist-get metadata :contextSize)
   :cost (plist-get metadata :cost)
   :worktree (plist-get metadata :worktree)
   :state (let ((table (make-hash-table :test #'equal))
                (state (plist-get metadata :state)))
            (cl-loop for (key value) on state by #'cddr
                     do (puthash (intern (substring (symbol-name key) 1)) value table))
            table)))

(defun harness-session--read-metadata (file)
  "Read a metadata FILE, returning a plist or nil."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-string (buffer-string) :object-type 'plist))
    (error (harness-log "cannot read session metadata %s: %S" file err) nil)))

(defun harness-session-save (session)
  "Write SESSION's metadata and new transcript entries to disk."
  (let ((file (harness-session--metadata-file session)))
    (condition-case err
        (progn
          (harness-session--write-atomic
           file (harness-json-serialize (harness-session--metadata-plist session)))
          (harness-session--append-new-entries session))
      (error
       (harness-log "cannot save session %s: %S" (harness-session-id session) err)
       ;; Saves happen from timers; never steal the echo area or pop a
       ;; warning buffer for something the user cannot act on right now.
       (unless (or noninteractive (active-minibuffer-window))
         (message "harness: session not saved (%s)" (error-message-string err))))))
  session)

(defun harness-session--append-new-entries (session)
  "Append transcript entries not yet persisted."
  (let ((entries (harness-session-entries session))
        (persisted (harness-session-persisted session)))
    (when (< persisted (length entries))
      (let ((file (harness-session--transcript-file session))
            ;; Writing never visits the file and never asks anything: a save
            ;; runs from a timer and must not touch the minibuffer.
            (create-lockfiles nil)
            (coding-system-for-write 'utf-8-unix))
        (make-directory (file-name-directory file) t)
        (with-temp-buffer
          (cl-loop for index from persisted below (length entries)
                   for entry = (aref entries index)
                   do (insert (harness-json-serialize entry) "\n"))
          (write-region (point-min) (point-max) file nil 'silent))
        (setf (harness-session-persisted session) (length entries))))))

(defun harness-session--schedule-save (session)
  "Persist SESSION after a quiet period."
  (harness-batch (list 'harness-session-save (harness-session-id session))
                 harness-session-save-delay
                 (lambda () (harness-session-save session))))

(defun harness-session--touch (session)
  "Mark SESSION as updated now."
  (setf (harness-session-updated-at session) (harness-iso-time)
        (harness-session-updated-float session) (harness-now)))

;;; Creating, loading, deleting

(defun harness-session-create (&rest args)
  "Create a session.
ARGS: :cwd (required), :title, :additional-directories, :parent-id,
:fork-entry-id, :model, :thinking, :permission-mode, :mode."
  (let* ((cwd (plist-get args :cwd))
         (directory (and cwd (file-name-absolute-p cwd)
                         (file-name-as-directory (expand-file-name cwd))))
         (session nil))
    (unless cwd
      (signal 'harness-user-error (list "A session needs a :cwd")))
    (unless directory
      (signal 'harness-user-error (list (format "Session cwd is not absolute: %s" cwd))))
    (setq session
          (harness-session--make
                   :id (harness-uuid)
                   :title (plist-get args :title)
                   :cwd directory
                   :project-root (harness-config-project-root directory)
                   :additional-directories (plist-get args :additional-directories)
                   :parent-id (plist-get args :parent-id)
                   :fork-entry-id (plist-get args :fork-entry-id)
                   :created-at (harness-iso-time)
                   :updated-at (harness-iso-time)
                   :updated-float (harness-now)
                   :model (plist-get args :model)
                   :thinking (plist-get args :thinking)
                   :permission-mode (or (plist-get args :permission-mode) 'ask)
                   :mode (or (plist-get args :mode) "code")
                   :usage (list :input 0 :output 0 :cache-read 0 :cache-write 0)
                   :cost (list :amount 0.0 :currency (or (plist-get args :currency) "USD"))
                   :entries-loaded t))
    (harness-session--remember session)
    (setq harness-session--by-project nil)
    (harness-session-save session)
    (harness-emit 'session-created :session-id (harness-session-id session) :session session)
    session))

(defun harness-session-load (id &optional directory)
  "Return the active session ID, loading it from disk when needed.
DIRECTORY optionally hints where the session's project lives."
  (or (harness-session-active id)
      (let ((session-directory (harness-session--find-directory id directory)))
        (unless session-directory
          (signal 'harness-session-not-found (list id)))
        (let* ((metadata (harness-session--read-metadata
                          (expand-file-name "session.json" session-directory)))
               (session (and metadata (harness-session--session-from-metadata metadata))))
          (unless session
            (signal 'harness-session-not-found (list id)))
          (setf (harness-session-file session)
                (expand-file-name "session.json" session-directory))
          (harness-session--remember session)
          session))))

(defun harness-session--find-directory (id &optional directory)
  "Find the directory of session ID, optionally starting at DIRECTORY.
Returns the session's own directory, not the project directory."
  (let* ((candidate (and directory
                         (expand-file-name
                          (harness-session--project-id
                           (harness-config-project-root directory))
                          harness-session-storage-directory)))
         (project-dir
          (or (and candidate
                   (file-exists-p (expand-file-name (concat id "/session.json") candidate))
                   candidate)
              (seq-find (lambda (project-dir)
                          (file-exists-p (expand-file-name (concat id "/session.json")
                                                          project-dir)))
                        (harness-session--project-directories)))))
    (when project-dir
      (expand-file-name id project-dir))))

(defun harness-session--project-directories ()
  "Return the existing project storage directories."
  (let ((root harness-session-storage-directory))
    (and (file-directory-p root)
         (seq-filter #'file-directory-p
                     (directory-files root t "\\`[^.]" t)))))

(defun harness-session-load-entries-async (session)
  "Load SESSION's transcript from disk without blocking for long.
Returns a deferred that resolves to the entries vector."
  (let ((deferred (harness-deferred-new))
        (file (harness-session--transcript-file session)))
    (if (not (file-exists-p file))
        (progn
          (setf (harness-session-entries session) []
                (harness-session-persisted session) 0
                (harness-session-entries-loaded session) t)
          (harness-deferred-resolve deferred (harness-session-entries session)))
      (condition-case err
          (let* ((buffer (generate-new-buffer " *harness-transcript*"))
                 (accum nil))
            (with-current-buffer buffer
              (insert-file-contents file))
            (cl-labels ((parse-more ()
                          ;; Parse a bounded number of lines per call.
                          (let ((count 0))
                            (while (and (< count 500) (not (eobp)))
                              (let ((line (buffer-substring-no-properties
                                           (line-beginning-position) (line-end-position))))
                                (forward-line 1)
                                (unless (string-empty-p (string-trim line))
                                  (condition-case err
                                      (push (json-parse-string line :object-type 'plist) accum)
                                    (error (harness-log "skipping bad transcript line: %S" err)))))
                              (cl-incf count))
                            (not (eobp))))
                         (tick ()
                          (let ((more (with-current-buffer buffer
                                        (harness-budget-run 0.01 #'parse-more))))
                            (if more
                                (run-at-time 0 nil #'tick)
                              (let ((entries (vconcat (nreverse accum))))
                                (setf (harness-session-entries session) entries
                                      (harness-session-persisted session) (length entries)
                                      (harness-session-entries-loaded session) t)
                                (kill-buffer buffer)
                                (harness-deferred-resolve deferred entries))))))
              (tick)))
        (error
         (harness-deferred-reject deferred (cons (car err) (cdr err))))))
    deferred))

(defun harness-session-ensure-entries (session)
  "Return a deferred resolving to SESSION's entries, loading them if needed."
  (if (harness-session-entries-loaded session)
      (let ((deferred (harness-deferred-new)))
        (harness-deferred-resolve deferred (harness-session-entries session))
        deferred)
    (harness-session-load-entries-async session)))

(defun harness-session-with-loaded-entries (session function)
  "Call FUNCTION with SESSION once its transcript is in memory.
Returns FUNCTION's value, or a deferred when the transcript still has to
be read from disk."
  (if (harness-session-entries-loaded session)
      (funcall function session)
    (harness-deferred-then (harness-session-load-entries-async session)
                           (lambda (_entries) (funcall function session)))))

(defun harness-session-delete (session)
  "Delete SESSION and its files."
  (let ((id (harness-session-id session))
        (directory (file-name-directory (harness-session--metadata-file session))))
    (harness-session--forget session)
    (when (file-directory-p directory)
      (delete-directory directory t))
    (setq harness-session--by-project nil)
    (harness-emit 'session-deleted :session-id id)))

;;; Entries and streaming

(defun harness-session-append (session entry)
  "Append a materialized ENTRY to SESSION."
  (let ((entry (harness-session-ensure-entry entry)))
    (setf (harness-session-entries session)
          (vconcat (harness-session-entries session) (list entry)))
    (harness-session--touch session)
    (harness-session--note-activity session entry)
    (harness-session--schedule-save session)
    (harness-emit 'session-entry-added
                  :session-id (harness-session-id session)
                  :session session
                  :entry entry
                  :final t)
    entry))

(defun harness-session-stream-begin (session key entry)
  "Start a live entry for KEY in SESSION, based on ENTRY."
  (let ((entry (harness-session-ensure-entry entry)))
    (puthash key entry (harness-session-live session))
    (harness-session--touch session)
    (harness-emit 'session-entry-added
                  :session-id (harness-session-id session)
                  :session session
                  :entry entry
                  :live t)
    entry))

(defun harness-session--live (session key)
  "Return the live entry for KEY in SESSION."
  (gethash key (harness-session-live session)))

(defun harness-session-stream-chunk (session key update)
  "Merge UPDATE into the live entry for KEY in SESSION and emit it."
  (let* ((existing (harness-session--live session key))
         (entry (if existing
                    (harness-session--merge-update existing update)
                  (harness-session-ensure-entry update))))
    (puthash key entry (harness-session-live session))
    (harness-session--touch session)
    (harness-emit 'session-entry-added
                  :session-id (harness-session-id session)
                  :session session
                  :entry entry
                  :live t
                  :delta (harness-session--update-text update))
    entry))

(defun harness-session-stream-end (session key)
  "Move the live entry for KEY in SESSION into the transcript."
  (let ((entry (gethash key (harness-session-live session))))
    (if (null entry)
        (harness-log "stream-end without a live entry for %S" key)
      (remhash key (harness-session-live session))
      (setf (harness-session-entries session)
            (vconcat (harness-session-entries session) (list entry)))
      (harness-session--touch session)
      (harness-session--schedule-save session)
      (harness-emit 'session-entry-added
                    :session-id (harness-session-id session)
                    :session session
                    :entry entry
                    :final t)
      entry)))

(defun harness-session--note-activity (session update)
  "Adjust unread state for a new message UPDATE on SESSION."
  (let ((kind (plist-get update :sessionUpdate)))
    (cond
     ((equal kind "user_message_chunk")
      (setf (harness-session-unread session) 0))
     ((equal kind "agent_message_chunk")
      (cl-incf (harness-session-unread session))))))

(defun harness-session--update-text (update)
  "Return the text a chunk UPDATE appends, or nil."
  (let ((content (plist-get update :content)))
    (when (and (listp content) (equal (plist-get content :type) "text"))
      (plist-get content :text))))

(defun harness-session--merge-update (entry update)
  "Merge UPDATE into ENTRY following ACP chunk semantics."
  (let ((kind (plist-get update :sessionUpdate)))
    (cond
     ((member kind '("agent_message_chunk" "agent_thought_chunk" "user_message_chunk"))
      (let* ((existing (plist-get entry :content))
             (incoming (plist-get update :content)))
        (setf (plist-get entry :content)
              (if (and (listp existing) (listp incoming)
                       (equal (plist-get existing :type) "text")
                       (equal (plist-get incoming :type) "text"))
                  (plist-put existing :text
                             (concat (or (plist-get existing :text) "")
                                     (or (plist-get incoming :text) "")))
                (harness-session--append-blocks existing incoming)))))
     ((equal kind "tool_call_update")
      (dolist (key '(:title :name :kind :status :rawInput :rawOutput :locations))
        (when (plist-member update key)
          (setf (plist-get entry key) (plist-get update key))))
      (when (plist-member update :content)
        (setf (plist-get entry :content)
              (harness-session--append-blocks (plist-get entry :content)
                                              (plist-get update :content)))))
     ((equal kind "usage_update")
      (dolist (key '(:used :size :cost))
        (when (plist-member update key)
          (setf (plist-get entry key) (plist-get update key)))))
     (t
      (dolist (pair (cddr update))
        (setf (plist-get entry (car pair)) (car (cdr pair))))))
    entry))

(defun harness-session--blocks (content)
  "Return CONTENT as a list of content blocks."
  (cond
   ((null content) nil)
   ((vectorp content) (append content nil))
   ((and (listp content) (plist-get content :type)) (list content))
   ((listp content) content)
   (t (list content))))

(defun harness-session--append-blocks (existing incoming)
  "Append INCOMING content blocks to EXISTING, both as block lists."
  (vconcat (harness-session--blocks existing) (harness-session--blocks incoming)))

(defun harness-session-system-hint (session text &optional level)
  "Append a harness system hint TEXT to SESSION.
LEVEL is \"info\", \"warning\" or \"error\"."
  (harness-session-append
   session
   (list :sessionUpdate "_harness/system_hint"
         :content (list :type "text" :text text)
         :level (or level "info"))))

;;; Status and configuration

(defconst harness-session-statuses '(idle running blocked)
  "Valid session statuses.")

(defun harness-session-set-status (session status)
  "Set SESSION's status to STATUS and emit the change."
  (unless (memq status harness-session-statuses)
    (signal 'harness-user-error (list (format "Unknown session status: %s" status))))
  (let ((previous (harness-session-status session)))
    (unless (eq previous status)
      (setf (harness-session-status session) status)
      (when (eq status 'idle)
        (setf (harness-session-unread session)
              (max (harness-session-unread session) 0)))
      (harness-session--schedule-save session)
      (harness-emit 'session-status-changed
                    :session-id (harness-session-id session)
                    :status (symbol-name status)
                    :previous (symbol-name previous)
                    :title (harness-session-title session)
                    :cwd (harness-session-cwd session)
                    :model (harness-session-model session)
                    :permission-mode (symbol-name
                                      (or (harness-session-permission-mode session) 'ask))
                    :unread (harness-session-unread session)))))

(defun harness-session-set-unread (session count)
  "Set SESSION's unread COUNT and emit a status update."
  (setf (harness-session-unread session) (max 0 count))
  (harness-emit 'session-status-changed
                :session-id (harness-session-id session)
                :status (symbol-name (harness-session-status session))
                :previous (symbol-name (harness-session-status session))
                :title (harness-session-title session)
                :cwd (harness-session-cwd session)
                :model (harness-session-model session)
                :permission-mode (symbol-name
                                  (or (harness-session-permission-mode session) 'ask))
                :unread (harness-session-unread session)))

(defun harness-session-set-title (session title)
  "Rename SESSION to TITLE."
  (setf (harness-session-title session) title)
  (harness-session--touch session)
  (harness-session--schedule-save session)
  (harness-emit 'session-info-updated
                :session-id (harness-session-id session)
                :title title
                :updatedAt (harness-session-updated-at session))
  session)

(defun harness-session-set-model (session model)
  "Set the model of SESSION to MODEL."
  (setf (harness-session-model session) model)
  (harness-session--schedule-save session)
  (harness-session--emit-config-changed session)
  session)

(defun harness-session-set-thinking (session thinking)
  "Set the thinking level of SESSION."
  (setf (harness-session-thinking session) thinking)
  (harness-session--schedule-save session)
  (harness-session--emit-config-changed session)
  session)

(defun harness-session-set-permission-mode (session mode)
  "Set the permission mode of SESSION."
  (setf (harness-session-permission-mode session) mode)
  (harness-session--schedule-save session)
  (harness-session--emit-config-changed session)
  session)

(defun harness-session-set-mode (session mode)
  "Set the session mode (\"code\", \"plan\") of SESSION."
  (setf (harness-session-mode session) mode)
  (harness-session--schedule-save session)
  (harness-session--emit-config-changed session)
  session)

(defun harness-session-set-worktree (session worktree)
  "Record WORKTREE (a plist or nil) on SESSION."
  (setf (harness-session-worktree session) worktree)
  (harness-session--schedule-save session)
  session)

(defun harness-session-add-directory (session directory)
  "Add DIRECTORY to SESSION's allowed directories."
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (unless (member directory (harness-session-additional-directories session))
      (setf (harness-session-additional-directories session)
            (append (harness-session-additional-directories session)
                    (list directory))
            (harness-session-updated-at session) (harness-iso-time))
      (harness-session--schedule-save session))
    (harness-session-additional-directories session)))

(defun harness-session--emit-config-changed (session)
  "Emit the complete configuration state of SESSION."
  (harness-emit 'session-config-changed
                :session-id (harness-session-id session)
                :config-options (plist-get (harness-session-configuration session)
                                           :configOptions)))

(defconst harness-session-permission-modes
  '(("ask" "Ask" "Ask before tools that change files or run commands")
    ("auto" "Auto" "A cheap model approves tool calls")
    ("non-interactive" "Non-interactive"
     "Never block; steer the agent instead of asking"))
  "Permission modes offered as a configuration option.")

(defconst harness-session-modes
  '(("code" "Code" "Normal implementation mode")
    ("plan" "Plan" "Plan first, do not modify files"))
  "Session modes offered as configuration options.")

(defun harness-session-model-option (session models)
  "Build the model config option for SESSION from MODELS.
MODELS is a list of (:id :name :provider) plists; nil yields a
current-value-only option."
  (let ((current (harness-session-model session)))
    (list :id "model" :name "Model" :category "model" :type "select"
          :currentValue (or current "")
          :options (if models
                       (vconcat
                        (mapcar (lambda (model)
                                  (list :value (plist-get model :id)
                                        :name (if (plist-get model :provider)
                                                  (format "%s (%s)" (plist-get model :name)
                                                          (plist-get model :provider))
                                                (plist-get model :name))))
                                models))
                     (vector (list :value (or current "") :name (or current "No model")))))))

(defun harness-session-configuration (session)
  "Return the session-service fallback configuration for SESSION.
The agent service overrides this with a provider-aware model list."
  (list :configOptions
        (vector
         (harness-session-model-option session nil)
         (list :id "permission"
               :name "Permissions" :category "mode" :type "select"
               :currentValue (symbol-name (or (harness-session-permission-mode session) 'ask))
               :options (vconcat
                         (mapcar (lambda (entry)
                                   (list :value (car entry) :name (nth 1 entry)
                                         :description (nth 2 entry)))
                                 harness-session-permission-modes)))
         (list :id "mode"
               :name "Session Mode" :category "mode" :type "select"
               :currentValue (or (harness-session-mode session) "code")
               :options (vconcat
                         (mapcar (lambda (entry)
                                   (list :value (car entry) :name (nth 1 entry)
                                         :description (nth 2 entry)))
                                 harness-session-modes))))))

(defun harness-session-set-config (session config-id value)
  "Set CONFIG-ID to VALUE on SESSION, returning its configuration."
  (pcase config-id
    ("model" (harness-session-set-model session value))
    ("thinking" (harness-session-set-thinking session (if (eq value :false) nil value)))
    ("permission" (harness-session-set-permission-mode session (intern value)))
    ("mode" (harness-session-set-mode session value))
    (_ (signal 'harness-user-error (list (format "Unknown config option: %s" config-id)))))
  (harness-session-configuration session))

;;; Usage and cost

(defun harness-session-add-usage (session &rest args)
  "Add token usage to SESSION.
ARGS: :input, :output, :cache-read, :cache-write, :context-used,
:context-size."
  (let ((usage (or (harness-session-usage session)
                   (list :input 0 :output 0 :cache-read 0 :cache-write 0))))
    (dolist (key '(:input :output :cache-read :cache-write))
      (plist-put usage key (+ (or (plist-get usage key) 0) (or (plist-get args key) 0))))
    (setf (harness-session-usage session) usage))
  (when (plist-member args :context-used)
    (setf (harness-session-context-used session) (plist-get args :context-used)))
  (when (plist-member args :context-size)
    (setf (harness-session-context-size session) (plist-get args :context-size)))
  (harness-session--schedule-save session)
  (harness-emit 'session-usage-changed
                :session-id (harness-session-id session)
                :used (or (harness-session-context-used session) 0)
                :size (or (harness-session-context-size session) 0)
                :usage (harness-session-usage session)
                :cost (harness-session-cost session))
  session)

(defun harness-session-add-cost (session amount &optional currency)
  "Add AMOUNT (float) in CURRENCY to SESSION's cost."
  (let* ((cost (or (harness-session-cost session)
                   (list :amount 0.0 :currency (or currency "USD")))))
    (plist-put cost :amount (+ (or (plist-get cost :amount) 0.0) amount))
    (plist-put cost :currency (or currency (plist-get cost :currency) "USD"))
    (setf (harness-session-cost session) cost))
  (harness-session--schedule-save session)
  (harness-emit 'session-usage-changed
                :session-id (harness-session-id session)
                :used (or (harness-session-context-used session) 0)
                :size (or (harness-session-context-size session) 0)
                :usage (harness-session-usage session)
                :cost (harness-session-cost session))
  session)

;;; Forking

(defun harness-session-fork (session &rest args)
  "Fork SESSION, returning the new session.
ARGS: :entry-id (fork point, defaults to the whole transcript), :title,
:worktree."
  (let* ((point (plist-get args :entry-id))
         (entries (harness-session-entries session))
         (kept (if point
                   (let ((index (cl-position point entries
                                             :key (lambda (entry) (plist-get entry :id))
                                             :test #'equal)))
                     (if index (seq-subseq entries 0 (1+ index)) entries))
                 entries))
         (fork (harness-session-create
                :cwd (harness-session-cwd session)
                :title (or (plist-get args :title)
                           (when (harness-session-title session)
                             (format "%s (fork)" (harness-session-title session))))
                :additional-directories (harness-session-additional-directories session)
                :parent-id (harness-session-id session)
                :fork-entry-id point
                :model (harness-session-model session)
                :thinking (harness-session-thinking session)
                :permission-mode (harness-session-permission-mode session)
                :mode (harness-session-mode session))))
    (setf (harness-session-entries fork) (vconcat kept)
          (harness-session-persisted fork) 0
          (harness-session-entries-loaded fork) t)
    (harness-session-save fork)
    fork))

(defun harness-session-children (id)
  "Return the ids of sessions whose parent is ID."
  (mapcar (lambda (info) (plist-get info :sessionId))
          (seq-filter (lambda (info) (equal (plist-get info :parentId) id))
                      (harness-session--all-infos))))

(defun harness-session-usage-entries (&optional since)
  "Return usage entries of sessions updated after SINCE (an epoch float).
Returns a vector of plists with :sessionId, :projectRoot, :model, :time,
:usage and :cost.  Transcripts of sessions updated before SINCE are not
read, which keeps period reports cheap."
  (let ((entries nil))
    (dolist (info (harness-session--all-infos))
      (let ((updated (or (plist-get info :updatedEpoch) 0)))
        (when (or (null since) (>= updated since))
          (let* ((session-id (plist-get info :sessionId))
                 (directory (expand-file-name
                             session-id
                             (expand-file-name
                              (harness-session--project-id
                               (or (plist-get info :projectRoot) default-directory))
                              harness-session-storage-directory)))
                 (file (expand-file-name "transcript.jsonl" directory)))
            (when (file-readable-p file)
              (with-temp-buffer
                (insert-file-contents file)
                (goto-char (point-min))
                (while (not (eobp))
                  (let ((line (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position))))
                    (forward-line 1)
                    (when (and (not (string-empty-p line))
                               (string-match-p "usage_update" line))
                      (let ((entry (ignore-errors
                                     (json-parse-string line :object-type 'plist))))
                        (when entry
                          (push (append (list :sessionId session-id
                                              :projectRoot (plist-get info :projectRoot))
                                        (harness-plist-omit-nil
                                         (list :title (plist-get info :title)
                                               :model (plist-get entry :model)
                                               :time (plist-get entry :time)
                                               :usage (plist-get entry :usage)
                                               :cost (plist-get entry :cost))))
                                entries))))))))))))
    (vconcat (nreverse entries))))

(defun harness-session-all-infos ()
  "Return info plists for every session known on disk or in memory."
  (vconcat (harness-session--all-infos)))

;;; Listing

(defun harness-session--all-infos ()
  "Return info plists for every session on disk, plus active ones."
  (let ((seen (make-hash-table :test #'equal))
        (infos nil))
    (dolist (project-dir (harness-session--project-directories))
      (dolist (session-dir (directory-files project-dir t "\\`[^.]" t))
        (let ((file (expand-file-name "session.json" session-dir)))
          (when (file-regular-p file)
            (when-let* ((metadata (harness-session--read-metadata file)))
              (let ((id (plist-get metadata :sessionId)))
                (when (and id (not (gethash id seen)))
                  (puthash id t seen)
                  (push metadata infos))))))))
    (dolist (session (harness-session-active-list))
      (let ((id (harness-session-id session)))
        (unless (gethash id seen)
          (puthash id t seen)
          (push (harness-session-info session) infos))))
    infos))

(defun harness-session-list (&rest args)
  "List sessions, most recently updated first.
ARGS: :cwd (scope to that project), :cursor, :limit."
  (let* ((cwd (plist-get args :cwd))
         (scope (and cwd (harness-config-project-root cwd)))
         (infos (seq-filter
                 (lambda (info)
                   (or (null scope)
                       (equal (plist-get info :projectRoot) scope)
                       (equal (plist-get info :cwd) scope)))
                 (harness-session--all-infos)))
         (sorted (sort infos (lambda (a b)
                               (> (or (plist-get a :updatedEpoch) 0)
                                  (or (plist-get b :updatedEpoch) 0)))))
         (limit (or (plist-get args :limit) harness-session-page-size))
         (offset (harness-session--cursor-offset (plist-get args :cursor)))
         (page (seq-subseq sorted (min offset (length sorted))
                           (min (+ offset limit) (length sorted)))))
    (list :sessions (vconcat page)
          :nextCursor (when (< (+ offset limit) (length sorted))
                        (base64-encode-string
                         (number-to-string (+ offset limit)) t)))))

(defun harness-session--cursor-offset (cursor)
  "Decode CURSOR into an offset."
  (if (null cursor)
      0
    (condition-case nil
        (string-to-number (base64-decode-string cursor))
      (error (signal 'harness-user-error (list "Invalid session list cursor"))))))

;;; Service

(defun harness-session--get-service (session-id)
  "Return the active session for SESSION-ID or signal."
  (or (harness-session-active session-id)
      (signal 'harness-session-not-found (list session-id))))

(defun harness-session-service-create (&rest args)
  "Service: create a session."
  (harness-session-info (apply #'harness-session-create args)))

(defun harness-session-service-load (&rest args)
  "Service: load a session."
  (let* ((session (harness-session-load (plist-get args :session-id)
                                        (plist-get args :cwd))))
    (harness-session-info session)))

(defun harness-session-service-list (&rest args)
  "Service: list sessions."
  (apply #'harness-session-list args))

(defun harness-session-service-info (&rest args)
  "Service: session info."
  (harness-session-info (harness-session--get-service (plist-get args :session-id))))

(defun harness-session-service-close (&rest args)
  "Service: close a session, keeping it on disk."
  (let ((session (harness-session-active (plist-get args :session-id))))
    (when session
      (harness-session-save session)
      (harness-session--forget session))))

(defun harness-session-service-delete (&rest args)
  "Service: delete a session."
  (let ((session (or (harness-session-active (plist-get args :session-id))
                     (harness-session-load (plist-get args :session-id)
                                           (plist-get args :cwd)))))
    (harness-session-delete session)))

(defun harness-session-service-entries (&rest args)
  "Service: return a session's transcript.
Returns the entries vector, or a deferred resolving to it while the
transcript is still being read from disk."
  (harness-session-ensure-entries
   (harness-session--get-service (plist-get args :session-id))))

(defun harness-session-service-append (&rest args)
  "Service: append a materialized entry."
  (harness-session-with-loaded-entries
   (harness-session--get-service (plist-get args :session-id))
   (lambda (session) (harness-session-append session (plist-get args :entry)))))

(defun harness-session-service-stream-begin (&rest args)
  "Service: begin a live entry."
  (harness-session-with-loaded-entries
   (harness-session--get-service (plist-get args :session-id))
   (lambda (session)
     (harness-session-stream-begin session (plist-get args :key) (plist-get args :entry)))))

(defun harness-session-service-stream-chunk (&rest args)
  "Service: merge a chunk into a live entry."
  (harness-session-with-loaded-entries
   (harness-session--get-service (plist-get args :session-id))
   (lambda (session)
     (harness-session-stream-chunk session (plist-get args :key) (plist-get args :update)))))

(defun harness-session-service-stream-end (&rest args)
  "Service: materialize a live entry."
  (harness-session-with-loaded-entries
   (harness-session--get-service (plist-get args :session-id))
   (lambda (session) (harness-session-stream-end session (plist-get args :key)))))

(defun harness-session-service-system-hint (&rest args)
  "Service: append a system hint."
  (harness-session-with-loaded-entries
   (harness-session--get-service (plist-get args :session-id))
   (lambda (session)
     (harness-session-system-hint session (plist-get args :text) (plist-get args :level)))))

(defun harness-session-service-set-status (&rest args)
  "Service: set a session's status."
  (harness-session-set-status
   (harness-session--get-service (plist-get args :session-id))
   (intern (plist-get args :status))))

(defun harness-session-service-set-unread (&rest args)
  "Service: set a session's unread count."
  (harness-session-set-unread
   (harness-session--get-service (plist-get args :session-id))
   (plist-get args :count)))

(defun harness-session-service-rename (&rest args)
  "Service: rename a session."
  (harness-session-set-title
   (harness-session--get-service (plist-get args :session-id))
   (plist-get args :title)))

(defun harness-session-service-set-config (&rest args)
  "Service: set a configuration option."
  (harness-session-set-config
   (harness-session--get-service (plist-get args :session-id))
   (plist-get args :config-id)
   (plist-get args :value)))

(defun harness-session-service-configuration (&rest args)
  "Service: return the fallback configuration of a session."
  (harness-session-configuration
   (harness-session--get-service (plist-get args :session-id))))

(defun harness-session-service-set-mode (&rest args)
  "Service: set the session mode."
  (harness-session-set-mode
   (harness-session--get-service (plist-get args :session-id))
   (plist-get args :mode-id)))

(defun harness-session-service-infos (&rest _args)
  "Service: info plists for every session known on disk or in memory."
  (harness-session-all-infos))

(defun harness-session-service-usage-entries (&rest args)
  "Service: usage entries of sessions updated after :since (epoch)."
  (harness-session-usage-entries (plist-get args :since)))

(defun harness-session-service-add-usage (&rest args)
  "Service: add usage to a session."
  (apply #'harness-session-add-usage
         (harness-session--get-service (plist-get args :session-id))
         (cddr args)))

(defun harness-session-service-add-cost (&rest args)
  "Service: add cost to a session."
  (harness-session-add-cost
   (harness-session--get-service (plist-get args :session-id))
   (plist-get args :amount)
   (plist-get args :currency)))

(defun harness-session-service-fork (&rest args)
  "Service: fork a session."
  (harness-session-info
   (harness-session-fork
    (harness-session--get-service (plist-get args :session-id))
    :entry-id (plist-get args :entry-id)
    :title (plist-get args :title))))

(defun harness-session-service-children (&rest args)
  "Service: list child session ids."
  (harness-session-children (plist-get args :session-id)))

(defun harness-session-service-active (&rest _args)
  "Service: info for every active session."
  (vconcat (mapcar #'harness-session-info (harness-session-active-list))))

;;; Module

(defun harness-session-service-state-get (&rest args)
  "Service: read a session state value."
  (harness-session-state-get (harness-session--get-service (plist-get args :session-id))
                             (plist-get args :key)
                             (plist-get args :default)))

(defun harness-session-service-state-set (&rest args)
  "Service: set a session state value."
  (harness-session-state-set (harness-session--get-service (plist-get args :session-id))
                             (plist-get args :key)
                             (plist-get args :value)))

(defun harness-session-service-state-all (&rest args)
  "Service: return all state of a session."
  (harness-session--state-plist (harness-session--get-service (plist-get args :session-id))))

(defun harness-session-service-add-directory (&rest args)
  "Service: grant a directory to a session."
  (harness-session-add-directory (harness-session--get-service (plist-get args :session-id))
                                 (plist-get args :directory)))

(defun harness-session-setup ()
  "Set up the session module."
  (harness-event-define 'session-created
    :module 'harness-session
    :doc "A session was created."
    :payload '((session-id . string) (session . harness-session)))
  (harness-event-define 'session-deleted
    :module 'harness-session
    :doc "A session was deleted."
    :payload '((session-id . string)))
  (harness-event-define 'session-status-changed
    :module 'harness-session
    :doc "A session moved between idle, running and blocked."
    :payload '((session-id . string) (status . string) (previous . string)
               (title . string) (cwd . string) (model . string)
               (permission-mode . string) (unread . integer)))
  (harness-event-define 'session-info-updated
    :module 'harness-session
    :doc "Session metadata changed."
    :payload '((session-id . string) (title . string) (updatedAt . string)))
  (harness-event-define 'session-config-changed
    :module 'harness-session
    :doc "A session configuration option changed; carries the complete state."
    :payload '((session-id . string) (config-options . vector)))
  (harness-event-define 'session-entry-added
    :module 'harness-session
    :doc "One transcript entry was added or updated."
    :payload '((session-id . string) (entry . plist)
               (live . boolean) (final . boolean) (delta . string)))
  (harness-event-define 'session-usage-changed
    :module 'harness-session
    :doc "Token usage or cost changed."
    :payload '((session-id . string) (used . integer) (size . integer)
               (usage . plist) (cost . plist)))
  (harness-service-register
   "session"
   :module 'harness-session
   :doc "Sessions, transcripts and session lifecycle."
   :methods
   '((create . harness-session-service-create)
     (load . harness-session-service-load)
     (close . harness-session-service-close)
     (delete . harness-session-service-delete)
     (list . harness-session-service-list)
     (info . harness-session-service-info)
     (entries . harness-session-service-entries)
     (append . harness-session-service-append)
     (stream-begin . harness-session-service-stream-begin)
     (stream-chunk . harness-session-service-stream-chunk)
     (stream-end . harness-session-service-stream-end)
     (system-hint . harness-session-service-system-hint)
     (infos . harness-session-service-infos)
     (usage-entries . harness-session-service-usage-entries)
     (set-status . harness-session-service-set-status)
     (set-unread . harness-session-service-set-unread)
     (rename . harness-session-service-rename)
     (set-config . harness-session-service-set-config)
     (configuration . harness-session-service-configuration)
     (set-mode . harness-session-service-set-mode)
     (add-usage . harness-session-service-add-usage)
     (add-cost . harness-session-service-add-cost)
     (fork . harness-session-service-fork)
     (children . harness-session-service-children)
     (active . harness-session-service-active)
     (state-get . harness-session-service-state-get)
     (state-set . harness-session-service-state-set)
     (state-all . harness-session-service-state-all)
     (add-directory . harness-session-service-add-directory)))
  (harness-session-adopt-survivors))

(defun harness-session-adopt-survivors ()
  "Re-adopt sessions that were open before this module was reloaded."
  (dolist (id (harness-core-state-get 'harness-session 'active-ids))
    (condition-case err
        (harness-session-load id)
      (error (harness-log "could not re-adopt session %s: %S" id err))))
  (harness-core-state-clear 'harness-session 'active-ids))

(defun harness-session-teardown ()
  "Tear down the session module, flushing pending writes.
The ids of open sessions are recorded in kernel state so that a reload
can re-adopt them; the transcripts themselves were saved to disk."
  (dolist (session (harness-session-active-list))
    (condition-case err
        (harness-session-save session)
      (error (harness-log "flush failed for %s: %S" (harness-session-id session) err))))
  (harness-core-state-set 'harness-session 'active-ids
                          (mapcar #'harness-session-id (harness-session-active-list)))
  (clrhash harness-session--active)
  (clrhash harness-session--project-ids))

(harness-module-define 'harness-session
  :version harness-version
  :description "Sessions, transcripts and their storage."
  :requires '((harness-core "0.1.0")
              (harness-config "0.1.0"))
  :provides '(harness-session)
  :setup #'harness-session-setup
  :teardown #'harness-session-teardown)

(provide 'harness-session)
;;; harness-session.el ends here
