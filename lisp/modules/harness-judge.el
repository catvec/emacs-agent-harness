;;; harness-judge.el --- One-off questions to a cheap model, with lookups  -*- lexical-binding: t; -*-

;;; Commentary:

;; A judge is a one-off question to the simple tier of a session's
;; model, whose short reply the caller reads as a decision: emacs_eval
;; (tools-emacs-eval) asks one whether code returns at once before it
;; runs the code in the user's Emacs, and an event watch (tools-events)
;; asks one what an event that came in means for the session watching
;; it.  A judge is asked as the auto-mode permission judge is
;; (lisp/modules/harness-perms.el): `:ephemeral' requests, which bring
;; no earlier conversation and keep none, without thinking, with a
;; small output budget.
;;
;; `harness-judge-ask' asks one and returns a promise of its answer,
;; which never rejects: the value the caller's parser found in the
;; reply, or why there is none (no model, a failed request, a reply
;; without a value, no answer in time).  A reply its output budget cut
;; off before it held a value is asked for once more, with a larger
;; budget.  `harness-judge-model' says which model a judge asks.
;;
;; A judge may be given tools to look things up before it answers:
;; emacs_eval's judge looks up the functions and variables the code
;; uses that it does not know, as the user's Emacs has them.  Lookups
;; only read.  They run here as plain functions, outside the permission
;; chain and every session's chat, and a judge makes a few at most
;; (`:max-lookups'): a call past that budget, or of a tool the judge was
;; not given, gets an error result that tells it so, and runs nothing.
;; Both kinds of provider loop work:
;;
;; - A provider that runs the tool loop itself (Claude Code, Copilot)
;;   reports each call with a `:respond' function: the result goes back
;;   through it, and the same request goes on.  A judge that keeps
;;   calling past its budget there is stopped.
;; - A provider that stops at `tool-use' (the OpenAI-compatible APIs,
;;   Bedrock) is asked again, with the calls and their results added to
;;   the conversation as a session's transcript adds them
;;   (lisp/modules/harness-session.el).  A judge still asking after one
;;   round more than its budget gets no further.
;;
;; The module keeps no state and starts nothing.  Its callers `require'
;; it, and do not list `judge' among their modules' requirements, so
;; that each of them loads on its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-model)

