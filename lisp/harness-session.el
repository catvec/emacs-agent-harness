;;; harness-session.el --- Session lifecycle, persistence and search -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; Author: the emacs-agent-harness authors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
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

;; Sessions live in one JSONL file each: line one is a header record, later
;; lines are messages, metadata snapshots and title updates.  Appending a line
;; is the only write, so a crash loses at most the message being streamed.
;;
;; Listing sessions never reads a whole transcript: only the first few
;; kilobytes of each file are read, and only when the file's mtime changed.
;;
;; Searching does not read transcripts at all.  Every finished message is
;; recorded in a SQLite index (Emacs 29+ ships sqlite); if this Emacs lacks
;; it, search falls back to an asynchronous `grep' subprocess rather than
;; scanning in Lisp and blocking the main thread.
;;
;; See DESIGN.md section 6.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'harness-core)
(require 'harness-provider)

(declare-function projectile-project-root "projectile" (&optional dir))

(defcustom harness-session-directory
  (expand-file-name "agent-harness/sessions" user-emacs-directory)
  "Directory holding session files."
  :type 'directory
  :group 'harness-sessions)

(defcustom harness-session-index-file
  (expand-file-name "agent-harness/index.sqlite" user-emacs-directory)
  "SQLite database used to search sessions by content."
  :type 'file
  :group 'harness-sessions)

(defcustom harness-session-header-bytes 4096
  "Bytes read from the head of a session file when listing sessions.
Only the header line is needed, so this keeps listing cheap for large
transcripts."
  :type 'integer
  :group 'harness-sessions)

(defcustom harness-session-persist-tool-results t
  "Whether tool output is written to the session file.
Turning this off keeps session files small but loses tool output when a
session is resumed."
  :type 'boolean
  :group 'harness-sessions)

(defconst harness-session-record-version 1
  "Version of the on-disk session format.")

(defvar harness-session-header-cache (make-hash-table :test #'equal)
  "Cache of session file headers, keyed by file name.
Each value is (MTIME . HEADER-PLIST).")

(defvar harness--index-db nil
  "Open handle for `harness-session-index-file', or nil.")

(defvar harness-session-directory-changed-hook nil
  "Hook run after the set of session files may have changed.")


;;; Projects

(defun harness-session-project (&optional directory)
  "Return (ROOT . NAME) for DIRECTORY, or the current directory's basename.

`project.el' is asked first, because it is the built-in and every other Emacs
feature agrees with it.  Projectile is consulted only as a fallback, and only
when it is already installed -- a session should be tied to the project the
user's editor believes in, and that is usually the same answer from either."
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory default-directory))))
         (project (ignore-errors (project-current nil dir))))
    (cond
     (project
      (let ((root (file-name-as-directory (expand-file-name (project-root project)))))
        (cons root (or (ignore-errors (project-name project))
                       (file-name-nondirectory (directory-file-name root))))))
     ((and (require 'projectile nil t)
           (ignore-errors (projectile-project-root dir)))
      (let ((root (file-name-as-directory
                   (expand-file-name (projectile-project-root dir)))))
        (cons root (file-name-nondirectory (directory-file-name root)))))
     (t (cons dir (file-name-nondirectory (directory-file-name dir)))))))

(defun harness-session-project-slug (root)
  "Return a filesystem-safe directory name for project ROOT."
  (let ((base (string-remove-suffix "/" (or root default-directory))))
    (string-trim
     (replace-regexp-in-string
      "[^a-zA-Z0-9._-]+" "-"
      (truncate-string-to-width (string-remove-prefix "/" base) 80 nil nil "")
      nil t)
     "-+" "-+")))

(defun harness-session-cwd (session)
  "Return SESSION's working directory as an absolute path.

Everything that touches the filesystem for a session -- tools, `@'
attachments, git -- goes through this, so moving a session (to a git
worktree, say) moves all of it at once."
  (or (harness-session-working-directory session)
      (harness-session-project-root session)
      default-directory))

