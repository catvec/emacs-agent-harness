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
(defvar harness-acp-server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--tasks)
(defvar harness-ui-tasks--compose-start)
(defvar harness-ui-tasks--compose-end)
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
    (goto-char harness-ui-tasks--compose-end)
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
      (should (= harness-ui-tasks--compose-start harness-ui-tasks--compose-end))
      (should (string-match-p "Tasks" (harness-ui-tasks--header)))
      (should-not (buffer-modified-p)))))

(ert-deftest harness-ui-tasks-submit-runs-to-completed ()
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--type-and-submit board "Fix the flaky test")
    (with-current-buffer board
      (should (string-empty-p (buffer-substring-no-properties harness-ui-tasks--compose-start
                                                              harness-ui-tasks--compose-end))))
    (harness-ui-tasks-test--wait-text board "Completed  1\\(.\\|\n\\)*Fix the flaky test")
    (should (string-match-p "1 done" (with-current-buffer board (harness-ui-tasks--header))))))

(ert-deftest harness-ui-tasks-compose-survives-redraws ()
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (goto-char harness-ui-tasks--compose-end)
      (insert "half typed")
      (let ((offset (- (point) harness-ui-tasks--compose-start)))
        (harness-ui-tasks--render)
        (harness-ui-tasks--render)
        (should (equal "half typed" (buffer-substring-no-properties harness-ui-tasks--compose-start
                                                                   harness-ui-tasks--compose-end)))
        (should (= offset (- (point) harness-ui-tasks--compose-start)))))))

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
        (should (equal "First draft" (buffer-substring-no-properties harness-ui-tasks--compose-start
                                                                     harness-ui-tasks--compose-end)))
        (delete-region harness-ui-tasks--compose-start harness-ui-tasks--compose-end)
        (goto-char harness-ui-tasks--compose-start)
        (insert "Second draft")
        (harness-ui-tasks-submit)
        (should-not harness-ui-tasks--target))
      (harness-test-wait (lambda () (equal "Second draft"
                                           (plist-get (car (harness-call 'task/list default-directory)) :prompt)))
                         5 "the prompt to change"))))

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
        (goto-char harness-ui-tasks--compose-end)
        (should (eq 'self-insert-command (key-binding (kbd "s"))))
        (should (eq 'harness-ui-tasks-submit (key-binding (kbd "C-c C-c"))))))))

(defvar harness-ui-open-session-function)
(defvar harness-ui-default-position)
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

(provide 'harness-ui-tasks-test)
;;; harness-ui-tasks-test.el ends here
