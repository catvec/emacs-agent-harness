;;; harness-perms.el --- Permission decisions and auto mode -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Every tool call passes through `harness-permission-check', which runs
;; `harness-permission-functions' in order.  A function may return:
;;
;;   nil      no opinion, try the next function
;;   'allow   allow this call
;;   'ask     ask the user
;;   'deny    refuse, with a constructive reason
;;   a plist  (:decision allow|ask|deny :reason "..." ...)
;;
;; The first opinion wins.  When every function declines to answer the call
;; is allowed (the chain is opt-in gating; the sandbox, not permissions, is
;; the kernel-enforced boundary).
;;
;; `ask' is resolved by `harness-permission-ask-function', which the ACP
;; layer sets to `session/request_permission'.  Without an asker a call is
;; refused with an explanation the model can act on.
;;
;; Auto mode is one of the chain functions: when a session's
;; `:permission-mode' is `auto', a cheap model decides.  It is deliberately
;; not a security boundary -- the sandbox is.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'harness-core)

(defgroup harness-perms nil
  "Tool call permissions."
  :group 'harness)

(defcustom harness-permission-functions nil
  "Functions consulted for each tool call, in order.
Jail and auto-mode rules install themselves here; users can add, remove
or reorder rules freely."
  :type '(repeat function))

(defcustom harness-perms-auto-model "openai/gpt-4o-mini"
  "Cheap model used by auto mode."
  :type 'string)

(defcustom harness-perms-auto-timeout 30
  "Timeout in seconds for an auto-mode decision."
  :type 'number)

(defvar harness-permission-ask-function nil
  "Function asked to resolve `ask' decisions.
Called with a request plist and returns a deferred resolving to a plist
`:outcome \"allow\"|\"deny\", `:always' boolean, `:reason' string'.")

;;; Requests

(cl-defstruct (harness-permission-request (:constructor harness-permission-request-create))
  session-id
  cwd
  additional-directories
  permission-mode
  tool-name
  tool
  arguments
  context)

(defun harness-permission-request-plist (request)
  "Return REQUEST as a plist for chain functions."
  (list :session-id (harness-permission-request-session-id request)
        :cwd (harness-permission-request-cwd request)
        :additional-directories (harness-permission-request-additional-directories request)
        :permission-mode (harness-permission-request-permission-mode request)
        :tool-name (harness-permission-request-tool-name request)
        :tool (harness-permission-request-tool request)
        :arguments (harness-permission-request-arguments request)
        :context (harness-permission-request-context request)))

(defun harness-permission-options ()
  "Return the standard permission options in ACP shape."
  (vector (list :optionId "allow-once" :name "Allow once" :kind "allow_once")
          (list :optionId "allow-always" :name "Always allow"
                :kind "allow_always" :description "Allow this tool for the rest of the session")
          (list :optionId "reject-once" :name "Reject" :kind "reject_once")
          (list :optionId "reject-always" :name "Always reject"
                :kind "reject_always")))

;;; Decisions

(defun harness-permission--normalize (rule-result)
  "Normalize RULE-RESULT into a decision plist or nil."
  (cond
   ((null rule-result) nil)
   ((eq rule-result 'allow) (list :decision 'allow))
   ((eq rule-result 'deny) (list :decision 'deny))
   ((eq rule-result 'ask) (list :decision 'ask))
   ((and (listp rule-result) (plist-get rule-result :decision))
    (let ((decision (plist-get rule-result :decision)))
      (setq decision (if (symbolp decision) decision (intern decision)))
      (plist-put rule-result :decision decision)))
   (t nil)))

(defun harness-permission-check (tool-name arguments &optional context &rest options)
  "Decide whether TOOL-NAME may run with ARGUMENTS.
CONTEXT is a `harness-tool-context'.  OPTIONS may carry :cwd,
:additional-directories and :permission-mode overrides.

Returns a deferred resolving to a decision plist:
`(:decision allow|deny :reason STRING :always BOOL)'."
  (declare (indent 2))
  (let* ((tool (harness-tool-get tool-name))
         (request (harness-permission-request-create
                   :session-id (and context (harness-tool-context-session-id context))
                   :cwd (or (plist-get options :cwd)
                            (and context (harness-tool-context-cwd context))
                            default-directory)
                   :additional-directories (plist-get options :additional-directories)
                   :permission-mode (or (plist-get options :permission-mode) 'ask)
                   :tool-name tool-name
                   :tool tool
                   :arguments arguments
                   :context context)))
    (harness-permission--run-chain request)))

(defun harness-permission--run-chain (request)
  "Run REQUEST through the chain.  Returns a deferred decision.
Rules may return a decision directly or a deferred resolving to one."
  (let ((plist (harness-permission-request-plist request))
        (result (harness-deferred-new)))
    (cl-labels
        ((handle (value remaining)
           (let ((decision (harness-permission--normalize value)))
             (cond
              ((null decision) (step remaining))
              ((eq (plist-get decision :decision) 'ask)
               (harness-deferred-adopt result (harness-permission--ask request decision)))
              (t (harness-deferred-resolve result decision)))))
         (step (functions)
           (if (null functions)
               (harness-deferred-resolve result (list :decision 'allow))
             (let ((outcome
                    (condition-case err
                        (funcall (car functions) plist)
                      (error
                       (harness-log "permission rule %S failed: %S" (car functions) err)
                       (list :decision 'deny
                             :reason (format "Permission rule failed: %s"
                                             (error-message-string err)))))))
               (if (harness-deferred-p outcome)
                   (harness-deferred-then
                    outcome
                    (lambda (value) (handle value (cdr functions)))
                    (lambda (error)
                      (handle (list :decision 'deny
                                    :reason (format "Permission rule failed: %S" error))
                              (cdr functions))))
                 (handle outcome (cdr functions)))))))
      (step harness-permission-functions))
    result))

(defun harness-perms--set-session-status (session-id status)
  "Tell the session service about a status change, when it is loaded."
  (when (and session-id (harness-service-available-p "session" 'set-status))
    (ignore-errors
      (harness-service-call "session" 'set-status
                            :session-id session-id :status status))))

(defun harness-permission--ask (request decision)
  "Resolve an `ask' DECISION for REQUEST."
  (let* ((session-id (harness-permission-request-session-id request))
         (ask-request (harness-plist-omit-nil
                       (list :session-id session-id
                             :tool-name (harness-permission-request-tool-name request)
                             :arguments (harness-permission-request-arguments request)
                             :cwd (harness-permission-request-cwd request)
                             :reason (plist-get decision :reason)
                             :paths (plist-get decision :paths)
                             :options (or (plist-get decision :options)
                                          (harness-permission-options))))))
    (if harness-permission-ask-function
        (let ((deferred (harness-deferred-new)))
          ;; The session is blocked while the user decides.
          (harness-perms--set-session-status session-id "blocked")
          (harness-deferred-then
           (funcall harness-permission-ask-function ask-request)
           (lambda (outcome)
             (harness-perms--set-session-status session-id "running")
             (harness-deferred-resolve
              deferred
              (if (equal (plist-get outcome :outcome) "allow")
                  (list :decision 'allow
                        :always (plist-get outcome :always)
                        :reason (plist-get outcome :reason))
                (list :decision 'deny
                      :always (plist-get outcome :always)
                      :reason (or (plist-get outcome :reason)
                                  "The user rejected this tool call.")))))
           (lambda (error)
             (harness-perms--set-session-status session-id "running")
             (harness-deferred-resolve
              deferred
              (list :decision 'deny
                    :reason (format "Permission request failed: %S" error)))))
          deferred)
      (let ((deferred (harness-deferred-new)))
        (harness-deferred-resolve
         deferred
         (list :decision 'deny
               :reason (concat "This call needs permission and there is no one to ask. "
                               (or (plist-get decision :reason) "")
                               " Find a different approach that stays within the session "
                               "directory or ask the user to grant access.")))
        deferred))))

;;; Auto mode

(defun harness-perms-auto-check (request)
  "Auto-mode rule: let a cheap model decide.  Returns a decision or nil."
  (let ((tool (plist-get request :tool)))
    (when (and (eq (plist-get request :permission-mode) 'auto)
               tool
               (not (harness-tool-read-only tool))
               (harness-service-available-p "provider" 'complete)
               (not (string-empty-p harness-perms-auto-model)))
      (harness-perms--auto-complete request))))

(defun harness-perms--auto-prompt (request)
  "Build the auto-mode prompt for REQUEST."
  (let ((tool (plist-get request :tool)))
    (format (concat "A coding agent wants to call a tool. Decide whether it is safe.\n\n"
                    "Tool: %s\nDescription: %s\nWorking directory: %s\nArguments: %s\n\n"
                    "Answer with exactly one line: ALLOW or DENY, then a dash and one sentence "
                    "of reasoning. Deny only clearly destructive or out-of-scope actions.")
            (plist-get request :tool-name)
            (or (harness-tool-description tool) "(none)")
            (plist-get request :cwd)
            (let ((json (harness-json-serialize (or (plist-get request :arguments)
                                            (make-hash-table)))))
              (if (> (length json) 4000) (substring json 0 4000) json)))))

(defun harness-perms--auto-complete (request)
  "Ask the cheap model about REQUEST.  Returns a deferred decision."
  (let ((deferred (harness-deferred-new)))
    (harness-deferred-then
     (harness-service-call
      "provider" 'complete
      (list :model harness-perms-auto-model
            :system "You are a permission gate for a coding agent. Reply ALLOW or DENY, then a dash and a short reason."
            :messages (vector (list :role "user"
                                    :content (vector (list :type "text"
                                                           :text (harness-perms--auto-prompt request)))))
            :max-output-tokens 120))
     (lambda (result)
       (let* ((text (or (plist-get result :text) ""))
              (allow (string-match-p "\\`[^A-Za-z]*ALLOW" text))
              (reason (if (string-match "-\\s-*\\(.*\\)\\'" text)
                          (string-trim (match-string 1 text))
                        (string-trim text))))
         (harness-log "auto mode: %s (%s)" (if allow "allow" "deny") reason)
         (harness-deferred-resolve
          deferred (list :decision (if allow 'allow 'deny)
                         :reason (format "Auto mode: %s" reason)))))
     (lambda (_error)
       ;; A broken cheap model must not silently allow; hand it to the asker.
       (harness-deferred-resolve
        deferred (list :decision 'ask
                       :reason "Auto mode could not reach the decision model."))))
    deferred))

;;; Service

(defun harness-permission-allowed-p (decision)
  "Return non-nil when DECISION allows the call."
  (eq (plist-get decision :decision) 'allow))

(defun harness-perms-service-check (&rest args)
  "Service: check a tool call."
  (harness-permission-check (plist-get args :tool-name)
                            (plist-get args :arguments)
                            (plist-get args :context)
                            :cwd (plist-get args :cwd)
                            :additional-directories (plist-get args :additional-directories)
                            :permission-mode (plist-get args :permission-mode)))

(defun harness-perms-service-rules (&rest _args)
  "Service: describe the permission chain."
  (vconcat (mapcar #'symbol-name harness-permission-functions)))

(defun harness-perms-setup ()
  "Set up the permissions module."
  (add-to-list 'harness-permission-functions #'harness-perms-auto-check t)
  (harness-service-register
   "permission"
   :module 'harness-perms
   :doc "Permission chain and auto mode."
   :methods '((check . harness-perms-service-check)
              (rules . harness-perms-service-rules))))

(defun harness-perms-teardown ()
  "Tear down the permissions module."
  (setq harness-permission-functions
        (remove #'harness-perms-auto-check harness-permission-functions)))

(harness-module-define 'harness-perms
  :version harness-version
  :description "Permission chain, asking, and the cheap-model auto mode."
  :requires '((harness-core "0.1.0")
              (harness-tools "0.1.0"))
  :provides '(harness-perms)
  :setup #'harness-perms-setup
  :teardown #'harness-perms-teardown)

(provide 'harness-perms)
;;; harness-perms.el ends here
