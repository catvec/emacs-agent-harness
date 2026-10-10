;;; harness-tools-compact.el --- The compact tool: an agent compacts its own conversation  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation that nears its model's context window is compacted on
;; its own (harness-compaction.el), and a person can compact one by hand
;; from the UI (`harness-compact').  Neither helps an agent that sees the
;; context filling up mid-task: it can neither ask the user in time nor
;; wait for `agent/before-turn'.  This module gives it the `compact'
;; tool, which calls the one core path (`compaction/compact'), so what
;; the tool does is exactly what compacting by hand does.
;;
;; The turn the tool runs in is the reason for `mode': the session is
;; always running one when the agent calls it, and a compaction must not
;; write while the turn does.  `queue' (the default) registers the
;; compaction for the turn's next boundary -- the next step, or its end
;; -- so the turn goes on and the conversation continues from the
;; compaction after that.  `interrupt' cancels the running turn at once
;; (`agent/cancel') and compacts as soon as it is over: the step in
;; flight, and anything it had not recorded yet, are lost, so the tool
;; only does it when asked for it.  Both answer at once (the compaction
;; later resolves on its own), so the tool never holds its own step open
;; waiting for a compaction that waits for that step.
;;
;; The tool is offered to every session, task or interactive; a session
;; whose provider compacts on its own side (a hosted loop) may still be
;; compacted by hand, as a handoff to another provider may.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(declare-function harness-compaction-busy-p "harness-compaction" (session-id))

(defconst harness-tools-compact-kinds '("summary" "brief" "transcript" "fresh" "truncate")
  "The kinds of compaction the `compact' tool offers, the default first.
They are the kinds of `harness-compaction-kinds'.")

(defconst harness-tools-compact-modes '("queue" "interrupt")
  "How the `compact' tool handles the turn it is called from.
`queue' waits for the turn's next boundary; `interrupt' cancels the
turn first.")

(defun harness-tools-compact--kind-name (kind)
  "Return the name of KIND, a kind of `harness-tools-compact-kinds', for people."
  (pcase kind
    ("brief" "brief summary")
    ("transcript" "transcript file")
    ("fresh" "fresh start")
    ("truncate" "cut old context")
    (_ "summary")))

(defun harness-tools-compact--clean (value)
  "Return VALUE as a non-blank trimmed string, or nil."
  (and (stringp value) (not (harness-string-blank-p value)) (string-trim value)))

(defun harness-tools-compact--queued-text (kind interrupt)
  "Say that a KIND compaction is queued, interrupting the turn when INTERRUPT."
  (if interrupt
      (format (concat "The current turn is being cancelled, and the conversation is compacted (%s) as soon"
                      " as it is over; it does not go on.  Nothing more to do now.")
              (harness-tools-compact--kind-name kind))
    (format (concat "Compaction queued: a %s at this turn's next boundary.  The turn goes on, and the"
                    " conversation continues from the compaction after that.")
            (harness-tools-compact--kind-name kind))))

(defun harness-tools-compact--done-text (node)
  "Say what the compaction NODE now stands for."
  (format (concat "The conversation is compacted (%s) and continues from that.  The conversation it"
                  " replaced is still on record: search and read it with the session_history tool"
                  " when you need what it left out.")
          (harness-tools-compact--kind-name (or (harness-node-compaction-kind node) "summary"))))

(defun harness-tools-compact--compact (input ctx)
  "Handler of the compact tool: compact the conversation of CTX's session.
INPUT has `:kind' (`harness-tools-compact-kinds', default summary),
`:mode' (`harness-tools-compact-modes', default queue) and an optional
`:reason' kept with the compaction."
  (let* ((sid (plist-get ctx :session-id))
         (kind (or (harness-tools-compact--clean (plist-get input :kind)) "summary"))
         (mode (or (harness-tools-compact--clean (plist-get input :mode)) "queue"))
         (reason (harness-tools-compact--clean (plist-get input :reason))))
    (cond
     ((not (member kind harness-tools-compact-kinds))
      (harness-tool-error
       (format "Unknown kind %s: use summary, brief, transcript, fresh or truncate" kind)))
     ((not (member mode harness-tools-compact-modes))
      (harness-tool-error (format "Unknown mode %s: use queue or interrupt" mode)))
     ((harness-compaction-busy-p sid)
      (harness-tool-ok
       "A compaction of this conversation is already under way; it will finish on its own."))
     (t
      (harness-then
       (harness-call-async 'compaction/compact sid
                           (append (list :kind kind :reason reason)
                                   (when reason (list :meta (list :reason reason)))
                                   (if (equal mode "interrupt")
                                       (list :interrupt t)
                                     (list :queue t))))
       (lambda (result)
         (if (harness-json-true-p (plist-get result :queued))
             (harness-tool-ok
              (harness-tools-compact--queued-text
               (let ((k (plist-get result :kind)))
                 (if (stringp k) k kind))
               (harness-json-true-p (plist-get result :interrupt))))
           (harness-tool-ok (harness-tools-compact--done-text result))))
       (lambda (err)
         ;; Short: the failure of a summariser can carry a whole transcript
         ;; as its data, and this is read.
         (harness-tool-error (format "Could not compact: %s" (harness-error-short-message err)))))))))

(harness-define-tool "compact"
  :label "Compact the conversation"
  :description
  (concat "Compact this conversation to free context: the session goes on from a much smaller transcript,"
          " and the old conversation stays on record for the session_history tool.  Call it when the context"
          " is filling this model's window, or before a long job that will add a lot more, rather than"
          " waiting for the harness to compact on its own.  kind chooses what stands in for the conversation:"
          " summary (the default) has this session's model summarise the whole conversation, which reads all"
          " of it again; brief has a cheap model summarise the conversation's narrative -- every user and"
          " assistant message, each tool call and result in a line -- cheap however long the conversation"
          " but leaving out what tools read and wrote; transcript writes the whole conversation"
          " to a file and leaves a note to read what is needed of it, asking no model; fresh carries nothing"
          " over but a note, asking no model; truncate drops the oldest messages and keeps the most recent as"
          " they are, asking no model, for a conversation too big to summarise.  mode chooses when it happens:"
          " queue (the default) waits for this turn's next boundary, and the turn goes on; interrupt cancels"
          " the current turn at once -- the step in flight and anything it had not recorded yet are lost --"
          " and compacts as soon as it is over, so use it only when the context itself is what must be fixed"
          " now.  reason is one line on why you compacted, kept with the compaction.")
  :schema '(:type "object"
            :properties (:kind (:type "string"
                                :enum ("summary" "brief" "transcript" "fresh" "truncate")
                                :description "What stands in for the conversation: summary (default), brief, transcript, fresh or truncate.")
                         :mode (:type "string"
                                :enum ("queue" "interrupt")
                                :description "queue (default) compacts at this turn's next boundary; interrupt cancels the current turn now and compacts once it is over.")
                         :reason (:type "string"
                                  :description "One line on why you are compacting, kept with the compaction.")))
  :kind 'meta
  :subject (lambda (input) (plist-get input :kind))
  :timeout 600
  :handler #'harness-tools-compact--compact)

(harness-define-module 'tools-compact
  :doc "The compact tool: an agent compacts its own conversation, on a running turn by queueing it or interrupting it."
  :requires '(tools compaction))

(provide 'harness-tools-compact)
;;; harness-tools-compact.el ends here
