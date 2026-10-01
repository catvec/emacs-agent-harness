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
(defvar harness-provider-demo-delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-ui-default-position)
(defvar harness-acp-server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--tasks)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-tasks--target)
(defvar harness-ui-tasks--list-end)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks-edit "harness-ui-tasks")
(declare-function harness-ui-tasks--header "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-acp--drop-client "harness-acp")

(defmacro harness-ui-tasks-test-with (&rest body)
  "Load the state layer, tasks, ACP and the board UI; run BODY with `board' open."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (setq harness-tasks--loaded t harness-acp--clients nil)
     (let ((harness-provider-demo-delay 0.005)
           (harness-provider-demo-script-override
            '((:type text :delta "Working on it.") (:type done :stop-reason end-turn)))
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
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
    (should (string-match-p "✓ 1\\|done 1" (with-current-buffer board (harness-ui-tasks--header))))))

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
      (goto-char harness-compose-end)
      ;; The ordinary commands change the settings of the next task.
      (should (consp (harness-ui--setting-target nil)))
      (let ((before (plist-get harness-ui-tasks--new :non-interactive)))
        (harness-toggle-non-interactive)
        (should (eq (not before) (plist-get harness-ui-tasks--new :non-interactive))))
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
      (should-not (plist-get session :non-interactive))
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
      (let ((prompt (save-excursion (goto-char harness-compose-start) (line-beginning-position))))
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

(provide 'harness-ui-tasks-test)
;;; harness-ui-tasks-test.el ends here
