;;; promo-story.el --- What the promo film's footage shows  -*- lexical-binding: t; -*-

;;; Commentary:

;; The footage, as a story told to `promo-rec.el': one Emacs, which starts
;; plain -- the harness with no module but the core -- and gets one module
;; after another, each of them a real part of the harness enabled with
;; `harness-enable-module' while it runs.
;;
;;   intro   the plain harness: code on the left, a new chat on the right.  A
;;           person asks "show me what Emacs agent harness can do" and the
;;           agent answers.
;;   tasks   the task board has landed in the left window.  It is used: tasks are
;;           typed, run side by side, reviewed and merged.
;;
;; Each segment is recorded from the state the one before it left, so the
;; first frame of a segment is the last frame of the one before it with the new
;; module's UI added.  The film puts the module's UI crashing down between them.
;;
;; Sizes and times are in frames of 30 a second.  A beat is 15 frames (120 BPM),
;; a bar 60: the film's score is cut to the same grid (promo/src/timeline.ts).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'promo-rec)

;; Harness variables and functions the story reaches into.
(defvar harness-ui--position-buffers)
(defvar harness-ui--fullscreen-layouts)
(defvar harness-chat--loading)
(declare-function harness-call "harness-core")
(declare-function harness-enable-module "harness")
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-ui-display-session "harness-ui")
(declare-function harness-ui-tasks-open "harness-ui-tasks")
(declare-function transient-quit-all "transient")

(defconst promo-story-prompt "show me what Emacs agent harness can do"
  "What the person asks, first thing.")

(defconst promo-story-reply
  "Out of the box I can:
- read and edit your files
- run a shell, tests and git
- search the web and fetch pages
- use your Emacs buffers and commands

The rest is modules. Here is the first one: the task board."
  "What the agent answers: a list, so it is read at a glance.")

(defvar promo-story--session nil "Id of the session of the conversation.")

(defun promo-story--tour-script (_request)
  "The agent's answer to `promo-story-prompt': a beat to think, then the reply,
streamed."
  (cons (promo-rec-wait 9) (promo-rec-say promo-story-reply 2)))

;;;; The frame

