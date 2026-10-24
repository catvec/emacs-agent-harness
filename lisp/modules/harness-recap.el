;;; harness-recap.el --- Recap task cards and running chats with the model  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task's card shows a recap under its title: a short sentence, from a
;; model call, saying what the task is doing or has done so far (the
;; card's subtitle; see `harness-ui-tasks').  The board keeps it folded
;; away except where it matters most, on a task that needs your input.
;;
;; The recap is refreshed when the task has moved on enough: after
;; `harness-tasks-recap-turns' turns, `harness-tasks-recap-seconds'
;; seconds or `harness-tasks-recap-tool-calls' tool calls since the last
;; one, whichever comes first, like a warranty's months or miles.  The
;; counters and the time it was made are kept on the task record
;; (`:recap', `:recap-at', `:recap-turns', `:recap-tools'), so a reload
;; needs no history and the board shows the recap after a restart.
;;
;; Unlike naming (`harness-naming'), the request is self-contained: the
;; task, its plan and todos, and the tail of its transcript, not the
;; whole conversation.  That keeps it short, and it lets the request go
;; to the provider's simple tier (`harness-tasks-recap-model' `auto'),
;; which a fork of the session's own provider state could not.
;;
;; Checks run when a turn ends, after a tool result, and every
;; `harness-tasks-recap-interval' seconds while a turn runs, so the time
;; threshold fires even while the model is quiet.  A turn that ends
;; blocked is recapped at once, thresholds or not: that is when the card
;; shows the recap, in the needs-input column.  One request per session
;; is in flight at a time, and a failed one waits
;; `harness-tasks-recap-retry' seconds before the next try.
;;
;; A chat shows the recap too: while a turn runs, the line above the one
;; saying what it does (see `harness-ui-chat'), and, opened, the last few.
;; So every recap made for a session -- a card's, a sub-agent's, a
;; chat's -- is also added to the session's history, the newest
;; `harness-tasks-recap-history' of them in its `ext' as `:recaps'
;; (see "The recaps a session keeps").  The `ext' travels with the
;; session record, so every client has it and a restart keeps it, and a
;; redaction cleans it with the rest of the record.  A session that is
;; no task's gets its recaps while its turn runs, with the card's
;; thresholds counted from the start of the turn or the last recap
;; (`harness-tasks-recap-chats'); the recaps of a turn are dropped when
;; the next one begins, so a chat never shows the last turn's above this
;; one's.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

;; Settings of the tasks module (harness-tasks.el); a recap is a task
;; card's, so its knobs live with the other task settings.
(defvar harness-tasks-recap)
(defvar harness-tasks-recap-turns)
(defvar harness-tasks-recap-seconds)
(defvar harness-tasks-recap-tool-calls)
(defvar harness-tasks-recap-model)
(defvar harness-tasks-recap-thinking)
(defvar harness-tasks-recap-max-tokens)
(defvar harness-tasks-recap-max-length)
(defvar harness-tasks-recap-context)
(defvar harness-tasks-recap-interval)
(defvar harness-tasks-recap-retry)
(defvar harness-tasks-recap-chats)
(defvar harness-tasks-recap-history)

(defconst harness-recap--system-prompt
  "You write the progress recaps that coding agents' task cards show under their titles.  Write one short sentence, in plain words, saying what the task is doing or has done so far: concrete work and findings, not encouragement, not a question, not a plan.  No markdown, no quotes, no lists, no trailing period is needed."
  "System prompt of a recap request.")

(defconst harness-recap--ask
  "Recap this task now, in one short sentence."
  "Last line of a recap request.")

(defvar harness-recap--running (make-hash-table :test 'equal)
  "Session id -> promise of the recap request in flight.")

(defvar harness-recap--failed (make-hash-table :test 'equal)
  "Session id -> time a failed recap may be tried again.")

(defvar harness-recap--sessions (make-hash-table :test 'equal)
  "Session id -> the recap kept for a session that is no task's.
The value is (:recap TEXT :recap-at FLOAT :recap-turns N :recap-tools N
:started FLOAT), as a task's card keeps its own; see
`harness-recap-session'.")

(defvar harness-recap--session-running (make-hash-table :test 'equal)
  "Session id -> promise of the session recap request in flight.")

(defvar harness-recap--session-failed (make-hash-table :test 'equal)
  "Session id -> time a failed session recap may be tried again.")

(defvar harness-recap--runs (make-hash-table :test 'equal)
  "Session id -> where the thresholds of a running chat's recap count from.
The value is (:started FLOAT :at FLOAT :tools N): when the turn began,
when counting began -- the start of the turn, or the last recap, as
`harness-recap--chat-maybe' resets it -- and the tool calls finished
since.  Kept only while the turn runs.")

(defvar harness-recap--timer nil "Timer that checks recaps due on time.")

;;;; What the model is asked

(defun harness-recap--task (session-id)
  "Return the task worked on by SESSION-ID, or nil."
  (and (harness-method-exists-p 'task/for-session)
       (ignore-errors (harness-call 'task/for-session session-id))))

(defun harness-recap--eligible-p (task session)
  "Non-nil when the card of TASK may get a recap made from SESSION.
A backlog task and a write-up are skipped, and so is a done task:
their cards have nothing to recap."
  (and session
       (not (harness-json-true-p (plist-get task :backlog)))
       (not (memq (plist-get task :state) '(refining done)))
       ;; A pending task with a session is a backlog write-up.
       (not (eq (plist-get task :state) 'pending))))

(defun harness-recap--tools (session-id)
  "Return the number of tool calls in SESSION-ID's transcript."
  (let ((nodes (ignore-errors (harness-call 'session/nodes session-id))))
    (cl-count 'tool-call nodes :key (lambda (node) (plist-get node :kind)))))

(defun harness-recap--counts (session)
  "Return (TURNS TOOLS) of SESSION: the counters a recap is due by."
  (list (or (plist-get (plist-get session :usage) :turns) 0)
        (harness-recap--tools (plist-get session :id))))

(defun harness-recap--due-p (task turns tools now)
  "Non-nil when TASK's recap is due with TURNS, TOOLS and NOW.
Whichever comes first of the configured turns, seconds and tool calls
since the task's last recap, or since it started when it has none."
  (let* ((base-turns (or (plist-get task :recap-turns) 0))
         (base-tools (or (plist-get task :recap-tools) 0))
         (base-at (or (plist-get task :recap-at) (plist-get task :started)
                      (plist-get task :created) now)))
    (or (and (numberp harness-tasks-recap-turns) (> harness-tasks-recap-turns 0)
             (>= (- turns base-turns) harness-tasks-recap-turns))
        (and (numberp harness-tasks-recap-seconds) (> harness-tasks-recap-seconds 0)
             (>= (- now base-at) harness-tasks-recap-seconds))
        (and (numberp harness-tasks-recap-tool-calls) (> harness-tasks-recap-tool-calls 0)
             (>= (- tools base-tools) harness-tasks-recap-tool-calls)))))

(defun harness-recap--model (session)
  "Return the model a recap of SESSION asks."
  (let ((choice harness-tasks-recap-model)
        (model (plist-get session :model)))
    (cond ((eq choice 'auto)
           (or (and model (harness-method-exists-p 'provider/tier-model)
                    (ignore-errors (harness-call 'provider/tier-model model 'simple)))
               model))
          ((stringp choice) choice)
          (t model))))

(defun harness-recap--tail (session-id)
  "Return the tail of SESSION-ID's transcript, as long as a recap may carry."
  (let* ((text (or (ignore-errors (harness-call 'session/transcript-text session-id)) ""))
         (limit (or harness-tasks-recap-context 8000)))
    (if (or (<= limit 0) (<= (length text) limit))
        text
      (concat "…" (substring text (- (length text) limit))))))

(defun harness-recap--progress (task session)
  "Return the progress line of a recap request for TASK and SESSION.
TASK may carry its own, `:progress': a chat's, which says how long the
turn it recaps has run, not how many turns and tool calls the whole
session holds."
  (or (plist-get task :progress)
      (let* ((counts (harness-recap--counts session))
             (turns (car counts))
             (tools (cadr counts)))
        (format "Progress: %d turns, %d %s" turns tools
                (if (= tools 1) "tool call" "tool calls")))))

(defun harness-recap--prompt (task session)
  "Return the user text of a recap request for TASK and SESSION."
  (let* ((prompt (string-trim (or (plist-get task :prompt) "")))
         (prompt (if (> (length prompt) 600) (concat (substring prompt 0 600) "…") prompt))
         (todos (plist-get session :todos))
         (done (cl-count "done" todos :key (lambda (todo) (plist-get todo :status)) :test #'equal))
         (now (cl-find "in-progress" todos :key (lambda (todo) (plist-get todo :status)) :test #'equal))
         (plan (plist-get session :plan)))
    (string-join
     (delq nil
           (list (concat "Task: " prompt)
                 (harness-recap--progress task session)
                 (and (stringp plan) (not (string-blank-p plan))
                      (concat "Plan: " (harness-truncate-end (string-trim plan) 400)))
                 (and todos (format "Todos: %d/%d done" done (length todos)))
                 (and now (concat "Now: " (plist-get now :text)))
                 (let ((tail (harness-recap--tail (plist-get session :id))))
                   (and (not (string-blank-p tail))
                        (concat "Recent transcript (oldest first, newest last):\n" tail)))
                 harness-recap--ask))
     "\n\n")))

(defun harness-recap-sanitise (text)
  "Turn model output TEXT into a recap line, or nil when nothing is left.
Keeps the first non-blank line, strips markdown markers and a leading
\"Recap:\", collapses whitespace and truncates to
`harness-tasks-recap-max-length' characters."
  (let ((line (harness-first-line (or text ""))))
    (let ((case-fold-search t))
      (setq line (replace-regexp-in-string "\\`\\(?:recap\\|summary\\|status\\)[ \t]*:[ \t]*" "" line)))
    (setq line (replace-regexp-in-string "[*_`#>]+" "" line))
    (setq line (string-trim line "[][ \t\"'“”‘’(){}<>.,:;!?-]+" "[][ \t\"'“”‘’(){}<>.,:;!?-]+"))
    (setq line (replace-regexp-in-string "[ \t]+" " " line))
    (unless (string-empty-p line)
      (harness-truncate-end line (or harness-tasks-recap-max-length 160)))))

;;;; The recaps a session keeps

;; A task's card shows its latest recap, a sub-agent's note under the call
;; that shows it the same, and neither remembers the ones before.  A chat
;; wants more: the course of a long turn, the last few recaps in order.
;; So each recap made for a session is added to the history in its
;; `ext', `:recaps', a list of (:text TEXT :at FLOAT) of at most
;; `harness-tasks-recap-history' recaps, oldest first -- a value JSON
;; keeps as it is (`session/set-ext').  Setting it announces the session
;; as changed, which is how a chat hears of a new recap.

(defun harness-recap--history-limit ()
  "Return how many recaps a session keeps, at least 1.
That is `harness-tasks-recap-history'."
  (if (and (integerp harness-tasks-recap-history) (> harness-tasks-recap-history 0))
      harness-tasks-recap-history
    1))

(defun harness-recap-history (session-id)
  "Return the recaps kept for SESSION-ID, oldest first.
Each is a plist (:text TEXT :at FLOAT): the recap and when it was made.
Nil when the session has none or is gone.  They are what the chat of a
running turn shows (`harness-chat--recaps')."
  (when (and (harness-method-exists-p 'session/get) (harness-call 'session/exists-p session-id))
    (let ((records (plist-get (plist-get (harness-call 'session/get session-id) :ext) :recaps)))
      ;; One record alone may come back from a store as itself, not as a list of it.
      (when (keywordp (car-safe records)) (setq records (list records)))
      (when (or (listp records) (vectorp records))
        (cl-loop for record across (vconcat records)
                 for text = (and (consp record) (plist-get record :text))
                 when (and (stringp text) (not (harness-string-blank-p text)))
                 collect (list :text text :at (plist-get record :at)))))))

(defun harness-recap--remember (session-id text)
  "Add TEXT, a recap of SESSION-ID made now, to its history; return TEXT.
The history is a convenience the recap does not depend on: a failure to
keep it is logged, not signalled."
  (condition-case err
      (when (and (harness-method-exists-p 'session/set-ext)
                 (harness-call 'session/exists-p session-id))
        (harness-call 'session/set-ext session-id :recaps
                      (last (append (harness-recap-history session-id)
                                    (list (list :text text :at (float-time))))
                            (harness-recap--history-limit))))
    (error (harness-log 'warn "recap of %s could not be kept in its history: %s"
                        session-id (harness-error-short-message err))))
  text)

(defun harness-recap--forget (session-id)
  "Drop the recaps kept for SESSION-ID, if it has any.
A session that is no task's starts its next turn without the last one's
\(`harness-recap--on-turn-started'), so a chat never shows them above
the new turn's line."
  (condition-case err
      (when (and (harness-method-exists-p 'session/set-ext)
                 (harness-call 'session/exists-p session-id)
                 (plist-get (plist-get (harness-call 'session/get session-id) :ext) :recaps))
        (harness-call 'session/set-ext session-id :recaps nil))
    (error (harness-log 'warn "recaps of %s could not be dropped: %s"
                        session-id (harness-error-short-message err)))))

;;;; Making one

(defun harness-recap--finish (sid id counts good reason error)
  "Store the recap GOOD of task ID, or back off after a failure.
SID names the session, REASON and ERROR say why a failure failed.
COUNTS is the (TURNS TOOLS) the recap was made at.  Return GOOD, or
signal when it could not be stored."
  (remhash sid harness-recap--running)
  (if good
      (progn
        (harness-call 'task/set-recap id
                      :recap good :recap-at (float-time)
                      :recap-turns (car counts) :recap-tools (cadr counts))
        (harness-recap--remember sid good)
        (harness-emit 'recap/done sid good)
        good)
    (when (numberp harness-tasks-recap-retry)
      (puthash sid (+ (float-time) harness-tasks-recap-retry) harness-recap--failed))
    (harness-log 'warn "recap of %s failed: %s" id (or error reason))
    (harness-emit 'recap/failed sid (or error reason))
    nil))

(defun harness-recap--ask (session task on-done)
  "Ask the model for a recap of SESSION about TASK; call ON-DONE at its end.
The request is the one a card's recap is: `harness-recap--system-prompt'
and what `harness-recap--prompt' makes of TASK and SESSION, at most
`harness-tasks-recap-max-tokens' tokens, on the simple tier of
`harness-tasks-recap-model', with the thinking level of
`harness-tasks-recap-thinking'.  A recap is one short line, so a nil
level asks for no thinking (`:no-thinking'): a model whose thinking is
on by default would spend the whole budget on the reasoning and stop at
`max-tokens' with no line.  ON-DONE is called once, with RECAP (the
text the model wrote and `harness-recap-sanitise' accepted, nil when it
wrote none or failed), the provider's REASON for stopping and its ERROR
when it failed.  Return the promise of the call, which resolves to
RECAP, or rejects with why there is none."
  (let* ((text "")
         (settled nil)
         (promise (harness-make-promise))
         (finish (lambda (reason error)
                   (unless settled
                     (setq settled t)
                     (let ((recap (and (not (memq reason '(error cancelled)))
                                       (harness-recap-sanitise text))))
                       (if recap
                           (harness-resolve promise recap)
                         (harness-reject promise (or error (format "the model stopped: %s" reason))))
                       (condition-case err
                           (funcall on-done recap reason error)
                         (error (harness-log 'warn "recap of session %s could not be stored: %S"
                                             (plist-get session :id) err)))))))
         (request (append
                   (list :model (harness-recap--model session)
                         :session session
                         ;; Recorded as an internal session made for SESSION.
                         :job "Recap" :job-parent (plist-get session :id)
                         :system harness-recap--system-prompt
                         :messages (list (list :role 'user
                                               :content (list (list :type "text"
                                                                    :text (harness-recap--prompt task session)))))
                         :tools nil
                         :max-tokens harness-tasks-recap-max-tokens
                         ;; A recap is one short line: without a level of
                         ;; the user's, ask for no thinking (a model that
                         ;; thinks by default would spend the whole budget
                         ;; on the reasoning and stop at `max-tokens').
                         :no-thinking (null harness-tasks-recap-thinking)
                         :on-event
                         (lambda (ev)
                           (pcase (plist-get ev :type)
                             ('text (setq text (concat text (plist-get ev :delta))))
                             ('done (funcall finish (plist-get ev :stop-reason) (plist-get ev :error))))))
                   (and harness-tasks-recap-thinking
                        (list :thinking harness-tasks-recap-thinking)))))
    (condition-case err
        (harness-call 'provider/complete request)
      (error (funcall finish nil (harness-error-message err))))
    promise))

(defun harness-recap--start (task session)
  "Ask the model for a recap of TASK's session SESSION; return the promise."
  (let* ((sid (plist-get session :id))
         (id (plist-get task :id))
         (counts (harness-recap--counts session))
         (promise (harness-recap--ask
                   session task
                   (lambda (recap reason error)
                     (harness-recap--finish sid id counts recap reason error)))))
    (puthash sid promise harness-recap--running)
    promise))

(defun harness-recap--task-maybe (task session-id force)
  "Recap TASK, the task of SESSION-ID, when one is due; FORCE skips the thresholds.
Return the promise of a recap request just started, or nil."
  (unless (gethash session-id harness-recap--running)
    (let ((retry (gethash session-id harness-recap--failed)))
      (when (or (null retry) (>= (float-time) retry))
        (when-let* ((session (harness-call 'session/get session-id))
                    ((harness-recap--eligible-p task session))
                    (counts (harness-recap--counts session))
                    ((or force
                         (harness-recap--due-p task (car counts) (cadr counts) (float-time)))))
          (harness-recap--start task session))))))

(defun harness-recap--maybe (session-id &optional force)
  "Recap SESSION-ID when one is due; FORCE skips the thresholds.
A session that is a task's gets its card's recap.  Any other gets the
recap of its running turn (`harness-recap--chat-maybe'), never forced:
a turn that ended has no line to show one.  Return the promise of a
recap request just started, or nil."
  (when (and harness-tasks-recap
             (harness-call 'session/exists-p session-id))
    (if-let* ((task (harness-recap--task session-id)))
        (harness-recap--task-maybe task session-id force)
      (unless force
        (harness-recap--chat-maybe session-id)))))

;;;; Recaps of a session that is no task's

;; A call that shows a session -- a sub-agent's, or one a session_wait
;; waits on -- shows a recap of it, as a card does.  A session that is a
;; task's gives its card's recap; a sub-agent's has no card, so one is
;; written here with the same short model call and kept per session,
;; refreshed when the thresholds say it is stale.  Nothing polls: the
;; tools that show a session ask again when an event about it arrives
;; (`harness-tools-watch-session'), and a request just made announces
;; `recap/session-done'.

(defun harness-recap--session-own-p (session)
  "Non-nil when a recap of SESSION may be written here.
Only a sub-agent's: another session's recap is shown when a task card
or an earlier request keeps one, but writing it is the task module's
business."
  (eq (plist-get session :kind) 'subagent))

(defun harness-recap--session-prompt (session-id &optional session)
  "Return the prompt-like text of SESSION-ID's work, for a recap request.
For a sub-agent, SESSION being its plist, that is the newest user
message another session sent it, which is what its prompt is, else its
first user message.  For any other session it is the newest user
message, the one the running turn answers: a long turn has pushed it far
back in the transcript, out of the tail a request carries.  The whole
transcript is looked through, once per recap."
  (let* ((nodes (ignore-errors (harness-call 'session/nodes session-id)))
         (users (cl-remove-if-not (lambda (node) (eq (plist-get node :kind) 'user)) nodes))
         (chosen (if (eq (plist-get session :kind) 'subagent)
                     (cl-find-if #'harness-node-sender (reverse users))
                   (car (last users))))
         (text (plist-get chosen :content)))
    (if (and (stringp text) (not (harness-string-blank-p text)))
        text
      (or (plist-get (car users) :content) ""))))

(defun harness-recap--finish-session (sid counts good reason error)
  "Keep the session recap GOOD of SID, or back off after a failure.
COUNTS is the (TURNS TOOLS) it was made at; REASON and ERROR say why a
failure failed.  Return GOOD, or nil."
  (remhash sid harness-recap--session-running)
  (if good
      (let ((old (gethash sid harness-recap--sessions)))
        (puthash sid (list :recap good :recap-at (float-time)
                           :recap-turns (car counts) :recap-tools (cadr counts)
                           :started (or (plist-get old :started) (float-time)))
                 harness-recap--sessions)
        (harness-recap--remember sid good)
        (harness-emit 'recap/session-done sid good)
        good)
    (when (numberp harness-tasks-recap-retry)
      (puthash sid (+ (float-time) harness-tasks-recap-retry) harness-recap--session-failed))
    (harness-log 'warn "recap of session %s failed: %s" sid (or error reason))
    (harness-emit 'recap/session-failed sid (or error reason))
    nil))

(defun harness-recap--restart-count (session-id)
  "Count the thresholds of SESSION-ID's running turn from now, if it is counted.
A recap is being made of everything up to now (`harness-recap--runs'),
whichever way it was asked for: the next is due after the seconds and
tool calls that come after it."
  (when-let* ((run (gethash session-id harness-recap--runs)))
    (puthash session-id (list :started (plist-get run :started) :at (float-time) :tools 0)
             harness-recap--runs)))

(defun harness-recap--start-session (session &optional progress)
  "Ask the model for a recap of SESSION and keep it per session.
PROGRESS, a line, replaces the one that counts the session's turns and
tool calls (`harness-recap--progress').  Return the promise (see
`harness-recap-session')."
  (let* ((sid (plist-get session :id))
         (counts (harness-recap--counts session))
         (promise (harness-recap--ask
                   session (list :prompt (harness-recap--session-prompt sid session)
                                 :progress progress)
                   (lambda (recap reason error)
                     (harness-recap--finish-session sid counts recap reason error)))))
    (puthash sid promise harness-recap--session-running)
    (harness-recap--restart-count sid)
    promise))

(defun harness-recap--session-due-p (session-id session now)
  "Non-nil when a session recap of SESSION-ID is due.
The task thresholds apply as they do to a card, from the recap in hand
or from when the session started."
  (let* ((record (or (gethash session-id harness-recap--sessions)
                     (list :started (or (plist-get session :created) now))))
         (counts (harness-recap--counts session)))
    (harness-recap--due-p record (car counts) (cadr counts) now)))

(defun harness-recap--session-maybe (session-id session force)
  "Start a recap request for SESSION-ID when one is due and it may get one.
FORCE skips the thresholds, but never recaps an internal session, the
record of one model call (see `session/internal-start'): there is
nothing to recap there.  Return the promise of a request just started,
or nil."
  (when (and (not (gethash session-id harness-recap--session-running))
             (not (equal (format "%s" (plist-get session :kind)) "internal"))
             (or force (harness-recap--session-own-p session)))
    (let ((retry (gethash session-id harness-recap--session-failed)))
      (when (and (or (null retry) (>= (float-time) retry))
                 (or force (harness-recap--session-due-p session-id session (float-time))))
        (harness-recap--start-session session)))))

(defun harness-recap-session (session-id &optional force)
  "Return a recap of SESSION-ID to show, making one when it is due.
The value is a plist (:text TEXT :at FLOAT): the recap and when it was
made.  A session that is a task's gives its card's recap; another's
gives the recap kept for it, written here with the same short model
call a card's is (the simple tier, at most
`harness-tasks-recap-max-tokens' tokens) and refreshed when
`harness-tasks-recap-turns', `harness-tasks-recap-seconds' or
`harness-tasks-recap-tool-calls' say it is stale, or when FORCE is
non-nil.  Only a sub-agent's session is recapped here: one that is a
task's is its card's business, and a recap is not written for any
other session, though one already kept for it is shown.  The recap in
hand, if any, is returned while a new one is made, and nil while there
is nothing to show yet."
  (when (and harness-tasks-recap (harness-call 'session/exists-p session-id))
    (let* ((session (harness-call 'session/get session-id))
           (task (harness-recap--task session-id))
           (task-recap (and task (plist-get task :recap))))
      (if (and (stringp task-recap) (not (harness-string-blank-p task-recap)))
          (list :text task-recap :at (plist-get task :recap-at))
        (harness-recap--session-maybe session-id session force)
        (let* ((record (gethash session-id harness-recap--sessions))
               (text (plist-get record :recap)))
          (and (stringp text) (not (harness-string-blank-p text))
               (list :text text :at (plist-get record :recap-at))))))))

;;;; Recaps of a running chat

;; A chat shows the recap above the line saying what its turn does, and
;; the last few with it opened, so a long turn can be followed
;; (`harness-ui-chat').  A task's card is recapped as the task works;
;; any other session -- a conversation, a fork, a sub-agent -- is
;; recapped here, while its turn runs and not after: a turn that ended
;; has no such line.  The thresholds are the card's, but counted from
;; the start of the turn or the last recap, not from the start of the
;; session: a conversation that sat for a day is not due a recap the
;; moment you write to it.  `harness-recap--runs' holds where counting
;; began and the tool calls since, from `agent/turn-started' to the end
;; of the turn.  The same request, tier and limits as a card's
;; (`harness-recap--ask'), and the same back-off after a failure.

(defun harness-recap--chat-p (session)
  "Non-nil when SESSION, a plist, may get recaps as its turn runs.
An internal session, the record of one model call, has nothing to
recap, and nor has a seed conversation, a prompt cache."
  (and harness-tasks-recap-chats
       (not (equal (format "%s" (plist-get session :kind)) "internal"))
       (not (harness-json-true-p (plist-get (plist-get session :ext) :seed)))))

(defun harness-recap--chat-due-p (run now)
  "Non-nil when a running chat's recap is due at NOW, RUN being its record.
The seconds and tool calls of the card's thresholds (`harness-recap--due-p')
since RUN's `:at', which the turns do not apply to: a turn is one."
  (harness-recap--due-p (list :recap-at (plist-get run :at) :recap-turns 0 :recap-tools 0)
                        0 (or (plist-get run :tools) 0) now))

(defun harness-recap--chat-progress (run now)
  "Return the progress line of a request for a chat's recap, RUN being its record."
  (format "Progress: the current turn has been running for %s"
          (harness-format-duration (max 0 (- now (or (plist-get run :started) now))))))

(defun harness-recap--chat-maybe (session-id)
  "Recap SESSION-ID, a session that is no task's, when its running turn is due.
Counting begins anew as the request starts (`harness-recap--restart-count'):
what comes after is not in it.  Return the promise of a request just
started, or nil."
  (if (not (harness-call 'agent/running session-id))
      (ignore (remhash session-id harness-recap--runs))
    (when-let* (((not (gethash session-id harness-recap--session-running)))
                (session (harness-call 'session/get session-id))
                ((harness-recap--chat-p session)))
      (let* ((now (float-time))
             (retry (gethash session-id harness-recap--session-failed))
             ;; A turn that began before the module loaded counts from now.
             (run (or (gethash session-id harness-recap--runs)
                      (puthash session-id (list :started now :at now :tools 0)
                               harness-recap--runs))))
        (when (and (or (null retry) (>= now retry))
                   (harness-recap--chat-due-p run now))
          (harness-recap--start-session session (harness-recap--chat-progress run now)))))))

(defun harness-recap--count-tool (session-id)
  "Count a tool call finished in the running turn of SESSION-ID, a chat's."
  (when-let* ((run (gethash session-id harness-recap--runs)))
    (puthash session-id (plist-put (copy-sequence run) :tools (1+ (or (plist-get run :tools) 0)))
             harness-recap--runs)))

;;;; Checks

(defun harness-recap--on-turn-started (session-id)
  "Begin the recaps of SESSION-ID's turn, when it is no task's.
Counting starts now, and the recaps kept from the last turn go: they
tell of that one, and the chat showing this one's would show them above
its first.  A task keeps its recaps: its card's is the work so far."
  (remhash session-id harness-recap--runs)
  (when (and (harness-call 'session/exists-p session-id)
             (not (harness-recap--task session-id)))
    (let ((now (float-time)))
      (puthash session-id (list :started now :at now :tools 0) harness-recap--runs))
    (harness-recap--forget session-id)))

(defun harness-recap--on-turn-ended (session-id reason)
  "Recap SESSION-ID's task when its turn ended.
A turn that stopped for the user, or on an error (REASON `blocked',
`cancelled' or `error'), is recapped at once: its card needs the recap
then, whatever the thresholds say.  A chat's recap is of its running
turn, so nothing is counted any more."
  (remhash session-id harness-recap--runs)
  (harness-recap--maybe session-id (memq reason '(blocked error cancelled))))

(defun harness-recap--on-tool-result (session-id &rest _)
  "Recap SESSION-ID when a tool call of its turn finished.
That is its task's card, or, for a session that is no task's, its turn's recap."
  (harness-recap--count-tool session-id)
  (harness-recap--maybe session-id))

(defun harness-recap--check-running ()
  "Recap every running session, task or not, whose recap is due on time."
  (when (harness-method-exists-p 'agent/running)
    (dolist (session-id (harness-call 'agent/running))
      (harness-recap--maybe session-id))))

;;;; Init and reload

(defun harness-recap--start-timer ()
  "Start checking the time threshold every `harness-tasks-recap-interval'."
  (when (timerp harness-recap--timer) (cancel-timer harness-recap--timer))
  (setq harness-recap--timer
        (and (boundp 'harness-tasks-recap-interval)
             (numberp harness-tasks-recap-interval) (> harness-tasks-recap-interval 0)
             (run-with-timer harness-tasks-recap-interval harness-tasks-recap-interval
                             #'harness-recap--check-running))))

(defun harness-recap--shutdown ()
  "Stop checking recaps due on time, and stop listening to turns and tool calls."
  (when (timerp harness-recap--timer) (cancel-timer harness-recap--timer))
  (setq harness-recap--timer nil)
  (harness-off (cons 'agent/turn-started #'harness-recap--on-turn-started))
  (harness-off (cons 'agent/turn-ended #'harness-recap--on-turn-ended))
  (harness-off (cons 'agent/tool-result #'harness-recap--on-tool-result)))

(defun harness-recap--init ()
  "Subscribe recaps to turns and tool calls, and start the timer.
The turn-ended check runs before the tasks module's: a task that just
finished is still active there, so its last recap is made even when
the task itself goes straight to done."
  (harness-on 'agent/turn-started #'harness-recap--on-turn-started)
  (harness-on 'agent/turn-ended #'harness-recap--on-turn-ended 40)
  (harness-on 'agent/tool-result #'harness-recap--on-tool-result)
  (harness-recap--start-timer))

(harness-declare-event 'recap/done "(SESSION-ID RECAP) after a task card's recap was stored.")
(harness-declare-event 'recap/failed "(SESSION-ID MESSAGE) when a recap could not be made.")
(harness-declare-event 'recap/session-done
  "(SESSION-ID RECAP) after the recap of a session that is no task's was kept (see `harness-recap-session').")
(harness-declare-event 'recap/session-failed
  "(SESSION-ID MESSAGE) when the recap of a session that is no task's could not be made.")

(harness-define-module 'recap
  :doc "Write the recaps task cards and running chats show, with a short model call."
  :requires '(session provider agent tasks)
  :init #'harness-recap--init
  :shutdown #'harness-recap--shutdown)

(provide 'harness-recap)
;;; harness-recap.el ends here