(defconst harness-judge-lookup-max-chars 4000
  "Most characters of a lookup's result a judge reads.
A longer result is cut there, and says so: a judge answers in a line,
and reading more costs it time and tokens it has little of.")

(defconst harness-judge--extra-calls 2
  "Calls past its budget a judge on a hosted loop makes before it is stopped.
Each of them gets an error result telling the judge to answer; a judge
that goes on calling is cancelled, and gives no value.")

(defconst harness-judge--no-more-lookups
  "No more lookups: you have made all this question allows. Answer now with what you know."
  "What a judge is told of a call past its budget of lookups.")

;;;; The model

(defun harness-judge--session (session)
  "Return SESSION as a record: SESSION itself, or the record of the id SESSION.
A session that `session/get' does not know is a record with its id alone."
  (if (stringp session)
      (or (and (harness-method-exists-p 'session/get)
               (ignore-errors (harness-call 'session/get session)))
          (list :id session))
    session))

(defun harness-judge--config (key session)
  "Return config KEY for SESSION's directory.
That is through `config/get' when there is one, else KEY's value."
  (let ((cwd (or (plist-get session :cwd) default-directory)))
    (or (and (harness-method-exists-p 'config/get)
             (ignore-errors (harness-call 'config/get key cwd)))
        (and (boundp key) (symbol-value key)))))

(defun harness-judge-model (session &optional model)
  "Return the model a judge for SESSION asks, or nil when no model is known.
That is the simple tier of MODEL's provider (`provider/tier-model'), or
MODEL itself when its provider names none.  MODEL defaults to SESSION's
`:model', else to `harness-model' as configured for SESSION's
directory.  SESSION is a session's record, as `session/get' gives it,
or its id."
  (let* ((session (harness-judge--session session))
         (model (or model
                    (plist-get session :model)
                    (harness-judge--config 'harness-model session))))
    (and (stringp model)
         (or (and (harness-method-exists-p 'provider/tier-model)
                  (ignore-errors (harness-call 'provider/tier-model model 'simple)))
             model))))

;;;; Lookups

(defun harness-judge--spec (tool)
  "Return the spec of TOOL a provider is sent: its name, description and schema."
  (list :name (plist-get tool :name)
        :description (or (plist-get tool :description) "")
        :schema (or (plist-get tool :schema) '(:type "object" :properties :empty))))

(defun harness-judge--reason (err)
  "Return the message of ERR, a rejection or an error, for a judge to read.
An error whose data is just a message gives that message."
  (if (and (consp err) (symbolp (car err)) (stringp (cadr err)) (null (cddr err)))
      (cadr err)
    (harness-error-message err)))

(defun harness-judge--result (value)
  "Return VALUE, what a lookup gave, as a tool result.
That is (:content TEXT :is-error BOOL).  A result plist keeps its
content and its error flag; a string is the content of a result that
worked, nil an empty one, and anything else its printed form.  Content
longer than `harness-judge-lookup-max-chars' is cut there."
  (let* ((result-p (and (consp value) (ignore-errors (plist-member value :content)) t))
         (content (if result-p (plist-get value :content) value))
         (text (cond ((stringp content) content)
                     ((null content) "")
                     (t (format "%S" content)))))
    (list :content (if (> (length text) harness-judge-lookup-max-chars)
                       (format "%s\n[cut at %d characters]"
                               (substring text 0 harness-judge-lookup-max-chars)
                               harness-judge-lookup-max-chars)
                     text)
          :is-error (and result-p (harness-json-true-p (plist-get value :is-error)) t))))

(defun harness-judge--run (tool input)
  "Run the lookup TOOL with INPUT; return a promise of its result.
The promise never rejects: a handler that signals, or whose promise
rejects, gives an error result that says why."
  (let ((failed (lambda (err)
                  (list :content (format "The lookup failed: %s" (harness-judge--reason err))
                        :is-error t))))
    (condition-case err
        (harness-then (harness-as-promise (funcall (plist-get tool :handler) input))
                      #'harness-judge--result
                      failed)
      (error (harness-resolved (funcall failed err))))))

;;;; Asking

(defun harness-judge--no-value (event text)
  "Return why a judge's request gave no value.
The request ended with EVENT, its `done', having replied TEXT."
  (let ((err (plist-get event :error)))
    (cond (err (format "it failed: %s" (harness-truncate-end (harness-error-message err) 200)))
          ((not (eq (plist-get event :stop-reason) 'end-turn))
           (format "it stopped: %s" (plist-get event :stop-reason)))
          ((harness-string-blank-p text) "it gave no answer")
          (t (format "its answer held no verdict: %s" (harness-truncate-end (string-trim text) 200))))))

(defun harness-judge--parse (parse text label)
  "Return the value PARSE finds in TEXT, a judge's reply, or nil.
Without PARSE the value is TEXT trimmed, when it is not blank.  A PARSE
that signals finds nothing, and is logged under LABEL."
  (if parse
      (condition-case err
          (funcall parse text)
        (error (harness-log 'warn "%s: reading its reply failed: %s" label (harness-error-message err))
               nil))
    (and (stringp text) (not (harness-string-blank-p text)) (string-trim text))))

(cl-defun harness-judge-ask (&key session model system prompt tools (max-lookups 0)
                                  (max-tokens 200) retry-max-tokens (timeout 30)
                                  parse label (suffix "judge"))
  "Ask a judge PROMPT; return a promise of its answer, which never rejects.
A judge is a one-off question to a cheap model, whose reply PARSE, a
function of the reply's text, reads.  The answer is
\(:value V :text TEXT :lookups N) when PARSE returns a non-nil V
\(without PARSE, V is the reply itself, trimmed, when not blank), else
\(:value nil :reason WHY :text TEXT :lookups N).  WHY is \"no model
could be asked\", \"it failed: ...\", \"it stopped: ...\", \"it gave no
answer\", \"its answer held no verdict: ...\", \"it kept asking for
lookups past its budget of N\" or \"it took longer than Ns\".  TEXT is
the reply PARSE read, which is what the judge wrote after its last
lookup; N is how many lookups ran.

SESSION is the session the judge is for, as a record (as `session/get'
gives it) or an id.  It names the model, with MODEL (see
`harness-judge-model'), and the place: each request is made as the
session \"ID-SUFFIX\" in SESSION's directory, on its host.  A request
is `provider/complete' with `:ephemeral' and `:no-thinking', SYSTEM as
its system prompt and PROMPT as the user's message, for at most
MAX-TOKENS of output.  A reply that request's budget cut off before it
held a value is asked for once more with RETRY-MAX-TOKENS, when that is
given.  A judge that has not answered within TIMEOUT seconds, lookups
and retry included, gives no value, and its request is cancelled.

TOOLS are lookups the judge may make before it answers, at most
MAX-LOOKUPS calls in all; they are offered only when both are given.
Each is a plist (:name :description :schema :handler): the first three
are what the model is shown, and HANDLER is a function of a call's
input that returns a tool result (:content TEXT :is-error BOOL), a
string, or a promise of either.  A handler that signals, or whose
promise rejects, gives an error result, and content longer than
`harness-judge-lookup-max-chars' is cut.  A call past the budget, or
of a name not among TOOLS, gets an error result and runs nothing.
LABEL names the judge in the log, as \"emacs_eval judge\" (\"judge\"
by default)."
  (let* ((session (harness-judge--session session))
         (label (or label "judge"))
         (timeout (or timeout 30))
         (max-lookups (if (natnump max-lookups) max-lookups 0))
         (model (harness-judge-model session model))
         (lookups (and (> max-lookups 0) tools))
         (specs (mapcar #'harness-judge--spec lookups))
         (names (mapconcat (lambda (tool) (plist-get tool :name)) lookups ", "))
         (question (list (list :role 'user
                               :content (list (list :type "text" :text (or prompt ""))))))
         (result (harness-make-promise))
         (settled nil) (timer nil) (handle nil)
         ;; The serial of the live request: only its events count.
         (live 0) (ended nil)
         ;; Its reply after the last lookup, its thinking, and the calls
         ;; a native loop asked for in it.
         (text "") (thinking "") (pending nil)
         ;; Calls made, every one, and lookups that ran.
         (calls 0) (ran 0)
         (retried nil))
    (cl-labels
        ((finish (answer)
           (unless settled
             (setq settled t)
             (when timer (cancel-timer timer))
             (harness-resolve result (append answer (list :text text :lookups ran)))))
         (fail (why)
           (unless settled
             (harness-log 'warn "%s: no answer: %s" label why)
             (finish (list :value nil :reason why))))
         (stop (why)
           ;; Gives up, cancelling the live request.
           (let ((live-handle handle))
             (fail why)
             (when live-handle (ignore-errors (funcall (plist-get live-handle :cancel))))))
         (call (name input)
           ;; Decides a call, in the order calls come, and runs it when
           ;; it may run; a promise of its result.
           (cl-incf calls)
           (let ((tool (cl-find name lookups :key (lambda (tool) (plist-get tool :name)) :test #'equal)))
             (cond
              ((> calls max-lookups)
               (harness-resolved (list :content harness-judge--no-more-lookups :is-error t)))
              ((not tool)
               (harness-resolved
                (list :content (if lookups
                                   (format "There is no lookup named %s; the lookups are %s." name names)
                                 (format "There is no lookup named %s." name))
                      :is-error t)))
              (t
               (cl-incf ran)
               (harness-log 'debug "%s: looks up %s %S" label name input)
               (harness-judge--run tool input)))))
         (hosted (ev respond)
           (if (>= calls (+ max-lookups harness-judge--extra-calls))
               (progn
                 (ignore-errors (funcall respond (list :content harness-judge--no-more-lookups :is-error t)))
                 (stop (format "it kept asking for lookups past its budget of %d" max-lookups)))
             ;; What it writes from here on is its answer.
             (setq text "")
             (harness-then (call (plist-get ev :name) (plist-get ev :input))
                           (lambda (r) (ignore-errors (funcall respond r)) nil))))
         (next (messages round budget round-calls round-text round-thinking)
           ;; A native loop's next round: the calls ROUND asked for run,
           ;; and the model is asked again with them and their results.
           (let* ((round-calls (mapcar (lambda (c)
                                         (plist-put (copy-sequence c) :id
                                                    (or (plist-get c :id)
                                                        (concat "judge_" (harness-short-id 12)))))
                                       round-calls))
                  (results (mapcar (lambda (c) (call (plist-get c :name) (plist-get c :input)))
                                   round-calls)))
             (harness-then
              (harness-all results)
              (lambda (results)
                (unless settled
                  (ask (append
                        messages
                        (list (list :role 'assistant
                                    :content (append
                                              (unless (harness-string-blank-p round-thinking)
                                                (list (list :type "thinking" :text round-thinking)))
                                              (unless (harness-string-blank-p round-text)
                                                (list (list :type "text" :text round-text)))
                                              (mapcar (lambda (c)
                                                        (list :type "tool_use" :id (plist-get c :id)
                                                              :name (plist-get c :name)
                                                              :input (or (plist-get c :input) :empty)))
                                                      round-calls)))
                              (list :role 'user
                                    :content (cl-mapcar (lambda (c r)
                                                          (list :type "tool_result" :tool_use_id (plist-get c :id)
                                                                :content (plist-get r :content)
                                                                :is_error (and (plist-get r :is-error) t)))
                                                        round-calls results))))
                       (1+ round) budget))
                nil))))
         (done (ev messages round budget)
           (let ((stop-reason (plist-get ev :stop-reason))
                 (round-calls (reverse pending)))
             (setq handle nil ended live pending nil)
             (if (and (eq stop-reason 'tool-use) round-calls lookups)
                 ;; A native loop asks for lookups.
                 (if (> round max-lookups)
                     (fail (format "it kept asking for lookups past its budget of %d" max-lookups))
                   (next messages round budget round-calls text thinking))
               (let ((value (harness-judge--parse parse text label)))
                 (cond
                  (value (finish (list :value value)))
                  ((and (eq stop-reason 'max-tokens) retry-max-tokens (not retried))
                   (setq retried t)
                   (harness-log 'info "%s: ran out of output tokens; asking once more" label)
                   (ask messages round retry-max-tokens))
                  (t (fail (harness-judge--no-value ev text))))))))
         (ask (messages round budget)
           (let ((serial (cl-incf live)))
             (setq text "" thinking "" pending nil)
             (condition-case err
                 (let ((h (harness-call
                           'provider/complete
                           (list :model model
                                 ;; One question, alone: no earlier turns,
                                 ;; no project instructions.
                                 :ephemeral t
                                 :session (list :id (format "%s-%s" (plist-get session :id) suffix)
                                                :cwd (plist-get session :cwd) :host (plist-get session :host))
                                 :system system
                                 :messages messages
                                 :tools specs
                                 ;; Thinking would spend the output first.
                                 :no-thinking t
                                 :max-tokens budget
                                 :on-event
                                 (lambda (ev)
                                   (let ((respond (plist-get ev :respond)))
                                     (if (or settled (/= serial live))
                                         ;; A hosted loop still asking a judge
                                         ;; that is over is told so.
                                         (when (and respond (eq (plist-get ev :type) 'tool-call))
                                           (ignore-errors
                                             (funcall respond (list :content "This question is over."
                                                                    :is-error t))))
                                       (pcase (plist-get ev :type)
                                         ('text (setq text (concat text (or (plist-get ev :delta) ""))))
                                         ('thinking (setq thinking (concat thinking (or (plist-get ev :delta) ""))))
                                         ('tool-call
                                          (cond ((plist-get ev :builtin)
                                                 ;; The provider's own tool, which a
                                                 ;; judge is never offered: not a lookup.
                                                 nil)
                                                (respond (hosted ev respond))
                                                (t (push (list :id (plist-get ev :id) :name (plist-get ev :name)
                                                               :input (plist-get ev :input))
                                                         pending))))
                                         ('done (done ev messages round budget))))))))))
                   ;; Unless it ended already, or another took its place.
                   (when (and (= serial live) (not (eql ended serial)) (not settled))
                     (setq handle h)))
               (error
                (fail (format "it failed: %s" (harness-truncate-end (harness-error-message err) 200))))))))
      (cond
       ((not (and model (harness-method-exists-p 'provider/complete)))
        (fail "no model could be asked"))
       (t
        (setq timer (run-at-time timeout nil
                                 (lambda () (stop (format "it took longer than %ss" timeout)))))
        (ask question 1 max-tokens))))
    result))

(harness-define-module 'judge
  :doc "Judges: one-off questions to the simple tier of a session's model, read as a decision, with a few lookups that only read (emacs_eval's speed judge, event watches).")

(provide 'harness-judge)
;;; harness-judge.el ends here
