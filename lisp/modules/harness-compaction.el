;;; harness-compaction.el --- Summarise a transcript that outgrows its window  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation cannot grow past the model's context window, and it
;; must stop well before that: the summary that replaces it has to be
;; generated with room to spare (`harness-compaction--context-reserve').  This
;; module asks the session's own model for a thorough handoff summary,
;; appends it as a `compaction' node and lets `session/messages' restart
;; the transcript from there.  The earlier nodes stay in the DAG (the
;; node's `:meta' points at the compacted head) so nothing is lost for
;; the tree view or for search.
;;
;; Automatic compaction hangs on the `agent/before-turn' filter: when
;; the last request's context exceeds window minus reserve, the turn
;; waits for the summary and then proceeds.  Providers that report
;; `:compaction hosted' compact on their own side and are left alone.
;;
;; The summarisation request is a fresh one: no tools and no provider
;; state.  For a hosted-loop provider that means a fresh process that
;; receives the transcript as ordinary messages, which is fine for a
;; one-shot summary; such providers normally declare hosted compaction
;; and never get here.
;;
;; `compaction/status' grades how full the window is so a UI can colour
;; the token count progressively.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-compaction--system-prompt
  "You are writing a handoff summary so that a fresh agent can continue this work without access to the conversation above.

Write a thorough, factual summary in Markdown with these sections:

1. Goals: what the user is trying to achieve, in their words where possible.
2. Decisions: choices made and the reasons behind them.
3. Files touched: every file read, created or edited, with its full path and what changed in it.
4. Current state: what works, what is unfinished, and what was being done last.
5. Open items: remaining tasks, unanswered questions, known problems.
6. Pending user request: the most recent user message(s) verbatim if they have not been answered yet.

Keep exact identifiers: file paths, function and variable names, commands, error messages, URLs, ids and numbers.  Prefer precise statements over prose.  Do not add commentary about the summary itself."
  "System prompt for the compaction summariser.")

(defconst harness-compaction--request-text
  "Summarize the conversation above for a fresh agent that will take over from here.  Follow the section list from your instructions and keep every exact identifier."
  "Final user message that asks the model for the summary.")

(defconst harness-compaction--max-tokens 4000
  "Output budget for a compaction summary, in tokens.")

(defconst harness-compaction--context-reserve 20000
  "Tokens kept free below the context window before compaction.
The room the summary request and the summary itself need, with some to
spare: `harness-compaction--max-tokens' of output plus the prompt.")

(defconst harness-compaction--levels '((0.7 . ok) (0.85 . warning) (0.95 . urgent))
  "Fractions of the usable window below which each level applies.
Anything at or above the last fraction is `critical'.")

(defvar harness-compaction--running (make-hash-table :test 'equal)
  "Session id -> promise of the compaction in flight.")

;;;; Status

(defun harness-compaction--reserve (_session)
  "Return the context reserve that applies to SESSION."
  harness-compaction--context-reserve)

(defun harness-compaction--window (session)
  "Return the context window of SESSION's model."
  (or (plist-get session :context-window)
      (and (harness-method-exists-p 'provider/model)
           (plist-get (harness-call 'provider/model (plist-get session :model)) :context-window))
      128000))

(defun harness-compaction--usable (window reserve)
  "Return the tokens usable before compaction given WINDOW and RESERVE.
The reserve is capped at half the window so tiny models still work."
  (max 1 (- window (min reserve (/ window 2)))))

(defun harness-compaction--level (fraction)
  "Return the warning level for FRACTION of the usable window."
  (or (cdr (cl-find-if (lambda (cell) (< fraction (car cell))) harness-compaction--levels))
      'critical))

(harness-defmethod compaction/status (session-id)
  "Describe how full the context of SESSION-ID is.
Return (:context N :window N :reserve N :usable N :fraction F :level L)
where L is one of `ok', `warning', `urgent' and `critical'."
  (let* ((session (harness-call 'session/get session-id))
         (context (or (plist-get (plist-get session :usage) :context) 0))
         (window (harness-compaction--window session))
         (reserve (harness-compaction--reserve session))
         (usable (harness-compaction--usable window reserve))
         (fraction (/ (float context) usable)))
    (list :context context :window window :reserve reserve :usable usable
          :fraction fraction :level (harness-compaction--level fraction))))

(defun harness-compaction-needed-p (session)
  "Non-nil when SESSION's last context exceeded its window minus the reserve."
  (let ((context (or (plist-get (plist-get session :usage) :context) 0)))
    (> context (harness-compaction--usable (harness-compaction--window session)
                                           (harness-compaction--reserve session)))))

(defun harness-compaction-hosted-p (session)
  "Non-nil when SESSION's provider compacts on its own side."
  (let ((v (plist-get (harness-call 'provider/capabilities (plist-get session :model)) :compaction)))
    (or (eq v 'hosted) (equal v "hosted"))))

;;;; Compacting

(defun harness-compaction--trailing-user-nodes (path)
  "Return the unanswered user nodes at the end of PATH, oldest first."
  (let (out)
    (cl-loop for n in (reverse path)
             while (memq (plist-get n :kind) '(user hint))
             when (eq (plist-get n :kind) 'user) do (push n out))
    out))

(defun harness-compaction--messages (session-id)
  "Return the summarisation messages for SESSION-ID."
  (let* ((messages (harness-call 'session/messages session-id))
         (ask (list :type "text" :text harness-compaction--request-text))
         (last (car (last messages))))
    (if (and last (eq (plist-get last :role) 'user))
        (append (butlast messages)
                (list (list :role 'user :content (append (plist-get last :content) (list ask)))))
      (append messages (list (list :role 'user :content (list ask)))))))

(defun harness-compaction--messages-tokens (messages)
  "Cheap token estimate for MESSAGES."
  (let ((n 0))
    (dolist (m messages n)
      (dolist (b (plist-get m :content))
        (cl-incf n (harness-estimate-tokens
                    (or (plist-get b :text)
                        (and (stringp (plist-get b :content)) (plist-get b :content))
                        "")))))))

(defun harness-compaction--finish (session-id summary old-head model usage input-tokens trailing)
  "Record SUMMARY for SESSION-ID and return the compaction node.
OLD-HEAD is the head that was compacted, MODEL the summariser, USAGE
its usage event, INPUT-TOKENS the size of what was compacted and
TRAILING the unanswered user nodes to carry over."
  (let ((node (harness-call 'session/append session-id
                            (list :kind 'compaction :content summary
                                  :meta (list :compacted-head old-head :model model
                                              :input-tokens input-tokens
                                              :summary-tokens (harness-estimate-tokens summary))))))
    (harness-call 'session/hint session-id
                  (format "Compacted: %s tokens → summary" (harness-format-tokens input-tokens)))
    (dolist (u trailing)
      (harness-call 'session/append session-id
                    (list :kind 'user :content (plist-get u :content) :blocks (plist-get u :blocks)
                          :meta (plist-put (copy-sequence (plist-get u :meta)) :carried-from (plist-get u :id)))))
    (harness-call 'session/usage-add session-id
                  (list :input (plist-get usage :input) :output (plist-get usage :output)
                        :cache-read (plist-get usage :cache-read) :cache-write (plist-get usage :cache-write)
                        :cost (plist-get usage :cost)
                        :context (harness-estimate-tokens summary)))
    (harness-emit 'compaction/done session-id node)
    node))

(harness-defmethod compaction/compact (session-id &optional opts)
  "Summarise the transcript of SESSION-ID; return a promise of the compaction node.
OPTS `:model' picks a summariser other than the session's model.  The
summary replaces the transcript for the provider (`session/messages'
restarts at the compaction node); unanswered user messages at the end
of the transcript are carried over after it.  A second call while one
is running returns the running promise."
  (or (gethash session-id harness-compaction--running)
      (let* ((session (harness-call 'session/get session-id))
             (model (or (plist-get opts :model) (plist-get session :model)))
             (old-head (plist-get session :head))
             (path (harness-call 'session/nodes session-id))
             (trailing (harness-compaction--trailing-user-nodes path))
             (messages (harness-compaction--messages session-id))
             (estimate (or (let ((c (plist-get (plist-get session :usage) :context)))
                             (and (numberp c) (> c 0) c))
                           (harness-compaction--messages-tokens messages)))
             (promise (harness-make-promise))
             (text "") (usage nil))
        (puthash session-id promise harness-compaction--running)
        (harness-finally promise (lambda () (remhash session-id harness-compaction--running)))
        (harness-call 'session/hint session-id "Compacting context…")
        (harness-log 'info "compaction: summarising %s with %s (%s tokens)" session-id model estimate)
        (condition-case err
            (harness-call
             'provider/complete
             (list :model model :session session
                   :system harness-compaction--system-prompt
                   :messages messages :tools nil :provider-state nil
                   :max-tokens harness-compaction--max-tokens
                   :on-event
                   (lambda (ev)
                     (pcase (plist-get ev :type)
                       ('text (setq text (concat text (plist-get ev :delta))))
                       ('usage (setq usage ev))
                       ('done
                        (let* ((reason (plist-get ev :stop-reason))
                               (summary (string-trim text))
                               (problem (cond ((memq reason '(error cancelled))
                                               (or (plist-get ev :error) (format "%s" reason)))
                                              ((string-empty-p summary)
                                               "the model returned an empty summary"))))
                          (if problem
                              (harness-compaction--fail session-id promise problem)
                            (condition-case err
                                (harness-resolve
                                 promise
                                 (harness-compaction--finish
                                  session-id summary old-head model usage
                                  (or (plist-get usage :context)
                                      (and (plist-get usage :input)
                                           (+ (plist-get usage :input) (or (plist-get usage :cache-read) 0)))
                                      estimate)
                                  trailing))
                              (error (harness-compaction--fail session-id promise err))))))
                       (_ nil)))))
          (error (harness-compaction--fail session-id promise err)))
        promise)))

(defun harness-compaction--fail (session-id promise err)
  "Reject PROMISE with ERR and tell SESSION-ID about it."
  (let ((msg (harness-error-message err)))
    (harness-log 'warn "compaction of %s failed: %s" session-id msg)
    (ignore-errors (harness-call 'session/hint session-id (format "Compaction failed: %s" msg)))
    (harness-emit 'compaction/failed session-id msg)
    (harness-reject promise err)))

;;;; Automatic compaction

(defun harness-compaction--before-turn (value next session)
  "Compact SESSION before its turn when the context is nearly full.
VALUE and NEXT are the `agent/before-turn' filter arguments.  SESSION
is read again first: a handler earlier in the chain (the fallback) may
have moved it to another model, whose window and compaction decide."
  (let ((session (or (ignore-errors (harness-call 'session/get (plist-get session :id))) session)))
    (if (or (not (plist-get value :proceed))
            (not (harness-compaction-needed-p session))
            (harness-compaction-hosted-p session))
        (funcall next value)
      (harness-then (harness-call 'compaction/compact (plist-get session :id))
                    (lambda (_node) (funcall next value))
                    (lambda (_err) (funcall next value)))))
  nil)

(defun harness-compaction--init ()
  "Hook automatic compaction into the turn loop."
  (harness-add-filter 'agent/before-turn #'harness-compaction--before-turn 20))

(harness-compaction--init)

(harness-declare-event 'compaction/done "(SESSION-ID NODE) after a compaction node is appended.")
(harness-declare-event 'compaction/failed "(SESSION-ID MESSAGE) when a compaction fails.")

(harness-define-module 'compaction
  :doc "Summarise the transcript when it nears the context window."
  :requires '(session provider agent)
  :init #'harness-compaction--init)

(provide 'harness-compaction)
;;; harness-compaction.el ends here
