;;; harness-tools.el --- Tool registry and execution pipeline  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tools are declared with `harness-define-tool' and executed with the
;; `tools/execute' method, which runs the permission chain, the handler
;; (with a timeout), the context-bomb guard and the result filter.  A
;; tool never runs without a permission decision; when no permission
;; module is installed every call is denied, so a misconfigured harness
;; fails safe.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)

(defcustom harness-tools-max-output-chars 30000
  "Tool outputs longer than this are saved to a file and truncated."
  :type 'integer :group 'harness)

(defcustom harness-tools-timeout 600
  "Default seconds a tool may run before it is cancelled."
  :type 'number :group 'harness)

(cl-defstruct (harness-tool (:copier nil))
  name description schema handler kind paths-fn coalescable title-fn module timeout)

(defvar harness-tools (make-hash-table :test 'equal)
  "Tool name -> `harness-tool'.")

(cl-defun harness-define-tool (name &key description schema handler (kind 'meta)
                                    paths coalescable title timeout)
  "Register tool NAME.  See docs/architecture.md for the keyword arguments."
  (unless (functionp handler) (error "Tool %s needs a handler" name))
  (puthash name (make-harness-tool :name name :description (or description "")
                                   :schema (or schema '(:type "object" :properties :empty))
                                   :handler handler :kind kind :paths-fn paths
                                   :coalescable coalescable :title-fn title
                                   :timeout timeout
                                   :module (and (boundp 'harness--defining-module)
                                                harness--defining-module))
           harness-tools)
  name)

(defun harness-tool-get (name)
  "Return the tool struct for NAME or nil."
  (gethash name harness-tools))

(defun harness-tool-spec (tool)
  "Return the public spec plist of TOOL."
  (list :name (harness-tool-name tool)
        :description (harness-tool-description tool)
        :schema (harness-tool-schema tool)
        :kind (harness-tool-kind tool)
        :coalescable (and (harness-tool-coalescable tool) t)))

(defun harness-tool-title (name input)
  "Return a short label for a call to NAME with INPUT."
  (let ((tool (harness-tool-get name)))
    (or (and tool (harness-tool-title-fn tool)
             (ignore-errors (funcall (harness-tool-title-fn tool) input)))
        (let ((first (cl-loop for (_k v) on input by #'cddr
                              when (stringp v) return v)))
          (if first
              (format "%s %s" name (harness-truncate-end (harness-first-line first) 60))
            name)))))

;;;; Results

(defun harness-tool-ok (content &rest props)
  "Return a successful RESULT with CONTENT and extra PROPS."
  (append (list :content (if (stringp content) content (format "%S" content)) :is-error nil) props))

(defun harness-tool-error (message &rest props)
  "Return an error RESULT with MESSAGE."
  (append (list :content message :is-error t) props))

(defun harness-tools--normalise-result (value)
  (cond ((and (listp value) (plist-member value :content))
         (plist-put (copy-sequence value) :is-error (and (plist-get value :is-error) t)))
        ((stringp value) (harness-tool-ok value))
        ((null value) (harness-tool-ok ""))
        (t (harness-tool-ok (format "%S" value)))))

(defun harness-tools--guard-size (result call-id)
  "Truncate an oversized RESULT, saving the full text for range reads."
  (let ((content (plist-get result :content)))
    (if (<= (length content) harness-tools-max-output-chars)
        result
      (let* ((dir (expand-file-name "outputs" harness-state-directory))
             (path (expand-file-name (format "%s.txt" (or call-id (harness-short-id))) dir))
             (head (substring content 0 (/ harness-tools-max-output-chars 3))))
        (harness-write-file-atomically path content)
        (plist-put
         (plist-put (copy-sequence result) :content
                    (format "%s\n\n[Output truncated: %d characters, %d lines. The full output was saved to %s. Read it in ranges with read_file (offset/limit), or narrow the request.]"
                            head (length content)
                            (1+ (cl-count ?\n content)) path))
         :truncated (list :path path :chars (length content)))))))

;;;; Context

(defun harness-tools--session (session-id)
  (or (and session-id (harness-method-exists-p 'session/get)
           (ignore-errors (harness-call 'session/get session-id)))
      (list :id session-id :cwd (file-name-as-directory (expand-file-name default-directory)))))

(defun harness-tools-resolve-path (path ctx)
  "Return PATH absolute, relative to CTX's cwd and host."
  (let* ((cwd (or (plist-get ctx :cwd) default-directory))
         (host (plist-get ctx :host))
         (p (expand-file-name path cwd)))
    (if (and host (not (file-remote-p p)))
        (concat host p)
      p)))

(defun harness-tools--paths (tool input ctx)
  (when (harness-tool-paths-fn tool)
    (condition-case err
        (mapcar (lambda (p) (harness-tools-resolve-path p ctx))
                (delq nil (funcall (harness-tool-paths-fn tool) input)))
      (error (harness-log 'warn "tool %s: paths function failed: %S" (harness-tool-name tool) err) nil))))

;;;; Methods

(harness-defmethod tools/list (&optional session-id)
  "Return tool specs available to SESSION-ID (or all), after `agent/tools'."
  (let* ((session (and session-id (harness-tools--session session-id)))
         (names (let (n) (maphash (lambda (k _) (push k n)) harness-tools) (sort n #'string<)))
         (names (if session (harness-run-filter 'agent/tools names session) names)))
    (delq nil (mapcar (lambda (n) (let ((tool (harness-tool-get n))) (and tool (harness-tool-spec tool)))) names))))

(harness-defmethod tools/get (name)
  "Return the spec of tool NAME or nil."
  (let ((tool (harness-tool-get name))) (and tool (harness-tool-spec tool))))

(defun harness-tools--run-handler (tool input ctx)
  "Run TOOL's handler; return a promise of a normalised result, with timeout."
  (harness-with-promise (resolve reject)
    (let* ((timeout (or (harness-tool-timeout tool) harness-tools-timeout))
           (timer nil)
           (settled nil)
           (finish (lambda (value)
                     (unless settled
                       (setq settled t)
                       (when timer (cancel-timer timer))
                       (funcall resolve (harness-tools--normalise-result value))))))
      (ignore reject)
      (setq timer (run-at-time timeout nil
                               (lambda ()
                                 (funcall finish (harness-tool-error
                                                  (format "Tool %s timed out after %ss" (harness-tool-name tool) timeout))))))
      (condition-case err
          (let ((value (funcall (harness-tool-handler tool) input ctx)))
            (if (harness-promise-p value)
                (harness-then value finish
                              (lambda (e) (funcall finish (harness-tool-error
                                                           (format "Tool %s failed: %s" (harness-tool-name tool)
                                                                   (harness-error-message e))))))
              (funcall finish value)))
        (error (funcall finish (harness-tool-error
                                (format "Tool %s failed: %s" (harness-tool-name tool)
                                        (harness-error-message err)))))))))

(harness-defmethod tools/execute (session-id call)
  "Execute CALL (:id :name :input) for SESSION-ID; return a promise of a RESULT."
  (let* ((name (plist-get call :name))
         (call-id (or (plist-get call :id) (harness-short-id)))
         (input (plist-get call :input))
         (tool (harness-tool-get name))
         (session (harness-tools--session session-id))
         (ctx (list :session-id session-id :cwd (plist-get session :cwd)
                    :host (plist-get session :host) :call-id call-id
                    :report (lambda (text)
                              (harness-emit 'tools/progress session-id call-id text)))))
    (harness-emit 'tools/started session-id call)
    (cond
     ((null tool)
      (let ((r (harness-tool-error (format "Unknown tool %s. Available: %s" name
                                           (mapconcat (lambda (s) (plist-get s :name))
                                                      (harness-call 'tools/list session-id) ", ")))))
        (harness-emit 'tools/finished session-id call r)
        (harness-resolved r)))
     (t
      (let* ((request (list :session session :tool name :input input
                            :kind (harness-tool-kind tool)
                            :paths (harness-tools--paths tool input ctx)
                            :call-id call-id))
             (decision (harness-run-filter-async 'permission/decide (list :behavior 'ask) request)))
        (harness-then
         decision
         (lambda (decision)
           (let ((behavior (plist-get decision :behavior)))
             (harness-emit 'permission/decided session-id request decision)
             (harness-then
              (if (eq behavior 'allow)
                  (harness-tools--run-handler tool (or (plist-get decision :input) input) ctx)
                (harness-resolved
                 (harness-tool-error
                  (format "Denied: %s%s"
                          (or (plist-get decision :reason)
                              (if (eq behavior 'ask) "no permission handler answered"
                                "not permitted"))
                          (if (plist-get decision :hint) (concat " " (plist-get decision :hint)) ""))
                  :denied t)))
              (lambda (result)
                (let* ((result (harness-tools--guard-size result call-id))
                       (result (harness-run-filter 'tools/result result session-id call)))
                  (harness-emit 'tools/finished session-id call result)
                  result)))))))))))

(harness-declare-event 'tools/started "(SESSION-ID CALL) before permission and execution.")
(harness-declare-event 'tools/progress "(SESSION-ID CALL-ID TEXT) progress from a running tool.")
(harness-declare-event 'tools/finished "(SESSION-ID CALL RESULT) after execution or denial.")
(harness-declare-event 'permission/decided "(SESSION-ID REQUEST DECISION) after the permission chain.")

(harness-define-module 'tools
  :doc "Tool registry, permission-gated execution and context-bomb guard.")

(provide 'harness-tools)
;;; harness-tools.el ends here