(defun harness-session-set-working-directory (session directory)
  "Point SESSION at DIRECTORY and persist the change."
  (let ((expanded (file-name-as-directory (expand-file-name directory))))
    (unless (file-directory-p expanded)
      (user-error "No such directory: %s" expanded))
    (setf (harness-session-working-directory session) expanded)
    (harness-session-save-state session)
    (harness-session-notify session 'meta)
    (message "%s now works in %s" (harness-session-name session) expanded)
    expanded))

(declare-function harness-conversation-session "harness-ui-conversation" (&optional buffer))

(defun harness-set-working-directory (directory &optional session)
  "Change the working directory of SESSION."
  (interactive
   (list (read-directory-name "Working directory: " nil nil t)
         (when (fboundp 'harness-conversation-session)
           (harness-conversation-session))))
  (let ((session (or session (harness-session--read-session "Directory for"))))
    (harness-session-set-working-directory session directory)))

(defun harness-session-in-project-p (session root)
  "Return non-nil when SESSION belongs to the project at ROOT."
  (and root (equal (harness-session-project-root session) root)))


;;; Reading and writing files

(defun harness-session--write-record (session record)
  "Append RECORD as one JSON line to SESSION's file."
  (when-let* ((file (harness-session-file session)))
    (condition-case err
        (let ((write-region-inhibit-fsync t)
              (coding-system-for-write 'utf-8-unix))
          (write-region (harness-json-write-line record) nil file t 'silent))
      (error (harness--log "could not append to %s: %s" file
                           (error-message-string err))))))

(defun harness-session--tool-call-record (tool-call)
  "Return TOOL-CALL as a JSON record."
  (list (cons 'id (harness-tool-call-id tool-call))
        (cons 'name (harness-tool-call-name tool-call))
        (cons 'args_string (harness-tool-call-args-string tool-call))
        (cons 'status (symbol-name (harness-tool-call-status tool-call)))
        (cons 'result (when harness-session-persist-tool-results
                        (harness-truncate-string
                         (harness-tool-call-result tool-call))))
        (cons 'error (harness-tool-call-error tool-call))
        (cons 'detail (harness-session--plist-record (harness-tool-call-detail tool-call)))
        (cons 'started (harness-tool-call-started tool-call))
        (cons 'finished (harness-tool-call-finished tool-call))))

(defun harness-session--key-name (key)
  "Return KEY as a plain string, without a leading colon."
  (let ((name (format "%s" key)))
    (if (string-prefix-p ":" name) (substring name 1) name)))

(defun harness-session--plist-record (plist)
  "Convert PLIST to an alist suitable for `harness-json-write'.
Returns nil for nil, and leaves already-alist values alone."
  (cond
   ((null plist) nil)
   ((and (listp plist) (keywordp (car plist)))
    (cl-loop for (key value) on plist by #'cddr
             collect (cons (intern (harness-session--key-name key)) value)))
   (t plist)))

(defun harness-session--meta-record (meta)
  "Return message META as an alist, dropping derived caches.
`:wire-json' is provider-generated and reconstructed on demand, so it is
never written to disk."
  (cl-loop for (key value) on meta by #'cddr
           unless (eq key :wire-json)
           collect (cons (intern (harness-session--key-name key)) value)))

(defun harness-session--record-plist (record)
  "Convert alist RECORD to a plist with keyword keys."
  (when (listp record)
    (cl-loop for (key . value) in record
             collect (intern (concat ":" (format "%s" key)))
             collect value)))

(defun harness-session--message-record (message)
  "Return MESSAGE as a JSON record."
  (list (cons 'type "message")
        (cons 'id (harness-message-id message))
        (cons 'role (symbol-name (harness-message-role message)))
        (cons 'content (harness-message-content message))
        (cons 'thinking (harness-message-thinking message))
        (cons 'tool_call_id (harness-message-tool-call-id message))
        (cons 'tool_name (harness-message-tool-name message))
        (cons 'tool_calls (mapcar #'harness-session--tool-call-record
                                  (harness-message-tool-calls message)))
        (cons 'status (symbol-name (harness-message-status message)))
        (cons 'error (harness-message-error message))
        (cons 'timestamp (harness-message-timestamp message))
        (cons 'duration (harness-message-duration message))
        (cons 'usage (harness-session--plist-record (harness-message-usage message)))
        ;; `:wire-json' is a derived, provider-specific cache; never persist it.
        (cons 'meta (harness-session--meta-record (harness-message-meta message)))))

(defun harness-session--header-record (session)
  "Return SESSION's header record."
  (list (cons 'type "session")
        (cons 'version harness-session-record-version)
        (cons 'id (harness-session-id session))
        (cons 'name (harness-session-name session))
        (cons 'project_root (harness-session-project-root session))
        (cons 'project_name (harness-session-project-name session))
        (cons 'working_directory (harness-session-working-directory session))
        (cons 'provider (and (harness-session-provider session)
                             (symbol-name (harness-session-provider session))))
        (cons 'model (harness-session-model session))
        (cons 'parent (harness-session-parent session))
        (cons 'created (harness-session-created session))))

(defun harness-session-save-state (session)
  "Append a metadata snapshot for SESSION to its file."
  (harness-session--write-record
   session
   (list (cons 'type "meta")
         (cons 'name (harness-session-name session))
         (cons 'working_directory (harness-session-working-directory session))
         (cons 'model (harness-session-model session))
         (cons 'provider (and (harness-session-provider session)
                              (symbol-name (harness-session-provider session))))
         (cons 'status (symbol-name (harness-session-status session)))
         (cons 'usage (harness-session--plist-record (harness-session-usage session)))
         (cons 'queue (mapcar (lambda (queued)
                                (list (cons 'id (harness-queued-message-id queued))
                                      (cons 'text (harness-queued-message-text queued))
                                      (cons 'created (harness-queued-message-created queued))))
                              (harness-session-queue session)))
         (cons 'updated (float-time)))))


;;; Creating

(defun harness-session--file-for (id project-root)
  "Return the session file name for ID inside PROJECT-ROOT's directory."
  (expand-file-name
   (format "%s_%s.jsonl" (format-time-string "%Y%m%dT%H%M%S") id)
   (expand-file-name (harness-session-project-slug project-root)
                     harness-session-directory)))

(defun harness-session-create (&optional plist)
  "Create, register and persist a new session.

PLIST may contain `:name', `:directory', `:model', `:provider' and
`:parent'.  The session is tied to the `project.el' project of `:directory'
\(default `default-directory')."
  (let* ((directory (or (plist-get plist :directory) default-directory))
         (project (harness-session-project directory))
         (id (harness-generate-id))
         (session (harness--make-session
                   :id id
                   :name (or (plist-get plist :name)
                             (format "%s session" (cdr project)))
                   :project-root (car project)
                   :project-name (cdr project)
                   :working-directory (file-name-as-directory
                                       (expand-file-name
                                        (or (plist-get plist :working-directory)
                                            (car project))))
                   :file (harness-session--file-for id (car project))
                   :provider (or (plist-get plist :provider)
                                 harness-default-provider)
                   :model (or (plist-get plist :model) harness-default-model)
                   :parent (plist-get plist :parent)
                   :created (float-time)
                   :updated (float-time))))
    (make-directory (file-name-directory (harness-session-file session)) t)
    (harness-session-put session)
    (harness-session--write-record session (harness-session--header-record session))
    (if-let* ((parent-id (harness-session-parent session)))
        (when-let* ((parent (harness-session-get parent-id)))
          (setf (harness-session-children parent)
                (cons id (harness-session-children parent)))))
    (harness--log "created session %s (%s)" id (harness-session-file session))
    session))

(defun harness-session-add-message (session message)
  "Append MESSAGE to SESSION, persist it, index it and notify listeners.
This is the single write path for transcripts."
  (harness-session-append-message session message)
  (harness-session--write-record session (harness-session--message-record message))
  (harness-index-add-message session message)
  (run-hook-with-args 'harness-message-added-hook session message)
  (harness-session-notify session 'messages)
  message)

(defun harness-session-persist-message (session message)
  "Write MESSAGE to SESSION's file, index it and announce it.

Use this for a message that was already appended to the transcript before it
was complete -- the assistant message being streamed -- so that finishing a
message does not append it twice."
  (harness-session--write-record session (harness-session--message-record message))
  (harness-index-add-message session message)
  (run-hook-with-args 'harness-message-added-hook session message)
  message)

(defun harness-session-rename (session name)
  "Give SESSION a new NAME and persist the change."
  (interactive
   (list (harness-session--read-session "Rename session")
         (read-string "New name: ")))
  (setf (harness-session-name session) name)
  (harness-session-save-state session)
  (harness-session-notify session 'meta)
  name)

(defun harness-session-set-model (session model)
  "Set SESSION's model to MODEL and persist the change."
  (setf (harness-session-model session) model)
  (harness-session-save-state session)
  (harness-session-notify session 'meta)
  model)

(defun harness-session-set-provider (session provider)
  "Set SESSION's provider to PROVIDER (a symbol) and persist the change."
  (setf (harness-session-provider session) provider)
  (harness-session-save-state session)
  (harness-session-notify session 'meta)
  provider)

(defun harness-session--read-session (prompt)
  "Read a session from the minibuffer, prompting with PROMPT."
  (let* ((sessions (harness-session-list))
         (choices (mapcar (lambda (session)
                            (cons (format "%s  [%s]"
                                          (harness-session-name session)
                                          (harness-session-status-string session))
                                  session))
                          sessions)))
    (unless choices (user-error "No live sessions"))
    (cdr (assoc (completing-read (concat prompt ": ") choices nil t) choices))))


;;; Listing without loading

(defun harness-session-files ()
  "Return every session file on disk, newest first."
  (let ((files nil))
    (when (file-directory-p harness-session-directory)
      (dolist (directory (directory-files harness-session-directory t "\\`[^.]"))
        (when (file-directory-p directory)
          (dolist (file (directory-files directory t "\\`[^.]"))
            (when (string-suffix-p ".jsonl" file)
              (push file files))))))
    (sort files (lambda (a b) (string-lessp b a)))))

(defun harness-session--read-header-line (file)
  "Return FILE's first line, reading as few bytes as possible.
Retries with a larger window when the header line does not fit, so a very
long session name cannot make a session invisible."
  (let ((window harness-session-header-bytes)
        (size (or (file-attribute-size (file-attributes file)) 0))
        (line nil)
        (attempt 0))
    (while (and (null line) (< attempt 4))
      (setq attempt (1+ attempt))
      (with-temp-buffer
        (insert-file-contents file nil 0 (min window size))
        (goto-char (point-min))
        (if (search-forward "\n" nil t)
            (setq line (buffer-substring-no-properties (point-min) (1- (point))))
          (when (>= window size)
            (setq line (buffer-substring-no-properties (point-min) (point-max))))))
      (setq window (* window 4)))
    line))

(defun harness-session--read-header (file)
  "Return FILE's header record, reading only its first few kilobytes."
  (let* ((attributes (file-attributes file))
         (mtime (and attributes (float-time (file-attribute-modification-time attributes))))
         (cached (gethash file harness-session-header-cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let ((header
             (condition-case err
                 (let ((line (harness-session--read-header-line file)))
                   (when (and line (not (string-empty-p line))
                              (string-prefix-p "{" line))
                     (harness-json-read line)))
               (error
                (harness--log "unreadable session file %s: %s" file
                              (error-message-string err))
                nil))))
        (puthash file (cons mtime header) harness-session-header-cache)
        header))))

(defun harness-session-record (file)
  "Return a plist describing the session in FILE, without loading messages.
Keys: `:file', `:id', `:name', `:project-root', `:project-name', `:model',
`:provider', `:created', `:updated', `:mtime'."
  (let* ((header (harness-session--read-header file))
         (attributes (file-attributes file))
         (mtime (and attributes
                     (float-time (file-attribute-modification-time attributes)))))
    (when header
      (list :file file
            :id (harness-alist-get :id header)
            :name (harness-alist-get :name header)
            :project-root (harness-alist-get :project_root header)
            :project-name (harness-alist-get :project_name header)
            :working-directory (harness-alist-get :working_directory header)
            :model (harness-alist-get :model header)
            :provider (harness-alist-get :provider header)
            :created (harness-alist-get :created header)
            :mtime mtime
            :updated mtime))))

(defun harness-session-records (&optional directory)
  "Return a session record for every session file.
When DIRECTORY is non-nil, only sessions whose project root is DIRECTORY."
  (let ((records nil))
    (dolist (file (harness-session-files))
      (let ((record (harness-session-record file)))
        (when (and record
                   (or (null directory)
                       (equal (file-name-as-directory
                               (expand-file-name
                                (or (harness-plist-or-alist-get :project-root record) "")))
                              (file-name-as-directory (expand-file-name directory)))))
          (push record records))))
    (sort records (lambda (a b)
                    (> (or (harness-plist-or-alist-get :mtime a) 0)
                       (or (harness-plist-or-alist-get :mtime b) 0))))))

(defun harness-session-record-status (record)
  "Return the live status of the session RECORD describes.
Sessions that are not loaded are `idle' unless another Emacs has them open,
which we cannot know; the on-disk meta line is the best available answer."
  (let ((session (harness-session-get (harness-plist-or-alist-get :id record))))
    (if session
        (harness-session-status session)
      'idle)))

(defun harness-session-record-usage (record)
  "Return the usage plist recorded for RECORD's last meta line.
Only the header is read, so this is nil unless the session is live."
  (let ((session (harness-session-get (harness-plist-or-alist-get :id record))))
    (when session (harness-session-usage session))))


;;; Loading and resuming

(defun harness-session--apply-record (session record)
  "Apply one JSON RECORD to SESSION."
  (pcase (harness-alist-get :type record)
    ("message"
     (let* ((id (harness-alist-get :id record))
            (message (harness--make-message
                      :id id
                      :role (intern (or (harness-alist-get :role record) "user"))
                      :content (or (harness-alist-get :content record) "")
                      :thinking (harness-alist-get :thinking record)
                      :tool-call-id (harness-alist-get :tool_call_id record)
                      :tool-name (harness-alist-get :tool_name record)
                      :status (intern (or (harness-alist-get :status record) "complete"))
                      :error (harness-alist-get :error record)
                      :timestamp (harness-alist-get :timestamp record)
                      :duration (harness-alist-get :duration record)
                      :usage (harness-session--record-plist (harness-alist-get :usage record))
                      :meta (harness-session--record-plist (harness-alist-get :meta record))
                      :tool-calls (mapcar #'harness-session--load-tool-call
                                          (harness-alist-get :tool_calls record)))))
       (harness-session-append-message session message)))
    ("meta"
     (when-let* ((name (harness-alist-get :name record)))
       (setf (harness-session-name session) name))
     (when-let* ((directory (harness-alist-get :working_directory record)))
       (setf (harness-session-working-directory session) directory))
     (when-let* ((model (harness-alist-get :model record)))
       (setf (harness-session-model session) model))
     (when-let* ((provider (harness-alist-get :provider record)))
       (setf (harness-session-provider session) (intern provider)))
     (when-let* ((usage (harness-alist-get :usage record)))
       (setf (harness-session-usage session) (harness-session--record-plist usage)))
     (setf (harness-session-queue session)
           (mapcar (lambda (queued)
                     (harness--make-queued-message
                      :id (harness-alist-get :id queued)
                      :text (or (harness-alist-get :text queued) "")
                      :created (harness-alist-get :created queued)))
                   (harness-alist-get :queue record))))
    (_ nil)))

(defun harness-session--load-tool-call (record)
  "Rebuild a `harness-tool-call' from JSON RECORD."
  (let ((call (harness-tool-call-create
               :id (harness-alist-get :id record)
               :name (harness-alist-get :name record)
               :args-string (or (harness-alist-get :args_string record) "")
               :status (intern (or (harness-alist-get :status record) "pending"))
               :result (harness-alist-get :result record)
               :error (harness-alist-get :error record)
               :detail (harness-session--record-plist (harness-alist-get :detail record))
               :started (harness-alist-get :started record)
               :finished (harness-alist-get :finished record))))
    (harness-tool-call-parse-args call)
    call))

(defun harness-session-load (file)
  "Read FILE into a session struct, without registering it."
  (let* ((header (harness-session--read-header file))
         (session (harness--make-session
                   :id (or (harness-alist-get :id header) (harness-generate-id))
                   :name (or (harness-alist-get :name header) "session")
                   :project-root (harness-alist-get :project_root header)
                   :project-name (harness-alist-get :project_name header)
                   :working-directory (harness-alist-get :working_directory header)
                   :file file
                   :provider (let ((provider (harness-alist-get :provider header)))
                               (and provider (intern provider)))
                   :model (harness-alist-get :model header)
                   :parent (harness-alist-get :parent header)
                   :created (or (harness-alist-get :created header) (float-time))
                   :updated (float-time))))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (goto-char (point-min))
      (let ((first t))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (forward-line 1)
            (cond
             (first (setq first nil))   ; the header record
             ((string-empty-p (string-trim line)) nil)
             (t (condition-case err
                    (harness-session--apply-record session (harness-json-read line))
                  (error (harness--log "skipping bad session line in %s: %s"
                                       file (error-message-string err))))))))))
    session))

(defun harness-session-resume (id-or-file)
  "Load the session named ID-OR-FILE, register it and return it.
A live session with the same id is returned as-is."
  (interactive (list (harness-session--read-file "Resume session")))
  (let* ((file (if (file-exists-p id-or-file)
                   id-or-file
                 (or (harness-session-file-for-id id-or-file)
                     (user-error "No such session: %s" id-or-file))))
         (loaded (harness-session-load file))
         (existing (harness-session-get (harness-session-id loaded))))
    (if existing
        existing
      (harness-session-put loaded)
      (harness-index-sync-session loaded)
      (harness--log "resumed session %s" (harness-session-id loaded))
      loaded)))

(defun harness-session-file-for-id (id)
  "Return the session file whose header id is ID, or nil."
  (cl-find-if (lambda (file)
                (equal id (harness-alist-get :id (harness-session--read-header file))))
              (harness-session-files)))

(defun harness-session--read-file (prompt)
  "Read a session file from the minibuffer, prompting with PROMPT."
  (let* ((records (harness-session-records))
         (choices (mapcar (lambda (record)
                            (cons (format "%s  %s"
                                          (or (harness-plist-or-alist-get :name record) "?")
                                          (harness-format-time
                                           (harness-plist-or-alist-get :mtime record)))
                                  record))
                          records)))
    (unless choices (user-error "No saved sessions"))
    (harness-plist-or-alist-get
     :file
     (cdr (assoc (completing-read (concat prompt ": ") choices nil t) choices)))))

(defun harness-session-delete (session)
  "Delete SESSION's file, index rows and registry entry."
  (interactive (list (harness-session--read-session "Delete session")))
  (when (and session (harness-session-file session)
             (file-exists-p (harness-session-file session))
             (yes-or-no-p (format "Delete session %s? "
                                  (harness-session-name session))))
    (delete-file (harness-session-file session))
    (remhash (harness-session-file session) harness-session-header-cache)
    (harness-index-delete-session session)
    (harness-session-remove session)
    (run-hooks 'harness-session-directory-changed-hook)
    t))

(defun harness-session-kill (session)
  "Remove SESSION from the live registry, keeping its file."
  (interactive (list (harness-session--read-session "Close session")))
  (when session
    (harness-session-remove session)
    session))


;;; SQLite content index

(defun harness-index-available-p ()
  "Return non-nil when the SQLite index can be used."
  (and (fboundp 'sqlite-open) (fboundp 'sqlite-execute)))

(defun harness--index ()
  "Return an open index handle, creating the schema if needed."
  (when (harness-index-available-p)
    (condition-case err
        (progn
          (unless harness--index-db
            (make-directory (file-name-directory harness-session-index-file) t)
            (setq harness--index-db (sqlite-open harness-session-index-file))
            (sqlite-execute harness--index-db
                            "CREATE TABLE IF NOT EXISTS sessions (
                               id TEXT PRIMARY KEY, name TEXT, project_root TEXT,
                               project_name TEXT, file TEXT, model TEXT,
                               provider TEXT, created REAL, updated REAL, usage TEXT)")
            (sqlite-execute harness--index-db
                            "CREATE TABLE IF NOT EXISTS messages (
                               session_id TEXT, message_id TEXT, role TEXT,
                               content TEXT, ts REAL)")
            (sqlite-execute harness--index-db
                            "CREATE INDEX IF NOT EXISTS messages_session
                               ON messages (session_id)")
            ;; Unique so that REPLACE really replaces a message rather than
            ;; inserting a duplicate when a session is re-indexed.
            (sqlite-execute harness--index-db
                            "CREATE UNIQUE INDEX IF NOT EXISTS messages_unique
                               ON messages (session_id, message_id)")
            (sqlite-execute harness--index-db
                            "CREATE INDEX IF NOT EXISTS messages_content
                               ON messages (content)"))
          harness--index-db)
      (error
       (harness--log "session index unavailable: %s" (error-message-string err))
       (setq harness--index-db nil)
       nil))))

(defun harness-index-add-message (session message)
  "Record MESSAGE in the search index for SESSION."
  (when-let* ((db (harness--index)))
    (condition-case err
        (sqlite-execute db
                        "REPLACE INTO messages (session_id, message_id, role, content, ts)
                         VALUES (?, ?, ?, ?, ?)"
                        (list (harness-session-id session)
                              (harness-message-id message)
                              (symbol-name (harness-message-role message))
                              (concat (harness-message-content message)
                                      (when-let* ((result (harness-session--message-result-text message)))
                                        (concat "\n" result)))
                              (or (harness-message-timestamp message) (float-time))))
      (error (harness--log "index insert failed: %s" (error-message-string err))))))

(defun harness-session--message-result-text (message)
  "Return the tool output attached to MESSAGE, if any."
  (mapconcat (lambda (call) (or (harness-tool-call-result call) ""))
             (harness-message-tool-calls message) "\n"))

(defun harness-index-sync-session (session)
  "Insert every message of SESSION into the index, and its metadata."
  (when-let* ((db (harness--index)))
    (harness-index-delete-session session)
    (dolist (message (harness-session-messages session))
      (harness-index-add-message session message))
    (condition-case err
        (sqlite-execute db
                        "REPLACE INTO sessions
                           (id, name, project_root, project_name, file, model,
                            provider, created, updated, usage)
                         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                        (list (harness-session-id session)
                              (or (harness-session-name session) "")
                              (or (harness-session-project-root session) "")
                              (or (harness-session-project-name session) "")
                              (or (harness-session-file session) "")
                              (or (harness-session-model session) "")
                              (or (and (harness-session-provider session)
                                       (symbol-name (harness-session-provider session)))
                                  "")
                              (or (harness-session-created session) 0)
                              (or (harness-session-updated session) 0)
                              (harness-json-write (harness-session--plist-record
                                                   (harness-session-usage session)))))
      (error (harness--log "index metadata failed: %s" (error-message-string err))))))

(defun harness-index-delete-session (session)
  "Remove SESSION's rows from the index."
  (when-let* ((db (harness--index)))
    (let ((id (harness-session-id session)))
      (condition-case err
          (progn
            (sqlite-execute db "DELETE FROM messages WHERE session_id = ?" (list id))
            (sqlite-execute db "DELETE FROM sessions WHERE id = ?" (list id)))
        (error (harness--log "index delete failed: %s" (error-message-string err)))))))

(defun harness-index-search (query &optional limit)
  "Search indexed messages for QUERY.
Returns a list of plists: `:session-id', `:file', `:name', `:role',
`:snippet', `:ts'.  Honours LIMIT (default 50).  Falls back to an
asynchronous `grep' when SQLite is unavailable or the index cannot be
opened."
  (let ((db (and (harness-index-available-p) (harness--index))))
    (if (null db)
        (harness--search-fallback query limit)
      (let ((rows (condition-case err
                      (sqlite-select
                       db
                       "SELECT m.session_id, m.role, m.content, m.ts, s.file, s.name
                          FROM messages m LEFT JOIN sessions s ON s.id = m.session_id
                         WHERE m.content LIKE ?
                         ORDER BY m.ts DESC LIMIT ?"
                       (list (concat "%" query "%") (or limit 50)))
                    (error
                     (harness--log "index search failed: %s" (error-message-string err))
                     nil))))
        (if (null rows)
            (harness--search-fallback query limit)
          (mapcar (lambda (row)
                    (let ((content (nth 2 row)))
                      (list :session-id (nth 0 row)
                            :role (nth 1 row)
                            :snippet (harness--search-snippet content query)
                            :ts (nth 3 row)
                            :file (nth 4 row)
                            :name (nth 5 row)
                            :line (harness--search-line content query))))
                  rows))))))

(defun harness--search-snippet (content query)
  "Return a snippet of CONTENT around QUERY."
  (let ((index (string-match (regexp-quote query) content)))
    (if (not index)
        (truncate-string-to-width (replace-regexp-in-string "\n" " " content) 120 nil nil "…")
      (let ((start (max 0 (- index 40)))
            (end (min (length content) (+ index (length query) 60))))
        (concat (when (> start 0) "…")
                (replace-regexp-in-string
                 "\n" " " (substring content start end))
                (when (< end (length content)) "…"))))))

(defun harness--search-line (content query)
  "Return the number of the line in CONTENT containing QUERY."
  (let ((index (string-match (regexp-quote query) content)))
    (when index
      (1+ (cl-count ?\n content :start 0 :end index)))))

(defvar harness--search-async-results nil
  "Last result of the `grep' fallback search.")

(defvar harness-search-finished-hook nil
  "Hook run when an asynchronous search finishes.")

(defun harness--search-fallback (query limit)
  "Search session files for QUERY using an asynchronous `grep' subprocess.
This is the path taken when Emacs has no SQLite.  It returns nil and fills
`harness--search-async-results' instead, notifying
`harness-search-finished-hook' when the subprocess finishes."
  (let* ((buffer (get-buffer-create " *harness-search*"))
         (limit (or limit 50)))
    (with-current-buffer buffer (erase-buffer))
    (let ((process (make-process
                    :name "harness-search"
                    :buffer buffer
                    :command (list "grep" "-r" "-l" "-F" "--include=*.jsonl"
                                   query harness-session-directory)
                    :connection-type 'pipe
                    :noquery t
                    :coding 'utf-8-unix
                    :sentinel (lambda (process _event)
                                (when (memq (process-status process) '(exit signal))
                                  (setq harness--search-async-results
                                        (harness--search-fallback-collect buffer query limit))
                                  (kill-buffer buffer)
                                  (run-hooks 'harness-search-finished-hook))))))
      (ignore process)
      nil)))

(defun harness--search-fallback-collect (buffer _query limit)
  "Turn the `grep -l' output in BUFFER into search results."
  (let ((files (with-current-buffer buffer
                 (split-string (buffer-string) "\n" t)))
        (results nil))
    (while (and files (< (length results) limit))
      (let* ((file (car files))
             (record (harness-session-record file)))
        (when record
          (push (list :session-id (harness-plist-or-alist-get :id record)
                      :file file
                      :name (harness-plist-or-alist-get :name record)
                      :role "unknown"
                      :snippet ""
                      :ts (harness-plist-or-alist-get :mtime record))
                results)))
      (setq files (cdr files)))
    (nreverse results)))

(defun harness-index-rebuild ()
  "Rebuild the content index from every session file.
This is an explicit maintenance command; it reads every transcript, so it
can take a while on a large history."
  (interactive)
  (unless (harness-index-available-p)
    (user-error "This Emacs has no SQLite support"))
  (when-let* ((db (harness--index)))
    (sqlite-execute db "DELETE FROM messages")
    (sqlite-execute db "DELETE FROM sessions")
    (let ((count 0))
      (dolist (file (harness-session-files))
        (let ((session (harness-session-load file)))
          (harness-index-sync-session session)
          (setq count (1+ count))
          (when (zerop (% count 25)) (message "Indexed %d sessions…" count))))
      (message "Indexed %d sessions" count))))

(defun harness-search-sessions (query)
  "Search all sessions for QUERY.
Returns results synchronously when SQLite is available; otherwise starts an
asynchronous search and returns nil, running `harness-search-finished-hook'
with the results in `harness--search-async-results'."
  (interactive "sSearch sessions: ")
  (harness-index-search query))

(provide 'harness-session)
;;; harness-session.el ends here
