;;; harness-tools.el --- Tool registry and context-bomb protection -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Tools are the only way the agent acts on the world.  Each tool declares a
;; JSON schema, a kind, and a handler that returns a deferred (or a plain
;; value) of a normalized result:
;;
;;   (:content (VEC of content blocks) :is-error BOOL
;;    :locations ((:path ... :line ...)) :truncated BOOL :meta ...)
;;
;; A handler receives ARGUMENTS (a plist decoded from the model's JSON) and
;; a `harness-tool-context' with the session id, working directory and
;; abort deferred.
;;
;; Context-bomb protection lives here, not in each tool: results over
;; `harness-tools-max-output-bytes' are either refused with instructions to
;; use range parameters (tools that declare `:range-params') or truncated
;; with a notice (everything else), unless the tool is `:unbounded'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'harness-core)

(define-error 'harness-tool-error "Tool error" 'harness-error)
(define-error 'harness-tool-not-found "Tool not found" 'harness-user-error)

(defgroup harness-tools nil
  "Agent tools."
  :group 'harness)

(defcustom harness-tools-max-output-bytes 65536
  "Results larger than this are refused or truncated."
  :type 'natnum)

(defcustom harness-tools-truncated-bytes 8192
  "How much of an unbounded oversized result to show."
  :type 'natnum)

;;; Tools

(cl-defstruct (harness-tool (:constructor harness-tool--make))
  name
  module
  description
  schema                      ; plist JSON Schema
  kind                        ; read, edit, delete, move, search, execute, ...
  read-only
  unbounded
  range-params                ; names of range arguments, when supported
  handler                     ; (arguments context) -> result or deferred
  access-fn                   ; (arguments) -> ((:path P :mode M) ...)
  config)

(defvar harness-tools--registry (make-hash-table :test #'equal)
  "Tool name (string) -> `harness-tool'.")

(defun harness-tool-register (name &rest properties)
  "Register tool NAME (a string) with PROPERTIES.

  :description  what the model sees
  :schema       JSON Schema plist for the arguments
  :kind         read, edit, delete, move, search, execute, fetch, other
  :read-only    non-nil when the tool never modifies state
  :unbounded    non-nil to skip output-size protection
  :range-params list of argument names that narrow the output
  :handler      (arguments context) -> result plist or deferred
  :access       (arguments) -> list of (:path PATH :mode read|write|search)
  :module       owning module, defaults to the module being set up

Returns the tool."
  (declare (indent 1))
  (let* ((module (or (plist-get properties :module) harness-core--current-module))
         (tool (harness-tool--make
                :name name
                :module module
                :description (plist-get properties :description)
                :schema (plist-get properties :schema)
                :kind (or (plist-get properties :kind) 'other)
                :read-only (plist-get properties :read-only)
                :unbounded (plist-get properties :unbounded)
                :range-params (plist-get properties :range-params)
                :handler (plist-get properties :handler)
                :access-fn (plist-get properties :access)
                :config (plist-get properties :config))))
    (when module
      (harness-core-add-module-cleanup
       module (lambda () (harness-tool-unregister name))))
    (puthash name tool harness-tools--registry)
    tool))

(defun harness-tool-unregister (name)
  "Remove tool NAME."
  (remhash name harness-tools--registry))

(defun harness-tool-unregister-module (module)
  "Remove every tool owned by MODULE."
  (let ((names nil))
    (maphash (lambda (name tool)
               (when (eq (harness-tool-module tool) module)
                 (push name names)))
             harness-tools--registry)
    (dolist (name names) (remhash name harness-tools--registry))))

(defun harness-tool-get (name)
  "Return tool NAME, or nil."
  (gethash name harness-tools--registry))

(defun harness-tool-list ()
  "Return all registered tools, sorted by name."
  (sort (hash-table-values harness-tools--registry)
        (lambda (a b) (string< (harness-tool-name a) (harness-tool-name b)))))

(defun harness-tools-specs (&optional names)
  "Return model-facing specs for tools, optionally filtered by NAMES."
  (vconcat
   (mapcar (lambda (tool)
             (harness-plist-omit-nil
              (list :name (harness-tool-name tool)
                    :description (harness-tool-description tool)
                    :input-schema (or (harness-tool-schema tool)
                                      (list :type "object" :properties (make-hash-table))))))
           (seq-filter (lambda (tool)
                         (or (null names) (member (harness-tool-name tool) names)))
                       (harness-tool-list)))))

;;; Argument validation

(defun harness-tools--type-error (value type)
  "Return non-nil when VALUE does not fit TYPE."
  (pcase type
    ("string" (not (stringp value)))
    ("integer" (not (integerp value)))
    ("number" (not (numberp value)))
    ("boolean" (not (memq value '(t :false))))
    ("array" (not (or (vectorp value) (listp value))))
    ("object" (not (or (null value) (listp value))))
    (_ nil)))

(defun harness-tools-validate (tool arguments)
  "Return a list of validation errors for ARGUMENTS on TOOL."
  (let ((schema (harness-tool-schema tool))
        (errors nil))
    (when (and schema (listp arguments))
      (dolist (required (append (plist-get schema :required) nil))
        (unless (plist-get arguments (intern (concat ":" required)))
          (push (format "Missing required argument `%s'." required) errors)))
      (let ((properties (plist-get schema :properties)))
        (cl-loop for (key value) on properties by #'cddr
                 do (let ((actual (plist-get arguments key)))
                      (when (and (not (null actual))
                                 (plist-get value :type)
                                 (harness-tools--type-error actual (plist-get value :type)))
                        (push (format "Argument `%s' should be %s."
                                      (substring (symbol-name key) 1)
                                      (plist-get value :type))
                              errors))))))
    (nreverse errors)))

;;; Results

(defun harness-tools--content (result)
  "Return RESULT's content as a vector of blocks."
  (let ((content (plist-get result :content)))
    (cond
     ((null content) [])
     ((vectorp content) content)
     ((stringp content) (vector (list :type "text" :text content)))
     ((and (listp content) (plist-get content :type)) (vector content))
     ((listp content) (vconcat content))
     (t (vector (list :type "text" :text (format "%S" content)))))))

(defun harness-tools--content-bytes (content)
  "Return the byte size of CONTENT blocks."
  (seq-reduce
   (lambda (total block)
     (+ total (if (equal (plist-get block :type) "text")
                  (string-bytes (or (plist-get block :text) ""))
                (string-bytes (prin1-to-string block)))))
   content 0))

(defun harness-tools--text-of (content)
  "Concatenate the text of CONTENT blocks."
  (mapconcat (lambda (block) (or (plist-get block :text) ""))
             (seq-filter (lambda (block) (equal (plist-get block :type) "text"))
                         (append content nil))
             ""))

(defun harness-tool-error-result (message)
  "Build an error result carrying MESSAGE."
  (list :is-error t
        :content (vector (list :type "text" :text message))))

(defun harness-tool-result (text &rest properties)
  "Build a plain result whose content is TEXT."
  (append (list :content (vector (list :type "text" :text text)))
          properties))

(defun harness-tools-normalize-result (tool result)
  "Normalize RESULT from TOOL, applying context-bomb protection."
  (let* ((result (cond
                  ((null result) (harness-tool-result ""))
                  ((stringp result) (harness-tool-result result))
                  ((plist-get result :content) result)
                  ((vectorp result) (list :content result))
                  (t (harness-tool-result (format "%S" result)))))
         (content (harness-tools--content result))
         (bytes (harness-tools--content-bytes content)))
    (append
     (if (<= bytes harness-tools-max-output-bytes)
         (list :content content)
       (cond
        ((harness-tool-unbounded tool)
         (list :content content))
        ((harness-tool-range-params tool)
         (list :content
               (vector (list :type "text"
                             :text (format
                                    "Output is %d bytes, over the %d byte limit, so it was not returned. Use the %s arguments to read it in smaller parts."
                                    bytes harness-tools-max-output-bytes
                                    (string-join (harness-tool-range-params tool) ", "))))
               :truncated t))
        (t
         (let* ((text (harness-tools--text-of content))
                (kept (substring text 0 (min (length text)
                                             harness-tools-truncated-bytes))))
           (list :content
                 (vector (list :type "text"
                               :text (format "%s\n\n[output truncated: showing the first %d of %d bytes; narrow the request to see more]"
                                             kept (string-bytes kept) bytes)))
                 :truncated t)))))
     (harness-plist-omit-nil
      (list :is-error (plist-get result :is-error)
            :locations (plist-get result :locations)
            :meta (plist-get result :meta))))))

;;; Context

(cl-defstruct (harness-tool-context (:constructor harness-tool-context-create))
  session-id
  cwd
  abort                         ; deferred, cancelled to abort the tool
  report                        ; (string &optional plist) progress callback
  meta)                         ; extra plist, e.g. the session info

(defun harness-tool-context-path (context path)
  "Expand PATH against CONTEXT's working directory."
  (expand-file-name path (harness-tool-context-cwd context)))

(defun harness-tool-context-cancelled-p (context)
  "Return non-nil when CONTEXT's abort deferred was cancelled."
  (let ((abort (harness-tool-context-abort context)))
    (and abort (harness-deferred-rejected-p abort))))

(defun harness-tool-context-on-cancel (context function)
  "Call FUNCTION when CONTEXT is aborted."
  (when-let* ((abort (harness-tool-context-abort context)))
    (harness-deferred-on-cancel abort function)))

(defun harness-tool-context-report (context message &optional properties)
  "Report progress MESSAGE to the agent."
  (when-let* ((report (harness-tool-context-report context)))
    (funcall report message properties)))

;;; Execution

(harness-event-define 'tool-executed
  :module 'harness-tools
  :doc "A tool handler finished."
  :payload '((name . string) (session-id . string) (is-error . boolean)
             (duration . number)))

(defun harness-tools-execute (name arguments &optional context)
  "Execute tool NAME with ARGUMENTS.
CONTEXT is a `harness-tool-context'.  Always returns a deferred resolving
to a normalized result; handler failures become `:is-error' results."
  (let ((deferred (harness-deferred-new))
        (start (harness-now))
        (tool (harness-tool-get name)))
    (cond
     ((null tool)
      (harness-deferred-resolve
       deferred (harness-tool-error-result (format "No such tool: %s" name))))
     ((null (harness-tool-handler tool))
      (harness-deferred-resolve
       deferred (harness-tool-error-result (format "Tool %s has no handler" name))))
     (t
      (let ((errors (harness-tools-validate tool arguments)))
        (if errors
            (harness-deferred-resolve
             deferred (harness-tool-error-result
                       (concat "Invalid arguments:\n- " (string-join errors "\n- "))))
          (let ((result nil))
            (condition-case err
                (setq result (funcall (harness-tool-handler tool)
                                      (or arguments nil) context))
              (error
               (setq result
                     (harness-tool-error-result
                      (format "Tool %s failed: %s" name (error-message-string err))))))
            (if (harness-deferred-p result)
                (harness-deferred-then
                 result
                 (lambda (value)
                   (harness-deferred-resolve
                    deferred
                    (harness-tools--finish name context
                                           (harness-tools-normalize-result tool value)
                                           start)))
                 (lambda (error)
                   (harness-deferred-resolve
                    deferred
                    (harness-tools--finish
                     name context
                     (harness-tool-error-result
                      (format "Tool %s failed: %s" name
                              (if (stringp (car (cdr error)))
                                  (car (cdr error))
                                (format "%S" error))))
                     start))))
              (harness-deferred-resolve
               deferred
               (harness-tools--finish name context
                                      (harness-tools-normalize-result tool result)
                                      start))))))))))

(defun harness-tools--finish (name context result start)
  "Emit the completion event for NAME and return RESULT."
  (harness-emit 'tool-executed
                :name name
                :session-id (and context (harness-tool-context-session-id context))
                :is-error (plist-get result :is-error)
                :duration (- (harness-now) start))
  result)

;;; Service

(defun harness-tools-service-list (&rest _args)
  "Service: describe registered tools."
  (vconcat
   (mapcar (lambda (tool)
             (list :name (harness-tool-name tool)
                   :description (harness-tool-description tool)
                   :kind (symbol-name (harness-tool-kind tool))
                   :read-only (harness-tool-read-only tool)
                   :module (harness-tool-module tool)))
           (harness-tool-list))))

(defun harness-tools-service-specs (&rest args)
  "Service: model-facing tool specs."
  (harness-tools-specs (plist-get args :names)))

(defun harness-tools-service-execute (&rest args)
  "Service: execute a tool."
  (harness-tools-execute
   (plist-get args :name)
   (plist-get args :arguments)
   (harness-tool-context-create
    :session-id (plist-get args :session-id)
    :cwd (or (plist-get args :cwd) default-directory)
    :abort (plist-get args :abort))))

(defun harness-tools-service-get (&rest args)
  "Service: return a tool's declaration."
  (let ((tool (harness-tool-get (plist-get args :name))))
    (when tool
      (list :name (harness-tool-name tool)
            :description (harness-tool-description tool)
            :schema (harness-tool-schema tool)
            :kind (symbol-name (harness-tool-kind tool))
            :read-only (harness-tool-read-only tool)))))

(defun harness-tools-setup ()
  "Set up the tools module."
  (harness-service-register
   "tool"
   :module 'harness-tools
   :doc "Agent tool registry and execution."
   :methods '((list . harness-tools-service-list)
              (get . harness-tools-service-get)
              (specs . harness-tools-service-specs)
              (execute . harness-tools-service-execute))))

(defun harness-tools-teardown ()
  "Tear down the tools module."
  (clrhash harness-tools--registry))

(harness-module-define 'harness-tools
  :version harness-version
  :description "Tool registry, validation and context-bomb protection."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-tools)
  :setup #'harness-tools-setup
  :teardown #'harness-tools-teardown)

(provide 'harness-tools)
;;; harness-tools.el ends here
