;;; harness-recap-test.el --- Tests for task recaps  -*- lexical-binding: t; -*-
;;; Commentary:

;; Recaps are the subtitles task cards show: a short model-written line
;; about what a task is doing.  These tests cover when one is due (the
;; first of the turn, time and tool-call thresholds), the request and its
;; model, storing the result on the task, and the failure back-off.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-recap--running)
(defvar harness-recap--failed)
(defvar harness-recap--sessions)
(defvar harness-recap--session-running)
(defvar harness-recap--session-failed)
(defvar harness-tasks-recap)
(defvar harness-tasks-recap-turns)
(defvar harness-tasks-recap-seconds)
(defvar harness-tasks-recap-tool-calls)
(defvar harness-tasks-recap-model)
(defvar harness-tasks-recap-interval)
(defvar harness-tasks-recap-retry)
(declare-function harness-short-id "harness-util")
(declare-function harness-recap-sanitise "harness-recap")
(declare-function harness-recap--maybe "harness-recap")
(declare-function harness-recap--due-p "harness-recap")
(declare-function harness-recap--model "harness-recap")

(defmacro harness-recap-test-with (&rest body)
  "Load the state layer with the demo provider, tasks and recaps; run BODY.
Every threshold is off unless BODY turns one on, and no timer checks
recaps: each test asks for one itself."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-tasks-recap-interval nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks recap))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-recap--running)
     (clrhash harness-recap--failed)
     (clrhash harness-recap--sessions)
     (clrhash harness-recap--session-running)
     (clrhash harness-recap--session-failed)
     (setq harness-tasks--loaded t)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           (harness-tasks-max-running 0)
           (harness-tasks-recap t)
           (harness-tasks-recap-turns nil)
           (harness-tasks-recap-seconds nil)
           (harness-tasks-recap-tool-calls nil)
           (harness-tasks-recap-model "demo:scripted")
           (harness-tasks-recap-retry 60)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defconst harness-recap-test-script
  '((:type text :delta "  \"Implemented the widget, ") (:type text :delta "tests pass\".")
    (:type done :stop-reason end-turn))
  "What the demo provider answers a recap request with.")

(defun harness-recap-test-session (&rest plist)
  "Create a demo session; PLIST overrides the defaults."
  (plist-get (apply #'harness-call 'session/create
                    (append plist (list :cwd (harness-test-temp-dir) :model "demo:scripted")))
             :id))

(defun harness-recap-test-task (session-id)
  "Put a task for SESSION-ID on the board; return its id.
It waits in review: active would look like work a restart interrupted,
and the tasks module would prompt the session while a test runs."
  (let ((id (format "t-%s" (harness-short-id 6))))
    (puthash id (list :id id :prompt "Do the widget" :state 'review :session session-id
                      :project (harness-test-temp-dir)
                      :created (float-time) :started (float-time) :finished (float-time))
             harness-tasks--table)
    id))

(defun harness-recap-test-record (id)
  "Return task ID as stored, not as the view."
  (gethash id harness-tasks--table))

(defun harness-recap-test-recap (id)
  "Return the recap stored for task ID, or nil."
  (plist-get (harness-recap-test-record id) :recap))

