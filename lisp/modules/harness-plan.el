;;; harness-plan.el --- Plan mode tool -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The `plan' tool lets an agent lay out a complete implementation plan as
;; a first-class transcript entry.  It is read-only, so it stays available
;; in plan mode, where the agent may investigate but not modify anything.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)

(defcustom harness-plan-max-chars 20000
  "Maximum size of a recorded plan (context bomb protection)."
  :type 'natnum)

(defun harness-plan-tool (arguments context)
  "Tool handler: record a plan for the session in CONTEXT."
  (let ((plan (plist-get arguments :plan))
        (title (plist-get arguments :title))
        (session-id (harness-tool-context-session-id context)))
    (cond
     ((or (null plan) (string-empty-p (string-trim plan)))
      (harness-tool-error-result "A plan needs at least a sentence."))
     ((null session-id)
      (harness-tool-error-result "A plan needs a session to live in."))
     (t
      (let* ((text (string-trim plan))
             (text (if (> (length text) harness-plan-max-chars)
                       (concat (substring text 0 harness-plan-max-chars)
                               "\n\n[plan truncated]")
                     text))
             (headline (or (and title (not (string-empty-p title)) (string-trim title))
                           "Plan")))
        (harness-service-call "session" 'append
                              :session-id session-id
                              :entry (list :sessionUpdate "plan"
                                           :title headline
                                           :content (list :type "text" :text text)))
        (harness-service-call "session" 'state-set
                              :session-id session-id
                              :key 'plan
                              :value (list :title headline :text text))
        (harness-service-call "session" 'system-hint
                              :session-id session-id
                              :text (format "%s recorded; waiting for approval." headline))
        (format (concat "Recorded the plan in the transcript. Stop here and wait for the "
                        "user to approve or adjust it before making any changes.")))))))

(defun harness-plan-setup ()
  "Set up the plan module."
  (harness-tool-register
   "plan"
   :description (concat
                 "Record a complete implementation plan in the transcript and stop. "
                 "Use it in plan mode to lay out the task: the goal, the approach, the "
                 "files and tools involved, how to verify the result, and how to split "
                 "work across forks or sub-agents when that helps. Markdown is fine.")
   :schema '(:type "object"
             :properties (:plan (:type "string"
                                 :description "The full plan, in markdown.")
                          :title (:type "string"
                                  :description "Short headline for the plan."))
             :required ["plan"])
   :kind 'think
   :read-only t
   :handler #'harness-plan-tool))

(defun harness-plan-teardown ()
  "Tear down the plan module."
  (harness-tool-unregister "plan"))

(harness-module-define 'harness-plan
  :version harness-version
  :description "The plan tool for plan mode."
  :requires '((harness-core "0.1.0")
              (harness-session "0.1.0")
              (harness-tools "0.1.0"))
  :provides '(harness-plan)
  :setup #'harness-plan-setup
  :teardown #'harness-plan-teardown)

(provide 'harness-plan)
;;; harness-plan.el ends here
