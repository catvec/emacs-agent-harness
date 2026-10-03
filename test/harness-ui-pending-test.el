;;; harness-ui-pending-test.el --- Tests for shared pending requests  -*- lexical-binding: t; -*-

;;; Commentary:

;; The requests a session waits on live in one store, drawn and answered
;; by whichever buffer shows them: the chat's tail panels (driven hard by
;; harness-ui-chat-test.el) and a popout of their own, opened from the
;; session list and from the task board with SPC.  These tests drive the
;; store, the popout and the two views' way in, against the real state
;; layer, the demo provider and the in-process ACP connection.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo-delay)
(defvar harness-naming-auto)
(defvar harness-model)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-ui-default-position)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-sessions--buffer-name)
(defvar harness-ui-popout--buffers)
(defvar harness-chat--buffers)
(defvar harness-ui-tasks--tasks)
(defvar harness-ui-tasks--loading)

(declare-function harness-sessions "harness-ui-sessions")
(declare-function harness-ui-pending-popout "harness-ui-pending")
(declare-function harness-ui-popout-buffer "harness-ui-popout")
(declare-function harness-ui-popout--title-text "harness-ui-popout")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-tasks--task "harness-ui-tasks")
(declare-function harness-ui-tasks--column "harness-ui-tasks")
(declare-function harness-ui-tasks--actions "harness-ui-tasks")
(declare-function harness-ui-tasks--fetch "harness-ui-tasks")
(declare-function harness-ui-popout-submit "harness-ui-popout")
(declare-function harness-compose-live-p "harness-ui-compose")
(declare-function harness-chat-push "harness-ui-chat")
(defvar harness-compose-end)

(defvar harness-ui-pending-test-answers nil
  "Answers the tests recorded, newest first: (KIND SESSION-ID PID ANSWER).
A special variable, so the methods registered below record into the
list the running test reads, not into a copy of their own.")

(defmacro harness-ui-pending-test-with (&rest body)
  "Load the state layer, the demo provider, ACP and the UI; run BODY.
Nothing here needs a window system."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo-delay 0.005)
           (harness-naming-auto nil)
           (harness-model "demo:scripted")
           (harness-acp-token nil)
           (harness-ui-pending-test-answers nil)
           (harness-ui-default-position 'full)
           (default-directory dir))
       (dolist (m '(ui ui-compose ui-markdown ui-chat ui-popout ui-pending ui-tasks ui-sessions))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (clrhash harness-ui-popout--buffers)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-ui-popout--buffers)
         (clrhash harness-ui-popout--buffers)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (b (buffer-list))
           (when (string-match-p "\\`\\*harness \\(?:tasks\\|sessions\\)" (buffer-name b)) (kill-buffer b)))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))
         (harness-ui-pending--forget-all)))))

(defun harness-ui-pending-test-session (&optional name)
  "Create a demo session called NAME, cache it, and return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (file-name-as-directory default-directory)
                                      :model "demo:scripted" :name (or name "Waiter"))
                        :id)))
    (harness-ui-pending-test-cache sid)
    sid))