(defun harness-recap-test-add-tool-calls (session-id n)
  "Append N tool calls to SESSION-ID's transcript."
  (dotimes (i n)
    (harness-call 'session/append session-id
                  (list :kind 'tool-call :tool "read_file" :call-id (format "c%d" i) :title "read"))))

(ert-deftest harness-recap-sanitise ()
  (harness-recap-test-with
    (should (equal "Implemented the parser" (harness-recap-sanitise "  \"Implemented the parser\".")))
    (should (equal "Ran the tests" (harness-recap-sanitise "**Ran the tests**\n\nMore text")))
    (should (equal "Fixed the bug" (harness-recap-sanitise "Recap: Fixed the bug")))
    (should (null (harness-recap-sanitise "  \n\"\" ")))
    (let* ((harness-tasks-recap-max-length 20)
           (long (harness-recap-sanitise (make-string 50 ?x))))
      (should (= 20 (length long)))
      (should (string-suffix-p "…" long)))))

(ert-deftest harness-recap-due-whichever-comes-first ()
  "A recap is due at the first threshold crossed, and only then."
  (let* ((harness-tasks-recap-turns 4)
         (harness-tasks-recap-seconds 120)
         (harness-tasks-recap-tool-calls 8)
         (task (list :recap-at 1000.0 :recap-turns 10 :recap-tools 20)))
    ;; Nothing moved yet.
    (should-not (harness-recap--due-p task 13 27 1119.0))
    ;; Each threshold on its own is enough.
    (should (harness-recap--due-p task 14 27 1119.0))
    (should (harness-recap--due-p task 13 28 1119.0))
    (should (harness-recap--due-p task 13 27 1120.0))
    ;; A threshold that is off cannot fire.
    (let ((harness-tasks-recap-turns nil))
      (should-not (harness-recap--due-p task 14 27 1119.0)))
    (let ((harness-tasks-recap-seconds nil))
      (should-not (harness-recap--due-p task 13 27 9999.0)))
    (let ((harness-tasks-recap-tool-calls nil))
      (should-not (harness-recap--due-p task 13 28 1119.0))))
  ;; With no recap yet the task's start is the baseline.
  (let* ((harness-tasks-recap-turns nil)
         (harness-tasks-recap-seconds 120)
         (harness-tasks-recap-tool-calls nil)
         (task (list :started 1000.0 :created 900.0)))
    (should-not (harness-recap--due-p task 1 1 1119.0))
    (should (harness-recap--due-p task 1 1 1120.0))))

(ert-deftest harness-recap-turn-threshold-makes-one ()
  "Crossing the turn threshold sends a short request and stores the recap."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-turns 2)
           (requests nil) (done nil))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      (harness-call 'session/append sid '(:kind assistant :content "on it"))
      (harness-recap-test-add-tool-calls sid 1)
      (harness-call 'session/usage-add sid '(:turns 2))
      (harness-on 'recap/done (lambda (session-id recap) (push (list session-id recap) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should (equal "Implemented the widget, tests pass"
                       (harness-test-await (harness-recap--maybe sid)))))
      (should (equal "Implemented the widget, tests pass" (harness-recap-test-recap id)))
      (should (equal (list (list sid "Implemented the widget, tests pass")) done))
      (should (zerop (hash-table-count harness-recap--running)))
      (let* ((task (harness-recap-test-record id))
             (req (car requests))
             (message (car (last (plist-get req :messages))))
             (text (plist-get (car (plist-get message :content)) :text)))
        (should (= 2 (plist-get task :recap-turns)))
        (should (= 1 (plist-get task :recap-tools)))
        (should (numberp (plist-get task :recap-at)))
        (should (equal "demo:scripted" (plist-get req :model)))
        (should-not (plist-get req :tools))
        (should (string-match-p "Do the widget" text))
        (should (string-match-p "Progress: 2 turns, 1 tool call" text))
        (should (string-match-p "\\[tool read_file\\]" text))
        (should (string-match-p "Recap this task now" text))))))

(ert-deftest harness-recap-not-due-makes-none ()
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-turns 4))
      (harness-call 'session/usage-add sid '(:turns 1))
      (should-not (harness-recap--maybe sid))
      (should-not (harness-recap-test-recap id)))))

(ert-deftest harness-recap-tool-threshold-makes-one ()
  "The tool-call threshold alone is enough, whatever the turns say."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-tool-calls 2))
      (harness-recap-test-add-tool-calls sid 1)
      (should-not (harness-recap--maybe sid))
      (harness-recap-test-add-tool-calls sid 1)
      (harness-emit 'agent/tool-result sid nil)
      (harness-test-wait (lambda () (harness-recap-test-recap id)) 5 "the recap")
      (should (equal "Implemented the widget, tests pass" (harness-recap-test-recap id)))
      (should (= 2 (plist-get (harness-recap-test-record id) :recap-tools))))))

(ert-deftest harness-recap-blocked-turn-is-recapped-at-once ()
  "A turn that stops for the user is recapped even before its thresholds."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-turns 99)
           (harness-tasks-recap-seconds 99999)
           (harness-tasks-recap-tool-calls 99))
      (harness-call 'session/usage-add sid '(:turns 1))
      (harness-emit 'agent/turn-ended sid 'blocked)
      (harness-test-wait (lambda () (harness-recap-test-recap id)) 5 "the blocked recap")
      (should (equal "Implemented the widget, tests pass" (harness-recap-test-recap id))))))

(ert-deftest harness-recap-failure-backs-off ()
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override
            '((:type done :stop-reason error :error "the model is down")))
           (harness-tasks-recap-turns 1))
      (harness-call 'session/usage-add sid '(:turns 1))
      (should-error (harness-test-await (harness-recap--maybe sid)))
      (should-not (harness-recap-test-recap id))
      (should (gethash sid harness-recap--failed))
      ;; Still cooling off: no second request.
      (should-not (harness-recap--maybe sid)))))

