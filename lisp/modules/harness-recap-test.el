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
(defvar harness-tasks-recap-chats)
(defvar harness-tasks-recap-history)
(defvar harness-recap--runs)
(declare-function make-harness-agent-turn "harness-agent")
(declare-function harness-recap-history "harness-recap")
(declare-function harness-recap--chat-maybe "harness-recap")
(declare-function harness-short-id "harness-util")
(declare-function harness-recap-sanitise "harness-recap")
(declare-function harness-recap--maybe "harness-recap")
(declare-function harness-recap--due-p "harness-recap")
(declare-function harness-recap--model "harness-recap")
(declare-function harness-recap--request "harness-recap")
(declare-function harness-replay-seam "harness-replay")
(declare-function harness-replay-seam-keep "harness-replay")

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
     (clrhash harness-recap--runs)
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
           (harness-tasks-recap-chats t)
           (harness-tasks-recap-history 5)
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

(ert-deftest harness-recap-reads-a-small-part-of-the-transcript ()
  "A recap is one line, so it reads a few thousand characters, not the log.
The request carries the newest of what the transcript holds, cut to
`harness-tasks-recap-context', so a long turn of file dumps and test
logs costs the same as a short one, and a first line says how much was
left out."
  (harness-recap-test-with
    (let ((sid (harness-recap-test-session)))
      (dotimes (i 50)
        (harness-call 'session/append sid
                      (list :kind 'assistant
                            :content (format "step %02d %s" i (make-string 300 ?x)))))
      (let ((work (harness-recap--work (harness-call 'session/nodes sid) nil)))
        (should (<= (length work) (+ harness-tasks-recap-context 60)))
        (should (string-match-p "\\`\\[[0-9]+ earlier entries left out\\]\n" work))
        (should (string-suffix-p (format "step 49 %s" (make-string 300 ?x)) work))
        (should-not (string-match-p "step 00 " work)))
      ;; Zero carries the whole transcript, as it always did.
      (let ((harness-tasks-recap-context 0))
        (should (> (length (harness-recap--work (harness-call 'session/nodes sid) nil)) 10000)))
      ;; The request carries that, not the whole log: the assignment and a
      ;; line of progress above it cost a few hundred characters.
      (let* ((task (list :prompt "Make the widget faster"))
             (session (harness-call 'session/get sid))
             (prompt (harness-recap--prompt task session))
             (newest (format "step 49 %s" (make-string 300 ?x))))
        (should (string-match-p "Recent transcript (oldest first, newest last):" prompt))
        (should (string-match-p (regexp-quote newest) prompt))
        (should-not (string-match-p "step 00 " prompt))
        (should (< (length prompt) (+ harness-tasks-recap-context 1000)))))))

(ert-deftest harness-recap-a-tool-result-takes-a-small-part-of-the-work ()
  "A long tool result is cut short, so the entries around it are read.
The work a recap carries is cut to `harness-tasks-recap-context': a file
dump or a test log that fills it would leave the messages and calls that
say what the work is doing out of the request."
  (harness-recap-test-with
    (let ((sid (harness-recap-test-session)))
      (harness-call 'session/append sid (list :kind 'assistant :content "Before the dump."))
      (harness-call 'session/append sid
                    (list :kind 'tool-result :call-id "c1"
                          :output (mapconcat (lambda (i) (format "line %03d %s" i (make-string 200 ?x)))
                                             (number-sequence 1 50) "\n")))
      (harness-call 'session/append sid (list :kind 'assistant :content "After the dump."))
      (let* ((nodes (harness-call 'session/nodes sid))
             (work (harness-recap--work nodes nil))
             (result (cl-find-if (lambda (line) (string-prefix-p "[result] " line))
                                 (split-string work "\n"))))
        (should (string-match-p "Before the dump\\." work))
        (should (string-match-p "After the dump\\." work))
        (should result)
        (should (<= (length result) harness-recap--result-chars))
        (should-not (string-match-p "line 010" work))
        (should (< (length work) 2000))))))


(ert-deftest harness-recap-does-not-read-or-replace-the-conversation-prefix ()
  "Real recap requests leave a parent's frozen bytes and strict guard intact."
  (harness-recap-test-with
    (harness-test-load-module 'replay)
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (session (harness-call 'session/get sid))
           (request (list :model "m" :session session))
           (body (list :model "m" :messages
                       (list (list :role "system" :content "Conversation é")
                             (list :role "user" :content "Work"))))
           (recap (harness-recap--request session (harness-recap-test-record id) "m"))
           (recap-body (list :model "m" :messages
                             (list (list :role "system" :content (plist-get recap :system))
                                   (list :role "user" :content "Summarize")))))
      ;; First a recap before the first real request must not establish a prefix.
      (should-not (cdr (harness-replay-seam recap "m" "route" recap-body)))
      (harness-replay-seam-keep recap "m" "route" recap-body)
      (should-not (harness-call 'replay/frozen-status sid))
      (harness-replay-seam-keep request "m" "route" body)
      (let ((before (copy-tree (harness-call 'replay/frozen-status sid)))
            (wire (car (harness-replay-seam request "m" "route" body))))
        ;; Then another recap with a completely different system is independent.
        (should-not (cdr (harness-replay-seam recap "m" "route" recap-body)))
        (harness-replay-seam-keep recap "m" "route" recap-body)
        (should (equal before (harness-call 'replay/frozen-status sid)))
        (should (equal wire (car (harness-replay-seam request "m" "route" body))))
        ;; The recap left the conversation's own prefix alone, so a real
        ;; change of the conversation is the conversation's: it is recorded
        ;; as the reset it is and sent, never left refused for good.
        (let ((changed (copy-tree body)))
          (setf (plist-get (car (plist-get changed :messages)) :content) "Mutated")
          (should-not (cdr (harness-replay-seam request "m" "route" changed)))
          (should (equal "system"
                         (plist-get (harness-call 'replay/frozen-status sid) :reset)))))
      (should (equal "Recap" (plist-get recap :job)))
      (should (equal sid (plist-get recap :job-parent)))
      (should (equal session (plist-get recap :session))))))

(defun harness-recap-test-recovery-fixture ()
  "Create a parent and a witnessed recap prefix; return their ids."
  (harness-test-load-module 'replay)
  (let* ((model "openrouter:deepseek/deepseek-v4.1-flash-1017")
         (sid (harness-recap-test-session :model model))
         (task (harness-recap-test-task sid))
         (job (harness-call 'session/internal-start :job "Recap" :model model
                            :cwd (harness-test-temp-dir) :parent-id sid :prompt "Recap work"))
         (body (list :model "deepseek/deepseek-v4.1-flash-1017"
                     :messages (list (list :role "system" :content harness-recap--system-prompt)
                                     (list :role "user" :content
                                           (list (list :type "text" :text "Recap work"))))
                     :reasoning (list :effort "none"))))
    (harness-call 'session/append sid '(:kind user :content "Original assignment"))
    (harness-call 'session/hint sid "Error: HTTP 400")
    (harness-call 'replay/frozen-record sid body model "openrouter|-|https://openrouter.ai/api/v1")
    (harness-call 'session/internal-finish job :reply "UNCHANGED" :stop-reason 'end-turn)
    (harness-call 'session/append job
                  '(:kind hint :content "Slots changed"
                    :meta (:fold (:key "tool-slots-load"))))
    (list sid task job body)))

(ert-deftest harness-recap-recovery-archives-only-proven-prefix ()
  (harness-recap-test-with
    (pcase-let* ((`(,sid ,task ,job ,_) (harness-recap-test-recovery-fixture))
                 (before (copy-tree (harness-call 'session/nodes sid)))
                 (status (harness-call 'session/recap-recovery-status sid task))
                 (result (harness-call 'session/recover-recap-prefix sid task
                                      (plist-get status :generation) (plist-get status :sha256)))
                 (audit (plist-get result :transition))
                 (archive (harness-call 'store/load (plist-get audit :archive))))
      (should (equal job (plist-get status :job-id)))
      (should (plist-get archive :frozen))
      (should (equal (harness-json-encode-text before)
                     (harness-json-encode-text (plist-get archive :parent-nodes))))
      (should (equal before (harness-call 'session/nodes sid)))
      (should (equal sid (plist-get (harness-call 'task/get task) :session)))
      (should (= 0 (plist-get (harness-call 'replay/frozen-status sid) :bytes)))
      ;; A fresh main prefix is permitted, and a later change of it is
      ;; recorded and sent rather than refused.
      (let* ((req (list :session (harness-call 'session/get sid)))
             (body '(:model "m" :messages ((:role "system" :content "Main")))))
        (should-not (cdr (harness-replay-seam req "m" "route" body)))
        (harness-replay-seam-keep req "m" "route" body)
        (should-not (cdr (harness-replay-seam req "m" "route"
                                             '(:model "m" :messages ((:role "system" :content "Changed"))))))
        (should (equal "system"
                       (plist-get (harness-call 'replay/frozen-status sid) :reset)))))))

(ert-deftest harness-recap-recovery-refuses-stale-and-substantive-evidence ()
  (harness-recap-test-with
    (pcase-let* ((`(,sid ,task ,_ ,_) (harness-recap-test-recovery-fixture))
                 (status (harness-call 'session/recap-recovery-status sid task))
                 (before (harness-call 'replay/frozen-status sid)))
      (should-error (harness-call 'session/recover-recap-prefix sid task
                                 (1+ (plist-get status :generation)) (plist-get status :sha256)))
      (should-error (harness-call 'session/recover-recap-prefix sid task
                                 (plist-get status :generation) "wrong"))
      (should (equal before (harness-call 'replay/frozen-status sid)))
      (harness-call 'session/append sid '(:kind assistant :content "Real result"))
      (should-error (harness-call 'session/recap-recovery-status sid task))
      (should (equal before (harness-call 'replay/frozen-status sid))))))

(ert-deftest harness-recap-recovery-refuses-extra-fields-and-active-session ()
  (harness-recap-test-with
    (pcase-let* ((`(,sid ,task ,_ ,body) (harness-recap-test-recovery-fixture)))
      (puthash sid t harness-recap--running)
      (should-error (harness-call 'session/recap-recovery-status sid task))
      (remhash sid harness-recap--running)
      (harness-call 'session/set-status sid 'running)
      (should-error (harness-call 'session/recap-recovery-status sid task))
      (harness-call 'session/set-status sid 'idle)
      (harness-call 'replay/frozen-record sid (append body '(:tools ((:name "real-tool"))))
                    "openrouter:deepseek/deepseek-v4.1-flash-1017" "openrouter|-|https://openrouter.ai/api/v1")
      (should-error (harness-call 'session/recap-recovery-status sid task)))))

(ert-deftest harness-recap-recovery-refuses-ambiguous-witness ()
  (harness-recap-test-with
    (pcase-let* ((`(,sid ,task ,_ ,body) (harness-recap-test-recovery-fixture))
                 (model "openrouter:deepseek/deepseek-v4.1-flash-1017")
                 (job (harness-call 'session/internal-start :job "Recap" :model model
                                    :cwd (harness-test-temp-dir) :parent-id sid :prompt "Recap work")))
      (harness-call 'replay/frozen-record sid body model "openrouter|-|https://openrouter.ai/api/v1")
      (harness-call 'session/internal-finish job :reply "UNCHANGED" :stop-reason 'end-turn)
      ;; Place both witnessed responses after the kept body's timestamp.
      (let* ((sessions (harness-call 'session/list (list :kind 'internal :parent-id sid)))
             (at (plist-get (harness-replay--frozen-read sid) :at)))
        (dolist (session sessions)
          (let* ((nodes (harness-call 'session/nodes (plist-get session :id)))
                 (answer (cl-find-if (lambda (n) (eq (plist-get n :kind) 'assistant)) nodes)))
            (harness-call 'session/update-node (plist-get session :id) (plist-get answer :id)
                          :ts (+ at 0.1)))))
      (should-error (harness-call 'session/recap-recovery-status sid task)))))

(ert-deftest harness-recap-recovery-archive-failure-preserves-prefix ()
  (harness-recap-test-with
    (pcase-let* ((`(,sid ,task ,_ ,_) (harness-recap-test-recovery-fixture))
                 (status (harness-call 'session/recap-recovery-status sid task))
                 (before (harness-replay--frozen-read sid)))
      (cl-letf (((symbol-function 'harness-recap--archive-exclusive)
                 (lambda (&rest _) (error "Archive unavailable"))))
        (should-error (harness-call 'session/recover-recap-prefix sid task
                                   (plist-get status :generation) (plist-get status :sha256))))
      (should (equal before (harness-replay--frozen-read sid))))))

(ert-deftest harness-recap-recovery-refuses-concurrent-change-and-archive-overwrite ()
  (harness-recap-test-with
    (pcase-let* ((`(,sid ,task ,_ ,_) (harness-recap-test-recovery-fixture))
                 (status (harness-call 'session/recap-recovery-status sid task))
                 (before (harness-replay--frozen-read sid))
                 (save (symbol-function 'harness-recap--archive-exclusive)))
      (cl-letf (((symbol-function 'harness-recap--archive-exclusive)
                 (lambda (&rest args)
                   (prog1 (apply save args)
                     (harness-call 'session/update sid :silent t :name "Concurrent change")))))
        (should-error (harness-call 'session/recover-recap-prefix sid task
                                   (plist-get status :generation) (plist-get status :sha256))))
      (should (equal before (harness-replay--frozen-read sid)))
      ;; The abandoned attempt's archive remains evidence, never overwritten.
      (should-error (harness-call 'session/recover-recap-prefix sid task
                                 (plist-get status :generation) (plist-get status :sha256)))
      (should (equal before (harness-replay--frozen-read sid))))))

(ert-deftest harness-recap-recovery-concurrent-archive-writer-wins-intact ()
  "An archive created after the early check is never replaced, even in a race."
  (harness-recap-test-with
    (pcase-let* ((`(,sid ,task ,_ ,_) (harness-recap-test-recovery-fixture))
                 (status (harness-call 'session/recap-recovery-status sid task))
                 (before (harness-replay--frozen-read sid))
                 (link (symbol-function 'add-name-to-file))
                 (path (harness-replay--file
                        (format "sessions/%s.recap-recovery-%s.json"
                                sid (plist-get status :generation))))
                 (sentinel "Other writer's immutable evidence\n"))
      (cl-letf (((symbol-function 'add-name-to-file)
                 (lambda (from to &optional overwrite)
                   (should (equal to path))
                   (should-not overwrite)
                   ;; Another writer publishes after validation, before ours.
                   (with-temp-file to (insert sentinel))
                   (funcall link from to overwrite))))
        (should-error (harness-call 'session/recover-recap-prefix sid task
                                   (plist-get status :generation) (plist-get status :sha256))
                      :type 'file-already-exists))
      (should (equal sentinel (harness-read-file path)))
      (should (equal before (harness-replay--frozen-read sid)))
      (should-not (directory-files (file-name-directory path) nil "\\`\\.recap-archive-")))))

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
        ;; Recorded as an internal session of the session recapped.
        (should (equal "Recap" (plist-get req :job)))
        (should (eq t (plist-get req :ephemeral)))
        (should (equal sid (plist-get req :job-parent)))
        (should (equal (list (list "Recap" sid 'idle))
                       (mapcar (lambda (s) (list (plist-get s :name) (plist-get s :parent-id) (plist-get s :status)))
                               (harness-call 'session/select '(:kind internal)))))
        (should-not (plist-get req :tools))
        ;; A recap is one short line: thinking is off unless asked for.
        (should (eq t (plist-get req :no-thinking)))
        (should-not (plist-get req :thinking))
        (should (string-match-p "Do the widget" text))
        (should (string-match-p "Work so far: 2 turns, 1 tool call" text))
        (should (string-match-p "\\[tool read_file\\]" text))
        (should (string-match-p "Write the recap now" text))))))

(ert-deftest harness-recap-honours-a-thinking-level ()
  "A configured recap thinking level goes out instead of `:no-thinking'."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-turns 1)
           (harness-tasks-recap-thinking "high")
           (requests nil))
      (harness-call 'session/usage-add sid '(:turns 1))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should (equal "Implemented the widget, tests pass"
                       (harness-test-await (harness-recap--maybe sid)))))
      (let ((req (car requests)))
        (should (equal "high" (plist-get req :thinking)))
        (should-not (plist-get req :no-thinking))))))

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
  "`auto' takes the provider's simple tier; a name or nil says which model."
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
        (should (string-match-p "Work so far: 0 turns, 0 tool calls" text))))
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
      ;; The child's recap reached the note of the call that shows it,
      ;; while the child ran and the call watched it.
      (harness-test-wait
       (lambda () (cl-some (lambda (n) (string-match-p "recap: Implemented the widget, tests pass" n)) notes))
       10 "the child's recap in the note"))))

;;;; The recaps a session keeps

(defun harness-recap-test-texts (session-id)
  "Return the texts of the recaps kept for SESSION-ID, oldest first."
  (mapcar (lambda (record) (plist-get record :text)) (harness-recap-history session-id)))

(defun harness-recap-test-script-of (&rest texts)
  "Return a demo script override answering each recap request with the next of TEXTS."
  (let ((left texts))
    (lambda (_request)
      (let ((text (or (pop left) "Ran out of recaps")))
        (list (list :type 'text :delta text) '(:type done :stop-reason end-turn))))))

(defun harness-recap-test-run-turn (session-id)
  "Make the turn of SESSION-ID run, as `agent/turn-started' announces it."
  (puthash session-id (make-harness-agent-turn :session-id session-id :started (float-time))
           harness-agent--turns)
  (harness-emit 'agent/turn-started session-id))

(defun harness-recap-test-end-turn (session-id)
  "End the turn of SESSION-ID, as `agent/turn-ended' announces it."
  (remhash session-id harness-agent--turns)
  (harness-emit 'agent/turn-ended session-id 'end-turn))

(defun harness-recap-test-tool-results (session-id n)
  "Finish N tool calls in the running turn of SESSION-ID."
  (dotimes (_ n)
    (harness-recap-test-add-tool-calls session-id 1)
    (harness-emit 'agent/tool-result session-id nil)))

(ert-deftest harness-recap-task-recaps-are-kept-in-the-sessions-history ()
  "A card's recap is also added to the history of its session, a few of them."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override
            (harness-recap-test-script-of "First" "Second" "Third"))
           (harness-tasks-recap-history 2))
      (should-not (harness-recap-history sid))
      (dolist (text '("First" "Second" "Third"))
        (should (equal text (harness-test-await (harness-recap--maybe sid t)))))
      ;; The card shows the latest, the history the last two, oldest first.
      (should (equal "Third" (harness-recap-test-recap id)))
      (should (equal '("Second" "Third") (harness-recap-test-texts sid)))
      (should (cl-every (lambda (record) (numberp (plist-get record :at)))
                        (harness-recap-history sid)))
      ;; The history is part of the session record, which is what a client is sent.
      (should (equal '("Second" "Third")
                     (mapcar (lambda (record) (plist-get record :text))
                             (plist-get (plist-get (harness-call 'session/get sid) :ext) :recaps)))))))

(ert-deftest harness-recap-history-survives-the-store ()
  "The history comes back from the JSON store of the session record as it was."
  (harness-recap-test-with
    (let ((sid (harness-recap-test-session)))
      (harness-call 'session/set-ext sid :recaps
                    (list (list :text "One" :at 1700000000.5) (list :text "Two" :at 1700000100.25)))
      ;; The record, as JSON writes it and the session reads it back.
      (let* ((record (harness-session-plist (gethash sid harness-sessions)))
             (stored (harness-json-parse (harness-json-encode record))))
        (should (equal (list (list :text "One" :at 1700000000.5) (list :text "Two" :at 1700000100.25))
                       (plist-get (harness-session-ext (harness-session--from-plist stored)) :recaps))))
      ;; And from the store itself, after the harness exited and started again.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal '("One" "Two") (harness-recap-test-texts sid)))
      (should (equal 1700000100.25 (plist-get (cadr (harness-recap-history sid)) :at)))
      ;; A record that is no recap, or a blank one, is not one to show.
      (harness-call 'session/set-ext sid :recaps
                    (list (list :text "  " :at 1.0) (list :text "Kept" :at 2.0) 17))
      (should (equal '("Kept") (harness-recap-test-texts sid)))
      ;; One record alone, as a store may give a list of one back.
      (harness-call 'session/set-ext sid :recaps (list :text "Alone" :at 3.0))
      (should (equal '("Alone") (harness-recap-test-texts sid)))
      (harness-call 'session/set-ext sid :recaps nil)
      (should-not (harness-recap-history sid)))))

(ert-deftest harness-recap-a-subagents-recap-is-kept-in-its-history ()
  "A recap made for a sub-agent's session, on demand, joins its history too."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-child))
           (harness-provider-demo-script-override harness-recap-test-script))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      (harness-test-await (harness-recap--session-maybe sid (harness-call 'session/get sid) t))
      (should (equal '("Implemented the widget, tests pass") (harness-recap-test-texts sid))))))

;;;; Recaps of a chat while its turn runs

(ert-deftest harness-recap-chat-is-recapped-as-its-turn-runs ()
  "A session that is no task's gets a recap of its running turn, and keeps the last few.
The request carries the message the turn answers and how long the turn
has run, and counting starts anew with each recap."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override
            (harness-recap-test-script-of "Read the parser" "Wrote the test" "Fixed the parser"))
           (harness-tasks-recap-tool-calls 2)
           (harness-tasks-recap-history 2)
           (requests nil))
      (harness-call 'session/append sid '(:kind user :content "an old request"))
      (harness-call 'session/append sid '(:kind assistant :content "done"))
      (harness-call 'session/append sid '(:kind user :content "refactor the parser"))
      (harness-recap-test-run-turn sid)
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        ;; One tool call is not enough, the second is.
        (harness-recap-test-tool-results sid 1)
        (should-not requests)
        (harness-recap-test-tool-results sid 1)
        (harness-test-wait (lambda () (harness-recap-history sid)) 5 "the first recap")
        (should (equal '("Read the parser") (harness-recap-test-texts sid)))
        (let* ((req (car requests))
               (message (car (last (plist-get req :messages))))
               (text (plist-get (car (plist-get message :content)) :text)))
          (should (equal "Recap" (plist-get req :job)))
          (should (string-match-p "Task (the assignment; do not restate it): refactor the parser" text))
          (should-not (string-match-p "do not restate it): an old request" text))
          (should (string-match-p "Progress: the current turn has been running for" text))
          (should-not (string-match-p "Work so far: [0-9]+ turns" text)))
        ;; Counting began again with it: one more call is not due, two are.
        (harness-recap-test-tool-results sid 1)
        (should (= 1 (length requests)))
        (harness-recap-test-tool-results sid 1)
        (harness-test-wait (lambda () (= 2 (length (harness-recap-history sid)))) 5 "the second recap")
        (harness-recap-test-tool-results sid 2)
        (harness-test-wait (lambda () (equal '("Wrote the test" "Fixed the parser")
                                             (harness-recap-test-texts sid)))
                           5 "the third recap, the first one dropped"))
      (should (= 3 (length requests)))
      ;; The kept record says when each was made.
      (should (cl-every (lambda (record) (numberp (plist-get record :at)))
                        (harness-recap-history sid))))))

(ert-deftest harness-recap-chat-counts-from-its-turn-not-its-session ()
  "An old conversation is not due a recap the moment its turn starts.
The card's seconds threshold counts from the start of the session when
no recap was made; a chat counts from the start of its turn."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-seconds 120)
           (started nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (setq started t) (funcall orig req))))
        ;; A session made a day ago: the card's baseline, the session's
        ;; start, is long past, and it would be due at once.
        (setf (cl-struct-slot-value 'harness-session 'created (gethash sid harness-sessions))
              (- (float-time) 86400))
        (should (harness-recap--due-p (list :started (- (float-time) 86400)) 0 0 (float-time)))
        (harness-recap-test-run-turn sid)
        (should-not (harness-recap--chat-maybe sid))
        (harness-emit 'agent/tool-result sid nil)
        (should-not started)
        ;; Two minutes into the turn it is.
        (puthash sid (list :started (- (float-time) 130) :at (- (float-time) 130) :tools 0)
                 harness-recap--runs)
        (should (harness-recap--chat-maybe sid))
        (harness-test-wait (lambda () (harness-recap-history sid)) 5 "the recap")
        (should started)))))

(ert-deftest harness-recap-chat-recapped-on-time-by-the-timer-check ()
  "The check that runs every few seconds recaps a quiet turn that has run long enough."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-seconds 120))
      (harness-recap-test-run-turn sid)
      (harness-recap--check-running)
      (should-not (harness-recap-history sid))
      (puthash sid (list :started (- (float-time) 300) :at (- (float-time) 300) :tools 0)
               harness-recap--runs)
      (harness-recap--check-running)
      (harness-test-wait (lambda () (harness-recap-history sid)) 5 "the recap on time")
      (should (equal '("Implemented the widget, tests pass") (harness-recap-test-texts sid))))))

(ert-deftest harness-recap-chat-recaps-nothing-once-its-turn-ended ()
  "A turn that ended is not recapped, and nothing is counted for it any more."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-tool-calls 1)
           (started nil))
      (harness-recap-test-run-turn sid)
      (should (gethash sid harness-recap--runs))
      (harness-recap-test-end-turn sid)
      (should-not (gethash sid harness-recap--runs))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (setq started t) (funcall orig req))))
        (harness-recap-test-tool-results sid 3)
        (harness-recap--check-running)
        (should-not (harness-recap--maybe sid t))
        (should-not started)
        (should-not (gethash sid harness-recap--runs))
        (should-not (harness-recap-history sid))))))

(ert-deftest harness-recap-chat-can-be-turned-off ()
  "With `harness-tasks-recap-chats' nil, or recaps off, a chat gets none."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-tool-calls 1)
           (started nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (setq started t) (funcall orig req))))
        (let ((harness-tasks-recap-chats nil))
          (harness-recap-test-run-turn sid)
          (harness-recap-test-tool-results sid 2))
        (let ((harness-tasks-recap nil))
          (harness-recap-test-tool-results sid 2))
        (should-not started)
        (should-not (harness-recap-history sid))
        ;; Back on, the next call is due.
        (harness-recap-test-tool-results sid 1)
        (harness-test-wait (lambda () (harness-recap-history sid)) 5 "the recap, with the setting back on")))))

(ert-deftest harness-recap-chat-skips-internal-sessions-and-seeds ()
  "The record of a model call and a prompt-cache seed have nothing to recap."
  (harness-recap-test-with
    (let* ((seed (harness-recap-test-session :ext '(:seed t)))
           (internal (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                              :model "demo:scripted" :kind 'internal)
                                :id))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-tool-calls 1)
           (started nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (setq started t) (funcall orig req))))
        (dolist (sid (list seed internal))
          (harness-recap-test-run-turn sid)
          (harness-recap-test-tool-results sid 2))
        (should-not started)))))

(ert-deftest harness-recap-chat-drops-the-last-turns-recaps-but-a-task-keeps-its ()
  "A new turn of a chat starts without the last turn's recaps; a task's stay.
A task's recap is the work so far, which its card keeps."
  (harness-recap-test-with
    (let* ((chat (harness-recap-test-session))
           (task-session (harness-recap-test-session)))
      (harness-recap-test-task task-session)
      (dolist (sid (list chat task-session))
        (harness-call 'session/set-ext sid :recaps (list (list :text "Last turn's" :at 1.0))))
      (harness-recap-test-run-turn chat)
      (harness-recap-test-run-turn task-session)
      (should-not (harness-recap-history chat))
      (should (equal '("Last turn's") (harness-recap-test-texts task-session)))
      ;; Only a session with a history is written to.
      (let ((changes 0))
        (harness-on 'session/ext-changed (lambda (&rest _) (cl-incf changes)))
        (harness-recap-test-run-turn chat)
        (should (zerop changes))))))

(ert-deftest harness-recap-chat-backs-off-after-a-failure ()
  "A chat's failed recap waits `harness-tasks-recap-retry' seconds like any other."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override
            '((:type done :stop-reason error :error "the model is down")))
           (harness-tasks-recap-tool-calls 1))
      (harness-recap-test-run-turn sid)
      (harness-recap-test-add-tool-calls sid 1)
      (harness-emit 'agent/tool-result sid nil)
      (harness-test-wait (lambda () (gethash sid harness-recap--session-failed)) 5 "the failure")
      (should-not (harness-recap-history sid))
      (harness-recap-test-tool-results sid 3)
      (should-not (gethash sid harness-recap--session-running)))))

(ert-deftest harness-recap-chat-counting-restarts-with-any-recap ()
  "A recap of a running chat asked for another way is in its count too.
The pet and the notes under the calls that show a session ask for one
\(`harness-recap-session'); the chat's own comes after the seconds and
tool calls that follow it, not twice in a row."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-tool-calls 3)
           (requests 0))
      (harness-recap-test-run-turn sid)
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf requests) (funcall orig req))))
        (harness-recap-test-tool-results sid 2)
        (should (= 2 (plist-get (gethash sid harness-recap--runs) :tools)))
        (should (zerop requests))
        ;; Asked for by force, as the pet does.
        (should (harness-recap--session-maybe sid (harness-call 'session/get sid) t))
        (should (= 1 requests))
        (should (= 0 (plist-get (gethash sid harness-recap--runs) :tools)))
        (harness-test-wait (lambda () (harness-recap-history sid)) 5 "the recap")
        ;; One more call is not due, as it would have been (the third).
        (harness-recap-test-tool-results sid 1)
        (should (= 1 requests))
        (should (equal '("Implemented the widget, tests pass") (harness-recap-test-texts sid)))))))

(ert-deftest harness-recap-shutdown-stops-listening-and-init-starts-again ()
  "A stopped recap module makes no recap and counts nothing; started again, it does."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-tool-calls 2))
      (harness-recap--shutdown)
      (harness-recap-test-run-turn sid)
      (harness-recap-test-tool-results sid 3)
      (should-not (gethash sid harness-recap--runs))
      (should-not (harness-recap-history sid))
      ;; Started again, as a reload starts it: the next turn is counted.
      (harness-recap--init)
      (harness-recap-test-end-turn sid)
      (harness-recap-test-run-turn sid)
      (should (gethash sid harness-recap--runs))
      (harness-recap-test-tool-results sid 2)
      (harness-test-wait (lambda () (harness-recap-history sid)) 5 "the recap, after the module started again")
      (harness-recap--shutdown))))

;;;; What a recap says: recent work, not the assignment

;; The request is what makes a recap concrete.  These tests read the
;; prompt it sends: the assignment is labelled and must not be restated,
;; the work since the previous recap is what it carries, and a recap in
;; hand travels with it so the model can tell what is new.  They read the
;; answers too: `UNCHANGED', and a line that only repeats what is already
;; known, leave the recap in hand in place rather than make one up.

(defun harness-recap-test-prompt-text (request)
  "Return the text of the user message of REQUEST, a recap request."
  (plist-get (car (plist-get (car (last (plist-get request :messages))) :content)) :text))

(ert-deftest harness-recap-prompt-asks-for-the-work-since-the-last-one ()
  "The request labels the assignment, and carries the recap in hand and the work after it."
  (harness-recap-test-with
    (let ((sid (harness-recap-test-session)))
      (harness-call 'session/append sid '(:kind user :content "Make the widget faster"))
      (harness-call 'session/append sid '(:kind assistant :content "Reading the widget code."))
      (harness-call 'session/append sid '(:kind tool-call :tool "read_file" :call-id "c1"
                                                       :title "Read widget.el"))
      (let* ((first-node (plist-get (car (last (harness-call 'session/nodes sid))) :id))
             (task (list :id "t-1" :prompt "Make the widget faster"))
             (session (harness-call 'session/get sid))
             (first (harness-recap--prompt task session)))
        ;; Before any recap the request labels the assignment, says what
        ;; the work is so far, and carries the transcript from its start.
        (should (string-match-p
                 "\\`Task (the assignment; do not restate it): Make the widget faster" first))
        (should (string-match-p "Work so far: 0 turns, 1 tool call" first))
        (should (string-match-p "Recent transcript (oldest first, newest last):" first))
        (should (string-match-p "\\[tool read_file\\] Read widget.el" first))
        (should (string-match-p "Write the recap now: one short sentence" first))
        (should-not (string-match-p "Previous recap:" first))
        ;; Now it has one: the next request carries it, counts the work
        ;; since it was made, and carries only what came after its node.
        (harness-call 'session/append sid '(:kind assistant :content "The parser test fails."))
        (harness-call 'session/append sid '(:kind tool-call :tool "bash" :call-id "c2"
                                                         :title "Bash: scripts/test.sh"))
        (let* ((task (list :id "t-1" :prompt "Make the widget faster"
                           :recap "Read widget.el; the parser test fails"
                           :recap-turns 0 :recap-tools 1 :recap-node first-node))
               (second (harness-recap--prompt task session)))
          (should (string-match-p "Previous recap: Read widget.el; the parser test fails" second))
          (should (string-match-p "Since the previous recap: 0 turns, 1 tool call" second))
          (should (string-match-p
                   "What happened since the previous recap (oldest first, newest last):" second))
          (should (string-match-p "\\[agent\\] The parser test fails\\." second))
          (should (string-match-p "\\[tool bash\\] Bash: scripts/test.sh" second))
          ;; What the last recap already told of is not asked about again:
          ;; the work section starts after its node.
          (let ((work (substring second (string-match-p "What happened since the previous recap" second))))
            (should-not (string-match-p "Reading the widget code" work))
            (should-not (string-match-p "Read widget.el" work))))))))

(ert-deftest harness-recap-prompt-carries-a-blocker ()
  "A turn that stopped for the user is the blocker the request reports."
  (harness-recap-test-with
    (let ((sid (harness-recap-test-session)))
      (harness-call 'session/append sid '(:kind user :content "Make the widget faster"))
      (harness-call 'session/pending-add sid (list :kind 'permission
                                                   :payload (list :tool "Bash" :title "Bash: npm test")))
      (harness-call 'session/append sid '(:kind assistant :content "The parser test fails."))
      (let* ((task (list :id "t-1" :prompt "Make the widget faster"))
             (prompt (harness-recap--prompt task (harness-call 'session/get sid))))
        (should (string-match-p "The work waits on the engineer: permission for Bash" prompt))
        (should (string-match-p "Say what it waits for\\." prompt))
        ;; It comes before the work, which the engineer's answer unblocks.
        (should (< (string-match-p "The work waits on the engineer" prompt)
                   (string-match-p "Recent transcript" prompt)))))))

(ert-deftest harness-recap-unchanged-keeps-the-line-in-hand ()
  "UNCHANGED leaves the recap as it was: no new line, no new history, no made-up work."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override
            (harness-recap-test-script-of "Read the parser" "UNCHANGED"))
           (harness-tasks-recap-tool-calls 1)
           (changes 0))
      (harness-call 'session/append sid '(:kind user :content "Do the widget"))
      (harness-recap-test-add-tool-calls sid 1)
      (should (equal "Read the parser" (harness-test-await (harness-recap--maybe sid))))
      (should (equal "Read the parser" (harness-recap-test-recap id)))
      (should (equal '("Read the parser") (harness-recap-test-texts sid)))
      (let ((node (plist-get (car (last (harness-call 'session/nodes sid))) :id)))
        (should (equal node (plist-get (harness-recap-test-record id) :recap-node))))
      (harness-on 'recap/done (lambda (&rest _) (cl-incf changes)))
      ;; More work comes, the model is asked, and finds nothing new in it.
      (harness-recap-test-add-tool-calls sid 1)
      (should (equal "Read the parser" (harness-test-await (harness-recap--maybe sid t))))
      (should (equal "Read the parser" (harness-recap-test-recap id)))
      ;; The line in hand stays, alone in the history: nothing was made up.
      (should (equal '("Read the parser") (harness-recap-test-texts sid)))
      (should (zerop changes))
      ;; The counters moved on, so the same stretch is not asked about again.
      (should (= 2 (plist-get (harness-recap-test-record id) :recap-tools))))))

(ert-deftest harness-recap-a-restatement-is-no-new-progress ()
  "A line that only repeats the task or the recap in hand is not a new accomplishment."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override
            (harness-recap-test-script-of "Read the parser" "Do the widget" "Read the parser"))
           (harness-tasks-recap-tool-calls 1))
      (harness-call 'session/append sid '(:kind user :content "Do the widget"))
      (harness-recap-test-add-tool-calls sid 1)
      (harness-test-await (harness-recap--maybe sid))
      (should (equal '("Read the parser") (harness-recap-test-texts sid)))
      ;; The assignment, word for word: the recap in hand stays.
      (harness-recap-test-add-tool-calls sid 1)
      (should (equal "Read the parser" (harness-test-await (harness-recap--maybe sid t))))
      (should (equal "Read the parser" (harness-recap-test-recap id)))
      (should (equal '("Read the parser") (harness-recap-test-texts sid)))
      ;; And so does the recap in hand, said again in other punctuation.
      (harness-recap-test-add-tool-calls sid 1)
      (should (equal "Read the parser" (harness-test-await (harness-recap--maybe sid t))))
      (should (equal '("Read the parser") (harness-recap-test-texts sid))))))

(ert-deftest harness-recap-a-quiet-task-is-not-asked-again ()
  "A task whose transcript has not moved since its recap makes no request."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-session))
           (id (harness-recap-test-task sid))
           (harness-provider-demo-script-override harness-recap-test-script)
           (harness-tasks-recap-turns 1)
           (requests 0))
      (harness-call 'session/append sid '(:kind user :content "Do the widget"))
      (harness-call 'session/usage-add sid '(:turns 1))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf requests) (funcall orig req))))
        (harness-test-await (harness-recap--maybe sid))
        (should (= 1 requests))
        ;; The threshold is crossed again -- a turn, a tool call -- but the
        ;; transcript did not grow: there is nothing new to report.
        (harness-call 'session/usage-add sid '(:turns 1))
        (should-not (harness-recap--maybe sid))
        (should (= 1 requests))
        ;; A node arrives, and the next is asked for.
        (harness-call 'session/append sid '(:kind assistant :content "Wrote the parser test."))
        (should (harness-recap--maybe sid))
        (harness-test-wait (lambda () (= 2 requests)) 5 "the next recap")))))

(ert-deftest harness-recap-a-session-recap-reads-the-work-since-its-own ()
  "A sub-agent's recap, refreshed, carries the line in hand and only what came after it."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-child))
           (harness-provider-demo-script-override
            (harness-recap-test-script-of "Read the parser" "Fixed the parser test"))
           (harness-tasks-recap-tool-calls 1)
           (requests nil))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      (harness-recap-test-add-tool-calls sid 1)
      (harness-test-await (harness-recap--session-maybe sid (harness-call 'session/get sid) nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (harness-call 'session/append sid '(:kind assistant :content "The parser test passes."))
        (harness-recap-test-add-tool-calls sid 1)
        (harness-test-await (harness-recap--session-maybe sid (harness-call 'session/get sid) nil)))
      (let* ((req (car requests))
             (text (harness-recap-test-prompt-text req)))
        (should (string-match-p "Previous recap: Read the parser" text))
        (should (string-match-p "What happened since the previous recap" text))
        (should (string-match-p "\\[agent\\] The parser test passes\\." text))
        ;; The work the first recap told of is left out of the second.
        (should-not (string-match-p "\\[engineer\\] do the widget" text)))
      (should (equal '("Read the parser" "Fixed the parser test")
                     (harness-recap-test-texts sid))))))

(ert-deftest harness-recap-unchanged-does-not-repeat-the-same-line-in-history ()
  "A session recap answered UNCHANGED keeps the line in hand and adds nothing."
  (harness-recap-test-with
    (let* ((sid (harness-recap-test-child))
           (harness-provider-demo-script-override
            (harness-recap-test-script-of "Read the parser" "UNCHANGED"))
           (harness-tasks-recap-tool-calls 1))
      (harness-call 'session/append sid '(:kind user :content "do the widget"))
      (harness-recap-test-add-tool-calls sid 1)
      (harness-test-await (harness-recap--session-maybe sid (harness-call 'session/get sid) nil))
      (harness-call 'session/append sid '(:kind assistant :content "Still reading."))
      (harness-recap-test-add-tool-calls sid 1)
      (should (equal "Read the parser"
                     (harness-test-await (harness-recap--session-maybe sid (harness-call 'session/get sid) nil))))
      (should (equal '("Read the parser") (harness-recap-test-texts sid)))
      (should (equal "Read the parser" (plist-get (harness-recap-session sid) :text))))))

(ert-deftest harness-recap-the-system-prompt-asks-for-what-changed ()
  "The registry's system prompt forbids restating the task and makes up nothing."
  (let ((system (harness-prompt-default 'recap-system)))
    (should (string-match-p "since the previous recap" system))
    (should (string-match-p "Do not restate the task" system))
    (should (string-match-p "UNCHANGED" system)))
  (should (string-match-p "UNCHANGED" (harness-prompt-default 'recap-ask))))
