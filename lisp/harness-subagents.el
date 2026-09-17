;;; harness-subagents.el --- Sub-agents and personalities -*- lexical-binding: t; -*-

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

;; A subagent is an ordinary session whose `parent' is set.  It inherits the
;; parent's provider, and its model unless the call or the personality
;; overrides it -- so a reviewer can run on a stronger model than the worker
;; that spawned it, or a planner on a cheaper one.
;;
;; Because a subagent is a session, viewing it needs no separate viewer: it is
;; the same conversation buffer, opened from the same session list or from
;; `harness-subagents-list'.  Nothing here is special-cased in the UI.
;;
;; The `spawn_subagent' tool is asynchronous, like every tool that waits: the
;; parent's tool call stays running, the child runs in its own session, and the
;; parent resumes when the child goes idle.  Multiple subagents can run at
;; once, and the parent stays responsive while they do.
;;
;; See DESIGN.md section 10.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-agent)
(require 'harness-provider)
(require 'harness-ui-conversation)
(require 'harness-faces)


(defcustom harness-personalities
  '((general
     :description "General purpose worker"
     :system-prompt "You are a focused worker. Do the task you are given, concisely, and report what you did.")
    (planner
     :description "Plans work before doing it"
     :system-prompt "You are a planner. Produce a short, concrete plan and the open questions. Do not write code; do not edit files."
     :tools ("read" "glob" "grep"))
    (reviewer
     :description "Reviews code critically"
     :system-prompt "You are a code reviewer. Look for bugs, unclear code and missing tests. Be specific and cite file and line. Do not edit files."
     :tools ("read" "glob" "grep"))
    (researcher
     :description "Finds things out"
     :system-prompt "You are a researcher. Search the codebase, read what you need, and report findings with file references. Do not edit files."
     :tools ("read" "glob" "grep" "bash"))
    (implementer
     :description "Writes the code"
     :system-prompt "You are an implementer. Make the smallest correct change, then run the tests that cover it."))
  "Named subagent personalities.

Each entry maps a name to a plist with `:description', `:system-prompt',
`:model' (to override the parent's) and `:tools' (to restrict which tools the
subagent may use)."
  :type '(alist :key-type symbol :value-type plist)
  :group 'harness)

