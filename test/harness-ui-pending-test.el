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
(declare-function harness-sessions-waiting "harness-ui-sessions")
(declare-function harness-ui-action-push "harness-ui")
(declare-function harness-ui-pending-view-actions "harness-ui-pending")
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
                               :payload (list :title "Bash: ls" :tool "bash" :call-id "c1"
                                              :options '("allow-once" "deny-once"))))))
      (should (equal '("q1" "p1") (mapcar (lambda (r) (plist-get r :id)) (harness-ui-pending-items sid))))
      (should (equal "Which?" (plist-get (car (harness-ui-pending-items sid)) :question)))
      ;; A permission knows the call waiting on it, which the chat keeps unfolded.
      (should (equal "c1" (plist-get (harness-ui-pending-record sid "p1") :call-id)))
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
            (should (equal "c1" (plist-get (harness-ui-pending-record "drawn" "p9") :call-id)))
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

(defvar harness-compose-attachments)
(declare-function harness-compose-add-attachment "harness-ui-compose")

(ert-deftest harness-ui-pending-popup-answer-mentioning-a-file-is-text ()
  "An answer naming a file with @ goes as the text it is.
An attachment of the box's own still cannot go with an answer."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Free text"))
           (key (list 'pending sid)))
      (harness-ui-pending-test-record-answers)
      (with-temp-file (expand-file-name "notes.txt" dir) (insert "Some notes\n"))
      (with-temp-file (expand-file-name "other.txt" dir) (insert "Other notes\n"))
      (harness-ui-pending-sync sid (list (list :id "q1" :kind "question"
                                               :payload (list :question "Which file?" :options nil))))
      (harness-ui-pending-popout sid)
      (with-current-buffer (harness-ui-popout-buffer key)
        (harness-compose-add-attachment (expand-file-name "other.txt" dir))
        (goto-char harness-compose-end)
        (insert "@notes.txt")
        (should-error (harness-ui-popout-submit) :type 'user-error)
        (should-not harness-ui-pending-test-answers)
        (goto-char harness-compose-end)
        (insert "@notes.txt")
        (harness-ui-popout-submit))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the typed answer")
      (should (equal (list 'question sid "q1" "@notes.txt") (car harness-ui-pending-test-answers))))))

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
        (should (string-match-p "y allows it, n denies it, SPC shows it"
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

(ert-deftest harness-ui-pending-sessions-list-answers-in-place ()
  "The list of those waiting for you answers them as the task board does.
The notifier's list shows the blocked sessions, each with the buttons a
board's card has for what it waits on, from the same code: [Allow]
answers the tool call, [Answer…] pops the question out."
  (harness-ui-pending-test-with
    (let* ((asker (harness-ui-pending-test-session "Asker"))
           (runner (harness-ui-pending-test-session "Runner"))
           (idle (harness-ui-pending-test-session "Idle")))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-question asker "q1" "Which colour?")
      (harness-ui-pending-test-block asker "question" "q1")
      (harness-ui-pending-test-permission runner "p1" "Bash: ls -la")
      (harness-ui-pending-test-block runner "permission" "p1")
      (should (equal '("[Allow]" "[Deny]") (mapcar #'car (harness-ui-pending-view-actions runner))))
      (should (equal '("[Answer…]") (mapcar #'car (harness-ui-pending-view-actions asker))))
      (should-not (harness-ui-pending-view-actions idle))
      ;; The seeded cache is the harness's answer: do not reload over it.
      (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                 (lambda (&optional callback) (when callback (funcall callback nil)))))
        (harness-sessions-waiting))
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal (sort (list asker runner) #'string<)
                       (sort (mapcar #'car tabulated-list-entries) #'string<)))
        (goto-char (point-min))
        (search-forward "[Allow")
        (should (equal runner (tabulated-list-get-id)))
        (should (string-match-p "needs your permission · Bash: ls -la"
                                (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
        (harness-ui-action-push))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the permission answered from the list")
      (should (equal (list 'permission runner "p1" "allow-once") (car harness-ui-pending-test-answers)))
      (should-not (harness-ui-pending-items runner))
      (with-current-buffer harness-ui-sessions--buffer-name
        (goto-char (point-min))
        (search-forward "[Answer")
        (should (equal asker (tabulated-list-get-id)))
        (harness-ui-action-push))
      (let ((buf (harness-ui-popout-buffer (list 'pending asker))))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (string-match-p "Which colour?" (buffer-string)))
          (goto-char (point-min))
          (search-forward "green")
          (harness-chat-push)))
      (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the question answered")
      (should (equal (list 'question asker "q1" "green") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-task-board-answers-in-place ()
  "A card waiting on a tool call answers it with [Allow], as the list does."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Task session"))
           (board nil))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-permission sid "p1" "Bash: make release")
      (cl-letf (((symbol-function 'harness-ui-tasks--fetch) (lambda (&rest _) nil)))
        (setq board (harness-tasks dir)))
      (with-current-buffer board
        (setq harness-ui-tasks--tasks
              (list (list :id "t-1" :session sid :state "active" :column "needs-input"
                          :project dir :cwd dir :prompt "Ship the release"))
              harness-ui-tasks--loading nil)
        (harness-ui-tasks--render)
        (goto-char (point-min))
        (search-forward "[Allow] [Deny]")
        (search-backward "[Allow")
        (should (equal "t-1" (plist-get (harness-ui-tasks--task) :id)))
        (push-button))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the permission answered from the board")
      (should (equal (list 'permission sid "p1" "allow-once") (car harness-ui-pending-test-answers))))))

;;;; The same answers on every request

(defun harness-ui-pending-test-item (kind)
  "Return a pending permission item of KIND, offering every answer.
KIND is `tool' (a call the mode asks about), `jail' (a call reaching
outside the allowed directories) or `dir' (the agent's own request for
a directory); the item's id is KIND's name."
  (let ((options '("allow-once" "allow-session" "allow-always" "deny-once" "deny-always")))
    (list :id (symbol-name kind) :kind "permission"
          :payload (pcase kind
                     ('tool (list :title "Bash: ls -la" :tool "bash" :kind "exec"
                                  :input '(:command "ls -la") :options options))
                     ('jail (list :title "Read /srv/notes/todo.org" :tool "read_file" :kind "read"
                                  :input '(:path "/srv/notes/todo.org") :paths '("/srv/notes/todo.org")
                                  :dir "/srv/notes/" :pattern "/srv/notes/**" :options options))
                     ('dir (list :title "Access /srv/api/" :tool "request_directory_access" :kind "meta"
                                 :input '(:path "/srv/api") :dir "/srv/api/" :pattern "/srv/api/**"
                                 :reason "The agent asks for access: read the API types"
                                 :options options))))))

(ert-deftest harness-ui-pending-every-request-has-the-same-buttons ()
  "A tool call, a call reaching outside, an agent's own request: the same buttons.
Under the same labels, which ACP clients get as the options' names, and
with the same keys, which answer the same on every panel; the echo area
says what the answer covered."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (row "[Allow] y  [Allow for session] s  [Always allow] a  [Deny] n  [Always deny] N")
           (press (lambda (pid key)
                    (with-current-buffer (harness-ui-popout-buffer (list 'pending sid))
                      ;; Onto the request's panel (its id is a string: no `eq').
                      (goto-char (point-min))
                      (while (not (equal pid (get-text-property (point) 'harness-ui-pending)))
                        (goto-char (or (next-single-property-change (point) 'harness-ui-pending)
                                       (error "No panel for %s" pid))))
                      (let ((shown nil))
                        (cl-letf (((symbol-function 'message)
                                   (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
                          (call-interactively (key-binding (kbd key))))
                        shown)))))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync sid (mapcar #'harness-ui-pending-test-item '(tool jail dir)))
      (dolist (pid '("tool" "jail" "dir"))
        (should (equal '(("Allow" "y" "allow-once") ("Allow for session" "s" "allow-session")
                         ("Always allow" "a" "allow-always") ("Deny" "n" "deny-once")
                         ("Always deny" "N" "deny-always"))
                       (harness-ui-pending-permission-buttons (harness-ui-pending-record sid pid)))))
      (should (equal (mapcar (lambda (o) (plist-get o :name)) harness-acp--permission-options)
                     (mapcar #'car (harness-ui-pending-permission-buttons (harness-ui-pending-record sid "dir")))))
      (harness-ui-pending-popout sid)
      (with-current-buffer (harness-ui-popout-buffer (list 'pending sid))
        (should (= 3 (how-many (regexp-quote row) (point-min) (point-max)))))
      (should (equal "Always allowed" (funcall press "tool" "a")))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the tool call answered")
      (should (equal (list 'permission sid "tool" "allow-always") (car harness-ui-pending-test-answers)))
      (should (equal "Allowed this call to reach /srv/notes/**" (funcall press "jail" "y")))
      (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the jail's prompt answered")
      (should (equal (list 'permission sid "jail" "allow-once") (car harness-ui-pending-test-answers)))
      ;; The agent's own request has an Allow too: until the turn ends.
      (should (equal "Allowed /srv/api/** until this turn ends" (funcall press "dir" "y")))
      (harness-test-wait (lambda () (= 3 (length harness-ui-pending-test-answers))) 5 "the request answered")
      (should (equal (list 'permission sid "dir" "allow-once") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-answer-help-says-what-it-covers ()
  "The same answer covers what the request is about, and its tooltip says so."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (help (lambda (pid option)
                   (harness-ui-pending-answer-help (harness-ui-pending-record sid pid) option))))
      (harness-ui-pending-sync sid (mapcar #'harness-ui-pending-test-item '(tool jail dir)))
      (should (equal "Allow this call, this time" (funcall help "tool" "allow-once")))
      (should (equal "Allow every bash call for this session" (funcall help "tool" "allow-session")))
      (should (equal "Always allow every bash call, in every session" (funcall help "tool" "allow-always")))
      (should (equal "Deny this call" (funcall help "tool" "deny-once")))
      (should (equal "Always deny every bash call" (funcall help "tool" "deny-always")))
      (should (equal "Let this call reach /srv/notes/**, this time" (funcall help "jail" "allow-once")))
      (should (equal "Allow /srv/notes/** for this session" (funcall help "jail" "allow-session")))
      (should (equal "Always allow /srv/notes/**, in every session" (funcall help "jail" "allow-always")))
      (should (equal "Deny this call" (funcall help "jail" "deny-once")))
      (should (equal "Always deny /srv/notes/**, to every tool" (funcall help "jail" "deny-always")))
      (should (equal "Allow /srv/api/** until this turn ends" (funcall help "dir" "allow-once")))
      (should (equal "Allow /srv/api/** for this session" (funcall help "dir" "allow-session")))
      (should (equal "Always allow /srv/api/**, in every session" (funcall help "dir" "allow-always")))
      (should (equal "Deny the request" (funcall help "dir" "deny-once")))
      (should (equal "Always deny /srv/api/**, to every tool" (funcall help "dir" "deny-always")))
      ;; A pattern the user edited is what the answers hold for.
      (harness-ui-pending-set-pattern sid "dir" "/srv/api/types/**")
      (should (equal "Allow /srv/api/types/** until this turn ends" (funcall help "dir" "allow-once")))
      ;; The panel's buttons carry it, with their keys.
      (with-temp-buffer
        (let ((harness-ui-session-id sid))
          (harness-ui-pending--insert-permission (harness-ui-pending-record sid "dir")))
        (goto-char (point-min))
        (search-forward "[Allow]")
        (should (equal "Allow /srv/api/types/** until this turn ends (y)"
                       (get-text-property (1- (point)) 'help-echo)))))))

(ert-deftest harness-ui-pending-views-offer-the-panels-allow-and-deny ()
  "The session list and the task board offer the panel's own [Allow] and [Deny].
With the panel's keys and tooltips, whatever the request: the views'
Allow answers an agent's own request for a directory as its y does."
  (harness-ui-pending-test-with
    (let ((tool (harness-ui-pending-test-session "Tool"))
          (dir (harness-ui-pending-test-session "Dir"))
          (shown (lambda (sid) (mapcar (lambda (a) (list (nth 0 a) (nth 2 a)))
                                       (harness-ui-pending-view-actions sid)))))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync tool (list (harness-ui-pending-test-item 'tool)))
      (harness-ui-pending-sync dir (list (harness-ui-pending-test-item 'dir)))
      (should (equal '(("[Allow]" "Allow this call, this time (y)") ("[Deny]" "Deny this call (n)"))
                     (funcall shown tool)))
      (should (equal '(("[Allow]" "Allow /srv/api/** until this turn ends (y)") ("[Deny]" "Deny the request (n)"))
                     (funcall shown dir)))
      (funcall (nth 1 (car (harness-ui-pending-view-actions dir))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "answered from the view")
      (should (equal (list 'permission dir "dir" "allow-once") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-refuses-an-answer-not-offered ()
  "A request offering only some answers shows those, and refuses the others."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-permission sid "p1")
      (should (equal '(("Allow" "y" "allow-once") ("Allow for session" "s" "allow-session") ("Deny" "n" "deny-once"))
                     (harness-ui-pending-permission-buttons (harness-ui-pending-record sid "p1"))))
      (should-error (harness-ui-pending-answer-permission sid "p1" "deny-always") :type 'user-error)
      (should (harness-ui-pending-record sid "p1"))
      (accept-process-output nil 0.05)
      (should-not harness-ui-pending-test-answers))))

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

;;;; A long input, whole

(ert-deftest harness-ui-pending-long-input-is-what-the-line-cuts ()
  "A permission's input is long when its one line leaves something out.
That is a value past its width, a further line of one, or a line too
long for the panel; whitespace around a value is not.  The toggle
counts the lines of the values with several, which would go unseen."
  (harness-ui-pending-test-with
    (cl-flet ((long (input &optional kind)
                (harness-ui-pending--input-long-p (list :kind (or kind "permission") :input input)))
              (label (input)
                (harness-ui-pending--show-all-label (harness-ui-pending--input-entries input))))
      (should-not (long '(:command "ls -la" :timeout 600)))
      (should-not (long '(:command "  ls -la  \n")))
      (should-not (long nil))
      (should-not (long "not a plist"))
      (should-not (long '(:command "ls\nrm -rf ~") "question"))
      (should-not (harness-ui-pending--input-long-p nil))
      ;; A further line, however short, is something left out.
      (should (long '(:command "ls\nrm -rf ~")))
      (should (equal "[Show all 2 lines]" (label '(:command "ls\nrm -rf ~"))))
      ;; A value past the width.
      (should-not (long (list :command (make-string 60 ?x))))
      (should (long (list :command (make-string 61 ?x))))
      (should (equal "[Show all]" (label (list :command (make-string 61 ?x)))))
      ;; Short values, but too many for the line.
      (let ((many (cl-loop for i below 12 append (list (intern (format ":k%d" i)) "value"))))
        (should (long many))
        (should (equal "[Show all]" (label many))))
      ;; The lines of every value with several, counted together.
      (should (equal "[Show all 5 lines]" (label '(:path "a.el" :old_string "a\nb" :new_string "c\nd\ne")))))))

(ert-deftest harness-ui-pending-popout-shows-a-long-command-whole ()
  "The popout the session list and the task board open shows a long command whole.
Its [Show all] button and TAB show it in place and put it back on one
line.  The state is the request's: the popout opened again, from the
other view, shows the command as it was left."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Long command"))
           (key (list 'pending sid))
           (command (concat "cd ~/src/acme-api && python3 -m pip install 'httpx>=0.28'"
                            " && python3 -m pytest tests/test_webhooks.py -x -q\nrm -rf build/ dist/"))
           (pid (harness-call 'session/pending-add sid
                              (list :kind 'permission
                                    :payload (list :tool "bash" :kind 'exec
                                                   :title (concat "Bash: " (harness-first-line command 70))
                                                   :input (list :command command :timeout 600)
                                                   :options '(allow-once allow-session deny-once)))))
           (board nil))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-cache sid)
      ;; SPC on the session list pops it out, cut short.
      (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                 (lambda (&optional callback) (when callback (funcall callback nil)))))
        (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (goto-char (point-min))
        (should (equal sid (tabulated-list-get-id)))
        (call-interactively (key-binding (kbd "SPC"))))
      (with-current-buffer (harness-ui-popout-buffer key)
        (should (string-match-p "  timeout: 600  \\[Show all 2 lines\\] TAB\n" (buffer-string)))
        (should-not (string-match-p "rm -rf build/" (buffer-string)))
        ;; Its button shows the command whole, in place.
        (goto-char (point-min))
        (search-forward "[Show all")
        (harness-chat-push)
        (should (string-match-p (regexp-quote (concat "   command:  [Show less] TAB\n" command "\n   timeout: 600\n"))
                                (buffer-string)))
        (should (equal pid (get-text-property (point) 'harness-ui-pending-input-toggle))))
      (should (harness-ui-pending-input-whole-p sid pid))
      (harness-ui-popout-close key)
      ;; SPC on the task board pops out the same request, still whole.
      (cl-letf (((symbol-function 'harness-ui-tasks--fetch) (lambda (&rest _) nil)))
        (setq board (harness-tasks dir)))
      (with-current-buffer board
        (setq harness-ui-tasks--tasks
              (list (list :id "t-1" :session sid :state "active" :column "needs-input"
                          :project dir :cwd dir :prompt "Clean the build"))
              harness-ui-tasks--loading nil)
        (harness-ui-tasks--render)
        (goto-char (point-min))
        (search-forward "Long command")
        (call-interactively (key-binding (kbd "SPC"))))
      (with-current-buffer (harness-ui-popout-buffer key)
        (should (string-match-p "\nrm -rf build/ dist/\n" (buffer-string)))
        ;; TAB on the panel puts it back on one line, point on the toggle.
        (goto-char (point-min))
        (search-forward "Permission")
        (should (eq 'harness-ui-pending-toggle-input (key-binding (kbd "TAB"))))
        (call-interactively (key-binding (kbd "TAB")))
        (should-not (string-match-p "rm -rf build/" (buffer-string)))
        (should (equal pid (get-text-property (point) 'harness-ui-pending-input-toggle)))
        ;; The panel answers as ever.
        (goto-char (point-min))
        (search-forward "[Allow]")
        (harness-chat-push))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer from the board's popout")
      (should (equal (list 'permission sid pid "allow-once") (car harness-ui-pending-test-answers)))
      (harness-test-wait (lambda () (null (harness-ui-popout-buffer key))) 5 "the popout to close"))))

(declare-function harness-ui-pending--pattern-suggestions "harness-ui-pending")

(ert-deftest harness-ui-pending-pattern-suggestions-go-from-the-file-to-the-root ()
  "Editing a pattern offers, narrowest first, the call's path, the files
like it beside it, its directory and each one above it up to the
prompt's own, which may be the root of a repository far above the
file, then that pattern and the directory above it."
  (require 'harness-ui-pending)
  (should (equal '("/srv/emacs.d/modules/doom/compat/compat.el"
                   "/srv/emacs.d/modules/doom/compat/*.el"
                   "/srv/emacs.d/modules/doom/compat/**"
                   "/srv/emacs.d/modules/doom/**"
                   "/srv/emacs.d/modules/**"
                   "/srv/emacs.d/**"
                   "/srv/**")
                 (harness-ui-pending--pattern-suggestions
                  (list :pattern "/srv/emacs.d/**" :paths ["/srv/emacs.d/modules/doom/compat/compat.el"]))))
  ;; A pattern for the file's own directory, and one for a directory itself.
  (should (equal '("/srv/x/a.txt" "/srv/x/*.txt" "/srv/x/**" "/srv/**")
                 (harness-ui-pending--pattern-suggestions (list :pattern "/srv/x/**" :paths '("/srv/x/a.txt")))))
  (should (equal '("/srv/x/sub" "/srv/x/sub/**" "/srv/x/**")
                 (harness-ui-pending--pattern-suggestions (list :pattern "/srv/x/sub/**" :paths '("/srv/x/sub")))))
  ;; A path named through a link elsewhere: nothing between.
  (should (equal '("/link/x/a.el" "/real/x/**" "/real/**")
                 (harness-ui-pending--pattern-suggestions (list :pattern "/real/x/**" :paths '("/link/x/a.el"))))))

;;;; Image diagrams

(defvar harness-ui-pending--images)
(defvar harness-ui-image-colors)
(defvar harness-ui-pending-popout-max-height)
(defvar harness-ui-popout-max-height)
(defvar harness-ui-connection)
(defvar harness-ui-connected-hook)
(declare-function harness-ui-pending--diagram-string "harness-ui-pending" (session-id r index))
(declare-function harness-ui-pending--fetched-image "harness-ui-pending" (session-id pid index))
(declare-function harness-ui-pending--retry-images "harness-ui-pending" ())
(declare-function harness-ui-pending--forget-images "harness-ui-pending" (session-id records))
(declare-function harness-ui-pending--diagram-image "harness-ui-pending" (session-id r index))
(declare-function harness-ui-pending--image-box "harness-ui-pending" (r))
(declare-function harness-ui-popout--max-lines "harness-ui-popout" (frame))
(declare-function harness-ui-popout-close "harness-ui-popout" (key &optional quiet))
(declare-function harness-acp-connection-kind "harness-acp" (conn))

(defun harness-ui-pending-test-image-question (sid files &optional id)
  "Make SID wait on a question showing FILES, one per option; return its record.
ID names the question, \"q1\" by default."
  (let ((id (or id "q1")))
    (harness-ui-pending-sync
     sid (list (list :id id :kind "question"
                     :payload (list :question "Which layout?"
                                    :options (mapcar #'file-name-base files)
                                    :diagrams (mapcar (lambda (f) (list :type "image" :path f :mime "image/png"))
                                                      files)))))
    (harness-ui-pending-record sid id)))

(defun harness-ui-pending-test-image (string &optional file)
  "Return the first image STRING displays, or nil.
With FILE, the first image of that file: icons are images too."
  (let ((pos 0) found)
    (while (and (not found) pos (< pos (length string)))
      (let ((display (get-text-property pos 'display string)))
        (when (and (eq 'image (car-safe display))
                   (or (not file) (equal file (image-property display :file))))
          (setq found display)))
      (setq pos (next-single-property-change pos 'display string)))
    found))

(defun harness-ui-pending-test-png (dir name)
  "Write a small PNG called NAME in DIR; return its path."
  (let ((file (expand-file-name name dir))
        (coding-system-for-write 'no-conversion))
    (write-region harness-test-png nil file nil 'silent)
    file))

(ert-deftest harness-ui-pending-image-diagrams-on-white-and-whole ()
  "An option's image is drawn black on white, as a browser shows it, and
fits half the window, so a short one (a BTW's) shows it whole.
`harness-ui-image-colors' nil draws it in the text's colours instead."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Pictures"))
           (r (harness-ui-pending-test-image-question
               sid (list (harness-ui-pending-test-png dir "left.png") (harness-ui-pending-test-png dir "top.png")))))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
        (with-temp-buffer
          (set-window-buffer (selected-window) (current-buffer))
          (let ((image (harness-ui-pending-test-image (harness-ui-pending--diagram-string sid r 1))))
            (should image)
            (should (equal (expand-file-name "top.png" dir) (image-property image :file)))
            (should (equal "black" (image-property image :foreground)))
            (should (equal "white" (image-property image :background)))
            (should (<= (image-property image :max-height) (/ (window-body-height nil t) 2)))
            (should (<= (image-property image :max-width) (window-body-width nil t))))
          (let* ((harness-ui-image-colors nil)
                 (image (harness-ui-pending-test-image (harness-ui-pending--diagram-string sid r 0))))
            (should image)
            (should-not (image-property image :foreground))
            (should-not (image-property image :background))))))))

(ert-deftest harness-ui-pending-image-too-large-to-draw ()
  "An image larger than Emacs draws (`max-image-size', ten times the
frame) is a line saying so, a button opening it outside Emacs, rather
than an empty box Emacs complains about on every redisplay."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Pictures"))
           (page (expand-file-name "page.png" dir))
           (small (harness-ui-pending-test-png dir "small.png"))
           (opened nil))
      ;; Only its header: a full page's screenshot, 1400x12000.
      (let ((coding-system-for-write 'no-conversion))
        (write-region (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n 0 0 0 13 ?I ?H ?D ?R
                                      0 0 5 120 0 0 46 224 8 6 0 0 0)
                      nil page nil 'silent))
      (let ((r (harness-ui-pending-test-image-question sid (list page small)))
            (max-image-size 10.0))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'harness-ui-popout-open-file) (lambda (file) (setq opened file))))
          (with-temp-buffer
            (set-window-buffer (selected-window) (current-buffer))
            (let ((s (harness-ui-pending--diagram-string sid r 0)))
              (should-not (harness-ui-pending-test-image s))
              (should (string-search (format "[image %s: 1400\N{U+00D7}12000 pixels, too large to draw here"
                                             (abbreviate-file-name page))
                                     s))
              (funcall (get-text-property (string-search "[image" s) 'harness-ui-action s))
              (should (equal page opened)))
            ;; A small one draws as ever, and so does the large one where
            ;; Emacs is told to draw larger images.
            (should (harness-ui-pending-test-image (harness-ui-pending--diagram-string sid r 1) small))
            (let ((max-image-size 20000))
              (should (harness-ui-pending-test-image (harness-ui-pending--diagram-string sid r 0) page)))))))))

(ert-deftest harness-ui-pending-popout-of-images-grows-and-fits-them ()
  "The popout of a question with images grows taller than others, and
sizes the image to show whole beside the panel and the box.  A question
with images arriving while the popout is open makes it grow too."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Pictures"))
           (key (list 'pending sid))
           (files (list (harness-ui-pending-test-png dir "left.png") (harness-ui-pending-test-png dir "top.png"))))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
        ;; A question without images: an ordinary popout.
        (harness-ui-pending-test-question sid "q0" "Which colour?")
        (harness-ui-pending-popout sid)
        (with-current-buffer (harness-ui-popout-buffer key)
          (should (= (max 4 (floor (* harness-ui-popout-max-height (frame-height))))
                     (harness-ui-popout--max-lines (selected-frame)))))
        ;; The images come: it grows, and draws them to fit.
        (let ((r (harness-ui-pending-test-image-question sid files "q1")))
          (with-current-buffer (harness-ui-popout-buffer key)
            (should (= (max 4 (floor (* harness-ui-pending-popout-max-height (frame-height))))
                       (harness-ui-popout--max-lines (selected-frame))))
            (let ((image (harness-ui-pending-test-image (buffer-string) (car files)))
                  (box (harness-ui-pending--image-box r)))
              (should (eq 'image (car-safe image)))
              (should box)
              (should (equal (plist-get box :max-height) (image-property image :max-height)))
              (should (equal (plist-get box :max-width) (image-property image :max-width)))
              (should (< (image-property image :max-width) (window-body-width (get-buffer-window) t)))
              (should (equal "white" (image-property image :background))))))
        (harness-ui-popout-close key)))))

(ert-deftest harness-ui-pending-images-come-from-a-harness-elsewhere ()
  "A harness reached at a host and port may run on another machine: the
UI asks it for an option's image (`question/image') instead of reading
the path, shows it once it comes, says why when it cannot, and forgets
it with the question."
  (harness-ui-pending-test-with
    (harness-test-load-module 'tools-agent)
    (let* ((sid (harness-ui-pending-test-session "Far away"))
           (png (harness-ui-pending-test-png dir "far.png"))
           (gone (harness-ui-pending-test-png dir "gone.png"))
           (pid (harness-call 'session/pending-add sid
                              (list :kind 'question
                                    :payload (list :question "Which?" :options '("Far" "Gone")
                                                   :diagrams (list (list :type "image" :path png :mime "image/png")
                                                                   (list :type "image" :path gone :mime "image/png"))))))
           (changed nil)
           (note (lambda (session-id) (push session-id changed)))
           (port (plist-get (harness-call 'acp/start :port 0) :port)))
      (delete-file gone)
      (add-hook 'harness-ui-pending-changed-hook note)
      (unwind-protect
          (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
            (harness-connect-remote (format "127.0.0.1:%d" port))
            (should (eq 'tcp (harness-acp-connection-kind harness-ui-connection)))
            (harness-ui-pending-sync sid (harness-call 'session/pending sid))
            (let ((r (harness-ui-pending-record sid pid)))
              (should r)
              ;; Asked for, not read: it shows once it comes.
              (should (string-match-p "\\`\\[loading the image far\\.png…\\]"
                                      (harness-ui-pending--diagram-image sid r 0)))
              (should (string-match-p "\\`\\[loading the image gone\\.png…\\]"
                                      (harness-ui-pending--diagram-image sid r 1)))
              (harness-test-wait (lambda () (cl-notany (lambda (i) (eq 'loading (car-safe (gethash (list sid pid i) harness-ui-pending--images))))
                                                       '(0 1)))
                                 5 "the images from the harness")
              ;; The panels showing it are drawn again.
              (should (member sid changed))
              (let ((image (harness-ui-pending-test-image (harness-ui-pending--diagram-image sid r 0))))
                (should image)
                (should-not (image-property image :file))
                (should (equal harness-test-png (image-property image :data)))
                (should (equal "white" (image-property image :background))))
              (should (string-match-p (regexp-quote (format "[image %s: The image %s cannot be read any more]" gone gone))
                                      (harness-ui-pending--diagram-image sid r 1)))
              ;; Answered, the question takes its images along.
              (harness-ui-pending-remove sid pid)
              (should-not (gethash (list sid pid 0) harness-ui-pending--images))
              (should-not (gethash (list sid pid 1) harness-ui-pending--images))))
        (remove-hook 'harness-ui-pending-changed-hook note)
        (harness-call 'acp/stop)
        (setq harness-ui-connection-address nil)))))

(ert-deftest harness-ui-pending-image-fetch-weathers-connection-trouble ()
  "Asking the harness for an image never breaks the panel asking: a
connection that cannot be made is an error the panel shows; a
connection the UI let go of for another asks that one; an answer to an
asking since replaced is dropped; and what failed is asked for again
once the UI connects again."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Far away"))
           (key (list sid "q1" 0))
           (unknown t)
           (asked nil)
           (changed nil)
           (note (lambda (session-id) (push session-id changed))))
      (should (memq #'harness-ui-pending--retry-images harness-ui-connected-hook))
      (add-hook 'harness-ui-pending-changed-hook note)
      (unwind-protect
          (cl-letf (((symbol-function 'harness-ui-call)
                     (lambda (method params callback on-error)
                       (when unknown (error "Unknown host far.example"))
                       (push (list method params callback on-error) asked)
                       nil)))
            ;; Connecting fails as the panel is drawn: the panel says why.
            (should (equal '(:error "Unknown host far.example") (harness-ui-pending--fetched-image sid "q1" 0)))
            (should (equal '(:error "Unknown host far.example") (harness-ui-pending--fetched-image sid "q1" 0)))
            (should-not changed)
            ;; Connected, the UI asks for it again.
            (setq unknown nil)
            (harness-ui-pending--retry-images)
            (should (equal (list sid) changed))
            (should (eq 'loading (harness-ui-pending--fetched-image sid "q1" 0)))
            (should (eq 'loading (harness-ui-pending--fetched-image sid "q1" 0)))
            (should (= 1 (length asked)))
            (should (equal (list "_harness/question/image" (list :session-id sid :pid "q1" :index 0))
                           (seq-take (car asked) 2)))
            ;; The UI let go of that connection for another: the next
            ;; drawing asks that one.
            (setq changed nil)
            (funcall (nth 3 (car asked))
                     (list 'acp-error harness-acp-error-transport "connection replaced" (list :closed "replaced")))
            (should-not (gethash key harness-ui-pending--images))
            (should (equal (list sid) changed))
            (should (eq 'loading (harness-ui-pending--fetched-image sid "q1" 0)))
            (should (= 2 (length asked)))
            ;; The question went and came back, and is asked for anew:
            ;; the answer to the asking before is not the one awaited.
            (let ((before (car asked)))
              (harness-ui-pending--forget-images sid nil)
              (should (eq 'loading (harness-ui-pending--fetched-image sid "q1" 0)))
              (should (= 3 (length asked)))
              (setq changed nil)
              (funcall (nth 2 before) (list :data "b2xk" :mime "image/png"))
              (should-not changed)
              (should (eq 'loading (harness-ui-pending--fetched-image sid "q1" 0))))
            ;; The awaited one comes, and the panels are drawn again.
            (funcall (nth 2 (car asked)) (list :data "bmV3" :mime "image/png"))
            (should (equal (list sid) changed))
            (should (equal '(:data "bmV3" :mime "image/png") (harness-ui-pending--fetched-image sid "q1" 0)))
            ;; An image that came is kept: connecting again asks nothing.
            (setq changed nil)
            (harness-ui-pending--retry-images)
            (should-not changed)
            (should (equal '(:data "bmV3" :mime "image/png") (harness-ui-pending--fetched-image sid "q1" 0)))
            (should (= 3 (length asked))))
        (remove-hook 'harness-ui-pending-changed-hook note)))))

(provide 'harness-ui-pending-test)
;;; harness-ui-pending-test.el ends here
