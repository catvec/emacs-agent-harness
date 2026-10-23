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
(defvar harness-perms-rules)
(defvar harness-perms--session-rules)
(defvar harness-chat--loading)

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
(declare-function harness-chat-buffer "harness-ui-chat")
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
                           :_harness (list :pendingId "p9" :tool "bash"
                                           :commands '(("ls")) :covers "ls"))
                     respond))
            (should (equal "c1" (plist-get (harness-ui-pending-record "drawn" "p9") :call-id)))
            (should (equal "ls" (plist-get (harness-ui-pending-record "drawn" "p9") :covers)))
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

(ert-deftest harness-ui-pending-answers-carry-their-attachments ()
  "The files attached to an answer go with it, an image with its bytes.
Through the function that holds the request the reply carries them as
ACP content blocks, as a prompt does; over `question/answer' they are
the harness's blocks of them.  Either way an image keeps its label, so
the model reads the token its text names it by, [image 1], before it."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Attacher"))
           (png (harness-ui-pending-test-png dir "shot.png"))
           (att (list :path png :mime "image/png" :size (length harness-test-png)
                      :name "shot.png" :label "image 1"))
           (data (base64-encode-string harness-test-png t))
           (drawn (list sid))
           (drawn-p (lambda (session-id) (member session-id drawn)))
           (answers nil)
           (respond (lambda (r) (push r answers) t)))
      (harness-ui-pending-test-record-answers)
      (add-hook 'harness-ui-pending-drawn-predicates drawn-p)
      (unwind-protect
          (progn
            (should (harness-ui-pending--on-question
                     (list :sessionId sid :requestId "q0" :question "Which?" :options '("yes" "no"))
                     respond))
            (harness-ui-pending-answer-question sid "q0" "like [image 1]" nil (list att))
            (should (equal (list (list :answer "like [image 1]"
                                       :attachments (list (list :type "image" :mimeType "image/png" :data data
                                                                :_harness (list :label "image 1")))))
                           answers))
            ;; One the session's own list holds goes over `question/answer'.
            (harness-ui-pending-test-question sid "q1")
            (harness-ui-pending-answer-question sid "q1" "like [image 1]" nil (list att))
            (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer over ACP")
            (should (equal (list 'question sid "q1"
                                 (list :answer "like [image 1]"
                                       :blocks (list (list :type "image" :mime "image/png" :data data
                                                           :label "image 1"))))
                           (car harness-ui-pending-test-answers)))
            ;; Without attachments, the text alone, as before.
            (harness-ui-pending-test-question sid "q2")
            (harness-ui-pending-answer-question sid "q2" "plain")
            (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the plain answer")
            (should (equal (list 'question sid "q2" "plain") (car harness-ui-pending-test-answers))))
        (remove-hook 'harness-ui-pending-drawn-predicates drawn-p)))))

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

(ert-deftest harness-ui-pending-question-is-markdown ()
  "The question of a panel renders as Markdown, under its own indent.
A question is often the agent's prose: its emphasis and lists render as
they do in the transcript, every line indented under \"Question\"."
  (harness-ui-pending-test-with
    (let ((harness-ui-session-id "sid")
          (question "Which **colour** is right?\n\n- red\n- green"))
      (with-temp-buffer
        (harness-ui-pending-insert-panel
         (list :id "q1" :kind "question" :question question :options '("red" "green")))
        (let* ((text (buffer-string))
               (plain (substring-no-properties text))
               (colour (string-match "colour" plain))
               (which (string-match "Which" plain))
               (faces (let ((f (get-text-property colour 'face text)))
                        (if (listp f)
                            (apply #'append (mapcar (lambda (x) (if (listp x) x (list x))) f))
                          (list f)))))
          (should (string-match-p "Which colour is right?" plain))
          (should-not (string-match-p "\\*\\*" plain))
          (should (string-match-p "red" plain))
          (should (string-match-p "green" plain))
          ;; The panel is still a panel, marked with its own request.
          (should (equal "q1" (get-text-property (point-min) 'harness-ui-pending)))
          ;; The question's plain words are bold; the list's bullet is there.
          (should (memq 'bold faces))
          (should (string-match-p "• red" plain))
          ;; Its lines are indented under the panel's label, wrapped too.
          (should (equal "   " (get-text-property which 'line-prefix text)))
          (should (equal "   " (get-text-property which 'wrap-prefix text))))))))

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
The box's own attachments go with it: a screenshot its text names by
its token reaches the model with the answer, its bytes and its label."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Free text"))
           (key (list 'pending sid))
           (png (harness-ui-pending-test-png dir "shot.png")))
      (harness-ui-pending-test-record-answers)
      (with-temp-file (expand-file-name "notes.txt" dir) (insert "Some notes\n"))
      (harness-ui-pending-sync sid (list (list :id "q1" :kind "question"
                                               :payload (list :question "Which file?" :options nil))))
      (harness-ui-pending-popout sid)
      (with-current-buffer (harness-ui-popout-buffer key)
        (goto-char harness-compose-end)
        (insert "@notes.txt")
        (harness-ui-popout-submit))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the typed answer")
      (should (equal (list 'question sid "q1" "@notes.txt") (car harness-ui-pending-test-answers)))
      ;; Asked again, answered with a screenshot.
      (harness-ui-pending-sync sid (list (list :id "q2" :kind "question"
                                               :payload (list :question "Which looks wrong?" :options nil))))
      (harness-ui-pending-popout sid)
      (with-current-buffer (harness-ui-popout-buffer key)
        (goto-char harness-compose-end)
        (insert "@notes.txt, and this:")
        (harness-compose-add-attachment png)
        (harness-ui-popout-submit))
      (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the answer with an image")
      (should (equal (list 'question sid "q2"
                           (list :answer "@notes.txt, and this: [image 1]"
                                 :blocks (list (list :type "image" :mime "image/png"
                                                     :data (base64-encode-string harness-test-png t)
                                                     :label "image 1"))))
                     (car harness-ui-pending-test-answers))))))

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
                                  :input '(:command "ls -la") :commands '(("ls")) :covers "ls"
                                  :options options))
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
      (should (equal "Always allowed every ls call" (funcall press "tool" "a")))
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
      (should (equal "Allow every ls call for this session" (funcall help "tool" "allow-session")))
      (should (equal "Always allow every ls call, in every session" (funcall help "tool" "allow-always")))
      (should (equal "Deny this call" (funcall help "tool" "deny-once")))
      (should (equal "Always deny every ls call" (funcall help "tool" "deny-always")))
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
      ;; A shell prompt says what its lasting answers cover, and the
      ;; panel keeps saying it while it waits.
      (with-temp-buffer
        (let ((harness-ui-session-id sid))
          (harness-ui-pending--insert-permission (harness-ui-pending-record sid "tool")))
        (should (string-search "lasting answers: every ls call" (buffer-string)))
        (goto-char (point-min))
        (search-forward "[Always allow]")
        (should (equal "Always allow every ls call, in every session (a)"
                       (get-text-property (1- (point)) 'help-echo))))
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
    (harness-test-load-module 'tools-question)
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

;;;; The note of a lasting answer

(ert-deftest harness-ui-pending-lasting-answer-is-noted-in-the-chat ()
  "A lasting answer given in a popout is noted in the session's chat, with [Undo].
Answered from the popout a view opens -- the session list's, the task
board's SPC -- with no chat open: the perms module records the rule and
notes it in the session's transcript all the same, so the chat shows
the notes when it opens, and its [Undo] takes the rule back."
  (harness-ui-pending-test-with
    (harness-test-load-module 'perms)
    (let ((harness-perms-rules nil))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (sym value) (set sym value))))
        (let* ((sid (harness-ui-pending-test-session "Asker"))
               (popout (list 'pending sid))
               (board nil)
               (ask (lambda (tool command)
                      ;; The agent puts the call in the transcript, then runs it.
                      (let ((call-id (harness-short-id)))
                        (harness-call 'session/append sid (list :kind 'tool-call :tool tool :call-id call-id
                                                                :input (list :command command)))
                        (prog1 (harness-call 'tools/execute sid (list :id call-id :name tool
                                                                      :input (list :command command)))
                          (harness-test-wait (lambda () (harness-call 'session/pending sid)) 5 "the prompt")
                          ;; As `_harness/session' brings it: what it waits on, over the wire.
                          (harness-ui-pending-test-cache
                           sid (harness-json-parse (harness-json-encode (harness-call 'session/get sid))))))))
               (press (lambda (key)
                        (with-current-buffer (harness-ui-popout-buffer popout)
                          (goto-char (point-min))
                          (while (not (get-text-property (point) 'harness-ui-pending))
                            (goto-char (or (next-single-property-change (point) 'harness-ui-pending)
                                           (error "No panel in %S" (buffer-string)))))
                          (call-interactively (key-binding (kbd key)))))))
          (harness-call 'session/update sid :permission-mode 'ask)
          (dolist (tool '("t_make" "t_deploy"))
            (harness-define-tool tool :label tool :kind 'exec :handler (lambda (_in _ctx) "ran")))
          ;; Always allow, from the popout the session list opens.
          (let ((call (funcall ask "t_make" "make")))
            (harness-ui-pending-popout sid)
            (funcall press "a")
            (should (equal "ran" (plist-get (harness-test-await call) :content))))
          (should (equal '((:tool "t_make" :commands (("make")) :behavior allow)) harness-perms-rules))
          ;; Allow for session, from the popout the task board's SPC opens.
          (let ((call (funcall ask "t_deploy" "deploy")))
            (cl-letf (((symbol-function 'harness-ui-tasks--fetch) (lambda (&rest _) nil)))
              (setq board (harness-tasks dir)))
            (with-current-buffer board
              (setq harness-ui-tasks--tasks
                    (list (list :id "t-1" :session sid :state "active" :column "needs-input"
                                :project dir :cwd dir :prompt "Ship the release"))
                    harness-ui-tasks--loading nil)
              (harness-ui-tasks--render)
              (goto-char (point-min))
              (search-forward "Asker")
              (call-interactively (key-binding (kbd "SPC"))))
            (funcall press "s")
            (should (equal "ran" (plist-get (harness-test-await call) :content))))
          (should (equal '((:tool "t_deploy" :commands (("deploy")) :behavior allow)) (gethash sid harness-perms--session-rules)))
          ;; The chat, opened afterwards, has both notes under their calls.
          (let ((buf (harness-chat-buffer sid))
                (find (lambda (buf text)
                        (with-current-buffer buf
                          (save-excursion (goto-char (point-min)) (search-forward text nil t))))))
            (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-compose-end)))
                               5 "the chat loaded")
            (harness-test-wait (lambda () (funcall find buf "Allowing every t_deploy call to deploy for this session  [Undo]"))
                               5 "the notes in the chat")
            (should (funcall find buf "Always allowing every t_make call to make, in every session  [Undo]"))
            (let ((shown nil))
              (cl-letf (((symbol-function 'message)
                         (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) shown)))))
                (with-current-buffer buf
                  (goto-char (- (funcall find buf "in every session  [Undo]") 2))
                  (harness-chat-push))
                (harness-test-wait (lambda () shown) 5 "the echo area"))
              (should (equal '("Undone: no longer always allowing every t_make call to make, in every session") shown)))
            (should-not harness-perms-rules)
            (harness-test-wait (lambda () (funcall find buf "Always allowing every t_make call to make, in every session  undone"))
                               5 "the note redrawn")
            ;; The other answer's rule stays, and so does its [Undo].
            (should (equal '((:tool "t_deploy" :commands (("deploy")) :behavior allow)) (gethash sid harness-perms--session-rules)))
            (should (funcall find buf "for this session  [Undo]"))))))))

(ert-deftest harness-ui-pending-the-cover-picked-is-the-rule-recorded ()
  "From the real prompt to the rule: what the panel has picked is what lasts.
The harness works the covers out of the call, the panel lists them, `<'
and `>' pick one, and a lasting answer given there records the rule of
that cover: the exact command line, a directory, the whole tool.  What
is recorded then decides the next call, and nothing wider than what was
picked."
  (harness-ui-pending-test-with
    (harness-test-load-module 'perms)
    (let ((harness-perms-rules nil))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (sym value) (set sym value))))
        (let* ((sid (harness-ui-pending-test-session "Asker"))
               (cwd (file-name-as-directory default-directory))
               (popout (list 'pending sid))
               (ask (lambda (tool input)
                      (let ((call-id (harness-short-id)))
                        (harness-call 'session/append sid (list :kind 'tool-call :tool tool :call-id call-id :input input))
                        (prog1 (harness-call 'tools/execute sid (list :id call-id :name tool :input input))
                          (harness-test-wait (lambda () (harness-call 'session/pending sid)) 5 "the prompt")
                          ;; As `_harness/session' brings it: what it waits on, over the wire.
                          (harness-ui-pending-test-cache
                           sid (harness-json-parse (harness-json-encode (harness-call 'session/get sid))))))))
               (text (lambda () (with-current-buffer (harness-ui-popout-buffer popout) (buffer-string))))
               (press (lambda (key)
                        (with-current-buffer (harness-ui-popout-buffer popout)
                          (goto-char (point-min))
                          (while (not (get-text-property (point) 'harness-ui-pending))
                            (goto-char (or (next-single-property-change (point) 'harness-ui-pending)
                                           (error "No panel in %S" (buffer-string)))))
                          (call-interactively (key-binding (kbd key))))))
               ;; What the rules say of a call: allow or deny, or `ask' when
               ;; none holds it and the user would be asked.
               (decide (lambda (tool input)
                         (let ((rule (harness-perms--find-rule
                                      (list :session (harness-call 'session/get sid) :tool tool
                                            :kind (if (equal tool "t_write") 'write 'exec) :input input
                                            :paths (if (plist-get input :path)
                                                       (list (expand-file-name (plist-get input :path) cwd))
                                                     (list cwd))))))
                           (if rule (plist-get rule :behavior) 'ask)))))
          (harness-call 'session/update sid :permission-mode 'ask)
          (harness-define-tool "t_run" :label "Run" :kind 'exec :handler (lambda (_in _ctx) "ran"))
          (harness-define-tool "t_write" :label "Write" :kind 'write
                               :paths (lambda (in) (list (plist-get in :path)))
                               :handler (lambda (_in _ctx) "wrote"))
          ;; A command: the panel lists the ladder, starting on the program;
          ;; two steps narrower is the very command line.
          (let ((call (funcall ask "t_run" '(:command "gcloud compute instances list --project p"))))
            (harness-ui-pending-popout sid)
            (dolist (line '("Lasting answers (s, a, N) cover:"
                            "every t_run call whose command is exactly \"gcloud compute instances list --project p\""
                            "every gcloud compute instances call (any arguments)"
                            "every gcloud call (any arguments)"
                            "every t_run call (any command)"))
              (should (string-search line (funcall text))))
            (should (equal "programs" (harness-ui-pending--cover-id (car (harness-ui-pending-items sid)))))
            (funcall press "<")
            (funcall press "<")
            (should (equal "exact" (harness-ui-pending--cover-id (car (harness-ui-pending-items sid)))))
            (funcall press "a")
            (should (equal "ran" (plist-get (harness-test-await call) :content))))
          (should (equal '((:tool "t_run" :input (:command "gcloud compute instances list --project p") :behavior allow))
                         harness-perms-rules))
          ;; That command runs unasked now; another gcloud command asks.
          (should (eq 'allow (funcall decide "t_run" '(:command "gcloud compute instances list --project p"))))
          (should (eq 'ask (funcall decide "t_run" '(:command "gcloud compute instances list --project q"))))
          ;; A file: the directory, for this session.
          (let ((call (funcall ask "t_write" (list :path "lisp/a.el" :content "x"))))
            (harness-ui-pending-popout sid)
            (should (string-search (format "every t_write call under %s (any file)"
                                           (abbreviate-file-name (expand-file-name "lisp/" cwd)))
                                   (funcall text)))
            (should (equal "tool" (harness-ui-pending--cover-id (car (harness-ui-pending-items sid)))))
            (funcall press "<")
            (funcall press "<")
            (should (equal "dir" (harness-ui-pending--cover-id (car (harness-ui-pending-items sid)))))
            (funcall press "s")
            (should (equal "wrote" (plist-get (harness-test-await call) :content))))
          (should (equal (list (list :tool "t_write" :path (expand-file-name "lisp/" cwd) :behavior 'allow))
                         (gethash sid harness-perms--session-rules)))
          (should (eq 'allow (funcall decide "t_write" (list :path "lisp/sub/b.el" :content "y"))))
          (should (eq 'ask (funcall decide "t_write" (list :path "README" :content "y"))))
          ;; The whole tool, picked on purpose, and denied for good.
          (let ((call (funcall ask "t_run" '(:command "rm -rf build"))))
            (harness-ui-pending-popout sid)
            (funcall press ">")
            (should (equal "tool" (harness-ui-pending--cover-id (car (harness-ui-pending-items sid)))))
            (funcall press "N")
            (should (plist-get (harness-test-await call) :denied)))
          (should (equal '(:tool "t_run" :behavior deny) (car harness-perms-rules)))
          (should (eq 'deny (funcall decide "t_run" '(:command "ls")))))))))

;;;; A panel's key, from the box

;; The digits of a question and the keys of a permission type in the
;; compose box, as every printable key does there.  C-c . reads a key and
;; presses it on the panel above the box that has it (the compose box's
;; `harness-compose-panel-key'); every panel says so.

(defvar harness-compose-start)

(defun harness-ui-pending-test-chat (sid)
  "Open the chat of SID, wait until it has drawn, and return its buffer."
  (let ((buf (harness-chat-buffer sid)))
    (harness-test-wait (lambda () (with-current-buffer buf (and (not harness-chat--loading) harness-compose-end)))
                       5 "the chat to load")
    buf))

(defun harness-ui-pending-test-panel-key (keys &optional n)
  "Call `harness-compose-panel-key' with N, the keys KEYS typed after it."
  (cl-letf (((symbol-function 'read-key-sequence) (lambda (&rest _) keys)))
    (harness-compose-panel-key n)))

(defun harness-ui-pending-test-panel-text (pid)
  "Return the text of the panel PID in the current buffer, without properties.
That is what `harness-compose-panel' names PID."
  (apply #'string (cl-loop for i from (point-min) below (point-max)
                           when (equal pid (get-text-property i 'harness-compose-panel))
                           collect (char-after i))))

(ert-deftest harness-ui-pending-panel-keys-can-be-pressed-from-the-popouts-box ()
  "C-c . in the box of a popout presses a key of the panel above that has it.
The newest request is the nearest to the box, and a numeric argument
takes the Nth up.  The draft stays in the box and so does point, at the
offset it had, whatever the popout drew again when a request left."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Asker"))
           (key (list 'pending sid))
           (answers (lambda () harness-ui-pending-test-answers)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync
       sid (list (list :id "q1" :kind "question"
                       :payload (list :question "Which colour?" :options '("red" "green" "blue")))
                 (harness-ui-pending-test-item 'tool)
                 (harness-ui-pending-test-item 'jail)))
      (harness-ui-pending-popout sid)
      (with-current-buffer (harness-ui-popout-buffer key)
        (should (harness-compose-live-p))
        (goto-char harness-compose-end)
        (insert "draft")
        (goto-char (+ harness-compose-start 2))
        (should (eq 'harness-compose-panel-key (key-binding (kbd "C-c ."))))
        ;; Every request is a panel of the box, named by its id.
        (dolist (pid '("q1" "tool" "jail"))
          (should (string-match-p "\n" (harness-ui-pending-test-panel-text pid))))
        ;; The second panel up that takes y: the tool call's, not the jail's.
        (execute-kbd-macro (kbd "C-u 2 C-c . y"))
        (harness-test-wait (lambda () (funcall answers)) 5 "the tool call answered")
        (should (equal (list 'permission sid "tool" "allow-once") (car (funcall answers))))
        (should (equal "draft" (harness-compose-text)))
        (should (= (point) (+ harness-compose-start 2)))
        ;; Then the nearest, the jail's.
        (execute-kbd-macro (kbd "C-c . y"))
        (harness-test-wait (lambda () (= 2 (length (funcall answers)))) 5 "the jail's prompt answered")
        (should (equal (list 'permission sid "jail" "allow-once") (car (funcall answers))))
        (should (= (point) (+ harness-compose-start 2)))
        ;; Only the question is left: it has no y, nor a fourth option.
        (let ((err (should-error (harness-ui-pending-test-panel-key "y") :type 'user-error)))
          (should (equal "No panel above the box has y" (cadr err))))
        (let ((err (should-error (harness-ui-pending-test-panel-key "4") :type 'user-error)))
          (should (string-match-p "\\`4 has nothing to act on from the box" (cadr err))))
        (should (= 2 (length (funcall answers))))
        ;; Its second option answers it.
        (execute-kbd-macro (kbd "C-c . 2"))
        (harness-test-wait (lambda () (= 3 (length (funcall answers)))) 5 "the question answered")
        (should (equal (list 'question sid "q1" "green") (car (funcall answers))))))))

(ert-deftest harness-ui-pending-panel-keys-can-be-pressed-from-the-chats-box ()
  "C-c . answers a question of the chat from its box, the draft and point kept.
The chat draws its tail again when the question goes, with point on the
panel; it ends back in the box at the offset it had."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Chatty"))
           (buf (harness-ui-pending-test-chat sid)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync
       sid (list (list :id "q1" :kind "question"
                       :payload (list :question "Which colour?" :options '("red" "green" "blue")))))
      (with-current-buffer buf
        (should (string-match-p "from the box: C-c \\. 1" (buffer-string)))
        (goto-char harness-compose-end)
        (insert "draft here")
        (goto-char (+ harness-compose-start 4))
        (save-window-excursion
          ;; Keys reach the buffer of the selected window.
          (set-window-buffer nil buf)
          (execute-kbd-macro (kbd "C-c . 3")))
        ;; The question left the tail, the panel with it.
        (should-not (harness-ui-pending-items sid))
        (should-not (text-property-not-all (point-min) (point-max) 'harness-compose-panel nil))
        (should (equal "draft here" (harness-compose-text)))
        (should (= (point) (+ harness-compose-start 4))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the question answered")
      (should (equal (list 'question sid "q1" "blue") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-panels-say-how-to-press-their-keys-from-the-box ()
  "A request's panel says what the key to press its keys from the box is.
It is a permission's y, a question's first option; a question to type
the answer to has no keys.  The panel's text is all the panel's, under
the request's id."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync
       sid (list (harness-ui-pending-test-item 'tool)
                 (list :id "q1" :kind "question"
                       :payload (list :question "Which?" :options '("a" "b")))
                 (list :id "q2" :kind "question"
                       :payload (list :question "Name?" :options nil))
                 (list :id "q3" :kind "question"
                       :payload (list :question "Which layout?" :options '("Left" "Right")
                                      :diagrams '((:type "ascii" :text "[left]") (:type "ascii" :text "[right]"))))))
      (with-temp-buffer
        (let ((harness-ui-session-id sid))
          (harness-ui-pending-insert-panels sid))
        ;; All the text of a panel is the panel's, and nothing else is.
        (should (cl-loop for i from (point-min) below (point-max)
                         always (equal (get-text-property i 'harness-ui-pending)
                                       (get-text-property i 'harness-compose-panel))))
        (should (string-match-p "^   from the box: C-c \\. y\n" (harness-ui-pending-test-panel-text "tool")))
        (should (string-match-p "or type another answer below · from the box: C-c \\. 1\n"
                                (harness-ui-pending-test-panel-text "q1")))
        (should (string-match-p "or type another answer below · from the box: C-c \\. 1\n"
                                (harness-ui-pending-test-panel-text "q3")))
        (should (string-match-p "next diagram" (harness-ui-pending-test-panel-text "q3")))
        (should-not (string-match-p "from the box" (harness-ui-pending-test-panel-text "q2")))
        ;; The hint is dim, its key a key.
        (let ((face-p (lambda (pos face)
                        (let ((faces (get-text-property pos 'face)))
                          (if (listp faces) (memq face faces) (eq face faces))))))
          (goto-char (point-min))
          (search-forward "from the box: ")
          (should (funcall face-p (- (point) 3) 'harness-dim-face))
          (should (funcall face-p (point) 'harness-ui-key-face)))))))

;;;; A question that allows several options

;; ask_user's `allow_multiple': the options are check boxes.  A digit or a
;; click ticks one instead of answering, and C-c C-c (or [Send answer])
;; answers with the options ticked, a line each, and the box's words
;; after them.

(defun harness-ui-pending-test-multiple (sid &optional id)
  "Make SID wait on a question that allows several options; return its id."
  (let ((id (or id "m1")))
    (harness-ui-pending-sync
     sid (list (list :id id :kind "question"
                     :payload (list :question "Which features?"
                                    :options '("Dark mode" "Offline sync" "Push notifications")
                                    :allow-multiple t))))
    id))

(defun harness-ui-pending-test-box (ticked)
  "Return the check box the panels draw, ticked when TICKED, as text."
  (substring-no-properties (harness-ui-icon (if ticked 'harness-icon-check-on 'harness-icon-check-off))))

(defun harness-ui-pending-test-press-on (label key)
  "Press KEY with point on the first LABEL in the current buffer."
  (goto-char (point-min))
  (search-forward label)
  (call-interactively (key-binding (kbd key))))

(ert-deftest harness-ui-pending-several-options-draw-as-check-boxes ()
  "A question that allows several options draws its options as check boxes.
It says none is ticked, offers [Send answer] and says what the words
typed below are for; an ordinary question is drawn as it was."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session "Ticker")))
      (harness-ui-pending-test-multiple sid "m1")
      (harness-ui-pending-test-question sid "q1")
      (should (harness-ui-pending-multiple-p (harness-ui-pending-record sid "m1")))
      (should-not (harness-ui-pending-multiple-p (harness-ui-pending-record sid "q1")))
      (with-temp-buffer
        (let ((harness-ui-session-id sid))
          (harness-ui-pending-insert-panels sid))
        (let ((multiple (harness-ui-pending-test-panel-text "m1"))
              (single (harness-ui-pending-test-panel-text "q1"))
              (off (harness-ui-pending-test-box nil)))
          (dolist (label '("Dark mode" "Offline sync" "Push notifications"))
            (should (string-search (concat off " " label) multiple)))
          (should (string-search "[Send answer]" multiple))
          (should (string-search "none ticked" multiple))
          (should (string-search "or type a note below, sent with the options ticked · from the box: C-c . 1"
                                 multiple))
          ;; An ordinary question: no boxes, no button, its hint as before.
          (should-not (string-search off single))
          (should-not (string-search "[Send answer]" single))
          (should (string-search "or type another answer below · from the box: C-c . 1" single)))))))

(ert-deftest harness-ui-pending-the-flag-is-read-as-the-wire-gives-it ()
  "Only a true flag, and only with options to pick among, allows several.
The session's pending list gives JSON, whose false is `:false'; an ACP
request gives it in camelCase."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session "Flags"))
          (drawn (list "drawn")))
      (harness-ui-pending-sync
       sid (list (list :id "t" :kind "question"
                       :payload (list :question "?" :options '("a" "b") :allow-multiple t))
                 (list :id "f" :kind "question"
                       :payload (list :question "?" :options '("a" "b") :allow-multiple :false))
                 (list :id "n" :kind "question"
                       :payload (list :question "?" :options '("a" "b")))
                 (list :id "w" :kind "question"
                       :payload (list :question "?" :options nil :allow-multiple t))))
      (should (equal '(t nil nil nil)
                     (mapcar (lambda (pid) (harness-ui-pending-multiple-p (harness-ui-pending-record sid pid)))
                             '("t" "f" "n" "w"))))
      (add-hook 'harness-ui-pending-drawn-predicates (lambda (id) (member id drawn)))
      (unwind-protect
          (progn
            (should (harness-ui-pending--on-question
                     (list :sessionId "drawn" :requestId "a" :question "?" :options '("x" "y") :allowMultiple t)
                     #'ignore))
            (should (harness-ui-pending--on-question
                     (list :sessionId "drawn" :requestId "b" :question "?" :options '("x" "y") :allowMultiple :false)
                     #'ignore))
            (should (harness-ui-pending--on-question
                     (list :sessionId "drawn" :requestId "c" :question "?" :options '("x" "y"))
                     #'ignore))
            (should (equal '(t nil nil)
                           (mapcar (lambda (pid) (harness-ui-pending-multiple-p (harness-ui-pending-record "drawn" pid)))
                                   '("a" "b" "c")))))
        (remove-hook 'harness-ui-pending-drawn-predicates (lambda (id) (member id drawn)))))))

(ert-deftest harness-ui-pending-digits-and-clicks-tick-the-options ()
  "On the panel a digit, or a click on an option, ticks it or unticks it.
It answers nothing.  The panel draws the box ticked, and how many are, in
place, with point where it was; the options ticked are kept in the
order the question gave them."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Ticker"))
           (buf (harness-ui-pending-test-chat sid))
           (on (harness-ui-pending-test-box t))
           (off (harness-ui-pending-test-box nil)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-multiple sid "m1")
      (with-current-buffer buf
        ;; A digit with point on the panel: the third option.
        (goto-char (point-min))
        (search-forward "Offline sync")
        (let ((line (line-number-at-pos)) (column (current-column)) said)
          ;; The echo area says what happened: the panel may be out of sight.
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args) (setq said (apply #'format format-string args)))))
            (call-interactively (key-binding (kbd "3"))))
          (should (equal "Ticked Push notifications: 1 of 3 ticked" said))
          (should (equal '(2) (harness-ui-pending-picked sid "m1")))
          (should (string-search (concat on " Push notifications") (buffer-string)))
          (should (string-search (concat off " Offline sync") (buffer-string)))
          (should (string-search "1 of 3 ticked" (buffer-string)))
          ;; Drawn in place: point is on the line it was on.
          (should (= line (line-number-at-pos)))
          (should (= column (current-column))))
        ;; A click on the first option; the order is the question's.
        (goto-char (point-min))
        (search-forward "Dark mode")
        (harness-ui-action-push)
        (should (equal '(0 2) (harness-ui-pending-picked sid "m1")))
        (should (equal '("Dark mode" "Push notifications") (harness-ui-pending-picked-labels sid "m1")))
        (should (string-search "2 of 3 ticked" (buffer-string)))
        ;; Unticking, with the digit.
        (harness-ui-pending-test-press-on "Push notifications" "3")
        (should (equal '(0) (harness-ui-pending-picked sid "m1")))
        (let (said)
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args) (setq said (apply #'format format-string args)))))
            (harness-ui-pending-test-press-on "Dark mode" "1"))
          (should (equal "Unticked Dark mode: none ticked" said)))
        (should-not (harness-ui-pending-picked sid "m1"))
        (should (string-search "none ticked" (buffer-string)))
        ;; A digit beyond the options is no option.
        (goto-char (point-min))
        (search-forward "Dark mode")
        (should (eq 'user-error (car (should-error (call-interactively (key-binding (kbd "5")))
                                                   :type 'user-error)))))
      ;; None of it answered anything.
      (should-not harness-ui-pending-test-answers)
      (should (harness-ui-pending-record sid "m1")))))

(ert-deftest harness-ui-pending-several-options-are-answered-with-c-c-c ()
  "The options ticked answer the question, with the box's words after them.
They come in the order of the question, a line each.  With the box empty
the options are the answer; a box with words and no option ticked
answers with the words, as for any question; with nothing, nothing is
sent."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Ticker"))
           (buf (harness-ui-pending-test-chat sid)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-multiple sid "m1")
      (with-current-buffer buf
        (should (string-search "tick options above and press C-c C-c" (harness-chat--placeholder)))
        ;; Ticked from the box, as a panel's key is pressed from there.
        (harness-ui-pending-test-panel-key "3")
        (harness-ui-pending-test-panel-key "1")
        (should (equal '(0 2) (harness-ui-pending-picked sid "m1")))
        (goto-char harness-compose-end)
        (insert "but dark mode first")
        (harness-chat-send)
        (should (equal "" (harness-compose-text))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer over ACP")
      (should (equal (list 'question sid "m1" "Dark mode\nPush notifications\nbut dark mode first")
                     (car harness-ui-pending-test-answers)))
      (should-not (harness-ui-pending-items sid))
      ;; What was ticked goes with the question.
      (should-not (gethash sid harness-ui-pending--picked))
      ;; With the box empty: the options alone.
      (harness-ui-pending-test-multiple sid "m2")
      (with-current-buffer buf
        (harness-ui-pending-test-panel-key "2")
        (should (equal "" (string-trim (harness-compose-text))))
        (harness-chat-send))
      (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the options alone")
      (should (equal (list 'question sid "m2" "Offline sync") (car harness-ui-pending-test-answers)))
      ;; Nothing ticked: the words are the answer, as for any question.
      (harness-ui-pending-test-multiple sid "m3")
      (with-current-buffer buf
        (goto-char harness-compose-end)
        (insert "none of them")
        (harness-chat-send))
      (harness-test-wait (lambda () (= 3 (length harness-ui-pending-test-answers))) 5 "the words alone")
      (should (equal (list 'question sid "m3" "none of them") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-send-answer-button-does-what-c-c-c-does ()
  "[Send answer] on the panel sends the options ticked and the box's words.
Without an option ticked or a word typed there is nothing to send, and
it says so."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Ticker"))
           (buf (harness-ui-pending-test-chat sid)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-multiple sid "m1")
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "[Send answer]")
        (should (equal "Tick an option, or type an answer, first"
                       (cadr (should-error (harness-ui-action-push) :type 'user-error))))
        (should-not harness-ui-pending-test-answers)
        (harness-ui-pending-test-press-on "Offline sync" "2")
        (goto-char (point-min))
        (search-forward "[Send answer]")
        (backward-char 3)
        (harness-ui-action-push))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer over ACP")
      (should (equal (list 'question sid "m1" "Offline sync") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-an-older-question-is-sent-by-its-own-button ()
  "The box answers the newest question, so [Send answer] of an older one sends its options alone.
What is typed in the box stays for the question it belongs to."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Ticker"))
           (buf (harness-ui-pending-test-chat sid)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-multiple sid "m1")
      (harness-ui-pending-test-multiple sid "m2")
      (should (equal '("m1" "m2") (mapcar (lambda (r) (plist-get r :id)) (harness-ui-pending-items sid))))
      (with-current-buffer buf
        (harness-ui-pending-toggle-option sid "m1" 0)
        (goto-char harness-compose-end)
        (insert "a note for the second")
        ;; The first panel is the older question's.
        (goto-char (point-min))
        (search-forward "[Send answer]")
        (backward-char 3)
        (should (equal "m1" (get-text-property (point) 'harness-ui-pending)))
        (harness-ui-action-push)
        (should (equal "a note for the second" (harness-compose-text))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the older question answered")
      (should (equal (list 'question sid "m1" "Dark mode") (car harness-ui-pending-test-answers)))
      (should (equal '("m2") (mapcar (lambda (r) (plist-get r :id)) (harness-ui-pending-items sid))))
      ;; The newest one takes the box, with nothing ticked: the words alone.
      (with-current-buffer buf
        (harness-chat-send))
      (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the newest question answered")
      (should (equal (list 'question sid "m2" "a note for the second") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-the-popout-ticks-and-sends-too ()
  "A popout of the question ticks with its digits and sends with its box.
An empty box sends the options ticked; words typed go after them.  The
chat of the session follows what the popout ticks."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Ticker"))
           (chat (harness-ui-pending-test-chat sid))
           (key (list 'pending sid))
           (on (harness-ui-pending-test-box t)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-multiple sid "m1")
      (harness-ui-pending-popout sid)
      (let ((popout (harness-ui-popout-buffer key)))
        (with-current-buffer popout
          (should (string-search "[Send answer]" (buffer-string)))
          (harness-ui-pending-test-press-on "Dark mode" "1")
          (harness-ui-pending-test-press-on "Push notifications" "3")
          (should (string-search (concat on " Dark mode") (buffer-string))))
        ;; The chat shows the same boxes ticked.
        (with-current-buffer chat
          (should (string-search (concat on " Dark mode") (buffer-string)))
          (should (string-search (concat on " Push notifications") (buffer-string)))
          (should (string-search "2 of 3 ticked" (buffer-string))))
        ;; Ticked in the chat, the popout follows.
        (with-current-buffer chat
          (harness-ui-pending-test-press-on "Push notifications" "3"))
        (with-current-buffer popout
          (should (string-search "1 of 3 ticked" (buffer-string)))
          (harness-ui-pending-test-press-on "Offline sync" "2")
          (goto-char harness-compose-end)
          (insert "  plus a note ")
          (harness-ui-popout-submit)))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer from the popout")
      (should (equal (list 'question sid "m1" "Dark mode\nOffline sync\nplus a note")
                     (car harness-ui-pending-test-answers)))
      ;; The options alone, the box empty.
      (harness-ui-pending-test-multiple sid "m2")
      (harness-ui-pending-popout sid)
      (with-current-buffer (harness-ui-popout-buffer key)
        (should (functionp harness-ui-popout-empty-ok-function))
        (should-not (funcall harness-ui-popout-empty-ok-function))
        (should-error (harness-ui-popout-submit) :type 'user-error)
        (harness-ui-pending-test-press-on "Offline sync" "2")
        (should (funcall harness-ui-popout-empty-ok-function))
        (harness-ui-popout-submit))
      (harness-test-wait (lambda () (= 2 (length harness-ui-pending-test-answers))) 5 "the options alone")
      (should (equal (list 'question sid "m2" "Offline sync") (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-a-request-owned-over-acp-answers-the-lines-in-its-reply ()
  "A question a client owns (the ACP request) is answered through its RESPOND.
The reply is the options ticked, a line each, as the harness reads it."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Owner"))
           (drawn-p (lambda (id) (equal id sid)))
           (answers nil))
      (add-hook 'harness-ui-pending-drawn-predicates drawn-p)
      (unwind-protect
          (progn
            (should (harness-ui-pending--on-question
                     (list :sessionId sid :requestId "q9" :question "Which?" :options '("a" "b" "c")
                           :allowMultiple t)
                     (lambda (reply) (push reply answers) t)))
            (harness-ui-pending-toggle-option sid "q9" 2)
            (harness-ui-pending-toggle-option sid "q9" 0)
            (should (equal "a\nc" (harness-ui-pending-compose-answer sid (harness-ui-pending-record sid "q9") "")))
            (harness-ui-pending-answer-question
             sid "q9" (harness-ui-pending-compose-answer sid (harness-ui-pending-record sid "q9") "later"))
            (should (equal '((:answer "a\nc\nlater")) answers)))
        (remove-hook 'harness-ui-pending-drawn-predicates drawn-p)))))

(ert-deftest harness-ui-pending-views-answer-with-the-options-ticked ()
  "A view that answers with words (the task board's box) puts the options ticked first.
Ticking is for a question that allows several: it refuses any other, a
question gone, and an option it has not."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session "Viewer")))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-test-multiple sid "m1")
      (harness-ui-pending-toggle-option sid "m1" 1)
      (harness-ui-pending-answer-first-question sid "maybe tomorrow")
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer over ACP")
      (should (equal (list 'question sid "m1" "Offline sync\nmaybe tomorrow")
                     (car harness-ui-pending-test-answers)))
      ;; The refusals.
      (harness-ui-pending-test-question sid "q1")
      (harness-ui-pending-test-multiple sid "m2")
      (should (equal "This question takes one answer"
                     (cadr (should-error (harness-ui-pending-toggle-option sid "q1" 0) :type 'user-error))))
      (should (equal "No such option"
                     (cadr (should-error (harness-ui-pending-toggle-option sid "m2" 3) :type 'user-error))))
      (should (equal "That question was answered already"
                     (cadr (should-error (harness-ui-pending-toggle-option sid "gone" 0) :type 'user-error))))
      ;; An ordinary question's digits still answer, whatever the flag says of others.
      (should-not (harness-ui-pending-picked sid "q1"))
      (should (equal "words" (harness-ui-pending-compose-answer sid (harness-ui-pending-record sid "q1") "words"))))))

;;;; What the lasting answers cover

(defconst harness-ui-pending-test-options
  '("allow-once" "allow-session" "allow-always" "deny-once" "deny-always")
  "The answers a request offers when nothing narrows them.")

(defun harness-ui-pending-test-ladder-item (&optional id options)
  "Return a pending item for a shell call that comes with a ladder of covers.
ID names it (\"ladder\" by default); OPTIONS are the answers it offers.
The covers are those the harness works out for
`gcloud compute instances list --project p': the last but one, every
call of its program, is the one the lasting answers start on."
  (list :id (or id "ladder") :kind "permission"
        :payload (list :title "Bash: gcloud compute instances list --project p" :tool "bash" :kind "exec"
                       :input '(:command "gcloud compute instances list --project p")
                       :cwd "/home/u/proj/" :paths '("/home/u/proj/")
                       :commands '(("gcloud")) :covers "gcloud"
                       :ladder '((:id "exact" :label "every bash call with this exact command")
                                 (:id "subcommands" :label "every gcloud compute instances call (any arguments)")
                                 (:id "programs" :label "every gcloud call (any arguments)")
                                 (:id "tool" :label "every bash call (any command)"))
                       :cover "programs"
                       :options (or options harness-ui-pending-test-options))))

(defun harness-ui-pending-test-rendered (sid pid)
  "Return the panel of request PID of SID as a chat draws it, without properties."
  (with-temp-buffer
    (let ((harness-ui-session-id sid))
      (harness-ui-pending--insert-permission (harness-ui-pending-record sid pid)))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-pending-test-step-line (selected label &optional note)
  "Return the line of a cover block that shows LABEL, picked when SELECTED.
NOTE is the dim word after it."
  (concat "     "
          (substring-no-properties
           (harness-ui-icon (if selected 'harness-icon-radio-on 'harness-icon-radio-off)))
          " " label (if note (concat "  " note) "")))

(defun harness-ui-pending-test-face-p (pos face)
  "Non-nil when the text at POS wears FACE, alone or among others."
  (let ((faces (get-text-property pos 'face)))
    (if (listp faces) (and (memq face faces) t) (eq face faces))))

(defun harness-ui-pending-test-picked (sid pid)
  "Return the label of the picked line of the block of request PID of SID, as drawn."
  (let ((on (substring-no-properties (harness-ui-icon 'harness-icon-radio-on)))
        (text (harness-ui-pending-test-rendered sid pid)))
    (when (string-match (concat "^     " (regexp-quote on)
                                " \\(.*?\\)\\(?:  default\\|  edited\\|  home directory\\|  whole host\\)?$")
                        text)
      (match-string 1 text))))

(ert-deftest harness-ui-pending-ladder-panel-lists-the-covers ()
  "A call with a ladder says what its lasting answers cover, on the panel.
Every step is a line, narrowest first, the one they start on picked, with
the keys of the answers the block is for and buttons that move the pick;
the facts line of the commands it replaces is gone."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ladder-item)))
      (let ((text (harness-ui-pending-test-rendered sid "ladder")))
        (should (string-search
                 (concat "   command: gcloud compute instances list --project p\n"
                         "   Lasting answers (s, a, N) cover:\n"
                         (harness-ui-pending-test-step-line nil "every bash call with this exact command") "\n"
                         (harness-ui-pending-test-step-line nil "every gcloud compute instances call (any arguments)") "\n"
                         (harness-ui-pending-test-step-line t "every gcloud call (any arguments)") "\n"
                         (harness-ui-pending-test-step-line nil "every bash call (any command)") "\n"
                         "   [Narrower] <  [Wider] >\n"
                         "   [Allow] y  [Allow for session] s  [Always allow] a  [Deny] n  [Always deny] N")
                 text))
        (should-not (string-search "lasting answers:" text)))
      (should (equal "programs" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
      (should (equal "every gcloud call (any arguments)" (harness-ui-pending-test-picked sid "ladder")))
      ;; The lines are buttons with a tooltip that says what a click does.
      (with-temp-buffer
        (let ((harness-ui-session-id sid))
          (harness-ui-pending--insert-permission (harness-ui-pending-record sid "ladder")))
        (goto-char (point-min))
        (search-forward "every bash call (any command)")
        (should (equal "Make Allow for session, Always allow and Always deny cover every bash call (any command) (click)"
                       (get-text-property (1- (point)) 'help-echo)))
        (should (get-text-property (1- (point)) 'harness-ui-action))))))

(ert-deftest harness-ui-pending-covers-are-all-the-panels ()
  "The lines of covers and patterns belong to the panel, as every other line does.
So the box's C-c . finds the panel's keys, and one request's panel ends
where the next one's starts."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ladder-item "a")
                                         (harness-ui-pending-test-item 'jail)
                                         (harness-ui-pending-test-ladder-item "b")))
      (with-temp-buffer
        (let ((harness-ui-session-id sid))
          (harness-ui-pending-insert-panels sid))
        (should (string-search "Lasting answers (" (buffer-string)))
        (should (string-search "Answers hold for:" (buffer-string)))
        (should (cl-loop for i from (point-min) below (point-max)
                         always (equal (get-text-property i 'harness-ui-pending)
                                       (get-text-property i 'harness-compose-panel))))
        ;; Each block is the panel of the request it is about.
        (goto-char (point-min))
        (dolist (pid '("a" "jail" "b"))
          (re-search-forward (if (equal pid "jail") "Answers hold for:" "Lasting answers ("))
          (should (equal pid (get-text-property (point) 'harness-ui-pending)))
          (should (equal pid (get-text-property (point) 'harness-ui-pending-cover))))))))

(ert-deftest harness-ui-pending-a-button-moves-the-cover-of-its-own-request ()
  "[Narrower] and [Wider] belong to the request they are drawn in.
Once it is answered they say so, rather than moving the cover of another
request that waits: a stale click must not change what an answer to a
different request will record."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (harness-ui-pending-session-id sid)
           (cover (lambda (pid) (harness-ui-pending--cover-id (harness-ui-pending-record sid pid)))))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ladder-item "a")
                                         (harness-ui-pending-test-ladder-item "b")
                                         (harness-ui-pending-test-item 'tool)))
      (harness-ui-pending-cover-wider "a")
      (should (equal "tool" (funcall cover "a")))
      (should (equal "programs" (funcall cover "b")))
      ;; A request with nothing to choose between, named by its button.
      (should (equal "That request has no covers to choose between"
                     (cadr (should-error (harness-ui-pending-cover-wider "tool") :type 'user-error))))
      ;; One answered already.
      (harness-ui-pending-answer-permission sid "a" "allow-once")
      (should (equal "That request was answered already"
                     (cadr (should-error (harness-ui-pending-cover-narrower "a") :type 'user-error))))
      (should (equal "programs" (funcall cover "b")))
      ;; A key, which names no request, goes to the one that has covers.
      (harness-ui-pending-cover-narrower)
      (should (equal "subcommands" (funcall cover "b"))))))

(ert-deftest harness-ui-pending-ladder-of-one-step-is-one-line ()
  "A ladder of one step is that step on the header's line, without the buttons that move."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync
       sid (list (list :id "spawn" :kind "permission"
                       :payload (list :title "Sub-agent: x" :tool "spawn_agent" :kind "meta"
                                      :ladder '((:id "tool" :label "every spawn_agent call (any arguments)"))
                                      :cover "tool" :options harness-ui-pending-test-options))))
      (let ((text (harness-ui-pending-test-rendered sid "spawn")))
        (should (string-search "   Lasting answers (s, a, N) cover: every spawn_agent call (any arguments)\n" text))
        (should-not (string-search "[Narrower]" text))
        (should-not (string-search "[Wider]" text)))
      ;; Its tooltips and echo say it too; nothing to pick, so < and > type.
      (let ((r (harness-ui-pending-record sid "spawn")))
        (should (equal "Always allow every spawn_agent call (any arguments), in every session"
                       (harness-ui-pending-answer-help r "allow-always")))
        (should-not (cdr (harness-ui-pending--cover-steps r)))))))

(ert-deftest harness-ui-pending-ladder-block-follows-the-answers-offered ()
  "The block names the lasting answers a request offers, and only those.
A policy can take Always allow and Always deny away: the keys of the
header go with them, and a request with no lasting answer draws no block
and no facts line either."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync
       sid (list (harness-ui-pending-test-ladder-item "some" '("allow-once" "allow-session" "deny-once"))
                 (harness-ui-pending-test-ladder-item "none" '("allow-once" "deny-once"))))
      (let ((some (harness-ui-pending-test-rendered sid "some")))
        (should (string-search "   Lasting answers (s) cover:\n" some))
        (should (string-search "[Allow] y  [Allow for session] s  [Deny] n  \n" some)))
      (with-temp-buffer
        (let ((harness-ui-session-id sid))
          (harness-ui-pending--insert-permission (harness-ui-pending-record sid "some")))
        (goto-char (point-min))
        (search-forward "every bash call (any command)")
        (should (equal "Make Allow for session cover every bash call (any command) (click)"
                       (get-text-property (1- (point)) 'help-echo))))
      (let ((none (harness-ui-pending-test-rendered sid "none")))
        (should-not (string-search "Lasting answers" none))
        (should-not (string-search "lasting answers" none))
        (should-not (string-search "every gcloud" none))))))

(ert-deftest harness-ui-pending-records-without-a-ladder-draw-as-before ()
  "A request the harness sent no ladder for says what its answers cover as it always did.
Its shell commands in a line of facts, its tool in the tooltips; it is
no panel of covers, and < and > have nothing to move."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-item 'tool)))
      (let ((text (harness-ui-pending-test-rendered sid "tool"))
            (r (harness-ui-pending-record sid "tool")))
        (should (string-search "lasting answers: every ls call\n" text))
        (should-not (string-search "Lasting answers (" text))
        (should-not (string-search "[Narrower]" text))
        (should-not (harness-ui-pending--ladder r))
        (should-not (harness-ui-pending--cover-id r))
        (should-not (harness-ui-pending--cover-label r))
        (should-not (harness-ui-pending--cover-steps r))
        (should (equal "Always allow every ls call, in every session"
                       (harness-ui-pending-answer-help r "allow-always")))
        (should-error (harness-ui-pending-set-cover sid "tool" "exact") :type 'user-error)
        (let ((harness-ui-pending-session-id sid))
          (should-error (harness-ui-pending-cover-wider "tool") :type 'user-error))))))

(ert-deftest harness-ui-pending-picked-cover-is-what-the-answers-say ()
  "Picking a step moves the mark, the tooltips and the echo area with it.
The first lasting answer carries the id of the picked step; one that
records nothing carries none."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (hooked 0)
           (hook (lambda (_sid) (cl-incf hooked))))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ladder-item)))
      (let ((r (lambda () (harness-ui-pending-record sid "ladder"))))
        (add-hook 'harness-ui-pending-changed-hook hook)
        (unwind-protect
            (progn
              ;; What the answers start on: the step the harness named.
              (should (equal "Always allow every gcloud call (any arguments), in every session"
                             (harness-ui-pending-answer-help (funcall r) "allow-always")))
              (should (equal "Allow every gcloud call (any arguments) for this session"
                             (harness-ui-pending-answer-help (funcall r) "allow-session")))
              (should (equal "Always deny every gcloud call (any arguments)"
                             (harness-ui-pending-answer-help (funcall r) "deny-always")))
              ;; What records nothing says the same as ever.
              (should (equal "Allow this call, this time" (harness-ui-pending-answer-help (funcall r) "allow-once")))
              (should (equal "Deny this call" (harness-ui-pending-answer-help (funcall r) "deny-once")))
              (harness-ui-pending-set-cover sid "ladder" "exact")
              (should (= 1 hooked))
              (should (equal "exact" (harness-ui-pending--cover-id (funcall r))))
              (should (equal "every bash call with this exact command" (harness-ui-pending-test-picked sid "ladder")))
              (should (equal "Always allow every bash call with this exact command, in every session"
                             (harness-ui-pending-answer-help (funcall r) "allow-always")))
              (should (equal "Allowed every bash call with this exact command for this session"
                             (harness-ui-pending--message-for (funcall r) "allow-session")))
              (should (equal "Always allowed every bash call with this exact command"
                             (harness-ui-pending--message-for (funcall r) "allow-always")))
              (should (equal "Always denied every bash call with this exact command"
                             (harness-ui-pending--message-for (funcall r) "deny-always")))
              (should (equal "Allowed this call" (harness-ui-pending--message-for (funcall r) "allow-once")))
              ;; Picking the one already picked changes nothing, and redraws nothing.
              (harness-ui-pending-set-cover sid "ladder" "exact")
              (should (= 1 hooked))
              ;; A step the ladder lacks, or a request that is gone, is refused.
              (should-error (harness-ui-pending-set-cover sid "ladder" "nowhere") :type 'user-error)
              (should-error (harness-ui-pending-set-cover sid "gone" "exact") :type 'user-error)
              (should (equal "exact" (harness-ui-pending--cover-id (funcall r)))))
          (remove-hook 'harness-ui-pending-changed-hook hook))))))

(ert-deftest harness-ui-pending-pick-survives-the-request-arriving-again ()
  "The session's pending list brings a request again: the cover picked stays.
While the ladder still has it; a ladder that lost it goes back to where
the answers start, and so does one that names no such step."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (item (harness-ui-pending-test-ladder-item))
           (again (lambda (item)
                    (harness-ui-pending-add sid (harness-ui-pending--record-of-item item))
                    (harness-ui-pending-record sid "ladder"))))
      (harness-ui-pending-sync sid (list item))
      (harness-ui-pending-set-cover sid "ladder" "tool")
      (should (equal "tool" (harness-ui-pending--cover-id (funcall again item))))
      (should (equal "tool" (plist-get (harness-ui-pending-record sid "ladder") :picked-cover)))
      ;; A ladder without the step picked: back to the harness's own.
      (let ((narrower (copy-tree item)))
        (setf (plist-get (plist-get narrower :payload) :ladder)
              '((:id "exact" :label "every bash call with this exact command")
                (:id "programs" :label "every gcloud call (any arguments)")))
        (should (equal "programs" (harness-ui-pending--cover-id (funcall again narrower))))
        (should-not (plist-get (harness-ui-pending-record sid "ladder") :picked-cover)))
      ;; A cover the harness names that its ladder lacks: the narrowest.
      (let ((odd (copy-tree item)))
        (setf (plist-get (plist-get odd :payload) :cover) "nowhere")
        (should (equal "exact" (harness-ui-pending--cover-id (funcall again odd))))))))

(ert-deftest harness-ui-pending-ladder-comes-over-the-wire-as-a-vector ()
  "A ladder an ACP client sends in `_harness' is a vector; it is read like a list.
The request that arrives over ACP keeps its ladder and its cover, and
its answer goes back through the function that holds it, the picked
cover in its `_harness'; what records nothing carries none."
  (harness-ui-pending-test-with
    (let* ((answers nil)
           (respond (lambda (r) (push r answers) t))
           (drawn (list "drawn"))
           (drawn-p (lambda (sid) (member sid drawn))))
      (add-hook 'harness-ui-pending-drawn-predicates drawn-p)
      (unwind-protect
          (progn
            (should (harness-ui-pending--on-permission
                     (list :sessionId "drawn"
                           :toolCall (list :toolCallId "c1" :title "Bash: ls -la" :kind "execute"
                                           :rawInput '(:command "ls -la"))
                           :options harness-acp--permission-options
                           :_harness (list :pendingId "p9" :tool "bash" :commands '(("ls")) :covers "ls"
                                           :ladder (vector (list :id "exact" :label "every bash call with this exact command")
                                                           (list :id "programs" :label "every ls call (any arguments)")
                                                           (list :id "tool" :label "every bash call (any command)"))
                                           :cover "programs"))
                     respond))
            (let ((r (harness-ui-pending-record "drawn" "p9")))
              (should (equal "programs" (plist-get r :cover)))
              (should (= 3 (length (harness-ui-pending--ladder r))))
              (should (equal "programs" (harness-ui-pending--cover-id r)))
              (should (equal '(("exact" "every bash call with this exact command")
                               ("programs" "every ls call (any arguments)")
                               ("tool" "every bash call (any command)"))
                             (harness-ui-pending--cover-steps r))))
            (harness-ui-pending-set-cover "drawn" "p9" "exact")
            (harness-ui-pending-answer-permission "drawn" "p9" "allow-always")
            (should (equal '((:outcome (:outcome "selected" :optionId "allow-always")
                                       :_harness (:cover "exact")))
                           answers))
            ;; An answer that records nothing carries no cover.
            (should (harness-ui-pending--on-permission
                     (list :sessionId "drawn"
                           :toolCall (list :toolCallId "c2" :title "Bash: ls" :kind "execute")
                           :options harness-acp--permission-options
                           :_harness (list :pendingId "p10" :tool "bash"
                                           :ladder (list (list :id "tool" :label "every bash call (any command)"))
                                           :cover "tool"))
                     respond))
            (harness-ui-pending-answer-permission "drawn" "p10" "allow-once")
            (should (equal '(:outcome (:outcome "selected" :optionId "allow-once")) (car answers))))
        (remove-hook 'harness-ui-pending-drawn-predicates drawn-p)))))

(ert-deftest harness-ui-pending-answers-over-the-method-carry-the-cover ()
  "A request only the session's pending list knows is answered over `permission/answer'.
A lasting answer carries the id of the picked cover next to its option,
the three of them; Allow and Deny are the plain option, which records
nothing for a cover to say."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-test-record-answers)
      (dolist (c '(("allow-session" . (:option "allow-session" :cover "exact"))
                   ("allow-always" . (:option "allow-always" :cover "exact"))
                   ("deny-always" . (:option "deny-always" :cover "exact"))
                   ("allow-once" . "allow-once")
                   ("deny-once" . "deny-once")))
        (let ((pid (concat "ladder-" (car c))))
          (harness-ui-pending-sync sid (list (harness-ui-pending-test-ladder-item pid)))
          (harness-ui-pending-set-cover sid pid "exact")
          (setq harness-ui-pending-test-answers nil)
          (harness-ui-pending-answer-permission sid pid (car c))
          (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 (format "the %s answer" (car c)))
          (should (equal (list 'permission sid pid (cdr c)) (car harness-ui-pending-test-answers))))))))

(defun harness-ui-pending-test-popout-panel (sid)
  "Open the popout of SID's requests and return its buffer, point on the panel."
  (harness-ui-pending-popout sid)
  (let ((buf (harness-ui-popout-buffer (list 'pending sid))))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "Permission"))
    buf))

(ert-deftest harness-ui-pending-keys-move-the-cover-on-the-panel ()
  "< picks the next narrower line, > the next wider one, with point on the panel.
At either end nothing moves, and the echo area says which end it is.
Point goes to the picked line again after the popout draws itself anew,
so the keys go on working; the lasting answers hold for the new pick."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (buf (progn (harness-ui-pending-test-record-answers)
                       (harness-ui-pending-sync sid (list (harness-ui-pending-test-ladder-item)))
                       (harness-ui-pending-test-popout-panel sid)))
           (shown nil)
           (press (lambda (key)
                    (setq shown nil)
                    (cl-letf (((symbol-function 'message)
                               (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) shown)))))
                      (call-interactively (key-binding (kbd key))))
                    (car shown))))
      (with-current-buffer buf
        (should (eq 'harness-ui-pending-cover-narrower (key-binding (kbd "<"))))
        (should (eq 'harness-ui-pending-cover-wider (key-binding (kbd ">"))))
        (should (equal "Lasting answers now cover every bash call (any command)" (funcall press ">")))
        (should (equal "tool" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
        ;; Point went back to the picked line, which is on the panel.
        (should (equal "ladder" (get-text-property (point) 'harness-ui-pending-selected)))
        (should (equal "ladder" (get-text-property (point) 'harness-ui-pending)))
        (should (equal "Already the widest cover: every bash call (any command)" (funcall press ">")))
        (should (equal "tool" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
        (should (string-search (harness-ui-pending-test-step-line t "every bash call (any command)") (buffer-string)))
        (should (equal "Lasting answers now cover every gcloud call (any arguments)" (funcall press "<")))
        (should (equal "Lasting answers now cover every gcloud compute instances call (any arguments)"
                       (funcall press "<")))
        (should (equal "Lasting answers now cover every bash call with this exact command" (funcall press "<")))
        (should (equal "Already the narrowest cover: every bash call with this exact command" (funcall press "<")))
        (should (equal "exact" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
        ;; The end a pick cannot go on to has its button dim.
        (goto-char (point-min))
        (search-forward "[Narrower]")
        (should (harness-ui-pending-test-face-p (- (point) 3) 'harness-dim-face))
        (search-forward "[Wider]")
        (should (harness-ui-pending-test-face-p (- (point) 3) 'button))
        (should-not (harness-ui-pending-test-face-p (- (point) 3) 'harness-dim-face))
        ;; The panel still answers: Always allow holds for what is picked.
        (goto-char (point-min))
        (search-forward "Permission")
        (call-interactively (key-binding (kbd "a"))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the lasting answer")
      (should (equal (list 'permission sid "ladder" '(:option "allow-always" :cover "exact"))
                     (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-clicking-a-line-picks-it ()
  "A click on a line of the block, or RET on it, picks that cover.
So does a click on [Narrower] and [Wider], which the keys do."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (buf (progn (harness-ui-pending-sync sid (list (harness-ui-pending-test-ladder-item)))
                       (harness-ui-pending-test-popout-panel sid))))
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "every gcloud compute instances call")
        (harness-ui-action-push)
        (should (equal "subcommands" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
        (should (equal "every gcloud compute instances call (any arguments)" (harness-ui-pending-test-picked sid "ladder")))
        (should (equal "ladder" (get-text-property (point) 'harness-ui-pending-selected)))
        ;; The popout is drawn anew after each click: find the button again.
        (let ((click (lambda (button)
                       (goto-char (point-min))
                       (search-forward button)
                       (backward-char 2)
                       (harness-ui-action-push))))
          (funcall click "[Wider]")
          (should (equal "programs" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
          (funcall click "[Narrower]")
          (funcall click "[Narrower]")
          (should (equal "exact" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder")))))))))

(ert-deftest harness-ui-pending-cover-keys-type-in-the-box-and-press-from-it ()
  "In the compose box < and > type; C-c . then the key moves the cover.
On a panel with nothing to pick between they type too, into the box."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           ;; A popout has a box only when a question waits in it.
           (buf (progn (harness-ui-pending-test-record-answers)
                       (harness-ui-pending-sync
                        sid (list (list :id "q1" :kind "question"
                                        :payload (list :question "Which colour?" :options '("red" "green")))
                                  (harness-ui-pending-test-ladder-item)))
                       (harness-ui-pending-test-popout-panel sid))))
      (with-current-buffer buf
        (goto-char harness-compose-end)
        (insert "x")
        ;; Typed in the box, they are text.
        (execute-kbd-macro (kbd "<"))
        (should (equal "x<" (harness-compose-text)))
        (should (equal "programs" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
        (goto-char (+ harness-compose-start 1))
        ;; Pressed from the box, they move the pick; point and draft stay.
        (execute-kbd-macro (kbd "C-c . >"))
        (should (equal "tool" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder"))))
        (should (equal "x<" (harness-compose-text)))
        (should (= (point) (+ harness-compose-start 1)))
        (execute-kbd-macro (kbd "C-c . <"))
        (should (equal "programs" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ladder")))))
      ;; Where the panel has no covers to pick between, the key types.
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-item 'tool)))
      (harness-ui-pending-answer-permission sid "ladder" "allow-once")
      (should-not (harness-ui-pending-record sid "ladder"))
      (let ((buf (harness-ui-popout-buffer (list 'pending sid))))
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "Permission")
          (should (eq 'harness-ui-pending-cover-wider (key-binding (kbd ">"))))
          (should-not (harness-ui-pending--steps-here-p))
          (execute-kbd-macro (kbd ">"))
          (should (equal "x<>" (harness-compose-text))))))))

;;;; The patterns a prompt about a path is answered for

(ert-deftest harness-ui-pending-pattern-block-lists-the-patterns-around-its-own ()
  "A request about a path outside lists its patterns as lines, narrowest first.
The request's own is noted as the default and picked, and [Edit] types
another; a pattern the user typed that is none of them is a line of its
own, noted as edited, and the pattern the answers hold for."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-item 'jail)))
      (should (string-search
               (concat "   Answers hold for:\n"
                       (harness-ui-pending-test-step-line nil "/srv/notes/todo.org") "\n"
                       (harness-ui-pending-test-step-line nil "/srv/notes/*.org") "\n"
                       (harness-ui-pending-test-step-line t "/srv/notes/**" "default") "\n"
                       (harness-ui-pending-test-step-line nil "/srv/**") "\n"
                       "   [Edit] e  [Narrower] <  [Wider] >\n"
                       "   [Allow] y")
               (harness-ui-pending-test-rendered sid "jail")))
      (should-not (string-search "pattern:" (harness-ui-pending-test-rendered sid "jail")))
      (should (equal "/srv/notes/**" (harness-ui-pending--cover-selected (harness-ui-pending-record sid "jail"))))
      ;; Typed, and none of the others.
      (harness-ui-pending-set-pattern sid "jail" "/srv/notes/sub/*.org")
      (should (string-search
               (concat (harness-ui-pending-test-step-line nil "/srv/notes/**" "default") "\n"
                       (harness-ui-pending-test-step-line nil "/srv/**") "\n"
                       (harness-ui-pending-test-step-line t "/srv/notes/sub/*.org" "edited") "\n")
               (harness-ui-pending-test-rendered sid "jail")))
      ;; Typed, and one of them: picked, not edited text.
      (harness-ui-pending-set-pattern sid "jail" "/srv/notes/*.org")
      (should (equal "/srv/notes/*.org" (harness-ui-pending-test-picked sid "jail")))
      (should-not (string-search "edited" (harness-ui-pending-test-rendered sid "jail")))
      ;; The tooltips name the pattern, as they did.
      (should (equal "Allow /srv/notes/*.org for this session"
                     (harness-ui-pending-answer-help (harness-ui-pending-record sid "jail") "allow-session"))))))

(ert-deftest harness-ui-pending-pattern-lines-pick-the-pattern ()
  "A click on a line, or < and >, makes that the pattern the answers hold for.
The request's own goes back to being no edit, as an empty answer to the
minibuffer did, and the answer carries the pattern picked."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (buf (progn (harness-ui-pending-test-record-answers)
                       (harness-ui-pending-sync sid (list (harness-ui-pending-test-item 'jail)))
                       (harness-ui-pending-test-popout-panel sid)))
           (r (lambda () (harness-ui-pending-record sid "jail"))))
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "/srv/notes/*.org")
        (harness-ui-action-push)
        (should (equal "/srv/notes/*.org" (plist-get (funcall r) :edited-pattern)))
        (should (equal "jail" (get-text-property (point) 'harness-ui-pending-selected)))
        (call-interactively (key-binding (kbd ">")))
        (should (equal "/srv/notes/**" (harness-ui-pending--cover-selected (funcall r))))
        (should-not (plist-get (funcall r) :edited-pattern))
        (call-interactively (key-binding (kbd ">")))
        (should (equal "/srv/**" (plist-get (funcall r) :edited-pattern)))
        (let ((shown nil))
          (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq shown (apply #'format fmt args)))))
            (call-interactively (key-binding (kbd ">"))))
          (should (equal "Already the widest pattern: /srv/**" shown)))
        (call-interactively (key-binding (kbd "<")))
        (call-interactively (key-binding (kbd "<")))
        (call-interactively (key-binding (kbd "<")))
        (should (equal "/srv/notes/todo.org" (plist-get (funcall r) :edited-pattern)))
        (goto-char (point-min))
        (search-forward "Permission")
        (call-interactively (key-binding (kbd "s"))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer")
      ;; The pattern, as the minibuffer's answer carried it, and no cover.
      (should (equal (list 'permission sid "jail" '(:option "allow-session" :pattern "/srv/notes/todo.org"))
                     (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-pattern-block-of-one-line ()
  "A request whose pattern has nothing around it is one line, with [Edit] alone."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync
       sid (list (list :id "root" :kind "permission"
                       :payload (list :title "Access /" :tool "request_directory_access" :kind "meta"
                                      :dir "/" :pattern "/**" :options harness-ui-pending-test-options))))
      (let ((text (harness-ui-pending-test-rendered sid "root")))
        (should (string-search "   Answers hold for: /**  [Edit] e\n" text))
        (should-not (string-search "[Narrower]" text))
        (should-not (cdr (harness-ui-pending--cover-steps (harness-ui-pending-record sid "root"))))))))

;;;; Paths on a host

;; A request about a path on another host is answered for a pattern like
;; any other, but a host has no repository root for the harness to look
;; for (nothing in the permission chain connects): the lines around the
;; pattern are the directories above it up to the host's root, which is
;; always the last.  A path in the home directory of the login is written
;; with its tilde, which nothing here may expand: a tilde name expanded
;; would connect to the host, or give this machine's own home directory.

(declare-function harness-ui-pending--pattern-choices "harness-ui-pending")
(declare-function harness-ui-pending--pattern-place "harness-ui-pending")
(declare-function harness-ui-pending--permission-facts "harness-ui-pending")
(defvar harness-ui-pending--ancestors-near)

(defconst harness-ui-pending-test-host "/ssh:admin@laptop-0#4358:"
  "TRAMP's name of a host that exists nowhere, with a user and a port.")

(defun harness-ui-pending-test-ssh-jail-item (&optional id)
  "Return the pending item of the jail's prompt about the home directory on a host.
ID names it (\"ssh-jail\" by default): the first call of the ssh tool to
the host, which runs in the login's home directory."
  (let ((home (concat harness-ui-pending-test-host "~/")))
    (list :id (or id "ssh-jail") :kind "permission"
          :payload (list :title (format "Access %s (the login's home directory)" home)
                         :tool "ssh" :kind "exec"
                         :input '(:host "admin@laptop-0:4358" :command "uptime")
                         :paths (list home) :dir home :pattern (concat home "**")
                         :reason (format "SSH wants %s (the home directory of the login on admin@laptop-0#4358, where ssh starts), which is outside the allowed directories" home)
                         :options harness-ui-pending-test-options))))

(defun harness-ui-pending-test-ssh-tool-item (&optional id paths)
  "Return the pending item of the ssh tool's own prompt, once the home is allowed.
ID names it (\"ssh-tool\" by default); PATHS are the paths the command
names outside the session's directories, the home directory it runs in by
default.  Its covers are those the harness works out for
`journalctl -u k3s | tail -50' on the host: the last but two, every call
of its programs on the host, is the one the lasting answers start on."
  (let ((home (concat harness-ui-pending-test-host "~/")))
    (list :id (or id "ssh-tool") :kind "permission"
          :payload (list :title "SSH: admin@laptop-0:4358: journalctl -u k3s | tail -50" :tool "ssh" :kind "exec"
                         :input '(:host "admin@laptop-0:4358" :command "journalctl -u k3s | tail -50")
                         :cwd home :paths (or paths (list home))
                         :commands '(("journalctl") ("tail")) :covers "journalctl and tail"
                         :ladder '((:id "exact" :label "every ssh call whose host is exactly \"admin@laptop-0:4358\" and command is exactly \"journalctl -u k3s | tail -50\"")
                                   (:id "host-programs" :label "every journalctl and tail call on admin@laptop-0:4358 (any arguments)")
                                   (:id "host-tool" :label "every ssh call on admin@laptop-0:4358 (any command)")
                                   (:id "programs" :label "every journalctl and tail call (any host, any arguments)")
                                   (:id "tool" :label "every ssh call (any host, any command)"))
                         :cover "host-programs"
                         :options harness-ui-pending-test-options))))

(ert-deftest harness-ui-pending-patterns-on-a-host-go-up-to-its-root ()
  "The lines for a path on a host are the path, its pattern, each directory
above it, and last the root of the host, the widest answer there is.  The
home directory of a login comes after the directories in it, before the
root.  Nothing is looked up or expanded."
  (require 'harness-ui-pending)
  (harness-test-without-connections
    (let ((host harness-ui-pending-test-host))
      (cl-flet ((choices (pattern paths &rest more)
                  (harness-ui-pending--pattern-choices (append (list :pattern pattern :paths paths) more))))
        ;; The first call of the ssh tool to a host: its home directory.
        (should (equal (list (concat host "~/") (concat host "~/**") (concat host "/**"))
                       (choices (concat host "~/**") (list (concat host "~/")))))
        ;; A directory in it: each one above, the home, the host.
        (should (equal (list (concat host "~/projects/x/") (concat host "~/projects/x/**")
                             (concat host "~/projects/**") (concat host "~/**") (concat host "/**"))
                       (choices (concat host "~/projects/x/**") (list (concat host "~/projects/x/")))))
        ;; An absolute directory has no home to stop at.
        (should (equal '("/ssh:benito:/var/log/nginx/" "/ssh:benito:/var/log/nginx/**" "/ssh:benito:/var/log/**"
                         "/ssh:benito:/var/**" "/ssh:benito:/**")
                       (choices "/ssh:benito:/var/log/nginx/**" '("/ssh:benito:/var/log/nginx/"))))
        ;; The host's root has nothing above it.
        (should (equal '("/ssh:benito:/" "/ssh:benito:/**")
                       (choices "/ssh:benito:/**" '("/ssh:benito:/"))))
        ;; A file: the files like it beside it, the directories between it and the pattern's.
        (should (equal (list (concat host "~/projects/x/src/a.el") (concat host "~/projects/x/src/*.el")
                             (concat host "~/projects/x/src/**") (concat host "~/projects/x/**")
                             (concat host "~/projects/**") (concat host "~/**") (concat host "/**"))
                       (choices (concat host "~/projects/**") (list (concat host "~/projects/x/src/a.el")))))
        ;; A path outside the pattern's directory is a line of its own and nothing between.
        (should (equal '("/ssh:benito:/etc/hosts" "/ssh:benito:/srv/**" "/ssh:benito:/**")
                       (choices "/ssh:benito:/srv/**" '("/ssh:benito:/etc/hosts"))))
        ;; Another user's home is a home, with the host above it.
        (should (equal '("/ssh:benito:~bob/**" "/ssh:benito:/**")
                       (choices "/ssh:benito:~bob/**" nil)))
        ;; A pattern that is no directory's has nothing around it.
        (should (equal '("/ssh:benito:~/src/*.el") (choices "/ssh:benito:~/src/*.el" nil)))
        ;; One the user typed is a line of its own, last, as for a path here.
        (should (equal (list (concat host "~/") (concat host "~/**") (concat host "/**")
                             (concat host "~/notes/*.org"))
                       (choices (concat host "~/**") (list (concat host "~/"))
                                :edited-pattern (concat host "~/notes/*.org"))))
        ;; ... unless it is one of them.
        (should (equal (list (concat host "~/") (concat host "~/**") (concat host "/**"))
                       (choices (concat host "~/**") (list (concat host "~/"))
                                :edited-pattern (concat host "/**"))))))))

(ert-deftest harness-ui-pending-patterns-on-a-host-keep-the-block-short ()
  "A path with many directories lists the nearest few of the ones above it
and the two highest, the host's root last: the block does not grow with
the path."
  (require 'harness-ui-pending)
  (harness-test-without-connections
    (cl-flet ((suggestions (pattern) (harness-ui-pending--pattern-suggestions (list :pattern pattern))))
      ;; As many directories above as are listed whole: all of them.
      (should (equal '("/ssh:box:/a/b/c/d/e/**" "/ssh:box:/a/b/c/d/**" "/ssh:box:/a/b/c/**" "/ssh:box:/a/b/**"
                       "/ssh:box:/a/**" "/ssh:box:/**")
                     (suggestions "/ssh:box:/a/b/c/d/e/**")))
      ;; More: the nearest three, then the two highest.
      (should (equal '("/ssh:box:/a/b/c/d/e/f/g/h/**" "/ssh:box:/a/b/c/d/e/f/g/**" "/ssh:box:/a/b/c/d/e/f/**"
                       "/ssh:box:/a/b/c/d/e/**" "/ssh:box:/a/**" "/ssh:box:/**")
                     (suggestions "/ssh:box:/a/b/c/d/e/f/g/h/**")))
      (should (= (+ 1 harness-ui-pending--ancestors-near 2)
                 (length (suggestions "/ssh:box:/a/b/c/d/e/f/g/h/i/j/k/l/**"))))
      (should (equal "/ssh:box:/**"
                     (car (last (suggestions "/ssh:box:/a/b/c/d/e/f/g/h/i/j/k/l/**")))))
      ;; Under a home directory the home and the host close the list.
      (should (equal '("/ssh:box:~/a/b/c/d/e/f/**" "/ssh:box:~/a/b/c/d/e/**" "/ssh:box:~/a/b/c/d/**"
                       "/ssh:box:~/a/b/c/**" "/ssh:box:~/**" "/ssh:box:/**")
                     (suggestions "/ssh:box:~/a/b/c/d/e/f/**"))))))

(ert-deftest harness-ui-pending-patterns-here-are-as-they-were ()
  "A pattern on this machine has the lines it always had: no host to stop
at, and the home directory as `abbreviate-file-name' writes it."
  (require 'harness-ui-pending)
  (let ((home (expand-file-name "~/")))
    (should (equal (mapcar #'abbreviate-file-name
                           (list (concat home "notes/todo.org") (concat home "notes/*.org") (concat home "notes/**")
                                 (concat home "**")))
                   (harness-ui-pending--pattern-choices
                    (list :pattern (concat home "notes/**") :paths (list (concat home "notes/todo.org"))))))
    (should (equal '("/srv/x/" "/srv/x/**" "/srv/**")
                   (harness-ui-pending--pattern-choices (list :pattern "/srv/x/**" :paths '("/srv/x/")))))))

(ert-deftest harness-ui-pending-pattern-place-names-the-whole-places ()
  "A line of the block says when it is a whole home directory or a whole host."
  (require 'harness-ui-pending)
  (harness-test-without-connections
    (dolist (pattern '("/ssh:box:~/**" "/ssh:box:~/" "/ssh:box:~" "/ssh:box:~bob/**"))
      (should (equal "home directory" (harness-ui-pending--pattern-place pattern))))
    (dolist (pattern '("/ssh:box:/**" "/ssh:box:/" "/ssh:box:" "/ssh:u@box#22:/**"))
      (should (equal "whole host" (harness-ui-pending--pattern-place pattern))))
    (dolist (pattern '("/ssh:box:~/src/**" "/ssh:box:~/src/" "/ssh:box:/var/**" "/ssh:box:/etc/hosts"
                       "/ssh:box:~/*.el" "/srv/**" "/" "~/**" "/ssh:box:/*"))
      (should-not (harness-ui-pending--pattern-place pattern)))))

(ert-deftest harness-ui-pending-facts-of-a-call-on-a-host ()
  "The facts of an ssh call say where it runs, and the paths it names
elsewhere on the host; a path in the home directory is named as it is."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session))
          (host harness-ui-pending-test-host))
      (harness-ui-pending-sync
       sid (list (harness-ui-pending-test-ssh-tool-item "home")
                 (harness-ui-pending-test-ssh-tool-item "elsewhere" (list (concat host "/etc/hostname")))
                 (harness-ui-pending-test-ssh-tool-item "inside" (list (concat host "~/notes")))
                 (harness-ui-pending-test-ssh-jail-item "jail")))
      (harness-test-without-connections
        (should (equal (list (format "kind: exec   runs in: %s~/" host))
                       (harness-ui-pending--permission-facts (harness-ui-pending-record sid "home"))))
        (should (equal (list (format "kind: exec   runs in: %s~/" host) (format "paths: %s/etc/hostname" host))
                       (harness-ui-pending--permission-facts (harness-ui-pending-record sid "elsewhere"))))
        (should (equal (list (format "kind: exec   runs in: %s~/" host) (format "paths: %s~/notes" host))
                       (harness-ui-pending--permission-facts (harness-ui-pending-record sid "inside"))))
        ;; The jail's prompt has no command, so no directory it runs in.
        (should (equal (list (format "kind: exec   paths: %s~/" host))
                       (harness-ui-pending--permission-facts (harness-ui-pending-record sid "jail"))))))))

(ert-deftest harness-ui-pending-panel-of-the-first-call-to-a-host ()
  "The jail's prompt for a host's home directory lists, narrowest first, the
home directory, its pattern (the default) and the whole host, each line
saying so when it is a whole place, and the panel is drawn without a
connection."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session))
          (host harness-ui-pending-test-host))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ssh-jail-item)))
      (harness-test-without-connections
        (let ((text (harness-ui-pending-test-rendered sid "ssh-jail")))
          (should (string-search "Permission  Access /ssh:admin@laptop-0#4358:~/ (the login's home directory)" text))
          (should (string-search "   host: admin@laptop-0:4358  command: uptime\n" text))
          (should (string-search (format "   kind: exec   paths: %s~/\n" host) text))
          (should (string-search "(the home directory of the login on admin@laptop-0#4358, where ssh starts)" text))
          (should (string-search
                   (concat "   Answers hold for:\n"
                           (harness-ui-pending-test-step-line nil (concat host "~/") "home directory") "\n"
                           (harness-ui-pending-test-step-line t (concat host "~/**") "default") "\n"
                           (harness-ui-pending-test-step-line nil (concat host "/**") "whole host") "\n"
                           "   [Edit] e  [Narrower] <  [Wider] >\n"
                           "   [Allow] y")
                   text)))
        (should (equal (concat host "~/**") (harness-ui-pending-test-picked sid "ssh-jail")))
        (should (equal (concat host "~/**") (harness-ui-pending--cover-selected (harness-ui-pending-record sid "ssh-jail"))))
        ;; The tooltips name the pattern the answers hold for.
        (let ((help (lambda (option) (harness-ui-pending-answer-help (harness-ui-pending-record sid "ssh-jail") option))))
          (should (equal (format "Let this call reach %s~/**, this time" host) (funcall help "allow-once")))
          (should (equal (format "Allow %s~/** for this session" host) (funcall help "allow-session")))
          (should (equal (format "Always allow %s~/**, in every session" host) (funcall help "allow-always")))
          (should (equal (format "Always deny %s~/**, to every tool" host) (funcall help "deny-always"))))
        ;; The host's root is the widest line: the pick stops there.
        (harness-ui-pending-set-pattern sid "ssh-jail" (concat host "/**"))
        (should (equal (concat host "/**") (harness-ui-pending-test-picked sid "ssh-jail")))
        (should-not (string-search "edited" (harness-ui-pending-test-rendered sid "ssh-jail")))
        (should (equal (format "Always allow %s/**, in every session" host)
                       (harness-ui-pending-answer-help (harness-ui-pending-record sid "ssh-jail") "allow-always")))))))

(ert-deftest harness-ui-pending-keys-widen-a-home-prompt-to-the-host ()
  "> from the default of the home directory's prompt picks the whole host, and
nothing is wider; < goes back, the pattern the answer carries following."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (host harness-ui-pending-test-host)
           (buf (progn (harness-ui-pending-test-record-answers)
                       (harness-ui-pending-sync sid (list (harness-ui-pending-test-ssh-jail-item)))
                       (harness-ui-pending-test-popout-panel sid)))
           (shown nil)
           (press (lambda (key)
                    (setq shown nil)
                    (cl-letf (((symbol-function 'message)
                               (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) shown)))))
                      (call-interactively (key-binding (kbd key))))
                    (car shown))))
      (harness-test-without-connections
        (with-current-buffer buf
          (should (equal (format "Answers now hold for %s/**" host) (funcall press ">")))
          (should (equal (concat host "/**") (plist-get (harness-ui-pending-record sid "ssh-jail") :edited-pattern)))
          (should (equal (format "Already the widest pattern: %s/**" host) (funcall press ">")))
          (should (equal (concat host "/**") (harness-ui-pending-test-picked sid "ssh-jail")))
          (should (equal (format "Answers now hold for %s~/**" host) (funcall press "<")))
          ;; Back on the request's own pattern: no edit.
          (should-not (plist-get (harness-ui-pending-record sid "ssh-jail") :edited-pattern))
          (should (equal (format "Answers now hold for %s~/" host) (funcall press "<")))
          (should (equal (format "Already the narrowest pattern: %s~/" host) (funcall press "<")))
          (funcall press ">")
          (funcall press ">")
          ;; The answer carries the whole host as the pattern it holds for.
          (goto-char (point-min))
          (search-forward "Permission")
          (call-interactively (key-binding (kbd "s")))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer")
      (should (equal (list 'permission sid "ssh-jail" (list :option "allow-session" :pattern (concat host "/**")))
                     (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-clicking-the-whole-host-line-picks-it ()
  "A click on the line of the whole host picks it, and the answer carries it:
the widest answer is one click away from the default, and it is always the
last line."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (host harness-ui-pending-test-host)
           (buf (progn (harness-ui-pending-test-record-answers)
                       (harness-ui-pending-sync sid (list (harness-ui-pending-test-ssh-jail-item)))
                       (harness-ui-pending-test-popout-panel sid))))
      (harness-test-without-connections
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward (concat host "/**"))
          (harness-ui-action-push)
          (should (equal (concat host "/**") (plist-get (harness-ui-pending-record sid "ssh-jail") :edited-pattern)))
          (should (equal "ssh-jail" (get-text-property (point) 'harness-ui-pending-selected)))
          (should (equal (concat host "/**") (harness-ui-pending-test-picked sid "ssh-jail")))
          (goto-char (point-min))
          (search-forward "Permission")
          (call-interactively (key-binding (kbd "a")))))
      (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer")
      (should (equal (list 'permission sid "ssh-jail" (list :option "allow-always" :pattern (concat host "/**")))
                     (car harness-ui-pending-test-answers))))))

(ert-deftest harness-ui-pending-edit-a-pattern-on-a-host ()
  "[Edit] offers the pattern as the text to change and the lines around it
to step through, the host's root among them; what is typed is what the
answers hold for, an empty answer goes back to the request's own, and the
whole thing is done without a connection."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session))
          (host harness-ui-pending-test-host)
          (asked nil))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ssh-jail-item)))
      (harness-test-without-connections
        (cl-flet ((edit (typed)
                    (cl-letf (((symbol-function 'read-string)
                               (lambda (prompt &optional initial _history default &rest _)
                                 (setq asked (list prompt initial default))
                                 typed))
                              ((symbol-function 'message) #'ignore))
                      (let ((harness-ui-session-id sid))
                        (harness-ui-pending-edit-pattern "ssh-jail")))))
          ;; The user steps to the whole host, as M-n offers it.
          (edit (concat host "/**"))
          (should (string-prefix-p "Pattern (" (nth 0 asked)))
          (should (equal (concat host "~/**") (nth 1 asked)))
          (should (equal (list (concat host "~/") (concat host "~/**") (concat host "/**")) (nth 2 asked)))
          (should (equal (concat host "/**") (plist-get (harness-ui-pending-record sid "ssh-jail") :edited-pattern)))
          ;; Typed afresh: a pattern of the user's own, kept as it is, tilde and all.
          (edit (concat host "~/notes/*.org"))
          (should (equal (concat host "/**") (nth 1 asked)))
          (should (equal (concat host "~/notes/*.org")
                         (plist-get (harness-ui-pending-record sid "ssh-jail") :edited-pattern)))
          (should (equal (concat host "~/notes/*.org") (harness-ui-pending-test-picked sid "ssh-jail")))
          (should (string-search (harness-ui-pending-test-step-line t (concat host "~/notes/*.org") "edited")
                                 (harness-ui-pending-test-rendered sid "ssh-jail")))
          ;; Empty: back to the request's own.
          (edit "")
          (should-not (plist-get (harness-ui-pending-record sid "ssh-jail") :edited-pattern))
          (should (equal (concat host "~/**") (harness-ui-pending-test-picked sid "ssh-jail"))))))))

(ert-deftest harness-ui-pending-panel-of-a-call-on-a-host-offers-its-host-first ()
  "The ladder of an ssh call lists the exact call, the programs on its host
\(where the lasting answers start), any command on the host, and then the
programs and the tool for every host, each saying what it leaves free.  The
tooltips say what the pick covers, and the answer carries the pick."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session))
          (host harness-ui-pending-test-host))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ssh-tool-item)))
      (harness-test-without-connections
        (let ((text (harness-ui-pending-test-rendered sid "ssh-tool")))
          (should (string-search (format "   kind: exec   runs in: %s~/\n" host) text))
          (should (string-search
                   (concat "   Lasting answers (s, a, N) cover:\n"
                           (harness-ui-pending-test-step-line nil "every ssh call whose host is exactly \"admin@laptop-0:4358\" and command is exactly \"journalctl -u k3s | tail -50\"") "\n"
                           (harness-ui-pending-test-step-line t "every journalctl and tail call on admin@laptop-0:4358 (any arguments)") "\n"
                           (harness-ui-pending-test-step-line nil "every ssh call on admin@laptop-0:4358 (any command)") "\n"
                           (harness-ui-pending-test-step-line nil "every journalctl and tail call (any host, any arguments)") "\n"
                           (harness-ui-pending-test-step-line nil "every ssh call (any host, any command)") "\n"
                           "   [Narrower] <  [Wider] >")
                   text)))
        (should (equal "host-programs" (harness-ui-pending--cover-id (harness-ui-pending-record sid "ssh-tool"))))
        (let ((help (lambda (option) (harness-ui-pending-answer-help (harness-ui-pending-record sid "ssh-tool") option))))
          (should (equal "Allow every journalctl and tail call on admin@laptop-0:4358 (any arguments) for this session"
                         (funcall help "allow-session")))
          (should (equal "Always allow every journalctl and tail call on admin@laptop-0:4358 (any arguments), in every session"
                         (funcall help "allow-always")))
          (should (equal "Always deny every journalctl and tail call on admin@laptop-0:4358 (any arguments)"
                         (funcall help "deny-always")))
          ;; Wider: any command on this host, then the programs on any host, then the tool.
          (harness-ui-pending-set-cover sid "ssh-tool" "host-tool")
          (should (equal "Always allow every ssh call on admin@laptop-0:4358 (any command), in every session"
                         (funcall help "allow-always")))
          (harness-ui-pending-set-cover sid "ssh-tool" "programs")
          (should (equal "Always allow every journalctl and tail call (any host, any arguments), in every session"
                         (funcall help "allow-always")))
          (harness-ui-pending-set-cover sid "ssh-tool" "tool")
          (should (equal "Always deny every ssh call (any host, any command)" (funcall help "deny-always")))
          (harness-ui-pending-set-cover sid "ssh-tool" "host-tool"))
        ;; The answer carries the cover picked, and Allow and Deny none.
        (harness-ui-pending-answer-permission sid "ssh-tool" "allow-session")
        (harness-test-wait (lambda () harness-ui-pending-test-answers) 5 "the answer")
        (should (equal (list 'permission sid "ssh-tool" '(:option "allow-session" :cover "host-tool"))
                       (car harness-ui-pending-test-answers)))))))

(ert-deftest harness-ui-pending-the-phone-gets-a-default-that-is-no-wider-than-this-host ()
  "A client that knows no ladder (the phone's) answers with no cover, which is
the step the prompt started on: the programs on the host, narrower than the
programs on any host it used to hold for."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-test-record-answers)
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-ssh-tool-item)))
      (let ((r (harness-ui-pending-record sid "ssh-tool")))
        (should (equal "host-programs" (plist-get r :cover)))
        (should (equal "every journalctl and tail call on admin@laptop-0:4358 (any arguments)"
                       (harness-ui-pending--cover-label r)))
        ;; What the answer carries is the cover picked; picking none, the one it started on.
        (should (equal '(:cover "host-programs") (harness-ui-pending--answer-extras r "allow-always")))))))

;;;; A model's summary of the call

(defvar harness-ui-pending-test-changed nil
  "Session ids `harness-ui-pending-changed-hook' was run with, newest first.")

(defun harness-ui-pending-test-hear-changes (sid)
  "Note that the requests of SID changed."
  (push sid harness-ui-pending-test-changed))

(defun harness-ui-pending-test-summary-item (&optional id extra)
  "Return a pending item for a shell call, ID by default \"p1\", with EXTRA in its payload."
  (list :id (or id "p1") :kind "permission"
        :payload (append (list :title "Bash: rm -rf build && make" :tool "bash" :kind "exec"
                               :input '(:command "rm -rf build && make")
                               :reason "The permission judge would deny this call: it deletes files"
                               :options '("allow-once" "deny-once"))
                         extra)))

(ert-deftest harness-ui-pending-panel-says-it-is-summarizing-and-then-shows-the-summary ()
  "A permission request whose call a model summarizes is drawn at once with a
line saying so; the summary takes the line's place when it comes, marked as
a model's, its tooltip saying the model and that it decides nothing.  It
sits under the call and why it is asked, above the answers."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session))
          (harness-ui-pending-test-changed nil))
      (add-hook 'harness-ui-pending-changed-hook #'harness-ui-pending-test-hear-changes)
      (unwind-protect
          (progn
            (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "p1" '(:summarizing t))))
            (let ((text (harness-ui-pending-test-rendered sid "p1")))
              (should (string-search "   Model summary: summarizing…\n" text))
              (should (< (string-search "The permission judge would deny" text)
                         (string-search "Model summary:" text)
                         (string-search "[Allow]" text)))
              ;; Dim, like what is not known yet.
              (with-temp-buffer
                (let ((harness-ui-session-id sid))
                  (harness-ui-pending--insert-permission (harness-ui-pending-record sid "p1")))
                (goto-char (point-min))
                (search-forward "summarizing")
                (should (harness-ui-pending-test-face-p (1- (point)) 'harness-dim-face))))
            ;; The harness says what the model wrote.
            (setq harness-ui-pending-test-changed nil)
            (harness-ui-pending--on-event
             "session/pending-updated"
             (list sid "p1" '(:summary "Deletes the build directory, then rebuilds the project."
                              :summary-model "claude:claude-haiku-4-5" :summarizing nil)))
            (should (equal (list sid) harness-ui-pending-test-changed))
            (let ((text (harness-ui-pending-test-rendered sid "p1")))
              (should (string-search "   Model summary: Deletes the build directory, then rebuilds the project.\n" text))
              (should-not (string-search "summarizing" text))
              (should (< (string-search "The permission judge would deny" text)
                         (string-search "Model summary:" text)
                         (string-search "[Allow]" text))))
            (with-temp-buffer
              (let ((harness-ui-session-id sid))
                (harness-ui-pending--insert-permission (harness-ui-pending-record sid "p1")))
              (goto-char (point-min))
              (search-forward "Deletes the build")
              (should (harness-ui-pending-test-face-p (1- (point)) 'harness-ui-pending-summary-face))
              (let ((help (get-text-property (1- (point)) 'help-echo)))
                (should (string-search "the model claude:claude-haiku-4-5" help))
                (should (string-search "can be wrong" help))
                (should (string-search "decides nothing" help)))
              (goto-char (point-min))
              (search-forward "Model summary:")
              (should (harness-ui-pending-test-face-p (1- (point)) 'harness-dim-face)))
            ;; A request the harness made with the summary in it, the same call asked about before.
            (harness-ui-pending-sync
             sid (list (harness-ui-pending-test-summary-item
                        "p2" '(:summary "Runs make." :summary-model "claude:haiku"))))
            (should (string-search "   Model summary: Runs make.\n" (harness-ui-pending-test-rendered sid "p2"))))
        (remove-hook 'harness-ui-pending-changed-hook #'harness-ui-pending-test-hear-changes)))))

(ert-deftest harness-ui-pending-panel-without-a-summary-is-as-it-was ()
  "A model that gave no summary leaves only the panel it would have been:
the line saying one is on its way goes, and nothing takes its place."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "plain")
                                         (harness-ui-pending-test-summary-item "waits" '(:summarizing t))))
      (let ((plain (harness-ui-pending-test-rendered sid "plain")))
        (should-not (string-search "Model summary" plain))
        (should-not (equal plain (harness-ui-pending-test-rendered sid "waits")))
        (harness-ui-pending--on-event "session/pending-updated" (list sid "waits" '(:summarizing nil)))
        (should (equal plain (harness-ui-pending-test-rendered sid "waits")))
        ;; Over the wire a false is :false, a null nil.
        (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "wire" '(:summarizing t))))
        (should (string-search "summarizing" (harness-ui-pending-test-rendered sid "wire")))
        (harness-ui--dispatch-ui "_harness/event"
                                 (list :event "session/pending-updated"
                                       :args (list sid "wire" '(:summary nil :summarizing :false)))
                                 nil)
        (should (equal plain (harness-ui-pending-test-rendered sid "wire")))))))

(ert-deftest harness-ui-pending-summary-news-for-a-request-not-held-is-no-harm ()
  "An update for a request, a session or a shape this Emacs does not hold
changes nothing and signals nothing; a question has no call to summarize."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session))
          (harness-ui-pending-test-changed nil))
      (harness-ui-pending-test-question sid "q1")
      (add-hook 'harness-ui-pending-changed-hook #'harness-ui-pending-test-hear-changes)
      (unwind-protect
          (progn
            (dolist (args (list (list sid "nope" '(:summary "x"))
                                (list "no-such-session" "p1" '(:summary "x"))
                                (list sid "q1" nil)
                                (list sid nil '(:summary "x"))
                                (list sid "q1" '(:summary "x"))
                                nil))
              (should-not (harness-ui-pending--on-event "session/pending-updated" args)))
            (should-not (harness-ui-pending--on-event "session/pending-changed" (list sid "q1" '(:summary "x"))))
            ;; Nothing else about the request moved with the unknown ones.
            (should (equal '("q1") (mapcar (lambda (r) (plist-get r :id)) (harness-ui-pending-items sid)))))
        (remove-hook 'harness-ui-pending-changed-hook #'harness-ui-pending-test-hear-changes)))))

(ert-deftest harness-ui-pending-the-session-list-only-teaches-forwards ()
  "The session's list lags the news of a request: a push made before the
summary came does not take it back, and does not make a request wait for
one it has none of.  A list that has the summary teaches it, and one that
says there is none takes the placeholder off."
  (harness-ui-pending-test-with
    (let ((sid (harness-ui-pending-test-session)))
      ;; The request waits for a summary; the list, later, has it.
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "a" '(:summarizing t))))
      (should (harness-ui-pending-sync
               sid (list (harness-ui-pending-test-summary-item "a" '(:summary "Runs make." :summary-model "m")))))
      (should (equal "Runs make." (plist-get (harness-ui-pending-record sid "a") :summary)))
      (should-not (plist-get (harness-ui-pending-record sid "a") :summarizing))
      ;; A push made before it came is not the last word.
      (should-not (harness-ui-pending-sync
                   sid (list (harness-ui-pending-test-summary-item "a" '(:summarizing t)))))
      (should (equal "Runs make." (plist-get (harness-ui-pending-record sid "a") :summary)))
      (should-not (plist-get (harness-ui-pending-record sid "a") :summarizing))
      ;; Nor does a request that waits for none start to.
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "b")))
      (should-not (harness-ui-pending-sync
                   sid (list (harness-ui-pending-test-summary-item "b" '(:summarizing t)))))
      (should-not (plist-get (harness-ui-pending-record sid "b") :summarizing))
      ;; A list that says there is none takes the placeholder off.
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "c" '(:summarizing t))))
      (should (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "c"))))
      (should-not (plist-get (harness-ui-pending-record sid "c") :summarizing))
      (should-not (plist-get (harness-ui-pending-record sid "c") :summary))
      ;; The news of the request, made before it was summarized, loses nothing either.
      (harness-ui-pending-add sid (list :id "a" :kind "permission" :tool "bash" :summarizing t))
      (should (equal "Runs make." (plist-get (harness-ui-pending-record sid "a") :summary)))
      (should-not (plist-get (harness-ui-pending-record sid "a") :summarizing)))))

(ert-deftest harness-ui-pending-acp-request-brings-its-summary-state ()
  "A request the harness asks over ACP says whether a summary is on its way,
or carries the one written; an update over the wire then reaches it, the
request holding the function that answers it all the while."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session))
           (answers nil)
           (respond (lambda (r) (push r answers) t))
           (drawn (list sid))
           (drawn-p (lambda (session-id) (member session-id drawn))))
      (add-hook 'harness-ui-pending-drawn-predicates drawn-p)
      (unwind-protect
          (progn
            (should (harness-ui-pending--on-permission
                     (list :sessionId sid
                           :toolCall (list :toolCallId "c1" :title "Bash: make" :kind "execute")
                           :_harness (list :pendingId "p1" :tool "bash" :summarizing t))
                     respond))
            (let ((r (harness-ui-pending-record sid "p1")))
              (should (eq t (plist-get r :summarizing)))
              (should-not (plist-get r :summary)))
            (should (string-search "summarizing" (harness-ui-pending-test-rendered sid "p1")))
            (harness-ui--dispatch-ui "_harness/event"
                                     (list :event "session/pending-updated"
                                           :args (list sid "p1" '(:summary "Runs make." :summary-model "claude:haiku"
                                                                  :summarizing nil)))
                                     nil)
            (let ((r (harness-ui-pending-record sid "p1")))
              (should (equal "Runs make." (plist-get r :summary)))
              (should (equal "claude:haiku" (plist-get r :summary-model)))
              (should-not (plist-get r :summarizing))
              (should (eq respond (plist-get r :respond))))
            ;; A request that came with its summary.
            (should (harness-ui-pending--on-permission
                     (list :sessionId sid
                           :toolCall (list :toolCallId "c2" :title "Bash: make" :kind "execute")
                           :_harness (list :pendingId "p2" :tool "bash" :summary "Runs make."
                                           :summaryModel "claude:haiku"))
                     respond))
            (let ((r (harness-ui-pending-record sid "p2")))
              (should (equal "Runs make." (plist-get r :summary)))
              (should (equal "claude:haiku" (plist-get r :summary-model)))
              (should-not (plist-get r :summarizing)))
            (harness-ui-pending-answer-permission sid "p1" "allow-once")
            (should (equal '((:outcome (:outcome "selected" :optionId "allow-once"))) answers)))
        (remove-hook 'harness-ui-pending-drawn-predicates drawn-p)))))

(ert-deftest harness-ui-pending-popout-follows-the-summary ()
  "The popout of a request redraws when its summary comes, as the chat's tail
does: both are drawn from the one store."
  (harness-ui-pending-test-with
    (let* ((sid (harness-ui-pending-test-session "Asker"))
           (key (list 'pending sid)))
      (harness-ui-pending-sync sid (list (harness-ui-pending-test-summary-item "p1" '(:summarizing t))))
      (harness-ui-pending-popout sid)
      (let ((buf (harness-ui-popout-buffer key)))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (string-search "Model summary: summarizing…" (buffer-string)))
          (should-not (string-search "Deletes the build" (buffer-string))))
        (harness-ui-pending--on-event
         "session/pending-updated"
         (list sid "p1" '(:summary "Deletes the build directory." :summary-model "m" :summarizing nil)))
        (harness-test-wait (lambda () (with-current-buffer buf (string-search "Deletes the build" (buffer-string))))
                           5 "the popout to show the summary")
        (with-current-buffer buf
          (should (string-search "Model summary: Deletes the build directory." (buffer-string)))
          (should-not (string-search "summarizing" (buffer-string))))))))

(provide 'harness-ui-pending-test)
;;; harness-ui-pending-test.el ends here