(defcustom harness-subagents-default-personality 'general
  "Personality used when a subagent call does not name one."
  :type 'symbol
  :group 'harness)

(defcustom harness-subagents-display-action
  '(display-buffer-same-window)
  "`display-buffer' action used when opening a subagent."
  :type '(repeat sexp)
  :group 'harness-ui)

(defvar harness-subagents--waiters (make-hash-table :test #'equal)
  "Callbacks waiting for a child session to finish, keyed by session id.")

(defvar harness-subagents--children (make-hash-table :test #'equal)
  "Child sessions spawned by the tool, keyed by child session id.")


;;; Personalities

(defun harness-personality (name)
  "Return the personality plist named NAME, or nil."
  (harness-plist-or-alist-get (or name harness-subagents-default-personality)
                              harness-personalities))

(defun harness-personality-prompt (session)
  "Return SESSION's system prompt addition, if it is a subagent.
Registered in `harness-system-prompt-functions', so a personality shapes the
system prompt of every request the child makes."
  (when-let* ((personality (plist-get (harness-session-meta session) :personality)))
    (when-let* ((spec (harness-personality personality)))
      (let ((prompt (harness-plist-or-alist-get :system-prompt spec)))
        (when prompt
          (format "%s\n\nYou are a subagent working for another agent. Answer with the result it needs, not with a summary of what you did." prompt))))))

(defun harness-subagents-tool-enabled (tool session)
  "Return non-nil when TOOL may be used by SESSION.

A subagent personality can restrict the tool list, which is how a reviewer
that cannot edit files is enforced rather than merely requested.  SESSION may
be nil (asking for the general tool list), in which case everything is
allowed."
  (let ((allowed (and session (plist-get (harness-session-meta session) :tools))))
    (or (null allowed)
        (member (harness-tool-name tool) allowed))))

(add-hook 'harness-system-prompt-functions #'harness-personality-prompt)
(add-hook 'harness-tool-enabled-functions #'harness-subagents-tool-enabled)

(defun harness-subagents-of (session)
  "Return SESSION's direct children, newest first."
  (sort (delq nil (mapcar #'harness-session-get (harness-session-children session)))
        (lambda (a b) (> (or (harness-session-created a) 0)
                         (or (harness-session-created b) 0)))))

(defun harness-subagents-running ()
  "Return every live subagent that is not idle."
  (seq-filter (lambda (session)
                (and (harness-session-parent session)
                     (harness-session-active-p session)))
              (harness-session-list)))

(defun harness-subagents-list (&optional parent)
  "Open one of PARENT's subagents, or any running subagent."
  (interactive)
  (let* ((candidates (or (and parent (harness-subagents-of parent))
                         (append (harness-subagents-running)
                                 (seq-filter (lambda (session)
                                               (harness-session-parent session))
                                             (harness-session-list)))))
         (session (if (= (length candidates) 1)
                      (car candidates)
                    (harness-session--read-session "Subagent"))))
    (unless session (user-error "No subagents"))
    (harness-conversation-open session)))

(defun harness-view-subagents (&optional parent)
  "Show the running subagents of PARENT, or every running subagent."
  (interactive)
  (let ((running (if parent (harness-subagents-of parent) (harness-subagents-running))))
    (if (null running)
        (message "No subagents running")
      (harness-subagents-list parent))))

(defun harness-subagents-model-for (session model personality)
  "Return the model a child of SESSION should use.

An explicit MODEL wins, then the personality's, then the parent's.  The point
is that a session can delegate to a different model without the caller having
to know anything about provider configuration."
  (or model
      (when personality
        (harness-plist-or-alist-get :model (harness-personality personality)))
      (harness-session-model session)))

(defun harness-subagents-system-prompt (session)
  "Return the system prompt a child of SESSION should start with."
  (let ((parent-prompt (plist-get (harness-session-meta session) :system-prompt)))
    parent-prompt))

(defun harness-subagents-summary (session)
  "Return the text a parent should receive from a finished child SESSION.
The last assistant message is the child's answer; anything else is noise."
  (let ((message (car (last (cl-remove-if-not
                             (lambda (message)
                               (and (eq (harness-message-role message) 'assistant)
                                    (not (string-empty-p
                                          (string-trim (harness-message-content message))))))
                             (harness-session-messages session))))))
    (if message
        (harness-message-content message)
      (format "The subagent finished without a reply (status %s)."
              (harness-session-status session)))))


;;; The tool

(harness-define-tool "spawn_subagent"
  :description "Run a task in a separate agent session and get its result. Useful for parallel or specialised work such as reviewing or research."
  :parameters '(:type "object"
                :properties
                (:prompt (:type "string" :description "What the subagent should do")
                         :personality (:type "string"
                                      :description "general, planner, reviewer, researcher or implementer")
                         :model (:type "string" :description "Override the model for this subagent")
                         :background (:type "boolean"
                                      :description "Return immediately with the session id instead of waiting"))
                :required ("prompt"))
  :category 'meta
  :approval 'allow
  :async
  (lambda (args context done)
    (let* ((parent (harness-tool-context-session context))
           (prompt (or (harness-tools-arg args :prompt) ""))
           (personality (let ((name (harness-tools-arg args :personality)))
                          (and name (intern (format "%s" name)))))
           (override (harness-tools-arg args :model))
           (background (harness-tools-arg args :background)))
      (cond
       ((string-empty-p (string-trim prompt))
        (funcall done (harness-tool-result-create
                       :content "spawn_subagent needs a prompt"
                       :error "no prompt")))
       ((and personality (null (harness-personality personality)))
        (funcall done (harness-tool-result-create
                       :content (format "Unknown personality %s; known: %s"
                                        personality
                                        (string-join
                                         (mapcar (lambda (entry)
                                                   (symbol-name (car entry)))
                                                 harness-personalities)
                                         ", "))
                       :error "unknown personality")))
       (t
        (let* ((spec (harness-personality (or personality
                                               harness-subagents-default-personality)))
               (model (harness-subagents-model-for parent override personality))
               (child (harness-session-create
                       (list :name (harness-subagents--child-name prompt personality)
                             :model model
                             :provider (harness-session-provider parent)
                             :parent (harness-session-id parent)
                             :directory (harness-session-project-root parent)))))
          (setf (harness-session-provider child)
                (or (harness-model-provider-for parent model)
                    (harness-session-provider parent)))
          (setf (harness-session-meta child)
                (list :personality (or personality harness-subagents-default-personality)
                      :tools (harness-plist-or-alist-get :tools spec)
                      :spawned-by (harness-session-id parent)
                      :task prompt))
          (puthash (harness-session-id child) child harness-subagents--children)
          (if background
              (progn
                (harness-agent-send child prompt)
                (funcall done (harness-tool-result-create
                               :content (format "Started subagent %s (%s) in the background."
                                                (harness-session-id child)
                                                (harness-session-name child))
                               :detail (list :kind 'subagent
                                             :session-id (harness-session-id child)
                                             :background t))))
            (puthash (harness-session-id child)
                     (lambda (summary)
                       (funcall done (harness-tool-result-create
                                      :content summary
                                      :detail (list :kind 'subagent
                                                    :session-id (harness-session-id child)
                                                    :task prompt))))
                     harness-subagents--waiters)
            (harness-session-set-status
             parent 'working
             (list :label (format "subagent: %s" (harness-session-name child))))
            (harness-agent-send child prompt))))))))

(defun harness-subagents--child-name (prompt personality)
  "Return a short name for a child session working on PROMPT."
  (format "%s: %s"
          (or personality harness-subagents-default-personality)
          (truncate-string-to-width
           (replace-regexp-in-string "\n" " " (string-trim prompt)) 40 nil nil "…")))

(defun harness-subagents--child-finished (child)
  "Report CHILD's result to whoever is waiting for it."
  (when-let* ((waiter (gethash (harness-session-id child) harness-subagents--waiters)))
    (remhash (harness-session-id child) harness-subagents--waiters)
    (funcall waiter (harness-subagents-summary child))))

(add-hook 'harness-run-finished-hook #'harness-subagents--child-finished)

(defun harness-subagents--abort-children (session)
  "Abort SESSION's running children."
  (dolist (child (harness-subagents-of session))
    (when (harness-session-active-p child)
      (harness-agent-abort child))))

(add-hook 'harness-run-aborted-hook #'harness-subagents--abort-children)

(defun harness-subagents-abort-all ()
  "Abort every running subagent."
  (interactive)
  (dolist (child (harness-subagents-running))
    (harness-agent-abort child)))

(defun harness-subagents--annotate (session)
  "Return a completion annotation for SESSION."
  (format "  %s  %s"
          (harness-session-status-string session)
          (or (plist-get (harness-session-meta session) :task) "")))

(provide 'harness-subagents)
;;; harness-subagents.el ends here
