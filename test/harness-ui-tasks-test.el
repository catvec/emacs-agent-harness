;;; harness-ui-tasks-test.el --- Tests for the task board  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the task board against the real state layer, the demo
;; provider and the in-process ACP connection: loading, submitting from
;; the compose box, the columns, editing a pending task, the compose box
;; surviving redraws, and the keys on a card.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-ui-default-position)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--tasks)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-tasks--target)
(defvar harness-ui-tasks--list-end)
(defvar harness-ui-tasks--error)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks-edit "harness-ui-tasks")
(declare-function harness-ui-tasks--header "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
(declare-function harness-ui-tasks-toggle-subtitle "harness-ui-tasks")
(declare-function harness-ui-tasks-tab "harness-ui-tasks")
(declare-function harness-acp--drop-client "harness-acp")

(defmacro harness-ui-tasks-test-with (&rest body)
  "Load the state layer, tasks, ACP and the board UI; run BODY with `board' open.
Finished tasks are completed at once, without review, unless BODY turns
`harness-tasks-require-verification' on."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (setq harness-tasks--loaded t harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override
            '((:type text :delta "Working on it.") (:type done :stop-reason end-turn)))
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification nil)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           ;; Full width: the content checks below are not about narrow windows.
           (harness-ui-default-position (quote full))
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-tasks)
       (clrhash harness-ui--sessions)
       (let ((board (harness-tasks dir)))
         (unwind-protect
             (progn
               (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                                  5 "the board to load")
               ,@body)
           (kill-buffer board)
           (dolist (c (copy-sequence harness-acp--clients))
             (harness-acp--drop-client c)))))))

(defun harness-ui-tasks-test--type-and-submit (board text)
  "Type TEXT into BOARD's compose box and submit it."
  (with-current-buffer board
    (goto-char harness-compose-end)
    (insert text)
    (harness-ui-tasks-submit)))

(defun harness-ui-tasks-test--board-text (board)
  "The board region of BOARD as plain text."
  (with-current-buffer board
    (buffer-substring-no-properties (point-min) harness-ui-tasks--list-end)))

(defun harness-ui-tasks-test--wait-text (board regexp)
  "Wait until BOARD's board region matches REGEXP."
  (harness-test-wait (lambda () (with-current-buffer board
                                  (harness-ui-tasks--render)
                                  (string-match-p regexp (harness-ui-tasks-test--board-text board))))
                     5 (format "the board to show %s" regexp)))

(ert-deftest harness-ui-tasks-empty-board ()
  (harness-ui-tasks-test-with
    (should (string-match-p "No tasks yet" (harness-ui-tasks-test--board-text board)))
    (with-current-buffer board
      (should (= harness-compose-start harness-compose-end))
      (should (string-match-p "Tasks" (harness-ui-tasks--header)))
      (should-not (buffer-modified-p)))))

(ert-deftest harness-ui-tasks-submit-runs-to-completed ()
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--type-and-submit board "Fix the flaky test")
    (with-current-buffer board
      (should (string-empty-p (buffer-substring-no-properties harness-compose-start
                                                              harness-compose-end))))
    (harness-ui-tasks-test--wait-text board "Completed  1\\(.\\|\n\\)*Fix the flaky test")
    (should (string-match-p "✓ 1\\|done 1" (with-current-buffer board (harness-ui-tasks--header most-positive-fixnum))))))

(ert-deftest harness-ui-tasks-compose-survives-redraws ()
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (goto-char harness-compose-end)
      (insert "half typed")
      (let ((offset (- (point) harness-compose-start)))
        (harness-ui-tasks--render)
        (harness-ui-tasks--render)
        (should (equal "half typed" (buffer-substring-no-properties harness-compose-start
                                                                   harness-compose-end)))
        (should (= offset (- (point) harness-compose-start)))))))

(ert-deftest harness-ui-tasks-edit-pending ()
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "First draft")
      (harness-ui-tasks-test--wait-text board "Pending  1")
      (with-current-buffer board
        (goto-char (point-min))
        (search-forward "First draft")
        (harness-ui-tasks-edit)
        (should (eq 'edit (car harness-ui-tasks--target)))
        (should (equal "First draft" (buffer-substring-no-properties harness-compose-start
                                                                     harness-compose-end)))
        (delete-region harness-compose-start harness-compose-end)
        (goto-char harness-compose-start)
        (insert "Second draft")
        (harness-ui-tasks-submit)
        (should-not harness-ui-tasks--target))
      (harness-test-wait (lambda () (equal "Second draft"
                                           (plist-get (car (harness-call 'task/list default-directory)) :prompt)))
                         5 "the prompt to change"))))

(ert-deftest harness-ui-tasks-in-progress-newest-first ()
  "A task that starts shows at the top of In progress, above older ones."
  (harness-ui-tasks-test-with
    ;; A turn that never ends keeps both tasks in progress.
    (let ((harness-provider-demo-script-override '((:type text :delta "Working on it."))))
      (unwind-protect
          (progn
            (harness-ui-tasks-test--type-and-submit board "Older task")
            (harness-ui-tasks-test--wait-text board "In progress  1\\(.\\|\n\\)*Older task")
            (harness-ui-tasks-test--type-and-submit board "Newer task")
            (harness-ui-tasks-test--wait-text board "In progress  2\n.*Newer task\\(.\\|\n\\)*Older task"))
        (dolist (task (harness-call 'task/list default-directory))
          (harness-call 'task/cancel (plist-get task :id)))))))

(ert-deftest harness-ui-tasks-stopped-task-needs-input ()
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (harness-ui-tasks-test--type-and-submit board "Break things")
      (harness-ui-tasks-test--wait-text board "Requires your input  1\\(.\\|\n\\)*stopped: error")
      (should (string-match-p "1 need you" (with-current-buffer board (harness-ui-tasks--header)))))))

(ert-deftest harness-ui-tasks-paused-mark-lines-up-with-the-square ()
  "A wide pause mark centres on the square's column, its text in line.
On a graphical frame the blocked mark is an image about a column wider
than the stopped square, with its ink centred: the card moves it half
that extra width left and pads the same width after it, so the two marks
share a centre and the title keeps its column.  Terminals draw the pause
as a one-column symbol, already in line, so they keep the old layout."
  (harness-ui-tasks-test-with
    (let* ((image (propertize "x" 'display '(image :type svg :file "blocked.svg")))
           (session (list :id "s1" :name "Fix the parser" :pending '((:kind "permission"))))
           (task (list :id "t1" :session "s1" :prompt "Fix the parser" :started 0)))
      (puthash "s1" session harness-ui--sessions)
      (cl-letf (((symbol-function 'harness-ui-tasks--width) (lambda () 96)))
        ;; A 21px image in an 11px column is nudged by half the 10px extra.
        (cl-letf (((symbol-function 'string-pixel-width) (lambda (&rest _) 21))
                  ((symbol-function 'frame-char-width) (lambda (&optional _) 11)))
          (should (= 5 (harness-ui-tasks--mark-nudge image))))
        (cl-letf (((symbol-function 'harness-ui-tasks--icon) (lambda (&rest _) image))
                  ((symbol-function 'harness-ui-tasks--mark-nudge) (lambda (&rest _) 5))
                  ((symbol-function 'frame-char-width) (lambda (&optional _) 11)))
          (with-temp-buffer
            (harness-ui-tasks--insert-card task 'needs-input nil)
            ;; The chevron comes first; then a column less nudge before
            ;; the mark, and a column plus the same nudge after it.
            (should (equal '(space :width (6)) (get-text-property (+ (point-min) 3) 'display)))
            (should (equal '(space :width (16)) (get-text-property (+ (point-min) 5) 'display)))))
        ;; A one-column symbol, as a terminal draws it, is left alone.
        (cl-letf (((symbol-function 'harness-ui-tasks--icon) (lambda (&rest _) "x")))
          (with-temp-buffer
            (harness-ui-tasks--insert-card task 'needs-input nil)
            (should-not (get-text-property (+ (point-min) 3) 'display))
            (should-not (get-text-property (+ (point-min) 5) 'display))))))))

(ert-deftest harness-ui-tasks-card-keys ()
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "Waiting task")
      (harness-ui-tasks-test--wait-text board "Waiting task")
      (with-current-buffer board
        (goto-char (point-min))
        (search-forward "Waiting task")
        (should (eq 'harness-ui-tasks-start (key-binding (kbd "s"))))
        (should (eq 'harness-ui-tasks-open (key-binding (kbd "RET"))))
        (should (eq 'harness-ui-tasks-merge (key-binding (kbd "M"))))
        ;; The compose box types letters instead.
        (goto-char harness-compose-end)
        (should (eq 'self-insert-command (key-binding (kbd "s"))))
        (should (eq 'harness-ui-tasks-submit (key-binding (kbd "C-c C-c"))))))))

(defvar harness-ui-open-session-function)
(declare-function harness-ui-display-buffer "harness-ui")
(declare-function harness-ui-tasks-open "harness-ui-tasks")

(ert-deftest harness-ui-tasks-shares-session-positions ()
  "The board and sessions replace each other in the same position."
  (harness-ui-tasks-test-with
    (let* ((session-buf (get-buffer-create " *fake session*"))
           (harness-ui-open-session-function (lambda (_id) session-buf)))
      (unwind-protect
          (let ((window (get-buffer-window board)))
            (should (eq harness-ui-default-position (buffer-local-value 'harness-ui-position board)))
            (should window)
            ;; A session shown in the board's position takes its window.
            (harness-ui-display-buffer session-buf harness-ui-default-position)
            (should (eq session-buf (window-buffer window)))
            (should-not (get-buffer-window board))
            ;; Opening the board again puts it back in that window.
            (harness-tasks default-directory)
            (should (eq board (window-buffer window)))
            ;; Opening a task's session from the board replaces the board.
            (harness-ui-tasks-test--type-and-submit board "Open me")
            (harness-ui-tasks-test--wait-text board "Completed  1")
            (with-selected-window window
              (goto-char (point-min))
              (search-forward "Open me")
              (harness-ui-tasks-open))
            (harness-test-wait (lambda () (eq session-buf (window-buffer window))) 5 "the session to replace the board")
            (should-not (get-buffer-window board)))
        (kill-buffer session-buf)))))

(defvar harness-ui-session-id)

(ert-deftest harness-ui-tasks-back-from-a-tasks-session ()
  "The board's key in a task's session goes back to the board the task is on.
Whatever the session's directory: one the board's project cannot be
told from, like a worktree git lost track of, still leads back."
  (harness-ui-tasks-test-with
    (let* ((elsewhere (harness-test-temp-dir))
           (session-buf nil)
           (harness-ui-open-session-function
            (lambda (id)
              ;; What a chat buffer is: its session, in the session's directory.
              (setq session-buf (get-buffer-create " *a task's session*"))
              (with-current-buffer session-buf
                (setq harness-ui-session-id id
                      default-directory elsewhere))
              session-buf)))
      (unwind-protect
          (let ((window (get-buffer-window board)))
            (harness-ui-tasks-test--type-and-submit board "Come back to me")
            (harness-ui-tasks-test--wait-text board "Completed  1")
            (with-selected-window window
              (goto-char (point-min))
              (search-forward "Come back to me")
              (harness-ui-tasks-open))
            (harness-test-wait (lambda () (eq session-buf (window-buffer window))) 5 "the session to replace the board")
            (with-selected-window window
              (with-current-buffer session-buf
                (should (eq board (call-interactively #'harness-tasks)))))
            (should (eq board (window-buffer window)))
            ;; Without a task's session the directory picks the board.
            (with-temp-buffer
              (setq default-directory elsewhere)
              (let ((other (call-interactively #'harness-tasks)))
                (unwind-protect
                    (progn (should-not (eq board other))
                           (should (equal elsewhere (buffer-local-value 'default-directory other))))
                  (kill-buffer other)))))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))))))

(defvar harness-compose-attachments)
(defvar harness-compose--files)
(declare-function harness-compose-completion-at-point "harness-ui-compose")
(declare-function harness-compose-add-attachment "harness-ui-compose")
(declare-function harness-compose-fetch-completions "harness-ui-compose")

(ert-deftest harness-ui-tasks-compose-is-the-chat-box ()
  "The board's compose box completes @files, newlines on RET and attaches."
  (harness-ui-tasks-test-with
    ;; Only projects are listed for @ completion, so this board is for a repository.
    (let* ((repo (harness-test-temp-dir))
           (file (expand-file-name "notes.txt" repo))
           (default-directory repo))
      (call-process "git" nil nil nil "init" "-q")
      (with-temp-file file (insert "notes\n"))
      (setq board (harness-tasks repo))
      (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board))) 5 "the board")
      (with-current-buffer board
        (goto-char harness-compose-end)
        (should (eq 'harness-compose-newline (key-binding (kbd "RET"))))
        (should (eq 'harness-compose-add-attachment (key-binding (kbd "C-c C-a"))))
        ;; @file completion offers the project's files.
        (setq harness-compose--files nil)
        (harness-compose-fetch-completions)
        (harness-test-wait (lambda () harness-compose--files) 5 "files fetched")
        (insert "Summarise @no")
        (let ((capf (harness-compose-completion-at-point)))
          (should capf)
          (should (member "notes.txt" (all-completions "no" (nth 2 capf)))))
        (delete-region harness-compose-start harness-compose-end)
        ;; An attachment travels with the submitted task.
        (insert "Summarise the notes")
        (harness-compose-add-attachment file)
        (should (= 1 (length harness-compose-attachments)))
        (harness-ui-tasks-submit)
        (should-not harness-compose-attachments))
      (harness-test-wait (lambda () (let ((task (car (harness-call 'task/list default-directory))))
                                      (and task (plist-get task :session)
                                           (eq 'done (plist-get task :state)))))
                         5 "the task to finish")
      (let* ((task (car (harness-call 'task/list default-directory)))
             (user (cl-find 'user (harness-call 'session/nodes (plist-get task :session))
                            :key (lambda (n) (plist-get n :kind)))))
        (should (equal file (plist-get (car (plist-get task :attachments)) :path)))
        (should (cl-some (lambda (b) (equal (plist-get b :path) file)) (plist-get user :blocks)))))))

(defvar harness-ui-tasks--new)
(declare-function harness-toggle-non-interactive "harness-ui")
(declare-function harness-set-permission-mode "harness-ui")
(declare-function harness-ui--setting-target "harness-ui")

(ert-deftest harness-ui-tasks-session-settings ()
  "The session setting commands set up new tasks from the box and change a task's session on its card."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (harness-test-wait (lambda () harness-ui-tasks--new) 5 "the defaults")
      (should (equal "auto" (format "%s" (plist-get harness-ui-tasks--new :permission-mode))))
      ;; Nothing configures it here, so new tasks start interactive.
      (should-not (plist-get harness-ui-tasks--new :non-interactive))
      (goto-char harness-compose-end)
      ;; The ordinary commands change the settings of the next task.
      (should (consp (harness-ui--setting-target nil)))
      (harness-toggle-non-interactive)
      (should (eq t (plist-get harness-ui-tasks--new :non-interactive)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Ask")))
        (harness-set-permission-mode))
      (should (equal "ask" (plist-get harness-ui-tasks--new :permission-mode)))
      (insert "Configured task")
      (harness-ui-tasks-submit))
    (harness-ui-tasks-test--wait-text board "Completed  1")
    (let* ((task (car (harness-call 'task/list default-directory)))
           (sid (plist-get task :session))
           (session (harness-call 'session/get sid)))
      (should (eq 'ask (plist-get session :permission-mode)))
      (should (plist-get session :non-interactive))
      ;; On a started task's card the same commands change its session.
      (with-current-buffer board
        (goto-char (point-min))
        (search-forward "Configured task")
        (should (equal sid (harness-ui--setting-target nil)))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "YOLO")))
          (harness-set-permission-mode)))
      (harness-test-wait (lambda () (eq 'yolo (plist-get (harness-call 'session/get sid) :permission-mode)))
                         5 "the session's mode to change"))))

(declare-function harness-ui-tasks--on-window-change "harness-ui-tasks")

(ert-deftest harness-ui-tasks-bulk-edit-current-tasks ()
  "Bulk mode makes the setting commands change every current task."
  (harness-ui-tasks-test-with
    (let ((pending nil))
      (let ((harness-tasks-max-running 0))
        (setq pending (plist-get (harness-call 'task/submit default-directory "later") :id)))
      (harness-ui-tasks--fetch board t)
      (harness-test-wait (lambda () (with-current-buffer board (harness-ui-tasks--find pending)))
                         5 "the board's task")
      (with-current-buffer board
        (should (= 1 (length (harness-ui-tasks--bulk-tasks))))
        (should-not harness-ui-tasks--bulk)
        (harness-ui-tasks-toggle-bulk)
        (should harness-ui-tasks--bulk)
        (should (string-match-p "Bulk: editing" (harness-ui-tasks--header)))
        (should (string-match-p "EDITING 1 CURRENT TASK" (harness-ui-tasks-test--tail-text board)))
        (should (equal "for 1 task" (nth 2 (harness-ui--setting-target nil))))
        ;; The next task's own settings are untouched; the current one changes,
        ;; and so does the record the next task will start from.
        (should (equal "auto" (format "%s" (plist-get harness-ui-tasks--new :permission-mode))))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "YOLO")))
          (harness-set-permission-mode))
        (harness-test-wait (lambda () (equal "yolo" (format "%s" (plist-get (harness-call 'task/get pending) :permission-mode))))
                           5 "the pending task's mode")
        (should (equal "yolo" (format "%s" (plist-get harness-ui-tasks--new :permission-mode))))
        (harness-ui-tasks-toggle-bulk)
        (should-not harness-ui-tasks--bulk)
        (should-not (string-match-p "Bulk: editing" (harness-ui-tasks--header)))))))

(declare-function harness-ui-tasks--on-resize "harness-ui-tasks")
(declare-function harness-ui-tasks--refresh-soon "harness-ui-tasks")
(declare-function harness-ui-tasks--schedule-render "harness-ui-tasks")
(declare-function harness-ui-tasks--fetch "harness-ui-tasks")

(ert-deftest harness-ui-tasks-never-draws-into-other-buffers ()
  "A session that replaces the board in its window is left alone by the board's hooks."
  (harness-ui-tasks-test-with
    (let ((session (get-buffer-create " *fake chat*")))
      (unwind-protect
          (let ((window (get-buffer-window board)))
            (with-current-buffer session (insert "transcript\n"))
            (set-window-buffer window session)
            ;; The hooks and timers get the window's buffer as it is now.
            (harness-ui-tasks--on-window-change window)
            (harness-ui-tasks--on-resize window)
            (harness-ui-tasks--refresh-soon session)
            (harness-ui-tasks--schedule-render session)
            (harness-ui-tasks--fetch session)
            (with-current-buffer session (harness-ui-tasks--render) (harness-ui-tasks--render-tail))
            (let ((deadline (+ (float-time) 0.8)))
              (while (< (float-time) deadline) (accept-process-output nil 0.05)))
            (should (equal "transcript\n" (with-current-buffer session (buffer-string)))))
        (kill-buffer session)))))

(declare-function harness-ui-tasks-reply "harness-ui-tasks")
(declare-function harness-ui-tasks--set-compose "harness-ui-tasks")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-in-p "harness-ui-compose")

(defun harness-ui-tasks-test--c-g ()
  "Press C-g in the current buffer; return `quit' when it quits."
  (condition-case nil
      (progn (call-interactively (key-binding (kbd "C-g"))) nil)
    (quit 'quit)))

(ert-deftest harness-ui-tasks-c-g-leaves-the-answer-box ()
  "C-g leaves the answer box for a new task; the question is not cancelled."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type tool-call :id "demo-q" :name "ask_user"
                    :input (:question "Which colour?" :options ("red" "green")))
             (:type text :delta "Noted.")
             (:type done :stop-reason end-turn))))
      (harness-test-load-module 'tools-agent)
      (harness-ui-tasks-test--type-and-submit board "Pick a colour")
      (harness-ui-tasks-test--wait-text board "Requires your input  1\\(.\\|\n\\)*has a question for you")
      (let ((sid (plist-get (car (harness-call 'task/list default-directory)) :session)))
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Pick a colour")
          (harness-ui-tasks-reply)
          (should (eq 'answer (car harness-ui-tasks--target)))
          (should (harness-compose-in-p))
          (insert "gre")
          (should (eq 'harness-ui-tasks-compose-quit (key-binding (kbd "C-g"))))
          (should-not (harness-ui-tasks-test--c-g))
          (should-not harness-ui-tasks--target)
          (should (equal "" (harness-compose-text)))
          (should (string-match-p "New task" (buffer-substring-no-properties harness-ui-tasks--list-end
                                                                              (point-max)))))
        ;; The question still waits, on the session and on the card...
        (should (= 1 (length (harness-call 'question/pending sid))))
        (harness-ui-tasks-test--wait-text board "Requires your input  1\\(.\\|\n\\)*has a question for you")
        ;; ...where [Answer] comes back to it.
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Pick a colour")
          (harness-ui-tasks-reply)
          (should (eq 'answer (car harness-ui-tasks--target)))
          (insert "green")
          (harness-ui-tasks-submit))
        (harness-test-wait (lambda () (null (harness-call 'question/pending sid))) 5 "the question to be answered")
        (harness-ui-tasks-test--wait-text board "Completed  1")))))

(ert-deftest harness-ui-tasks-c-g-otherwise-quits-as-usual ()
  "With a region or nothing to leave, C-g quits the usual way, globally remapped too."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (goto-char harness-compose-end)
      (insert "a new task")
      ;; Nothing to leave: it quits, and the new task's text stays.
      (should (eq 'quit (harness-ui-tasks-test--c-g)))
      (should (equal "a new task" (harness-compose-text)))
      ;; An active region is deactivated first; the box stays.
      (harness-ui-tasks--set-compose "half a message" (cons 'reply "t1"))
      (let ((transient-mark-mode t))
        (set-mark harness-compose-start)
        (should (region-active-p))
        (should (eq 'quit (harness-ui-tasks-test--c-g)))
        (should-not (region-active-p))
        (should (equal '(reply . "t1") harness-ui-tasks--target))
        (should (equal "half a message" (harness-compose-text))))
      ;; A global remapping of `keyboard-quit' (Doom's `doom/escape') runs
      ;; once there is no box left to leave.
      (let* ((escapes 0)
             (old (lookup-key global-map [remap keyboard-quit])))
        (define-key global-map [remap keyboard-quit] (lambda () (interactive) (cl-incf escapes)))
        (unwind-protect
            (progn
              (should-not (harness-ui-tasks-test--c-g))
              (should-not harness-ui-tasks--target)
              (should (= 0 escapes))
              (should-not (harness-ui-tasks-test--c-g))
              (should (= 1 escapes)))
          (define-key global-map [remap keyboard-quit] old))))))

;;;; The box wraps and never scrolls sideways

(defvar harness-compose-overlay)
(defvar harness-compose--pads)
(declare-function harness-compose-unscroll "harness-ui-compose")
(declare-function harness-compose-pad-window "harness-ui-compose")
(declare-function harness-ui-tasks--refit-tail "harness-ui-tasks")
(declare-function harness-ui-tasks--render-tail "harness-ui-tasks")

(defun harness-ui-tasks-test--words (n)
  "N words of text, one long line."
  (mapconcat #'identity (make-list n "word") " "))

(ert-deftest harness-ui-tasks-compose-wraps ()
  "The board's box wraps long lines, in a side window too, and never scrolls sideways."
  (harness-ui-tasks-test-with
    (let ((window (get-buffer-window board)))
      (with-current-buffer board
        (should-not truncate-lines)
        (should word-wrap)
        ;; A window narrower than the frame would truncate otherwise.
        (should (local-variable-p 'truncate-partial-width-windows))
        (should-not truncate-partial-width-windows)
        (goto-char harness-compose-end)
        (insert (harness-ui-tasks-test--words 40))
        (should (> (count-screen-lines harness-compose-start harness-compose-end t window) 1))
        (let ((side (split-window window 40 'right)))
          (unwind-protect
              (progn
                (set-window-buffer side board)
                (should (< (window-total-width side) (default-value 'truncate-partial-width-windows)))
                (should (> (count-screen-lines harness-compose-start harness-compose-end t side) 3)))
            (delete-window side)))
        ;; A window scrolled sideways by hand comes back before it is drawn.
        (should (memq #'harness-compose-unscroll pre-redisplay-functions))
        (set-window-hscroll window 7)
        (harness-compose-unscroll window)
        (should (= 0 (window-hscroll window)))
        ;; Unless the user truncated the lines again: then it follows point.
        (setq truncate-lines t)
        (set-window-hscroll window 7)
        (harness-compose-unscroll window)
        (should (= 7 (window-hscroll window)))))))

(ert-deftest harness-ui-tasks-compose-lines-up-after-the-prompt ()
  "Wrapped lines and lines after a newline start under the text, not under the prompt."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (goto-char harness-compose-end)
      (insert "first line\nsecond line")
      (let ((prompt (save-excursion (goto-char harness-compose-start) (pos-bol))))
        (should-not (get-char-property prompt 'line-prefix))
        ;; The box's lines, down to an empty last one.
        (dolist (pos (list harness-compose-start (1- harness-compose-end) harness-compose-end))
          (should (equal "  " (get-char-property pos 'line-prefix)))
          (should (equal "  " (get-char-property pos 'wrap-prefix)))))
      ;; Text typed at the start of the box, and a redraw, keep it lined up.
      (goto-char harness-compose-start)
      (insert "x")
      (should (equal "  " (get-char-property harness-compose-start 'wrap-prefix)))
      (harness-ui-tasks--render-tail)
      (should (equal "xfirst line\nsecond line" (harness-compose-text)))
      (should (equal "  " (get-char-property (1- harness-compose-end) 'line-prefix))))))

(ert-deftest harness-ui-tasks-compose-c-a-c-k-clears ()
  "C-a stops after the prompt, so C-a C-k clears the box."
  (harness-ui-tasks-test-with
    (harness-test-compose-c-a-c-k board)))

(ert-deftest harness-ui-tasks-tail-fits-the-window ()
  "The lines above the box fit the window, also after it narrows, leaving the box alone."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (window (get-buffer-window board)))
      (harness-ui-tasks-test--type-and-submit board (concat "A pending task " (harness-ui-tasks-test--words 30)))
      (harness-ui-tasks-test--wait-text board "Pending  1")
      (with-current-buffer board
        (goto-char (point-min))
        (search-forward "A pending task")
        (harness-ui-tasks-edit)
        (let ((fits (lambda (width)
                      ;; Every line between the board and the box, [cancel] included.
                      (save-excursion
                        (goto-char harness-ui-tasks--list-end)
                        (should (search-forward "[cancel]" (overlay-start harness-compose-overlay) t))
                        (goto-char harness-ui-tasks--list-end)
                        (while (< (point) (overlay-start harness-compose-overlay))
                          (should (< (string-width (buffer-substring (point) (line-end-position))) width))
                          (forward-line 1))))))
          (funcall fits (window-body-width window))
          (let ((side (split-window window 40 'right))
                (text (harness-compose-text))
                (offset (- (point) harness-compose-start)))
            (unwind-protect
                (progn
                  (set-window-buffer side board)
                  (set-window-buffer window (get-buffer-create "*scratch*"))
                  (harness-ui-tasks--refit-tail)
                  (funcall fits (window-body-width side))
                  (should (equal text (harness-compose-text)))
                  (should (= offset (- (point) harness-compose-start))))
              (delete-window side)
              (set-window-buffer window board))))))))

(ert-deftest harness-ui-tasks-box-stays-at-the-bottom ()
  "A box grown past the window keeps its last line on the window's last line."
  (harness-ui-tasks-test-with
    (let ((window (get-buffer-window board)))
      (with-current-buffer board
        (goto-char harness-compose-end)
        (insert (mapconcat #'identity (make-list 40 "a line") "\n"))
        (set-window-point window (point))
        (harness-compose-pad-window window)
        (should (> (window-start window) (point-min)))
        (should (= (window-body-height window t)
                   (cdr (window-text-pixel-size window (window-start window) harness-compose-end))))
        ;; Scrolling is the user's: without a change the window stays put.
        (set-window-start window (point-min))
        (harness-compose-pad-window window)
        (should (= (point-min) (window-start window)))
        ;; Back to one line, the board shows from its top, padded.
        (delete-region harness-compose-start harness-compose-end)
        (insert "short")
        (set-window-start window 10)
        (harness-compose-pad-window window)
        (should (= (point-min) (window-start window)))))))

(ert-deftest harness-ui-tasks-box-grows-past-a-short-window ()
  "A board taller than its window keeps the box on its last line, point in it.
A BTW under the board makes its window that short.  Measured as on a
graphical frame, a board a line or so too tall once seemed to fit: its
window was forced back to the top, and redisplay moved point out of the
box, up a line or onto the board, whose letters are commands."
  (harness-ui-tasks-test-with
    (harness-test-compose-grows-past-the-window board (get-buffer-window board) 0)))

(ert-deftest harness-ui-tasks-padding-leaves-with-its-window ()
  "A window that stops showing the board takes its padding along."
  (harness-ui-tasks-test-with
    (let* ((window (get-buffer-window board))
           (side (split-window window nil 'right)))
      (unwind-protect
          (with-current-buffer board
            (set-window-buffer side board)
            (harness-compose-pad-window window)
            (harness-compose-pad-window side)
            (let ((pad (alist-get window harness-compose--pads)))
              (should pad)
              (set-window-buffer window (get-buffer-create "*scratch*"))
              (harness-compose-pad-window side)
              (should-not (alist-get window harness-compose--pads))
              ;; Left behind it would pad the window twice once it shows the board again.
              (should-not (overlay-buffer pad))))
        (delete-window side)
        (set-window-buffer window board)))))

;;;; Submit or Refine: the backlog

(defvar harness-ui-tasks--refine)
(defvar harness-ui-tasks--settings)
(declare-function harness-ui-tasks-toggle-refine "harness-ui-tasks")
(declare-function harness-ui-tasks-refine "harness-ui-tasks")
(declare-function harness-ui-tasks-start "harness-ui-tasks")
(declare-function harness-ui-tasks--task "harness-ui-tasks")
(declare-function harness-ui-tasks--actions "harness-ui-tasks")
(declare-function harness-ui-tasks--placeholder "harness-ui-tasks")
(declare-function harness-ui-tasks-compose-reset "harness-ui-tasks")

(defun harness-ui-tasks-test--tail-text (board)
  "The compose end of BOARD (label, toggle, settings, box) as plain text."
  (with-current-buffer board
    (buffer-substring-no-properties harness-ui-tasks--list-end (point-max))))

(defun harness-ui-tasks-test--modes-shown (board)
  "Which of Submit and Refine BOARD shows above its compose box."
  (with-current-buffer board
    (let ((head (buffer-substring-no-properties harness-ui-tasks--list-end
                                                (overlay-start harness-compose-overlay))))
      (seq-filter (lambda (mode) (string-search mode head)) '("Submit" "Refine")))))

(defun harness-ui-tasks-test--toggle (board)
  "Where BOARD's Submit / Refine toggle is: the start of its label."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (re-search-forward "Submit\\|Refine" (overlay-start harness-compose-overlay))
      (match-beginning 0))))

(defun harness-ui-tasks-test--goto-card (board text)
  "Move point in BOARD to the card showing TEXT."
  (with-current-buffer board
    (goto-char (point-min))
    (search-forward text)))

(declare-function harness-ui-tasks-toggle-main-tree "harness-ui-tasks")
(declare-function harness-ui-tasks--render-tail "harness-ui-tasks")

(ert-deftest harness-ui-tasks-main-tree-switch ()
  "The worktree switch makes the next task work in the main tree, on the card too."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      ;; A git project, where the switch applies; this test's dir is not one.
      (setq harness-ui-tasks--settings (plist-put (copy-sequence harness-ui-tasks--settings) :worktrees t))
      (harness-ui-tasks--render-tail)
      (let ((tail (harness-ui-tasks-test--tail-text board)))
        ;; The switch's label is the only word on where the task works:
        ;; no explainer repeats it.
        (should (= 1 (1- (length (split-string tail "own worktree"))))))
      (harness-ui-tasks-toggle-main-tree)
      (should (harness-json-true-p (plist-get harness-ui-tasks--new :main-tree)))
      (let ((tail (harness-ui-tasks-test--tail-text board)))
        (should (string-match-p "main tree" tail))
        (should (= 1 (1- (length (split-string tail "main tree")))))
        (should-not (string-match-p "no worktree" tail))))
    (harness-ui-tasks-test--type-and-submit board "Clean the checkout")
    (harness-ui-tasks-test--wait-text board "main tree")
    (let ((task (car (harness-call 'task/list default-directory))))
      (should (harness-json-true-p (plist-get task :main-tree))))))

(defun harness-ui-tasks-test--show-subtitle (board text)
  "Show the subtitle of BOARD's card whose title shows TEXT, and render.
Cards are one line by default (see `harness-ui-tasks-toggle-subtitle');
tests that check a card's detail line show it first."
  (with-current-buffer board
    (harness-ui-tasks-test--goto-card board text)
    (let ((id (plist-get (harness-ui-tasks--task) :id)))
      (harness-ui-tasks--set-subtitle id t)
      (harness-ui-tasks--render))))

(ert-deftest harness-ui-tasks-refine-toggle-fills-the-backlog ()
  "With the toggle on Refine a new task is written up and waits in Pending for its start."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "Fix nested quotes in the parser\n\nHandle them in parse-args.")
             (:type done :stop-reason end-turn))))
      (with-current-buffer board
        (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
        (should-not harness-ui-tasks--refine)
        ;; The toggle shows only the current mode.
        (should (string-match-p "New task +. Submit\n" (harness-ui-tasks-test--tail-text board)))
        (should (equal '("Submit") (harness-ui-tasks-test--modes-shown board)))
        (goto-char harness-compose-end)
        (should (eq 'harness-ui-tasks-toggle-refine (key-binding (kbd "C-c C-t"))))
        (harness-ui-tasks-toggle-refine)
        (should harness-ui-tasks--refine)
        (should (equal '("Refine") (harness-ui-tasks-test--modes-shown board)))
        (should (string-match-p "an agent writes it up" (harness-ui-tasks-test--tail-text board)))
        (insert "the parser chokes on nested quotes")
        (harness-ui-tasks-submit)
        ;; The toggle stays on Refine for the next one.
        (should harness-ui-tasks--refine))
      (harness-ui-tasks-test--wait-text
       board "Pending  1\\(.\\|\n\\)*Fix nested quotes in the parser")
      (harness-ui-tasks-test--show-subtitle board "Fix nested quotes in the parser")
      (harness-ui-tasks-test--wait-text board "refined, start it when ready")
      (should (string-match-p "In progress  0" (harness-ui-tasks-test--board-text board)))
      (let ((task (car (harness-call 'task/list default-directory))))
        (should (eq 'pending (plist-get task :state)))
        (should (plist-get task :backlog))
        (should (equal "the parser chokes on nested quotes" (plist-get task :note))))
      ;; Its card starts it, and its session does the work.
      (harness-ui-tasks-test--goto-card board "Fix nested quotes")
      (with-current-buffer board
        (should (equal '("Start now" "Edit")
                       (take 2 (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task))))))
        (should (eq 'harness-ui-tasks-refine (key-binding (kbd "r"))))
        (harness-ui-tasks-start))
      (harness-ui-tasks-test--wait-text board "Completed  1")
      ;; Back to Submit with a click on the toggle, a task starts at once again.
      (with-current-buffer board
        (push-button (harness-ui-tasks-test--toggle board))
        (should-not harness-ui-tasks--refine)
        (should (equal '("Submit") (harness-ui-tasks-test--modes-shown board))))
      (harness-ui-tasks-test--type-and-submit board "Straight to work")
      (harness-ui-tasks-test--wait-text board "Completed  2"))))

(ert-deftest harness-ui-tasks-refine-feedback-from-the-card ()
  "r on a backlog task sends feedback, and the agent writes it up again."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "First write-up") (:type done :stop-reason end-turn))))
      (with-current-buffer board (harness-ui-tasks-toggle-refine))
      (harness-ui-tasks-test--type-and-submit board "An idea")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*First write-up")
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Second write-up") (:type done :stop-reason end-turn))))
        (harness-ui-tasks-test--goto-card board "First write-up")
        (with-current-buffer board
          (harness-ui-tasks-refine)
          (should (eq 'refine (car harness-ui-tasks--target)))
          (should (string-match-p "Refine .First write-up." (harness-ui-tasks-test--tail-text board)))
          (insert "call it the second")
          (harness-ui-tasks-submit)
          (should-not harness-ui-tasks--target))
        (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Second write-up")))))

(ert-deftest harness-ui-tasks-refine-failure-needs-input ()
  "A write-up that stops asks for you; written by hand, the task waits in the backlog."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (with-current-buffer board (harness-ui-tasks-toggle-refine))
      (harness-ui-tasks-test--type-and-submit board "Shaky idea")
      (harness-ui-tasks-test--wait-text board "Requires your input  1\\(.\\|\n\\)*write-up stopped: error")
      (harness-ui-tasks-test--goto-card board "Shaky idea")
      (with-current-buffer board
        (should (equal "Retry" (caar (harness-ui-tasks--actions (harness-ui-tasks--task)))))
        (harness-ui-tasks-edit)
        (should (eq 'edit (car harness-ui-tasks--target)))
        (delete-region harness-compose-start harness-compose-end)
        (goto-char harness-compose-start)
        (insert "Make the shaky idea solid")
        (harness-ui-tasks-submit))
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Make the shaky idea solid")
      (harness-ui-tasks-test--show-subtitle board "Make the shaky idea solid")
      (harness-ui-tasks-test--wait-text board "on hold"))))

(ert-deftest harness-ui-tasks-refused-duplicate-card ()
  "A write-up that refuses its task as a duplicate names the original; r writes it up all the same."
  (harness-ui-tasks-test-with
    ;; A finished task on the board for the write-up to find.
    (harness-ui-tasks-test--type-and-submit board "CSV export for reports")
    (harness-ui-tasks-test--wait-text board "Completed  1")
    (let* ((first (car (harness-call 'task/list default-directory)))
           (fid (plist-get first :id)))
      (harness-call 'session/update (plist-get first :session) :name "CSV export" :silent t)
      (harness-ui-tasks-test--wait-text board "CSV export")
      (setq harness-provider-demo-script-override
            `((:type text :delta ,(format "Duplicate of %s\n\nThe board has it already." fid))
              (:type done :stop-reason end-turn)))
      (with-current-buffer board (harness-ui-tasks-toggle-refine))
      (harness-ui-tasks-test--type-and-submit board "export the reports as csv")
      (harness-ui-tasks-test--wait-text
       board "Requires your input  1\\(.\\|\n\\)*duplicate of .CSV export.")
      (harness-ui-tasks-test--goto-card board "duplicate of")
      (with-current-buffer board
        (should (equal '("Drop" "Write it up")
                       (take 2 (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task))))))
        ;; m takes feedback on it: what makes it another task than the one it duplicates.
        (harness-ui-tasks-reply)
        (should (eq 'refine (car harness-ui-tasks--target)))
        (should (string-match-p "another task" (harness-ui-tasks--placeholder)))
        (harness-ui-tasks-compose-reset))
      ;; r has it written up all the same.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Export the reports as CSV\n\nNot the same after all.")
               (:type done :stop-reason end-turn))))
        (harness-ui-tasks-test--goto-card board "duplicate of")
        (with-current-buffer board (harness-ui-tasks-refine))
        (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Export the reports as CSV")))))

(ert-deftest harness-ui-tasks-toggle-shows-the-current-mode ()
  "The toggle is one button naming the current mode; a click switches to the other."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
      (pcase-dolist (`(,refine ,mode ,does ,other)
                     '((nil "Submit" "starts at once" "Refine")
                       (t "Refine" "an agent writes the task up" "Submit")))
        (should (eq refine harness-ui-tasks--refine))
        (should (equal (list mode) (harness-ui-tasks-test--modes-shown board)))
        (let* ((pos (harness-ui-tasks-test--toggle board))
               (help (get-text-property pos 'help-echo)))
          ;; One face: there is no unselected side to dim any more.
          (should (eq 'harness-task-choice-face (get-text-property pos 'face)))
          ;; Its tooltip says what the mode does and how to switch.
          (should (string-search does help))
          (should (string-search (concat "click or C-c C-t to switch to " other) help))
          (push-button pos))
        (should (equal (list other) (harness-ui-tasks-test--modes-shown board))))
      (should-not harness-ui-tasks--refine))))

(ert-deftest harness-ui-tasks-toggle-fits-the-window ()
  "The New task line, toggle included, fits a narrow window like the rest of the tail."
  (harness-ui-tasks-test-with
    (let* ((window (get-buffer-window board))
           (side (split-window window 40 'right)))
      (unwind-protect
          (with-current-buffer board
            (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
            (set-window-buffer side board)
            (set-window-buffer window (get-buffer-create "*scratch*"))
            (should-not harness-ui-tasks--refine)
            (dolist (mode '("Submit" "Refine"))
              (harness-ui-tasks--refit-tail)
              ;; Only the current mode shows, whole.
              (should (equal (list mode) (harness-ui-tasks-test--modes-shown board)))
              (save-excursion
                (goto-char harness-ui-tasks--list-end)
                (while (< (point) (overlay-start harness-compose-overlay))
                  (should (< (string-width (buffer-substring (point) (line-end-position)))
                             (window-body-width side)))
                  (forward-line 1)))
              ;; Toggling switches it to the other mode.
              (harness-ui-tasks-toggle-refine))
            (should-not harness-ui-tasks--refine)
            (should (equal '("Submit") (harness-ui-tasks-test--modes-shown board))))
        (delete-window side)
        (set-window-buffer window board)))))

;;;; Review: finished work waits for you

(declare-function harness-ui-tasks-reject "harness-ui-tasks")
(declare-function harness-ui-tasks-verify "harness-ui-tasks")

(defun harness-ui-tasks-test--user-texts (sid)
  "The user messages of session SID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes sid))))

(ert-deftest harness-ui-tasks-review-verify-and-send-back ()
  "Finished work waits in Ready for review: R sends it back with feedback, v accepts it."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (notices nil))
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (when format-string (push (apply #'format format-string args) notices))
                    (apply orig format-string args))))
        (harness-ui-tasks-test--type-and-submit board "Fix the flaky test")
        (harness-ui-tasks-test--wait-text board "Ready for review  1\\(.\\|\n\\)*Fix the flaky test")
        ;; The review facts ("sent back once", the merge target) live on
        ;; the subtitle, folded by default: show it for the checks below.
        (harness-ui-tasks-test--show-subtitle board "Fix the flaky test")
        ;; It says so wherever you are.
        (harness-test-wait (lambda () (cl-some (lambda (m) (string-match-p "Fix the flaky test. is ready for your review" m))
                                               notices))
                           5 "the review notice"))
      (should (string-match-p "Completed  0" (harness-ui-tasks-test--board-text board)))
      (should (string-match-p "1 to review" (with-current-buffer board (harness-ui-tasks--header))))
      (harness-ui-tasks-test--goto-card board "Fix the flaky test")
      (with-current-buffer board
        (should (equal '("Verify" "Send back")
                       (take 2 (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task))))))
        (should (eq 'harness-ui-tasks-verify (key-binding (kbd "v"))))
        (should (eq 'harness-ui-tasks-reject (key-binding (kbd "R"))))
        ;; R takes the feedback in the compose box.
        (call-interactively (key-binding (kbd "R")))
        (should (eq 'reject (car harness-ui-tasks--target)))
        (should (harness-compose-in-p))
        (should (string-match-p "Send back .Fix the flaky test. with feedback" (harness-ui-tasks-test--tail-text board)))
        (insert "It still flakes on CI")
        (harness-ui-tasks-submit)
        (should-not harness-ui-tasks--target))
      (harness-ui-tasks-test--wait-text board "Ready for review  1\\(.\\|\n\\)*sent back once")
      (let ((sid (plist-get (car (harness-call 'task/list default-directory)) :session)))
        (should (string-suffix-p "It still flakes on CI" (car (last (harness-ui-tasks-test--user-texts sid)))))
        ;; With a prefix argument the feedback is read in the minibuffer.
        (harness-ui-tasks-test--goto-card board "Fix the flaky test")
        (with-current-buffer board
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "And on macOS")))
            (let ((current-prefix-arg '(4)))
              (call-interactively #'harness-ui-tasks-reject)))
          (should-not harness-ui-tasks--target))
        (harness-ui-tasks-test--wait-text board "Ready for review  1\\(.\\|\n\\)*sent back twice")
        (should (string-suffix-p "And on macOS" (car (last (harness-ui-tasks-test--user-texts sid))))))
      ;; v accepts it.
      (harness-ui-tasks-test--goto-card board "Fix the flaky test")
      (with-current-buffer board (call-interactively (key-binding (kbd "v"))))
      (harness-ui-tasks-test--wait-text board "Completed  1\\(.\\|\n\\)*Fix the flaky test")
      (should (string-match-p "Ready for review  0" (harness-ui-tasks-test--board-text board)))
      (should (plist-get (car (harness-call 'task/list default-directory)) :verified))
      ;; Only work waiting for review is verified or sent back.
      (harness-ui-tasks-test--goto-card board "Fix the flaky test")
      (with-current-buffer board
        (should-error (harness-ui-tasks-verify) :type 'user-error)
        (should-error (harness-ui-tasks-reject) :type 'user-error)))))

;;;; Review: the switch that turns it off

(declare-function harness-ui-tasks-toggle-review "harness-ui-tasks")
(declare-function harness-ui-tasks-refresh "harness-ui-tasks")
(declare-function harness-ui-tasks--new-settings-line "harness-ui-tasks")

(defun harness-ui-tasks-test--settings-say (board review)
  "Wait until BOARD's settings say REVIEW, t or `:false', about review."
  (harness-test-wait (lambda () (eq review (plist-get (buffer-local-value 'harness-ui-tasks--settings board)
                                                     :require-verification)))
                     5 (format "the board to know review is %s" (if (eq review t) "on" "off"))))

(defun harness-ui-tasks-test--switch (board)
  "Return (TEXT HELP CLICK) of the Review switch in BOARD's header line, or nil.
HELP is its tooltip, CLICK what a click on it runs."
  (with-current-buffer board
    ;; The whole header: which segments a narrow window keeps is not what
    ;; this asks about, and the switch is one a window may drop.
    (let* ((header (harness-ui-tasks--header most-positive-fixnum))
           (start (string-search "[Review: " header)))
      (when start
        (list (substring-no-properties header start (1+ (string-search "]" header start)))
              (let ((help (get-text-property start 'help-echo header)))
                (if (functionp help) (funcall help (get-buffer-window board t) nil nil) help))
              (lookup-key (get-text-property start 'keymap header) [header-line mouse-1]))))))

(ert-deftest harness-ui-tasks-review-switch ()
  "The Review switch turns review off and on again: an option, saved for every project.
Off, finished work completes by itself and Ready for review goes away."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (saved nil))
      (cl-letf (((symbol-function 'harness-save-user-option)
                 (lambda (symbol value) (set symbol value) (push (cons symbol value) saved)))
                ;; Nothing waits for review, so turning it off asks nothing.
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked about tasks waiting for review"))))
        (with-current-buffer board (harness-ui-tasks-refresh))
        (harness-ui-tasks-test--settings-say board t)
        (pcase-let ((`(,text ,help ,_) (harness-ui-tasks-test--switch board)))
          (should (equal "[Review: on]" text))
          (should (string-search "Review is on" help))
          (should (string-search "V to turn it off, for every project" help)))
        ;; V on the board turns it off.
        (with-current-buffer board
          (goto-char (point-min))
          (should (eq 'harness-ui-tasks-toggle-review (key-binding (kbd "V"))))
          (call-interactively (key-binding (kbd "V"))))
        (harness-test-wait (lambda () (equal "[Review: off]" (car (harness-ui-tasks-test--switch board))))
                           5 "the switch to show off")
        ;; Saved as the option, so it holds for every project and after a restart.
        (should (equal '((harness-tasks-require-verification)) saved))
        (should-not harness-tasks-require-verification)
        (should (string-search "Review is off" (nth 1 (harness-ui-tasks-test--switch board))))
        ;; Finished work is done without waiting for anyone, and the board
        ;; has no column for review.
        (harness-ui-tasks-test--type-and-submit board "Fix the flaky test")
        (harness-ui-tasks-test--wait-text board "Completed  1\\(.\\|\n\\)*Fix the flaky test")
        (should (string-match-p "In progress  0" (harness-ui-tasks-test--board-text board)))
        (should-not (string-search "Ready for review" (harness-ui-tasks-test--board-text board)))
        (should-not (plist-get (car (harness-call 'task/list default-directory)) :verified))
        ;; A click on the switch turns it on again.
        (with-current-buffer board (funcall (nth 2 (harness-ui-tasks-test--switch board))))
        (harness-test-wait (lambda () harness-tasks-require-verification) 5 "review on again")
        (should (equal '(harness-tasks-require-verification . t) (car saved)))
        (harness-ui-tasks-test--settings-say board t)
        (should (equal "[Review: on]" (car (harness-ui-tasks-test--switch board))))
        (should (string-match-p "Ready for review  0" (harness-ui-tasks-test--board-text board)))))))

(ert-deftest harness-ui-tasks-review-off-verifies-what-waits ()
  "Turning review off while tasks wait for it offers to verify them.
No leaves them waiting; yes verifies them, and they complete.  A prefix
argument says which way to turn it, and turning it on asks nothing."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (answer nil)
          (asked nil))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (symbol value) (set symbol value)))
                ((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) answer)))
        (harness-ui-tasks-test--type-and-submit board "First task")
        (harness-ui-tasks-test--type-and-submit board "Second task")
        (harness-ui-tasks-test--wait-text board "Ready for review  2")
        (harness-ui-tasks-test--settings-say board t)
        ;; No: they wait on, and so does their column.
        (with-current-buffer board (harness-ui-tasks-toggle-review))
        (should (equal '("Verify the 2 tasks waiting for your review too? ") asked))
        (harness-ui-tasks-test--settings-say board :false)
        (should-not harness-tasks-require-verification)
        (harness-ui-tasks-test--wait-text board "Ready for review  2")
        ;; On, with a prefix argument: nothing to ask.
        (setq asked nil)
        (with-current-buffer board
          (let ((current-prefix-arg 1)) (call-interactively #'harness-ui-tasks-toggle-review)))
        (harness-ui-tasks-test--settings-say board t)
        (should harness-tasks-require-verification)
        (should-not asked)
        ;; Off again, and yes: both are verified and complete.
        (setq answer t)
        (with-current-buffer board
          (let ((current-prefix-arg -1)) (call-interactively #'harness-ui-tasks-toggle-review)))
        (should (= 1 (length asked)))
        (harness-ui-tasks-test--wait-text board "Completed  2")
        (should-not (string-search "Ready for review" (harness-ui-tasks-test--board-text board)))
        (dolist (task (harness-call 'task/list default-directory))
          (should (eq 'done (plist-get task :state)))
          (should (plist-get task :verified)))))))

;;;; Point stays where it was put

;; The board is drawn again on every change of a task or a session and
;; on every tick of the clock, the lines above the box on every reload:
;; point moved there with the usual keys must stay, or the key pressed
;; next acts somewhere else.

(defun harness-ui-tasks-test--change (board id &rest props)
  "Set PROPS (KEY VALUE...) on task ID of BOARD, as the harness would."
  (with-current-buffer board
    (setq harness-ui-tasks--tasks
          (mapcar (lambda (task)
                    (if (not (equal id (plist-get task :id)))
                        task
                      (let ((task (copy-sequence task)))
                        (cl-loop for (key value) on props by #'cddr
                                 do (setq task (plist-put task key value)))
                        task)))
                  harness-ui-tasks--tasks))))

(defun harness-ui-tasks-test--card-id (board text)
  "The id of the task whose card in BOARD shows TEXT."
  (harness-ui-tasks-test--goto-card board text)
  (with-current-buffer board (plist-get (harness-ui-tasks--task) :id)))

(defun harness-ui-tasks-test--line (&optional pos)
  "The text of the line at POS (default point)."
  (save-excursion
    (when pos (goto-char pos))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun harness-ui-tasks-test--on-second-line-p (id)
  "Non-nil when point is on the second line of task ID's card."
  (and (equal id (get-text-property (point) 'harness-task-id))
       (> (line-beginning-position) (point-min))
       (equal id (get-text-property (1- (line-beginning-position)) 'harness-task-id))))

(ert-deftest harness-ui-tasks-redraw-keeps-point-on-the-buttons ()
  "Point moved to a card's buttons stays on the same button through redraws.
A folded card is one line, so its buttons sit right of its facts there."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "First waiting task")
      (harness-ui-tasks-test--type-and-submit board "Second waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  2")
      (let ((id (harness-ui-tasks-test--card-id board "First waiting task")))
        (with-current-buffer board
          ;; On the card's only line, three characters into [Start now].
          (search-forward "[Start now]")
          (goto-char (+ (match-beginning 0) 3))
          (should (equal id (get-text-property (point) 'harness-task-id)))
          (harness-ui-tasks--render)
          (should (equal id (get-text-property (point) 'harness-task-id)))
          (should (looking-at-p (regexp-quote "art now]")))
          ;; The text on its left grows: point stays on the button.
          (harness-ui-tasks-test--change board id :prompt "First waiting task, now under a much longer title")
          (harness-ui-tasks--render)
          (should (string-search "First waiting task" (harness-ui-tasks-test--line)))
          (should (looking-at-p (regexp-quote "art now]")))
          ;; The keys pressed there push the button, and act on its card.
          (should (eq 'push-button (key-binding (kbd "RET"))))
          (should (eq 'harness-ui-tasks-start (key-binding (kbd "s"))))
          (should (equal id (plist-get (harness-ui-tasks--task) :id)))
          ;; The text on the left of the line stays put the same way.
          (beginning-of-line)
          (forward-char 6)
          (harness-ui-tasks-test--change board id :prompt "First waiting task")
          (harness-ui-tasks--render)
          (should (= 6 (current-column))))))))

(ert-deftest harness-ui-tasks-redraw-never-puts-point-on-another-button ()
  "A card whose buttons change leaves point on its line, off the new buttons.
RET there would push a button point was never on."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "Waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  1")
      (let ((id (harness-ui-tasks-test--card-id board "Waiting task")))
        (with-current-buffer board
          (search-forward "[Edit]")
          (goto-char (match-beginning 0))
          ;; Completed, the card offers [Archive] [Reply], [Reply] where [Edit] was.
          (harness-ui-tasks-test--change board id :state "done" :column "done")
          (harness-ui-tasks--render)
          (should (string-search "[Archive] [Reply]" (harness-ui-tasks-test--line)))
          (should (equal id (get-text-property (point) 'harness-task-id)))
          (should-not (get-text-property (point) 'button))
          (should (eq 'harness-ui-tasks-open (key-binding (kbd "RET")))))))))

(ert-deftest harness-ui-tasks-redraw-keeps-point-between-the-cards ()
  "Point on a line of no card, the blank one after a column, stays on it."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "First waiting task")
      (harness-ui-tasks-test--type-and-submit board "Second waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  2")
      (let ((first (harness-ui-tasks-test--card-id board "First waiting task"))
            (second (harness-ui-tasks-test--card-id board "Second waiting task")))
        (with-current-buffer board
          ;; On the blank line right after the second card.
          (harness-ui-tasks-test--goto-card board "Second waiting task")
          (forward-line 1)
          (should (and (bolp) (eolp)))
          (should (equal second (get-text-property (1- (point)) 'harness-task-id)))
          ;; The cards above it change length.
          (harness-ui-tasks-test--change board first :prompt "First waiting task, now under a much longer title")
          (harness-ui-tasks--render)
          (should (and (bolp) (eolp)))
          (should (equal second (get-text-property (1- (point)) 'harness-task-id))))))))

(ert-deftest harness-ui-tasks-redraw-keeps-every-window-in-place ()
  "Every window showing the board keeps its point and its start, not just the selected one."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (window (get-buffer-window board)))
      (harness-ui-tasks-test--type-and-submit board "First waiting task")
      (harness-ui-tasks-test--type-and-submit board "Second waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  2")
      (let ((first (harness-ui-tasks-test--card-id board "First waiting task"))
            (second (harness-ui-tasks-test--card-id board "Second waiting task"))
            (side (split-window window nil 'below)))
        (unwind-protect
            (with-current-buffer board
              (set-window-buffer side board)
              (goto-char harness-compose-end)
              ;; The other window starts at the second card, its point on the card's [Edit].
              (let ((start (save-excursion (harness-ui-tasks-test--goto-card board "Second waiting task")
                                           (line-beginning-position)))
                    (edit (save-excursion (harness-ui-tasks-test--goto-card board "Second waiting task")
                                          (search-forward "[Edit]")
                                          (1+ (match-beginning 0)))))
                (set-window-start side start)
                (set-window-point side edit))
              (harness-ui-tasks-test--change board first :prompt "First waiting task, now under a much longer title")
              (harness-ui-tasks--render)
              (should (= (point) harness-compose-end))
              (save-excursion
                (goto-char (window-point side))
                (should (equal second (get-text-property (point) 'harness-task-id)))
                (should (looking-at-p (regexp-quote "Edit]"))))
              (save-excursion
                (goto-char (window-start side))
                (should (bolp))
                (should (string-search "Second waiting task" (harness-ui-tasks-test--line)))))
          (delete-window side))))))

(ert-deftest harness-ui-tasks-redraw-keeps-point-above-the-box ()
  "Point on a setting above the box stays on it: reloads, resizes, its own change."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
      (let ((setting (lambda ()
                       (save-excursion
                         (goto-char harness-ui-tasks--list-end)
                         (prop-match-beginning
                          (text-property-search-forward 'harness-task-button 'harness-toggle-non-interactive #'eq))))))
        (goto-char (1+ (funcall setting)))
        (let ((label (button-label (button-at (point)))))
          ;; Every reload draws these lines again, a resize too.
          (harness-ui-tasks--render-tail)
          (should (= (point) (1+ (funcall setting))))
          (harness-ui-tasks--refit-tail)
          (should (= (point) (1+ (funcall setting))))
          (harness-ui-tasks--render)
          (should (= (point) (1+ (funcall setting))))
          ;; Pushed, the button names the other setting, and point stays on it.
          (push-button (point))
          (should-not (equal label (button-label (button-at (point)))))
          (should (= (point) (1+ (funcall setting))))))
      ;; Under the box too.
      (goto-char (point-max))
      (harness-ui-tasks--render-tail)
      (should (= (point) (point-max)))
      ;; On a line that goes away, the error's: the first line above the box.
      (setq harness-ui-tasks--error "Starting the task failed: boom")
      (harness-ui-tasks--render-tail)
      (goto-char harness-ui-tasks--list-end)
      (should (string-search "boom" (harness-ui-tasks-test--line)))
      (forward-char 4)
      (setq harness-ui-tasks--error nil)
      (harness-ui-tasks--render-tail)
      (should (= (point) harness-ui-tasks--list-end))
      (should (string-search "New task" (harness-ui-tasks-test--line))))))

(ert-deftest harness-ui-tasks-click-pushes-the-button ()
  "Any click on a button pushes it once, and leaves point there.
A slow click, or a double click's second, used to reach the board's own
click and open the session instead."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "Waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  1")
      (harness-ui-tasks-test--goto-card board "Waiting task")
      (with-current-buffer board
        ;; The title opens the session, however long the click.
        (should (eq 'harness-ui-tasks-mouse-open (key-binding [mouse-1] nil nil (point))))
        (search-forward "[Start now]")
        (let ((pos (match-beginning 0)))
          (should (eq 'push-button (key-binding [mouse-1] nil nil pos)))
          (should (eq 'push-button (key-binding [mouse-2] nil nil pos)))
          (should (eq 'ignore (key-binding [double-mouse-1] nil nil pos)))
          (should (eq 'ignore (key-binding [triple-mouse-1] nil nil pos)))
          ;; The buttons above the box take a click the same way.
          (let ((toggle (harness-ui-tasks-test--toggle board)))
            (should (eq 'push-button (key-binding [mouse-1] nil nil toggle)))
            (should (eq 'ignore (key-binding [double-mouse-1] nil nil toggle))))
          ;; Pushed, it starts its task, point staying on the button.
          (goto-char (1+ pos))
          (push-button pos)
          (should (= (point) (1+ pos))))
        (harness-test-wait (lambda () (not (eq 'pending (plist-get (car (harness-call 'task/list default-directory))
                                                                    :state))))
                           5 "the task to start")))))

;;;; Notifications

(defvar harness-notifications-providers)
(defvar harness-tasks-notify-events)
(defvar harness-ui-tasks--focus)
(declare-function harness-ui-tasks--on-notification "harness-ui-tasks")

(ert-deftest harness-ui-tasks-notification-click-opens-the-task ()
  "A task's desktop notification, clicked, shows its card on the board.
All the way through: the task waits for review, the tasks-notify module
notifies, the system provider asks the UI over ACP, the UI shows it on
the desktop (stubbed here) and the click opens the board on the card."
  (harness-ui-tasks-test-with
    (harness-test-load-module 'notifications)
    (harness-test-load-module 'tasks-notify)
    (let ((harness-tasks-require-verification t)
          (harness-notifications-providers '(system))
          (harness-tasks-notify-events '(review done))
          (shown nil))
      (cl-letf (((symbol-function 'harness-notifications-desktop-notify)
                 (lambda (&rest params) (push params shown) (harness-resolved '(:backend test)))))
        (harness-ui-tasks-test--type-and-submit board "first task")
        (harness-ui-tasks-test--type-and-submit board "second task")
        (harness-test-wait (lambda () (= 2 (length shown))) 10 "both notifications")
        (let* ((first (cl-find-if (lambda (p) (string-search "first task" (plist-get p :title))) shown))
               (id (plist-get (cl-find "first task" (harness-call 'task/list dir)
                                       :key (lambda (task) (plist-get task :prompt)) :test #'equal)
                              :id)))
          (should (equal "Ready for review: first task" (plist-get first :title)))
          (harness-ui-tasks-test--wait-text board "second task")
          (with-current-buffer board (goto-char (point-max)))
          ;; The click.
          (funcall (plist-get first :on-action))
          (harness-test-wait (lambda () (with-current-buffer board
                                          (equal id (get-text-property (point) 'harness-task-id))))
                             5 "point on the card")
          (should (eq board (window-buffer (selected-window))))
          (should-not (buffer-local-value 'harness-ui-tasks--focus board)))))))

(ert-deftest harness-ui-tasks-notification-for-a-card-not-shown-yet ()
  "A click before the board has the task waits for it, a while."
  (harness-ui-tasks-test-with
    (should-not (harness-ui-tasks--on-notification '(:session "s1")))
    (should (harness-ui-tasks--on-notification (list :task "t-later" :project dir)))
    (with-current-buffer board
      (should (equal "t-later" (car harness-ui-tasks--focus)))
      ;; Long past: the board forgets it.
      (setq harness-ui-tasks--focus (cons "t-later" (- (float-time) 60)))
      (harness-ui-tasks--render)
      (should-not harness-ui-tasks--focus))))

;;;; Subtitles

(defun harness-ui-tasks-test--recap (board id text)
  "Put TEXT as the recap of task ID, wait for BOARD to have it, render."
  (harness-call 'task/set-recap id :recap text :recap-at (float-time))
  (harness-test-wait
   (lambda () (with-current-buffer board
                (equal text (plist-get (harness-ui-tasks--find id) :recap))))
   5 "the recap to reach the board")
  (with-current-buffer board (harness-ui-tasks--render)))

(ert-deftest harness-ui-tasks-subtitles-folded-in-most-columns ()
  "A pending card is one line: its recap shows only when you ask for it."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "Fold the recap")
      (harness-ui-tasks-test--wait-text board "Pending\\(.\\|\n\\)*Fold the recap")
      (let* ((id (plist-get (car (harness-call 'task/list default-directory)) :id))
             (harness-ui-tasks--subtitles nil))
        (harness-ui-tasks-test--recap board id "Wrote the pager and its tests.")
        ;; Folded: no recap, and not even the old detail line: one line.
        (should-not (string-match-p "Wrote the pager" (harness-ui-tasks-test--board-text board)))
        (should-not (string-match-p "in line" (harness-ui-tasks-test--board-text board)))
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Fold the recap")
          (call-interactively #'harness-ui-tasks-toggle-subtitle))
        (should (string-match-p "Wrote the pager and its tests"
                                (harness-ui-tasks-test--board-text board)))
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Fold the recap")
          (call-interactively #'harness-ui-tasks-toggle-subtitle))
        (should-not (string-match-p "Wrote the pager" (harness-ui-tasks-test--board-text board)))))))

(ert-deftest harness-ui-tasks-needs-input-shows-the-recap ()
  "The needs-input column shows the recap, with the request beside it."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type tool-call :id "demo-q" :name "ask_user"
                    :input (:question "Which colour?" :options ("red" "green")))
             (:type text :delta "Noted.")
             (:type done :stop-reason end-turn))))
      (harness-test-load-module 'tools-agent)
      (harness-ui-tasks-test--type-and-submit board "Pick a colour")
      (harness-ui-tasks-test--wait-text board "Requires your input\\(.\\|\n\\)*has a question for you")
      (let* ((id (plist-get (car (harness-call 'task/list default-directory)) :id))
             (harness-ui-tasks--subtitles nil))
        (harness-ui-tasks-test--recap board id "Read the palette code; one choice is left.")
        (let ((text (harness-ui-tasks-test--board-text board)))
          (should (string-match-p "Read the palette code" text))
          (should (string-match-p "has a question for you" text)))
        ;; Even here you can fold it away, and unfold it again.
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Pick a colour")
          (call-interactively #'harness-ui-tasks-toggle-subtitle))
        (should-not (string-match-p "Read the palette code" (harness-ui-tasks-test--board-text board)))
        (should-not (string-match-p "has a question for you" (harness-ui-tasks-test--board-text board)))
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Pick a colour")
          (call-interactively #'harness-ui-tasks-toggle-subtitle))
        (should (string-match-p "Read the palette code" (harness-ui-tasks-test--board-text board)))))))

(ert-deftest harness-ui-tasks-review-card-folded ()
  "A card waiting for review hides its recap by default too."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-ui-tasks--subtitles nil))
      (harness-ui-tasks-test--type-and-submit board "Send for review")
      (harness-ui-tasks-test--wait-text board "Ready for review\\(.\\|\n\\)*Send for review")
      (let ((id (plist-get (car (harness-call 'task/list default-directory)) :id)))
        (harness-ui-tasks-test--recap board id "Added the endpoint and its tests.")
        (should-not (string-match-p "Added the endpoint" (harness-ui-tasks-test--board-text board)))))))

(ert-deftest harness-ui-tasks-tab-toggles-the-subtitle-and-keeps-point ()
  "TAB shows and hides a card's recap; a card that shrank keeps point."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "Keep my point")
      (harness-ui-tasks-test--wait-text board "Pending\\(.\\|\n\\)*Keep my point")
      (let* ((id (plist-get (car (harness-call 'task/list default-directory)) :id))
             (harness-ui-tasks--subtitles nil))
        (harness-ui-tasks-test--recap board id "A recap line to fold.")
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Keep my point")
          (harness-ui-tasks-tab)
          (should (string-match-p "A recap line to fold" (harness-ui-tasks-test--board-text board)))
          ;; Fold from the second line: point stays on the card.
          (goto-char (point-min))
          (search-forward "A recap line to fold")
          (harness-ui-tasks-tab)
          (should (equal id (get-text-property (point) 'harness-task-id)))
          (should-not (string-match-p "A recap line to fold"
                                      (harness-ui-tasks-test--board-text board))))))))

;;;; A board taller than its window fits by capping its sections

(defun harness-ui-tasks-test--fake-done (board n)
  "Put N completed tasks on BOARD, as the harness's own store would."
  (with-current-buffer board
    (setq harness-ui-tasks--tasks
          (append harness-ui-tasks--tasks
                  (cl-loop for i below n
                           collect (list :id (format "t-fake%03d" i)
                                         :project harness-ui-tasks--project
                                         :cwd harness-ui-tasks--dir
                                         :prompt (format "Completed task %d: tidy the orders API" i)
                                         :state "done" :column "done" :merged t
                                         :created (- (float-time) (* 3600 i))
                                         :started (- (float-time) (* 3600 i) -60)
                                         :finished (- (float-time) (* 3600 i) -900)
                                         :verified-at (- (float-time) (* 3600 i) -1000)))))))

(defun harness-ui-tasks-test--fits-p (board)
  "Non-nil when BOARD's buffer fits the window it is shown in."
  (with-current-buffer board
    (harness-ui-tasks--fits-p (harness-ui-tasks--window))))

(ert-deftest harness-ui-tasks-long-board-caps-its-sections ()
  "A board taller than its window holds the least urgent cards back.
The completed section says how many it holds and offers to show them,
the whole buffer fits the window, and [Show all] opens the section
again with [Show fewer] to fold it back.  The frame is made taller for
the test: a batch window is too short for the headings alone."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (unwind-protect
        (progn
          (set-frame-height nil 40)
          (let ((window (get-buffer-window board)))
            (should window)
            (select-window window)
            (with-current-buffer board
              (harness-ui-tasks--render t)
              (redisplay t)
              (should (harness-ui-tasks--fits-p window))
              (should (<= (marker-position harness-compose-end) (window-end window t)))
              (should (string-match-p "more +\\[Show all\\]" (harness-ui-tasks-test--board-text board)))
              (should-not (string-match-p "Completed task 59" (harness-ui-tasks-test--board-text board)))
              ;; The line belongs to its section, and opens it whole.
              (goto-char (point-min))
              (search-forward "[Show all]")
              (goto-char (line-beginning-position))
              (call-interactively #'harness-ui-tasks-show-all)
              (should (memq 'done harness-ui-tasks--expanded))
              (should (string-match-p "Completed task 59" (harness-ui-tasks-test--board-text board)))
              (should (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))
              (search-forward "[Show fewer]")
              (goto-char (line-beginning-position))
              (call-interactively #'harness-ui-tasks-show-fewer)
              (should-not (memq 'done harness-ui-tasks--expanded))
              (should (string-match-p "more +\\[Show all\\]" (harness-ui-tasks-test--board-text board)))))
      (set-frame-height nil 25)))))

(ert-deftest harness-ui-tasks-typing-outlives-a-board-redraw ()
  "The box keeps point and the window after the board is drawn again.
The board is redrawn on every tick and on every task event; before, a
board taller than its window read as one that fit, the window was
scrolled to the top and point was dragged out of the box with it."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (unwind-protect
        (progn
          (set-frame-height nil 40)
          (let ((window (get-buffer-window board)))
            (should window)
            (select-window window)
            (with-current-buffer board
              ;; A box of more than one line, to be sure the tail is measured.
              (harness-compose-set "one\\ntwo\\nthree")
              (goto-char harness-compose-end)
              (harness-ui-tasks--render t)
              (redisplay t)
              (should (harness-ui-tasks--fits-p window))
              (should (harness-compose-in-p (window-point window)))
              (should (<= (marker-position harness-compose-end) (window-end window t)))
              ;; The same with the board redrawn while the box is typed in.
              (goto-char harness-compose-end)
              (insert "!")
              (harness-ui-tasks--render t)
              (redisplay t)
              (should (equal "one\\ntwo\\nthree!" (harness-compose-text)))
              (should (harness-compose-in-p (window-point window)))
              (should (<= (marker-position harness-compose-end) (window-end window t)))))
      (set-frame-height nil 25)))))

(provide 'harness-ui-tasks-test)
;;; harness-ui-tasks-test.el ends here
