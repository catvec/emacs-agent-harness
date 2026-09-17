;;; harness-tools.el --- Tool registry and built-in tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
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

;; A tool is a name, a JSON schema and a function.  `harness-define-tool'
;; registers one; everything else (the model's tool list, the permission
;; system, the UI renderers) reads the same registry, so a plugin adds a tool
;; by registering it and nothing else changes.
;;
;; Parameter schemas are written as plists, which `json-encode' renders as JSON
;; objects and which are far easier to read and balance than alists:
;;
;;   (:type "object" :properties (:path (:type "string")) :required ("path"))
;;
;; Tools are plain functions.  Anything that needs the user -- approval,
;; asking a question, waiting for a subagent -- uses the asynchronous form, so
;; the agent loop never blocks and other sessions stay responsive.
;;
;; Long output is truncated before it becomes a message; the untruncated result
;; stays on the tool call so the UI can expand it.
;;
;; See DESIGN.md section 7.1.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-session)

(defcustom harness-bash-timeout 300
  "Seconds after which the `bash' tool kills its command."
  :type 'integer
  :group 'harness-tools)

(defcustom harness-tool-max-output 65536
  "Maximum characters of a tool result kept in a message."
  :type 'integer
  :group 'harness-tools)

(defcustom harness-shell-program shell-file-name
  "Shell used to run the `bash' tool."
  :type 'string
  :group 'harness-tools)

(defcustom harness-tool-search-limit 500
  "Maximum number of files `glob' returns."
  :type 'integer
  :group 'harness-tools)

(defvar harness-tool-enabled-functions nil
  "Abnormal hook deciding which tools a session may use.
Each function is called with (TOOL SESSION) and returns non-nil when the tool
should be offered.  Subagent personalities use this to restrict tools.")


;;; Data structures

(cl-defstruct (harness-tool (:constructor harness-tool--make) (:copier nil))
  "One registered tool.

CATEGORY groups tools for permission policies (`read', `edit', `execute',
`meta').  READ-ONLY is a hint for auto mode and parallel execution.  APPROVAL
is the per-tool default permission: `ask', `allow' or `never'."
  (name nil)
  (label nil)
  (description "")
  (parameters nil)
  (category 'meta)
  (read-only nil)
  (approval 'ask)
  (function nil)
  (async nil)
  (render nil)
  (group nil)
  (enabled t))

(cl-defstruct (harness-tool-context (:constructor harness-tool-context-create)
                                    (:copier nil))
  "Everything a tool needs to know about the call it is serving."
  (session nil)
  (tool-call nil)
  (directory nil)
  (meta nil))

(cl-defstruct (harness-tool-result (:constructor harness-tool-result-create)
                                   (:copier nil))
  "What a tool produced.

CONTENT is what the model sees.  DETAIL is structured data for renderers
(a diff, a todo list, a file path).  ERROR, when non-nil, marks the call
failed; the content is still shown to the model."
  (content "")
  (error nil)
  (detail nil)
  (meta nil))

(defvar harness--tools (make-hash-table :test #'equal)
  "Tool registry, keyed by tool name.")

(defvar harness-tool-registered-hook nil
  "Hook run with the tool after it is registered.")

(defun harness-register-tool (tool)
  "Add TOOL to the registry, replacing any tool with the same name."
  (puthash (harness-tool-name tool) tool harness--tools)
  (run-hook-with-args 'harness-tool-registered-hook tool)
  tool)

(defun harness-tool-get (name)
  "Return the tool named NAME, or nil."
  (and name (gethash name harness--tools)))

(defun harness-tool-all ()
  "Return every registered tool, sorted by name."
  (let (tools)
    (maphash (lambda (_name tool) (push tool tools)) harness--tools)
    (sort tools (lambda (a b) (string-lessp (harness-tool-name a)
                                            (harness-tool-name b))))))

(defun harness-tool-enabled-p (tool session)
  "Return non-nil when TOOL is enabled and allowed for SESSION."
  (and (harness-tool-enabled tool)
       (cl-every (lambda (function) (funcall function tool session))
                 harness-tool-enabled-functions)))

(defmacro harness-define-tool (name &rest args)
  "Define and register a tool called NAME.

ARGS is a keyword list: `:description', `:parameters' (a plist), `:category',
`:read-only', `:approval' (one of `ask', `allow', `never'), `:function'
\(called with the parsed arguments and a `harness-tool-context'), `:async'
\(called with the arguments, the context and a DONE callback), `:render' and
`:group'.  Exactly one of `:function' and `:async' is required."
  (declare (indent 1) (doc-string 2))
  ;; `quote-symbol' runs at macroexpansion time: it quotes bare symbols so
  ;; both `:category read' and `:category \='read' work.
  (cl-labels ((quote-symbol (value)
                (if (or (null value) (and (consp value) (eq (car value) 'quote)))
                    value
                  (list 'quote value))))
    (let ((category (quote-symbol (or (plist-get args :category) 'meta)))
          (approval (quote-symbol (or (plist-get args :approval) 'ask)))
          (group (quote-symbol (plist-get args :group))))
    `(harness-register-tool
      (harness-tool--make
       :name ,name
       :label ,(or (plist-get args :label)
                   (capitalize (replace-regexp-in-string "[-_]" " " name)))
       :description ,(plist-get args :description)
       :parameters ,(plist-get args :parameters)
       :category ,category
       :read-only ,(plist-get args :read-only)
       :approval ,approval
       :function ,(plist-get args :function)
       :async ,(plist-get args :async)
       :render ,(plist-get args :render)
       :group ,group)))))

(defun harness-tools-specs (&optional session)
  "Return the model-facing tool list for SESSION in OpenAI format."
  (harness-json-array
   (delq nil
         (mapcar
          (lambda (tool)
            (when (harness-tool-enabled-p tool session)
              (list (cons 'type "function")
                    (cons 'function
                          (list (cons 'name (harness-tool-name tool))
                                (cons 'description (harness-tool-description tool))
                                (cons 'parameters
                                      (or (harness-tool-parameters tool)
                                          '(:type "object"))))))))
          (harness-tool-all)))))

(defun harness-tools-describe (&optional session)
  "Return a plain text description of the tools available to SESSION.
Used to build the system prompt for providers without native tool support."
  (string-join
   (delq nil
         (mapcar (lambda (tool)
                   (when (harness-tool-enabled-p tool session)
                     (format "- %s: %s" (harness-tool-name tool)
                             (harness-tool-description tool))))
                 (harness-tool-all)))
   "\n"))

(defun harness-tool-args (tool-call)
  "Return TOOL-CALL's parsed arguments, parsing them if needed."
  (or (harness-tool-call-args tool-call)
      (harness-tool-call-parse-args tool-call)))

(defun harness-tools-arg (args key &optional default)
  "Return argument KEY of the parsed tool ARGS, or DEFAULT.
Accepts plists and alists, with symbol, keyword or string keys."
  (let ((value (harness-plist-or-alist-get key args)))
    (if (null value) default value)))

(defun harness-tool-session-directory (session)
  "Return the working directory for SESSION's tools."
  (or (and session (harness-session-project-root session))
      default-directory))

(defun harness-tools-resolve (path context)
  "Resolve PATH against CONTEXT's directory."
  (expand-file-name (or path "") (harness-tool-context-directory context)))


;;; Running tools

(defun harness-tools-finish (tool-call result &optional context)
  "Apply RESULT to TOOL-CALL, run the update hook and return TOOL-CALL."
  (let* ((content (harness-tool-result-content result))
         (truncated (harness-truncate-string content harness-tool-max-output
                                             harness-truncate-lines)))
    (setf (harness-tool-call-result tool-call) content)
    (setf (harness-tool-call-error tool-call) (harness-tool-result-error result))
    (setf (harness-tool-call-detail tool-call) (harness-tool-result-detail result))
    (setf (harness-tool-call-finished tool-call) (float-time))
    (setf (harness-tool-call-status tool-call)
          (if (harness-tool-result-error result) 'error 'ok))
    (setf (harness-tool-call-meta tool-call)
          (plist-put (plist-put (harness-tool-call-meta tool-call)
                                :result-meta (harness-tool-result-meta result))
                     :truncated-content truncated))
    (when-let* ((session (and context (harness-tool-context-session context))))
      (run-hook-with-args 'harness-tool-call-updated-hook session tool-call)
      (harness-session-notify session 'messages))
    tool-call))

(defun harness-tool-call-output (tool-call)
  "Return the (possibly truncated) output of TOOL-CALL for the model."
  (or (plist-get (harness-tool-call-meta tool-call) :truncated-content)
      (harness-truncate-string (harness-tool-call-result tool-call)
                               harness-tool-max-output harness-truncate-lines)))

(defun harness-tool-run (tool-call session done)
  "Run TOOL-CALL for SESSION, calling DONE with the finished tool call.

DONE is always called exactly once, on the main thread.  Synchronous tools
complete immediately; asynchronous ones call back later, which is what keeps
the run loop free while a command or a question is outstanding."
  (let* ((tool (harness-tool-get (harness-tool-call-name tool-call)))
         (context (harness-tool-context-create
                   :session session
                   :tool-call tool-call
                   :directory (harness-tool-session-directory session)))
         (finished nil)
         (finish (lambda (result)
                   (unless finished
                     (setq finished t)
                     (harness-tools-finish tool-call result context)
                     (funcall done tool-call)))))
    (setf (harness-tool-call-started tool-call) (float-time))
    (setf (harness-tool-call-status tool-call) 'running)
    (when session
      (run-hook-with-args 'harness-tool-call-updated-hook session tool-call)
      (harness-session-notify session 'messages))
    (cond
     ((null tool)
      (funcall finish (harness-tool-result-create
                       :content (format "Unknown tool %S"
                                        (harness-tool-call-name tool-call))
                       :error (format "unknown tool %s"
                                      (harness-tool-call-name tool-call)))))
     (t
      (let ((args (harness-tool-args tool-call)))
        (condition-case err
            (cond
             ((harness-tool-async tool)
              (funcall (harness-tool-async tool) args context finish))
             ((harness-tool-function tool)
              (let ((result (funcall (harness-tool-function tool) args context)))
                (funcall finish (if (harness-tool-result-p result)
                                    result
                                  (harness-tool-result-create
                                   :content (format "%s" result))))))
             (t
              (funcall finish (harness-tool-result-create
                               :content (format "Tool %s has no implementation"
                                                (harness-tool-name tool))
                               :error "tool has no implementation"))))
          (error
           (funcall finish (harness-tool-result-create
                            :content (format "Tool %s failed: %s"
                                             (harness-tool-call-name tool-call)
                                             (error-message-string err))
                            :error (error-message-string err)))))))))
  tool-call)

(defun harness-tool-call-cancel (tool-call &optional reason)
  "Mark TOOL-CALL aborted with REASON, if it has not finished."
  (when (memq (harness-tool-call-status tool-call)
              '(pending running awaiting-approval))
    (setf (harness-tool-call-status tool-call) 'aborted)
    (setf (harness-tool-call-error tool-call) (or reason "aborted"))
    (setf (harness-tool-call-finished tool-call) (float-time)))
  tool-call)


;;; Process helper

(defun harness-tools-run-process (command directory on-done &optional timeout max-output)
  "Run shell COMMAND in DIRECTORY, calling ON-DONE when it exits.

ON-DONE receives a plist with `:output' (stdout and stderr interleaved),
`:exit' (the exit code, or nil when killed) and `:timed-out'.  Output is
capped at MAX-OUTPUT characters (default `harness-tool-max-output'), keeping
the tail, so a runaway command cannot freeze redisplay or grow without bound."
  (let* ((output "")
         (max-output (or max-output harness-tool-max-output))
         (dropped nil)
         (timer nil)
         (done nil)
         (timed-out nil)
         (process nil)
         (finish
          (lambda (exit _killed)
            (unless done
              (setq done t)
              (when (timerp timer) (cancel-timer timer))
              (funcall on-done
                       (list :output (if dropped
                                         (concat "[earlier output dropped]\n" output)
                                       output)
                             :exit (unless timed-out exit)
                             :timed-out timed-out))))))
    (condition-case err
        ;; The command must run in DIRECTORY, so bind `default-directory'
        ;; around process creation; `make-process' inherits it.
        (let ((default-directory (file-name-as-directory
                                  (or directory default-directory))))
          (setq process
                (make-process
                 :name "harness-tool"
                 :buffer nil
                 :command (list harness-shell-program shell-command-switch command)
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :filter (lambda (_process chunk)
                           (setq output (concat output chunk))
                           (when (> (length output) max-output)
                             (setq output (substring output (- (length output) max-output)))
                             (setq dropped t)))
                 :sentinel (lambda (process _event)
                             (when (memq (process-status process) '(exit signal))
                               (funcall finish (process-exit-status process) nil))))))
      (error
       (harness--log "could not start %s: %s" command (error-message-string err))
       (funcall finish nil nil)))
    (when (and timeout (> timeout 0))
      (setq timer
            (run-at-time timeout nil
                         (lambda ()
                           ;; Flag the timeout before killing the process:
                           ;; `delete-process' runs the sentinel, which would
                           ;; otherwise report the kill signal as the exit code.
                           (setq timed-out t)
                           (when (process-live-p process)
                             (delete-process process))
                           (funcall finish nil t)))))
    process))


;;; Built-in tools

(harness-define-tool "read"
  :description "Read a file. Returns the contents with line numbers; use offset and limit for large files."
  :parameters '(:type "object"
                :properties (:file_path (:type "string"
                                         :description "Absolute or project-relative path")
                             :offset (:type "integer"
                                      :description "First line to read, 1-based")
                             :limit (:type "integer"
                                     :description "Maximum number of lines"))
                :required ("file_path"))
  :category 'read
  :read-only t
  :approval 'allow
  :function
  (lambda (args context)
    (let* ((path (harness-tools-resolve (harness-tools-arg args :file_path) context))
           (offset (or (harness-tools-arg args :offset) 1))
           (limit (harness-tools-arg args :limit))
           (label (harness-relative-path path (harness-tool-context-directory context))))
      (cond
       ((not (file-exists-p path))
        (harness-tool-result-create :content (format "No such file: %s" label)
                                    :error "file not found"))
       ((file-directory-p path)
        (harness-tool-result-create :content (format "%s is a directory" label)
                                    :error "is a directory"))
       (t
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents path))
          (let* ((total (line-number-at-pos (point-max)))
                 (end (if limit (min total (+ (1- offset) limit)) total))
                 (body (save-restriction
                         (widen)
                         (goto-char (point-min))
                         (forward-line (1- offset))
                         (let ((start (point)))
                           (forward-line (- end (1- offset)))
                           (buffer-substring-no-properties start (point))))))
            (harness-tool-result-create
             :content (if (string-empty-p body)
                          (format "%s: no lines in that range (file has %d lines)"
                                  label total)
                        (with-temp-buffer
                          (insert body)
                          (goto-char (point-min))
                          (let ((number offset))
                            (while (not (eobp))
                              (insert (format "%6d\t" number))
                              (setq number (1+ number))
                              (forward-line 1)))
                          (buffer-string)))
             :detail (list :path path :lines (cons offset end)
                           :truncated (< end total))))))))))

(harness-define-tool "write"
  :description "Write a file, creating parent directories. Overwrites the file if it exists."
  :parameters '(:type "object"
                :properties (:file_path (:type "string")
                             :content (:type "string"))
                :required ("file_path" "content"))
  :category 'edit
  :approval 'ask
  :function
  (lambda (args context)
    (let* ((path (harness-tools-resolve (harness-tools-arg args :file_path) context))
           (content (or (harness-tools-arg args :content) ""))
           (existed (and (file-exists-p path) (not (file-directory-p path))))
           (old (when existed
                  (with-temp-buffer
                    (let ((coding-system-for-read 'utf-8-unix))
                      (insert-file-contents path))
                    (harness-truncate-string (buffer-string) 4000 nil nil)))))
      (make-directory (file-name-directory path) t)
      (let ((coding-system-for-write 'utf-8-unix)
            (write-region-inhibit-fsync t))
        (write-region content nil path nil 'silent))
      (harness-tool-result-create
       :content (format "%s %s (%d bytes)"
                        (if existed "Wrote" "Created")
                        (harness-relative-path path (harness-tool-context-directory context))
                        (string-bytes content))
       :detail (list :kind 'edit :path path
                     :action (if existed 'write 'create)
                     :old old
                     :new (harness-truncate-string content 4000 nil nil))))))

(harness-define-tool "edit"
  :description "Replace an exact string in a file. old_string must match exactly, and must be unique unless replace_all is set."
  :parameters '(:type "object"
                :properties (:file_path (:type "string")
                             :old_string (:type "string")
                             :new_string (:type "string")
                             :replace_all (:type "boolean"))
                :required ("file_path" "old_string" "new_string"))
  :category 'edit
  :approval 'ask
  :function
  (lambda (args context)
    (let* ((path (harness-tools-resolve (harness-tools-arg args :file_path) context))
           (old (or (harness-tools-arg args :old_string) ""))
           (new (or (harness-tools-arg args :new_string) ""))
           (replace-all (harness-tools-arg args :replace_all))
           (label (harness-relative-path path (harness-tool-context-directory context))))
      (cond
       ((not (file-exists-p path))
        (harness-tool-result-create :content (format "No such file: %s" label)
                                    :error "file not found"))
       ((string-empty-p old)
        (harness-tool-result-create :content "old_string must not be empty"
                                    :error "empty old_string"))
       (t
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents path))
          (let* ((content (buffer-string))
                 (first (string-search old content))
                 (count 0)
                 (index 0))
            (while (setq index (string-search old content index))
              (setq count (1+ count))
              (setq index (+ index (length old))))
            (cond
             ((zerop count)
              (harness-tool-result-create
               :content (format "old_string not found in %s" label)
               :error "old_string not found"))
             ((and (> count 1) (not replace-all))
              (harness-tool-result-create
               :content (format "old_string appears %d times in %s; add more context or set replace_all"
                                count label)
               :error "ambiguous old_string"))
             (t
              (let* ((replaced (if replace-all
                                   (replace-regexp-in-string
                                    (regexp-quote old) (lambda (_match) new) content t t)
                                 (concat (substring content 0 first)
                                         new
                                         (substring content (+ first (length old))))))
                     (line (1+ (cl-count ?\n content :start 0 :end first))))
                (let ((coding-system-for-write 'utf-8-unix)
                      (write-region-inhibit-fsync t))
                  (write-region replaced nil path nil 'silent))
                (harness-tool-result-create
                 :content (format "Replaced %d occurrence%s in %s"
                                  count (if (= count 1) "" "s") label)
                 :detail (list :kind 'edit :path path :line line
                               :old (harness-truncate-string old 4000 nil nil)
                               :new (harness-truncate-string new 4000 nil nil)))))))))))))

(harness-define-tool "glob"
  :description "Find files by glob pattern, for example \"**/*.el\" or \"src/*.ts\". Returns paths relative to the project."
  :parameters '(:type "object"
                :properties (:pattern (:type "string")
                             :path (:type "string"
                                    :description "Directory to search, default the project root"))
                :required ("pattern"))
  :category 'read
  :read-only t
  :approval 'allow
  :function
  (lambda (args context)
    (let* ((pattern (or (harness-tools-arg args :pattern) ""))
           (root (or (harness-tools-arg args :path)
                     (harness-tool-context-directory context)))
           ;; `wildcard-to-regexp' understands * and ? but not **, so a
           ;; leading **/ is handled by matching the basename as well.
           (regexp (wildcard-to-regexp (string-remove-prefix "**/" pattern)))
           (matches nil))
      (dolist (file (ignore-errors
                      (directory-files-recursively
                       root "" nil
                       (lambda (directory)
                         (not (string-match-p
                               "/\\(?:\\.git\\|\\.venv\\|node_modules\\|eln-cache\\|\\.cache\\)/"
                               (file-name-as-directory directory)))))))
        (when (and (< (length matches) harness-tool-search-limit)
                   (or (string-match-p regexp (harness-relative-path file root))
                       (string-match-p regexp (file-name-nondirectory file))))
          (push (harness-relative-path file root) matches)))
      (harness-tool-result-create
       :content (if matches
                    (string-join (nreverse matches) "\n")
                  (format "No files match %s under %s" pattern root))
       :detail (list :pattern pattern :path root :count (length matches))))))

(harness-define-tool "grep"
  :description "Search file contents with a regular expression. Returns matching lines with file names and line numbers."
  :parameters '(:type "object"
                :properties (:pattern (:type "string")
                             :path (:type "string")
                             :glob (:type "string"
                                    :description "Limit to files matching this shell glob, e.g. *.el"))
                :required ("pattern"))
  :category 'read
  :read-only t
  :approval 'allow
  :async
  (lambda (args context done)
    (let* ((pattern (or (harness-tools-arg args :pattern) ""))
           (root (or (harness-tools-arg args :path)
                     (harness-tool-context-directory context)))
           (glob (harness-tools-arg args :glob))
           (command (string-join
                     (delq nil
                           (list "grep" "-rn" "-I" "-E"
                                 (when glob
                                   (format "--include=%s" (shell-quote-argument glob)))
                                 (shell-quote-argument pattern)
                                 (shell-quote-argument (file-name-as-directory root))))
                     " ")))
      (harness-tools-run-process
       command root
       (lambda (result)
         (let ((output (string-trim-right (plist-get result :output)))
               (exit (plist-get result :exit)))
           (funcall done
                    (cond
                     ((and (integerp exit) (= exit 1))
                      (harness-tool-result-create
                       :content (format "No matches for %s under %s" pattern root)
                       :detail (list :pattern pattern :path root :count 0)))
                     (t
                      (harness-tool-result-create
                       :content (if (string-empty-p output)
                                    (format "No matches for %s" pattern)
                                  output)
                       :error (when (and (integerp exit) (> exit 1))
                                (format "grep exited with %d" exit))
                       :detail (list :pattern pattern :path root)))))))
       120))))

(harness-define-tool "bash"
  :description "Run a shell command in the project directory. Returns stdout and stderr and the exit code."
  :parameters '(:type "object"
                :properties (:command (:type "string"
                                       :description "The shell command to run")
                             :description (:type "string"
                                           :description "What the command does, for the user"))
                :required ("command"))
  :category 'execute
  :approval 'ask
  :async
  (lambda (args context done)
    (let* ((command (or (harness-tools-arg args :command) ""))
           (directory (harness-tool-context-directory context))
           (finish
            (lambda (result)
              (let* ((output (string-trim-right (plist-get result :output)))
                     (exit (plist-get result :exit))
                     (timed-out (plist-get result :timed-out))
                     (body (cond
                            (timed-out
                             (concat (when (not (string-empty-p output))
                                       (concat output "\n"))
                                     (format "Command timed out after %d seconds"
                                             harness-bash-timeout)))
                            ((string-empty-p output) "(no output)")
                            (t output))))
                (funcall done
                         (harness-tool-result-create
                          :content (format "%s\n(exit %s)" body
                                           (if exit (format "%d" exit) "killed"))
                          :error (cond (timed-out
                                        (format "timed out after %s seconds"
                                                harness-bash-timeout))
                                       ((and (integerp exit) (/= exit 0))
                                        (format "exit code %d" exit)))
                          :detail (list :command command :directory directory
                                        :exit exit)))))))
      (harness-tools-run-process command directory finish harness-bash-timeout))))

(harness-define-tool "todo"
  :description "Replace the session's task list. Use this to plan multi-step work and to show the user progress."
  :parameters '(:type "object"
                :properties (:todos (:type "array"
                                    :items (:type "object"
                                            :properties
                                            (:text (:type "string")
                                                   :status (:type "string"
                                                            :enum ("pending" "in_progress" "completed"))))))
                :required ("todos"))
  :category 'meta
  :read-only t
  :approval 'allow
  :function
  (lambda (args context)
    (let* ((session (harness-tool-context-session context))
           (raw (or (harness-tools-arg args :todos) '()))
           (todos (delq nil
                        (mapcar
                         (lambda (item)
                           (let ((text (harness-tools-arg item :text)))
                             (when (and text (not (string-empty-p (format "%s" text))))
                               (list :text (format "%s" text)
                                     :status (intern (or (harness-tools-arg item :status)
                                                         "pending"))))))
                         (if (listp raw) raw nil)))))
      (setf (harness-session-meta session)
            (plist-put (harness-session-meta session) :todos todos))
      (harness-session-save-state session)
      (harness-session-notify session 'meta)
      (harness-tool-result-create
       :content (if todos
                    (string-join
                     (mapcar (lambda (todo)
                               (format "%s %s"
                                       (pcase (harness-plist-or-alist-get :status todo)
                                         ('completed "[x]")
                                         ('in_progress "[~]")
                                         (_ "[ ]"))
                                       (harness-plist-or-alist-get :text todo)))
                             todos)
                     "\n")
                  "Task list cleared")
       :detail (list :kind 'todo :todos todos)))))

(defun harness-session-todos (session)
  "Return SESSION's task list."
  (harness-plist-or-alist-get :todos (harness-session-meta session)))

(provide 'harness-tools)
;;; harness-tools.el ends here
