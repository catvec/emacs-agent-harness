;;; harness-provider-openrouter-task-test.el --- Catalogue outages through the task lifecycle  -*- lexical-binding: t; -*-

;;; Commentary:

;; The other OpenRouter suites drive the provider and one turn.  This one
;; runs the failure that was reported -- the shared endpoint catalogue
;; timing out -- through the whole lifecycle a task has: the task starts,
;; its turn's step finds the catalogue unreadable, and the harness decides
;; what becomes of the task.
;;
;; What it must not become is a failure.  Nine tasks were waiting among
;; the failures after one timeout on 2026-11-17, each needing a person to
;; retry it by hand.  A catalogue that cannot be read is no more a failure
;; of a task than a provider out of quota: the price of every endpoint it
;; may use is read from it, so nothing can be sent until it is back, and
;; it is read again by itself.  So the task waits in its queue, its slot
;; goes to the task behind it, and it starts again when a reading comes
;; back -- by priority, within the limit, and with its own session, branch
;; and worktree as they were.
;;
;; Every test here drives a real turn with the retry and fallback modules
;; loaded, the tasks module on top, and every request through a fake HTTP
;; layer: no test makes a live call, and no test touches a provider other
;; than OpenRouter.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)
(require 'harness-session)
(require 'harness-provider-openrouter-test-helpers)

(declare-function harness-tasks--get "harness-tasks")
(declare-function harness-tasks--schedule "harness-tasks")
(declare-function harness-tasks-flush "harness-tasks")

(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--waking)
(defvar harness-tasks--joining)
(defvar harness-tasks--superseding)
(defvar harness-tasks--message-starts)
(defvar harness-tasks--write-up-messages)
(defvar harness-tasks--naming)
(defvar harness-tasks--blocked-at)
(defvar harness-tasks--reply-blocked)
(defvar harness-tasks--lend-timers)
(defvar harness-tasks--holds)
(defvar harness-tasks--hold-timer)
(defvar harness-tasks--title-wait)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks--naming-pool)
(defvar harness-tasks--naming-concurrency)
(defvar harness-tasks--refine-calls)
(defvar harness-tasks--plans-submitted)
(defvar harness-tasks--plan-reminders)
(defvar harness-fallback--marks)
(defvar harness-fallback--moved)
(defvar harness-fallback--quotas)
(defvar harness-fallback--notified)
(defvar harness-fallback--timer)
(defvar harness-fallback-models)
(defvar harness-usage--holds)
(defvar harness-budget)
(defvar harness-tasks-model)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-working-phase)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-worktrees)
(defvar harness-acp--server-enabled)

