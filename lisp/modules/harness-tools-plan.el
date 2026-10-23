;;; harness-tools-plan.el --- The plan tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; `plan' records a plan on the session: the approach, the steps, how
;; the result is verified and how the work is split.  The session shows
;; it to the user.  The Planning section the tools-agent module adds to
;; the system prompt says when to make one.

;;; Code:

(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defun harness-tools-plan--record (input ctx)
  "Handler of the plan tool: record INPUT's plan on the session in CTX."
  (let* ((sid (plist-get ctx :session-id))
         ;; The links in the plan are written out in full, in the terms of
         ;; this session before this call (`harness-tools-written').
         (written (harness-tools-written (or (plist-get input :plan) "") ctx))
         (plan (car written))
         (title (plist-get input :title)))
    (harness-call 'session/set-plan sid plan)
    (harness-call 'session/append sid (list :kind 'plan :content plan :title title))
    (harness-call 'session/hint sid "Plan updated")
    (harness-tool-ok (harness-tools-with-note
                      "Plan recorded. Proceed when the user agrees or continue if they asked you to just do it."
                      (cdr written)))))

(harness-define-tool "plan"
  :label "Plan"
  :description "Record a plan for a complex task before starting it: approach, steps, verification, and how the work is split (forks, sub-agents, worktrees, merges). The plan is shown to the user."
  :schema '(:type "object"
            :properties (:plan (:type "string" :description "The plan in markdown.")
                         :title (:type "string" :description "Optional short title."))
            :required ("plan"))
  :kind 'meta
  :subject (lambda (input) (let ((title (plist-get input :title)))
                             (if (harness-string-blank-p title) (harness-first-line (plist-get input :plan) 60) title)))
  :handler #'harness-tools-plan--record)

(harness-define-module 'tools-plan
  :doc "The Plan tool: record a plan for a complex task, shown to the user."
  :requires '(tools session))

(provide 'harness-tools-plan)
;;; harness-tools-plan.el ends here
