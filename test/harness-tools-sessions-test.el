;;; harness-tools-sessions-test.el --- Tests for the session and task tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-tools-agent--questions)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-tools-sessions--waiters)

(defconst harness-tools-sessions-test-script
  '((:type text :delta "Reply from ") (:type text :delta "the other session.") (:type done :stop-reason end-turn)))

(defmacro harness-tools-sessions-test-with (&rest body)
  "Load the state layer, tasks and the session tools with the demo provider; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-agent tasks tools-sessions))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-tools-agent--questions)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tools-sessions--waiters)
     (setq harness-tasks--loaded t)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-tools-sessions-test-script)
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           ;; Finished tasks are done at once unless a test reviews them.
           (harness-tasks-require-verification nil)
           (harness-tasks-permission-mode 'auto)
           (harness-tasks-non-interactive t)
           (harness-tasks-model "demo:scripted")
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-sessions-test-session (&rest plist)
  "Create a demo session in the state directory and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd default-directory :model "demo:scripted" plist) :id))

(defun harness-tools-sessions-test-run (sid name input)
  "Run tool NAME with INPUT as session SID; return the result plist."
  (harness-test-await (harness-call 'tools/execute sid (list :id (harness-short-id) :name name :input input)) 10))

(defun harness-tools-sessions-test-ok (sid name input)
  "Run tool NAME as SID, assert it succeeded and return its text."
  (let ((r (harness-tools-sessions-test-run sid name input)))
    (should-not (plist-get r :is-error))
    (plist-get r :content)))

(defun harness-tools-sessions-test-idle (sid)
  (harness-test-wait (lambda () (and (not (harness-call 'agent/running sid))
                                     (eq 'idle (plist-get (harness-call 'session/get sid) :status))))
                     5 (format "%s idle" sid)))

(ert-deftest harness-tools-sessions-registers-tools ()
  (harness-tools-sessions-test-with
    (let ((names (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list))))
      (dolist (n '("session_list" "session_search" "session_read" "session_send" "session_control"
                   "session_wait" "task_list" "task_submit" "task_control" "task_wait"))
        (should (member n names))))
    (dolist (n '("session_list" "session_search" "session_read" "session_wait" "task_list" "task_wait"))
      (should (eq 'read (plist-get (harness-call 'tools/get n) :kind))))
    (dolist (n '("session_send" "session_control" "task_submit" "task_control"))
      (should (eq 'meta (plist-get (harness-call 'tools/get n) :kind))))))

(ert-deftest harness-tools-sessions-list-and-filters ()
  (harness-tools-sessions-test-with
    (let* ((me (harness-tools-sessions-test-session :name "Me"))
           (other (harness-tools-sessions-test-session :name "Parser fixer"))
           (child (harness-tools-sessions-test-session :name "Child" :parent-id other :kind 'subagent))
           (closed (harness-tools-sessions-test-session :name "Old one"))
           (elsewhere (let ((default-directory (harness-test-temp-dir)))
                        (harness-tools-sessions-test-session :name "Elsewhere"))))
      (harness-call 'session/deactivate closed)
      (let ((text (harness-tools-sessions-test-ok me "session_list" nil)))
        (should (string-match-p (regexp-quote (concat me)) text))
        (should (string-match-p "(this session)" text))
        (should (string-match-p (regexp-quote other) text))
        (should (string-match-p (regexp-quote child) text))
        (should-not (string-match-p (regexp-quote closed) text))
        (should-not (string-match-p (regexp-quote elsewhere) text)))
      (should (string-match-p (regexp-quote closed)
                              (harness-tools-sessions-test-ok me "session_list" '(:include_inactive t))))
      (should (string-match-p (regexp-quote elsewhere)
                              (harness-tools-sessions-test-ok me "session_list" '(:all_projects t))))
      (let ((text (harness-tools-sessions-test-ok me "session_list" (list :parent_id (substring other 0 8)))))
        (should (string-match-p (regexp-quote child) text))
        (should-not (string-match-p (regexp-quote me) text)))
      (should (string-match-p (regexp-quote other)
                              (harness-tools-sessions-test-ok me "session_list" '(:name "parser")))))))

(ert-deftest harness-tools-sessions-search-content ()
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Me"))
          (a (harness-tools-sessions-test-session :name "Alpha"))
          (b (harness-tools-sessions-test-session :name "Beta")))
      (harness-call 'session/append a '(:kind user :content "Please look at the \"zebra\" handler in lexer.el"))
      (harness-call 'session/append b '(:kind assistant :content "Nothing to see here."))
      (harness-call 'session/append b '(:kind tool-result :output "line 3: ZEBRA stripes"))
      (harness-call 'session/append me '(:kind user :content "zebra in my own session"))
      (let ((text (harness-tools-sessions-test-ok me "session_search" '(:query "zebra"))))
        (should (string-match-p (regexp-quote a) text))
        (should (string-match-p (regexp-quote b) text))
        (should (string-match-p "\"zebra\" handler" text))
        (should (string-match-p "ZEBRA stripes" text))
        (should-not (string-match-p (regexp-quote me) text)))
      ;; A quote inside the query is matched through the JSON escaping.
      (let ((text (harness-tools-sessions-test-ok me "session_search" '(:query "\"zebra\" handler"))))
        (should (string-match-p (regexp-quote a) text))
        (should-not (string-match-p (regexp-quote b) text)))
      ;; Names match without content.
      (should (string-match-p (regexp-quote b) (harness-tools-sessions-test-ok me "session_search" '(:query "beta"))))
      (should (string-match-p "No session mentions"
                              (harness-tools-sessions-test-ok me "session_search" '(:query "giraffe"))))
      (should (string-match-p (regexp-quote b)
                              (harness-tools-sessions-test-ok me "session_search" '(:query "ZEB+RA s" :regexp t)))))))

(ert-deftest harness-tools-sessions-non-ascii-tool-input ()
  ;; A tool call's input is shown as text: session_read gives it as it was
  ;; written, in a result that can go back to the model as JSON, and
  ;; session_search finds it.
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Me"))
          (other (harness-tools-sessions-test-session :name "Other"))
          (word "caf\N{U+E9} \N{U+2717}"))
      (harness-call 'session/append other (list :kind 'tool-call :tool "edit_file" :call-id "c1"
                                                :title "edit_file notes.md"
                                                :input (list :path "notes.md" :new_string word)))
      (let ((text (harness-tools-sessions-test-ok me "session_read" '(:session_id "Other"))))
        (should (string-search word text))
        (should (equal text (plist-get (harness-json-parse (harness-json-encode (list :text text))) :text))))
      (let ((text (harness-tools-sessions-test-ok me "session_search" (list :query word))))
        (should (string-search other text))
        (should (string-search word text))))))

(ert-deftest harness-tools-sessions-read-transcript ()
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session))
          (other (harness-tools-sessions-test-session :name "Other")))
      (dotimes (i 5)
        (harness-call 'session/append other (list :kind 'user :content (format "message %d" i))))
      (harness-call 'session/set-todos other '((:id "t1" :text "write tests" :status done)))
      (let ((text (harness-tools-sessions-test-ok me "session_read" (list :session_id "Other" :limit 2))))
        (should (string-match-p "message 4" text))
        (should (string-match-p "message 3" text))
        (should-not (string-match-p "message 2" text))
        (should (string-match-p "\\[x\\] write tests" text))
        (should (string-match-p "2 of 5 nodes; earlier ones with before=" text))
        (string-match "before=\\([^)]+\\))" text)
        (let ((older (harness-tools-sessions-test-ok me "session_read"
                                                     (list :session_id other :before (match-string 1 text)))))
          (should (string-match-p "message 0" older))
          (should-not (string-match-p "message 3" older))))
      (let ((r (harness-tools-sessions-test-run me "session_read" '(:session_id "nope"))))
        (should (plist-get r :is-error))
        (should (string-match-p "No session matches" (plist-get r :content)))))))

(ert-deftest harness-tools-sessions-send-and-wait-reply ()
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Boss"))
          (other (harness-tools-sessions-test-session)))
      (let ((text (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "status?" :wait t))))
        (should (string-match-p "turn ended: end-turn" text))
        (should (string-match-p "Reply from the other session." text)))
      (let ((user (cl-find 'user (harness-call 'session/nodes other) :key (lambda (n) (plist-get n :kind)))))
        (should (string-match-p (regexp-quote (format "[Message from session %s \"Boss\"]" me)) (plist-get user :content)))
        (should (string-match-p "status\\?" (plist-get user :content))))
      (let ((r (harness-tools-sessions-test-run me "session_send" (list :session_id me :message "hi"))))
        (should (plist-get r :is-error))
        (should (string-match-p "cannot message itself" (plist-get r :content)))))))

(ert-deftest harness-tools-sessions-send-says-who-sent-it ()
  "A message session_send delivers is the sending session's, not the user's.
Its node says so, a queued one too, and session_read and session_search
tell it from the user's messages."
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Boss"))
          (other (harness-tools-sessions-test-session :name "Worker"))
          (third (harness-tools-sessions-test-session :name "Onlooker")))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "status?" :wait t))
      (let ((user (cl-find 'user (harness-call 'session/nodes other) :key (lambda (n) (plist-get n :kind)))))
        (should (equal (list :kind 'session :id me :name "Boss") (harness-node-sender user))))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "later" :mode "queue"))
      (let ((item (car (plist-get (harness-call 'session/get other) :queue))))
        (should (string-suffix-p "later" (plist-get item :text)))
        (should (equal me (plist-get (plist-get item :from) :id))))
      (harness-call 'session/queue-take other)
      (harness-call 'session/append other '(:kind user :content "from the user"))
      (let ((tag (regexp-quote (format ", from session %s \"Boss\"]" me))))
        (let ((text (harness-tools-sessions-test-ok third "session_read" (list :session_id other))))
          (should (string-match-p (concat tag (regexp-quote " [Message from session")) text))
          (should (string-match-p "\\[user n-[a-z0-9]+\\] from the user" text)))
        (should (string-match-p tag (harness-tools-sessions-test-ok third "session_search" '(:query "status?"))))))))

(ert-deftest harness-tools-sessions-send-then-wait ()
  (harness-tools-sessions-test-with
    (let ((harness-provider-demo--delay 0.1)
          (me (harness-tools-sessions-test-session))
          (a (harness-tools-sessions-test-session))
          (b (harness-tools-sessions-test-session)))
      (should (string-match-p "started a turn" (harness-tools-sessions-test-ok me "session_send" (list :session_id a :message "go"))))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id b :message "go"))
      ;; Running at once: a wait right after the send cannot see a stale idle.
      (should (harness-call 'agent/running a))
      (let ((p (harness-call 'tools/execute me (list :id "w1" :name "session_wait" :input (list :session_ids (list a b))))))
        (should-not (harness-promise-settled-p p))
        (let ((text (plist-get (harness-test-await p 10) :content)))
          (should (string-match-p "Done waiting" text))
          (should (= 2 (cl-count-if (lambda (l) (string-match-p "Reply from the other session" l))
                                    (split-string text "\n"))))))
      (should (zerop (hash-table-count harness-tools-sessions--waiters))))))

(ert-deftest harness-tools-sessions-wait-timeout-and-any ()
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session))
          (idle (harness-tools-sessions-test-session)))
      ;; Already stopped: returns at once.
      (should (string-match-p "Done waiting" (harness-tools-sessions-test-ok me "session_wait" (list :session_id idle))))
      ;; Never starts running: times out with a report, not an error.
      (let ((text (harness-tools-sessions-test-ok me "session_wait" (list :session_id idle :until "running" :timeout_seconds 0.2))))
        (should (string-match-p "Still waiting" text))
        (should (string-match-p (regexp-quote idle) text)))
      (should (zerop (hash-table-count harness-tools-sessions--waiters))))))

(ert-deftest harness-tools-sessions-wait-ends-with-the-waiting-turn ()
  (harness-tools-sessions-test-with
    (let* ((me (harness-tools-sessions-test-session))
           (other (harness-tools-sessions-test-session))
           (p (harness-call 'tools/execute me (list :id "w" :name "session_wait"
                                                    :input (list :session_id other :until "running")))))
      (harness-test-wait (lambda () (= 1 (hash-table-count harness-tools-sessions--waiters))) 5 "a waiter")
      (harness-emit 'agent/turn-ended me 'cancelled)
      (should (string-match-p "interrupted" (plist-get (harness-test-await p 5) :content)))
      (should (zerop (hash-table-count harness-tools-sessions--waiters))))))

(ert-deftest harness-tools-sessions-wait-until-blocked-and-answer ()
  (harness-tools-sessions-test-with
    (let* ((me (harness-tools-sessions-test-session))
           (other (harness-tools-sessions-test-session))
           (wait (harness-call 'tools/execute me (list :id "w" :name "session_wait"
                                                       :input (list :session_id other :until "blocked"))))
           (ask (harness-call 'tools/execute other (list :id "q" :name "ask_user" :input '(:question "Which colour?")))))
      (let ((text (plist-get (harness-test-await wait 5) :content)))
        (should (string-match-p "waiting on the user: question .*Which colour\\?" text)))
      (should (string-match-p "Answered" (harness-tools-sessions-test-ok me "session_control"
                                                                          (list :session_id other :action "answer" :answer "teal"))))
      (should (equal "teal" (plist-get (harness-test-await ask 5) :content))))))

(ert-deftest harness-tools-sessions-control ()
  (harness-tools-sessions-test-with
    (let ((harness-provider-demo--delay 0.2)
          (me (harness-tools-sessions-test-session))
          (other (harness-tools-sessions-test-session)))
      (harness-tools-sessions-test-ok me "session_control" (list :session_id other :action "rename" :name "Renamed"))
      (should (equal "Renamed" (plist-get (harness-call 'session/get other) :name)))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "long job"))
      (let ((r (harness-tools-sessions-test-run me "session_control" (list :session_id other :action "close"))))
        (should (plist-get r :is-error)))
      (should (string-match-p "Cancelling" (harness-tools-sessions-test-ok me "session_control" (list :session_id "Renamed" :action "cancel"))))
      (harness-tools-sessions-test-idle other)
      (harness-tools-sessions-test-ok me "session_control" (list :session_id other :action "close"))
      (should (eq 'inactive (plist-get (harness-call 'session/get other) :status)))
      (harness-tools-sessions-test-ok me "session_control" (list :session_id other :action "resume"))
      (should (eq 'idle (plist-get (harness-call 'session/get other) :status)))
      (should (plist-get (harness-tools-sessions-test-run me "session_control" (list :session_id me :action "cancel")) :is-error)))))

(ert-deftest harness-tools-sessions-tasks ()
  (harness-tools-sessions-test-with
    (let* ((harness-provider-demo--delay 0.05)
           (me (harness-tools-sessions-test-session))
           (submitted (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")))
           (id (plist-get (plist-get submitted :meta) :task-id)))
      (should-not (plist-get submitted :is-error))
      (should (string-prefix-p "t-" id))
      (should (string-match-p "Fix the lexer" (harness-tools-sessions-test-ok me "task_list" nil)))
      ;; Once its session is named, the title on the board leads the line.
      (harness-call 'session/update (plist-get (harness-call 'task/get id) :session) :name "Lexer fix" :silent t)
      (should (string-match-p (concat (regexp-quote id) " +[a-z-]+ +\"Lexer fix\": Fix the lexer")
                              (harness-tools-sessions-test-ok me "task_list" nil)))
      (let ((text (harness-tools-sessions-test-ok me "task_wait" (list :task_id (substring id 0 4)))))
        (should (string-match-p "Done waiting" text))
        (should (string-match-p "done" text))
        (should (string-match-p "Reply from the other session" text)))
      (should (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" '(:column "done"))))
      (should (string-match-p "No tasks match" (harness-tools-sessions-test-ok me "task_list" '(:column "pending"))))
      ;; A follow-up reopens it; wait for it to settle again.
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "message" :message "and the parser"))
      (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "done"))
      (should (= 2 (cl-count 'user (harness-call 'session/nodes (plist-get (harness-call 'task/get id) :session))
                             :key (lambda (n) (plist-get n :kind)))))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "archive"))
      (should-not (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" nil)))
      (should (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" '(:include_archived t))))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "delete"))
      (should-not (harness-call 'task/list)))))

(ert-deftest harness-tools-sessions-task-list-marks-this-task ()
  "task_list marks the task of the calling session, its times, and keeps the most recent with limit."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (mine (plist-get (harness-call 'task/adopt me) :id))
           (listing (harness-tools-sessions-test-ok me "task_list" nil)))
      (should (eq 'needs-input (plist-get (harness-call 'task/get mine) :column)))
      (should (string-match-p (concat (regexp-quote mine) " +needs-input +Adopted session\\s-+(this task)") listing))
      (should (string-match-p ", created " listing))
      ;; limit keeps the most recently created, and says how many it hid.
      (let ((newer (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Second")) :meta)
                              :task-id)))
        (let ((listing (harness-tools-sessions-test-ok me "task_list" '(:limit 1))))
          (should (string-match-p (regexp-quote newer) listing))
          (should-not (string-match-p (regexp-quote mine) listing))
          (should (string-match-p "1 older task not shown" listing)))))))

(ert-deftest harness-tools-sessions-task-list-shows-a-refused-duplicate ()
  "task_list shows the task a write-up refused as a duplicate, and the one it named."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (first (plist-get (plist-get (harness-tools-sessions-test-run
                                         me "task_submit" '(:prompt "CSV export for reports"))
                                        :meta)
                             :task-id)))
      (let* ((harness-provider-demo-script-override
              `((:type text :delta ,(format "Duplicate of %s\n\nThe board has it already." first))
                (:type done :stop-reason end-turn)))
             (second (plist-get (plist-get (harness-tools-sessions-test-run
                                            me "task_submit" '(:prompt "export the reports as csv" :refine t))
                                           :meta)
                                :task-id)))
        (harness-test-wait (lambda () (eq 'duplicate (plist-get (harness-call 'task/get second) :outcome)))
                           5 "the refusal")
        (let ((listing (harness-tools-sessions-test-ok me "task_list" nil)))
          (should (string-match-p (concat (regexp-quote second) " +needs-input +export the reports as csv") listing))
          (should (string-match-p (concat "state refining (duplicate), duplicate of " (regexp-quote first)) listing))
          (should (string-match-p (regexp-quote first) listing)))))))

(ert-deftest harness-tools-sessions-pending-task-message-edits-prompt ()
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (id (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "First")) :meta) :task-id)))
      (should (eq 'pending (plist-get (harness-call 'task/get id) :state)))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "message" :message "Also second"))
      (should (equal "First\n\nAlso second" (plist-get (harness-call 'task/get id) :prompt)))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "cancel"))
      (should-not (harness-call 'task/list)))))

(ert-deftest harness-tools-sessions-task-for-the-backlog ()
  "task_submit with refine writes a task up; task_wait settles once it waits to be started."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running nil)
           (harness-provider-demo-script-override
            '((:type text :delta "Fix the lexer\n\nIt drops the last token.") (:type done :stop-reason end-turn)))
           (me (harness-tools-sessions-test-session))
           (submitted (harness-tools-sessions-test-run me "task_submit" '(:prompt "lexer eats a token" :refine t)))
           (id (plist-get (plist-get submitted :meta) :task-id)))
      (should (string-match-p "backlog" (plist-get submitted :content)))
      (let ((text (harness-tools-sessions-test-ok me "task_wait" (list :task_id id))))
        (should (string-match-p "Done waiting" text))
        (should (string-match-p "It drops the last token" text)))
      (let ((task (harness-call 'task/get id)))
        (should (eq 'pending (plist-get task :state)))
        (should (equal "Fix the lexer\n\nIt drops the last token." (plist-get task :prompt))))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "start"))
      (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "done"))
      (should (eq 'done (plist-get (harness-call 'task/get id) :state))))))

(ert-deftest harness-tools-sessions-task-review ()
  "task_wait settles when finished work waits for review; task_control sends it back, then verifies it."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-require-verification t)
           (me (harness-tools-sessions-test-session))
           (id (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")) :meta)
                          :task-id)))
      (let ((text (harness-tools-sessions-test-ok me "task_wait" (list :task_id id))))
        (should (string-match-p "Done waiting" text))
        (should (string-match-p (concat (regexp-quote id) " +review +Fix the lexer") text)))
      (should (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" '(:column "review"))))
      (should (string-match-p "No tasks match" (harness-tools-sessions-test-ok me "task_list" '(:column "done"))))
      ;; Sending it back needs the feedback.
      (should (plist-get (harness-tools-sessions-test-run me "task_control" (list :task_id id :action "reject")) :is-error))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "reject" :message "Also the parser."))
      (should (string-match-p "sent back 1 time\\b"
                              (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "review"))))
      (should (= 2 (cl-count 'user (harness-call 'session/nodes (plist-get (harness-call 'task/get id) :session))
                             :key (lambda (n) (plist-get n :kind)))))
      (let ((text (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "verify"))))
        (should (string-match-p "verify done" text))
        (should (string-match-p "state done.*, verified" text)))
      (should (plist-get (harness-tools-sessions-test-run me "task_control" (list :task_id id :action "verify")) :is-error))
      (should (eq 'done (plist-get (harness-call 'task/get id) :state))))))

(provide 'harness-tools-sessions-test)
;;; harness-tools-sessions-test.el ends here