(defun harness-openrouter-task-test--hints (sid)
  "Return the hint texts of session SID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint))
                            (harness-call 'session/nodes sid))))

(defun harness-openrouter-task-test--prompts (sid)
  "Return the user messages of session SID, oldest first.
The message a parked task is started with is one of these, not a hint:
it is the prompt its next turn runs with."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                            (harness-call 'session/nodes sid))))

(defun harness-openrouter-task-test--completions ()
  "Return the completion requests the fake served, newest first."
  (cl-remove-if-not (lambda (r) (string-match-p "chat/completions" (plist-get r :url)))
                    harness-openrouter-test--requests))

(defun harness-openrouter-task-test--task-of (id)
  "Return task ID as the store has it."
  (harness-call 'task/get id))

(defmacro harness-openrouter-task-test-with (&rest body)
  "Run BODY with tasks and the OpenRouter policy, and a fake transport.
The modules are the ones a real harness starts, tasks included; the
routed model is OpenRouter's, with a static listing so a session can be
made without a key, and every request it makes goes to the fake HTTP
layer.  A task works in its own directory rather than a worktree: what is
under test is what becomes of the task, not git."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-openai provider-openrouter
                           tools session agent retry fallback priority tasks))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-retry--attempts)
     (clrhash harness-fallback--marks)
     (clrhash harness-fallback--moved)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tasks--waking)
     (clrhash harness-tasks--superseding)
     (clrhash harness-tasks--message-starts)
     (clrhash harness-tasks--write-up-messages)
     (clrhash harness-tasks--naming)
     (clrhash harness-tasks--blocked-at)
     (clrhash harness-tasks--reply-blocked)
     (maphash (lambda (_ timer) (cancel-timer timer)) harness-tasks--lend-timers)
     (clrhash harness-tasks--lend-timers)
     (clrhash harness-tasks--holds)
     (when (timerp harness-tasks--hold-timer) (cancel-timer harness-tasks--hold-timer))
     (setq harness-tasks--hold-timer nil)
     (setq harness-openrouter-test--completion-script nil
           harness-openrouter-test--completions 0)
     (let ((default-directory dir)
           (harness-retry-delay 0.01)
           (harness-retry-jitter 0)
           (harness-retry-max-delay 0.05)
           (harness-fallback-models nil)
           (harness-tasks-model (format "openrouter:%s" harness-openrouter-test-model))
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification nil)
           (harness-tasks-working-phase nil)
           (harness-tasks-permission-mode 'auto)
           (harness-tasks-non-interactive t)
           (harness-tasks-worktrees nil)
           (harness-naming-auto nil)
           (harness-acp--clients nil)
           (harness-openrouter-routing nil)
           (harness-openrouter-catalogue-wait 10)
           (harness-openai--models-cache (make-hash-table :test 'eq))
           (harness-openrouter--catalogue (make-hash-table :test 'equal))
           (harness-openrouter--fetching (make-hash-table :test 'equal))
           (harness-openrouter--catalogue-failures (make-hash-table :test 'equal))
           (harness-openrouter--catalogue-waiters (make-hash-table :test 'equal))
           (harness-openrouter--canonical (make-hash-table :test 'equal))
           (harness-openai-endpoints
            (list (list :id 'openrouter :label "OpenRouter"
                        :base-url "https://openrouter.ai/api/v1"
                        :models (list harness-openrouter-test-model))))
           (harness-openrouter-test--requests nil)
           (harness-openrouter-test--responses nil)
           (harness-openrouter-test--hold nil)
           (harness-openrouter-test--hold-catalogue nil)
           (harness-openrouter-test--held-catalogues nil)
           (auth-sources nil))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (setq harness-tasks--loaded t
             harness-tasks--dirty nil
             harness-tasks--naming-pool (harness-tasks--naming-pool-new))
       (unwind-protect
           (cl-letf (((symbol-function 'harness-http-request)
                      #'harness-openrouter-test--fake-request))
             ,@body)
         (harness-tasks--forget-stores)
         (harness-tasks--shutdown)
         (harness-fallback--shutdown)
         (harness-retry--shutdown)
         (harness-openrouter--shutdown)
         (harness-provider-unregister 'openrouter)))))

(defun harness-openrouter-task-test--submit (prompt)
  "Submit PROMPT as a task of this test's project, and return its id."
  (plist-get (harness-call 'task/submit default-directory prompt) :id))

(defun harness-openrouter-task-test--outage ()
  "Make the catalogue read fail as the live one did: a stalled 200."
  (list (cons (harness-openrouter-test--catalogue-url-regexp)
              '(:error (http-error 200 (timeout "request timed out after 20s"))))))

(defun harness-openrouter-task-test--catalogue ()
  "Make the catalogue read answer with the fixture, and completions answer."
  (list (cons (harness-openrouter-test--catalogue-url-regexp)
              (list :body (harness-openrouter-test--catalogue-json)))
        (cons "chat/completions"
              (harness-openrouter-test--chain-answer))))

;;;; A catalogue outage is a wait, not a failed task

(ert-deftest harness-openrouter-task-a-catalogue-outage-parks-the-task ()
  "A task whose turn stops on an outage waits in its queue, not among failures.
This is the reported failure end to end: the catalogue timed out, the
turn's step ended `catalogue-unavailable', and the task was marked
`:outcome error' -- nine of them, each needing a person.  Now the turn's
own step waits out the episode first (covered in the provider suite);
when the wait is outlasted, the task is *parked*: back in the pending
queue with `:return-reason catalogue', its slot free for the task behind
it, its session, branch and worktree kept, and a hint saying why it
waits.  Nothing is reported as failed, and nothing needs a person to
restart it."
  (harness-openrouter-task-test-with
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    ;; The catalogue is out, and outlasting the wait the step may spend on
    ;; it: this test is about what task mode makes of that.
    (setq harness-openrouter-catalogue-wait 0.2)
    (setq harness-openrouter-test--responses (harness-openrouter-task-test--outage))
    (let ((id (harness-openrouter-task-test--submit "fix the parser")))
      ;; The turn stops on the outage and the task goes back to the queue.
      (harness-test-wait
       (lambda () (eq 'pending (plist-get (harness-openrouter-task-test--task-of id) :state)))
       60 "the task to wait in its queue")
      (let ((parked (harness-openrouter-task-test--task-of id)))
        (should (eq 'catalogue (plist-get parked :return-reason)))
        (should-not (plist-get parked :outcome))
        ;; Its session is kept, at rest: the turn is over and nothing of it
        ;; is left running.
        (should (memq (plist-get (harness-call 'session/get (plist-get parked :session))
                                 :status)
                      '(idle blocked)))
        ;; The hold says what it waits for, and when the next read is due.
        (let ((hold (harness-tasks--hold parked)))
          (should hold)
          (should (eq 'catalogue (plist-get hold :kind)))
          (should (string-match-p "catalogue" (plist-get hold :reason))))
        ;; And its session says so too.
        (should (cl-some (lambda (h) (string-match-p "catalogue" h))
                         (harness-openrouter-task-test--hints
                          (plist-get parked :session))))
        ;; A catalogue comes back: the queue starts the task again by
        ;; itself, and it goes on to finish its work.
        (setq harness-openrouter-test--responses (harness-openrouter-task-test--catalogue))
        (harness-openrouter--catalogue-retry harness-openrouter-test-model)
        (harness-test-wait
         (lambda () (not (eq 'pending (plist-get (harness-openrouter-task-test--task-of id)
                                                :state))))
         60 "the task to start again")
        (harness-test-wait
         (lambda () (memq (plist-get (harness-openrouter-task-test--task-of id) :state)
                          '(done review)))
         60 "the task to finish")
        ;; It ended as work, not as a failure: no outcome error, and its
        ;; session was told why it had waited -- the message that started
        ;; it again is the one that says the catalogue is back.
        (let ((finished (harness-openrouter-task-test--task-of id)))
          (should-not (eq 'error (plist-get finished :outcome)))
          (should (member harness-tasks--catalogue-message
                          (harness-openrouter-task-test--prompts
                           (plist-get finished :session)))))))))

(ert-deftest harness-openrouter-task-a-waiting-task-gives-its-slot-up ()
  "A task waiting for the catalogue does not hold a slot from the queue.
The catalogue stops every task of the model, so a slot held by one of
them is a slot the queue cannot use: a parked task frees it at once, and
the queue has it for whatever can go on.  The task behind it waits too --
nothing of this model can be sent until a price can be read -- but it
waits as queued work, not as a failure, and the project's limit is never
exceeded while the queue starts them again."
  (harness-openrouter-task-test-with
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-catalogue-wait 0.2)
    (setq harness-tasks-max-running 1)
    (setq harness-openrouter-test--responses (harness-openrouter-task-test--outage))
    (let ((first (harness-openrouter-task-test--submit "first task"))
          (second (harness-openrouter-task-test--submit "second task"))
          (over nil))
      ;; The first task's turn stops on the outage and it gives its slot up.
      (harness-test-wait
       (lambda () (eq 'pending (plist-get (harness-openrouter-task-test--task-of first)
                                         :state)))
       60 "the first task to wait in its queue")
      (let ((task (harness-openrouter-task-test--task-of first)))
        (should (eq 'catalogue (plist-get task :return-reason)))
        (should-not (plist-get task :outcome)))
      ;; Its slot is free again: the limit is one, and nothing holds it.
      (should (= 1 (harness-tasks--free-slots default-directory)))
      ;; The second waits as queued work for the same catalogue, not as a
      ;; failure of its own.
      (harness-test-wait
       (lambda () (eq 'catalogue (plist-get (harness-tasks--hold
                                             (harness-openrouter-task-test--task-of second))
                                            :kind)))
       60 "the second task to wait for the catalogue")
      (let ((task (harness-openrouter-task-test--task-of second)))
        (should (eq 'pending (plist-get task :state)))
        (should-not (plist-get task :outcome)))
      ;; A catalogue comes back: the queue starts them again, one at a
      ;; time, and the limit is never exceeded on the way.
      (setq harness-openrouter-test--responses (harness-openrouter-task-test--catalogue))
      (harness-openrouter--catalogue-retry harness-openrouter-test-model)
      (harness-test-wait
       (lambda ()
         (when (< (harness-tasks--free-slots default-directory) 0)
           (setq over t))
         (cl-every (lambda (id)
                     (memq (plist-get (harness-openrouter-task-test--task-of id) :state)
                           '(done review)))
                   (list first second)))
       120 "both tasks to finish")
      (should-not over))))

(ert-deftest harness-openrouter-task-a-paused-task-stays-paused ()
  "A task paused while it waits for the catalogue is not started by a reading.
Pausing is the user's, and a reading coming back is not their resume: the
task waits in the queue, paused, until it is resumed, and only then does
it start.  Nothing about the outage overrides a pause."
  (harness-openrouter-task-test-with
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-catalogue-wait 0.2)
    (setq harness-openrouter-test--responses (harness-openrouter-task-test--outage))
    (let ((id (harness-openrouter-task-test--submit "paused while waiting")))
      (harness-test-wait
       (lambda () (eq 'pending (plist-get (harness-openrouter-task-test--task-of id)
                                         :state)))
       60 "the task to wait in its queue")
      (harness-call 'task/pause id)
      (should (plist-get (harness-openrouter-task-test--task-of id) :paused))
      ;; A catalogue comes back; a paused task is not started by it.
      (setq harness-openrouter-test--responses (harness-openrouter-task-test--catalogue))
      (harness-openrouter--catalogue-retry harness-openrouter-test-model)
      (sit-for 1)
      (let ((task (harness-openrouter-task-test--task-of id)))
        (should (eq 'pending (plist-get task :state)))
        (should (plist-get task :paused))
        (should (eq 'paused (plist-get (harness-tasks--hold task) :kind))))
      ;; Resumed, it starts and finishes.
      (harness-call 'task/resume id)
      (harness-test-wait
       (lambda () (memq (plist-get (harness-openrouter-task-test--task-of id) :state)
                        '(done review)))
       60 "the resumed task to finish"))))

(ert-deftest harness-openrouter-task-a-refused-catalogue-waits-for-a-person ()
  "A catalogue the server refuses is not an outage: the task waits for a person.
An auth failure will answer the same way however often it is read, so the
task is not parked as an outage and not restarted by a reading: it waits
where a failure of the work waits, with what the catalogue said.  That is
the difference a person needs -- a key to fix, not an outage to sit out."
  (harness-openrouter-task-test-with
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-catalogue-wait 10)
    (setq harness-openrouter-test--responses
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      (list :body (harness-json-encode
                                   (list :error (list :code 401
                                                      :message "No auth credentials found")))))))
    (let ((id (harness-openrouter-task-test--submit "refused catalogue")))
      (harness-test-wait
       (lambda () (plist-get (harness-openrouter-task-test--task-of id) :outcome))
       60 "the task to stop")
      (let ((task (harness-openrouter-task-test--task-of id)))
        ;; It waits for the user, as a failure of the work does -- not in
        ;; the queue for a catalogue that will answer the same way again.
        (should (eq 'error (plist-get task :outcome)))
        (should-not (eq 'catalogue (plist-get task :return-reason)))
        ;; And its session says what the catalogue said.
        (should (cl-some (lambda (h) (string-match-p "No auth credentials found" h))
                         (harness-openrouter-task-test--hints
                          (plist-get task :session)))))
      ;; Nothing was sent, and no reading is being waited for.
      (should-not (harness-openrouter-task-test--completions))
      (should (zerop (plist-get (harness-openrouter-catalogue-status) :waiting))))))

(ert-deftest harness-openrouter-task-a-model-the-policy-no-longer-routes-is-no-wait ()
  "A task the policy has moved away from is not held for its old model's outage.
The task's session runs model A; the operator then routes model B.  A's
catalogue being out is no reason to keep the task in the queue: its next
turn would be refused `model-mismatch' whatever A's catalogue says, and
waiting for a reading of A would only meet that refusal.  So the hold is
gone, and the task waits where a policy answer leaves work -- in front of
a person."
  (harness-openrouter-task-test-with
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-catalogue-wait 0.2)
    (setq harness-openrouter-test--responses (harness-openrouter-task-test--outage))
    (let ((id (harness-openrouter-task-test--submit "routes A")))
      ;; It waits for A's catalogue, as it should while A is what the
      ;; policy routes.
      (harness-test-wait
       (lambda () (eq 'catalogue (plist-get (harness-openrouter-task-test--task-of id)
                                            :return-reason)))
       60 "the task to wait for the catalogue")
      (should (harness-tasks--hold (harness-openrouter-task-test--task-of id)))
      ;; The operator routes another model.  The hold is A's, and A is no
      ;; longer what this task's next turn would run: a scheduling pass
      ;; works the holds out again and finds none.
      (setq harness-openrouter-routing
            (harness-openrouter-test-policy :model "deepseek/deepseek-v4.1-flash-20261017"))
      (should-not (harness-tasks--compute-hold (harness-openrouter-task-test--task-of id)))
      (harness-tasks--refresh-holds)
      (should-not (harness-tasks--hold (harness-openrouter-task-test--task-of id)))
      (should-not (harness-call 'openrouter/catalogue-hold harness-openrouter-test-model)))))

(provide 'harness-provider-openrouter-task-test)
;;; harness-provider-openrouter-task-test.el ends here
