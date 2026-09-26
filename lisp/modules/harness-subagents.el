;;; harness-subagents.el --- Sub-agent tool -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A tool that spawns a fully fledged session as a sub-agent.  The child
;; session is created with this session as its parent (so it shows up in
;; the conversation tree and the session list), inherits the model and
;; thinking level, runs the given prompt to completion, and reports its
;; final message back as the tool result.
;;
;; The nesting depth is capped so an agent cannot fork itself into an
;; infinite tree of sessions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-tools)
(require 'harness-session)
(require 'harness-agent)

(defcustom harness-subagents-max-depth 3
  "Maximum sub-agent nesting depth."
  :type 'natnum)

(defcustom harness-subagents-max-result-chars 6000
  "Maximum characters of a sub-agent report handed back to the caller."
  :type 'natnum)

(defun harness-subagents--info (session-id)
  "Return SESSION-ID's info plist, or nil."
  (when (harness-service-available-p "session" 'info)
    (ignore-errors (harness-service-call "session" 'info :session-id session-id))))

(defun harness-subagents--depth (session-id)
  "Return how deep SESSION-ID sits in the parent chain."
  (let ((depth 0)
        (current session-id)
        (seen nil))
    (while (and current (not (member current seen)) (< depth 100))
      (push current seen)
      (setq current (plist-get (harness-subagents--info current) :parentId))
      (when current (cl-incf depth)))
    depth))

(defun harness-subagents--truncate (text)
  "Limit TEXT to `harness-subagents-max-result-chars'."
  (if (and text (> (length text) harness-subagents-max-result-chars))
      (concat (substring text 0 harness-subagents-max-result-chars)
              "\n\n[report truncated]")
    text))

(defun harness-subagents--inherit (parent-id child-id)
  "Copy PARENT-ID's model and thinking level onto CHILD-ID."
  (let ((info (harness-subagents--info parent-id)))
    (dolist (config '(("model" . :model) ("thinking" . :thinking)))
      (let ((value (plist-get info (cdr config))))
        (when value
          (ignore-errors
            (harness-service-call "agent" 'set-config
                                  :session-id child-id
                                  :config-id (car config)
                                  :value (if (symbolp value) (symbol-name value) value))))))))

(defun harness-subagents--directory (arguments context)
  "Resolve the working directory for a sub-agent call."
  (let ((directory (plist-get arguments :directory)))
    (if (and directory (not (string-empty-p directory)))
        (file-name-as-directory
         (expand-file-name directory (harness-tool-context-cwd context)))
      (harness-tool-context-cwd context))))

(defun harness-subagents--create-session (arguments context parent-id)
  "Create the child session for ARGUMENTS with PARENT-ID."
  (let ((fork-entry (plist-get arguments :fork))
        (directory (harness-subagents--directory arguments context))
        (title (plist-get arguments :title)))
    (if fork-entry
        ;; A fork inherits the parent's transcript, model, thinking level
        ;; and permission mode; the working directory stays the parent's.
        (let ((parent (condition-case nil (harness-session-load parent-id) (error nil))))
          (if parent
              (harness-session-fork
               parent
               :entry-id (and (stringp fork-entry) fork-entry)
               :title (and title (not (string-empty-p title)) title))
            (harness-session-create :cwd directory :title title :parent-id parent-id)))
      (harness-session-create :cwd directory :title title :parent-id parent-id))))

(defun harness-subagents-tool (arguments context)
  "Tool handler: run a prompt in a new sub-agent session.
Returns a deferred resolving to the sub-agent's final report."
  (let ((parent-id (harness-tool-context-session-id context))
        (prompt (plist-get arguments :prompt)))
    (cond
     ((or (null prompt) (string-empty-p (string-trim prompt)))
      (harness-tool-error-result "A sub-agent needs a prompt."))
     ((not (harness-service-available-p "agent" 'prompt))
      (harness-tool-error-result "No agent service is available to run a sub-agent."))
     ((>= (harness-subagents--depth parent-id) harness-subagents-max-depth)
      (harness-tool-error-result
       (format "Sub-agents are nested %d deep already; do this work directly instead."
               harness-subagents-max-depth)))
     (t
      (let ((child (harness-subagents--create-session arguments context parent-id)))
        (if (null child)
            (harness-tool-error-result "Could not create a sub-agent session.")
          (let* ((child-id (harness-session-id child))
                 (blocks (vector (list :type "text"
                                       :text (concat
                                              "You are a sub-agent working for another session. "
                                              "Complete the task independently, then finish with a "
                                              "concise report of what you did and found.\n\n"
                                              prompt)))))
            (harness-tool-context-report
             context (format "Sub-agent started (%s)" (substring child-id 0 8)))
            (harness-subagents--inherit parent-id child-id)
            (let ((deferred (harness-deferred-new)))
              (harness-deferred-then
               (harness-service-call "agent" 'prompt :session-id child-id :prompt blocks)
               (lambda (stop-reason)
                 (harness-deferred-then
                  (harness-service-call "session" 'entries :session-id child-id)
                  (lambda (entries)
                    (let ((report (or (harness-subagents--last-text entries)
                                      "(the sub-agent produced no message)")))
                      (harness-deferred-resolve
                       deferred
                       (format "Sub-agent %s finished (%s).\n\n%s"
                               (substring child-id 0 8)
                               (or stop-reason "end_turn")
                               (harness-subagents--truncate report)))))
                  (lambda (error)
                    (harness-deferred-resolve
                     deferred
                     (harness-tool-error-result
                      (format "Sub-agent %s finished but its transcript could not be read: %S"
                              (substring child-id 0 8) error))))))
               (lambda (error)
                 (harness-deferred-resolve
                  deferred
                  (harness-tool-error-result
                   (format "Sub-agent %s failed: %S" (substring child-id 0 8) error)))))
              deferred))))))))

(defun harness-subagents--last-text (entries)
  "Return the last agent message text in ENTRIES."
  (let ((last nil))
    (dolist (entry (append entries nil))
      (when (equal (plist-get entry :sessionUpdate) "agent_message_chunk")
        (let ((content (plist-get entry :content)))
          (setq last (cond
                      ((vectorp content) (plist-get (aref content 0) :text))
                      ((and (listp content) (plist-get content :text))
                       (plist-get content :text))
                      ((stringp content) content)
                      (t last))))))
    last))

(defun harness-subagents-setup ()
  "Set up the sub-agents module."
  (harness-tool-register
   "subagent"
   :description (concat
                 "Run a task in a separate sub-agent session and get its report back. "
                 "The sub-agent is a full session (visible in the session list) with this "
                 "session as its parent; it inherits the model and thinking level. "
                 "Use it for independent, parallelizable or context-hungry work.")
   :schema '(:type "object"
             :properties (:prompt (:type "string"
                                   :description "The task for the sub-agent.")
                          :directory (:type "string"
                                      :description "Working directory (defaults to this session's).")
                          :title (:type "string" :description "Title for the sub-agent session.")
                          :fork (:type "string"
                                 :description "Fork from this entry id instead of starting empty."))
             :required ["prompt"])
   :kind 'other
   :handler #'harness-subagents-tool))

(defun harness-subagents-teardown ()
  "Tear down the sub-agents module."
  (harness-tool-unregister "subagent"))

(harness-module-define 'harness-subagents
  :version harness-version
  :description "Sub-agent sessions as a tool."
  :requires '((harness-core "0.1.0")
              (harness-tools "0.1.0")
              (harness-session "0.1.0")
              (harness-agent "0.1.0"))
  :provides '(harness-subagents)
  :setup #'harness-subagents-setup
  :teardown #'harness-subagents-teardown)

(provide 'harness-subagents)
;;; harness-subagents.el ends here
