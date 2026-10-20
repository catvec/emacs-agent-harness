;;; harness-resilience.el --- Keep sessions going through restarts, unanswered prompts and stalls  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Sessions and sub-agents should never sit stalled unless the user
;; stopped them on purpose.  Three things used to leave them so, each
;; until somebody noticed and typed "continue":
;;
;; - The harness process stopping in the middle of their turns: it
;;   crashed, was killed, or the machine went down.  The next start
;;   closes such a turn -- its tool calls get results saying they were
;;   interrupted, a hint says so -- and leaves the session inactive (see
;;   `session/interrupted').  Task mode carries its own tasks on; this
;;   module carries the rest on: each session whose turn a stop cut short
;;   gets a message of the harness's naming the calls that did not
;;   finish, and goes on (`harness-resilience-resume-interrupted').  A
;;   turn the user cancelled is not the harness's doing: `agent/cancelling'
;;   marks the session, until its next turn starts, and a marked session
;;   is left stopped.  How many times in a row a session is carried on is
;;   bounded (`harness-resilience--resume-max').  A session that was
;;   waiting, its turn over, for work the stop took with it -- a
;;   `session_wait', an event watch -- is woken to look for itself, and a
;;   sub-agent nothing carries on is reported to its parent
;;   (`harness-tools-agent-settle-adopted'), so no parent waits for a
;;   report that cannot come.  What other modules start themselves --
;;   tasks, a supervisor's workers, the merge queue's conflict
;;   resolvers, seeds -- they carry on themselves.
;;
;; - A sub-agent waiting on a permission prompt or a question nobody
;;   answers.  Its parent waits for its report, and the whole tree with
;;   it.  After `harness-resilience-prompt-timeout' seconds the prompt
;;   is answered by default -- a permission denied, a question told to
;;   decide alone -- and the parent and the user are told.
;;
;; - A running turn that makes no progress: a model stream that never
;;   ends, a call that never returns.  A watchdog notices a turn that
;;   has done nothing for `harness-resilience--stall-after' seconds,
;;   longer when a tool call may legitimately take longer, says so in
;;   the session, emits `resilience/stalled' and notifies the user.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(declare-function harness-tools-agent-settle-adopted "harness-tools-agent" (&optional reasons))

;;;; Options

(defcustom harness-resilience-resume-interrupted t
  "Non-nil carries on the sessions a stopped harness cut short.
When the harness process stops in the middle of a turn -- it crashed,
was killed, or the machine went down -- the next start closes the turn
and, with this on, sends the session a message of the harness's naming
the tool calls that did not finish, so that it goes on by itself.  A
turn the user cancelled is never carried on, and neither is a session
already carried on three times in a row with no turn ending normally
between (`harness-resilience--resume-max').  Tasks follow
`harness-tasks-resume-interrupted' instead.  Nil leaves every such
session stopped, with a hint saying what happened."
  :type 'boolean :group 'harness)

(defvar harness-resilience--resume-max 3
  "Most times in a row the harness carries one session on after it stopped.
Internal, not an option (see docs/configuration-audit.md).  Counted per
session across restarts, and reset when one of its turns ends normally:
a session whose turns keep being cut short -- or that keeps taking the
harness down -- is left stopped after that many, with a hint saying
why, and the user is notified.")

(defcustom harness-resilience-prompt-timeout 600
  "Seconds a sub-agent's permission prompt or question waits for an answer.
After that it is answered by default -- a permission is denied, a
question is told to decide for itself -- and the sub-agent's parent and
the user are told, rather than leaving the parent, and everything above
it, waiting for a report that cannot come.  Nil waits for the user
however long it takes.  The user's own sessions, tasks included, always
wait for the user."
  :type '(choice (const :tag "Wait for the user" nil) (number :tag "Seconds"))
  :group 'harness)

(defvar harness-resilience--stall-after 900
  "Seconds a running turn may make no progress before the user is told.
Internal, not an option (tests shorten it; nil turns the watchdog off).
Progress is anything the turn does: the model streaming, a step
starting, a tool call starting, ending or reporting progress, a prompt
being asked or answered.  A tool call may run as long as its own timeout
allows, and a minute more, without counting as a stall.  A stalled
turn gets a hint, `resilience/stalled' is emitted and the user is
notified, once until it moves again.")

(defvar harness-resilience--tick-seconds 30
  "Seconds between two checks for stalled turns and unanswered prompts.")

;;;; State

(defvar harness-resilience--progress (make-hash-table :test 'equal)
  "Session id -> when its running turn last made progress, a `float-time'.")

(defvar harness-resilience--stalled (make-hash-table :test 'equal)
  "Session id -> when its running turn was reported stalled.
Dropped as soon as it makes progress again, or its turn ends.")

(defvar harness-resilience--defaulted (make-hash-table :test 'equal)
  "Pending request id -> t, once it was answered by default.
A request whose default answer failed is not tried again each tick.")

(defvar harness-resilience--timer nil
  "The repeating timer of the watchdog and the prompt timeout.")

;; Keys of a session's `ext' this module keeps there, in the record, so
;; that they outlive the harness process:
;;
;; `:resilience-cancelled' t from the moment a turn of the session is
;;   cancelled (`agent/cancelling') until its next turn starts: its turn
;;   is the user's to restart, never the harness's.
;; `:resilience-resumes' how many times in a row the harness carried the
;;   session on after a restart; dropped by a turn that ends normally.
;; `:resilience-awaiting' what the session waited for when its last turn
;;   ended (`agent/outstanding'), until its next turn starts.

;;;; Helpers

(defun harness-resilience--session (id)
  "Return the plist of session ID, or nil when there is none."
  (and (stringp id)
       (harness-call 'session/exists-p id)
       (harness-call 'session/get id)))

(defun harness-resilience--ext (session key)
  "Return KEY of the `ext' of SESSION, a plist."
  (plist-get (plist-get session :ext) key))

(defun harness-resilience--set-ext (id key value)
  "Set KEY of the `ext' of session ID to VALUE, unless it holds it already."
  (let ((session (harness-resilience--session id)))
    (when (and session (not (equal (harness-resilience--ext session key) value)))
      (harness-call 'session/set-ext id key value))))

(defun harness-resilience--name (session)
  "Return how messages name SESSION, a plist."
  (let ((name (plist-get session :name))
        (id (plist-get session :id)))
    (if (and (stringp name) (not (harness-string-blank-p name)))
        name
      (substring id 0 (min 8 (length id))))))

(defun harness-resilience--span (seconds)
  "Return SECONDS as words: \"12 minutes\", \"1 hour 5 minutes\"."
  (let* ((minutes (max 1 (round seconds 60)))
         (hours (/ minutes 60))
         (minutes (% minutes 60))
         (plural (lambda (n unit) (format "%d %s%s" n unit (if (= n 1) "" "s")))))
    (cond ((zerop hours) (funcall plural minutes "minute"))
          ((zerop minutes) (funcall plural hours "hour"))
          (t (concat (funcall plural hours "hour") " " (funcall plural minutes "minute"))))))

(defun harness-resilience--notify (session title body &optional urgency kind)
  "Tell the user TITLE and BODY about SESSION, a plist, in a notification.
URGENCY is low, normal (the default) or critical, KIND what it is about.
It goes through the notifications module when it runs, else straight to
the UI, else to the log."
  (let ((urgency (or urgency 'normal))
        (kind (or kind "resilience")))
    (cond
     ((harness-method-exists-p 'notification/send)
      (harness-catch (harness-call-async 'notification/send
                                         (list :title title :body body :urgency urgency
                                               :source "resilience" :kind kind
                                               :session (plist-get session :id)
                                               :project (plist-get session :project)))
                     (lambda (err) (harness-log 'warn "resilience: notifying failed: %s"
                                                (harness-error-message err)))))
     ((harness-method-exists-p 'client/request)
      (harness-catch (harness-call-async 'client/request "_harness/client/notify"
                                         (list :id (concat "n-" (harness-short-id)) :title title :body body
                                               :urgency (symbol-name urgency) :source "resilience"
                                               :kind kind :session (plist-get session :id)))
                     (lambda (err) (harness-log 'info "resilience: no UI showed %S: %s"
                                                title (harness-error-message err)))))
     (t (harness-log 'warn "resilience: %s: %s" title body)))))

(defun harness-resilience--owner (session)
  "Return what carries SESSION, a plist, on after a restart, if not this module.
That is a text naming it, or nil when it is this module's to carry on:
the user's own sessions and spawn_agent's sub-agents.  An internal
session records one model call and is never continued; a task's session
is task mode's (`harness-tasks-resume-interrupted'); any other
sub-agent -- a supervisor's worker, the merge queue's resolver, a seed
-- is the module's that started it."
  (let ((id (plist-get session :id)))
    (cond ((eq (plist-get session :kind) 'internal) "it is internal")
          ((and (harness-method-exists-p 'task/for-session) (harness-call 'task/for-session id))
           "task mode")
          ((and (eq (plist-get session :kind) 'subagent)
                (not (harness-resilience--ext session :report-to)))
           "the module that started it"))))

;;;; Carrying on after a restart

(defun harness-resilience--resume-text (item)
  "Return the message that carries on ITEM, as `session/interrupted' lists it."
  (let* ((calls (plist-get item :calls))
         (names (delete-dups (delq nil (mapcar (lambda (c) (plist-get c :tool)) calls))))
         (pending (car (plist-get item :pending)))
         (kind (and pending (format "%s" (plist-get pending :kind))))
         (payload (plist-get pending :payload)))
    (concat
     "The harness restarted and cut your last turn short. "
     (when names
       (format "%s did not finish and returned no result: check what %s did before you run %s again. "
               (if (cdr calls)
                   (format "These tool calls (%s)" (string-join names ", "))
                 (format "Your %s call" (car names)))
               (if (cdr calls) "they" "it")
               (if (cdr calls) "them" "it")))
     (pcase kind
       ("permission" (format "You were waiting for permission to run %s: ask again if you still need it. "
                             (or (plist-get payload :title) (plist-get payload :tool) "a tool call")))
       ("question" "You were waiting for an answer to a question: ask it again if you still need it. ")
       (_ ""))
     "Check where you left off and carry on.")))

(defun harness-resilience--may-resume (session)
  "Return nil when SESSION, a plist, may be carried on; else why not, a text.
A session the user cancelled stays stopped; so does one the harness
already carried on `harness-resilience--resume-max' times in a row."
  (let ((count (or (harness-resilience--ext session :resilience-resumes) 0)))
    (cond ((not harness-resilience-resume-interrupted) "harness-resilience-resume-interrupted is off")
          ((harness-resilience--ext session :resilience-cancelled) "its turn was cancelled")
          ((and (numberp count) (>= count (or harness-resilience--resume-max 0)))
           ;; Each time it was carried on, and once before that.
           (format "the harness stopped during its turn %d times in a row" (1+ count))))))

(defun harness-resilience--carry-on (session text)
  "Send TEXT, a message of the harness's, to SESSION, a plist, and count it.
Return non-nil when it went out."
  (let* ((id (plist-get session :id))
         (count (or (harness-resilience--ext session :resilience-resumes) 0)))
    (harness-call 'session/set-ext id :resilience-resumes (1+ (if (numberp count) count 0)))
    (harness-catch (harness-call-async 'agent/prompt id text
                                       (list :from (harness-sender-system "restart")))
                   (lambda (err)
                     (harness-log 'warn "resilience: carrying %s on failed: %s"
                                  id (harness-error-message err))))
    t))

(defun harness-resilience--left-stopped (session why)
  "Say in SESSION, a plist, that it was left stopped after the restart, and WHY.
The user is notified unless it was they who stopped it."
  (let ((id (plist-get session :id)))
    (harness-log 'info "resilience: leaving %s stopped after the restart: %s" id why)
    (unless (or (harness-resilience--ext session :resilience-cancelled)
                (not harness-resilience-resume-interrupted))
      (harness-call 'session/hint id (format "Not carried on after the restart: %s. Send a message to carry on." why))
      (harness-resilience--notify session (format "Left stopped: %s" (harness-resilience--name session))
                                  (format "The harness restarted during its turn and did not carry it on: %s." why)
                                  'normal "left-stopped"))))

(defun harness-resilience--resume-interrupted (item)
  "Carry on the session ITEM names, as `session/interrupted' lists it.
Return non-nil when it was carried on."
  (let* ((id (plist-get item :id))
         (session (harness-resilience--session id)))
    (when (and session (not (harness-call 'agent/running id)))
      (let ((owner (harness-resilience--owner session)))
        (if owner
            (progn (harness-log 'info "resilience: %s is carried on by %s" id owner) nil)
          (let ((why (harness-resilience--may-resume session)))
            (if why
                (progn (harness-resilience--left-stopped session why) nil)
              (harness-log 'info "resilience: carrying %s on after the restart" id)
              (harness-resilience--carry-on session (harness-resilience--resume-text item)))))))))

(defun harness-resilience--wake-text (awaiting)
  "Return the message that wakes a session that waited for AWAITING."
  (format (concat "The harness restarted while you waited for work to finish (%s). "
                  "What you registered to be woken by -- a session_wait, an event watch -- "
                  "did not survive the restart, so that wake-up will not come. "
                  "Check on the work yourself and carry on.")
          awaiting))

(defun harness-resilience--wake-waiters (skip)
  "Wake the sessions whose waits a stopped harness took with it.
A session whose turn ended while work it waited for went on (see
`agent/outstanding') noted what (`:resilience-awaiting'); when nothing
of that runs in this process any more, nothing would ever wake it.
SKIP lists the ids of the sessions carried on already.  Return the ids
woken."
  (let (woken)
    (dolist (session (harness-call 'session/list))
      (let ((id (plist-get session :id))
            (awaiting (harness-resilience--ext session :resilience-awaiting)))
        (when (and (stringp awaiting)
                   (not (member id skip))
                   (not (harness-call 'agent/running id))
                   (not (harness-resilience--owner session))
                   (not (harness-call 'agent/outstanding id)))
          (let ((why (harness-resilience--may-resume session)))
            (if why
                (harness-resilience--left-stopped session why)
              (harness-log 'info "resilience: waking %s, whose wait the restart took (%s)" id awaiting)
              (harness-resilience--carry-on session (harness-resilience--wake-text awaiting))
              (push id woken))))))
    woken))

(defun harness-resilience--recover ()
  "Carry on what the stopped harness before this one left cut short.
Runs once, soon after a start, not after a reload: the sessions
`session/interrupted' lists, the sessions whose waits were lost, then
the sub-agents left with nothing to run, which report to their parents."
  (when (harness-module-ready-p 'resilience)
    (let* ((interrupted (and (harness-method-exists-p 'session/interrupted)
                             (harness-call 'session/interrupted)))
           (ids (mapcar (lambda (item) (plist-get item :id)) interrupted))
           resumed)
      (dolist (item interrupted)
        (harness-ignore-errors-logged (format "resilience: carrying %s on" (plist-get item :id))
          (when (harness-resilience--resume-interrupted item)
            (push (plist-get item :id) resumed))))
      (harness-ignore-errors-logged "resilience: waking the sessions whose waits were lost"
        (setq resumed (append (harness-resilience--wake-waiters ids) resumed)))
      (when (and (fboundp 'harness-tools-agent-settle-adopted) (harness-module-ready-p 'tools-agent))
        (harness-ignore-errors-logged "resilience: reporting the sub-agents taken back"
          (harness-tools-agent-settle-adopted
           (mapcar (lambda (id)
                     (cons id (if (harness-resilience--ext (harness-resilience--session id) :resilience-cancelled)
                                  'cancelled
                                'interrupted)))
                   ids))))
      (harness-emit 'resilience/recovered (nreverse resumed)))))

;;;; Marks

(defun harness-resilience--on-cancelling (session-id)
  "Mark SESSION-ID as stopped by a cancel: no restart carries its turn on."
  (harness-ignore-errors-logged "resilience: marking a cancelled turn"
    (harness-resilience--set-ext session-id :resilience-cancelled t)))

(defun harness-resilience--on-turn-started (session-id)
  "Start the watchdog's clock for SESSION-ID, and drop the marks of its last turn."
  (harness-resilience--note session-id)
  (harness-ignore-errors-logged "resilience: a turn started"
    (harness-resilience--set-ext session-id :resilience-cancelled nil)
    (harness-resilience--set-ext session-id :resilience-awaiting nil)))

(defun harness-resilience--on-turn-ended (session-id reason)
  "Stop watching SESSION-ID, whose turn ended with REASON; note its waits.
What it waits for once its turn is over (`agent/outstanding') goes to
`:resilience-awaiting'.  A turn that ended normally resets how many
times in a row the harness carried the session on."
  (remhash session-id harness-resilience--progress)
  (remhash session-id harness-resilience--stalled)
  (harness-ignore-errors-logged "resilience: a turn ended"
    (when (harness-call 'session/exists-p session-id)
      (when (eq reason 'end-turn)
        (harness-resilience--set-ext session-id :resilience-resumes nil))
      (harness-resilience--set-ext session-id :resilience-awaiting
                                   (and (harness-method-exists-p 'agent/outstanding)
                                        (harness-call 'agent/outstanding session-id))))))

;;;; Unanswered prompts of sub-agents

(defun harness-resilience--parent (session)
  "Return the id of the session SESSION, a sub-agent's plist, works for."
  (or (plist-get (harness-resilience--ext session :report-to) :parent)
      (plist-get session :parent-id)))

(defun harness-resilience--what (item)
  "Return what the pending request ITEM asks for, in words."
  (let ((payload (plist-get item :payload)))
    (if (equal (format "%s" (plist-get item :kind)) "question")
        (format "an answer to the question \"%s\"" (harness-first-line (or (plist-get payload :question) "") 150))
      (format "permission to run %s" (or (plist-get payload :title) (plist-get payload :tool) "a tool call")))))

(defun harness-resilience--answer (session item waited)
  "Answer ITEM, a request SESSION waited on for WAITED (words), by default.
A permission is denied, for this call alone; a question of ask_user's
is told to decide alone; a question the harness asked is dismissed.
Return what became of it, in words, or nil when nothing could answer."
  (let ((id (plist-get session :id))
        (pid (plist-get item :id))
        (payload (plist-get item :payload)))
    (pcase (format "%s" (plist-get item :kind))
      ("permission"
       (when (harness-method-exists-p 'permission/answer)
         (harness-call 'permission/answer id pid
                       (list :behavior 'deny :scope 'once
                             :reason (format (concat "nobody answered this permission prompt in %s, so the harness "
                                                     "denied it; your parent session was told. Do not wait for it: "
                                                     "find another way, or finish and say in your report that you "
                                                     "need this permission")
                                             waited)))
         "the harness denied it, for this call alone"))
      ("question"
       (cond ((and (plist-get payload :call-id) (harness-method-exists-p 'question/answer))
              (harness-call 'question/answer id pid
                            (format (concat "Nobody answered in %s. Decide for yourself with your best "
                                            "judgement, carry on, and say in your report what you assumed.")
                                    waited))
              "the harness told it to decide for itself")
             ((harness-method-exists-p 'question/cancel)
              (harness-call 'question/cancel id pid)
              "the harness dismissed it"))))))

(defun harness-resilience--prompt-timed-out (session item)
  "Answer ITEM, which SESSION, a sub-agent's plist, waited on too long, by default.
Then tell the session's parent and the user."
  (let* ((id (plist-get session :id))
         (waited (harness-resilience--span harness-resilience-prompt-timeout))
         (what (harness-resilience--what item))
         (outcome (harness-resilience--answer session item waited)))
    (when outcome
      (harness-log 'info "resilience: %s waited %s for %s; %s" id waited what outcome)
      (harness-emit 'resilience/prompt-timed-out id item)
      (let* ((parent (harness-resilience--session (harness-resilience--parent session)))
             (text (format (concat "Sub-agent %s (session %s) waited %s for %s, and nobody answered: %s. "
                                   "It carries on. If it needs what it asked for, give it, or ask the user, "
                                   "and tell it (session_send).")
                           (harness-resilience--name session) id waited what outcome)))
        (cond
         ;; A spawn_agent child: its parent is an agent waiting for its
         ;; report, and hears of it the way it hears the report.
         ((and parent (harness-resilience--ext session :report-to))
          (harness-catch (harness-call-async 'agent/prompt (plist-get parent :id) text
                                             (list :from (harness-sender-system "resilience")))
                         (lambda (err) (harness-log 'warn "resilience: telling %s failed: %s"
                                                    (plist-get parent :id) (harness-error-message err)))))
         ;; Another module's sub-agent: its owner hears from it as it
         ;; always does; the parent's transcript says what happened.
         (parent (harness-call 'session/hint (plist-get parent :id) text)))
        (harness-resilience--notify session (format "Answered for you: %s" (harness-resilience--name session))
                                    (format "It waited %s for %s; %s." waited what outcome)
                                    'normal "prompt-timeout")))))

(defun harness-resilience--check-prompts ()
  "Answer by default what sub-agents waited on for too long."
  (when harness-resilience-prompt-timeout
    (let ((now (float-time)))
      (dolist (session (harness-call 'session/list (list :kind 'subagent :status 'blocked)))
        (dolist (item (harness-call 'session/pending (plist-get session :id)))
          (let ((pid (plist-get item :id))
                (created (plist-get item :created)))
            (when (and (numberp created)
                       (> (- now created) harness-resilience-prompt-timeout)
                       (not (gethash pid harness-resilience--defaulted)))
              (puthash pid t harness-resilience--defaulted)
              (harness-ignore-errors-logged (format "resilience: answering %s of %s" pid (plist-get session :id))
                (harness-resilience--prompt-timed-out session item)))))))))

;;;; Watchdog

(defun harness-resilience--note (session-id &rest _)
  "Note that the running turn of SESSION-ID made progress."
  (when (stringp session-id)
    (puthash session-id (float-time) harness-resilience--progress)
    (when (gethash session-id harness-resilience--stalled)
      (remhash session-id harness-resilience--stalled)
      (harness-log 'info "resilience: %s makes progress again" session-id))))

(defun harness-resilience--stall-limit (session-id)
  "Return how many quiet seconds make the running turn of SESSION-ID stalled.
That is `harness-resilience--stall-after', or, while tool calls run, the
longest timeout among them and a minute more, when that is longer."
  (let ((limit harness-resilience--stall-after)
        (activity (and (harness-method-exists-p 'agent/activity)
                       (harness-call 'agent/activity session-id))))
    (when (eq (plist-get activity :phase) 'tool)
      (dolist (call (or (plist-get activity :calls) (list activity)))
        (let ((tool (harness-tool-get (plist-get call :tool))))
          (setq limit (max limit (+ 60 (or (and tool (harness-tool-timeout tool)) harness-tools--timeout)))))))
    limit))

(defun harness-resilience--doing (session-id)
  "Return what the running turn of SESSION-ID does, in words."
  (let ((activity (and (harness-method-exists-p 'agent/activity)
                       (harness-call 'agent/activity session-id))))
    (pcase (plist-get activity :phase)
      ('waiting "waiting for the model")
      ('thinking "the model is thinking")
      ('writing "the model is writing")
      ('tool-input (format "the model is writing a call to %s" (or (plist-get activity :tool) "a tool")))
      ('compacting "compacting")
      ('tool (format "running %s" (or (plist-get activity :title) (plist-get activity :tool) "a tool call")))
      (_ "starting its turn"))))

(defun harness-resilience--report-stall (session quiet)
  "Report SESSION, a plist, whose running turn did nothing for QUIET seconds."
  (let* ((id (plist-get session :id))
         (span (harness-resilience--span quiet))
         (doing (harness-resilience--doing id)))
    (puthash id (float-time) harness-resilience--stalled)
    (harness-log 'warn "resilience: %s has made no progress for %s (%s)" id span doing)
    (harness-call 'session/hint id (format "No progress for %s (%s): the turn may be stuck. The user was notified."
                                           span doing))
    (harness-emit 'resilience/stalled id quiet)
    (harness-resilience--notify session (format "Stalled: %s" (harness-resilience--name session))
                                (format "No progress for %s (%s). It may be stuck: cancel its turn and send it again, or wait."
                                        span doing)
                                'normal "stalled")))

(defun harness-resilience--check-stalls ()
  "Report the running turns that made no progress for too long."
  (when harness-resilience--stall-after
    (let ((now (float-time)))
      (dolist (id (harness-call 'agent/running))
        (let ((session (harness-resilience--session id))
              (last (gethash id harness-resilience--progress)))
          (cond
           ((null session))
           ;; Waiting for the user is no stall; the clock starts again
           ;; when the answer comes (`session/pending-changed').
           ((or (eq (plist-get session :kind) 'internal) (not (eq (plist-get session :status) 'running))))
           ((null last) (puthash id now harness-resilience--progress))
           ((and (not (gethash id harness-resilience--stalled))
                 (> (- now last) (harness-resilience--stall-limit id)))
            (harness-resilience--report-stall session (- now last)))))))))

(defun harness-resilience--tick ()
  "Check for unanswered prompts of sub-agents and for stalled turns."
  (if (not (harness-module-ready-p 'resilience))
      (harness-resilience--stop-timer)
    (harness-ignore-errors-logged "resilience: checking prompts" (harness-resilience--check-prompts))
    (harness-ignore-errors-logged "resilience: checking for stalls" (harness-resilience--check-stalls))))

(defun harness-resilience--stop-timer ()
  "Stop the repeating timer of the checks."
  (when (timerp harness-resilience--timer)
    (cancel-timer harness-resilience--timer))
  (setq harness-resilience--timer nil))

;;;; Module

(defun harness-resilience--init ()
  "Follow turns and check them every while (idempotent).
At a start, not a reload, carry on what a stopped harness cut short."
  (harness-on 'agent/cancelling #'harness-resilience--on-cancelling)
  (harness-on 'agent/turn-started #'harness-resilience--on-turn-started)
  (harness-on 'agent/turn-ended #'harness-resilience--on-turn-ended)
  ;; What says a running turn made progress.  The same list is in
  ;; `harness-resilience--shutdown'.
  (dolist (event '(agent/step-started agent/stream agent/tool-call agent/tool-result
                   agent/activity-changed agent/steered tools/progress session/pending-changed))
    (harness-on event #'harness-resilience--note))
  (unless (memq harness-resilience--timer timer-list)
    (setq harness-resilience--timer (run-at-time harness-resilience--tick-seconds harness-resilience--tick-seconds
                                                 #'harness-resilience--tick)))
  (unless (harness-module-ready-p 'resilience)
    (harness-run-soon #'harness-resilience--recover)))

(defun harness-resilience--shutdown ()
  "Stop following turns and checking them."
  (harness-resilience--stop-timer)
  (harness-off (cons 'agent/cancelling #'harness-resilience--on-cancelling))
  (harness-off (cons 'agent/turn-started #'harness-resilience--on-turn-started))
  (harness-off (cons 'agent/turn-ended #'harness-resilience--on-turn-ended))
  (dolist (event '(agent/step-started agent/stream agent/tool-call agent/tool-result
                   agent/activity-changed agent/steered tools/progress session/pending-changed))
    (harness-off (cons event #'harness-resilience--note)))
  (clrhash harness-resilience--progress)
  (clrhash harness-resilience--stalled))

(harness-declare-event 'resilience/recovered
                       "(IDS) once a start carried on the sessions in IDS, which a stopped harness had cut short.")
(harness-declare-event 'resilience/stalled
                       "(SESSION-ID SECONDS) when a running turn has made no progress for SECONDS.")
(harness-declare-event 'resilience/prompt-timed-out
                       "(SESSION-ID ITEM) after a sub-agent's request ITEM, unanswered too long, was answered by default.")

(harness-define-module 'resilience
  :doc "Carry on sessions a stopped harness cut short, answer sub-agents' unanswered prompts by default, and report stalled turns."
  :requires '(session agent tools)
  :init #'harness-resilience--init
  :shutdown #'harness-resilience--shutdown)

(provide 'harness-resilience)
;;; harness-resilience.el ends here
