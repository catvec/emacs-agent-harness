;;; harness-agent.el --- The asynchronous run loop -*- lexical-binding: t; -*-

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

;; One run per session, driven entirely by callbacks:
;;
;;   send -> request -> stream -> tool calls -> tools -> request -> ...
;;
;; Nothing here waits.  A request returns immediately; deltas arrive through
;; the provider's callbacks; a tool that needs the user suspends the run by
;; recording an approval and returns, and the approval's callback resumes it.
;; That is what lets several sessions work (and block) at once without one
;; frozen Emacs.
;;
;; The transcript is the state: the assistant message being streamed is a real
;; message in the session, so the UI can render it before it is finished, and
;; a crash loses at most that one message.
;;
;; See DESIGN.md section 8.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-session)
(require 'harness-provider)
(require 'harness-tools)
(require 'harness-perms)
(require 'harness-queue)

(declare-function harness-context-build-messages "harness-context" (session))
(declare-function harness-context-needs-compaction-p "harness-context" (session))
(declare-function harness-context-compact "harness-context" (session &optional callback))
(declare-function harness-context-summary-addition "harness-context" (session))

(defcustom harness-agent-max-iterations 100
  "Maximum number of request/tool cycles in one run.
Reaching it stops the run with a note rather than looping forever."
  :type 'integer
  :group 'harness)

(defcustom harness-auto-name-sessions nil
  "Whether to ask a model for a short session title after the first reply.
This costs one extra request per session."
  :type 'boolean
  :group 'harness-sessions)

(defvar harness-user-message-functions nil
  "Functions transforming a user message before it is stored.

Each is called with (SESSION TEXT) and returns the text to use, or nil to
leave the text alone; they run in order, each seeing the previous result.
`run-hook-with-args' cannot be used here because it discards return values,
and threading the text is the whole point.

Attachments are expanded this way, so every caller of `harness-agent-send'
gets them -- the UI, a plugin, a queued message, a test.")

(defvar harness-run-started-hook nil
  "Hook run with the session when a run begins.")

(defvar harness-run-finished-hook nil
  "Hook run with the session when a run reaches idle.")

(defvar harness-before-request-hook nil
  "Hook run with the session just before each provider request.
Functions may mutate the session (for example to compact the transcript).")

(defvar harness-run-aborted-hook nil
  "Hook run with the session after its run is aborted.
Subagents use this to stop their children when the parent is abandoned.")

(defvar harness-request-failed-hook nil
  "Hook run with (SESSION MESSAGE) when a request fails.")


;;; Run state

(defun harness-agent-run-state (session)
  "Return SESSION's run state, or nil when idle."
  (harness-session-run session))

(defun harness-agent--new-run (session)
  "Install and return a fresh run state for SESSION."
  (let ((run (list :request nil :message nil :iteration 0
                   :calls nil :call-index 0 :aborted nil)))
    (setf (harness-session-run session) run)
    run))

(defun harness-agent-abort (&optional session)
  "Abort SESSION's run, if any."
  (interactive (list (or (harness-session--read-session "Abort")
                         (user-error "No live sessions"))))
  (let ((run (harness-agent-run-state session)))
    (when run
      (plist-put run :aborted t)
      (when-let* ((handle (plist-get run :request)))
        (harness-provider-cancel-handle handle))
      (when-let* ((message (plist-get run :message)))
        (when (eq (harness-message-status message) 'streaming)
          (setf (harness-message-status message) 'aborted)
          (harness-message-finalize message)
          (harness-session-persist-message session message)))
      (dolist (call (plist-get run :calls))
        (harness-tool-call-cancel call "aborted by the user"))
      (harness-perms-abort-approvals session)
      (run-hook-with-args 'harness-run-aborted-hook session)
      (harness-session-set-status session 'idle)
      (harness-agent--finish-run session)))
  session)

(defun harness-agent-abort-all ()
  "Abort every running session."
  (interactive)
  (dolist (session (harness-session-list #'harness-session-active-p))
    (harness-agent-abort session)))


;;; Sending

(defun harness-agent-send (session text)
  "Send TEXT to SESSION, starting a run or queueing when it is busy.
Returns the message or the queued message."
  (interactive
   (list (or (harness-session--read-session "Send to")
             (user-error "No live sessions"))
         (read-string "Message: ")))
  (let ((text (harness-agent--transform-user-text session text)))
    (if (harness-session-active-p session)
        (progn
          (harness-queue-add session text)
          (message "Queued for %s" (harness-session-name session))
          nil)
      (let ((message (harness-message-create session 'user text)))
        (harness-message-finalize message)
        (harness-session-add-message session message)
        (harness-agent--start-run session)
        message))))

(defun harness-agent--transform-user-text (session text)
  "Run SESSION's user message functions over TEXT, in order."
  (dolist (function harness-user-message-functions text)
    (let ((transformed (funcall function session text)))
      (when (stringp transformed)
        (setq text transformed)))))

(defun harness-agent-start (session)
  "Start a run on SESSION without adding a message.
Used to continue after a tool result is added by something else."
  (unless (harness-session-active-p session)
    (harness-agent--start-run session)))

(defun harness-agent--start-run (session)
  "Begin a run on SESSION."
  (harness-agent--new-run session)
  (harness-session-set-status session 'working)
  (run-hook-with-args 'harness-run-started-hook session)
  (harness-agent--request session))

(defun harness-agent--finish-run (session)
  "Mark SESSION idle and start the next queued message, if any."
  (harness-session-set-status session 'idle)
  (setf (harness-session-run session) nil)
  (harness-session-save-state session)
  (run-hook-with-args 'harness-run-finished-hook session)
  (when (harness-session-queue session)
    (let ((queued (harness-queue-pop session)))
      (harness-agent-send session (harness-queued-message-text queued)))))

(defun harness-agent--continue (session)
  "Move to the next iteration, or finish the run."
  (let* ((run (harness-agent-run-state session))
         (iteration (1+ (or (plist-get run :iteration) 0))))
    (if (plist-get run :aborted)
        (harness-agent--finish-run session)
      (if (>= iteration harness-agent-max-iterations)
          (progn
            (let ((message (harness-message-create
                            session 'system
                            (format "Stopped after %d iterations."
                                    harness-agent-max-iterations))))
              (harness-message-finalize message)
              (harness-session-add-message session message))
            (harness-agent--finish-run session))
        (plist-put run :iteration iteration)
        (harness-agent--request session)))))


;;; Requests

(defun harness-agent--provider-tool-capable-p (session)
  "Return non-nil when SESSION's provider supports native tool calls."
  (let ((provider (and (harness-session-provider session)
                       (harness-provider-get (harness-session-provider session)))))
    (and provider
         (plist-get (harness-provider-capabilities provider) :tools))))

(defun harness-agent--request-args (session)
  "Return the request overrides for SESSION's next request."
  (let ((capable (harness-agent--provider-tool-capable-p session)))
    (list :tools (when capable (harness-tools-specs session))
          ;; Not the transcript: the summary plus the recent tail, so a long
          ;; session degrades instead of failing.
          :messages (harness-context-build-messages session)
          :system (harness-provider-system-prompt session))))

(defun harness-agent--request (session)
  "Send the transcript to the model for SESSION and stream the reply.

When the transcript has outgrown the model's window the run waits for a
compaction first; the compaction is itself a request, so waiting is a
callback rather than a block."
  (if (harness-context-needs-compaction-p session)
      (progn
        (harness-session-set-status session 'working
                                    (list :label "compacting context"))
        (harness-context-compact
         session (lambda (_summary) (harness-agent--request-now session))))
    (harness-agent--request-now session)))

(defun harness-agent--request-now (session)
  "Send SESSION's context view to the model and stream the reply."
  (let ((run (harness-agent-run-state session)))
    (when run
      (run-hook-with-args 'harness-before-request-hook session)
      (let* ((message (harness-message-create session 'assistant ""))
             (handle nil)
             ;; Usage may arrive mid-stream and again with the final chunk;
             ;; count it once.
             (usage-recorded nil))
        (setf (harness-message-status message) 'streaming)
        (harness-session-append-message session message)
        (harness-session-notify session 'messages)
        (plist-put run :message message)
        (setq handle
              (harness-provider-chat-async
               session
               (list
                :on-delta (lambda (kind text)
                            (harness-agent--on-delta session message kind text))
                :on-tool-call (lambda (_index call)
                                (harness-agent--on-tool-call session message call))
                :on-usage (lambda (usage)
                            (setq usage-recorded t)
                            (harness-agent--record-usage session usage))
                :on-done (lambda (reason usage)
                           (unless usage-recorded
                             (harness-agent--record-usage session usage))
                           (harness-agent--message-finished session message reason))
                :on-error (lambda (symbol text)
                            (harness-agent--request-failed session message symbol text)))
               (harness-agent--request-args session)))
        (plist-put run :request handle))
      session)))

(defun harness-agent--on-delta (session message kind text)
  "Append streamed TEXT of KIND to MESSAGE."
  (let ((run (harness-agent-run-state session)))
    (unless (and run (plist-get run :aborted))
      (if (eq kind 'thinking)
          (setf (harness-message-thinking message)
                (concat (or (harness-message-thinking message) "") text))
        (setf (harness-message-content message)
              (concat (harness-message-content message) text)))
      (unless (eq (harness-session-status session) 'streaming)
        (harness-session-set-status session 'streaming))
      (run-hook-with-args 'harness-stream-hook session message kind text)
      (harness-session-notify session 'stream))))

(defun harness-agent--on-tool-call (session message call)
  "Record streamed tool CALL on MESSAGE."
  (let ((calls (harness-message-tool-calls message)))
    (unless (memq call calls)
      (setf (harness-message-tool-calls message) (append calls (list call))))
    (run-hook-with-args 'harness-tool-call-updated-hook session call)
    (harness-session-notify session 'messages)))

(defun harness-agent--record-usage (session usage)
  "Add USAGE to SESSION, computing its cost from the model's prices."
  (when usage
    (let* ((provider (harness-session-provider session))
           (model (harness-session-model session))
           (stats (and model (harness-model-stats provider model)))
           (cost (if stats (harness-usage-cost usage stats) 0.0)))
      (harness-session-add-usage
       session (plist-put (copy-sequence usage) :cost cost)))))

(defun harness-agent--request-failed (session message symbol text)
  "Report a failed request for SESSION, marking MESSAGE as errored."
  (let ((run (harness-agent-run-state session)))
    (setf (harness-message-status message) 'error)
    (setf (harness-message-error message) (format "%s: %s" symbol text))
    (harness-message-finalize message)
    (harness-session-persist-message session message)
    (harness-session-notify session 'messages)
    (run-hook-with-args 'harness-request-failed-hook session message)
    (cond
     ((and run (plist-get run :aborted))
      (harness-agent--finish-run session))
     (t
      (harness-session-set-status session 'idle
                                  (list :label (format "%s" text)))
      (harness-agent--finish-run session)))))


;;; Tool calls

(defun harness-agent--message-finished (session message reason)
  "Handle a finished assistant MESSAGE with REASON."
  (let ((run (harness-agent-run-state session)))
    (harness-message-finalize message)
    (setf (harness-message-meta message)
          (plist-put (harness-message-meta message) :finish-reason reason))
    ;; A provider without native tool support can still ask for a tool by
    ;; emitting a fenced block; turn that into a real tool call.
    (unless (harness-agent--provider-tool-capable-p session)
      (harness-agent--extract-text-tool-calls session message))
    (harness-session-persist-message session message)
    (run-hook-with-args 'harness-message-updated-hook session message '(complete))
    (harness-session-notify session 'messages)
    (cond
     ((and run (plist-get run :aborted))
      (harness-agent--finish-run session))
     ((harness-message-tool-calls message)
      (harness-session-set-status session 'working)
      (harness-agent--run-tools session (harness-message-tool-calls message)))
     (t
      (when (and harness-auto-name-sessions
                 (not (harness-session-title-generated session))
                 (equal (harness-message-role
                         (car (harness-session-messages session))) 'user))
        (harness-agent--name-session session))
      (harness-agent--finish-run session)))))

(defun harness-agent--run-tools (session calls)
  "Run CALLS in order for SESSION."
  (let ((run (harness-agent-run-state session)))
    (plist-put run :calls calls)
    (plist-put run :call-index 0)
    (harness-agent--run-next-tool session)))

(defun harness-agent--run-next-tool (session)
  "Run the next outstanding tool call of SESSION."
  (let* ((run (harness-agent-run-state session))
         (calls (plist-get run :calls))
         (index (plist-get run :call-index)))
    (cond
     ((or (null run) (plist-get run :aborted))
      (harness-agent--finish-run session))
     ((>= index (length calls))
      (harness-agent--continue session))
     (t
      (let ((call (nth index calls)))
        (harness-perms-authorize
         call session
         (lambda (allowed reason _remember)
           (cond
            ((plist-get run :aborted)
             (harness-tool-call-cancel call "aborted")
             (harness-agent--tool-finished session call))
            (allowed
             (harness-tool-run call session
                               (lambda (finished)
                                 (harness-agent--tool-finished session finished))))
            (t
             (setf (harness-tool-call-status call) 'denied)
             (setf (harness-tool-call-error call) reason)
             (setf (harness-tool-call-result call)
                   (format "The user denied this tool call: %s" (or reason "denied")))
             (setf (harness-tool-call-finished call) (float-time))
             (harness-agent--tool-finished session call))))))))))

(defun harness-agent--tool-finished (session call)
  "Append the result of CALL to SESSION and move on."
  (let* ((run (harness-agent-run-state session))
         (message (harness-message-create
                   session 'tool
                   (harness-tool-call-output call))))
    (setf (harness-message-tool-call-id message) (harness-tool-call-id call))
    (setf (harness-message-tool-name message) (harness-tool-call-name call))
    (setf (harness-message-status message)
          (if (memq (harness-tool-call-status call) '(ok running pending)) 'complete 'error))
    (when (harness-tool-call-error call)
      (setf (harness-message-error message) (harness-tool-call-error call)))
    (harness-message-finalize message)
    (harness-session-add-message session message)
    (when run
      (plist-put run :call-index (1+ (or (plist-get run :call-index) 0))))
    (harness-agent--run-next-tool session)))

(defun harness-agent--extract-text-tool-calls (_session message)
  "Turn fenced ```tool blocks in MESSAGE into tool calls.
This is the degradation path for providers without native tool calling."
  (let ((content (harness-message-content message))
        (calls (harness-message-tool-calls message))
        (start 0))
    (while (string-match "```tool[ \t]*\n\\(.*?\\)\n?```" content start)
      (let ((payload (match-string 1 content)))
        (condition-case err
            (let* ((parsed (harness-json-read payload))
                   (name (harness-alist-get :name parsed))
                   (arguments (harness-alist-get :arguments parsed)))
              (when name
                (setq calls (append calls
                                    (list (harness-tool-call-create
                                           :id (concat "text-" (harness--random-hex 6))
                                           :name (format "%s" name)
                                           :args-string (harness-json-write
                                                         (or arguments (list)))))))))
          (error (harness--log "bad text tool block: %s" (error-message-string err)))))
      (setq start (match-end 0)))
    (when calls
      (setf (harness-message-tool-calls message) calls)
      (setf (harness-message-content message)
            (string-trim (replace-regexp-in-string
                          "```tool[ \t]*\n\\(?:.*?\\)\n?```" "" content t))))))


;;; System context and session naming

(defun harness-agent-system-context (session)
  "Return project and tool context for SESSION's system prompt.
Returns a string, as `harness-system-prompt-functions' requires."
  (let ((root (harness-session-cwd session)))
    (string-join
     (delq nil
           (list (format "Project: %s\nWorking directory: %s\nDate: %s"
                         (or (harness-session-project-name session) "?")
                         root
                         (format-time-string "%Y-%m-%d"))
                 (unless (harness-agent--provider-tool-capable-p session)
                   (format "You have no native tool calling. To use a tool, emit a fenced block:

```tool
{\"name\": \"tool_name\", \"arguments\": {...}}
```

Available tools:
%s"
                           (harness-tools-describe session)))))
     "\n\n")))

(defun harness-agent--name-session (session)
  "Ask a cheap model for a short title for SESSION."
  (setf (harness-session-title-generated session) t)
  (let* ((model (or harness-auto-mode-model (harness-session-model session)))
         (stub (harness--make-session
                :id "naming" :name "naming" :model model
                :provider (harness-session-provider session)))
         (text (mapconcat (lambda (message)
                            (format "%s: %s" (harness-message-role message)
                                    (harness-truncate-string
                                     (harness-message-content message) 500)))
                          (cl-remove-if-not
                           (lambda (message)
                             (memq (harness-message-role message) '(user assistant)))
                           (harness-session-messages session))
                          "\n"))
         (answer ""))
    (harness-provider-chat-async
     stub
     (list :on-delta (lambda (kind chunk)
                       (when (eq kind 'text) (setq answer (concat answer chunk))))
           :on-done (lambda (&rest _)
                      (let ((title (string-trim
                                    (replace-regexp-in-string
                                     "[\n\r]+" " " (string-trim answer)))))
                        (when (and (not (string-empty-p title)) (< (length title) 80))
                          (setf (harness-session-name session)
                                (string-trim title "\"" "\""))
                          (harness-session-save-state session)
                          (harness-session-notify session 'meta))))
           :on-error (lambda (&rest _) nil))
     (list :messages (list (harness--make-message
                            :id "m-1" :role 'user :status 'complete
                            :content (concat "Give a short title (max 6 words, no quotes, "
                                             "no trailing punctuation) for this conversation:\n\n"
                                             text)))))))

(add-hook 'harness-system-prompt-functions #'harness-agent-system-context)

(provide 'harness-agent)
;;; harness-agent.el ends here