(defun promo-story--reset-layout ()
  "One window, in a frame of the full size, with nothing of the harness in it."
  (ignore-errors (transient-quit-all))
  (dolist (w (window-list nil 'nomini))
    (when (and (window-live-p w) (window-parameter w 'window-side))
      (ignore-errors (delete-window w))))
  (delete-other-windows)
  (clrhash harness-ui--position-buffers)
  (clrhash harness-ui--fullscreen-layouts)
  (switch-to-buffer (get-buffer-create "*scratch*"))
  (promo-rec-size-frame))

(defun promo-story--show-code ()
  "Visit acme/app.py in the selected window, from its first line."
  (find-file (harness-media--path "acme/app.py"))
  (display-line-numbers-mode 1)
  ;; No cursor in the code: the one in the chat's box is the picture's.
  (setq-local cursor-type nil)
  (goto-char (point-min))
  (set-window-start nil (point-min)))

(defun promo-story--layout ()
  "Code on the left, the conversation's chat on the right, point in its compose
box. Return the chat's window."
  (promo-story--reset-layout)
  (promo-story--show-code)
  (let* ((buffer (harness-ui-display-session promo-story--session 'right))
         (window (get-buffer-window buffer)))
    ;; A session with nothing said has no transcript to wait for, only the box.
    (harness-media--wait (lambda () (with-current-buffer buffer (not harness-chat--loading)))
                         20 "the chat to load")
    (harness-media--to-bottom buffer)
    (select-window window)
    (goto-char (point-max))
    (harness-media--settle 0.5)
    window))

;;;; intro

(defconst promo-story-intro-frames 336
  "Length of the intro: the answer sits for three seconds and a half; the
board then falls on the next twenty-four frames.")

(defun promo-story-intro ()
  "Record the plain harness and the first words said to it."
  (harness-media--log "building the demo project")
  (harness-media--make-project)
  (push (cons "show me what Emacs agent harness" #'promo-story--tour-script) promo-rec-scripts)
  ;; The title the harness's naming gives the session, as the README pictures script theirs.
  (push '("show me what Emacs agent harness" . "A tour of the harness") harness-media--titles)
  (setq promo-story--session
        (harness-media--new-session :model "claude:claude-fable-5-1" :permission-mode 'auto :thinking "high"))
  (let ((window (promo-story--layout)))
    (promo-rec-rect :chat (promo-rec-window-rect window))
    (promo-rec-begin "intro")
    (promo-rec-mark "start")
    (let ((typed (promo-rec-type-at 20 promo-story-prompt :cps 14)))
      (promo-rec-mark-at 20 "typing")
      (promo-rec-mark-at typed "typed")
      (promo-rec-key-at (+ typed 18) "C-c C-c" :caption "send")
      (promo-rec-mark-at (+ typed 18) "sent"))
    (promo-rec-play promo-story-intro-frames)
    (promo-rec-mark "end")
    (unless (eq (harness-media--status promo-story--session) 'idle)
      (error "The agent has not finished its answer by the end of the intro"))
    (promo-rec-end)))

;;;; tasks

(defvar harness-ui-tasks--tasks)
(declare-function harness-tasks "harness-ui-tasks")

(defun promo-story--await-task (id column what)
  "Advance the world, off camera, until task ID is in COLUMN (a string)."
  (promo-rec-advance-until
   (lambda () (equal (harness-media--column (harness-media--task id)) column))
   3000 (format "task %s to be %s (%s)" id column what)))

(defun promo-story--history ()
  "Give the board a past: two tasks finished and merged, a day and hours ago."
  (let* ((constant (harness-media--submit "use hmac.compare_digest when checking API keys, so a key check takes the same time whatever the key"))
         (python (harness-media--submit "we deploy on 3.12 now: bump requires-python and list the versions we support in pyproject.toml")))
    (dolist (id (list constant python))
      (promo-story--await-task id "review" "to wait for review"))
    (dolist (id (list constant python))
      (harness-call 'task/verify id)
      (promo-story--await-task id "done" "to merge"))
    ;; Minutes ago: created (and started), finished, verified.
    (pcase-dolist (`(,id ,created ,finished ,verified) `((,constant 180 171 140) (,python 1560 1556 1540)))
      (let* ((task (harness-media--task id)))
        (harness-tasks--set id
                            :created (harness-media--ago created)
                            :started (harness-media--ago created)
                            :finished (harness-media--ago finished)
                            :verified-at (harness-media--ago verified))
        (when-let* ((sid (plist-get task :session)))
          (harness-media--set-times sid created finished))))))

(defun promo-story--enable (modules)
  "Enable MODULES (a list of names), as `harness-enable-module' does for one."
  (dolist (m modules)
    (harness-enable-module m))
  (harness-media--settle 1))

(defconst promo-story--health-test "\"\"\"The health check answers a load balancer, which carries no API key.\"\"\"

import unittest

from tests.test_app import call


class HealthTest(unittest.TestCase):
    def test_health_needs_no_key(self):
        status, _, body = call(path=\"/health\", key=None)
        self.assertEqual(status, \"200 OK\")
        self.assertEqual(body, {\"status\": \"ok\"})
")

(defconst promo-story-pace 17
  "Frames a task's agent waits before each tool call, so that a task takes six
seconds or so.")

(defun promo-story--paced (events ticks)
  "EVENTS with a wait of TICKS frames before each tool call: the pace of a
model that thinks."
  (cl-loop for event in events
           if (eq (plist-get event :type) 'tool-call) append (list (promo-rec-wait ticks) event)
           else collect event))

(defun promo-story--task-turn (todos groups message summary problem evidence ticks)
  "A task's turn, paced by TICKS: a todo list that fills in as the work goes.
TODOS are the item texts; GROUPS the tool calls under each of them, one list
each.  The work is committed as MESSAGE and handed in with SUMMARY, the PROBLEM
it solves and its EVIDENCE."
  (let* ((at (lambda (done)
               (apply #'harness-media--todos
                      (cl-loop for text in todos for i from 0
                               collect (cons text (cond ((< i done) "done") ((= i done) "in-progress") (t "pending"))))))))
    (promo-story--paced
     (append (list (funcall at 0))
             (cl-loop for group in groups for i from 1 append (append group (list (funcall at i))))
             (list (harness-media--git-commit message)
                   (harness-media--say "Done, and the tests pass. Handing it in for review.")
                   (harness-media--tool "hand_in" :problem problem :summary summary :evidence evidence)))
     ticks)))

(defun promo-story--task-health (_request)
  "Task: a health check, ahead of authentication."
  (promo-story--task-turn
   '("Read how requests are routed" "Add the /health route" "Test it")
   (list (list (harness-media--tool "read_file" :path "acme/app.py"))
         (list (harness-media--tool "edit_file" :path "acme/app.py"
                                    :old_string "def application(environ, start_response):\n    key = authenticate(environ)\n"
                                    :new_string "def application(environ, start_response):\n    if environ[\"PATH_INFO\"] == \"/health\":\n        return respond(start_response, \"200 OK\", {\"status\": \"ok\"})\n    key = authenticate(environ)\n"))
         (list (harness-media--tool "write_file" :path "tests/test_health.py" :content promo-story--health-test)
               (harness-media--tool "bash" :command "python3 -m unittest")))
   "Add a health check endpoint"
   "`GET /health` answers `200` with `{\"status\": \"ok\"}`, ahead of the API key check, so a load balancer can ask whether the API is up."
   "A load balancer has nothing to ask whether the API is up."
   (list (list :file "acme/app.py" :caption "The route, ahead of authentication"))
   promo-story-pace))

(defun promo-story--task-pagination (_request)
  "Task: page the list of orders."
  (promo-story--task-turn
   '("Read the orders handler" "Add limit and offset" "Run the tests")
   (list (list (harness-media--tool "read_file" :path "acme/orders.py"))
         (list (harness-media--tool "write_file" :path "acme/orders.py" :content harness-media--orders-paginated)
               (harness-media--tool "edit_file" :path "tests/test_app.py"
                                    :old_string "{\"orders\": []}" :new_string "{\"orders\": [], \"total\": 0}"))
         (list (harness-media--tool "bash" :command "python3 -m unittest")))
   "Paginate GET /orders"
   "`GET /orders` takes `limit` (50 by default, 200 at most) and `offset`, and returns the total, so a client pages through the orders instead of loading them all."
   "GET /orders returns every order at once, so a client can only load the whole list."
   (list (list :file "acme/orders.py" :caption "limit, offset and the total"))
   promo-story-pace))

(defun promo-story--task-slow (_request)
  "Task: log the slow requests."
  (promo-story--task-turn
   '("Time every request" "Log the slow ones" "Wire it in")
   (list (list (harness-media--tool "read_file" :path "acme/app.py"))
         (list (harness-media--tool "write_file" :path "acme/timing.py" :content harness-media--timing))
         (list (harness-media--tool "edit_file" :path "acme/app.py"
                                    :old_string "from acme.auth import authenticate\n"
                                    :new_string "from acme.auth import authenticate\nfrom acme.timing import timed\n")))
   "Log slow requests"
   "`acme.timing.timed()` wraps the app and logs every request slower than 500 ms."
   "Requests slower than 500 ms are invisible in the logs, so slowness is found only by report."
   (list (list :file "acme/timing.py" :caption "The timing middleware and its threshold"))
   promo-story-pace))

(defvar promo-story--board nil "The window of the task board.")

(defun promo-story--task (regexp)
  "The task of the demo project whose prompt matches REGEXP."
  (cl-find-if (lambda (task) (string-match-p regexp (or (plist-get task :prompt) "")))
              (harness-call 'task/list harness-media-project)))

(defun promo-story--card-pos (regexp)
  "Where the card of the task REGEXP names starts, in the board's buffer; nil
when it has none."
  (when-let* ((id (plist-get (promo-story--task regexp) :id)))
    (with-current-buffer (window-buffer promo-story--board)
      (save-excursion
        (goto-char (point-min))
        (when-let* ((match (text-property-search-forward 'harness-task-id id #'equal)))
          (prop-match-beginning match))))))

(defun promo-story--button-pos (regexp label)
  "Where the button LABEL on the card of the task REGEXP names starts, in the
board's buffer."
  (when-let* ((start (promo-story--card-pos regexp)))
    (with-current-buffer (window-buffer promo-story--board)
      (save-excursion
        (goto-char start)
        (when (search-forward label (line-end-position) t) (match-beginning 0))))))

(defun promo-story--card-xy (regexp)
  "The title of the card of the task REGEXP names, as [X Y] frame pixels."
  (let ((pos (promo-story--card-pos regexp)))
    (promo-rec-point-xy promo-story--board (+ pos 14))))

(defun promo-story--button-xy (regexp label)
  "The button LABEL of the card of the task REGEXP names, as [X Y] frame pixels."
  (let ((pos (promo-story--button-pos regexp label)))
    (promo-rec-point-xy promo-story--board (+ pos (/ (length label) 2)))))

(defun promo-story--open-card (regexp)
  "Open the session of the task REGEXP names from the board, as RET on its card
does."
  (with-selected-window promo-story--board
    (goto-char (promo-story--card-pos regexp))
    (harness-ui-tasks-open)))

(defun promo-story--push-button (regexp label)
  "Click the button LABEL of the card of the task REGEXP names."
  (with-selected-window promo-story--board
    (goto-char (promo-story--button-pos regexp label))
    (push-button)))

(defun promo-story--typed-task (frame text cps)
  "At FRAME the person types TEXT into the board's box at CPS and submits it;
return the frame of the submit."
  (let ((typed (promo-rec-type-at frame text :cps cps)))
    (promo-rec-key-at (+ typed 14) "C-c C-c" :caption "submit")
    (+ typed 14)))

(defun promo-story--section-rect (heading next)
  "The lines of the board's section HEADING, down to the heading NEXT, as a
frame rectangle."
  (with-current-buffer (window-buffer promo-story--board)
    (save-excursion
      (goto-char (point-min))
      (when (search-forward heading nil t)
        (let ((start (match-beginning 0)))
          (when (search-forward next nil t)
            (promo-rec-lines-rect promo-story--board start (max start (- (match-beginning 0) 2)))))))))

(defun promo-story--completed-rect ()
  "The Completed section's heading and its cards, down to the oldest, as a
frame rectangle."
  (with-current-buffer (window-buffer promo-story--board)
    (save-excursion
      (goto-char (point-min))
      (when (search-forward "Completed" nil t)
        (let ((start (match-beginning 0))
              (last (promo-story--card-pos "requires-python")))
          (when last
            (promo-rec-lines-rect promo-story--board start last)))))))

(defun promo-story--card-rect (regexp)
  "The line of the card of the task REGEXP names, as a frame rectangle."
  (when-let* ((pos (promo-story--card-pos regexp)))
    (promo-rec-lines-rect promo-story--board pos pos)))

(defun promo-story--slot-window ()
  "The window beside the board, which shows a session."
  (cl-find-if (lambda (w) (not (eq w promo-story--board))) (window-list nil 'nomini)))

(defun promo-story--worktree-rect ()
  "The lines of the open session that say where its task started, as a frame
rectangle."
  (when-let* ((window (promo-story--slot-window)))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char (point-min))
        (when (search-forward "Task started in" nil t)
          (let ((start (match-beginning 0)))
            (promo-rec-lines-rect window start (min (point-max) (+ start 120)))))))))

(defconst promo-story-tasks-frames 600 "Length of the task board's segment: ten bars.")

(defun promo-story--ready-p (regexp)
  "Non-nil when the card of the task REGEXP names offers [Verify]."
  (and (promo-story--button-pos regexp "[Verify]") t))

(defun promo-story--done-p (regexp)
  "Non-nil when the task REGEXP names is complete."
  (equal (harness-media--column (promo-story--task regexp)) "done"))

(defun promo-story--click-card (regexp)
  "The person clicks the card of the task REGEXP names, which opens its session."
  (promo-rec-event 'click :xy (promo-story--card-xy regexp) :label "task card")
  (promo-story--open-card regexp))

(defun promo-story--click-verify (regexp)
  "The person clicks [Verify] on the card of the task REGEXP names."
  (promo-rec-event 'click :xy (promo-story--button-xy regexp "[Verify]") :label "Verify")
  (promo-story--push-button regexp "[Verify]"))

(defun promo-story-tasks ()
  "Record the task board, landed in the left window, in use."
  (push (cons "health check" #'promo-story--task-health) promo-rec-scripts)
  (push (cons "paginate" #'promo-story--task-pagination) promo-rec-scripts)
  (push (cons "slow requests" #'promo-story--task-slow) promo-rec-scripts)
  (push '("health check" . "Add a health check endpoint") harness-media--titles)
  (push '("paginate" . "Paginate GET /orders") harness-media--titles)
  (push '("slow requests" . "Log slow requests") harness-media--titles)
  (promo-story--enable '(tasks merge tools-handin))
  (promo-story--history)
  (select-window (frame-first-window))
  (harness-tasks harness-media-project 'fullscreen)
  (harness-media--settle 1.5)
  (setq promo-story--board (selected-window))
  (promo-rec-rect :board (promo-rec-window-rect promo-story--board))
  (promo-rec-begin "tasks")
  (promo-rec-mark "start")
  ;; The named title docks before the first word is typed, and the three
  ;; tasks are typed with a breath between them, each submitted as it is done.
  (let* ((s1 (promo-story--typed-task 80 "add a health check endpoint" 18))
         (s2 (promo-story--typed-task (+ s1 16) "paginate GET /orders" 16))
         (s3 (promo-story--typed-task (+ s2 14) "log slow requests" 15)))
    (promo-rec-mark-at s1 "submit-1")
    (promo-rec-mark-at s2 "submit-2")
    (promo-rec-mark-at s3 "submit-3")
    ;; Three agents at work at once; the second task's card is opened: its session takes the right half.
    (promo-rec-callout-at (+ s3 6) (lambda () (promo-story--section-rect "In progress" "Pending"))
                          "three agents at work, side by side" :side "right" :frames 64)
    (promo-rec-at (+ s3 22) (lambda () (promo-story--click-card "paginate")))
    (promo-rec-callout-at (+ s3 74) #'promo-story--worktree-rect
                          "each task in its own git worktree" :side "above" :frames 72)
    ;; The first to finish is read -- its report is its session's -- and verified, which merges it.
    (promo-rec-when-at
     (+ s3 150) (lambda () (promo-story--ready-p "health check"))
     (lambda ()
       (promo-rec-mark "review-1")
       (promo-rec-highlight-at (promo-rec-frame) (lambda () (promo-story--card-rect "health check")) "ready")
       (promo-rec-callout-at (+ (promo-rec-frame) 6) (lambda () (promo-story--card-rect "health check"))
                             "finished work waits for your review" :side "above" :frames 76)
       ;; The card opens its report; it sits long enough to be read.
       (promo-rec-after 10 (lambda () (promo-story--click-card "health check")))
       (promo-rec-after
        84 (lambda ()
             (promo-rec-mark "verify-1")
             (promo-story--click-verify "health check")
             ;; It merges, and is among the completed.
             (promo-rec-callout-at (+ (promo-rec-frame) 6) #'promo-story--completed-rect
                                   "verify it, and it merges back" :side "below" :frames 70)
             ;; The next one is verified a moment after, as soon as it has been through the merge queue's turn.
             (promo-rec-when-at
              (+ (promo-rec-frame) 40) (lambda () (and (promo-story--done-p "health check") (promo-story--ready-p "paginate")))
              (lambda ()
                (promo-rec-mark "verify-2")
                (promo-story--click-verify "paginate"))
              "the second task to be reviewed"))))
     "the first task to be ready for review"))
  (promo-rec-play promo-story-tasks-frames)
  (promo-rec-mark "end")
  (promo-rec-end))

;;;; The story

(defun promo-story-record ()
  "Record the segments asked for in PROMO_STORY_SEGMENTS (all of them when none
are named)."
  (let ((only (split-string (or (getenv "PROMO_STORY_SEGMENTS") "") "[ ,]+" t)))
    (dolist (segment '(("intro" . promo-story-intro) ("tasks" . promo-story-tasks)))
      (when (or (null only) (member (car segment) only))
        (funcall (cdr segment))))))

(setq promo-rec-story-function #'promo-story-record)

(provide 'promo-story)
;;; promo-story.el ends here
