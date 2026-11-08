;;; harness-ui-todo-sync-test.el --- Tests for /todos, the UI half of todo-sync  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-todo-sync' and /todos: what the words after it name, what the
;; echo area says of a request and of how a session stands, and syncing a
;; session's todo list from a chat's message box against the real state
;; layer, the demo provider and the in-process ACP connection.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-todo-sync)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-default-position)
(defvar harness-chat--loading)
(defvar harness-chat--buffers)
(defvar harness-chat--todos)
(defvar harness-chat-commands)
(defvar harness-compose-end)
(defvar harness-compose--skills)
(defvar harness-compose-commands)
(defvar harness-todo-sync-steps)
(defvar harness-todo-sync-model)
(defvar harness-todo-sync--steps)
(defvar harness-todo-sync--phase)
(defvar harness-todo-sync--last-node)
(defvar harness-todo-sync--anchor)
(defvar harness-todo-sync--counted)
(defvar harness-todo-sync--running)
(defvar harness-todo-sync--failed)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-send "harness-ui-chat")
(declare-function harness-chat--command "harness-ui-chat")
(declare-function harness-chat--clear-compose "harness-ui-chat")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-completion-at-point "harness-ui-compose")
(declare-function harness-acp--drop-client "harness-acp")

;;;; The words and what is said

