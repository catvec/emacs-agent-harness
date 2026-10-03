;;; harness-recap.el --- Recap task cards with the model  -*- lexical-binding: t; -*-

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
;; to the provider's cheap tier (`harness-tasks-recap-model' `auto'),
;; which a fork of the session's own provider state could not.
;;
;; Checks run when a turn ends, after a tool result, and every
;; `harness-tasks-recap-interval' seconds while a turn runs, so the time
;; threshold fires even while the model is quiet.  A turn that ends
;; blocked is recapped at once, thresholds or not: that is when the card
;; shows the recap, in the needs-input column.  One request per session
;; is in flight at a time, and a failed one waits
;; `harness-tasks-recap-retry' seconds before the next try.

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
                    (ignore-errors (harness-call 'provider/tier-model model 'cheap)))
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

(defun harness-recap--prompt (task session)
  "Return the user text of a recap request for TASK and SESSION."
  (let* ((prompt (string-trim (or (plist-get task :prompt) "")))
         (prompt (if (> (length prompt) 600) (concat (substring prompt 0 600) "…") prompt))
         (counts (harness-recap--counts session))
         (turns (car counts))
         (tools (cadr counts))
         (todos (plist-get session :todos))
         (done (cl-count "done" todos :key (lambda (todo) (plist-get todo :status)) :test #'equal))
         (now (cl-find "in-progress" todos :key (lambda (todo) (plist-get todo :status)) :test #'equal))
         (plan (plist-get session :plan)))
    (string-join
     (delq nil
           (list (concat "Task: " prompt)
                 (format "Progress: %d turns, %d %s" turns tools
                         (if (= tools 1) "tool call" "tool calls"))
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

;;;; Making one

(defun harness-recap--finish (sid id promise counts good reason error)
  "Store the recap GOOD of task ID, or back off after a failure.
SID names the session, PROMISE is settled either way; REASON and ERROR
say why a failure failed.  COUNTS is the (TURNS TOOLS) the recap was
made at."
  (remhash sid harness-recap--running)
  (if good
      (condition-case err
          (progn
            (harness-call 'task/set-recap id
                          :recap good :recap-at (float-time)
                          :recap-turns (car counts) :recap-tools (cadr counts))
            (harness-emit 'recap/done sid good)
            (harness-resolve promise good))
        (error (harness-log 'warn "recap of %s could not be stored: %S" id err)
               (harness-reject promise err)))
    (when (numberp harness-tasks-recap-retry)
      (puthash sid (+ (float-time) harness-tasks-recap-retry) harness-recap--failed))
    (harness-log 'warn "recap of %s failed: %s" id (or error reason))
    (harness-emit 'recap/failed sid (or error reason))
    (harness-reject promise (or error reason))))

(defun harness-recap--start (task session)
  "Ask the model for a recap of TASK's session SESSION; return the promise."
  (let* ((sid (plist-get session :id))
         (id (plist-get task :id))
         (counts (harness-recap--counts session))
         (text "")
         (promise (harness-make-promise))
         (request (append
                   (list :model (harness-recap--model session)
                         :session session
                         :system harness-recap--system-prompt
                         :messages (list (list :role 'user
                                               :content (list (list :type "text"
                                                                    :text (harness-recap--prompt task session)))))
                         :tools nil
                         :max-tokens harness-tasks-recap-max-tokens
                         :on-event
                         (lambda (ev)
                           (pcase (plist-get ev :type)
                             ('text (setq text (concat text (plist-get ev :delta))))
                             ('done
                              (let* ((reason (plist-get ev :stop-reason))
                                     (recap (and (not (memq reason '(error cancelled)))
                                                 (harness-recap-sanitise text))))
                                (harness-recap--finish sid id promise counts recap reason
                                                       (plist-get ev :error)))))))
                   (and harness-tasks-recap-thinking
                        (list :thinking harness-tasks-recap-thinking)))))
    (puthash sid promise harness-recap--running)
    (condition-case err
        (harness-call 'provider/complete request)
      (error (harness-recap--finish sid id promise counts nil nil (harness-error-message err))))
    promise))

(defun harness-recap--maybe (session-id &optional force)
  "Recap the task of SESSION-ID when one is due; FORCE skips the thresholds.
Return the promise of a recap request just started, or nil."
  (when (and harness-tasks-recap
             (harness-call 'session/exists-p session-id)
             (not (gethash session-id harness-recap--running)))
    (let ((retry (gethash session-id harness-recap--failed)))
      (when (or (null retry) (>= (float-time) retry))
        (when-let* ((task (harness-recap--task session-id))
                    (session (harness-call 'session/get session-id))
                    ((harness-recap--eligible-p task session))
                    (counts (harness-recap--counts session))
                    ((or force
                         (harness-recap--due-p task (car counts) (cadr counts) (float-time)))))
          (harness-recap--start task session))))))

;;;; Checks

(defun harness-recap--on-turn-ended (session-id reason)
  "Recap SESSION-ID's task when its turn ended.
A turn that stopped for the user, or on an error, is recapped at once:
its card needs the recap then, whatever the thresholds say."
  (harness-recap--maybe session-id (memq reason '(blocked error cancelled))))

(defun harness-recap--on-tool-result (session-id &rest _)
  "Recap SESSION-ID's task when a tool call of its turn finished."
  (harness-recap--maybe session-id))

(defun harness-recap--check-running ()
  "Recap every running task whose recap is due on time."
  (when (harness-method-exists-p 'agent/running)
    (dolist (session-id (harness-call 'agent/running))
      (harness-recap--maybe session-id))))

;;;; Init and reload

(defun harness-recap--start-timer ()
  "Start checking the time threshold every `harness-tasks-recap-interval'."
  (when (timerp harness-recap--timer) (cancel-timer harness-recap--timer))
  (setq harness-recap--timer
        (and (numberp harness-tasks-recap-interval) (> harness-tasks-recap-interval 0)
             (run-with-timer harness-tasks-recap-interval harness-tasks-recap-interval
                             #'harness-recap--check-running))))

(defun harness-recap--shutdown ()
  "Stop checking recaps due on time."
  (when (timerp harness-recap--timer) (cancel-timer harness-recap--timer))
  (setq harness-recap--timer nil))

(defun harness-recap--init ()
  "Subscribe recaps to turns and tool calls, and start the timer.
The turn-ended check runs before the tasks module's: a task that just
finished is still active there, so its last recap is made even when
the task itself goes straight to done."
  (harness-on 'agent/turn-ended #'harness-recap--on-turn-ended 40)
  (harness-on 'agent/tool-result #'harness-recap--on-tool-result)
  (harness-recap--start-timer))

(harness-recap--init)

(harness-declare-event 'recap/done "(SESSION-ID RECAP) after a task card's recap was stored.")
(harness-declare-event 'recap/failed "(SESSION-ID MESSAGE) when a recap could not be made.")

(harness-define-module 'recap
  :doc "Write the recaps task cards show, with a short model call."
  :requires '(session provider agent tasks)
  :init #'harness-recap--init
  :shutdown #'harness-recap--shutdown)

(provide 'harness-recap)
;;; harness-recap.el ends here