(defun harness-ui-pending-test-cache (sid &optional plist)
  "Cache session SID as the UI sees it over the wire: enums are strings."
  (let ((session (or plist (harness-call 'session/get sid))))
    (dolist (key '(:status :kind :permission-mode))
      (when (plist-get session key)
        (setq session (plist-put session key (format "%s" (plist-get session key))))))
    (harness-ui-cache-session session)))

(defun harness-ui-pending-test-block (sid kind &optional id)
  "Cache SID as blocked on a request of KIND, a kind name string.
ID names the request its pending list carries, as the wire does."
  (harness-ui-pending-test-cache
   sid (plist-put (plist-put (harness-call 'session/get sid) :status 'blocked)
                  :pending (list (list :id (or id "x") :kind kind))))
  sid)

(defun harness-ui-pending-test-question (sid &optional id question)
  "Make SID wait on a question; return the pending id."
  (let* ((id (or id "q1")) (question (or question "Which colour?")))
    (harness-ui-pending-sync
     sid (list (list :id id :kind "question"
                     :payload (list :question question :options '("red" "green" "blue")))))
    id))

(defun harness-ui-pending-test-permission (sid &optional id title)
  "Make SID wait on a permission request; return the pending id."
  (let* ((id (or id "p1")) (title (or title "Bash: ls -la")))
    (harness-ui-pending-sync
     sid (list (list :id id :kind "permission"
                     :payload (list :title title :tool "bash"
                                    :options '("allow-once" "allow-session" "deny-once")))))
    id))

(defun harness-ui-pending-test-record-answers ()
  "Register methods recording answers into `harness-ui-pending-test-answers'."
  (harness-register-method 'question/answer
                           (lambda (session-id pid answer)
                             (push (list 'question session-id pid answer) harness-ui-pending-test-answers) t))
  (harness-register-method 'permission/answer
                           (lambda (session-id pending-id answer)
                             (push (list 'permission session-id pending-id answer)
                                   harness-ui-pending-test-answers)
                             t)))

;;;; The store

(ert-deftest harness-ui-pending-syncs-both-kinds-and-answers ()
  "Requests from a session's pending list land in the store, in order.
What the session waits on is one short line for views, and answering
goes over ACP when no client holds the request."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           )
      (harness-ui-pending-test-record-answers)
      (should (harness-ui-pending-sync
               sid (list (list :id "q1" :kind "question"
                               :payload (list :question "Which?" :options '("a" "b")))
                         (list :id "p1" :kind "permission"
                               :payload (list :title "Bash: ls" :tool "bash"
                                              :options '("allow-once" "deny-once"))))))
      (should (equal '("q1" "p1") (mapcar (lambda (r) (plist-get r :id)) (harness-ui-pending-items sid))))
      (should (equal "Which?" (plist-get (car (harness-ui-pending-items sid)) :question)))
      ;; The one line views say, and the status a list column would show.
      (let ((session (list :id sid :pending (list (list :id "q1" :kind "question")))))
        (should (equal "has a question for you" (harness-ui-pending-summary session)))
        (should (equal "question" (harness-ui-pending-status session))))
      (let ((session (list :id "not-in-the-store" :pending (list (list :id "p1" :kind "permission")))))
        (should (equal "needs your permission" (harness-ui-pending-summary session)))
        (should (equal "permission" (harness-ui-pending-status session))))
      (should-not (harness-ui-pending-summary (list :id "not-in-the-store")))
      ;; Answering takes the request off the panels and reaches the session.
      (harness-ui-pending-answer-question sid "q1" "a")
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the question answered over ACP")
      (should (equal (list 'question sid "q1" "a") (car harness-ui-pending-test-answers)))
      (should (equal '("p1") (mapcar (lambda (r) (plist-get r :id)) (harness-ui-pending-items sid))))
      (harness-ui-pending-answer-permission sid "p1" "allow-once")
      (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the permission answered over ACP")
      (should (equal (list 'permission sid "p1" "allow-once") (car harness-ui-pending-test-answers)))
      (should-not (harness-ui-pending-items sid))
      ;; An answer given here is not undone by a lagging session push.
      (harness-ui-pending-sync sid (list (list :id "p1" :kind "permission")))
      (should-not (harness-ui-pending-items sid)))))

(ert-deftest harness-ui-pending-owns-acp-requests-only-when-drawn ()
  "An ACP request is taken over only while a buffer draws its session.
Otherwise it stays pending, and the session's own list answers it."
  (harness-ui-pending-test-with
    (let* ((answers nil)
           (respond (lambda (r) (push r answers)))
           (drawn (list "drawn")))
      (add-hook 'harness-ui-pending-drawn-predicates
                (lambda (sid) (member sid drawn)))
      (unwind-protect
          (progn
            (should-not (harness-ui-pending--on-question
                         (list :sessionId "other" :requestId "q9" :question "Hi?") respond))
            (should (harness-ui-pending--on-question
                     (list :sessionId "drawn" :requestId "q9" :question "Hi?" :options '("yes" "no")) respond))
            (should (equal "Hi?" (plist-get (harness-ui-pending-record "drawn" "q9") :question)))
            ;; Answered through the function that holds it, not over ACP.
            (harness-ui-pending-answer-question "drawn" "q9" "yes")
            (should (equal '((:answer "yes")) answers))
            (should-not (harness-ui-pending-items "drawn"))
            ;; A permission request the same way.
            (should (harness-ui-pending--on-permission
                     (list :sessionId "drawn"
                           :toolCall (list :toolCallId "c1" :title "Bash: ls" :kind "execute")
                           :_harness (list :pendingId "p9" :tool "bash"))
                     respond))
            (harness-ui-pending-answer-permission "drawn" "p9" "allow-once")
            (should (equal '((:outcome (:outcome "selected" :optionId "allow-once"))
                             (:answer "yes"))
                           answers)))
        (remove-hook 'harness-ui-pending-drawn-predicates
                     (lambda (sid) (member sid drawn)))))))

(ert-deftest harness-ui-pending-answers-survive-a-reconnect ()
  "A request owned before the UI connected again is still answered.
Its RESPOND belongs to the connection the UI let go of, which the
harness never hears, so an answer goes over ACP instead
\(`permission/answer', `question/answer') and the session is not left
blocked; a request still answered on its own connection uses RESPOND."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Reconnected"))
           (drawn (list sid))
           (answers nil)
           (respond (lambda (r) (push r answers) t))
           (port (plist-get (harness-call 'acp/start :port 0) :port))
           (address (format "127.0.0.1:%d" port)))
      (harness-ui-pending-test-record-answers)
      (add-hook 'harness-ui-pending-drawn-predicates
                (lambda (session-id) (member session-id drawn)))
      (unwind-protect
          (progn
            ;; An answer while the connection it came on is the UI's.
            (should (harness-ui-pending--on-question
                     (list :sessionId sid :requestId "q0" :question "Which?" :options '("yes" "no"))
                     respond))
            (harness-ui-pending-answer-question sid "q0" "yes")
            (should (equal '((:answer "yes")) answers))
            ;; Two requests that will still wait when the UI connects again.
            (should (harness-ui-pending--on-question
                     (list :sessionId sid :requestId "q1" :question "Which colour?"
                           :options '("red" "green"))
                     respond))
            (should (harness-ui-pending--on-permission
                     (list :sessionId sid
                           :toolCall (list :toolCallId "c1" :title "Bash: ls" :kind "execute")
                           :_harness (list :pendingId "p1" :tool "bash"))
                     respond))
            (should (equal '("q1" "p1") (mapcar (lambda (r) (plist-get r :id))
                                                (harness-ui-pending-items sid))))
            ;; Over TCP to the same harness: a connection of its own, and
            ;; the RESPOND of the records above belongs to the old one.
            (harness-connect-remote address)
            (should (eq 'tcp (harness-acp-connection-kind harness-ui-connection)))
            (harness-ui-pending-answer-question sid "q1" "green")
            (harness-ui-pending-answer-permission sid "p1" "allow-once")
            (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers)))
                               5 "the answers reach the harness")
            (should (equal (list (list 'permission sid "p1" "allow-once")
                                 (list 'question sid "q1" "green"))
                           harness-ui-pending-test-answers))
            (should-not (harness-ui-pending-items sid)))
        (remove-hook 'harness-ui-pending-drawn-predicates
                     (lambda (session-id) (member session-id drawn)))
        (harness-call 'acp/stop)
        (setq harness-ui-connection-address nil)))))

;;;; The popout

(ert-deftest harness-ui-pending-popup-shows-its-request-and-answers-it ()
  "The popout shows the question in full and answers it with a click.
Once nothing is left the popout closes itself."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Asker"))
           (key (list 'pending sid)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-question sid "q1" "Which colour?")
      (harness-ui-pending-popout sid)
      (let ((buf (harness-ui-popout-buffer key)))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (equal "q1" (plist-get (harness-ui-pending-question sid) :id)))
          (should (string-match-p "Which colour?" (buffer-string)))
          (should (string-match-p "green" (buffer-string)))
          (should (string-match-p "question" (harness-ui-popout--title-text)))
          (goto-char (point-min))
          (search-forward "green")
          (harness-chat-push)))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer from the popout")
      (should (equal (list 'question sid "q1" "green") (car harness-ui-pending-test-answers)))
      (harness-test-wait (lambda () (null (harness-ui-popout-buffer key))) 5 "the popout to close")
      (should-not (harness-ui-pending-items sid)))))

(ert-deftest harness-ui-pending-popup-asks-a-question-in-its-box ()
  "A question without options is answered by typing in the popout's box."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Free text"))
           (key (list 'pending sid)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync sid (list (list :id "q1" :kind "question"
                                               :payload (list :question "Name?" :options nil))))
      (harness-ui-pending-popout sid)
      (let ((buf (harness-ui-popout-buffer key)))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (harness-compose-live-p))
          (goto-char harness-compose-end)
          (insert "purple")
          (harness-ui-popout-submit)))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the typed answer")
      (should (equal (list 'question sid "q1" "purple") (car harness-ui-pending-test-answers)))
      (harness-test-wait (lambda () (null (harness-ui-popout-buffer key))) 5 "the popout to close"))))

(ert-deftest harness-ui-pending-popup-learns-a-cached-sessions-request ()
  "A popout shows a request the store has only heard of from the session.
No chat is open to sync it, which is the case the session list and the
board pop out from: the request is in the session's cached pending list."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Cached"))
           (key (list 'pending sid)))
      (harness-ui-pending-test-cache
       sid (plist-put (plist-put (harness-call 'session/get sid) :status 'blocked)
                      :pending (list (list :id "q7" :kind "question"
                                           :payload (list :question "Which colour?"
                                                          :options '("red" "green"))))))
      (should-not (harness-ui-pending-items sid))
      (harness-ui-pending-popout sid)
      (should (equal "q7" (plist-get (harness-ui-pending-question sid) :id)))
      (let ((buf (harness-ui-popout-buffer key)))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (string-match-p "Which colour?" (buffer-string)))
          (should (string-match-p "green" (buffer-string))))))))

;;;; The views

(ert-deftest harness-ui-pending-sessions-list-pops-it-out ()
  "SPC on the session list shows what the session at point waits on.
The list says so in the status cell's tooltip, and answers from there."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Blocked"))
           (key (list 'pending sid)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-permission sid "p1" "Bash: ls -la")
      (harness-ui-pending-test-block sid "permission" "p1")
      ;; The seeded cache is the harness's answer: do not reload over it.
      (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                 (lambda (&optional callback) (when callback (funcall callback nil)))))
        (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (goto-char (point-min))
        (should (equal sid (tabulated-list-get-id)))
        (should (equal sid (harness-ui-session-at-point)))
        (should (equal 'harness-ui-sessions-requests (key-binding (kbd "SPC"))))
        (should (string-match-p "SPC shows what it waits on"
                                (harness-ui-sessions--waiting-help (harness-ui-session sid))))
        (call-interactively (key-binding (kbd "SPC"))))
      (let ((buf (harness-ui-popout-buffer key)))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (string-match-p "Bash: ls -la" (buffer-string)))
          (goto-char (point-min))
          (search-forward "[Allow]")
          (harness-chat-push)))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the permission answered from the list")
      (should (equal (list 'permission sid "p1" "allow-once") (car harness-ui-pending-test-answers)))
      (harness-test-wait (lambda () (null (harness-ui-popout-buffer key))) 5 "the popout to close"))))

(ert-deftest harness-ui-pending-sessions-list-leaves-spc-alone ()
  "A session that waits on nothing pops nothing out: SPC still scrolls."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session "Busy")))
      (harness-sessions)
      (with-current-buffer harness-ui-sessions--buffer-name
        (goto-char (point-min))
        (should (equal sid (tabulated-list-get-id)))
        (harness-ui-sessions-requests)
        (should-not (harness-ui-popout-buffer (list 'pending sid)))))))

(ert-deftest harness-ui-pending-task-board-pops-it-out ()
  "SPC over a card, and the card's own action, pop out what it waits on."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Task session"))
           (key (list 'pending sid))
           (board nil))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-question sid "q1" "Deploy now?")
      ;; The board's own fetch would replace the tasks seeded here.
      (cl-letf (((symbol-function 'harness-ui-tasks--fetch) (lambda (&rest _) nil)))
        (setq board (harness-tasks dir)))
      (with-current-buffer board
        (setq harness-ui-tasks--tasks
              (list (list :id "t-1" :session sid :state "active" :column "needs-input"
                          :project dir :cwd dir :prompt "Ship the release"))
              harness-ui-tasks--loading nil)
        (harness-ui-tasks--render)
        (goto-char (point-min))
        (search-forward "Task session")
        (should (equal 'needs-input (harness-ui-tasks--column (harness-ui-tasks--task))))
        (should (equal sid (harness-ui-session-at-point)))
        (should (equal 'harness-ui-tasks-requests (key-binding (kbd "SPC"))))
        (should (member "Answer…" (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task)))))
        (call-interactively (key-binding (kbd "SPC"))))
      (should (harness-ui-popout-buffer key))
      (with-current-buffer (harness-ui-popout-buffer key)
        (should (string-match-p "Deploy now?" (buffer-string)))
        (goto-char (point-min))
        (search-forward "green")
        (harness-chat-push))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer from the board's popout")
      (should (equal (list 'question sid "q1" "green") (car harness-ui-pending-test-answers))))))

(provide 'harness-ui-pending-test)
;;; harness-ui-pending-test.el ends here
