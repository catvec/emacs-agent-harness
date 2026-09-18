;;; harness-context.el --- Long context handling -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; Author: the emacs-agent-harness authors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://git.sr.ht/~catvec/emacs-agent-harness

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

;; A session can outlive its model's context window.  Three rules keep that
;; graceful:
;;
;; 1. **The transcript is not the request.**  The session keeps every message,
;;    so the UI and search still see all of it; what goes to the model is
;;    `harness-context-build-messages', which is the summary plus the recent
;;    tail.  Nothing is lost by compacting, because nothing is deleted.
;; 2. **Keep the buffer small.**  The conversation view renders a window of
;;    messages and loads earlier ones on demand, so a 5000 message session
;;    does not mean a 5000 message buffer.
;; 3. **Never do the big walk on the main thread.**  Searching a whole
;;    transcript, or sizing one, is chunked across timers
;;    (`harness-context-search'), and cross-session search stays in the SQLite
;;    index and grep.  A long session must not make Emacs stutter.
;;
;; Compaction itself is a cheap-model request and therefore asynchronous: the
;; run it interrupts waits for it rather than the other way round.
;;
;; See DESIGN.md section 15.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-session)
(require 'harness-provider)
(require 'harness-agent)

(defcustom harness-context-default-window 128000
  "Context window assumed for a model whose size is unknown."
  :type 'integer
  :group 'harness)

(defcustom harness-context-minimum-budget 256
  "Lower bound on the request budget, whatever the arithmetic says."
  :type 'integer
  :group 'harness)

(defcustom harness-context-reserve-tokens 8000
  "Tokens kept free for the model's reply."
  :type 'integer
  :group 'harness)

(defcustom harness-context-keep-recent 12
  "Messages never summarised away.
The tail is what the next turn usually depends on."
  :type 'integer
  :group 'harness)

(defcustom harness-context-warn-at 0.6
  "Fraction of the budget at which the mode line shows a warning."
  :type 'number
  :group 'harness)

(defcustom harness-context-compact-at 0.8
  "Fraction of the budget that triggers automatic compaction."
  :type 'number
  :group 'harness)

(defcustom harness-context-auto-compact t
  "Whether to compact automatically when the transcript gets too large."
  :type 'boolean
  :group 'harness)

(defcustom harness-context-chars-per-token 4
  "Characters per token used for estimation.
Deliberately crude: it only has to be close enough to decide when to compact,
and being wrong is corrected by the provider's own token counts in usage."
  :type 'number
  :group 'harness)

(defcustom harness-context-message-overhead 4
  "Tokens assumed per message, for role and formatting overhead."
  :type 'integer
  :group 'harness)

(defcustom harness-context-summary-model nil
  "Model used to summarise old messages.
Nil uses `harness-auto-mode-model', then the session's model."
  :type '(choice (const :tag "Cheapest configured" nil) string)
  :group 'harness)

(defcustom harness-context-summary-prompt
  "You compress a coding session's transcript for another agent that will
continue the work.

Keep: what the user asked for, decisions and their reasons, file paths and
what changed in them, commands that matter, open questions and anything that
would be expensive to rediscover.  Drop: pleasantries, restatements, and
detail that is visible in the files themselves.  Write compact notes, not
prose.  Do not invent anything."
  "System prompt for the summariser."
  :type 'string
  :group 'harness)

(defcustom harness-context-search-chunk 50
  "Messages examined per timer tick when scanning a transcript."
  :type 'integer
  :group 'harness)

(defvar harness-context-updated-hook nil
  "Hook run with the session after its context view changes.")


;;; Sizing

(defun harness-context-message-chars (message)
  "Return MESSAGE's size in characters, cached on the message.
The cache matters: sizing a transcript happens before every request, and a
long session has a lot of messages."
  (or (plist-get (harness-message-meta message) :chars)
      (let ((chars (+ (length (or (harness-message-content message) ""))
                      (length (or (harness-message-thinking message) ""))
                      (cl-loop for call in (harness-message-tool-calls message)
                               sum (+ (length (or (harness-tool-call-args-string call) ""))
                                      (length (or (harness-tool-call-result call) "")))))))
        (setf (harness-message-meta message)
              (plist-put (harness-message-meta message) :chars chars))
        chars)))

(defun harness-context-tokens (&optional session messages)
  "Estimate the tokens MESSAGES would cost, defaulting to SESSION's transcript."
  (let ((messages (or messages (and session (harness-session-messages session)))))
    (+ (ceiling (/ (cl-loop for message in messages
                            sum (harness-context-message-chars message))
                   harness-context-chars-per-token))
       (* harness-context-message-overhead (length messages)))))

(defun harness-context-window (session)
  "Return SESSION's model context window."
  (or (harness-model-stats-context-window
       (harness-model-stats (harness-session-provider session)
                            (harness-session-model session)))
      harness-context-default-window))

(defun harness-context-budget (session)
  "Return how many tokens SESSION's requests may use.

Never returns less than `harness-context-minimum-budget': a configuration that
would leave no room at all is a misconfiguration, and silently pretending the
budget is negative would make the mode line nonsense."
  (max harness-context-minimum-budget
       (- (harness-context-window session)
          harness-context-reserve-tokens
          (or harness-max-tokens 0))))

(defun harness-context-ratio (session)
  "Return how full SESSION's context budget is, as a fraction."
  (/ (float (harness-context-tokens session))
     (harness-context-budget session)))

(defun harness-context-stats-string (session)
  "Return a short context usage string for the mode line."
  (let ((ratio (harness-context-ratio session)))
    (format "%d%% of %s"
            (round (* 100 (min ratio 1.0)))
            (harness-format-count (harness-context-window session)))))

(defcustom harness-context-compact-retry-delay 300
  "Seconds to wait after a failed compaction before trying again.
Without this a summariser that keeps failing would be asked on every turn."
  :type 'integer
  :group 'harness)

(defun harness-context-needs-compaction-p (session)
  "Return non-nil when SESSION's transcript should be compacted."
  (let ((failed-at (plist-get (harness-session-meta session) :summary-error-at)))
    (and harness-context-auto-compact
         (not (and failed-at
                   (< (- (float-time) failed-at) harness-context-compact-retry-delay)))
         (>= (harness-context-ratio session) harness-context-compact-at)
         (> (length (harness-session-messages session))
            (+ harness-context-keep-recent 1)))))


;;; The request view

(defun harness-context-summary (session)
  "Return SESSION's stored summary, or nil."
  (plist-get (harness-session-meta session) :summary))

(defun harness-context-summarised-upto (session)
  "Return how many of SESSION's messages the summary covers."
  (or (plist-get (harness-session-meta session) :summary-upto) 0))

(defun harness-context-build-messages (session)
  "Return the messages to send for SESSION.

Messages covered by the summary are dropped (the summary goes into the system
prompt), and if the remainder is still too large the oldest are dropped from
the front until it fits, with a note so the model knows it is looking at a
window rather than the beginning."
  (let* ((messages (harness-session-messages session))
         (upto (min (harness-context-summarised-upto session) (length messages)))
         (window (seq-drop messages upto))
         (budget (harness-context-budget session))
         (dropped 0))
    (while (and (> (harness-context-tokens nil window) budget)
                (> (length window) harness-context-keep-recent))
      (setq window (cdr window))
      (setq dropped (1+ dropped)))
    (when (> dropped 0)
      (setq window
            (cons (harness--make-message
                   :id "context-window-note" :role 'system :status 'complete
                   :content (format "[%d earlier messages omitted: the transcript is longer than the context window. Use the session search to look things up.]"
                                    (+ dropped upto))
                   :timestamp (float-time))
                  window)))
    window))

(defun harness-context-summary-addition (session)
  "Return SESSION's summary as a system prompt paragraph.
Registered in `harness-system-prompt-functions', which is how the summary
reaches the model without being a fake message in the transcript."
  (when-let* ((summary (harness-context-summary session)))
    (when (not (string-empty-p summary))
      (format "Summary of the conversation so far (earlier messages are not repeated):\n\n%s"
              summary))))

(add-hook 'harness-system-prompt-functions #'harness-context-summary-addition)


;;; Compaction

(defun harness-context--transcript-text (messages)
  "Return MESSAGES as plain text for the summariser."
  (string-join
   (mapcar (lambda (message)
             (format "%s: %s"
                     (capitalize (symbol-name (harness-message-role message)))
                     (truncate-string-to-width
                      (or (harness-message-content message) "") 4000 nil nil "…")))
           messages)
   "\n\n"))

(defun harness-context-compact (session &optional callback)
  "Summarise SESSION's old messages, then call CALLBACK.

The messages are not deleted; the summary and an index are stored on the
session, and `harness-context-build-messages' stops sending what the summary
covers.  This is a model request and therefore asynchronous: the run it
interrupts waits for it rather than the other way round."
  (let* ((messages (harness-session-messages session))
         (upto (harness-context-summarised-upto session))
         (end (max upto (- (length messages) harness-context-keep-recent)))
         (subject (seq-subseq messages upto end)))
    (if (null subject)
        (progn
          (when callback (funcall callback nil))
          nil)
      (let* ((model (or harness-context-summary-model harness-auto-mode-model
                        (harness-session-model session)))
             (stub (harness--make-session
                    :id "summarise" :name "summarise" :model model
                    :provider (harness-session-provider session)))
             (previous (harness-context-summary session))
             (text "")
             (settled nil)
             (finish
              (lambda (summary)
                (unless settled
                  (setq settled t)
                  (let ((meta (harness-session-meta session)))
                    (if (and summary (not (string-empty-p summary)))
                        (progn
                          (setf (harness-session-meta session)
                                (plist-put (plist-put meta :summary summary)
                                           :summary-upto end))
                          (setf (harness-session-meta session)
                                (plist-put (harness-session-meta session)
                                           :summary-error-at nil)))
                      ;; Remember the failure so the next turn does not ask a
                      ;; broken summariser again immediately.
                      (setf (harness-session-meta session)
                            (plist-put meta :summary-error-at (float-time)))))
                  (harness-session-save-state session)
                  (harness-session-notify session 'meta)
                  (run-hook-with-args 'harness-context-updated-hook session)
                  (when callback (funcall callback summary))))))
        (harness-provider-chat-async
         stub
         (list :on-delta (lambda (kind chunk)
                           (when (eq kind 'text) (setq text (concat text chunk))))
               :on-done (lambda (&rest _) (funcall finish (string-trim text)))
               :on-error (lambda (symbol message)
                           (harness--log "compaction failed: %s %s" symbol message)
                           (funcall finish nil)))
         (list :system harness-context-summary-prompt
               :messages
               (list (harness--make-message
                      :id "m-1" :role 'user :status 'complete
                      :content (format "%sTranscript to compress:\n\n%s"
                                       (if previous
                                           (format "Notes from the previous compaction:\n\n%s\n\n"
                                                   previous)
                                         "")
                                       (harness-context--transcript-text subject))))))
        t))))

(defun harness-compact-session (&optional session)
  "Summarise the older part of SESSION's transcript."
  (interactive)
  (let ((session (or session
                     (when (fboundp 'harness-conversation-session)
                       (harness-conversation-session))
                     (harness-session--read-session "Compact"))))
    (unless session (user-error "No session to compact"))
    (if (harness-context-compact
         session
         (lambda (summary)
           (message "%s: %s" (harness-session-name session)
                    (if summary "compacted" "nothing to compact"))))
        (message "Compacting %s…" (harness-session-name session))
      (message "Nothing to compact in %s" (harness-session-name session)))))

(defun harness-context-forget-summary (session)
  "Drop SESSION's summary, so the whole transcript is sent again."
  (interactive (list (or (when (fboundp 'harness-conversation-session)
                           (harness-conversation-session))
                         (harness-session--read-session "Forget summary of"))))
  (setf (harness-session-meta session)
        (plist-put (plist-put (harness-session-meta session) :summary nil)
                   :summary-upto 0))
  (harness-session-save-state session)
  (harness-session-notify session 'meta)
  (message "Summary forgotten"))


;;; Searching the transcript

(defun harness-context-search (session regexp callback &optional limit)
  "Search SESSION's transcript for REGEXP, calling CALLBACK with the matches.

The scan is chunked across timers, so a long transcript does not block
anything: this is the case where full access to the context is needed and
doing it in one pass would freeze Emacs.  CALLBACK receives a list of plists
with `:message', `:index', `:field' and `:text'."
  (let ((state (list :cursor (harness-session-messages session)
                     :index 0
                     :results nil))
        (limit (or limit 200)))
    (harness-context--search-step session regexp callback limit state)
    state))

(defun harness-context--search-step (session regexp callback limit state)
  "Examine one chunk of STATE, rescheduling until the transcript is done."
  (let ((processed 0)
        (cursor (plist-get state :cursor)))
    (while (and cursor
                (< processed harness-context-search-chunk)
                (< (length (plist-get state :results)) limit))
      (harness-context--search-message regexp state (car cursor))
      (setq cursor (cdr cursor))
      (plist-put state :cursor cursor)
      (plist-put state :index (1+ (plist-get state :index)))
      (setq processed (1+ processed)))
    (if (or (null cursor)
            (>= (length (plist-get state :results)) limit))
        (funcall callback (nreverse (plist-get state :results)))
      (run-at-time 0.02 nil
                   (lambda ()
                     (harness-context--search-step
                      session regexp callback limit state))))))

(defun harness-context--search-message (regexp state message)
  "Record REGEXP matches found in MESSAGE into STATE."
  (let ((position (plist-get state :index)))
    (dolist (field '((:content . content) (:thinking . thinking)))
      (let ((text (pcase (car field)
                    (:content (harness-message-content message))
                    (:thinking (harness-message-thinking message)))))
        (when (and text (string-match-p regexp text))
          (plist-put state :results
                     (cons (list :message message
                                 :index position
                                 :field (cdr field)
                                 :text (harness-context--match-line text regexp))
                           (plist-get state :results))))))
    (dolist (call (harness-message-tool-calls message))
      (let ((text (or (harness-tool-call-result call) "")))
        (when (and (not (string-empty-p text))
                   (string-match-p regexp text))
          (plist-put state :results
                     (cons (list :message message
                                 :index position
                                 :field 'tool
                                 :tool (harness-tool-call-name call)
                                 :text (harness-context--match-line text regexp))
                           (plist-get state :results))))))))

(defun harness-context--match-line (text regexp)
  "Return the line of TEXT containing REGEXP, trimmed for display."
  (let* ((index (string-match regexp text))
         (start (if index
                    (or (let ((newline (cl-position ?\n text :start 0 :end index
                                                    :from-end t)))
                          (and newline (1+ newline)))
                        0)
                  0))
         (end (or (cl-position ?\n text :start start) (length text))))
    (truncate-string-to-width
     (string-trim (substring text start end)) 120 nil nil "…")))

(provide 'harness-context)
;;; harness-context.el ends here
