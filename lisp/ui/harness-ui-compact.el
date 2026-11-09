;;; harness-ui-compact.el --- Compacting a conversation by hand, at a known cost  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation that nears its model's context window is compacted on
;; its own, as `harness-compaction-kind' says (harness-compaction.el).
;; This file compacts one by hand, and says first what each way costs
;; (`compaction/estimate'), at list prices:
;;
;; - a summary: the session's model summarises the whole conversation on
;;   a request that starts as the conversation's next step would, so the
;;   conversation is read from the prompt cache while that lasts
;;   (harness-compaction.el);
;; - a transcript file: the whole conversation goes to a file in the
;;   session's directory, and a note tells the model to read what it
;;   needs of it.  No request;
;; - a fresh start: nothing is carried over but a note saying so.  No
;;   request either.
;;
;; A brief summary -- a cheap model reads the narrative, which no cache
;; of the conversation covers -- is a handoff's way of carrying a
;; conversation to another provider (`compact-new'), and a cut old
;; context is what an automatic compaction falls back to; neither is one
;; this question offers.  `/compact brief` or `/compact truncate` still
;; makes either by name.
;;
;; `harness-compact' (C under the harness prefix and in its menu, or
;; /compact in a chat's message box) asks one flat list, the same the
;; automation asks (`harness-carry-menu'): Summary, Transcript,
;; Fresh start and Continuation.  The Summary is shown, no cache, where
;; the prompt cache does not hold its request, and says what it costs
;; where it does; the ways that ask no model are always offered.  The
;; panel a session shows once its prompt cache expired
;; (harness-ui-cache.el) is the same table less the answers about a
;; waiting message: a summary row, no cache, and the two buttons.
;; That is when carrying on is dearest, the whole context going out
;; uncached.  A message sent to such a session asks the same before it
;; goes (harness-cowboy.el, harness-ui-cowboy.el).  A session running a
;; turn is asked whether to interrupt the step and compact now, or to
;; queue the compaction for the turn's next boundary
;; (`harness-ui-compact-running-choice`): compacting it mid-step would
;; let the turn go on writing after the conversation it replaces.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
;; The menu the question offers is the one both questions share.
(require 'harness-carry)
(require 'harness-ui)

(defvar harness-chat-commands)
(defvar harness-chat--session)

(defconst harness-ui-compact-kinds
  '((brief ?b "brief"
           "narrative · no tool payloads")
    (summary ?s "summary"
             "context · model-written")
    (transcript ?t "transcript"
                "whole conversation · file · no request")
    (fresh ?f "fresh start"
           "nothing kept · session_history · no request")
    (truncate ?c "context cut"
              "oldest dropped · newest kept · no request"))
  "The kinds of compaction the harness knows, the cheap one first.
Each entry is (KIND KEY NAME DESCRIPTION): KIND a kind of
`compaction/compact', KEY the key that picks it on the command line,
NAME what it is called and DESCRIPTION one line on what it does.  The
question offers a summary and the ways that ask no model; a brief
summary is a handoff's, which reads the conversation uncached.")

;;;; What each kind costs

(defun harness-ui-compact-label (kind)
  "Return the name of KIND as a label, first letter up: \"Brief\"."
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

(defun harness-ui-compact-cost-text (estimate kind &optional session)
  "Return what KIND of compaction costs as ESTIMATE says, short: \"~$0.02\".
A transcript, a fresh start and a cut old context, which ask no model,
are \"free\"; a kind whose model the catalogue does not price is nil.
For SESSION, a session plist a plan pays for, the cost reads as a share of
the plan's quota (\"~0.2%\"; `harness-ui-format-estimate')."
  (let ((cost (harness-ui-compact-cost estimate kind)))
    (cond ((memq kind '(transcript fresh truncate)) "free")
          (cost (harness-ui-format-estimate cost session)))))

(defun harness-ui-compact--writer (estimate kind)
  "Return the label of the model that would write KIND, as ESTIMATE says, or nil."
  (let ((k (harness-ui-compact--kind estimate kind)))
    (and (not (memq kind '(transcript fresh truncate)))
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
       (string-join
        (delq nil (list (or writer "simple model") "narrative"
                        (format "~%s tokens" (harness-format-tokens (or (plist-get k :input) 0)))
                        "no tool payloads"))
        " · "))
      ('summary
       (string-join
        (delq nil (list (or writer "session model") "context"
                        (format "~%s tokens" (harness-format-tokens
                                                (or (plist-get k :input)
                                                    (plist-get estimate :context) 0)))
                        (if (harness-json-true-p (plist-get k :cached)) "cached" "uncached")))
        " · "))
      ('transcript
       (format "file · ~%s tokens note · no request"
               (harness-format-tokens (or (plist-get k :after) 100))))
      ('fresh
       (format "fresh · ~%s tokens note · session_history · no request"
               (harness-format-tokens (or (plist-get k :after) 100))))
      ('truncate
       (let ((dropped (or (plist-get k :dropped) 0)))
         (if (zerop dropped)
             "nothing cut · fits window · no request"
           (format "%d nodes dropped · ~%s tokens kept · no request"
                   dropped (harness-format-tokens (or (plist-get k :kept-tokens) 0))))))
      (_ ""))))

(defun harness-ui-compact-carry-on-text (estimate &optional session)
  "Say what the next message costs if the conversation is not compacted.
ESTIMATE is what `compaction/estimate' returned, SESSION the session
plist whose plan words the cost (`harness-ui-estimate-text').  Return nil
when it knows of no context to send."
  (let ((context (plist-get estimate :context))
        (cost (plist-get estimate :carry-on)))
    (when (and (numberp context) (> context 0))
      (string-join
       (delq nil (list (format "~%s tokens" (harness-format-tokens context))
                       (if (harness-json-true-p (plist-get estimate :cached)) "cached" "uncached")
                       (and (numberp cost) (harness-ui-estimate-text cost session))))
       " · "))))

;;;; Asking

(defconst harness-ui-compact-cache-kinds '(summary transcript fresh)
  "The ways the panel of a session whose prompt cache is cold offers.
It is the menu of both questions (`harness-carry-menu-ways'), less the
two answers about a waiting message, which that panel has none of: the
summary, shown not offered because a cold cache holds none of its
request, and the two ways that ask no model.")

(defun harness-ui-compact-clear-label (kind)
  "Return the label of KIND, a way the cache panel offers."
  (harness-carry-label kind))

(defun harness-ui-compact-clear-what (kind)
  "Return what KIND does, in a few words, as the menu words it."
  (or (harness-carry-property kind :what)
      (harness-ui-compact-describe nil kind)))

(defun harness-ui-compact-available-p (estimate kind)
  "Non-nil when KIND can be made as ESTIMATE prices it.
A summary says in its estimate whether its own request reads the prompt
cache (`:available'); the kinds that ask no model always can."
  (pcase kind
    ((or 'summary 'brief)
     (and (harness-json-true-p
           (plist-get (harness-ui-compact--kind estimate kind) :available))
          t))
    (_ t)))

(defun harness-ui-compact--session-line (session estimate)
  "Return the lines naming SESSION and what ESTIMATE says of carrying on.
They are what every page of the question shows first."
  (let ((name (plist-get session :name))
        (carry (harness-ui-compact-carry-on-text estimate session)))
    (delq nil
          (list (format "Session · %s"
                        (if (and (stringp name) (not (string-blank-p name)))
                            (format "“%s”" name)
                          (or (plist-get session :id) "")))
                (format "Model · %s" (or (plist-get estimate :model-label)
                                          (harness-ui-model-label (plist-get estimate :model))))
                (format "Cache · %s"
                        (if (harness-json-true-p (plist-get estimate :cached)) "warm" "cold"))
                (and carry (format "Continuation · %s" carry))))))

(defun harness-ui-compact--page-help (title lines)
  "Return the help of the compaction question.
TITLE heads it and LINES are its facts, one a line."
  (concat
   (propertize title 'face 'bold) "\n\n"
   (mapconcat (lambda (line) (concat line "\n")) (delq nil lines) "")))

(defun harness-ui-compact--ask (prompt choices help)
  "Ask the one page of the compaction question: PROMPT, CHOICES and HELP.
Return the key of the choice picked."
  (car (read-multiple-choice prompt choices help "*Harness compaction*")))

(defun harness-ui-compact--choice-name (choice)
  "Return what CHOICE is called in the question: its label and its cost."
  (let ((cost (plist-get choice :cost-text)))
    (concat (plist-get choice :label)
            (if cost (format " (%s)" cost) ""))))

(defun harness-ui-compact-read (session estimate)
  "Ask how to compact SESSION, a session plist, saying what ESTIMATE says.
Return a kind of `harness-ui-compact-kinds' -- `summary', `transcript'
or `fresh' -- or nil to carry on with the conversation as it is.  It is
one page, the same list the automatic question asks
\(`harness-carry-menu'): Summary, Transcript, Fresh start and
Continuation.  A summary whose own request the prompt cache does not hold
is shown, not offered, and choosing it says so and asks again."
  (let* ((menu (harness-carry-menu estimate))
         (asked (cl-remove-if (lambda (choice)
                                (equal (plist-get choice :choice) "hold"))
                              menu))
         (choices (mapcar (lambda (choice)
                            (list (aref (plist-get choice :key) 0)
                                  (harness-ui-compact--choice-name choice)
                                  (plist-get choice :what)))
                          asked))
         (unavailable (cl-find-if (lambda (choice) (plist-get choice :unavailable)) menu))
         (key (harness-ui-compact--ask
               "Options" choices
               (harness-ui-compact--page-help
                "Compaction"
                (append (harness-ui-compact--session-line session estimate)
                        (when unavailable
                          (list (format "%s · no cache"
                                        (plist-get unavailable :label))))))))
         (choice (cl-find key asked :key (lambda (c) (aref (plist-get c :key) 0)))))
    (cond
     ((null choice) nil)
     ((plist-get choice :unavailable)
      (message "%s" (format "%s · no cache"
                            (plist-get choice :label)))
      (harness-ui-compact-read session estimate))
     ((equal (plist-get choice :choice) "carry-on") nil)
     (t (intern (plist-get choice :choice))))))

;;;; Compacting

(defun harness-ui-compact-running-p (session)
  "Non-nil while SESSION, a session plist, runs a turn or waits inside one.
A session blocked between turns, waiting for the user's reply, runs
none, and compacts as one at rest
\(`harness-session-blocked-on-request-p')."
  (or (equal (format "%s" (plist-get session :status)) "running")
      (harness-session-blocked-on-request-p session)))

(defconst harness-ui-compact-running-choices
  '((?i "interruption" "step cancellation · compaction now")
    (?q "queue" "next step · turn end")
    (?c "cancellation" "turn cancellation"))
  "The choices offered when compacting a session that runs a turn.")

(defun harness-ui-compact-running-choice (session)
  "Ask how to compact SESSION, which is running a turn.
Return `interrupt', `queue', or `cancel'.  Compacting a running
session mid-step would let its turn go on writing after the
conversation it replaces: it is interrupted first, or the compaction
waits for the turn's next boundary."
  (let ((answer (read-multiple-choice
                 (format "Compaction · %s · running"
                         (or (let ((name (plist-get session :name)))
                               (and (stringp name) (not (string-blank-p name)) (format "“%s”" name)))
                             "session"))
                 harness-ui-compact-running-choices)))
    (pcase (car answer) (?i 'interrupt) (?q 'queue) (_ 'cancel))))

(defun harness-ui-compact-outcome (node)
  "Say what the compaction NODE, as `compaction/compact' returned it, did."
  (let* ((meta (plist-get node :meta))
         (kind (format "%s" (or (plist-get meta :compaction) "summary")))
         (input (plist-get meta :input-tokens))
         (from (if (numberp input) (format "~%s tokens" (harness-format-tokens input)) "conversation")))
    (pcase kind
      ("transcript"
       (format "Compaction · %s · transcript · %s" from
               (let ((file (plist-get meta :file)))
                 (if (stringp file) (abbreviate-file-name file) "file"))))
      ("brief"
       (format "Compaction · %s · brief · %s" from
               (harness-ui-model-label (plist-get meta :model))))
      ("fresh"
       (format "Fresh start · %s" from))
      ("truncate"
       (format "Context cut · %s" from))
      (_ (format "Compaction · %s · summary" from)))))

(defun harness-ui-compact-doing (kind)
  "Say that compacting as KIND is under way: \"Compaction · summary\"."
  (pcase kind
    ('fresh "Fresh start")
    ('truncate "Context cut")
    (_ (format "Compaction · %s"
               (or (nth 2 (assq kind harness-ui-compact-kinds)) kind)))))

(defun harness-ui-compact-run (session-id kind &optional callback mode)
  "Compact SESSION-ID as KIND, saying how it went.
KIND is one of `harness-ui-compact-kinds'.  MODE is how to treat a
session that is running a turn, as `harness-ui-compact-running-choice'
answers: nil compacts now and refuses a running turn (`:idle'), `queue'
leaves the turn running and compacts at its next boundary, and
`interrupt' cancels the turn first.  CALLBACK, if any, is called once
it is settled -- with the queued result, the compaction node, or nil on
failure."
  (message "%s" (harness-ui-compact-doing kind))
  (harness-ui-call "_harness/compaction/compact"
                   (list :session-id session-id
                         :opts (append (list :kind (symbol-name kind)
                                             ;; A summary whose own request
                                             ;; is not cached is written to a
                                             ;; transcript, not refused.
                                             :fallback "transcript")
                                       (pcase mode
                                         ('queue (list :queue t))
                                         ('interrupt (list :interrupt t))
                                         (_ (list :idle t)))))
                   (lambda (result)
                     (if (harness-json-true-p (plist-get result :queued))
                         (message "%s" (if (harness-json-true-p (plist-get result :interrupt))
                                           "Compaction · queue · interruption"
                                         "Compaction · queue · next boundary"))
                       (message "%s" (harness-ui-compact-outcome result)))
                     (when callback (funcall callback result)))
                   (lambda (err)
                     (unless (harness-ui-connection-replaced-p err)
                       ;; Short: the error can name a whole transcript as
                       ;; its data, and this goes to *Messages*.
                       (message "Compaction failure · %s" (harness-error-short-message err)))
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
          (user-error "unknown compaction kind · %s" text)))))

(defun harness-ui-compact--session (session-id)
  "Return what the UI knows of SESSION-ID: the list's record, else its chat's."
  (or (harness-ui-session session-id)
      (and (equal (bound-and-true-p harness-ui-session-id) session-id)
           (bound-and-true-p harness-chat--session))
      (list :id session-id)))

;;;###autoload
(defun harness-compact (session-id &optional kind)
  "Compact the conversation of SESSION-ID, as KIND, or as you choose.
KIND is `brief', `summary', `transcript', `fresh' or `truncate'
\(`harness-ui-compact-kinds'); without it you are asked, in one list,
with what each costs at list prices and what carrying on costs.  The
question is the one the automatic compaction asks
\(`harness-carry-menu'): Summary, Transcript, Fresh start and
Continuation.  A summary reads the conversation from the prompt cache while
that lasts, and is offered only then; a transcript and a fresh start ask
no model.  The session's next message then sends what stands in for the
conversation, not the conversation, and the model searches and reads the
rest with the session_history tool.

A session running a turn is asked how: interrupt the step and compact
now (the turn is cancelled, and what it was doing is dropped), or
queue the compaction for the turn's next boundary, when the turn goes
on with the compacted conversation.  In a chat, /compact does this
too, and /compact brief (or b, summary, transcript, fresh, truncate)
skips the question."
  (interactive (list (harness-ui-current-session-id)))
  (let* ((session (harness-ui-compact--session session-id))
         (mode (if (harness-ui-compact-running-p session)
                   (harness-ui-compact-running-choice session)
                 'now)))
    (unless (eq mode 'cancel)
      (harness-ui-compact--choose session-id kind mode))))

(defun harness-ui-compact--choose (session-id kind mode)
  "Compact SESSION-ID as KIND, asking which kind when KIND is nil.
MODE is how to treat a running turn (see `harness-ui-compact-run')."
  (if kind
      (harness-ui-compact-run session-id kind nil mode)
    (let ((session (harness-ui-compact--session session-id)))
      (message "Compaction estimate")
      (harness-ui-call "_harness/compaction/estimate" (list :session-id session-id)
                       (lambda (estimate)
                         (message nil)
                         (if (harness-json-true-p (plist-get estimate :compacting))
                             (message "Compaction · running")
                           (when-let* ((kind (harness-ui-compact-read session estimate)))
                             (harness-ui-compact-run session-id kind nil mode))))))))

(defun harness-ui-compact--chat-command (args)
  "Run /compact ARGS in a chat's message box: compact its session.
ARGS names the kind (`harness-ui-compact-parse-kind'), or is empty to ask."
  (harness-compact harness-ui-session-id (harness-ui-compact-parse-kind args)))

;;;; Setup

(defun harness-ui-compact--init ()
  "Bind `harness-compact', put it in the menu and take /compact in the chat."
  (define-key harness-ui-map (kbd "C") #'harness-compact)
  (condition-case err
      (transient-append-suffix 'harness-menu "f" '("C" "Context compaction" harness-compact))
    (error (harness-log 'warn "compact: no menu entry: %s" (error-message-string err))))
  (setf (alist-get "compact" harness-chat-commands nil nil #'equal) #'harness-ui-compact--chat-command))

(harness-define-module 'ui-compact
  :doc "Compact a session's conversation by hand, at a known cost."
  :requires '(ui ui-chat)
  :init #'harness-ui-compact--init)

(provide 'harness-ui-compact)
;;; harness-ui-compact.el ends here
