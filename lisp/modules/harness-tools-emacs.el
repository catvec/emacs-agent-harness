;;; harness-tools-emacs.el --- The built-in tool set -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The default tools, implemented with Emacs' own facilities wherever one
;; exists (buffers, `insert-file-contents', `directory-files-recursively',
;; `re-search-forward') and with sandboxed processes only where it does not.
;;
;;   read           file contents with offset/limit line ranges
;;   write          create or overwrite a file
;;   edit           exact-string replacement with an occurrence check
;;   list           directory listing with depth
;;   glob           file name search (** supported)
;;   search         content search, ripgrep when available
;;   bash           shell command through the sandbox
;;   emacs-eval     evaluate Emacs Lisp in the running Emacs
;;   emacs-describe describe a function, variable, face or buffer
;;   todo           maintain the session todo list
;;
;; File tools work through TRAMP transparently: paths are expanded against
;; the session cwd, and Emacs handles the rest.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'seq)
(require 'subr-x)
(require 'harness-core)
(require 'harness-tools)
(require 'harness-sandbox)

(defgroup harness-tools-emacs nil
  "Built-in Emacs-native tools."
  :group 'harness-tools)

(defcustom harness-tools-emacs-read-max-lines 2000
  "Maximum lines `read' returns in one call."
  :type 'natnum)

(defcustom harness-tools-emacs-bash-timeout 120
  "Default `bash' timeout in seconds."
  :type 'number)

(defcustom harness-tools-emacs-bash-max-output 200000
  "Bytes of bash output kept before further output is dropped."
  :type 'natnum)

(defcustom harness-tools-emacs-search-max-results 200
  "Maximum matches `search' returns."
  :type 'natnum)

(defcustom harness-tools-emacs-glob-max-results 1000
  "Maximum paths `glob' returns."
  :type 'natnum)

;;; Shared helpers

(defun harness-tools-emacs--relative (context path)
  "Return PATH relative to CONTEXT's cwd when it is inside."
  (let* ((cwd (file-name-as-directory (expand-file-name (harness-tool-context-cwd context))))
         (absolute (harness-tool-context-path context path)))
    (if (string-prefix-p cwd absolute)
        (substring absolute (length cwd))
      absolute)))

(defun harness-tools-emacs--read-file-lines (file)
  "Return FILE contents as a list of lines."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((lines (split-string (buffer-string) "\n")))
      (if (and (cdr lines) (string-empty-p (car (last lines))))
          (butlast lines)
        lines))))

(defun harness-tools-emacs--numbered (lines start)
  "Number LINES starting at line START."
  (let ((number start))
    (mapconcat (lambda (line)
                 (prog1 (format "%6d\t%s" number line)
                   (cl-incf number)))
               lines "\n")))

(defun harness-tools-emacs--access (path mode)
  "Build an access descriptor for PATH with MODE."
  (list :path path :mode mode))

;;; read

(defun harness-tools-emacs-read (arguments context)
  "Read a file with optional line range.
ARGUMENTS: :path, :offset (1-based line), :limit (lines)."
  (let* ((path (harness-tool-context-path context (plist-get arguments :path)))
         (offset (max 1 (or (plist-get arguments :offset) 1)))
         (limit (min (or (plist-get arguments :limit) harness-tools-emacs-read-max-lines)
                     harness-tools-emacs-read-max-lines)))
    (cond
     ((not (file-exists-p path))
      (harness-tool-error-result (format "File does not exist: %s" path)))
     ((file-directory-p path)
      (harness-tool-error-result (format "%s is a directory; use `list'." path)))
     (t
      (let* ((lines (harness-tools-emacs--read-file-lines path))
             (total (length lines))
             (start (min offset total))
             (end (min total (+ start -1 limit)))
             (window (seq-subseq lines (1- start) end)))
        (concat
         (format "%s (%d lines)\n" (harness-tools-emacs--relative context path) total)
         (harness-tools-emacs--numbered window start)
         (when (< end total)
           (format "\n\n[showing lines %d-%d of %d; call read again with offset=%d]"
                   start end total (1+ end)))))))))

;;; write

(defun harness-tools-emacs-write (arguments context)
  "Write :content to :path, creating parent directories."
  (let* ((path (harness-tool-context-path context (plist-get arguments :path)))
         (content (or (plist-get arguments :content) "")))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert content))
    (format "Wrote %d bytes to %s."
            (string-bytes content)
            (harness-tools-emacs--relative context path))))

;;; edit

(defun harness-tools-emacs--count-occurrences (needle haystack)
  "Count non-overlapping NEEDLE occurrences in HAYSTACK."
  (let ((start 0) (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (cl-incf count)
      (setq start (match-end 0)))
    count))

(defun harness-tools-emacs-edit (arguments context)
  "Replace :oldText with :newText in :path."
  (let* ((path (harness-tool-context-path context (plist-get arguments :path)))
         (old (plist-get arguments :oldText))
         (new (or (plist-get arguments :newText) ""))
         (replace-all (plist-get arguments :replaceAll)))
    (cond
     ((not (file-exists-p path))
      (harness-tool-error-result (format "File does not exist: %s" path)))
     ((or (null old) (string-empty-p old))
      (harness-tool-error-result "oldText must not be empty."))
     (t
      (let* ((contents (with-temp-buffer (insert-file-contents path) (buffer-string)))
             (occurrences (harness-tools-emacs--count-occurrences old contents)))
        (cond
         ((zerop occurrences)
          (harness-tool-error-result
           (format "oldText was not found in %s; read the file and copy the text exactly."
                   (harness-tools-emacs--relative context path))))
         ((and (> occurrences 1) (not replace-all))
          (harness-tool-error-result
           (format "oldText occurs %d times in %s; add surrounding context to make it unique, or pass replaceAll."
                   occurrences (harness-tools-emacs--relative context path))))
         (t
          (let ((replaced (replace-regexp-in-string (regexp-quote old) new contents t t)))
            (with-temp-file path
              (insert replaced))
            (let* ((match-index (string-match (regexp-quote old) contents))
                   (line-number (1+ (cl-count ?\n contents :start 0 :end match-index)))
                   (lines (split-string replaced "\n"))
                   (from (max 0 (- line-number 3)))
                   (to (min (length lines) (+ line-number 3))))
              (format "Replaced %d occurrence%s in %s:\n%s"
                      occurrences (if (= occurrences 1) "" "s")
                      (harness-tools-emacs--relative context path)
                      (harness-tools-emacs--numbered
                       (seq-subseq lines from to) (1+ from))))))))))))

;;; list

(defun harness-tools-emacs-list (arguments context)
  "List :path to :depth (default 1)."
  (let* ((path (harness-tool-context-path context (or (plist-get arguments :path) ".")))
         (depth (max 1 (min (or (plist-get arguments :depth) 1) 8))))
    (cond
     ((not (file-exists-p path))
      (harness-tool-error-result (format "Directory does not exist: %s" path)))
     ((not (file-directory-p path))
      (harness-tool-error-result (format "%s is not a directory." path)))
     (t
      (let (lines)
        (cl-labels ((walk (directory level)
                      (dolist (entry (sort (directory-files directory t "\\`[^.]") #'string<))
                        (let ((relative (harness-tools-emacs--relative context entry)))
                          (cond
                           ((file-directory-p entry)
                            (push (format "%s/" relative) lines)
                            (when (< level depth)
                              (walk entry (1+ level))))
                           (t
                            (push (format "%-60s %8s"
                                          relative
                                          (or (ignore-errors
                                                (file-size-human-readable
                                                 (file-attribute-size (file-attributes entry))))
                                              "?"))
                                  lines)))))))
          (walk path 1))
        (if lines
            (mapconcat #'identity (nreverse lines) "\n")
          (format "Directory %s is empty." (harness-tools-emacs--relative context path))))))))

;;; glob

(defun harness-tools-emacs--glob-regexp (glob)
  "Convert GLOB to a regexp matching relative paths."
  (let ((index 0)
        (regexp ""))
    (while (< index (length glob))
      (let ((char (aref glob index)))
        (cond
         ((and char (eq char ?*) (< (1+ index) (length glob))
               (eq (aref glob (1+ index)) ?*))
          (cl-incf index)
          (if (and (< (1+ index) (length glob))
                   (eq (aref glob (1+ index)) ?/))
              (progn (cl-incf index) (setq regexp (concat regexp "\\(?:.*/\\)?")))
            (setq regexp (concat regexp ".*"))))
         ((eq char ?*) (setq regexp (concat regexp "[^/]*")))
         ((eq char ??) (setq regexp (concat regexp "[^/]")))
         (t (setq regexp (concat regexp (regexp-quote (char-to-string char)))))))
      (cl-incf index))
    (concat "\\`" regexp "\\'")))

(defun harness-tools-emacs-glob (arguments context)
  "Find files matching :pattern under :path."
  (let* ((pattern (or (plist-get arguments :pattern) "**/*"))
         (root (harness-tool-context-path context (or (plist-get arguments :path) ".")))
         (regexp (harness-tools-emacs--glob-regexp pattern))
         (matches nil)
         (limit harness-tools-emacs-glob-max-results))
    (cond
     ((not (file-directory-p root))
      (harness-tool-error-result (format "Directory does not exist: %s" root)))
     (t
      (let ((files (ignore-errors (directory-files-recursively root ""))))
        (dolist (file (append files nil))
          (let ((relative (harness-tools-emacs--relative context file)))
            (when (and (string-match-p regexp relative) (< (length matches) limit))
              (push relative matches)))))
      (if matches
          (concat (mapconcat #'identity (nreverse matches) "\n")
                  (when (= (length matches) limit)
                    (format "\n\n[stopped after %d matches]" limit)))
        (format "No files match %s under %s." pattern
                (harness-tools-emacs--relative context root)))))))

;;; search

(defun harness-tools-emacs--search-with-ripgrep (arguments context)
  "Search with ripgrep.  Returns a deferred."
  (let* ((path (or (plist-get arguments :path) "."))
         (pattern (plist-get arguments :pattern))
         (glob (plist-get arguments :glob))
         (argv (append (list "--line-number" "--no-heading" "--color" "never"
                             "--max-columns" "400")
                       (when glob (list "-g" glob))
                       (list "--" pattern path)))
         (output "")
         (deferred (harness-deferred-new))
         (spawned (harness-sandbox-spawn
                   :name "harness-search"
                   :command "rg"
                   :args argv
                   :cwd (harness-tool-context-cwd context)
                   :policy (harness-sandbox-policy)
                   :filter (lambda (_process chunk) (setq output (concat output chunk)))
                   :sentinel (lambda (process _event)
                               (when (memq (process-status process) '(exit signal))
                                 ;; Exit 1 means "no matches" for ripgrep.
                                 (let ((lines (seq-filter
                                               (lambda (line) (not (string-empty-p line)))
                                               (split-string output "\n"))))
                                   (harness-deferred-resolve
                                    deferred
                                    (if (or lines (zerop (process-exit-status process)))
                                        (concat
                                         (mapconcat #'identity
                                                    (seq-take lines
                                                              harness-tools-emacs-search-max-results)
                                                    "\n")
                                         (when (> (length lines)
                                                  harness-tools-emacs-search-max-results)
                                           (format "\n\n[stopped after %d matches]"
                                                   harness-tools-emacs-search-max-results)))
                                      (format "No matches for %s under %s."
                                              pattern path)))))))))
    (harness-tool-context-on-cancel
     context (lambda () (when (process-live-p (harness-sandbox-process-process spawned))
                          (delete-process (harness-sandbox-process-process spawned)))))
    deferred))

(defun harness-tools-emacs--search-with-elisp (arguments context)
  "Elisp fallback search.  Returns a string."
  (let* ((root (harness-tool-context-path context (or (plist-get arguments :path) ".")))
         (pattern (plist-get arguments :pattern))
         (glob (plist-get arguments :glob))
         (matcher (if glob
                      (harness-tools-emacs--glob-regexp glob)
                    "\\`.*\\'"))
         (matches nil)
         (limit harness-tools-emacs-search-max-results))
    (dolist (file (append (ignore-errors
                            (directory-files-recursively root "\\`[^.]" ))
                          nil))
      (when (and (< (length matches) limit)
                 (file-regular-p file)
                 (string-match-p matcher (harness-tools-emacs--relative context file))
                 (< (or (file-attribute-size (file-attributes file)) 0) (* 4 1024 1024)))
        (ignore-errors
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (while (and (not (eobp)) (< (length matches) limit))
              (when (re-search-forward pattern (line-end-position) t)
                (push (format "%s:%d:%s"
                              (harness-tools-emacs--relative context file)
                              (line-number-at-pos)
                              (string-trim (buffer-substring (line-beginning-position)
                                                             (line-end-position))))
                      matches))
              (forward-line 1))))))
    (if matches
        (mapconcat #'identity (nreverse matches) "\n")
      (format "No matches for %s under %s." pattern
              (harness-tools-emacs--relative context root)))))

(defun harness-tools-emacs-search (arguments context)
  "Search file contents for :pattern under :path."
  (if (executable-find "rg")
      (harness-tools-emacs--search-with-ripgrep arguments context)
    (harness-tools-emacs--search-with-elisp arguments context)))

;;; bash

(defun harness-tools-emacs-bash (arguments context)
  "Run :command in a sandboxed shell.  Returns a deferred."
  (let* ((command (plist-get arguments :command))
         (timeout (min (or (plist-get arguments :timeout)
                           harness-tools-emacs-bash-timeout)
                       (* 60 30)))
         (output "")
         (truncated nil)
         (deferred (harness-deferred-new))
         (timed-out nil)
         (spawned (harness-sandbox-spawn
                   :name "harness-bash"
                   :command "/bin/sh"
                   :args (list "-c" command)
                   :cwd (harness-tool-context-cwd context)
                   :policy (harness-sandbox-policy)
                   :filter (lambda (_process chunk)
                             (if (> (length output) harness-tools-emacs-bash-max-output)
                                 (setq truncated t)
                               (setq output (concat output chunk))))
                   :sentinel (lambda (process _event)
                               (when (memq (process-status process) '(exit signal))
                                 (harness-deferred-resolve
                                  deferred
                                  (format "%s\n%s"
                                          (format "exit code: %d%s"
                                                  (process-exit-status process)
                                                  (cond (timed-out
                                                         (format " (timed out after %ss)" timeout))
                                                        (truncated " (output truncated)")
                                                        (t "")))
                                          (if (string-empty-p output)
                                              "(no output)"
                                            output)))))))
         (watchdog (run-at-time timeout nil
                                (lambda ()
                                  (let ((process (harness-sandbox-process-process spawned)))
                                    (when (process-live-p process)
                                      (setq timed-out t)
                                      (delete-process process)))))))
    (harness-tool-context-on-cancel
     context
     (lambda ()
       (when (process-live-p (harness-sandbox-process-process spawned))
         (delete-process (harness-sandbox-process-process spawned)))))
    (harness-deferred-finally deferred (lambda () (cancel-timer watchdog)))
    deferred))

;;; emacs-eval and emacs-describe

(defun harness-tools-emacs-eval (arguments _context)
  "Evaluate :expression and return its printed value."
  (let ((expression (or (plist-get arguments :expression) "")))
    (condition-case err
        (let* ((value (eval (car (read-from-string expression)) t))
               (printed (if (and (listp value) value)
                            (pp-to-string value)
                          (prin1-to-string value))))
          (if (> (length printed) 20000)
              (concat (substring printed 0 20000)
                      "\n[... printed value truncated]")
            printed))
      (error (harness-tool-error-result
              (format "Evaluation error: %s" (error-message-string err)))))))

(defun harness-tools-emacs-describe (arguments _context)
  "Describe :name as :type (function, variable, face, buffer)."
  (let ((name (plist-get arguments :name))
        (type (or (plist-get arguments :type) "function")))
    (pcase type
      ("function"
       (let ((symbol (intern name)))
         (cond
          ((fboundp symbol)
           (format "%s\n\nSignature: %S"
                   (or (documentation symbol) "No documentation.")
                   (help-function-arglist symbol t)))
          (t (harness-tool-error-result (format "No function named %s." name))))))
      ((or "variable" "var")
       (let ((symbol (intern name)))
         (cond
          ((boundp symbol)
           (format "Value: %S\n\n%s"
                   (if (> (length (prin1-to-string (symbol-value symbol))) 5000)
                       "[large value]"
                     (symbol-value symbol))
                   (or (documentation-property symbol 'variable-documentation)
                       "No documentation.")))
          (t (harness-tool-error-result (format "No variable named %s." name))))))
      ("face"
       (let ((face (intern name)))
         (if (facep face)
             (format "%s" (get face 'face-documentation))
           (harness-tool-error-result (format "No face named %s." name)))))
      ("buffer"
       (let ((buffer (get-buffer name)))
         (if buffer
             (with-current-buffer buffer
               (format "Buffer %s: %d lines, mode %s, file %s"
                       (buffer-name) (line-number-at-pos (point-max))
                       major-mode (or buffer-file-name "(none)")))
           (harness-tool-error-result (format "No buffer named %s." name)))))
      (_ (harness-tool-error-result
          (format "Unknown describe type %s (function, variable, face, buffer)." type))))))

;;; todo

(defun harness-tools-emacs--render-todos (todos)
  "Render TODOS as a checklist."
  (if (or (null todos) (zerop (length todos)))
      "Todo list is empty."
    (mapconcat (lambda (item)
                 (format "%s %s"
                         (pcase (plist-get item :status)
                           ((or "completed" "done") "[x]")
                           ("in_progress" "[~]")
                           (_ "[ ]"))
                         (or (plist-get item :content) (plist-get item :text) "")))
               (append todos nil) "\n")))

(defun harness-tools-emacs-todo (arguments context)
  "Replace the session todo list with :todos."
  (let* ((todos (or (plist-get arguments :todos) []))
         (session-id (harness-tool-context-session-id context)))
    (when (harness-service-available-p "session" 'state-set)
      (harness-service-call "session" 'state-set
                            :session-id session-id :key 'todos :value todos)
      (harness-service-call "session" 'append
                            :session-id session-id
                            :entry (list :sessionUpdate "_harness/todo"
                                         :todos todos)))
    (harness-tools-emacs--render-todos todos)))

;;; Registration

(defun harness-tools-emacs-setup ()
  "Register the built-in tools."
  (harness-tool-register
   "read"
   :description "Read a text file, optionally a line range. Prefer this over cat."
   :schema '(:type "object"
             :properties (:path (:type "string" :description "File path, absolute or relative to the session directory.")
                          :offset (:type "integer" :description "1-based line to start at.")
                          :limit (:type "integer" :description "Maximum number of lines."))
             :required ["path"])
   :kind 'read
   :read-only t
   :range-params '("offset" "limit")
   :access (lambda (arguments) (list (harness-tools-emacs--access (plist-get arguments :path) "read")))
   :handler #'harness-tools-emacs-read)

  (harness-tool-register
   "write"
   :description "Create or overwrite a file with the given content."
   :schema '(:type "object"
             :properties (:path (:type "string")
                          :content (:type "string"))
             :required ["path" "content"])
   :kind 'edit
   :access (lambda (arguments) (list (harness-tools-emacs--access (plist-get arguments :path) "write")))
   :handler #'harness-tools-emacs-write)

  (harness-tool-register
   "edit"
   :description "Replace an exact string in a file. oldText must match exactly."
   :schema '(:type "object"
             :properties (:path (:type "string")
                          :oldText (:type "string")
                          :newText (:type "string")
                          :replaceAll (:type "boolean"))
             :required ["path" "oldText" "newText"])
   :kind 'edit
   :access (lambda (arguments) (list (harness-tools-emacs--access (plist-get arguments :path) "write")))
   :handler #'harness-tools-emacs-edit)

  (harness-tool-register
   "list"
   :description "List a directory, optionally recursively."
   :schema '(:type "object"
             :properties (:path (:type "string")
                          :depth (:type "integer"))
             :required [])
   :kind 'read
   :read-only t
   :range-params '("depth")
   :access (lambda (arguments) (list (harness-tools-emacs--access (or (plist-get arguments :path) ".") "read")))
   :handler #'harness-tools-emacs-list)

  (harness-tool-register
   "glob"
   :description "Find files by glob pattern; ** matches across directories."
   :schema '(:type "object"
             :properties (:pattern (:type "string")
                          :path (:type "string"))
             :required ["pattern"])
   :kind 'search
   :read-only t
   :access (lambda (arguments) (list (harness-tools-emacs--access (or (plist-get arguments :path) ".") "read")))
   :handler #'harness-tools-emacs-glob)

  (harness-tool-register
   "search"
   :description "Search file contents by regular expression (ripgrep when available)."
   :schema '(:type "object"
             :properties (:pattern (:type "string")
                          :path (:type "string")
                          :glob (:type "string" :description "Only search files matching this glob."))
             :required ["pattern"])
   :kind 'search
   :read-only t
   :range-params '("glob")
   :access (lambda (arguments) (list (harness-tools-emacs--access (or (plist-get arguments :path) ".") "read")))
   :handler #'harness-tools-emacs-search)

  (harness-tool-register
   "bash"
   :description "Run a shell command in the session directory, confined by the sandbox."
   :schema '(:type "object"
             :properties (:command (:type "string")
                          :timeout (:type "integer" :description "Seconds, default 120."))
             :required ["command"])
   :kind 'execute
   :handler #'harness-tools-emacs-bash)

  (harness-tool-register
   "emacs-eval"
   :description "Evaluate an Emacs Lisp expression in the running Emacs."
   :schema '(:type "object"
             :properties (:expression (:type "string"))
             :required ["expression"])
   :kind 'execute
   :handler #'harness-tools-emacs-eval)

  (harness-tool-register
   "emacs-describe"
   :description "Show documentation for a function, variable, face or buffer."
   :schema '(:type "object"
             :properties (:name (:type "string")
                          :type (:type "string"))
             :required ["name"])
   :kind 'read
   :read-only t
   :handler #'harness-tools-emacs-describe)

  (harness-tool-register
   "todo"
   :description "Replace the session todo list. Each item is {content, status} with status pending, in_progress or completed."
   :schema '(:type "object"
             :properties (:todos (:type "array"))
             :required ["todos"])
   :kind 'other
   :handler #'harness-tools-emacs-todo))

(defun harness-tools-emacs-teardown ()
  "Remove the built-in tools."
  (harness-tool-unregister-module 'harness-tools-emacs))

(harness-module-define 'harness-tools-emacs
  :version harness-version
  :description "Built-in Emacs-native tool set."
  :requires '((harness-core "0.1.0")
              (harness-tools "0.1.0")
              (harness-sandbox "0.1.0"))
  :provides '(harness-tools-emacs)
  :setup #'harness-tools-emacs-setup
  :teardown #'harness-tools-emacs-teardown)

(provide 'harness-tools-emacs)
;;; harness-tools-emacs.el ends here