(ert-deftest harness-recap-model-choice ()
  "`auto' takes the provider's cheap tier; a name or nil says which model."
  (harness-recap-test-with
    (let ((harness-tasks-recap-model 'auto))
      (cl-letf (((symbol-function 'harness-method/provider/tier-model)
                 (lambda (_model &optional _tier) "demo:cheap")))
        (should (equal "demo:cheap" (harness-recap--model (list :model "demo:scripted"))))))
    (let ((harness-tasks-recap-model nil))
      (should (equal "demo:scripted" (harness-recap--model (list :model "demo:scripted")))))
    (let ((harness-tasks-recap-model "demo:other"))
      (should (equal "demo:other" (harness-recap--model (list :model "demo:scripted")))))))

(ert-deftest harness-recap-skipped-for-write-ups ()
  "A backlog task's write-up session is not recapped."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-turns 1))
      (harness-call 'session/usage-add sid '(:turns 3))
      (harness-tasks--set id :state 'refining)
      (should-not (harness-recap--maybe sid))
      (harness-tasks--set id :state 'pending :backlog t)
      (should-not (harness-recap--maybe sid))
      (should-not (harness-recap-test-recap id)))))

;;;; Recaps of a session that is no task's

(defun harness-recap-test-child ()
  "Create a sub-agent session of a fresh parent; return its id."
  (let ((parent (harness-recap-test-session)))
    (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                             :kind 'subagent :parent-id parent)
               :id)))

(ert-deftest harness-recap-session-made-and-kept ()
  "A sub-agent's session gets a recap of its own, prompt and all."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-child))
           (harness-provider-demo-script-override harness-recap-test-script)
           (requests nil))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      ;; Nothing asks, nothing is made.
      (should-not (harness-recap-session sid))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should-not (harness-recap-session sid t)) ; the request is in flight
        (harness-test-wait (lambda () (gethash sid harness-recap--sessions)) 5 "the session recap"))
      ;; It is kept, and shown while it is not stale.
      (should (equal "Implemented the widget, tests pass"
                     (plist-get (harness-recap-session sid) :text)))
      (should (numberp (plist-get (harness-recap-session sid) :at)))
      (let* ((req (car requests))
             (message (car (last (plist-get req :messages))))
             (text (plist-get (car (plist-get message :content)) :text)))
        (should (equal "demo:scripted" (plist-get req :model)))
        (should (string-match-p "Do the widget" text))
        (should (string-match-p "Progress: 0 turns, 0 tool calls" text))))
    ;; Another session's recap is not written here: only a sub-agent's.
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override harness-recap-test-script))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      (should-not (harness-recap--session-maybe sid (harness-call 'session/get sid) nil))
      (should (harness-recap--session-maybe sid (harness-call 'session/get sid) t))
      (should (gethash sid harness-recap--session-running)))))

(ert-deftest harness-recap-session-of-a-task-is-its-cards ()
  "A session that is a task's shows the card's recap, made by the task."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid)))
      (harness-call 'task/set-recap id :recap "The card's own line" :recap-at (float-time))
      (should (equal "The card's own line" (plist-get (harness-recap-session sid) :text))))))

(ert-deftest harness-recap-session-refreshed-when-stale ()
  "A session recap is made again when the thresholds say it is stale."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-child))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-tool-calls 2))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      (harness-recap-test-add-tool-calls sid 2)
      ;; The first ask is due and makes one...
      (let ((p (harness-recap--session-maybe sid (harness-call 'session/get sid) nil)))
        (should p)
        (should (equal "Implemented the widget, tests pass" (harness-test-await p))))
      ;; ...and nothing is asked again while nothing moved.
      (should-not (harness-recap--session-maybe sid (harness-call 'session/get sid) nil))
      (harness-recap-test-add-tool-calls sid 2)
      (should (harness-recap--session-maybe sid (harness-call 'session/get sid) nil)))))

(ert-deftest harness-recap-session-note-carries-it ()
  "The note under a call that shows a session carries its recap."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-child))
           (harness-provider-demo-script-override harness-recap-test-script))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      (harness-test-await (harness-recap--session-maybe sid (harness-call 'session/get sid) t))
      (puthash sid (list :phase 'thinking :since (float-time)) harness-agent--activities)
      (should (equal "thinking\nrecap: Implemented the widget, tests pass"
                     (harness-tools-session-note sid '(:recap t))))
      ;; Without asking for a recap, the note has none.
      (should (equal "thinking" (harness-tools-session-note sid))))))

(ert-deftest harness-recap-spawn-note-shows-the-childs ()
  "A spawn_agent call's note carries the recap of the child it runs."
  (harness-recap-test-with
    (harness-test-load-module 'tools-agent)
    (let* ((sid (harness-recap-test-session))
           (notes nil)
           (harness-provider-demo--delay 0.05)
           (harness-tasks-recap-tool-calls 1)
           (harness-provider-demo-script-override
            (lambda (request)
              (if (string-match-p "\\`You write the progress recaps" (or (plist-get request :system) ""))
                  harness-recap-test-script
                (append (list '(:type text :delta "The child works.\n")
                              '(:type tool-call :id "c1" :name "list_dir" :input (:path "/tmp")))
                        (mapcar (lambda (i) (list :type 'text :delta (format "chunk %d\n" i)))
                                (number-sequence 1 8))
                        '((:type done :stop-reason end-turn)))))))
      (harness-on 'tools/note (lambda (_s _c text) (push text notes)))
      (let ((r (harness-test-await
                (harness-call 'tools/execute sid (list :id "s1" :name "spawn_agent"
                                                       :input '(:prompt "child work" :name "helper")))
                10)))
        (should-not (plist-get r :is-error)))
      ;; The child's recap reached the note of the call that shows it.
      (should (cl-some (lambda (n) (string-match-p "recap: Implemented the widget, tests pass" n)) notes)))))
