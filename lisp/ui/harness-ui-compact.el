;;; harness-ui-compact.el --- Compacting a conversation by hand, at a known cost  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation that nears its model's context window is compacted on
;; its own, as `harness-compaction-kind' says (harness-compaction.el).
;; This file compacts one by hand, in any of the kinds, and says first
;; what each costs (`compaction/estimate'), at list prices:
;;
;; - a brief summary: a cheap model (by default the cheap tier of the
;;   session's provider) summarises only the first and last messages,
;;   for a few cents however long the conversation, but most of its
;;   middle is left out, which the summary says;
;; - a summary: the session's model summarises the whole conversation,
;;   reading all of it again -- uncached once the prompt cache lapsed;
;; - a transcript file: the whole conversation goes to a file in the
;;   session's directory, and a note tells the model to read what it
;;   needs of it.  No request;
;; - a fresh start: nothing is carried over but a note saying so.  No
;;   request either.
;;
;; The first three are the ways a handoff carries a conversation over to
;; another provider (`compact-new', `compact', `transcript'), on the
;; session's own.  After any of them the session's next message sends
;; the summary or the note, not the whole conversation, cached or not;
;; the model searches and reads what it left out with the
;; session_history tool.
;;
;; `harness-compact' (C under the harness prefix and in its menu, or
;; /compact in a chat's message box, /compact brief to skip the
;; question) asks which, with what each costs and what carrying on
;; costs.  The panel a session shows once its prompt cache expired
;; (harness-ui-cache.el) offers the same as buttons, the brief summary
;; first: that is when carrying on is dearest, the whole context going
;; out uncached.  A message sent to such a session asks the same before
;; it goes (harness-cowboy.el, harness-ui-cowboy.el).  A session running
;; a turn is not compacted.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-commands)
(defvar harness-chat--session)

(defconst harness-ui-compact-kinds
  '((brief ?b "brief summary"
           "a cheap model summarises the first and last messages; most of the middle is left out")
    (summary ?s "summary"
             "the session's model summarises the whole conversation, reading all of it again")
    (transcript ?t "transcript file"
                "the conversation goes to a file the model reads what it needs of; no request")
    (fresh ?f "fresh start"
           "nothing is carried over; the model looks back with session_history when it needs to; no request"))
  "The kinds of compaction offered by hand, the cheap one first.
Each entry is (KIND KEY NAME DESCRIPTION): KIND a kind of
`compaction/compact', KEY the key that picks it, NAME what it is called
and DESCRIPTION one line on what it does.")

;;;; What each kind costs

(defun harness-ui-compact-label (kind)
  "Return the name of KIND as a label, first letter up: \"Brief summary\"."
  (let ((name (or (nth 2 (assq kind harness-ui-compact-kinds)) (format "%s" kind))))
    (concat (upcase (substring name 0 1)) (substring name 1))))

(defun harness-ui-compact--kind (estimate kind)
  "Return the estimate of KIND in ESTIMATE, a `compaction/estimate' answer."
  (cl-find-if (lambda (k) (equal (format "%s" (plist-get k :kind)) (symbol-name kind)))
              (plist-get estimate :kinds)))

(defun harness-ui-compact-cost (estimate kind)
  "Return what KIND of compaction costs in USD as ESTIMATE says, or nil.
Nil when the catalogue does not price the model that would write it."
  (let ((cost (plist-get (harness-ui-compact--kind estimate kind) :cost)))
    (and (numberp cost) cost)))

(defun harness-ui-compact-cost-text (estimate kind)
  "Return what KIND of compaction costs as ESTIMATE says, short: \"~$0.02\".
A transcript and a fresh start, which ask no model, are \"free\"; a
kind whose model the catalogue does not price is nil."
  (let ((cost (harness-ui-compact-cost estimate kind)))
    (cond ((memq kind '(transcript fresh)) "free")
          (cost (concat "~" (harness-format-cost cost))))))

(defun harness-ui-compact--writer (estimate kind)
  "Return the label of the model that would write KIND, as ESTIMATE says, or nil."
  (let ((k (harness-ui-compact--kind estimate kind)))
    (and (not (memq kind '(transcript fresh)))
         (or (plist-get k :model-label)
             (and (plist-get k :model) (harness-ui-model-label (plist-get k :model)))))))

(defun harness-ui-compact-describe (estimate kind)
  "Describe KIND of compaction as ESTIMATE says, in a sentence or two.
What it reads and how, and what it leaves out; not what it costs, which
goes beside it."
  (let* ((k (harness-ui-compact--kind estimate kind))
         (writer (harness-ui-compact--writer estimate kind)))
    (pcase kind
      ('brief
       (format (concat "%s reads only the first and last messages, ~%s tokens in all."
                       "  Most of the middle is left out, which the summary says.")
               (or writer "A cheap model")
               (harness-format-tokens (or (plist-get k :input) 0))))
      ('summary
       (format "%s reads the whole conversation again, ~%s tokens %s."
               (or writer "The session's model")
               (harness-format-tokens (or (plist-get k :input) (plist-get estimate :context) 0))
               (if (harness-json-true-p (plist-get k :cached)) "mostly from the cache" "uncached")))
      ('transcript
       (format (concat "The whole conversation goes to a file in the session's directory, and a"
                       " note of ~%s tokens tells the model to read what it needs of it."
                       "  No model is asked anything.")
               (harness-format-tokens (or (plist-get k :after) 100))))
      ('fresh
       (format (concat "Nothing of the conversation is carried over: the model starts afresh, with a"
                       " note of ~%s tokens saying so, and searches and reads the old conversation"
                       " with session_history when it needs to.  No model is asked anything.")
               (harness-format-tokens (or (plist-get k :after) 100))))
      (_ ""))))

(defun harness-ui-compact-carry-on-text (estimate)
  "Say what the next message costs if the conversation is not compacted.
ESTIMATE is what `compaction/estimate' returned.  Return nil when it
knows of no context to send."
  (let ((context (plist-get estimate :context))
        (cost (plist-get estimate :carry-on)))
    (when (and (numberp context) (> context 0))
      (format "the next message sends ~%s tokens %s%s"
              (harness-format-tokens context)
              (if (harness-json-true-p (plist-get estimate :cached)) "from the prompt cache" "uncached")
              (if (numberp cost) (format ", about %s" (harness-format-cost cost)) "")))))

;;;; Asking

(defun harness-ui-compact--choices (estimate)
  "Return the `read-multiple-choice' choices for ESTIMATE, cancel last."
  (append
   (mapcar (lambda (entry)
             (pcase-let* ((`(,kind ,key ,name ,description) entry)
                          (cost (harness-ui-compact-cost-text estimate kind)))
               (list key (if cost (format "%s (%s)" name cost) name) description)))
           harness-ui-compact-kinds)
   (list (list ?q "cancel" "keep the conversation as it is"))))

(defun harness-ui-compact-help (session estimate)
  "Return what to show before asking how to compact SESSION, as ESTIMATE says.
SESSION is the session's plist, as the UI knows it."
  (let ((name (plist-get session :name))
        (carry (harness-ui-compact-carry-on-text estimate)))
    (concat
     (propertize "COMPACT THE CONVERSATION" 'face 'bold) "\n\n"
     (harness-ui--handoff-table
      nil
      (delq nil
            (list (list "Session" (if (and (stringp name) (not (string-blank-p name)))
                                      (format "“%s”" name)
                                    (or (plist-get session :id) "")))
                  (list "Model" (or (plist-get estimate :model-label)
                                    (harness-ui-model-label (plist-get estimate :model))))
                  (and carry (list "Carry on" carry))))
      72)
     "\n\n"
     (harness-ui--handoff-table
      (list "KEY" "KIND" "BY" "COST" "WHAT IT DOES")
      (mapcar (lambda (entry)
                (let ((kind (car entry)))
                  (list (char-to-string (nth 1 entry))
                        (nth 2 entry)
                        (or (harness-ui-compact--writer estimate kind) "-")
                        (or (harness-ui-compact-cost-text estimate kind) "?")
                        (harness-ui-compact-describe estimate kind))))
              harness-ui-compact-kinds)
      52)
     "\n\nCosts are estimates at list prices.  After any of them the next message"
     "\nsends what stands in for the conversation, not the conversation.\n")))

(defun harness-ui-compact-read (session estimate)
  "Ask how to compact SESSION, a session plist, saying what ESTIMATE says.
Return a kind of `harness-ui-compact-kinds', or nil to cancel."
  (let ((answer (read-multiple-choice "Compact the conversation"
                                      (harness-ui-compact--choices estimate)
                                      (harness-ui-compact-help session estimate)
                                      "*Harness compaction*")))
    (car (cl-find (car answer) harness-ui-compact-kinds :key #'cadr))))

;;;; Compacting

(defun harness-ui-compact-running-p (session)
  "Non-nil while SESSION, a session plist, runs a turn or waits inside one."
  (member (format "%s" (plist-get session :status)) '("running" "blocked")))

(defun harness-ui-compact-outcome (node)
  "Say what the compaction NODE, as `compaction/compact' returned it, did."
  (let* ((meta (plist-get node :meta))
         (kind (format "%s" (or (plist-get meta :compaction) "summary")))
         (input (plist-get meta :input-tokens))
         (from (if (numberp input) (format "~%s tokens" (harness-format-tokens input)) "the conversation")))
    (pcase kind
      ("transcript"
       (format "Compacted %s into %s" from
               (let ((file (plist-get meta :file)))
                 (if (stringp file) (abbreviate-file-name file) "a transcript file"))))
      ("brief"
       (format "Compacted %s into a brief summary by %s" from
               (harness-ui-model-label (plist-get meta :model))))
      ("fresh"
       (format "Started afresh, leaving %s behind; session_history reaches it" from))
      (_ (format "Compacted %s into a summary" from)))))

(defun harness-ui-compact-doing (kind)
  "Say that compacting as KIND is under way: \"Compacting … into a summary…\"."
  (if (eq kind 'fresh)
      "Starting afresh…"
    (format "Compacting the conversation into a %s…"
            (or (nth 2 (assq kind harness-ui-compact-kinds)) kind))))

(defun harness-ui-compact-run (session-id kind &optional callback)
  "Compact SESSION-ID as KIND, saying how it went.
KIND is one of `harness-ui-compact-kinds'.  CALLBACK, if any, is called
once it is done with the compaction node, or with nil when it failed."
  (message "%s" (harness-ui-compact-doing kind))
  (harness-ui-call "_harness/compaction/compact"
                   (list :session-id session-id :opts (list :kind (symbol-name kind) :idle t))
                   (lambda (node)
                     (message "%s" (harness-ui-compact-outcome node))
                     (when callback (funcall callback node)))
                   (lambda (err)
                     (unless (harness-ui-connection-replaced-p err)
                       (message "Compaction failed: %s" (harness-error-message err)))
                     (when callback (funcall callback nil))
                     nil)))

(defun harness-ui-compact-parse-kind (text)
  "Return the kind TEXT names, by name or key, or nil when TEXT is empty.
Signal when it names none."
  (let ((text (string-trim (or text ""))))
    (unless (string-empty-p text)
      (or (car (cl-find-if (lambda (entry)
                             (member text (list (symbol-name (car entry)) (char-to-string (nth 1 entry)))))
                           harness-ui-compact-kinds))
          (user-error "No compaction kind %s: brief, summary, transcript or fresh" text)))))

(defun harness-ui-compact--session (session-id)
  "Return what the UI knows of SESSION-ID: the list's record, else its chat's."
  (or (harness-ui-session session-id)
      (and (equal (bound-and-true-p harness-ui-session-id) session-id)
           (bound-and-true-p harness-chat--session))
      (list :id session-id)))

;;;###autoload
(defun harness-compact (session-id &optional kind)
  "Compact the conversation of SESSION-ID now, as KIND, or as you choose.
KIND is `brief', `summary', `transcript' or `fresh'
\(`harness-ui-compact-kinds'); without it you are asked, with what each
costs at list prices and what carrying on costs.  A brief summary is
cheap however long the conversation, a summary reads all of it again,
a transcript and a fresh start ask no model.  The session's next
message then sends what stands in for the conversation, not the
conversation, and the model searches and reads the rest with the
session_history tool.  A session running a turn is not compacted.  In
a chat, /compact does this too, and /compact brief (or b, summary,
transcript, fresh) skips the question."
  (interactive (list (harness-ui-current-session-id)))
  (when (harness-ui-compact-running-p (harness-ui-compact--session session-id))
    (user-error "This session is running a turn: compact it once the turn is over"))
  (if kind
      (harness-ui-compact-run session-id kind)
    (let ((session (harness-ui-compact--session session-id)))
      (message "Working out what compacting costs…")
      (harness-ui-call "_harness/compaction/estimate" (list :session-id session-id)
                       (lambda (estimate)
                         (message nil)
                         (if (harness-json-true-p (plist-get estimate :compacting))
                             (message "This conversation is being compacted already")
                           (when-let* ((choice (harness-ui-compact-read session estimate)))
                             (harness-ui-compact-run session-id choice))))))))

(defun harness-ui-compact--chat-command (args)
  "Run /compact ARGS in a chat's message box: compact its session.
ARGS names the kind (`harness-ui-compact-parse-kind'), or is empty to ask."
  (harness-compact harness-ui-session-id (harness-ui-compact-parse-kind args)))

;;;; Setup

(defun harness-ui-compact--init ()
  "Bind `harness-compact', put it in the menu and take /compact in the chat."
  (define-key harness-ui-map (kbd "C") #'harness-compact)
  (ignore-errors
    (transient-append-suffix 'harness-menu "f" '("C" "Compact context" harness-compact)))
  (setf (alist-get "compact" harness-chat-commands nil nil #'equal) #'harness-ui-compact--chat-command))

(harness-define-module 'ui-compact
  :doc "Compact a session's conversation by hand, choosing the kind at a known cost."
  :requires '(ui ui-chat)
  :init #'harness-ui-compact--init)

(provide 'harness-ui-compact)
;;; harness-ui-compact.el ends here