(ert-deftest harness-ui-todo-sync-reads-the-words-after-the-command ()
  "Nothing or `now' syncs the list; on, off, default and status are the rest."
  (should (eq 'now (harness-ui-todo-sync-parse-action "")))
  (should (eq 'now (harness-ui-todo-sync-parse-action nil)))
  (should (eq 'now (harness-ui-todo-sync-parse-action "  now ")))
  (should (eq 'now (harness-ui-todo-sync-parse-action "sync")))
  (should (eq 'on (harness-ui-todo-sync-parse-action "on")))
  (should (eq 'off (harness-ui-todo-sync-parse-action " OFF ")))
  (should (eq 'default (harness-ui-todo-sync-parse-action "default")))
  (should (eq 'status (harness-ui-todo-sync-parse-action "status")))
  (let ((err (should-error (harness-ui-todo-sync-parse-action "sideways") :type 'user-error)))
    (should (string-match-p "now, on, off, default, status" (error-message-string err)))))

(ert-deftest harness-ui-todo-sync-says-what-came-of-a-request ()
  (let ((todos '((:id "t1" :text "Read" :status "done") (:id "t2" :text "Edit" :status "in-progress")
                 (:id "t3" :text "Test" :status "pending"))))
    (should (equal "Todo list written: 3 items, 1 done"
                   (harness-ui-todo-sync-said-run (list :status "updated" :todos todos))))
    (should (equal "Todo list written: 1 item, 0 done"
                   (harness-ui-todo-sync-said-run (list :status "updated" :todos (list (nth 1 todos))))))
    (should (string-match-p "right as it stands"
                            (harness-ui-todo-sync-said-run '(:status "unchanged"))))
    (should (string-match-p "too small"
                            (harness-ui-todo-sync-said-run '(:status "none"))))
    (should (string-match-p "wrote its own todo list meanwhile"
                            (harness-ui-todo-sync-said-run '(:status "stale"))))
    (should (string-match-p "deleted"
                            (harness-ui-todo-sync-said-run '(:status "gone"))))
    (should (equal "Todo sync: other"
                   (harness-ui-todo-sync-said-run '(:status "other"))))))

(ert-deftest harness-ui-todo-sync-says-how-a-session-stands ()
  (should (string-match-p
           "not synced for this session"
           (harness-ui-todo-sync-said-state '(:setting "off" :every nil :steps 0 :model "demo:scripted"))))
  (should (string-match-p
           "harness-todo-sync-steps is nil; /todos on"
           (harness-ui-todo-sync-said-state '(:setting "default" :every nil :steps 0 :model "demo:scripted"))))
  (let ((said (harness-ui-todo-sync-said-state
               '(:setting "default" :every 6 :steps 2 :running nil :own :false :model "demo:scripted"))))
    (should (string-prefix-p "The todo list is synced every 6 steps, 2 since it was last updated, by " said))
    (should (string-match-p (regexp-quote (harness-ui-model-label "demo:scripted")) said))
    (should-not (string-match-p "set for this session" said))
    (should-not (string-match-p "under way" said)))
  (let ((said (harness-ui-todo-sync-said-state
               '(:setting "on" :every 6 :steps 0 :running t :own t :model "demo:scripted"))))
    (should (string-match-p "every 6 steps (set for this session)" said))
    (should (string-match-p "by the session's own model, on a fork of it" said))
    (should (string-suffix-p "; a request is under way" said)))
  (should (string-match-p "synced every step, 0 since"
                          (harness-ui-todo-sync-said-state
                           '(:setting "default" :every 1 :steps 0 :running nil :own :false :model "demo:scripted")))))

;;;; In a chat

(defconst harness-ui-todo-sync-test--answer
  '((:type text :delta "[x] Read the code\n[~] Edit it\n[ ] Run the tests")
    (:type usage :input 300 :output 30 :cost 0.0002)
    (:type done :stop-reason end-turn))
  "The list the demo provider writes.")

(defmacro harness-ui-todo-sync-test-with (&rest body)
  "Load the state layer with todo-sync, the demo provider and the chat, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent todo-sync acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (dolist (table (list harness-todo-sync--steps harness-todo-sync--phase harness-todo-sync--last-node
                          harness-todo-sync--anchor harness-todo-sync--counted harness-todo-sync--running
                          harness-todo-sync--failed))
       (clrhash table))
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-ui-todo-sync-test--answer)
           (harness-todo-sync-steps 6)
           (harness-todo-sync-model "demo:scripted")
           (harness-naming-auto nil)
           (harness-acp-token nil)
           (harness-ui-default-position 'full)
           (default-directory dir))
       (dolist (m '(ui ui-compose ui-markdown ui-chat ui-todo-sync))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-todo-sync-test--session ()
  "Create a demo session with a conversation of ten messages; return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                                      :name "Todo sync test")
                        :id)))
    (dotimes (i 10)
      (harness-call 'session/append sid (list :kind (if (cl-evenp i) 'user 'assistant)
                                              :content (format "message %d about the parser" i))))
    sid))

(defun harness-ui-todo-sync-test--open (sid)
  "Open SID's chat buffer and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (harness-test-wait (lambda () (with-current-buffer buffer
                                    (and (not harness-chat--loading) harness-compose-end)))
                       5 "the session to load")
    buffer))

(defun harness-ui-todo-sync-test--send (buffer text)
  "Type TEXT in BUFFER's message box and send it."
  (with-current-buffer buffer
    (goto-char harness-compose-end)
    (insert text)
    (harness-chat-send)))

(defun harness-ui-todo-sync-test--todos (sid)
  "Return the todo list of session SID."
  (plist-get (harness-call 'session/get sid) :todos))

(defun harness-ui-todo-sync-test--switch (sid)
  "Return the own switch of session SID: `:false', t, or `unset'."
  (let ((ext (plist-get (harness-call 'session/get sid) :ext)))
    (if (plist-member ext :todo-sync) (plist-get ext :todo-sync) 'unset)))

(defun harness-ui-todo-sync-test--shows (buffer text)
  "Non-nil when BUFFER shows TEXT."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (search-forward text nil t)))))

(defmacro harness-ui-todo-sync-test-messages (var &rest body)
  "Run BODY with what it says in the echo area pushed on the list VAR."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) ,var)) nil)))
       ,@body)))

(ert-deftest harness-ui-todo-sync-slash-command-writes-the-list ()
  "Typing /todos in a chat writes the todo list instead of sending a message.
No turn runs, the box empties, and the panel above the box shows the list."
  (harness-ui-todo-sync-test-with
    (let* ((sid (harness-ui-todo-sync-test--session))
           (buffer (harness-ui-todo-sync-test--open sid))
           (nodes (length (harness-call 'session/nodes sid))))
      (harness-ui-todo-sync-test-messages said
        (harness-ui-todo-sync-test--send buffer "/todos")
        (harness-test-wait (lambda () (harness-ui-todo-sync-test--todos sid)) 5 "the list")
        (harness-test-wait (lambda () (member "Todo list written: 3 items, 1 done" said)) 5
                           "the echo area to say so"))
      (should (equal '("Read the code" "Edit it" "Run the tests")
                     (mapcar (lambda (todo) (plist-get todo :text)) (harness-ui-todo-sync-test--todos sid))))
      (with-current-buffer buffer (should (equal "" (harness-compose-text))))
      (harness-test-wait (lambda () (harness-ui-todo-sync-test--shows buffer "Edit it")) 5
                         "the list in the chat")
      ;; Nothing went to the session: no message, no turn.
      (should (= nodes (length (harness-call 'session/nodes sid))))
      (should (member (plist-get (plist-get (harness-call 'session/get sid) :usage) :turns) '(nil 0)))
      ;; Asked again, with the list as it is: the demo moves it on a step.
      (let ((harness-provider-demo-script-override nil))
        (harness-ui-todo-sync-test-messages said
          (harness-ui-todo-sync-test--send buffer "/todos now")
          (harness-test-wait (lambda () (member "Todo list written: 3 items, 2 done" said)) 10
                             "the list to move on"))))))

(ert-deftest harness-ui-todo-sync-slash-command-switches-a-session ()
  "The words on, off and default set the session's own switch and say how it stands.
/todos status only says."
  (harness-ui-todo-sync-test-with
    (let* ((sid (harness-ui-todo-sync-test--session))
           (buffer (harness-ui-todo-sync-test--open sid)))
      (should (eq 'unset (harness-ui-todo-sync-test--switch sid)))
      (harness-ui-todo-sync-test-messages said
        (harness-ui-todo-sync-test--send buffer "/todos off")
        (harness-test-wait (lambda () (eq :false (harness-ui-todo-sync-test--switch sid))) 5 "the switch")
        (harness-test-wait (lambda () (cl-some (lambda (s) (string-match-p "not synced for this session" s)) said))
                           5 "it to say so"))
      (with-current-buffer buffer (should (equal "" (harness-compose-text))))
      (harness-ui-todo-sync-test-messages said
        (harness-ui-todo-sync-test--send buffer "/todos on")
        (harness-test-wait (lambda () (eq t (harness-ui-todo-sync-test--switch sid))) 5 "the switch")
        (harness-test-wait (lambda () (cl-some (lambda (s) (string-match-p "(set for this session)" s)) said))
                           5 "it to say so"))
      (harness-ui-todo-sync-test-messages said
        (harness-ui-todo-sync-test--send buffer "/todos default")
        (harness-test-wait (lambda () (eq 'unset (harness-ui-todo-sync-test--switch sid))) 5 "the switch")
        (harness-test-wait (lambda () (cl-some (lambda (s) (string-match-p "synced every 6 steps," s)) said))
                           5 "it to say so"))
      ;; Status changes nothing.
      (harness-ui-todo-sync-test-messages said
        (harness-ui-todo-sync-test--send buffer "/todos status")
        (harness-test-wait (lambda () (cl-some (lambda (s) (string-match-p "synced every 6 steps," s)) said))
                           5 "the status"))
      (should (eq 'unset (harness-ui-todo-sync-test--switch sid)))
      (should-not (harness-ui-todo-sync-test--todos sid))
      ;; A word that is none keeps the box as typed.
      (with-current-buffer buffer
        (goto-char harness-compose-end)
        (insert "/todos sideways")
        (should-error (harness-chat-send) :type 'user-error)
        (should (equal "/todos sideways" (harness-compose-text)))
        (harness-chat--clear-compose)))))

(ert-deftest harness-ui-todo-sync-slash-command-says-when-the-sync-fails ()
  "A request the model could not answer is reported, not swallowed."
  (harness-ui-todo-sync-test-with
    (let* ((sid (harness-ui-todo-sync-test--session))
           (buffer (harness-ui-todo-sync-test--open sid))
           (harness-provider-demo-script-override
            '((:type text :delta "I would rather not.") (:type done :stop-reason end-turn))))
      (harness-ui-todo-sync-test-messages said
        (harness-ui-todo-sync-test--send buffer "/todos")
        (harness-test-wait (lambda () (cl-some (lambda (s) (string-match-p "^The todo list failed: " s)) said))
                           5 "the failure"))
      (should-not (harness-ui-todo-sync-test--todos sid)))))

(ert-deftest harness-ui-todo-sync-slash-command-is-the-whole-message ()
  "Only a message that is /todos, maybe with a word after it, is the command.
A longer message, another word starting the same, or a skill called todos
goes to the session as usual.  / completion offers it."
  (harness-ui-todo-sync-test-with
    (let* ((sid (harness-ui-todo-sync-test--session))
           (buffer (harness-ui-todo-sync-test--open sid)))
      (with-current-buffer buffer
        (should (equal (cons #'harness-ui-todo-sync--chat-command "")
                       (harness-chat--command "/todos")))
        (should (equal (cons #'harness-ui-todo-sync--chat-command "status")
                       (harness-chat--command "/todos  status")))
        (should-not (harness-chat--command "/todos-later"))
        (should-not (harness-chat--command "please /todos"))
        (should-not (harness-chat--command "/todos\nand then fix the parser"))
        (should (member "todos" harness-compose-commands))
        (goto-char harness-compose-end)
        (insert "/tod")
        (should (member "todos" (all-completions "tod" (nth 2 (harness-compose-completion-at-point)))))
        (harness-chat--clear-compose)
        ;; A skill of that name wins.
        (let ((harness-compose--skills '("todos")))
          (should-not (harness-chat--command "/todos")))))))

(ert-deftest harness-ui-todo-sync-leaves-the-chat-when-it-shuts-down ()
  (harness-ui-todo-sync-test-with
    (should (eq #'harness-ui-todo-sync--chat-command (cdr (assoc "todos" harness-chat-commands))))
    (harness-ui-todo-sync--shutdown)
    (should-not (assoc "todos" harness-chat-commands))
    (harness-ui-todo-sync--init)
    (should (eq #'harness-ui-todo-sync--chat-command (cdr (assoc "todos" harness-chat-commands))))
    ;; A command of another module under the same name is left alone.
    (setf (alist-get "todos" harness-chat-commands nil nil #'equal) #'ignore)
    (harness-ui-todo-sync--shutdown)
    (should (eq #'ignore (cdr (assoc "todos" harness-chat-commands))))))

(provide 'harness-ui-todo-sync-test)
;;; harness-ui-todo-sync-test.el ends here
