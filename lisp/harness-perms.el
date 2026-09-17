;;; harness-perms.el --- Permissions, approvals and auto mode -*- lexical-binding: t; -*-

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

;; Permission decisions are made by a list of rules, and running a tool may
;; need to wait for the user.  That wait is asynchronous: a `harness-approval'
;; is recorded on the session, the session status becomes `awaiting-approval',
;; and the run loop is resumed by whoever answers -- the conversation buffer,
;; the sessions list, or `harness-approve-next'.  No recursive edit, so other
;; sessions stay fully responsive while one waits.
;;
;; Auto mode answers a rule of `auto' by asking a cheap model whether the call
;; is safe, which mirrors the pi-automode extension.  A classifier failure
;; degrades to asking the user, never to allowing.
;;
;; See DESIGN.md section 7.2 and 7.3.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-tools)
(require 'harness-provider)

(defcustom harness-permission-policy
  '((:category read :action allow)
    (:tool "todo" :action allow)
    (:tool "write" :action ask)
    (:tool "edit" :action ask)
    (:tool "bash" :action ask)
    (:default ask))
  "Rules deciding whether a tool call may run.

Rules are tried in order and the first match wins.  A rule is a plist with:

  :tool      a tool name, or a list of tool names
  :category  a tool category (`read', `edit', `execute', `meta')
  :match     a regular expression matched against the call's subject (the
             command for `bash', the path for `write' and `edit', the tool
             name otherwise)
  :action    `allow', `ask', `deny' or `auto'

`:default' sets the action when nothing matches.  `harness-perms-remember'
appends the rules created by answering \"always allow\"."
  :type '(repeat plist)
  :group 'harness-tools)

(defcustom harness-permission-rules-file
  (expand-file-name "agent-harness/permissions.json" user-emacs-directory)
  "Where rules added by \"always allow\" are stored."
  :type '(choice (const :tag "Do not persist" nil) file)
  :group 'harness-tools)

(defcustom harness-auto-mode nil
  "Default auto mode for new sessions.

When non-nil, rules whose action is `auto' ask `harness-auto-mode-model'
instead of the user.  A session can override this with
`harness-toggle-auto-mode'."
  :type 'boolean
  :group 'harness-tools)

(defcustom harness-auto-mode-model nil
  "Model used to classify commands in auto mode.
Nil means use the session's model, which is usually a waste of a good model;
set this to a cheap one."
  :type '(choice (const :tag "Session model" nil) string)
  :group 'harness-tools)

(defcustom harness-auto-mode-prompt
  "You are a security gate for a coding agent working in a user's project.

Decide whether the tool call below may run without asking the user.  Read-only
inspection, builds, tests, formatters, git queries and ordinary development
commands on the project are safe.  Deleting files outside the project,
force-pushing, piping the network into a shell, sending credentials anywhere,
or anything irreversible is not: deny when clearly unsafe, ask when you are
unsure.

Answer with exactly one word: allow, ask, or deny."
  "System prompt for the auto mode classifier."
  :type 'string
  :group 'harness-tools)

(defvar harness-permission-rules nil
  "Rules appended by `harness-perms-remember', newest first.")

(defvar harness-approval-added-hook nil
  "Hook run with (SESSION APPROVAL) when a decision is needed.")

(defvar harness-approval-resolved-hook nil
  "Hook run with (SESSION APPROVAL DECISION) when a decision is given.")


;;; Rule matching

(defun harness-perms-subject (tool-call)
  "Return the string a `:match' rule is tested against for TOOL-CALL."
  (let ((args (harness-tool-args tool-call)))
    (or (harness-tools-arg args :command)
        (harness-tools-arg args :file_path)
        (harness-tools-arg args :path)
        (harness-tools-arg args :pattern)
        (harness-tools-arg args :query)
        (harness-tool-call-name tool-call))))

(defun harness-perms--rule-matches-p (rule tool-call session)
  "Return non-nil when RULE applies to TOOL-CALL in SESSION."
  (let ((tool (harness-plist-or-alist-get :tool rule))
        (category (harness-plist-or-alist-get :category rule))
        (match (harness-plist-or-alist-get :match rule))
        (tool-object (harness-tool-get (harness-tool-call-name tool-call))))
    (and
     (or (null tool)
         (if (listp tool)
             (member (harness-tool-call-name tool-call) tool)
           (equal (harness-tool-call-name tool-call) tool)))
     (or (null category)
         (and tool-object (eq (harness-tool-category tool-object) category)))
     (or (null match)
         (string-match-p match (harness-perms-subject tool-call)))
     (or (null (harness-plist-or-alist-get :session rule))
         (equal (harness-plist-or-alist-get :session rule)
                (harness-session-id session))))))

(defun harness-permission-check (tool-call session)
  "Return the action for TOOL-CALL in SESSION: `allow', `ask', `deny' or `auto'."
  (let ((rules (append harness-permission-rules harness-permission-policy))
        (action nil))
    (while (and rules (null action))
      (let ((rule (car rules)))
        (if (harness-plist-or-alist-get :default rule)
            (setq action (or (harness-plist-or-alist-get :default rule) 'ask))
          (when (harness-perms--rule-matches-p rule tool-call session)
            (setq action (or (harness-plist-or-alist-get :action rule) 'ask)))))
      (setq rules (cdr rules)))
    (or action 'ask)))

(defun harness-perms-remember (tool-call _session &optional rule)
  "Add a rule allowing TOOL-CALL, pinned to its command or path.
RULE, when given, is used verbatim.  The rule is global, but narrow: the
subject is matched exactly, so approving one command does not
approve every command of that tool.  Returns the rule."
  (let* ((tool (harness-tool-get (harness-tool-call-name tool-call)))
         (subject (harness-perms-subject tool-call))
         (new nil))
    ;; NOTE: assigned with `setq' rather than in the `let*' binding list; the
    ;; Emacs 31 byte compiler mis-analyses a complex init form here and reports
    ;; the variable as unused.
    (setq new
          (or rule
              (list :tool (harness-tool-call-name tool-call)
                    :category (and tool (harness-tool-category tool))
                    ;; Commands and paths are pinned so that approving one
                    ;; command does not quietly approve every command.
                    :match (when (and subject
                                      (not (equal subject
                                                  (harness-tool-call-name tool-call))))
                             (concat "\\`" (regexp-quote subject) "\\'"))
                    :action 'allow)))
    (setq harness-permission-rules (cons new harness-permission-rules))
    (harness-permission-rules-save)
    new))

(defun harness-permission-rules-save ()
  "Persist `harness-permission-rules'."
  (when harness-permission-rules-file
    (condition-case err
        (progn
          (make-directory (file-name-directory harness-permission-rules-file) t)
          (let ((write-region-inhibit-fsync t))
            (with-temp-file harness-permission-rules-file
              (insert (harness-json-write
                       (harness-json-array harness-permission-rules) t)))))
      (error (harness--log "could not save permission rules: %s"
                           (error-message-string err))))))

(defun harness-permission-rules-load ()
  "Load persisted permission rules."
  (when (and harness-permission-rules-file
             (file-readable-p harness-permission-rules-file))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents harness-permission-rules-file)
          (let ((data (harness-json-read (buffer-string))))
            (when (listp data)
              (setq harness-permission-rules
                    (mapcar (lambda (rule)
                              (if (listp rule) (append rule nil) rule))
                            data)))))
      (error (harness--log "could not read permission rules: %s"
                           (error-message-string err))))))

(defun harness-permission-rules-reset ()
  "Forget every remembered rule."
  (interactive)
  (setq harness-permission-rules nil)
  (harness-permission-rules-save))


;;; Auto mode

(defun harness-session-auto-mode-p (session)
  "Return non-nil when SESSION classifies commands automatically."
  (let ((value (plist-get (harness-session-meta session) :auto-mode)))
    (if (null value) harness-auto-mode value)))

(defun harness-toggle-auto-mode (&optional session)
  "Toggle auto mode for SESSION."
  (interactive (list (or (harness-session--read-session "Auto mode for")
                         (user-error "No live sessions"))))
  (let* ((meta (harness-session-meta session))
         (current (if (null (plist-get meta :auto-mode))
                      harness-auto-mode
                    (plist-get meta :auto-mode)))
         (new (not current)))
    (setf (harness-session-meta session) (plist-put meta :auto-mode new))
    (harness-session-notify session 'meta)
    (message "Auto mode %s for %s" (if new "enabled" "disabled")
             (harness-session-name session))
    new))

(defun harness-perms--classifier-request (tool-call session)
  "Return the user message sent to the auto mode classifier."
  (format "Working directory: %s\nTool: %s\nArguments: %s\n\nIs this safe to run without asking?"
          (or (harness-session-project-root session) default-directory)
          (harness-tool-call-name tool-call)
          (let ((args (harness-tool-args tool-call)))
            (if args (harness-json-write args) "(none)"))))

(defun harness-perms-classify (tool-call session callback)
  "Ask the classifier model about TOOL-CALL, calling CALLBACK with a decision.
CALLBACK receives one of `allow', `ask' or `deny'.  Any failure reports
`ask', because guessing wrong in that direction is merely annoying and in the
other direction is destructive."
  (let* ((model (or harness-auto-mode-model (harness-session-model session)))
         (session-stub (harness--make-session
                        :id (format "classify-%s" (harness-session-id session))
                        :name "auto mode"
                        :model model
                        :provider (harness-session-provider session)))
         (message (harness--make-message :id "m-1" :role 'user
                                         :content (harness-perms--classifier-request
                                                   tool-call session)
                                         :status 'complete
                                         :timestamp (float-time)))
         (text "")
         (settled nil)
         (finish (lambda (decision)
                   (unless settled
                     (setq settled t)
                     (funcall callback decision)))))
    (harness-session-set-status
     session 'classifying (list :label (format "%s" (harness-tool-call-name tool-call))))
    (harness-provider-chat-async
     session-stub
     (list :on-delta (lambda (kind chunk)
                       (when (eq kind 'text) (setq text (concat text chunk))))
           :on-done (lambda (&rest _)
                      (funcall finish (harness-perms--parse-decision text)))
           :on-error (lambda (symbol message)
                       (harness--log "auto mode classifier failed: %s %s" symbol message)
                       (funcall finish 'ask)))
     (list :messages (list message)
           :system harness-auto-mode-prompt))))

(defun harness-perms--parse-decision (text)
  "Extract a decision from the classifier's TEXT."
  (let ((lower (downcase (or text ""))))
    (cond
     ((string-match-p "\\bdeny\\b" lower) 'deny)
     ((string-match-p "\\ballow\\b" lower) 'allow)
     ((string-match-p "\\bask\\b" lower) 'ask)
     (t 'ask))))


;;; Approvals

(defun harness-approval-pending (session)
  "Return SESSION's pending approvals, oldest first."
  (reverse (harness-session-approvals session)))

(defun harness-approval-for-tool-call (session tool-call)
  "Return the pending approval for TOOL-CALL in SESSION, or nil."
  (cl-find-if (lambda (approval)
                (eq (harness-approval-tool-call approval) tool-call))
              (harness-session-approvals session)))

(defun harness-approval-any-pending-p ()
  "Return non-nil when any session is waiting for the user."
  (cl-some (lambda (session) (harness-session-approvals session))
           (harness-session-all)))

(defun harness-perms--offer-approval (tool-call session callback &optional reason)
  "Record an approval for TOOL-CALL and return it.
CALLBACK receives (ALLOWED REASON).  The run loop is suspended until
`harness-perms-resolve' is called."
  (let ((approval (harness-approval-create
                   :session session
                   :tool-call tool-call
                   :kind 'tool
                   :prompt (format "Allow %s?" (harness-tool-call-summary tool-call))
                   :detail (harness-tool-call-args tool-call)
                   :choices '(allow allow-always deny)
                   :callback (lambda (decision)
                               (funcall callback
                                        (memq decision '(allow allow-always))
                                        (and (eq decision 'deny)
                                             (or reason "denied by the user"))
                                        (eq decision 'allow-always))))))
    (setf (harness-session-approvals session)
          (cons approval (harness-session-approvals session)))
    (harness-session-set-status
     session 'awaiting-approval
     (list :label (harness-tool-call-summary tool-call)
           :approval (harness-approval-id approval)))
    (run-hook-with-args 'harness-approval-added-hook session approval)
    (harness-session-notify session 'approvals)
    approval))

(defun harness-perms-resolve (approval decision)
  "Resolve APPROVAL with DECISION, one of `allow', `allow-always' or `deny'."
  (let* ((session (harness-approval-session approval))
         (callback (harness-approval-callback approval))
         (tool-call (harness-approval-tool-call approval)))
    (setf (harness-session-approvals session)
          (delq approval (harness-session-approvals session)))
    (when (and (eq decision 'allow-always) session tool-call)
      (harness-perms-remember tool-call session))
    (run-hook-with-args 'harness-approval-resolved-hook session approval decision)
    (harness-session-notify session 'approvals)
    (when callback (funcall callback decision))
    approval))

(defun harness-approvals-pending ()
  "Return every pending approval, oldest first, across all sessions."
  (let (approvals)
    (dolist (session (harness-session-all))
      (setq approvals (append approvals (harness-approval-pending session))))
    approvals))

(defun harness-approve-next ()
  "Answer the oldest pending approval anywhere, prompting in the minibuffer.
This is the quick path for a session the user is not looking at; the
minibuffer prompt is deliberate, and the event loop keeps running."
  (interactive)
  (let ((approval (car (harness-approvals-pending))))
    (unless approval (user-error "No pending approvals"))
    (pcase (read-char-choice
            (format "%s  [a]llow [A]lways [d]eny [v]iew: "
                    (harness-approval-prompt approval))
            '(?a ?A ?d ?v))
      (?a (harness-perms-resolve approval 'allow))
      (?A (harness-perms-resolve approval 'allow-always))
      (?d (harness-perms-resolve approval 'deny))
      (?v (message "%s" (let ((args (harness-approval-detail approval)))
                           (if args (harness-json-write args t) "no arguments")))
          (harness-approve-next)))))

(defun harness-perms-authorize (tool-call session callback)
  "Decide whether TOOL-CALL may run in SESSION.

CALLBACK is called with (ALLOWED REASON REMEMBER-P).  Returning without
calling CALLBACK would be a bug: exactly one of the branches below either
calls it or schedules it."
  (let* ((tool (harness-tool-get (harness-tool-call-name tool-call)))
         (action (cond
                  ;; A tool can opt out of asking entirely.
                  ((and tool (not (eq (harness-tool-approval tool) 'ask)))
                   (harness-tool-approval tool))
                  ((and (harness-session-auto-mode-p session)
                        (eq (harness-permission-check tool-call session) 'ask))
                   'auto)
                  (t (harness-permission-check tool-call session)))))
    (pcase action
      ('allow (funcall callback t nil nil))
      ('deny (funcall callback nil "denied by permission rules" nil))
      ('auto
       (harness-perms-classify
        tool-call session
        (lambda (decision)
          (pcase decision
            ('allow (harness-session-set-status session 'working)
                    (funcall callback t "allowed by auto mode" nil))
            ('deny (funcall callback nil "denied by auto mode" nil))
            (_ (harness-perms--offer-approval
                tool-call session callback "blocked by auto mode"))))))
      (_
       (harness-perms--offer-approval tool-call session callback)))))

(defun harness-perms-abort-approvals (session)
  "Deny every pending approval of SESSION, for example when a run is aborted."
  (dolist (approval (harness-approval-pending session))
    (harness-perms-resolve approval 'deny)))

(provide 'harness-perms)
;;; harness-perms.el ends here
