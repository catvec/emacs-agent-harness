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
(defvar harness-agent--cancel-grace)
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
(defvar harness-anthropic-admin-api-key)
(defvar auth-sources)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--tasks)
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-tasks--target)
(defvar harness-ui-tasks--list-end)
(defvar harness-ui-tasks--error)
(defvar harness-ui-tasks--collapse-min-width)
(defvar harness-ui-tasks--fitting)
(defvar harness-ui-tasks--main-tree-mode)
(defvar harness-ui-tasks--priority-mode)
(declare-function harness-ui-tasks--held "harness-ui-tasks")
(declare-function harness-ui-tasks--caps-that-fit "harness-ui-tasks")
(declare-function harness-ui-cache-session "harness-ui")
(declare-function harness-ui-refresh-sessions "harness-ui")
(declare-function harness-ui-session "harness-ui")
(declare-function harness-ui--forget-session "harness-ui")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks-edit "harness-ui-tasks")
(declare-function harness-ui-tasks--header "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
(declare-function harness-ui-tasks-toggle-subtitle "harness-ui-tasks")
(declare-function harness-ui-tasks-tab "harness-ui-tasks")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-ui-session-live "harness-ui")
(declare-function harness-ui--store-live "harness-ui")
(declare-function harness-ui-tasks--board-key "harness-ui-tasks")
(declare-function harness-ui-tasks--card-buttons "harness-ui-tasks")
(declare-function harness-chat-buffer "harness-ui-chat" (id))

(defvar harness-chat--loading)
(defvar harness-chat-placeholder)

(defmacro harness-ui-tasks-test-with (&rest body)
  "Load the state layer, the priority plugin, tasks, ACP and the board UI; run BODY.
BODY runs with `board' open.  Finished tasks are completed at once,
without review, unless BODY turns `harness-tasks-require-verification'
on.  The priority plugin is named on purpose: a task's priority is its
session's, and a `+` or `-` on a card goes through its `priority/set'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent priority tasks acp))
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
           ;; A budget over everything fetches Anthropic's cost report in
           ;; the background, and the header's budgets show one: no key
           ;; may reach a real one.
           (harness-anthropic-admin-api-key nil)
           (auth-sources nil)
           (process-environment (cons "ANTHROPIC_ADMIN_KEY" process-environment))
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
    ;; The column's heading counts it: the header does not.
    (should-not (string-match-p "✓ 1\\|done 1" (with-current-buffer board (harness-ui-tasks--header most-positive-fixnum))))))

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

(defun harness-ui-tasks-test--help-at (board regexp)
  "The `help-echo' of the text in BOARD's board region that REGEXP matches, or nil."
  (with-current-buffer board
    (save-excursion
      (goto-char (point-min))
      (and (re-search-forward regexp harness-ui-tasks--list-end t)
           (get-text-property (match-beginning 0) 'help-echo)))))

(ert-deftest harness-ui-tasks-card-shows-the-average-output-rate ()
  "A card says how fast its session wrote on average, once the harness timed it.
The figure is the output of the session's measured model calls over the
seconds they streamed, the totals `:stream-output' and `:stream-seconds'
of its usage, which come with the session; the card words it as an
average, and its tooltip names the current rate beside it once the
harness's `usage/rate-updated' event brings one."
  (harness-ui-tasks-test-with
    ;; A turn that never ends keeps the task in progress.
    (let ((harness-provider-demo-script-override '((:type text :delta "Working on it."))))
      (unwind-protect
          (progn
            (harness-ui-tasks-test--type-and-submit board "Write quickly")
            (harness-ui-tasks-test--wait-text board "In progress  1\\(.\\|\n\\)*Write quickly")
            (should-not (string-match-p "tok/s" (harness-ui-tasks-test--board-text board)))
            (let ((sid (plist-get (car (harness-call 'task/list default-directory)) :session)))
              (should sid)
              (harness-call 'session/usage-note sid (list :stream-output 420 :stream-seconds 10.0))
              (harness-ui-tasks-test--wait-text board "Write quickly\\(.\\|\n\\)*42 tok/s avg")
              ;; Not the wording of the current rate, "42 tok/s".
              (should-not (string-match-p "tok/s\\($\\| ·\\)" (harness-ui-tasks-test--board-text board)))
              ;; The tooltip says what the figure is, and no current rate was measured yet.
              (let ((help (harness-ui-tasks-test--help-at board "42 tok/s avg")))
                (should (string-prefix-p "Average output rate over the whole session: 42 tokens per second,"
                                         help))
                (should-not (string-match-p "measured at" help)))
              ;; The harness measures the current rate: the tooltip follows.
              (harness-emit 'usage/rate-updated sid
                            (list :rate 61.0 :output 610 :seconds 10.0 :calls 1
                                  :at (float-time) :model "demo:scripted"))
              (harness-test-wait (lambda ()
                                   (with-current-buffer board (harness-ui-tasks--render))
                                   (string-match-p "Output rate: 61 tokens per second"
                                                   (or (harness-ui-tasks-test--help-at board "42 tok/s avg") "")))
                                 5 "the current rate in the tooltip")))
        (dolist (task (harness-call 'task/list default-directory))
          (harness-call 'task/cancel (plist-get task :id)))))))

(ert-deftest harness-ui-tasks-card-shows-the-token-figures ()
  "A working task's card shows its session's token figures as they grow.
They come with the harness's `usage/live-updated' events, which redraw
the board by themselves, at most every half second, and not while the
cards read the same.  A card short of room leaves them out first,
keeping its other facts and its buttons."
  (harness-ui-tasks-test-with
    ;; A turn that never ends keeps the task in progress.
    (let ((harness-provider-demo-script-override '((:type text :delta "Working on it."))))
      (unwind-protect
          (progn
            (harness-ui-tasks-test--type-and-submit board "Count the tokens")
            (harness-ui-tasks-test--wait-text board "In progress  1\\(.\\|\n\\)*Count the tokens")
            ;; Nothing counted yet: no figures.
            (should-not (string-match-p " out\\b\\|/[0-9.]+[kM]\\b" (harness-ui-tasks-test--board-text board)))
            (let ((sid (plist-get (car (harness-call 'task/list default-directory)) :session)))
              (should sid)
              (harness-emit 'usage/live-updated sid '(:context 2400 :output 600 :estimated 600))
              (harness-test-wait (lambda () (harness-ui-session-live sid)) 5 "the live figures")
              (let ((timer (buffer-local-value 'harness-ui-tasks--live-timer board)))
                (should (timerp timer))
                (harness-emit 'usage/live-updated sid '(:context 2440 :output 640 :estimated 640))
                (harness-test-wait (lambda () (= 640 (plist-get (harness-ui-session-live sid) :output)))
                                   5 "the grown figures")
                (should (eq timer (buffer-local-value 'harness-ui-tasks--live-timer board))))
              (harness-test-wait (lambda () (string-match-p "Count the tokens.* ~2\\.4k/[0-9.]+[kM] · ~640 out"
                                                            (harness-ui-tasks-test--board-text board)))
                                 5 "the live figures on the card")
              ;; Reported: the real numbers.
              (harness-emit 'usage/live-updated sid '(:context 2600 :output 800 :estimated 0))
              (harness-test-wait (lambda () (string-match-p "Count the tokens.* 2\\.6k/[0-9.]+[kM] · 800 out"
                                                            (harness-ui-tasks-test--board-text board)))
                                 5 "the reported figures on the card")
              ;; What the cards depend on changes only with what they read.
              (with-current-buffer board
                (let ((sessions (nth 1 (harness-ui-tasks--board-key))))
                  (harness-ui--store-live sid '(:context 2610 :output 800 :estimated 0))
                  (should (equal sessions (nth 1 (harness-ui-tasks--board-key))))
                  (harness-ui--store-live sid '(:context 2610 :output 810 :estimated 0))
                  (should-not (equal sessions (nth 1 (harness-ui-tasks--board-key))))))
              ;; Short of room, the card leaves the figures out first.
              (let* ((task (car (buffer-local-value 'harness-ui-tasks--tasks board)))
                     (buttons (substring-no-properties (harness-ui-tasks--card-buttons task)))
                     (lines (cl-loop for width from 160 downto harness-ui-tasks--collapse-min-width
                                     collect (cl-letf (((symbol-function 'harness-ui-tasks--width)
                                                        (lambda () width)))
                                               (with-temp-buffer
                                                 (harness-ui-tasks--insert-card task 'active nil)
                                                 (goto-char (point-min))
                                                 (buffer-substring-no-properties (point) (line-end-position))))))
                     (tokens (lambda (line) (string-search "810 out" line)))
                     (elapsed (lambda (line) (string-match-p " [0-9]+s\\b" line)))
                     (buttoned (lambda (line) (string-search buttons line))))
                (should (string-search "Count the tokens" (car lines)))
                (should (funcall tokens (car lines)))
                (should (funcall elapsed (car lines)))
                (should (funcall buttoned (car lines)))
                ;; Some widths keep the elapsed time and the buttons alone.
                (should (cl-some (lambda (line) (and (not (funcall tokens line)) (funcall elapsed line)
                                                     (funcall buttoned line)))
                                 lines))
                ;; The figures never show without the rest of the facts.
                (should-not (cl-some (lambda (line) (and (funcall tokens line) (not (funcall elapsed line))))
                                     lines)))))
        (dolist (task (harness-call 'task/list default-directory))
          (harness-call 'task/cancel (plist-get task :id)))))))

(ert-deftest harness-ui-tasks-stopped-task-needs-input ()
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (harness-ui-tasks-test--type-and-submit board "Break things")
      (harness-ui-tasks-test--wait-text board "Requires your input  1\\(.\\|\n\\)*stopped: error")
      ;; The column's heading counts it, in the attention face: the header does not.
      (should-not (string-match-p "need you" (with-current-buffer board
                                                (harness-ui-tasks--header most-positive-fixnum)))))))

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

(ert-deftest harness-ui-tasks-typing-goes-to-the-box ()
  "Typing on the board goes into the compose box, but for the board's keys.
A letter the board does not bind types into the box from anywhere on
the board, and so does a key for the task at point typed off a card,
which has no task to act on.  On a card that key acts on its task, and
the board's own keys stay its own off the cards."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--type-and-submit board "Waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  1")
      (with-current-buffer board
        ;; Keys reach the buffer of the selected window.
        (should (eq board (window-buffer (selected-window))))
        (cl-flet ((off-card ()
                    (goto-char (point-min))
                    (search-forward "nothing working")
                    (should-not (get-text-property (point) 'harness-task-id))))
          ;; Start, edit, message, verify, what it needs; and no key at all.
          (dolist (key '("s" "e" "m" "v" "SPC" "h"))
            (off-card)
            (execute-kbd-macro (kbd key))
            (should (= (point) harness-compose-end)))
          (should (equal "semv h" (harness-compose-text)))
          (off-card)
          (should (eq 'harness-ui-tasks-refresh (key-binding "g")))
          (should (eq 'harness-ui-quit-view (key-binding "q")))
          (should (eq 'harness-ui-tasks-compose (key-binding "a")))
          ;; Help still lists the task's keys, wherever point is.
          (goto-char harness-compose-end)
          (should (string-match-p "harness-ui-tasks-verify"
                                  (substitute-command-keys "\\{harness-ui-tasks-board-map}")))
          ;; On the card, `e' edits its task's prompt in the box.
          (harness-compose-set "")
          (goto-char (point-min))
          (search-forward "Waiting task")
          (should (get-text-property (point) 'harness-task-id))
          (execute-kbd-macro "e")
          (should (equal "Waiting task" (harness-compose-text))))))))

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

(ert-deftest harness-ui-tasks-dropped-link-goes-with-the-task ()
  "A link dropped on the board downloads behind a chip, then goes with the task."
  (skip-unless (executable-find "curl"))
  (harness-ui-tasks-test-with
    (let ((server (harness-test-http-serve
                   `(("/shot.png" 200 (("Content-Type" . "image/png")) ,harness-test-png :chunks 2 :delay 0.3)))))
      (unwind-protect
          (let ((window (get-buffer-window board)))
            (with-current-buffer board
              (should (eq 'harness-compose-yank (key-binding (kbd "C-y")))))
            (dnd-handle-multiple-urls window (list (harness-test-http-url server "/shot.png")) 'private)
            (with-current-buffer board
              ;; The chip of the download is on the attachments line.
              (let ((pos (text-property-not-all (point-min) (point-max) 'harness-compose-pending nil)))
                (should pos)
                (should (eq 'attachments (get-text-property pos 'harness-task-tail))))
              (harness-test-wait (lambda () (not (plist-get (car harness-compose-attachments) :pending))) 10 "the download")
              (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
              (goto-char harness-compose-end)
              (insert "Look at the screenshot")
              (harness-ui-tasks-submit)
              (should-not harness-compose-attachments))
            (harness-test-wait (lambda () (car (harness-call 'task/list default-directory))) 5 "the task")
            (should (string-suffix-p "downloads/shot.png"
                                     (plist-get (car (plist-get (car (harness-call 'task/list default-directory)) :attachments))
                                                :path))))
        (delete-process server)))))

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

;;;; Commands that change every session and task

(defvar harness-non-interactive)
(defvar harness-model)
(defvar harness-tasks-non-interactive)
(declare-function harness-set-non-interactive-all "harness-ui")
(declare-function harness-set-model-all "harness-ui")

(defun harness-ui-tasks-test--open-board (directory)
  "Open the board of DIRECTORY; return it once it has its tasks and settings."
  (let ((board (harness-tasks directory)))
    (harness-test-wait (lambda () (with-current-buffer board
                                    (and (not harness-ui-tasks--loading) harness-ui-tasks--new)))
                       5 "the board to load")
    board))

(defun harness-ui-tasks-test--said (said prefix)
  "Wait until a message in the list SAID holds starts with PREFIX; return it.
SAID is a function returning the messages said so far."
  (harness-test-wait (lambda () (cl-find-if (lambda (m) (string-prefix-p prefix m)) (funcall said)))
                     5 (format "a message saying %s" prefix)))

(defun harness-ui-tasks-test--hint-count (sid text)
  "How many hints of session SID say TEXT."
  (cl-count-if (lambda (n) (and (eq (plist-get n :kind) 'hint) (equal (plist-get n :content) text)))
               (harness-call 'session/nodes sid)))

(ert-deftest harness-ui-tasks-set-all-reaches-every-project ()
  "The all-sessions commands reach every project and every open board.
`harness-set-non-interactive-all' turns non-interactive on for the
sessions and the current tasks here and in another project, for both
boards' next tasks and, as the default, for new sessions, and says what
keeps new work there interactive all the same.  With a prefix argument
it turns it off for them all and leaves the default alone.
`harness-set-model-all' switches the sessions and tasks of both
projects too, each session once, and both boards' next tasks.  Every
task has its session from submission, so the five sessions changed
include the two waiting tasks' (the two the test names, the started
task's, and those two): a waiting task's settings are its session's."
  (harness-ui-tasks-test-with
    (harness-test-load-module 'compaction)
    (harness-test-load-module 'handoff)
    (let* ((harness-provider-demo--delay 5)   ; a started task keeps running
           (harness-tasks-max-running 0)
           (harness-tasks-non-interactive nil)
           (harness-non-interactive nil)
           (harness-model harness-model)
           (other (harness-test-temp-dir))
           (messages nil)
           (said (lambda () messages))
           (saved nil)
           (other-board nil)
           (tasks nil)
           (sessions nil))
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (when format-string (push (apply #'format format-string args) messages))
                    (apply orig format-string args)))
                 ((symbol-function 'harness-save-user-option)
                  (lambda (symbol value) (set symbol value) (push (cons symbol value) saved))))
        (unwind-protect
            (progn
              ;; The other project keeps its new sessions interactive.
              (with-temp-file (expand-file-name ".dir-locals.el" other)
                (prin1 '((nil . ((harness-non-interactive . nil)))) (current-buffer)))
              (setq other-board (harness-ui-tasks-test--open-board other))
              (harness-test-wait (lambda () (buffer-local-value 'harness-ui-tasks--new board)) 5 "the settings")
              (setq tasks (list (plist-get (harness-call 'task/submit dir "waiting here") :id)
                                (plist-get (harness-call 'task/submit other "waiting there") :id)
                                (plist-get (harness-call 'task/submit other "running there") :id)))
              (harness-call 'task/start (nth 2 tasks))
              (setq sessions (list (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id)
                                   (plist-get (harness-call 'session/create :cwd other :model "demo:scripted") :id)
                                   (plist-get (harness-call 'task/get (nth 2 tasks)) :session)))
              (should (cl-every #'stringp sessions))
              (dolist (b (list board other-board))
                (should-not (plist-get (buffer-local-value 'harness-ui-tasks--new b) :non-interactive)))
              ;; On, offered first, for everything.
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt table _pred _require _initial _hist def)
                           (should (equal '("on" "off") (all-completions "" table)))
                           def)))
                (call-interactively #'harness-set-non-interactive-all))
              (let ((report (harness-ui-tasks-test--said said "Non-interactive on")))
                (should (string-prefix-p (concat "Non-interactive on for 5 sessions and 3 tasks, and for new"
                                                 " sessions and the open boards' new tasks.  But new sessions in ")
                                         report))
                (should (string-search (format " start interactive (harness-non-interactive in %s)"
                                               (abbreviate-file-name (expand-file-name ".dir-locals.el" other)))
                                       report)))
              (dolist (sid sessions)
                (should (plist-get (harness-call 'session/get sid) :non-interactive))
                (should (= 1 (harness-ui-tasks-test--hint-count sid "non-interactive on"))))
              (dolist (id tasks)
                (should (eq t (plist-get (harness-call 'task/get id) :non-interactive))))
              (dolist (b (list board other-board))
                (should (eq t (plist-get (buffer-local-value 'harness-ui-tasks--new b) :non-interactive))))
              (should (equal '((harness-non-interactive . t)) saved))
              ;; Off with a prefix argument: the default stays on.  The task
              ;; default turns new tasks on all the same, and it says so.
              (setq messages nil)
              (let ((harness-tasks-non-interactive t))
                (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "off")))
                  (harness-set-non-interactive-all t))
                (let ((report (harness-ui-tasks-test--said said "Non-interactive off")))
                  (should (equal (concat "Non-interactive off for 5 sessions and 3 tasks, and for the open boards'"
                                         " new tasks.  But new tasks start non-interactive"
                                         " (harness-tasks-non-interactive); M-x harness-settings changes them.")
                                 report))))
              (should (equal '((harness-non-interactive . t)) saved))
              (should (eq t harness-non-interactive))
              (dolist (sid sessions)
                (should-not (plist-get (harness-call 'session/get sid) :non-interactive))
                (should (= 1 (harness-ui-tasks-test--hint-count sid "non-interactive off"))))
              (dolist (id tasks)
                (should (eq :false (plist-get (harness-call 'task/get id) :non-interactive))))
              (dolist (b (list board other-board))
                (should-not (plist-get (buffer-local-value 'harness-ui-tasks--new b) :non-interactive)))
              ;; A model for everything, each session switched once.
              (setq messages nil)
              (cl-letf (((symbol-function 'harness-ui-choose-model)
                         (lambda (callback) (funcall callback "demo:other" "Other (Demo)"))))
                (harness-set-model-all))
              (let ((report (harness-ui-tasks-test--said said "Model → Other (Demo)")))
                (should (string-prefix-p (concat "Model → Other (Demo) for 5 sessions and 3 tasks, and for new"
                                                 " sessions and the open boards' new tasks.  But new tasks start on ")
                                         report))
                (should (string-search "(harness-tasks-model)" report)))
              (should (equal "demo:other" harness-model))
              (dolist (sid sessions)
                (should (equal "demo:other" (plist-get (harness-call 'session/get sid) :model)))
                (should (= 1 (harness-ui-tasks-test--hint-count sid "model → demo:other"))))
              (dolist (id tasks)
                (should (equal "demo:other" (plist-get (harness-call 'task/get id) :model))))
              (dolist (b (list board other-board))
                (should (equal "demo:other" (plist-get (buffer-local-value 'harness-ui-tasks--new b) :model)))))
          (ignore-errors (harness-call 'task/cancel (nth 2 tasks)))
          (when (buffer-live-p other-board) (kill-buffer other-board))
          (delete-directory other t))))))

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
      (harness-test-load-module 'tools-question)
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

(declare-function harness-compose-set "harness-ui-compose")

(ert-deftest harness-ui-tasks-answer-mentioning-a-file-goes-as-text ()
  "An answer naming a file with @ goes as the text it is.
The box's own attachments go with it: a screenshot the answer names by
its token reaches the model with the answer, in a message of the
user's that the turn takes with the ask_user result.  The box empties."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type tool-call :id "demo-q" :name "ask_user"
                    :input (:question "Which file?" :options ("notes.txt" "none")))
             (:type text :delta "Noted.")
             (:type done :stop-reason end-turn)))
          (notes (expand-file-name "notes.txt" dir))
          (png (expand-file-name "shot.png" dir)))
      (harness-test-load-module 'tools-question)
      (with-temp-file notes (insert "Some notes\n"))
      (let ((coding-system-for-write 'binary)) (write-region harness-test-png nil png nil 'silent))
      (harness-ui-tasks-test--type-and-submit board "Pick a file")
      (harness-ui-tasks-test--wait-text board "Requires your input  1\\(.\\|\n\\)*has a question for you")
      (let ((sid (plist-get (car (harness-call 'task/list default-directory)) :session)))
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "Pick a file")
          (harness-ui-tasks-reply)
          (should (eq 'answer (car harness-ui-tasks--target)))
          (goto-char harness-compose-end)
          (insert "@notes.txt, as")
          (harness-compose-add-attachment png)
          (goto-char harness-compose-end)
          (insert "shows")
          (harness-ui-tasks-submit)
          (should (equal "" (harness-compose-text)))
          (should-not harness-compose-attachments))
        (harness-test-wait (lambda () (null (harness-call 'question/pending sid))) 5 "the question to be answered")
        (harness-ui-tasks-test--wait-text board "Completed  1")
        (let* ((nodes (harness-call 'session/nodes sid))
               (result (cl-find-if (lambda (n) (eq (plist-get n :kind) 'tool-result)) nodes))
               (steering (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering)) nodes)))
          (should (equal "@notes.txt, as [image 1] shows" (plist-get result :output)))
          ;; The screenshot, with the answer; the file the text names is no attachment.
          (should (equal (list (list :type "image" :mime "image/png"
                                     :data (base64-encode-string harness-test-png t) :label "image 1"))
                         (plist-get steering :blocks)))
          (should (equal (plist-get result :id) (plist-get (plist-get steering :meta) :delivered-after)))
          (should-not (string-match-p "Attached file" (format "%S" nodes))))))))

(declare-function harness-ui-task-title "harness-ui")
(declare-function harness-ui-tasks--task "harness-ui-tasks")

(ert-deftest harness-ui-tasks-at-attaches-the-task-at-point ()
  "@ on a card attaches its task to the box; off a card @ types.
The task's reference, @task:ID, goes into the box and its line above
it, once however often @ is pressed.  A new task submitted with it
gives its model the task as text: its id, title and prompt.  The keys
go through the command loop."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--type-and-submit board "Alpha: fix the login form")
    (harness-ui-tasks-test--wait-text board "Completed  1")
    (let ((alpha (harness-ui-tasks-test--card-id board "Alpha")))
      (with-current-buffer board
        (should (eq board (window-buffer (selected-window))))
        (harness-ui-tasks-test--goto-card board "Alpha")
        (should (eq 'harness-ui-tasks-attach (key-binding "@")))
        (let ((title (harness-ui-task-title (harness-ui-tasks--task))))
          (execute-kbd-macro "@")
          (should (equal (concat "@task:" alpha " ") (harness-compose-text)))
          (should (equal (list alpha) (mapcar (lambda (a) (plist-get a :task)) harness-compose-attachments)))
          (should (save-excursion (goto-char (point-min))
                                  (search-forward (concat alpha " · " title) harness-compose-start t))))
        ;; Once is enough.
        (harness-ui-tasks-test--goto-card board "Alpha")
        (execute-kbd-macro "@")
        (should (equal (concat "@task:" alpha " ") (harness-compose-text)))
        (should (= 1 (length harness-compose-attachments)))
        ;; Off a card, @ types into the box.
        (goto-char (point-min))
        (search-forward "nothing working")
        (should-not (get-text-property (point) 'harness-task-id))
        (execute-kbd-macro "@")
        (should (equal (concat "@task:" alpha " @") (harness-compose-text)))
        (should (= 1 (length harness-compose-attachments)))
        (harness-compose-set (concat "Bravo: see what @task:" alpha " did"))
        (harness-ui-tasks-submit)
        (should-not harness-compose-attachments))
      (harness-ui-tasks-test--wait-text board "Completed  2")
      (let* ((bravo (cl-find-if (lambda (task) (string-prefix-p "Bravo" (plist-get task :prompt)))
                                (harness-call 'task/list default-directory)))
             (nodes (format "%S" (harness-call 'session/nodes (plist-get bravo :session)))))
        (should (equal (list alpha) (mapcar (lambda (a) (plist-get a :task)) (plist-get bravo :attachments))))
        (should (string-search (concat "Task " alpha ", attached: ") nodes))
        (should (string-search "Prompt:\nAlpha: fix the login form" nodes))))))

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

(declare-function harness-compose--pre-command "harness-ui-compose")

(defun harness-ui-tasks-test--laid-out (thunk)
  "Call THUNK; return where it laid out text from, in order.
Each `window-text-pixel-size' and `vertical-motion' is noted by the
position it starts from, each `pos-visible-in-window-p' as `visible'."
  (let ((froms nil))
    (cl-letf* ((size (symbol-function 'window-text-pixel-size))
               ((symbol-function 'window-text-pixel-size)
                (lambda (&optional window from &rest rest)
                  (push (if (integer-or-marker-p from) (+ 0 from) from) froms)
                  (apply size window from rest)))
               (motion (symbol-function 'vertical-motion))
               ((symbol-function 'vertical-motion)
                (lambda (&rest args) (push (point) froms) (apply motion args)))
               (visible (symbol-function 'pos-visible-in-window-p))
               ((symbol-function 'pos-visible-in-window-p)
                (lambda (&rest args) (push 'visible froms) (apply visible args))))
      (funcall thunk))
    (nreverse froms)))

(defun harness-ui-tasks-test--box-alone-p (froms)
  "Non-nil when FROMS, from `harness-ui-tasks-test--laid-out', are all in the box."
  (cl-every (lambda (from) (and (integerp from) (>= from harness-compose-start))) froms))

(ert-deftest harness-ui-tasks-typing-lays-out-the-box-alone ()
  "A key typed in the box measures the box, not the window.
The box is kept at the bottom before every redisplay, so after every
key, and measuring the window from its top on each one made typing lag.
The window is measured again once something changed outside the box:
its text, with the change hooks running or not, but not text properties
put on silently, as `jit-lock' does all the time."
  (harness-ui-tasks-test-with
    (let ((window (get-buffer-window board)))
      (with-current-buffer board
        (goto-char harness-compose-end)
        (set-window-point window (point))
        (set-window-start window (point-min))
        (harness-compose-pad-window window)
        (cl-flet ((measure (change)
                    (harness-ui-tasks-test--laid-out
                     (lambda () (funcall change) (harness-compose-pad-window window)))))
          (dolist (c '("h" "i" " " "t" "h" "e" "r" "e"))
            (should (harness-ui-tasks-test--box-alone-p (measure (lambda () (insert c))))))
          (should (equal "hi there" (harness-compose-text)))
          ;; Changed outside the box: the window is measured again.
          (should (memq (point-min)
                        (measure (lambda () (let ((inhibit-read-only t))
                                              (save-excursion (goto-char (point-min)) (insert "x")))))))
          ;; Even with the change hooks inhibited.
          (should (memq (point-min)
                        (measure (lambda () (let ((inhibit-read-only t) (inhibit-modification-hooks t))
                                              (save-excursion (goto-char (point-min)) (delete-char 1)))))))
          ;; Not for a face put on silently, nor for nothing at all.
          (should (harness-ui-tasks-test--box-alone-p
                   (measure (lambda () (let ((inhibit-read-only t))
                                         (with-silent-modifications
                                           (put-text-property (point-min) (1+ (point-min)) 'face 'bold)))))))
          (should (harness-ui-tasks-test--box-alone-p (measure #'ignore))))))))

(ert-deftest harness-ui-tasks-typing-brings-the-box-back ()
  "Typing brings an out-of-sight box back, though it changes no height.
A letter typed with point on the board goes to the box; the first key
typed after the window scrolled goes where point is.  Either way the
window shows the box at its bottom again, and later keys measure the
box alone again."
  (harness-ui-tasks-test-with
    (let ((window (get-buffer-window board)))
      (with-current-buffer board
        (goto-char harness-compose-end)
        (insert (mapconcat #'identity (make-list 40 "a line") "\n"))
        ;; Point on the board, the window at its top.
        (goto-char (point-min))
        (set-window-point window (point-min))
        (set-window-start window (point-min))
        (harness-compose-pad-window window)
        (should (= (point-min) (window-start window)))
        (let ((this-command 'self-insert-command))
          (harness-compose--pre-command))
        (should (= (point) harness-compose-end))
        (insert "s")
        (set-window-point window (point))
        (harness-compose-pad-window window)
        (should (> (window-start window) (point-min)))
        ;; Scrolled by hand, the window stays put until a key is typed.
        (set-window-start window (point-min))
        (harness-compose-pad-window window)
        (should (= (point-min) (window-start window)))
        (insert "t")
        (harness-compose-pad-window window)
        (should (> (window-start window) (point-min)))
        (should (harness-ui-tasks-test--box-alone-p
                 (harness-ui-tasks-test--laid-out
                  (lambda () (insert "u") (harness-compose-pad-window window)))))))))

;;;; Submit, Refine or Plan: the backlog

(defvar harness-ui-tasks--mode)
(defvar harness-ui-tasks--settings)
(declare-function harness-ui-tasks-cycle-mode "harness-ui-tasks")
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
  "Which of Submit, Refine and Plan BOARD shows above its compose box."
  (with-current-buffer board
    (let ((head (buffer-substring-no-properties harness-ui-tasks--list-end
                                                (overlay-start harness-compose-overlay))))
      (seq-filter (lambda (mode) (string-search mode head)) '("Submit" "Refine" "Plan")))))

(defun harness-ui-tasks-test--toggle (board)
  "Where BOARD's Submit / Refine / Plan toggle is: the start of its label."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (let ((case-fold-search nil))
        (re-search-forward "Submit\\|Refine\\|Plan" (overlay-start harness-compose-overlay)))
      (match-beginning 0))))

(defun harness-ui-tasks-test--goto-card (board text)
  "Move point in BOARD to the card showing TEXT."
  (with-current-buffer board
    (goto-char (point-min))
    (search-forward text)))

(declare-function harness-ui-tasks-toggle-main-tree "harness-ui-tasks")
(declare-function harness-ui-tasks--render-tail "harness-ui-tasks")

(ert-deftest harness-ui-tasks-main-tree-switch ()
  "The worktree switch makes the next task work in the main tree, once.
A second click keeps it on until clicked off; a submission spends the
one-shot choice, so the next task is a worktree task again."
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
      (should (eq harness-ui-tasks--main-tree-mode 'once))
      (let ((tail (harness-ui-tasks-test--tail-text board)))
        (should (string-match-p "main tree" tail))
        (should (string-match-p "Main tree for the next task" tail))
        (should-not (string-match-p "no worktree" tail))))
    (harness-ui-tasks-test--type-and-submit board "Clean the checkout")
    (harness-ui-tasks-test--wait-text board "main tree")
    (let ((task (car (harness-call 'task/list default-directory))))
      (should (harness-json-true-p (plist-get task :main-tree))))
    ;; The one-shot choice is spent: the next task is a worktree task.
    (with-current-buffer board
      (should-not harness-ui-tasks--main-tree-mode)
      (should-not (harness-json-true-p (plist-get harness-ui-tasks--new :main-tree))))
    (harness-ui-tasks-test--type-and-submit board "Plain worktree task")
    (harness-ui-tasks-test--wait-text board "Plain worktree task")
    (let ((tasks (harness-call 'task/list default-directory)))
      (should-not (harness-json-true-p (plist-get (cadr tasks) :main-tree))))))

(declare-function harness-ui-tasks-raise-priority "harness-ui-tasks")
(declare-function harness-ui-tasks-lower-priority "harness-ui-tasks")
(declare-function harness-ui-tasks-cycle-new-priority "harness-ui-tasks")
(declare-function harness-ui-tasks--facts "harness-ui-tasks")
(declare-function harness-ui-tasks--actions "harness-ui-tasks")

(defun harness-ui-tasks-test--priority-actions (board text)
  "The priority entries of the actions of BOARD's card showing TEXT."
  (harness-ui-tasks-test--goto-card board text)
  (with-current-buffer board
    (seq-filter (lambda (label) (string-match-p "priority" label))
                (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task))))))

(ert-deftest harness-ui-tasks-pending-in-priority-order ()
  "Pending lists the waiting tasks as they will start: by priority, then oldest first.
A high or low card has an arrow before its title and no words for it
among its facts; medium goes without saying.  + and - on a card move its
priority a step, and the card moves with it; off a card they type."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-call 'task/submit default-directory "Alpha, low" (list :priority "low"))
      (harness-call 'task/submit default-directory "Bravo, medium")
      (harness-call 'task/submit default-directory "Charlie, high" (list :priority "high"))
      (harness-ui-tasks-test--wait-text board "Pending  3\\(.\\|\n\\)*Charlie\\(.\\|\n\\)*Bravo\\(.\\|\n\\)*Alpha")
      (should (string-match-p "↑ +Charlie, high" (harness-ui-tasks-test--card-text board "Charlie")))
      (should (string-match-p "↓ +Alpha, low" (harness-ui-tasks-test--card-text board "Alpha")))
      (should-not (string-match-p "[↑↓]" (harness-ui-tasks-test--card-text board "Bravo")))
      (with-current-buffer board
        (let ((facts (lambda (title)
                       (harness-ui-tasks--facts (cl-find title harness-ui-tasks--tasks
                                                         :key (lambda (task) (plist-get task :prompt))
                                                         :test #'equal)
                                                'pending nil))))
          ;; The arrow says it, so the facts are the queue's alone and
          ;; carry no words for the priority.
          (dolist (title '("Charlie, high" "Alpha, low" "Bravo, medium"))
            (should (equal '(time) (mapcar #'car (funcall facts title))))
            (should (string-prefix-p "queued" (cdr (assq 'time (funcall facts title)))))
            (should-not (string-match-p "priority" (cdr (assq 'time (funcall facts title))))))))
      (dolist (title '("Charlie" "Alpha" "Bravo"))
        (should-not (string-match-p "priority" (harness-ui-tasks-test--card-text board title))))
      ;; The place in line is the place it starts in.
      (harness-ui-tasks-test--show-subtitle board "Charlie")
      (harness-ui-tasks-test--show-subtitle board "Alpha")
      (should (string-match-p "#1 in line" (harness-ui-tasks-test--card-text board "Charlie")))
      (should (string-match-p "#3 in line" (harness-ui-tasks-test--card-text board "Alpha")))
      ;; The menu offers the steps there are.
      (should (equal '("Raise priority to high" "Lower priority to low")
                     (harness-ui-tasks-test--priority-actions board "Bravo")))
      (should (equal '("Lower priority to medium") (harness-ui-tasks-test--priority-actions board "Charlie")))
      (should (equal '("Raise priority to medium") (harness-ui-tasks-test--priority-actions board "Alpha")))
      ;; + raises Bravo to high: older than Charlie, it goes first now.
      (with-current-buffer board
        (should (eq board (window-buffer (selected-window))))
        (harness-ui-tasks-test--goto-card board "Bravo")
        (should (eq 'harness-ui-tasks-raise-priority (key-binding (kbd "+"))))
        (should (eq 'harness-ui-tasks-lower-priority (key-binding (kbd "-"))))
        (execute-kbd-macro "+"))
      (harness-ui-tasks-test--wait-text board "Pending  3\\(.\\|\n\\)*Bravo\\(.\\|\n\\)*Charlie\\(.\\|\n\\)*Alpha")
      (should (eq 'high (plist-get (harness-call 'task/get (harness-ui-tasks-test--card-id board "Bravo"))
                                   :priority)))
      (should (string-match-p "↑ +Bravo" (harness-ui-tasks-test--card-text board "Bravo")))
      ;; Nothing above high, nothing below low.
      (harness-ui-tasks-test--goto-card board "Bravo")
      (with-current-buffer board (should-error (harness-ui-tasks-raise-priority) :type 'user-error))
      (harness-ui-tasks-test--goto-card board "Alpha")
      (with-current-buffer board (should-error (harness-ui-tasks-lower-priority) :type 'user-error))
      ;; - takes Charlie down to medium, after Bravo still, its arrow gone.
      (with-current-buffer board
        (harness-ui-tasks-test--goto-card board "Charlie")
        (execute-kbd-macro "-"))
      (harness-test-wait (lambda ()
                           (with-current-buffer board (harness-ui-tasks--render))
                           (not (string-match-p "[↑↓]" (harness-ui-tasks-test--card-text board "Charlie"))))
                         5 "Charlie's arrow to go")
      (should (eq 'medium (plist-get (harness-call 'task/get (harness-ui-tasks-test--card-id board "Charlie"))
                                     :priority)))
      (should (string-match-p "Pending  3\\(.\\|\n\\)*Bravo\\(.\\|\n\\)*Charlie\\(.\\|\n\\)*Alpha"
                              (harness-ui-tasks-test--board-text board)))
      ;; Off a card the keys type, into the compose box.
      (with-current-buffer board
        (harness-compose-set "")
        (goto-char (point-min))
        (search-forward "nothing working")
        (should-not (get-text-property (point) 'harness-task-id))
        (execute-kbd-macro "+")
        (execute-kbd-macro "-")
        (should (equal "+-" (harness-compose-text)))))))

(declare-function harness-ui-tasks--visible "harness-ui-tasks")

(defun harness-ui-tasks-test--column-ids (column)
  "The ids of the tasks the board shows in COLUMN, in its order."
  (mapcar (lambda (task) (plist-get task :id)) (cdr (assq column (harness-ui-tasks--visible)))))

(ert-deftest harness-ui-tasks-pending-follows-the-start-order ()
  "Pending lists the waiting tasks in the order the harness starts them.
That is `harness-tasks--start-order': by priority; within one, work
sent back from review first, then the tasks returned to the queue --
paused, pre-empted, their slot taken back -- the first returned first,
and only then the tasks that never started, oldest first.  The backlog
and Requires your input still go by priority, then the oldest,
whatever their tasks went through.  The tasks have the shape the wire
gives them, symbols as strings."
  (harness-ui-tasks-test-with
    (with-temp-buffer
      (setq-local harness-ui-tasks--tasks
                  (list (list :id "t-a" :state "pending" :column "pending" :priority "medium" :created 100)
                        (list :id "t-b" :state "pending" :column "pending" :priority "medium" :created 200)
                        (list :id "t-c" :state "pending" :column "pending" :priority "medium" :created 300
                              :returned 1000.5 :return-reason "preempted" :preempted-by "t-r")
                        (list :id "t-p" :state "pending" :column "pending" :priority "medium" :created 600
                              :returned 2000.0 :return-reason "returned")
                        (list :id "t-s" :state "pending" :column "pending" :priority "medium" :created 400
                              :returned 3000.0 :sent-back 3000.0 :return-reason "sent-back")
                        (list :id "t-h" :state "pending" :column "pending" :priority "high" :created 500)
                        (list :id "t-l" :state "pending" :column "pending" :priority "low" :created 10
                              :returned 900.0 :return-reason "returned")
                        (list :id "t-k1" :state "pending" :column "backlog" :backlog t
                              :priority "medium" :created 100)
                        (list :id "t-k2" :state "pending" :column "backlog" :backlog t
                              :priority "high" :created 200)
                        (list :id "t-n1" :state "active" :column "needs-input" :outcome "error"
                              :priority "medium" :created 100)
                        (list :id "t-n2" :state "active" :column "needs-input" :outcome "error"
                              :priority "medium" :created 200 :sent-back 5000.0)))
      ;; High first; then of medium the feedback, the pre-empted and the
      ;; paused task in the order they were returned, and the ones that
      ;; never started, oldest first; low last, returned or not.
      (should (equal '("t-h" "t-s" "t-c" "t-p" "t-a" "t-b" "t-l")
                     (harness-ui-tasks-test--column-ids 'pending)))
      (should (equal '("t-k2" "t-k1") (harness-ui-tasks-test--column-ids 'backlog)))
      (should (equal '("t-n1" "t-n2") (harness-ui-tasks-test--column-ids 'needs-input))))))

(ert-deftest harness-ui-tasks-pending-is-the-harness-line ()
  "The board's Pending is the line the harness starts tasks in.
Alpha and Bravo wait; Charlie, made after them, starts and is paused
back to the queue; then Hotel comes, high.  Pending shows Hotel,
Charlie, Alpha, Bravo -- as `task/queue-order' has them -- and
Charlie's card says it is #2 in line, and why."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-agent--cancel-grace 0.05)
          (harness-provider-demo-script-override '((:type wait :seconds 30))))
      (harness-call 'task/submit default-directory "Alpha, waiting")
      (harness-call 'task/submit default-directory "Bravo, waiting")
      (let* ((charlie (plist-get (harness-call 'task/submit default-directory "Charlie, paused") :id))
             (sid (plist-get (harness-call 'task/get charlie) :session)))
        (harness-call 'task/start charlie)
        (harness-test-wait (lambda () (harness-call 'agent/running sid)) 5 "Charlie at work")
        (harness-call 'task/return-to-pending charlie)
        (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 5 "Charlie's turn to stop"))
      (harness-call 'task/submit default-directory "Hotel, high" (list :priority "high"))
      (harness-ui-tasks-test--wait-text
       board "Pending  4\\(.\\|\n\\)*Hotel\\(.\\|\n\\)*Charlie\\(.\\|\n\\)*Alpha\\(.\\|\n\\)*Bravo")
      (with-current-buffer board
        (should (equal (mapcar (lambda (entry) (plist-get entry :id))
                               (harness-call 'task/queue-order default-directory))
                       (harness-ui-tasks-test--column-ids 'pending))))
      (harness-ui-tasks-test--show-subtitle board "Charlie")
      (should (string-match-p "#2 in line · paused"
                              (harness-ui-tasks-test--card-text board "Charlie"))))))

(ert-deftest harness-ui-tasks-click-the-priority-arrow ()
  "A click on a card's arrow asks for that task's session's priority.
The arrow is the priority UI's, so it carries the task's session id --
a task's priority being its session's -- and a click on it sets that
session's level, whatever card point is on."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-call 'task/submit default-directory "Click my arrow" (list :priority "high"))
      (harness-ui-tasks-test--wait-text board "Pending  1")
      (let* ((id (harness-ui-tasks-test--card-id board "Click my arrow"))
             (sid (plist-get (harness-call 'task/get id) :session))
             (pos (harness-ui-tasks-test--arrow-position board "Click my arrow")))
        (should (stringp sid))
        ;; The mark on the card is that arrow, and it names the session.
        (with-current-buffer board
          (should (equal sid (get-text-property pos 'harness-priority-session)))
          (should (keymapp (get-text-property pos 'keymap)))
          (should (eq 'harness-priority-high-face (get-text-property pos 'face))))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "low")))
          (harness-ui-tasks-test--goto-card board "Click my arrow")
          (with-current-buffer board
            (harness-ui-priority-click (list 'mouse-1 (list (selected-window) pos '(0 . 0) 0)))))
        (should (equal "low" (harness-call 'priority/get sid)))))))

(ert-deftest harness-ui-tasks-priority-goes-to-the-task-session ()
  "`+' and `-' on a card change the task's session's priority, not a task field.
A task's priority is its session's (`harness-priority-of-task'), so
the level changes on the session -- the `session/ext-changed' event
names it -- and no `:priority' is stored on the task.  A record from
before every task had a session has none to change, and is refused
rather than sent to the harness."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (changed nil))
      (harness-call 'task/submit default-directory "Alpha, low" (list :priority "low"))
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*↓ +Alpha, low")
      (let* ((id (harness-ui-tasks-test--card-id board "Alpha, low"))
             (sid (plist-get (harness-call 'task/get id) :session)))
        (should (stringp sid))
        (harness-on 'session/ext-changed
                    (lambda (session-id key value) (push (list session-id key value) changed)))
        ;; + raises it to medium: the change is the session's, and the
        ;; task's own record keeps no priority at all.
        (harness-ui-tasks-test--goto-card board "Alpha, low")
        (with-current-buffer board (harness-ui-tasks-raise-priority))
        (should (equal "medium" (harness-call 'priority/get sid)))
        (should (equal (list sid :priority "medium") (car changed)))
        (should-not (plist-member (gethash id harness-tasks--table) :priority))
        ;; The card follows (the board's own view of it), so the next
        ;; key moves from the level it now has.
        (harness-test-wait (lambda () (with-current-buffer board
                                        (equal "medium" (harness-ui-tasks--priority
                                                         (harness-ui-tasks--find id)))))
                           5 "the card to show medium")
        ;; - takes it back down.
        (setq changed nil)
        (harness-ui-tasks-test--goto-card board "Alpha, low")
        (with-current-buffer board (harness-ui-tasks-lower-priority))
        (should (equal "low" (harness-call 'priority/get sid)))
        (should (equal (list sid :priority "low") (car changed)))
        ;; A task with no session (a record from before every task had
        ;; one) has no priority to move: nothing is sent.
        (with-current-buffer board
          (setq harness-ui-tasks--tasks
                (mapcar (lambda (task)
                          (if (equal id (plist-get task :id))
                              (plist-put (copy-sequence task) :session nil)
                            task))
                        harness-ui-tasks--tasks)))
        (setq changed nil)
        (harness-ui-tasks-test--goto-card board "Alpha, low")
        (with-current-buffer board
          (should-error (harness-ui-tasks-raise-priority) :type 'user-error))
        (should-not changed)
        (should (equal "low" (harness-call 'priority/get sid)))))))

(ert-deftest harness-ui-tasks-priority-reload-follows-the-session ()
  "A session's `:priority' ext change reloads the board holding its task's card.
Nothing is stored on the task, so the new level arrives as the
session's `session/ext-changed' event and the board asks the harness
for the tasks again; another key of the same session, a session of no
task on the board, and the list of every session's change, do not."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (refreshed nil))
      (harness-call 'task/submit default-directory "Alpha" nil)
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Alpha")
      (let* ((sid (plist-get (harness-call 'task/get (harness-ui-tasks-test--card-id board "Alpha")) :session))
             (other (plist-get (harness-call 'session/create :cwd default-directory :name "elsewhere") :id)))
        (cl-letf (((symbol-function 'harness-ui-tasks--refresh-soon)
                   (lambda (buffer) (push (buffer-name buffer) refreshed))))
          ;; The priority of a task's session: the board reloads.
          (harness-ui-tasks--on-event "session/ext-changed" (list sid ":priority" "high"))
          (should (equal (list (buffer-name board)) refreshed))
          ;; Another key of it, and a session no card of the board shows.
          (setq refreshed nil)
          (harness-ui-tasks--on-event "session/ext-changed" (list sid ":supervisor" t))
          (harness-ui-tasks--on-event "session/ext-changed" (list other ":priority" "high"))
          (should-not refreshed)
          ;; The key the wire sends is a string, as it is for a keyword.
          (harness-ui-tasks--on-event "session/ext-changed" (list sid "priority" "low"))
          (should (equal (list (buffer-name board)) refreshed)))))))

(defun harness-ui-tasks-test--sessions-settled ()
  "Wait until the session list a board asks for as it opens has arrived.
It replaces the session cache, so a test that fills the cache waits first."
  (let (done)
    (harness-ui-refresh-sessions (lambda (_) (setq done t)))
    (harness-test-wait (lambda () done) 5 "the session list")))

(ert-deftest harness-ui-tasks-internal-sessions-reload-no-board ()
  "A session's creation, status change and deletion reload the board, unless it is internal.
The harness records each model call it makes on its own -- a judge, the
naming of a session -- as a session of kind internal, one per call and
many an hour, and none moves a task.  The event says what the session
is when it carries it (`session/created' does), else the session cache
does, else what was seen of the session before: a deletion comes after
the cache forgot the session.  A session nothing is known about is
taken for an ordinary one."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--sessions-settled)
    (let ((refreshed nil)
          (main '(:id "main-1" :kind "main" :name "Fix the parser"))
          (internal '(:id "int-1" :kind "internal" :name "Permission judge")))
      (cl-letf (((symbol-function 'harness-ui-tasks--refresh-soon)
                 (lambda (buffer) (push (buffer-name buffer) refreshed))))
        (cl-flet ((reloaded (event &rest args)
                    (setq refreshed nil)
                    (harness-ui-tasks--on-event event args)
                    refreshed))
          ;; A main session's events reload the board, as they did.
          (should (member (buffer-name board) (reloaded "session/created" "main-1" main)))
          (should (member (buffer-name board) (reloaded "session/status" "main-1" "running")))
          (should (member (buffer-name board) (reloaded "session/deleted" "main-1")))
          ;; So does any other event of the list, whoever it is about.
          (should (member (buffer-name board) (reloaded "agent/turn-ended" "int-1")))
          ;; An internal session's do not: its creation says what it is,
          ;; and the events after go by what was seen then.
          (should-not (reloaded "session/created" "int-1" internal))
          (should-not (reloaded "session/status" "int-1" "running"))
          (should-not (reloaded "session/status" "int-1" "idle"))
          (should-not (reloaded "session/deleted" "int-1"))
          ;; The cache tells a session the board never saw created.
          (harness-ui-cache-session '(:id "int-2" :kind "internal" :status "idle"))
          (should-not (reloaded "session/status" "int-2" "running"))
          ;; A deletion that comes after the cache let the session go.
          (harness-ui--forget-session "int-2")
          (should-not (harness-ui-session "int-2"))
          (should-not (reloaded "session/deleted" "int-2"))
          ;; A session nothing is known about is an ordinary one.
          (should (member (buffer-name board) (reloaded "session/status" "stranger" "idle"))))))))

(ert-deftest harness-ui-tasks-internal-session-over-the-wire-reloads-no-board ()
  "A real internal session, from its start to its deletion, reloads no board.
The events reach the UI in the shape the guard reads: the creation with
the session, the status changes and the deletion by the id (and the
session, which the harness adds).  A session of the user's made after
reloads the board, so the board still hears the events."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--sessions-settled)
    (let* ((reloads 0)
           (fetches 0)
           (heard nil)
           (listener (lambda (event args)
                       (when (string-prefix-p "session/" event)
                         ;; Asked as the board is, while the event is heard.
                         (push (list event (car-safe args) (harness-ui-internal-event-p event args))
                               heard))))
           (heard-of (lambda (event id)
                       (seq-filter (lambda (h) (and (equal (car h) event) (equal (nth 1 h) id)))
                                   heard))))
      (add-hook 'harness-ui-event-functions listener)
      (unwind-protect
          (cl-letf (((symbol-function 'harness-ui-tasks--refresh-soon)
                     (lambda (_buffer) (cl-incf reloads)))
                    ((symbol-function 'harness-ui-refresh-sessions)
                     (lambda (&rest _) (cl-incf fetches))))
            (let ((id (harness-call 'session/internal-start :job "Permission judge"
                                    :model "demo:scripted" :prompt "May it run ls?")))
              (harness-call 'session/internal-finish id :reply "Allow")
              (harness-test-wait (lambda () (and (funcall heard-of "session/created" id)
                                                 (= 2 (length (funcall heard-of "session/status" id)))))
                                 5 "the events of the internal session")
              ;; The session cache hears of it from the session's own
              ;; updates, with no list of every session fetched.
              (harness-test-wait (lambda () (equal "idle" (plist-get (harness-ui-session id) :status)))
                                 5 "the internal session in the cache")
              (harness-call 'session/delete id)
              (harness-test-wait (lambda () (funcall heard-of "session/deleted" id))
                                 5 "the deletion of the internal session")
              (harness-test-wait (lambda () (not (harness-ui-session id)))
                                 5 "the internal session to leave the cache")
              ;; Every event was the internal session's, and none reloaded
              ;; a board or fetched the sessions.
              (should (cl-every #'caddr (cl-remove-if-not (lambda (h) (equal (nth 1 h) id)) heard)))
              (should (zerop reloads))
              (should (zerop fetches))
              ;; A session of the user's does both.
              (let ((main (plist-get (harness-call 'session/create :cwd default-directory :name "Fix it")
                                     :id)))
                (harness-test-wait (lambda () (funcall heard-of "session/created" main))
                                   5 "the creation of the session")
                (should-not (nth 2 (car (funcall heard-of "session/created" main))))
                (should (> reloads 0))
                (should (> fetches 0)))))
        (remove-hook 'harness-ui-event-functions listener)))))

(ert-deftest harness-ui-tasks-board-key-leaves-out-internal-sessions ()
  "An internal session changing does not make the board draw itself again.
The key of what the board draws holds the sessions the cards read; the
internal ones change with every model call the harness makes on its
own, and no card shows one."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--sessions-settled)
    (with-current-buffer board
      (let ((sessions (lambda () (nth 1 (harness-ui-tasks--board-key)))))
        (harness-ui-cache-session '(:id "main-1" :kind "main" :status "idle" :updated 1))
        (let ((before (funcall sessions)))
          (should (= 1 (length before)))
          (harness-ui-cache-session '(:id "int-1" :kind "internal" :status "running" :updated 2))
          (harness-ui-cache-session '(:id "int-1" :kind "internal" :status "idle" :updated 3
                                      :usage (:cost 0.01)))
          (should (equal before (funcall sessions)))
          ;; A session of the user's does.
          (harness-ui-cache-session '(:id "main-1" :kind "main" :status "running" :updated 4))
          (should-not (equal before (funcall sessions))))))))

(ert-deftest harness-ui-tasks-has-no-bulk-edit ()
  "The board does not edit many tasks at once any more: the session list does.
Marking sessions there makes the harness's setting commands, and the
list's own keys, change them all and the tasks they work on.  The board
keeps the settings line of the next task: off a card, the commands
change its settings."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
      (should-not (lookup-key harness-ui-tasks-board-map (kbd "B")))
      (should-not (string-match-p "Bulk" (harness-ui-tasks--header most-positive-fixnum)))
      (should-not (string-match-p "Bulk\\|EDITING" (harness-ui-tasks-test--tail-text board)))
      (should-not (string-match-p "Bulk" (format "%S" (get 'harness-ui-tasks-mode 'harness-menu-group))))
      (should (equal harness-ui-tasks--new (car (harness-ui--setting-target nil)))))))

(ert-deftest harness-ui-tasks-new-task-priority ()
  "The button beside Submit sets the next task's priority for one task.
Clicking again cycles the level, and the notice above the box keeps the
choice on with [keep on]; a submission spends a one-shot choice."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (with-current-buffer board
        (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
        (should (string-match-p "Submit +medium priority\n" (harness-ui-tasks-test--tail-text board)))
        (push-button (save-excursion (goto-char harness-ui-tasks--list-end)
                                     (search-forward "medium priority")
                                     (match-beginning 0)))
        (should (string-match-p "Submit +high priority\n" (harness-ui-tasks-test--tail-text board)))
        (should (eq harness-ui-tasks--priority-mode 'once))
        (should (string-match-p "High priority for the next task" (harness-ui-tasks-test--tail-text board))))
      (harness-ui-tasks-test--type-and-submit board "Urgent fix")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*↑ +Urgent fix")
      (should (eq 'high (plist-get (car (harness-call 'task/list default-directory)) :priority)))
      ;; The one-shot choice is spent: the next task is medium again.
      (with-current-buffer board
        (should-not harness-ui-tasks--priority-mode)
        (should (string-match-p "Submit +medium priority\n" (harness-ui-tasks-test--tail-text board)))
        ;; Clicking still cycles the levels.
        (harness-ui-tasks-cycle-new-priority)
        (should (string-match-p "Submit +high priority\n" (harness-ui-tasks-test--tail-text board)))
        (harness-ui-tasks-cycle-new-priority)
        (should (string-match-p "Submit +low priority\n" (harness-ui-tasks-test--tail-text board)))
        (harness-ui-tasks-cycle-new-priority)
        (should (string-match-p "Submit +medium priority\n" (harness-ui-tasks-test--tail-text board)))
        ;; [keep on] makes the choice sticky, so it survives a submit.
        (harness-ui-tasks-cycle-new-priority)
        (push-button (harness-ui-tasks-test--tail-button board "[keep on]"))
        (should (eq harness-ui-tasks--priority-mode 'sticky)))
      (harness-ui-tasks-test--type-and-submit board "Whenever")
      (harness-ui-tasks-test--wait-text board "Pending  2\\(.\\|\n\\)*↑ +Urgent fix\\(.\\|\n\\)*Whenever")
      (should (eq 'high (plist-get (cadr (harness-call 'task/list default-directory)) :priority)))
      ;; Sticky stays, until it is clicked off.
      (with-current-buffer board
        (should (eq harness-ui-tasks--priority-mode 'sticky))
        (push-button (harness-ui-tasks-test--tail-button board "[off]"))
        (should-not harness-ui-tasks--priority-mode)
        (should (string-match-p "Submit +medium priority\n" (harness-ui-tasks-test--tail-text board)))))))

(defun harness-ui-tasks-test--tail-button (board text)
  "Where BOARD's button showing TEXT is, below the board."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (search-forward text)
      (match-beginning 0))))

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
  "With the toggle on Refine a new task is written up and waits in the Backlog for its start."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "Fix nested quotes in the parser\n\nHandle them in parse-args.")
             (:type done :stop-reason end-turn))))
      (with-current-buffer board
        (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
        (should (eq 'submit harness-ui-tasks--mode))
        ;; The toggle shows only the current mode, then the next task's priority.
        (should (string-match-p "New task +. Submit +medium priority\n" (harness-ui-tasks-test--tail-text board)))
        (should (equal '("Submit") (harness-ui-tasks-test--modes-shown board)))
        (goto-char harness-compose-end)
        (should (eq 'harness-ui-tasks-cycle-mode (key-binding (kbd "C-c C-t"))))
        (harness-ui-tasks-cycle-mode)
        (should (eq 'refine harness-ui-tasks--mode))
        (should (equal '("Refine") (harness-ui-tasks-test--modes-shown board)))
        (should (string-prefix-p " refine " (harness-ui-tasks-test--tail-line board 'step)))
        (insert "the parser chokes on nested quotes")
        (harness-ui-tasks-submit)
        ;; The toggle stays on Refine for the next one.
        (should (eq 'refine harness-ui-tasks--mode)))
      (harness-ui-tasks-test--wait-text
       board "Backlog  1\\(.\\|\n\\)*Fix nested quotes in the parser")
      (harness-ui-tasks-test--show-subtitle board "Fix nested quotes in the parser")
      (harness-ui-tasks-test--wait-text board "written up")
      (should (string-match-p "In progress  0" (harness-ui-tasks-test--board-text board)))
      (let ((task (car (harness-call 'task/list default-directory))))
        (should (eq 'pending (plist-get task :state)))
        (should (plist-get task :backlog))
        (should (equal "the parser chokes on nested quotes" (plist-get task :note))))
      ;; Its card starts it, and its session does the work.
      (harness-ui-tasks-test--goto-card board "Fix nested quotes")
      (with-current-buffer board
        ;; The backlog's way out: the queue first, then an explicit start.
        (should (equal '("Queue it" "Start now")
                       (take 2 (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task))))))
        (should (eq 'harness-ui-tasks-refine (key-binding (kbd "r"))))
        (harness-ui-tasks-start))
      (harness-ui-tasks-test--wait-text board "Completed  1")
      ;; Back to Submit with two clicks on the toggle, past Plan, a task
      ;; starts at once again.
      (with-current-buffer board
        (push-button (harness-ui-tasks-test--toggle board))
        (should (eq 'plan harness-ui-tasks--mode))
        (push-button (harness-ui-tasks-test--toggle board))
        (should (eq 'submit harness-ui-tasks--mode))
        (should (equal '("Submit") (harness-ui-tasks-test--modes-shown board))))
      (harness-ui-tasks-test--type-and-submit board "Straight to work")
      (harness-ui-tasks-test--wait-text board "Completed  2"))))

(ert-deftest harness-ui-tasks-refine-feedback-from-the-card ()
  "r on a backlog task sends feedback, and the agent writes it up again."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "First write-up") (:type done :stop-reason end-turn))))
      (with-current-buffer board (harness-ui-tasks-cycle-mode 'refine))
      (harness-ui-tasks-test--type-and-submit board "An idea")
      (harness-ui-tasks-test--wait-text board "Backlog  1\\(.\\|\n\\)*First write-up")
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
        (harness-ui-tasks-test--wait-text board "Backlog  1\\(.\\|\n\\)*Second write-up")))))

(ert-deftest harness-ui-tasks-refine-failure-needs-input ()
  "A write-up that stops asks for you; written by hand, the task waits in the backlog."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (with-current-buffer board (harness-ui-tasks-cycle-mode 'refine))
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
      (harness-ui-tasks-test--wait-text board "Backlog  1\\(.\\|\n\\)*Make the shaky idea solid")
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
      (with-current-buffer board (harness-ui-tasks-cycle-mode 'refine))
      (harness-ui-tasks-test--type-and-submit board "export the reports as csv")
      (harness-ui-tasks-test--wait-text
       board "Requires your input  1\\(.\\|\n\\)*duplicate of .CSV export.")
      (harness-ui-tasks-test--goto-card board "duplicate of")
      (with-current-buffer board
        (should (equal '("Drop" "Write it up")
                       (take 2 (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task))))))
        ;; m takes feedback on it: why it is not a duplicate.
        (harness-ui-tasks-reply)
        (should (eq 'refine (car harness-ui-tasks--target)))
        (should (string-match-p "not a duplicate" (harness-ui-tasks--placeholder)))
        (harness-ui-tasks-compose-reset))
      ;; r has it written up all the same.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Export the reports as CSV\n\nNot the same after all.")
               (:type done :stop-reason end-turn))))
        (harness-ui-tasks-test--goto-card board "duplicate of")
        (with-current-buffer board (harness-ui-tasks-refine))
        (harness-ui-tasks-test--wait-text board "Backlog  1\\(.\\|\n\\)*Export the reports as CSV")))))

(ert-deftest harness-ui-tasks-toggle-shows-the-current-mode ()
  "The toggle is one button naming the current mode; a click switches to the next."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the settings")
      (pcase-dolist (`(,symbol ,mode ,does ,other)
                     '((submit "Submit" "start the task now" "Refine")
                       (refine "Refine" "an agent writes it up first" "Plan")
                       (plan "Plan" "an agent plans it first" "Submit")))
        (should (eq symbol harness-ui-tasks--mode))
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
      (should (eq 'submit harness-ui-tasks--mode))
      ;; With a prefix argument the mode is read.
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Plan")))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'harness-ui-tasks-cycle-mode)))
      (should (eq 'plan harness-ui-tasks--mode)))))

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
            (should (eq 'submit harness-ui-tasks--mode))
            (dolist (mode '("Submit" "Refine" "Plan"))
              (harness-ui-tasks--refit-tail)
              ;; Only the current mode shows, whole.
              (should (equal (list mode) (harness-ui-tasks-test--modes-shown board)))
              (save-excursion
                (goto-char harness-ui-tasks--list-end)
                (while (< (point) (overlay-start harness-compose-overlay))
                  (should (< (string-width (buffer-substring (point) (line-end-position)))
                             (window-body-width side)))
                  (forward-line 1)))
              ;; Toggling switches it to the next mode.
              (harness-ui-tasks-cycle-mode))
            (should (eq 'submit harness-ui-tasks--mode))
            (should (equal '("Submit") (harness-ui-tasks-test--modes-shown board))))
        (delete-window side)
        (set-window-buffer window board)))))

;;;; Plan: a strong model plans, a cheaper one works

(defvar harness-providers)
(defvar harness-ui-tasks--new)
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-provider-demo--complete "harness-provider-demo")
(declare-function harness-ui-tasks--step-line "harness-ui-tasks")

(defun harness-ui-tasks-test--push-tail-button (board id)
  "Push BOARD's button named ID above the compose box."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (let ((match (text-property-search-forward 'harness-task-button id #'eq)))
        (should match)
        (push-button (prop-match-beginning match))))))

(defun harness-ui-tasks-test--tail-line (board key)
  "The line above BOARD's compose box named KEY, as plain text."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (let ((match (text-property-search-forward 'harness-task-tail key #'eq)))
        (and match (string-trim-right (buffer-substring-no-properties (prop-match-beginning match)
                                                                      (prop-match-end match))))))))

(ert-deftest harness-ui-tasks-plan-mode ()
  "Plan: the plan and the work each have a line of models above the box.
A button on a line sets its own model; the task is planned on the
plan's, read-only, waits in the Backlog with the plan, and works on the
work's once started.  Submit and Refine keep the task model."
  (harness-ui-tasks-test-with
    (harness-test-load-module 'readonly)
    (harness-test-load-module 'tools-sessions)
    (unwind-protect
        (let ((harness-tasks-model "test-plan:small")
              (chosen nil)
              (harness-provider-demo-script-override
               (lambda (request)
                 (if (string-match-p "^## Task planning" (or (plist-get request :system) ""))
                     '((:type tool-call :id "p1" :name "submit_task_plan"
                              :input (:title "Fix nested quotes" :plan "1. Handle them in parse-args."))
                       (:type done :stop-reason end-turn))
                   '((:type text :delta "Working on it.") (:type done :stop-reason end-turn))))))
          (harness-define-provider 'test-plan
            :complete #'harness-provider-demo--complete
            :tiers '(:hard "big" :medium "mid")
            :models (lambda () (harness-resolved (mapcar (lambda (name) (list :name name)) '("big" "mid" "small")))))
          (with-current-buffer board
            ;; The board's settings came before the provider: again.
            (setq harness-ui-tasks--new nil)
            (harness-ui-tasks--fetch board)
            (harness-test-wait (lambda () (plist-get harness-ui-tasks--new :plan-model)) 5 "the plan's model")
            (should (equal "test-plan:big" (plist-get harness-ui-tasks--new :plan-model)))
            (should (equal "test-plan:mid" (plist-get harness-ui-tasks--new :plan-work-model)))
            (should (equal "test-plan:small" (plist-get harness-ui-tasks--new :refine-model)))
            ;; Submit has the one line, of the work on the task model.
            (should (equal "" (harness-ui-tasks--step-line)))
            (should (string-match-p "\\` small (Test-Plan) · " (harness-ui-tasks-test--tail-line board 'settings)))
            (harness-ui-tasks-cycle-mode 'plan)
            (should (string-match-p "\\` plan  big (Test-Plan) · [^ ]+ default\\'"
                                    (harness-ui-tasks-test--tail-line board 'step)))
            ;; The work's line has its model and thinking level alone;
            ;; the task's settings and the limit are on the line below.
            (should (string-match-p "\\` work  mid (Test-Plan) · [^ ]+ default\\'"
                                    (harness-ui-tasks-test--tail-line board 'work)))
            (should (string-match-p "3 at a time\\'" (harness-ui-tasks-test--tail-line board 'settings)))
            (should-not (string-search "Test-Plan" (harness-ui-tasks-test--tail-line board 'settings)))
            (should (string-prefix-p "Describe a task…" (harness-ui-tasks--placeholder))))
          ;; Each line's model button sets its own.
          (cl-letf (((symbol-function 'harness-ui-choose-model)
                     (lambda (callback) (funcall callback chosen (harness-ui-model-label chosen)))))
            (setq chosen "test-plan:mid")
            (harness-ui-tasks-test--push-tail-button board 'harness-set-model@plan)
            (setq chosen "test-plan:big")
            (harness-ui-tasks-test--push-tail-button board 'harness-set-model))
          (with-current-buffer board
            (should (equal "test-plan:mid" (plist-get harness-ui-tasks--new :plan-model)))
            (should (equal "test-plan:big" (plist-get harness-ui-tasks--new :plan-work-model)))
            (should (equal "test-plan:small" (plist-get harness-ui-tasks--new :model)))
            (should (string-match-p "\\` plan  mid " (harness-ui-tasks-test--tail-line board 'step)))
            (should (string-match-p "\\` work  big " (harness-ui-tasks-test--tail-line board 'work))))
          ;; Planned on the plan's model, then waiting in the Backlog.
          (harness-ui-tasks-test--type-and-submit board "the parser chokes on nested quotes")
          (harness-ui-tasks-test--wait-text board "Backlog  1\\(.\\|\n\\)*Fix nested quotes")
          (let* ((task (car (harness-call 'task/list default-directory)))
                 (sid (plist-get task :session)))
            (should (eq t (plist-get task :plan)))
            (should (equal "test-plan:big" (plist-get task :model)))
            (should (equal "test-plan:mid" (plist-get (harness-call 'session/get sid) :model)))
            (should (equal "Fix nested quotes\n\n1. Handle them in parse-args." (plist-get task :prompt)))
            (should (string-match-p "planned " (harness-ui-tasks-test--card-text board "Fix nested quotes")))
            (harness-ui-tasks-test--show-subtitle board "Fix nested quotes")
            (harness-ui-tasks-test--wait-text board "planned · Handle them")
            ;; Started, it works on the work's model.
            (harness-ui-tasks-test--goto-card board "Fix nested quotes")
            (with-current-buffer board (harness-ui-tasks-start))
            (harness-ui-tasks-test--wait-text board "Completed  1")
            (should (equal "test-plan:big" (plist-get (harness-call 'session/get sid) :model))))
          ;; The mode stays; Refine has its write-up's line, and its
          ;; work the task model.
          (with-current-buffer board
            (should (eq 'plan harness-ui-tasks--mode))
            (harness-ui-tasks-cycle-mode 'refine)
            (should (string-match-p "\\` refine  small (Test-Plan) · [^ ]+ low\\'"
                                    (harness-ui-tasks-test--tail-line board 'step)))
            (should (string-match-p "\\` work    small " (harness-ui-tasks-test--tail-line board 'work)))))
      (remhash 'test-plan harness-providers)
      (harness-provider--forget 'test-plan))))

(defun harness-ui-tasks-test--tail-buttons (board key)
  "The ids of the buttons on BOARD's line above the compose box named KEY, in order."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (when-let* ((match (text-property-search-forward 'harness-task-tail key #'eq)))
        (let ((pos (prop-match-beginning match))
              (end (prop-match-end match))
              (ids nil))
          (while (< pos end)
            (when-let* ((id (get-text-property pos 'harness-task-button)))
              (push id ids))
            (setq pos (or (next-single-property-change pos 'harness-task-button nil end) end)))
          (nreverse ids))))))

(defun harness-ui-tasks-test--tail-tooltips (board key)
  "The tooltips of the buttons on BOARD's line above the compose box named KEY."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (when-let* ((match (text-property-search-forward 'harness-task-tail key #'eq)))
        (let ((pos (prop-match-beginning match))
              (end (prop-match-end match))
              (tips nil))
          (while (< pos end)
            (when (get-text-property pos 'harness-task-button)
              (push (get-text-property pos 'help-echo) tips))
            (setq pos (or (next-single-property-change pos 'harness-task-button nil end) end)))
          (nreverse tips))))))

(defun harness-ui-tasks-test--tail-loose-text (board key)
  "The text of BOARD's line KEY that no button holds, separators and spaces left out."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (when-let* ((match (text-property-search-forward 'harness-task-tail key #'eq)))
        (let ((pos (prop-match-beginning match))
              (end (prop-match-end match))
              (text ""))
          (while (< pos end)
            (let ((next (or (next-single-property-change pos 'harness-task-button nil end) end)))
              (unless (get-text-property pos 'harness-task-button)
                (setq text (concat text (buffer-substring-no-properties pos next))))
              (setq pos next)))
          (replace-regexp-in-string "[ ·\n]+" "" text))))))

(ert-deftest harness-ui-tasks-a-step-sets-its-model-and-thinking-alone ()
  "A step of a new task has a model and a thinking level of its own, no more.
In Refine and Plan the write-up or the plan, then the work, each have a
line with its name and those two buttons alone: no sentence says what
the mode does, there or in the box's placeholder, and changing the
mode says nothing either -- the toggle's tooltip does.  What the whole
task works with -- permission mode, interactive, supervisor mode, where
it works -- is on one line below them, which ends with how many tasks
work at once and has no model or thinking level.  Submit's one step has
its two at the start of that line.  The setting commands say whom a
change is for: a step's model and thinking level are its own, the rest
the task's."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the board's settings")
      ;; A git project, where the worktree switch shows; this test's dir is not one.
      (setq harness-ui-tasks--settings (plist-put (copy-sequence harness-ui-tasks--settings) :worktrees t))
      (goto-char (point-max))
      (let* ((sup (harness-ui-tasks--supervisor-p))
             (task (lambda (switch)
                     (append '(harness-set-permission-mode harness-toggle-non-interactive)
                             (and switch sup '(harness-toggle-supervisor))
                             '(harness-ui-tasks-toggle-main-tree harness-ui-tasks-set-max-running)))))
        (harness-ui-tasks-cycle-mode 'submit)
        (should (equal (append '(harness-set-model harness-set-thinking) (funcall task t))
                       (harness-ui-tasks-test--tail-buttons board 'settings)))
        (should-not (harness-ui-tasks-test--tail-line board 'step))
        (should-not (harness-ui-tasks-test--tail-line board 'work))
        (should (string-prefix-p "Describe a task…" (harness-ui-tasks--placeholder)))
        (pcase-dolist (`(,mode ,switch ,placeholder) '((refine t "Describe a task") (plan nil "Describe a task")))
          (harness-ui-tasks-cycle-mode mode)
          (should (equal (list (intern (format "harness-set-model@%s" mode))
                               (intern (format "harness-set-thinking@%s" mode)))
                         (harness-ui-tasks-test--tail-buttons board 'step)))
          (should (string-prefix-p (format " %s " mode) (harness-ui-tasks-test--tail-line board 'step)))
          (should (equal '(harness-set-model harness-set-thinking)
                         (harness-ui-tasks-test--tail-buttons board 'work)))
          (should (string-prefix-p " work " (harness-ui-tasks-test--tail-line board 'work)))
          ;; Each step's line is its name and its two buttons: nothing more.
          (should (equal (symbol-name mode) (harness-ui-tasks-test--tail-loose-text board 'step)))
          (should (equal "work" (harness-ui-tasks-test--tail-loose-text board 'work)))
          ;; Their tooltips name the setting and the step, and say no more.
          (pcase-dolist (`(,key ,scope)
                         (if (eq mode 'plan)
                             '((step "the plan of new tasks") (work "the work of new planned tasks"))
                           '((step "the write-up of new tasks") (work "the work of new tasks"))))
            (should (equal (list (concat "Model of " scope) (concat "Thinking level of " scope))
                           (harness-ui-tasks-test--tail-tooltips board key))))
          (should (string-prefix-p (concat placeholder harness-ui-tasks--ellipsis) (harness-ui-tasks--placeholder)))
          (should (equal (funcall task switch) (harness-ui-tasks-test--tail-buttons board 'settings)))))
      ;; Whom a change is for.  The commands typed in the box set the
      ;; work's model and the task's other settings.  Changing the mode
      ;; says nothing.
      (let ((said nil)
            (model (plist-get harness-ui-tasks--new :plan-work-model)))
        (cl-letf (((symbol-function 'harness-ui-choose-model)
                   (lambda (callback) (funcall callback model "the same model")))
                  ((symbol-function 'completing-read) (lambda (&rest _) "YOLO"))
                  ((symbol-function 'message)
                   (lambda (format &rest args)
                     (when format (push (apply #'format-message format args) said)))))
          (harness-set-model)
          (harness-set-permission-mode)
          (harness-toggle-non-interactive)
          (harness-ui-tasks-test--push-tail-button board 'harness-set-model@plan)
          (harness-ui-tasks-cycle-mode 'refine)
          (harness-set-model)
          (harness-ui-tasks-cycle-mode 'submit)
          (harness-set-model))
        (should (equal '("Model → the same model (for the work of new planned tasks)"
                         "Permission mode → YOLO (for new tasks)"
                         "Non-interactive on (for new tasks)"
                         "Model → the same model (for the plan of new tasks)"
                         "Model → the same model (for the work of new tasks)"
                         "Model → the same model (for new tasks)")
                       (reverse said)))
        (should (equal "yolo" (plist-get harness-ui-tasks--new :permission-mode)))
        (should (harness-json-true-p (plist-get harness-ui-tasks--new :non-interactive)))))))

;;;; Sending to a session is not composing a task

;; The same box does both, so what C-c C-c will do has to be plain: a
;; box that sends to a session wears the message colours, band, bar and
;; all, and names the session it sends to.

(defvar harness-compose--accent)
(defvar harness-compose--face)
(defvar harness-compose--placeholder)
(defvar harness-compose-overlay)
(declare-function harness-ui-tasks--messaging-p "harness-ui-tasks")
(declare-function harness-ui-tasks--set-compose "harness-ui-tasks")

(defun harness-ui-tasks-test--tail-line-faces (path)
  "The faces of the tail line PATH belongs to, as (BAR . EOL)."
  (save-excursion
    (goto-char harness-ui-tasks--list-end)
    (re-search-forward path (overlay-start harness-compose-overlay))
    (goto-char (match-beginning 0))
    (cons (get-text-property (point) 'face)
          (get-text-property (line-end-position) 'face))))

(ert-deftest harness-ui-tasks-only-messages-wear-the-message-colours ()
  "Every target that sends to a session colours the box; a new task does not."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (pcase-dolist (`(,target ,messaging)
                     '((nil nil) ((edit . "t1") nil)
                       ((reply . "t1") t) ((answer . "t1") t)
                       ((refine . "t1") t) ((reject . "t1") t)))
        (harness-ui-tasks--set-compose "" target)
        (should (eq (and (harness-ui-tasks--messaging-p) t) messaging))
        (should (eq (overlay-get harness-compose-overlay 'face)
                    (if messaging 'harness-compose-message-face 'harness-compose-face)))
        (should (eq (and harness-compose--accent t) messaging))
        (should (eq harness-compose--face (if messaging 'harness-compose-message-face
                                            'harness-compose-face)))
        (should (equal (if messaging
                           '(harness-compose-message-accent-face harness-compose-message-face)
                         '(harness-dim-face harness-compose-face))
                       (get-text-property (1- harness-compose-start) 'face)))))))

(ert-deftest harness-ui-tasks-message-box-names-its-session ()
  "The message box says which session it sends to, with a band and a bar."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--type-and-submit board "Waiting task")
    (harness-ui-tasks-test--wait-text board "Completed  1")
    (harness-ui-tasks-test--goto-card board "Waiting task")
    (with-current-buffer board
      ;; A new task's box: a plain label and no bar.
      (should (string-match-p " New task" (harness-ui-tasks-test--tail-text board)))
      (harness-ui-tasks-reply)
      (should (eq 'reply (car harness-ui-tasks--target)))
      (should (string-match-p "Message to session .Waiting task." (harness-ui-tasks-test--tail-text board)))
      ;; The label line is a band the bar opens, reaching the window's edge.
      (pcase-let ((`(,bar . ,eol) (harness-ui-tasks-test--tail-line-faces "Message to session")))
        (should (memq 'harness-compose-message-accent-face (ensure-list bar)))
        (should (memq 'harness-compose-message-face (ensure-list bar)))
        (should (memq 'harness-compose-message-face (ensure-list eol))))
      ;; The box under it follows, prompt and placeholder included.
      (should (string-match-p "▌ ❯ " (harness-ui-tasks-test--tail-text board)))
      (should (memq 'harness-compose-message-accent-face
                    (ensure-list (get-text-property (1- harness-compose-start) 'face))))
      (should (memq 'harness-compose-message-face
                    (ensure-list (get-text-property
                                  0 'face (overlay-get harness-compose--placeholder 'before-string)))))
      ;; C-g puts the plain new-task box back.
      (harness-ui-tasks-compose-reset)
      (should-not (harness-ui-tasks--messaging-p))
      (should (eq 'harness-compose-face (overlay-get harness-compose-overlay 'face)))
      (should (string-match-p " New task" (harness-ui-tasks-test--tail-text board))))))

(ert-deftest harness-ui-tasks-message-tail-fits-the-window ()
  "The message band, bar and icon included, fits a narrow window."
  (harness-ui-tasks-test-with
    (let* ((window (get-buffer-window board))
           (side (split-window window 40 'right)))
      (unwind-protect
          (with-current-buffer board
            (set-window-buffer side board)
            (set-window-buffer window (get-buffer-create "*scratch*"))
            (harness-ui-tasks--set-compose "" (cons 'reply "t1"))
            (harness-ui-tasks--refit-tail)
            (should (string-match-p "Message to session" (harness-ui-tasks-test--tail-text board)))
            (save-excursion
              (goto-char harness-ui-tasks--list-end)
              (while (< (point) (overlay-start harness-compose-overlay))
                (should (< (string-width (buffer-substring (point) (line-end-position)))
                           (window-body-width side)))
                (forward-line 1))))
        (delete-window side)
        (set-window-buffer window board)))))

(ert-deftest harness-ui-tasks-message-bar-runs-down-the-attachments ()
  "In a message box every attachment has a line, the bar and band on it.
Each line fits the narrow window the board is in, and one wrapping all
the same would carry the bar on."
  (harness-ui-tasks-test-with
    (let* ((window (get-buffer-window board))
           (side (split-window window 40 'right))
           (files (mapcar (lambda (name)
                            (let ((file (expand-file-name name dir)))
                              (with-temp-file file (insert "x"))
                              file))
                          '("notes.txt" "a-file-whose-name-is-far-too-long-for-a-window-forty-columns-wide.txt"))))
      (unwind-protect
          (with-current-buffer board
            (set-window-buffer side board)
            (set-window-buffer window (get-buffer-create "*scratch*"))
            (harness-ui-tasks--set-compose "" (cons 'reply "t1"))
            (dolist (file files) (harness-compose-add-attachment file))
            (harness-ui-tasks--refit-tail)
            (let ((lines (save-excursion
                           (goto-char harness-ui-tasks--list-end)
                           (cl-loop while (< (point) (overlay-start harness-compose-overlay))
                                    when (eq 'attachments (get-text-property (point) 'harness-task-tail))
                                    collect (cons (point) (line-end-position))
                                    do (forward-line 1)))))
              (should (= 2 (length lines)))
              (pcase-dolist (`(,start . ,end) lines)
                (should (equal "▌ " (buffer-substring-no-properties start (+ start 2))))
                (should (memq 'harness-compose-message-accent-face (ensure-list (get-text-property start 'face))))
                (should (memq 'harness-compose-message-face (ensure-list (get-text-property end 'face))))
                (should (string-prefix-p "▌ " (get-text-property start 'wrap-prefix)))
                (should (< (car (window-text-pixel-size side start end)) (window-body-width side))))
              (should (string-match-p "notes\\.txt" (buffer-substring (car (nth 0 lines)) (cdr (nth 0 lines)))))
              (should (string-match-p "\\`▌ .*a-file-whose.*….*-wide\\.txt (1 B) ×\\'"
                                      (buffer-substring-no-properties (car (nth 1 lines)) (cdr (nth 1 lines)))))))
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
      ;; The board learns review is on as from a change of the option.
      (with-current-buffer board (harness-ui-tasks-refresh))
      (harness-ui-tasks-test--settings-say board t)
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
      ;; The column's heading counts it: the header does not.
      (should-not (string-match-p "to review" (with-current-buffer board
                                                 (harness-ui-tasks--header most-positive-fixnum))))
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
        (should (string-suffix-p "And on macOS" (car (last (harness-ui-tasks-test--user-texts sid)))))
        ;; A message to a task in review is feedback too: m opens the same
        ;; box, and there is no Reply beside Send back.
        (harness-ui-tasks-test--goto-card board "Fix the flaky test")
        (with-current-buffer board
          (should-not (assoc "Reply" (harness-ui-tasks--actions (harness-ui-tasks--task))))
          (call-interactively (key-binding (kbd "m")))
          (should (eq 'reject (car harness-ui-tasks--target)))
          (should (string-match-p "Send back .Fix the flaky test. with feedback" (harness-ui-tasks-test--tail-text board)))
          (insert "And on Windows")
          (harness-ui-tasks-submit))
        (harness-ui-tasks-test--wait-text board "Ready for review  1\\(.\\|\n\\)*sent back 3 times")
        (should (string-suffix-p "And on Windows" (car (last (harness-ui-tasks-test--user-texts sid))))))
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

(ert-deftest harness-ui-tasks-action-functions-add-to-the-menu ()
  "`harness-ui-tasks-action-functions' adds actions to a card's menu only.
They follow the actions of the card's column, never become one of its
buttons, and a function that fails adds none and breaks nothing."
  (harness-ui-tasks-test-with
    (let* ((harness-tasks-require-verification t)
           (harness-ui-tasks-action-functions
            (list (lambda (task)
                    (and (equal (plist-get task :state) "review")
                         '(("Look closer" harness-ui-tasks-test--look-closer))))
                  (lambda (_task) (error "Broken"))))
           (labels (lambda () (mapcar #'car (harness-ui-tasks--actions (harness-ui-tasks--task))))))
      (harness-ui-tasks-test--type-and-submit board "Try the extra action")
      (harness-ui-tasks-test--wait-text board "Ready for review  1\\(.\\|\n\\)*Try the extra action")
      (harness-ui-tasks-test--goto-card board "Try the extra action")
      (with-current-buffer board
        (harness-ui-tasks--render)
        (harness-ui-tasks-test--goto-card board "Try the extra action")
        (let ((all (funcall labels)))
          (should (member "Look closer" all))
          ;; After the column's own actions.
          (should (< (cl-position "Archive" all :test #'equal)
                     (cl-position "Look closer" all :test #'equal))))
        (should-not (assoc "Look closer" (harness-ui-tasks--actions (harness-ui-tasks--task) t)))
        (should-not (string-match-p "\\[Look closer\\]" (harness-ui-tasks-test--board-text board)))
        (should (string-match-p "\\[Verify\\] \\[Send back\\]" (harness-ui-tasks-test--board-text board)))
        (should (equal (harness-ui-tasks--task) (harness-ui-tasks-task-at-point)))))))

(declare-function harness-ui-tools-dev-open-p "harness-ui-tools-dev" (task))

(ert-deftest harness-ui-tasks-review-offers-the-worktree-harness ()
  "A review card whose worktree is a harness checkout has Open harness in its menu.
This repository's plugin adds it (harness-ui-tools-dev.el, through
`harness-ui-tasks-action-functions'), and its harness half opens the
instance.  The card has no button for it, as it has none for its
session, which a click on its title opens."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (checkout nil)
          (open-harness (lambda ()
                          (assoc "Open harness" (harness-ui-tasks--actions (harness-ui-tasks--task))))))
      (harness-test-load-module 'ui-tools-dev)
      (harness-ui-tasks-test--type-and-submit board "Try the harness")
      (harness-ui-tasks-test--wait-text board "Ready for review  1\\(.\\|\n\\)*Try the harness")
      ;; Without a checkout of its own the card does not offer it.
      (harness-ui-tasks-test--goto-card board "Try the harness")
      (with-current-buffer board
        (should-not (harness-ui-tools-dev-open-p (harness-ui-tasks--task)))
        (should-not (funcall open-harness)))
      ;; A worktree that is a checkout of the harness gets it in the menu.
      (setq checkout (harness-test-harness-checkout))
      (harness-test-load-module 'tools-dev)
      (let ((id (plist-get (car (harness-call 'task/list default-directory)) :id)))
        (harness-tasks--set id :worktree checkout)
        (with-current-buffer board (harness-ui-tasks-refresh))
        (harness-test-wait (lambda () (with-current-buffer board
                                        (harness-ui-tools-dev-open-p (harness-ui-tasks--find id))))
                           5 "the board to know the task's worktree"))
      (harness-ui-tasks-test--goto-card board "Try the harness")
      (with-current-buffer board
        (harness-ui-tasks--render)
        (should (funcall open-harness))
        ;; Not as a button: the card's buttons stay Verify and Send back.
        (should-not (string-match-p "\\[Open harness\\]" (harness-ui-tasks-test--board-text board)))
        (should-not (harness-ui-tasks--find-button "open-harness" (point-min) (point-max)))
        (should (string-match-p "\\[Verify\\] \\[Send back\\]" (harness-ui-tasks-test--board-text board)))
        ;; The menu's entry starts the worktree's own live loop.
        (harness-ui-tasks-test--goto-card board "Try the harness")
        (call-interactively (nth 1 (funcall open-harness))))
      (harness-test-wait (lambda () (harness-test-dev-invocations checkout)) 5
                         "the worktree's dev loop to run")
      (should (equal "start" (cdr (assoc "args" (car (harness-test-dev-invocations checkout)))))))))

(defvar harness-config-sections)

;;;; Review: turning it off

(declare-function harness-ui-tasks-toggle-review "harness-ui-tasks")
(declare-function harness-ui-tasks-refresh "harness-ui-tasks")
(declare-function harness-ui-tasks--new-settings-line "harness-ui-tasks")

(defun harness-ui-tasks-test--settings-say (board review)
  "Wait until BOARD's settings say REVIEW, t or `:false', about review."
  (harness-test-wait (lambda () (eq review (plist-get (buffer-local-value 'harness-ui-tasks--settings board)
                                                     :require-verification)))
                     5 (format "the board to know review is %s" (if (eq review t) "on" "off"))))

(ert-deftest harness-ui-tasks-review-off-and-on ()
  "V turns review off and on again: an option, saved for every project.
Off, finished work completes by itself and Ready for review goes away.
The settings page has the option under Task board, so the header line
has no switch for it."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (saved nil))
      (should (memq 'harness-tasks-require-verification
                    (plist-get (alist-get 'tasks harness-config-sections) :keys)))
      (cl-letf (((symbol-function 'harness-save-user-option)
                 (lambda (symbol value) (set symbol value) (push (cons symbol value) saved)))
                ;; Nothing waits for review, so turning it off asks nothing.
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked about tasks waiting for review"))))
        (with-current-buffer board (harness-ui-tasks-refresh))
        (harness-ui-tasks-test--settings-say board t)
        (should-not (string-search "Review" (with-current-buffer board
                                              (harness-ui-tasks--header most-positive-fixnum))))
        ;; V on the board turns it off.
        (with-current-buffer board
          (goto-char (point-min))
          (should (eq 'harness-ui-tasks-toggle-review (key-binding (kbd "V"))))
          (call-interactively (key-binding (kbd "V"))))
        (harness-ui-tasks-test--settings-say board :false)
        ;; Saved as the option, so it holds for every project and after a restart.
        (should (equal '((harness-tasks-require-verification)) saved))
        (should-not harness-tasks-require-verification)
        ;; Finished work is done without waiting for anyone, and the board
        ;; has no column for review.
        (harness-ui-tasks-test--type-and-submit board "Fix the flaky test")
        (harness-ui-tasks-test--wait-text board "Completed  1\\(.\\|\n\\)*Fix the flaky test")
        (should (string-match-p "In progress  0" (harness-ui-tasks-test--board-text board)))
        (should-not (string-search "Ready for review" (harness-ui-tasks-test--board-text board)))
        (should-not (plist-get (car (harness-call 'task/list default-directory)) :verified))
        ;; V again turns it on.
        (with-current-buffer board (call-interactively #'harness-ui-tasks-toggle-review))
        (harness-test-wait (lambda () harness-tasks-require-verification) 5 "review on again")
        (should (equal '(harness-tasks-require-verification . t) (car saved)))
        (harness-ui-tasks-test--settings-say board t)
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

;;;; How many tasks work at once: the limit's button

(declare-function harness-ui-tasks-set-max-running "harness-ui-tasks")

(defun harness-ui-tasks-test--limit (board)
  "Return (TEXT HELP POS) of BOARD's limit button, above the compose box, or nil."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (when-let* ((match (text-property-search-forward
                          'harness-task-button 'harness-ui-tasks-set-max-running #'eq)))
        (let ((pos (prop-match-beginning match)))
          (list (buffer-substring-no-properties pos (prop-match-end match))
                (get-text-property pos 'help-echo)
                pos))))))

(defun harness-ui-tasks-test--limit-says (board text)
  "Wait until BOARD's limit button says TEXT."
  (harness-test-wait (lambda () (equal text (car (harness-ui-tasks-test--limit board))))
                     5 (format "the limit's button to say %s" text)))

(ert-deftest harness-ui-tasks-limit-button ()
  "\"N at a time\" is a button: a click sets how many tasks work at once.
It is the harness option, saved for every project, and a higher limit
starts the waiting tasks at once.  No limit shows as \"all at once\",
an answer that is no number changes nothing, and so does the limit
there is now.  Refine and Plan show it too, for the work their tasks
lead to."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (saved nil)
          (answer nil)
          (asked nil))
      (cl-letf (((symbol-function 'harness-save-user-option)
                 (lambda (symbol value) (set symbol value) (push (cons symbol value) saved)))
                ((symbol-function 'completing-read)
                 (lambda (prompt _table &optional _pred _require _initial _history default &rest _)
                   (push prompt asked)
                   (if (functionp answer) (funcall answer default) answer))))
        ;; The board came up with the 3 of the tests' setup.
        (harness-ui-tasks-test--limit-says board "3 at a time")
        (with-current-buffer board (harness-ui-tasks-refresh))
        (harness-ui-tasks-test--type-and-submit board "First waiting task")
        (harness-ui-tasks-test--type-and-submit board "Second waiting task")
        (harness-ui-tasks-test--wait-text board "Pending  2")
        ;; 0: nothing starts by itself, and the button stands out.
        (harness-ui-tasks-test--limit-says board "0 at a time")
        (pcase-let ((`(,_ ,help ,pos) (harness-ui-tasks-test--limit board)))
          (should (string-search "nothing starts by itself" help))
          (should (string-search "click to change" help))
          (should (eq 'harness-task-held-face (get-text-property pos 'face board)))
          ;; A click asks, the limit now the default; 2 lets both tasks start.
          (setq answer "2")
          (with-current-buffer board
            (should (eq board (window-buffer (selected-window))))
            (harness-test-click pos)))
        (should (equal '("Tasks of a project working at once (default 0): ") asked))
        (harness-test-wait (lambda () (equal '((harness-tasks-max-running . 2)) saved)) 5 "the limit to be saved")
        (should (eql 2 harness-tasks-max-running))
        (harness-ui-tasks-test--limit-says board "2 at a time")
        (should (eq 'harness-dim-face (get-text-property (nth 2 (harness-ui-tasks-test--limit board)) 'face board)))
        (should (string-search "At most 2 tasks at once per project"
                               (nth 1 (harness-ui-tasks-test--limit board))))
        ;; At once: the waiting tasks need no other task to end.
        (harness-ui-tasks-test--wait-text board "Pending  0")
        ;; No limit, by name: all at once.
        (setq answer "no limit")
        (with-current-buffer board (push-button (nth 2 (harness-ui-tasks-test--limit board))))
        (harness-ui-tasks-test--limit-says board "all at once")
        (should (equal '(harness-tasks-max-running) (car saved)))
        (should-not harness-tasks-max-running)
        (should (string-search "No limit" (nth 1 (harness-ui-tasks-test--limit board))))
        ;; The limit there is now, the default, saves nothing; nor does an
        ;; answer that is no number of tasks.
        (dolist (a (list (lambda (default) default) "" "lots" "-2"))
          (setq answer a)
          (with-current-buffer board
            (if (member a '("lots" "-2"))
                (should-error (push-button (nth 2 (harness-ui-tasks-test--limit board))) :type 'user-error)
              (push-button (nth 2 (harness-ui-tasks-test--limit board))))))
        (accept-process-output nil 0.05)
        (should (= 2 (length saved)))
        (should (equal "all at once" (car (harness-ui-tasks-test--limit board))))
        ;; The button's words read back as the number.
        (setq answer "4 at a time")
        (with-current-buffer board (push-button (nth 2 (harness-ui-tasks-test--limit board))))
        (harness-ui-tasks-test--limit-says board "4 at a time")
        (should (eql 4 harness-tasks-max-running))
        ;; A narrow board shortens the settings first: the button stays
        ;; whole, to be clicked, until the settings would be too short.
        (with-current-buffer board
          (let ((line (harness-ui-tasks--new-settings-line 44)))
            (should (= 44 (string-width line)))
            (should (string-suffix-p "…   4 at a time" line))
            (should (eq 'harness-ui-tasks-set-max-running
                        (get-text-property (1- (length line)) 'harness-task-button line))))
          (let ((line (harness-ui-tasks--new-settings-line 30)))
            (should (<= (string-width line) 30))
            (should-not (string-search "4 at a time" line))))
        ;; Refine and Plan show it too: what they write up takes no
        ;; slot, but the work does once it starts.
        (with-current-buffer board
          (dolist (mode '(refine plan))
            (harness-ui-tasks-cycle-mode mode)
            (should (harness-ui-tasks-test--limit board))
            (should (string-search "At most 4 tasks at once" (nth 1 (harness-ui-tasks-test--limit board))))
            (should (string-prefix-p (format " %s " mode) (harness-ui-tasks-test--tail-line board 'step))))
          (harness-ui-tasks-cycle-mode 'submit))
        (harness-ui-tasks-test--limit-says board "4 at a time")))))

;;;; In the merge queue

(defun harness-ui-tasks-test--card-text (board text)
  "The text of BOARD's card whose title shows TEXT, every line of it."
  (with-current-buffer board
    (save-excursion
      (harness-ui-tasks-test--goto-card board text)
      (buffer-substring-no-properties
       (line-beginning-position)
       (or (next-single-property-change (point) 'harness-task-id) (point-max))))))

(defun harness-ui-tasks-test--card-lines (board text)
  "How many lines BOARD's card whose title shows TEXT takes."
  (length (split-string (harness-ui-tasks-test--card-text board text) "\n" t)))

(ert-deftest harness-ui-tasks-merging-section ()
  "Tasks the merge queue holds get a section of their own, after review.
They keep the queue's order, and the heading counts them.  A card there is
one line, its recap folded as in review: the section says what the task
is doing, and the line says when its merge is under way or in conflict.
Shown, the subtitle says where the branch stands beside the recap, a
conflict which files its session is resolving."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--subtitles nil))
      (harness-ui-tasks-test--type-and-submit board "First to merge")
      (harness-ui-tasks-test--type-and-submit board "Second to merge")
      (harness-ui-tasks-test--wait-text board "Pending  2")
      (let ((first (harness-ui-tasks-test--card-id board "First to merge"))
            (second (harness-ui-tasks-test--card-id board "Second to merge"))
            (now (float-time)))
        ;; The first branch waits for the queue's turn; the second resolves
        ;; the conflicts the queue handed it (it joined later).
        (harness-ui-tasks-test--change board first :state "merging" :column "merging"
                                       :merge-status "queued" :merge-queued (- now 120) :base "main"
                                       :recap "Paged the orders endpoint.")
        (harness-ui-tasks-test--change board second :state "merging" :column "merging"
                                       :merge-status "conflict" :merge-queued (- now 5) :base "main"
                                       :conflicts '("shared.txt" "settings.py"))
        ;; Review on, so the empty Ready for review section shows: that the
        ;; merging section sits after it is what this checks.
        (with-current-buffer board
          (setq harness-ui-tasks--settings
                (plist-put (copy-sequence harness-ui-tasks--settings) :require-verification t)))
        (with-current-buffer board (harness-ui-tasks--render))
        (let ((text (harness-ui-tasks-test--board-text board)))
          ;; Between Ready for review and In progress, and not in Pending.
          (should (string-match-p
                   (concat "Ready for review  0\\(.\\|\n\\)*Merging  2\\(.\\|\n\\)*In progress  0"
                           "\\(.\\|\n\\)*Pending  0\\(.\\|\n\\)*Completed  0")
                   text))
          ;; The branch that joined first comes first.
          (should (string-match-p "First to merge\\(.\\|\n\\)*Second to merge" text))
          ;; Folded: neither the recap nor the detail line shows.
          (should-not (string-match-p "Paged the orders" text))
          (should-not (string-match-p "queued to merge into\\|resolving merge conflicts" text)))
        ;; One line each, which says where the branch stands: waiting for
        ;; the queue's turn, or in conflict.
        (should (= 1 (harness-ui-tasks-test--card-lines board "First to merge")))
        (let ((card (harness-ui-tasks-test--card-text board "First to merge")))
          (should (string-match-p "queued 2m ago" card))
          (should-not (string-match-p "conflict\\|merging now" card)))
        (should (= 1 (harness-ui-tasks-test--card-lines board "Second to merge")))
        ;; The merge and the time are facts of their own, in columns.
        (should (string-match-p "conflict +queued [0-9]+s ago"
                                (harness-ui-tasks-test--card-text board "Second to merge")))
        ;; Shown, a conflict says which files its session is resolving.
        (harness-ui-tasks-test--show-subtitle board "Second to merge")
        (should (= 2 (harness-ui-tasks-test--card-lines board "Second to merge")))
        (should (string-match-p "resolving merge conflicts in shared\\.txt, settings\\.py"
                                (harness-ui-tasks-test--card-text board "Second to merge")))
        ;; A merge in flight says so on its line.
        (harness-ui-tasks-test--change board first :merge-status "merging")
        (with-current-buffer board (harness-ui-tasks--render))
        (should (= 1 (harness-ui-tasks-test--card-lines board "First to merge")))
        (should (string-match-p "merging now +queued 2m ago"
                                (harness-ui-tasks-test--card-text board "First to merge")))
        ;; TAB on the card shows its recap, with the merge beside it, and
        ;; folds it away again.
        (with-current-buffer board
          (harness-ui-tasks-test--goto-card board "First to merge")
          (harness-ui-tasks-tab))
        (should (= 2 (harness-ui-tasks-test--card-lines board "First to merge")))
        (should (string-match-p "Paged the orders endpoint\\. · merging into main…"
                                (harness-ui-tasks-test--card-text board "First to merge")))
        (with-current-buffer board
          (harness-ui-tasks-test--goto-card board "First to merge")
          (harness-ui-tasks-tab))
        (should (= 1 (harness-ui-tasks-test--card-lines board "First to merge")))
        (should-not (string-match-p "Paged the orders" (harness-ui-tasks-test--board-text board)))
        ;; The heading counts them; the header leaves it to the heading.
        (let ((header (with-current-buffer board (harness-ui-tasks--header most-positive-fixnum))))
          (should-not (string-match-p "↣ 2\\|merge 2" header)))
        ;; Once it merged it shows under Completed, not in the queue.
        (harness-ui-tasks-test--change board first :state "done" :column "done" :merge-status nil
                                       :merged t :finished now)
        (with-current-buffer board (harness-ui-tasks--render))
        (should (string-match-p "Merging  1\\(.\\|\n\\)*In progress  0\\(.\\|\n\\)*Pending  0\\(.\\|\n\\)*Completed  1"
                                (harness-ui-tasks-test--board-text board)))))))

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

(defun harness-ui-tasks-test--arrow-position (board text)
  "The buffer position of the priority arrow on the card in BOARD showing TEXT."
  (with-current-buffer board
    (harness-ui-tasks-test--goto-card board text)
    (let ((end (line-end-position))
          (glyphs (list (harness-ui-icon 'harness-icon-priority-high)
                        (harness-ui-icon 'harness-icon-priority-low)))
          found)
      (dolist (glyph glyphs)
        (save-excursion
          (goto-char (line-beginning-position))
          (when (search-forward glyph end t) (setq found (match-beginning 0)))))
      found)))

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

(ert-deftest harness-ui-tasks-waiting-card-shows-the-task-name ()
  "A task is named as soon as it is submitted, so a card waiting for a slot
shows its title, not its raw prompt; the line under it says where it is
in line, then what its prompt asks."
  (harness-ui-tasks-test-with
    (harness-test-load-module 'naming)
    (let ((harness-tasks-max-running 0)
          (harness-naming-auto t)
          (harness-provider-demo-script-override
           (lambda (request)
             (if (plist-get request :ephemeral)
                 '((:type text :delta "Schedule the nightly export") (:type done :stop-reason end-turn))
               '((:type text :delta "Working on it.") (:type done :stop-reason end-turn))))))
      (harness-ui-tasks-test--type-and-submit board "make the export run every night at 2am")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Schedule the nightly export")
      (should-not (string-match-p "make the export run" (harness-ui-tasks-test--board-text board)))
      (harness-ui-tasks-test--show-subtitle board "Schedule the nightly export")
      (should (string-match-p "#1 in line · make the export run every night at 2am"
                              (harness-ui-tasks-test--card-text board "Schedule the nightly export"))))))

(ert-deftest harness-ui-tasks-needs-input-shows-the-recap ()
  "The needs-input column shows the recap, with the request beside it."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type tool-call :id "demo-q" :name "ask_user"
                    :input (:question "Which colour?" :options ("red" "green")))
             (:type text :delta "Noted.")
             (:type done :stop-reason end-turn))))
      (harness-test-load-module 'tools-question)
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

(ert-deftest harness-ui-tasks-holds-back-the-fewest-cards ()
  "A capped board holds back as few cards as the window needs held back.
The fitting measures what each card takes instead of bisecting the
number to hold back; showing one card more than it holds back must then
overflow the window, or a card that fits went missing."
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
              (should (harness-ui-tasks--fits-p window))
              (let ((held (harness-ui-tasks--held (cdr harness-ui-tasks--fitting))))
                (should (> held 0))
                ;; One card fewer held back: the compose box would not fit.
                (let ((inhibit-read-only t)
                      (caps (harness-ui-tasks--empty-caps)))
                  (harness-ui-tasks--cap-cards caps (harness-ui-tasks--visible) (1- held))
                  (harness-ui-tasks--draw-board caps)
                  (should-not (harness-ui-tasks--fits-p window))))))
      (set-frame-height nil 25)))))

;;;; Sections opened with [Show all] close when the window holds nothing back

(defvar harness-ui-tasks--expanded)
(defvar harness-ui-tasks--folded)
(defvar harness-ui-tasks--drawn-key)
(defvar harness-ui-tasks--cap-min-lines)
(declare-function harness-ui-tasks--needs-open-p "harness-ui-tasks")
(declare-function harness-ui-tasks--fits-p "harness-ui-tasks")
(declare-function harness-ui-tasks--window "harness-ui-tasks")
(declare-function harness-ui-tasks-show-all "harness-ui-tasks")

(defmacro harness-ui-tasks-test-in-frame (height &rest body)
  "Run BODY with the frame HEIGHT lines tall and `window' the board's window.
For use in `harness-ui-tasks-test-with', which names `board': a batch
window is too short for the headings alone, so a test that caps
sections makes the frame taller, and puts it back after."
  (declare (indent 1))
  `(unwind-protect
       (progn
         (set-frame-height nil ,height)
         (let ((window (get-buffer-window board)))
           (should window)
           (select-window window)
           ,@body))
     (set-frame-height nil 25)))

(defun harness-ui-tasks-test--fake-pending (board n)
  "Put N pending tasks on BOARD, as the harness's own store would."
  (with-current-buffer board
    (setq harness-ui-tasks--tasks
          (append harness-ui-tasks--tasks
                  (cl-loop for i below n
                           collect (list :id (format "t-wait%03d" i)
                                         :project harness-ui-tasks--project
                                         :cwd harness-ui-tasks--dir
                                         :prompt (format "Waiting task %d: tidy the orders API" i)
                                         :state "pending" :column "pending"
                                         :created (- (float-time) (* 60 i))))))))

(defun harness-ui-tasks-test--archive-done (board keep)
  "Archive all but KEEP of BOARD's completed tasks, as archiving them would."
  (with-current-buffer board
    (let ((kept 0))
      (setq harness-ui-tasks--tasks
            (mapcar (lambda (task)
                      (if (and (equal (plist-get task :column) "done")
                               (not (plist-get task :archived))
                               (> (cl-incf kept) keep))
                          (plist-put (copy-sequence task) :archived t)
                        task))
                    harness-ui-tasks--tasks)))))

(defun harness-ui-tasks-test--show-all (board)
  "Push BOARD's [Show all]: the first capped section opens."
  (with-current-buffer board
    (goto-char (point-min))
    (search-forward "[Show all]")
    (goto-char (line-beginning-position))
    (call-interactively #'harness-ui-tasks-show-all)))

(defun harness-ui-tasks-test--count (regexp board)
  "How many times REGEXP matches in BOARD's board region."
  (let ((text (harness-ui-tasks-test--board-text board)) (n 0) (start 0))
    (while (string-match regexp text start)
      (cl-incf n)
      (setq start (match-end 0)))
    n))

(ert-deftest harness-ui-tasks-show-fewer-goes-once-the-section-fits ()
  "An open section loses its [Show fewer] when its list shrinks to fit.
Archiving completed tasks leaves the section still too tall for the
window: folding it would hold cards back, so the line stays.  Archiving
on until the whole board fits leaves nothing for the line to fold back:
it goes, and the section is no longer open, so a list that grows past
the window again is capped again, with its [Show all]."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (harness-ui-tasks-test--show-all board)
        (should (memq 'done harness-ui-tasks--expanded))
        (should (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))
        ;; Fewer, but more than the window holds: the line is still needed.
        (harness-ui-tasks-test--archive-done board 45)
        (harness-ui-tasks--render)
        (should (string-match-p "Completed  45" (harness-ui-tasks-test--board-text board)))
        (should-not (harness-ui-tasks--fits-p window))
        (should (memq 'done harness-ui-tasks--expanded))
        (should (= 1 (harness-ui-tasks-test--count "\\[Show fewer\\]" board)))
        ;; Few enough to fit whole: the line goes, and the section closes.
        ;; Point is on the line that goes, and rests on the board.
        (goto-char (point-min))
        (search-forward "[Show fewer]")
        (goto-char (match-beginning 0))
        (harness-ui-tasks-test--archive-done board 5)
        (harness-ui-tasks--render)
        (should (< (point) (marker-position harness-ui-tasks--list-end)))
        (should-not (string-search "Show fewer" (buffer-substring-no-properties
                                                 (line-beginning-position) (line-end-position))))
        (should (string-match-p "Completed  5" (harness-ui-tasks-test--board-text board)))
        (should (harness-ui-tasks--fits-p window))
        (should (string-match-p "Completed task 4" (harness-ui-tasks-test--board-text board)))
        (should-not (string-match-p "\\[Show fewer\\]\\|\\[Show all\\]" (harness-ui-tasks-test--board-text board)))
        (should-not harness-ui-tasks--expanded)
        ;; The list grows past the window again: capped, not left open.
        (setq harness-ui-tasks--tasks
              (mapcar (lambda (task) (plist-put (copy-sequence task) :archived nil))
                      harness-ui-tasks--tasks))
        (harness-ui-tasks--render)
        (should (harness-ui-tasks--fits-p window))
        (should (string-match-p "more +\\[Show all\\]" (harness-ui-tasks-test--board-text board)))
        (should-not (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))))))

(ert-deftest harness-ui-tasks-show-all-goes-once-the-section-fits ()
  "The \"N more\" line of a capped section goes when its list shrinks to fit.
A capped section says how many cards it holds back and offers
[Show all]; when tasks leave it until the whole board fits the window,
it holds none back and the line has nothing to say."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (should (string-match-p "more +\\[Show all\\]" (harness-ui-tasks-test--board-text board)))
        (should (> (harness-ui-tasks--held (cdr harness-ui-tasks--fitting)) 0))
        (harness-ui-tasks-test--archive-done board 5)
        (harness-ui-tasks--render)
        (should (string-match-p "Completed  5" (harness-ui-tasks-test--board-text board)))
        (should-not (string-match-p "more +\\[Show all\\]\\|\\[Show all\\]" (harness-ui-tasks-test--board-text board)))
        (should (zerop (harness-ui-tasks--held (cdr harness-ui-tasks--fitting))))
        (should (harness-ui-tasks--fits-p window))))))

(ert-deftest harness-ui-tasks-open-section-is-checked-once-per-shape ()
  "Whether an open section is still needed is not asked on every redraw.
A section that needs it is checked when the board's shape changes, then
kept without asking while only what the cards read changes; one that
does not is closed in the redraw that finds out, and that redraw is the
board as drawn then: the next one has nothing to redraw."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (harness-ui-tasks-test--show-all board)
        (should (memq 'done harness-ui-tasks--expanded))
        (let ((asked 0))
          (cl-letf* ((real (symbol-function 'harness-ui-tasks--needs-open-p))
                     ((symbol-function 'harness-ui-tasks--needs-open-p)
                      (lambda (&rest args) (cl-incf asked) (apply real args))))
            ;; Needed, and known to be: redrawing the same board asks nothing.
            (harness-ui-tasks--render t)
            (harness-ui-tasks--render t)
            (should (zerop asked))
            (should (memq 'done harness-ui-tasks--expanded))
            ;; The list shrinks to fit: asked once, which closes the section.
            (harness-ui-tasks-test--archive-done board 5)
            (harness-ui-tasks--render)
            (should (= 1 asked))
            (should-not harness-ui-tasks--expanded)
            (should-not (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))
            ;; And the board fitted again without it asked nothing more.
            (harness-ui-tasks--render t)
            (should (= 1 asked))))
        ;; The board was drawn once for it: what it depends on, with the
        ;; section closed, is what was drawn, so no redraw follows.
        (should (equal harness-ui-tasks--drawn-key (harness-ui-tasks--board-key)))))))

(ert-deftest harness-ui-tasks-open-section-closes-in-a-window-too-small-to-cap ()
  "Nothing is capped in a window with no room to speak of, so nothing needs opening.
The board is drawn whole there and scrolls; an open section would have
a [Show fewer] that does nothing.  It goes, and the section is capped
again when the window has room."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (harness-ui-tasks-test--show-all board)
        (should (memq 'done harness-ui-tasks--expanded)))
      (set-frame-height nil 20)
      (should (< (window-body-height window) harness-ui-tasks--cap-min-lines))
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (should-not harness-ui-tasks--expanded)
        (should (string-match-p "Completed task 59" (harness-ui-tasks-test--board-text board)))
        (should-not (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board))))
      (set-frame-height nil 40)
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (should (string-match-p "more +\\[Show all\\]" (harness-ui-tasks-test--board-text board)))
        (should (harness-ui-tasks--fits-p window))))))

(ert-deftest harness-ui-tasks-open-section-stays-while-the-board-is-hidden ()
  "A board no window shows keeps what you opened.
There is no window to measure, so nothing says the section is not
needed; it is checked when the board is shown again."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 3)
    (harness-ui-tasks-test-in-frame 40
      (let ((elsewhere (get-buffer-create " *harness-tasks-test-elsewhere*")))
        (unwind-protect
            (with-current-buffer board
              (setq harness-ui-tasks--expanded '(done))
              (set-window-buffer window elsewhere)
              (should-not (harness-ui-tasks--window))
              (harness-ui-tasks--render t)
              (should (equal '(done) harness-ui-tasks--expanded))
              (should (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))
              (set-window-buffer window board)
              (select-window window)
              (harness-ui-tasks--render t)
              (should-not harness-ui-tasks--expanded)
              (should-not (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board))))
          (kill-buffer elsewhere))))))

(ert-deftest harness-ui-tasks-folded-section-keeps-its-expansion ()
  "Nothing of a folded section shows, so what you opened in it is not judged.
Unfolded, it is: the section that fits closes."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 3)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (setq harness-ui-tasks--expanded '(done)
              harness-ui-tasks--folded '(done))
        (harness-ui-tasks--render t)
        (should (equal '(done) harness-ui-tasks--expanded))
        (setq harness-ui-tasks--folded nil)
        (harness-ui-tasks--render t)
        (should-not harness-ui-tasks--expanded)))))

(ert-deftest harness-ui-tasks-open-section-stays-for-the-urgent-ones-it-spares ()
  "A section stays open while folding it would cap it, and with it a section after it.
Completed is open and short enough to fit, but the board does not fit
with it open: Pending, which is more urgent, is capped to make room.
Folded, Completed would be capped first and spare Pending, so its
[Show fewer] is worth having, and it stays."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 10)
    (harness-ui-tasks-test--fake-pending board 30)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (setq harness-ui-tasks--expanded '(done))
        (harness-ui-tasks--render t)
        (should (harness-ui-tasks--fits-p window))
        (should (equal '(done) harness-ui-tasks--expanded))
        (should (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))
        (should (string-match-p "more +\\[Show all\\]" (harness-ui-tasks-test--board-text board)))
        (should (string-match-p "Completed task 9" (harness-ui-tasks-test--board-text board)))
        ;; The oldest wait first; the newest are the cards held back.
        (should (string-match-p "Waiting task 29" (harness-ui-tasks-test--board-text board)))
        (should-not (string-match-p "Waiting task 0:" (harness-ui-tasks-test--board-text board)))))))

(ert-deftest harness-ui-tasks-open-section-closes-when-a-less-urgent-one-makes-room ()
  "A section closes when the fitting never needed it open.
Pending is open and short enough to fit, with Completed, which is less
urgent, taking all the capping: folded, Pending would not be capped, so
its [Show fewer] would do nothing and goes.  Completed stays capped."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 40)
    (harness-ui-tasks-test--fake-pending board 10)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (setq harness-ui-tasks--expanded '(pending))
        (harness-ui-tasks--render t)
        (should (harness-ui-tasks--fits-p window))
        (should-not harness-ui-tasks--expanded)
        (should-not (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))
        (should (string-match-p "Waiting task 9" (harness-ui-tasks-test--board-text board)))
        (should (= 1 (harness-ui-tasks-test--count "more +\\[Show all\\]" board)))
        (should-not (string-match-p "Completed task 39" (harness-ui-tasks-test--board-text board)))))))

(ert-deftest harness-ui-tasks-open-section-beside-a-longer-one-stays-open ()
  "A section stays open when folding it would hold cards back, whatever else is open.
Completed and Pending are both open and the window holds neither whole:
Completed is capped first when only one is folded, but folding Pending
caps Pending, as Completed stays open.  Each keeps its [Show fewer],
as a user who opened both would have it; once few enough tasks are left
for the board to fit, both close."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (harness-ui-tasks-test--fake-pending board 3)
    (harness-ui-tasks-test-in-frame 40
      (with-current-buffer board
        (setq harness-ui-tasks--expanded '(done pending))
        (harness-ui-tasks--render t)
        (should-not (harness-ui-tasks--fits-p window))
        (should (equal '(done pending) (sort (copy-sequence harness-ui-tasks--expanded) #'string<)))
        (should (= 2 (harness-ui-tasks-test--count "\\[Show fewer\\]" board)))
        (harness-ui-tasks-test--archive-done board 3)
        (harness-ui-tasks--render)
        (should (harness-ui-tasks--fits-p window))
        (should-not harness-ui-tasks--expanded)
        (should-not (string-match-p "\\[Show fewer\\]" (harness-ui-tasks-test--board-text board)))))))

;;;; How long a pending task has waited

(declare-function harness-ui-tasks--queued-since "harness-ui-tasks")

(ert-deftest harness-ui-tasks-queued-since-counts-from-the-queue ()
  "A pending card says how long its task has waited in the queue.
That is since the harness last queued it (`:queued-at'), else since it
was returned to pending, else since it was submitted: a task written
days ago and put back in the queue waits from then, not from the day it
was written."
  (harness-ui-tasks-test-with
    (let* ((now (float-time))
           (written (- now (* 3 86400))))
      (should (equal (- now 300)
                     (harness-ui-tasks--queued-since
                      (list :queued-at (- now 300) :returned (- now 200) :created written))))
      (should (equal (- now 200)
                     (harness-ui-tasks--queued-since (list :returned (- now 200) :created written))))
      (should (equal written (harness-ui-tasks--queued-since (list :created written))))
      ;; The card says so, each from its own start.
      (harness-ui-tasks-test--fake-pending board 3)
      (harness-ui-tasks-test--change board "t-wait000" :created written :queued-at (- now 300))
      (harness-ui-tasks-test--change board "t-wait001" :created written :returned (- now 7200))
      (harness-ui-tasks-test--change board "t-wait002" :created written)
      (with-current-buffer board (harness-ui-tasks--render t))
      (should (string-match-p "queued 5m ago" (harness-ui-tasks-test--card-text board "Waiting task 0")))
      (should (string-match-p "queued 2h ago" (harness-ui-tasks-test--card-text board "Waiting task 1")))
      (should (string-match-p "queued 3d ago" (harness-ui-tasks-test--card-text board "Waiting task 2"))))))

(ert-deftest harness-ui-tasks-redraw-for-figures-keeps-the-fitting ()
  "A redraw for a card's figures draws the caps again, without measuring.
A working task's cost, tokens and rate change many times a second: the
board then draws the cards its window shows, with the fitting it
measured, and the card reads the new figure."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test--fake-done board 60)
    (let ((figures (list :id "t-figures" :name "A task whose figures change"
                         :prompt "A task whose figures change" :state "done" :column "done"
                         :merged t :session "s-figures" :verified-at (float-time)
                         :created (- (float-time) 600) :started (- (float-time) 590)
                         :finished (float-time))))
      (with-current-buffer board
        (setq harness-ui-tasks--tasks (cons figures harness-ui-tasks--tasks))
        (harness-ui-cache-session (list :id "s-figures" :name "A task whose figures change"
                                        :status "inactive" :usage (list :cost 0.5 :list-cost 0.5))))
      (unwind-protect
          (progn
            (set-frame-height nil 40)
            (let ((window (get-buffer-window board)))
              (should window)
              (select-window window)
              (with-current-buffer board
                (harness-ui-tasks--render t)
                (should (string-match-p "\\$0\\.500" (harness-ui-tasks-test--board-text board))))
              (let ((measured 0)
                    (fitting (cdr harness-ui-tasks--fitting)))
                (cl-letf* ((real (symbol-function 'harness-ui-tasks--caps-that-fit))
                           ((symbol-function 'harness-ui-tasks--caps-that-fit)
                            (lambda (w g b) (cl-incf measured) (funcall real w g b))))
                  (with-current-buffer board
                    ;; The cost changes: the card reads it, the board's
                    ;; shape -- which cards show and how tall they are --
                    ;; does not.
                    (harness-ui-cache-session
                     (list :id "s-figures" :name "A task whose figures change"
                           :status "inactive" :usage (list :cost 2.0 :list-cost 2.0)))
                    (harness-ui-tasks--render)
                    (should (zerop measured))
                    ;; The same fitting, not a new one that happens to fit.
                    (should (eq fitting (cdr harness-ui-tasks--fitting)))
                    (should (string-match-p "\\$2\\.00" (harness-ui-tasks-test--board-text board)))))))))
      (set-frame-height nil 25))))

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

;;;; What the tasks cost, in the header

(defvar harness-ui--quotas)
(declare-function harness-ui--store-quota "harness-ui")

(defun harness-ui-tasks-test--header (board &optional width)
  "BOARD's header line as it reads, fitted to WIDTH columns, else whole.
The line shows each %% as one %.  \(`format-mode-line' would do that,
but formats nothing in batch.)"
  (with-current-buffer board
    (replace-regexp-in-string "%%" "%" (harness-ui-tasks--header (or width most-positive-fixnum)) t t)))

(defun harness-ui-tasks-test--sessions (board)
  "The session ids of BOARD's tasks."
  (delq nil (mapcar (lambda (task) (plist-get task :session))
                    (buffer-local-value 'harness-ui-tasks--tasks board))))

(defun harness-ui-tasks-test--multi-line-help (text)
  "The `help-echo' strings of TEXT that take more than one line."
  (let ((pos 0) out)
    (while (< pos (length text))
      (let ((help (get-text-property pos 'help-echo text)))
        (when (and (stringp help) (string-match-p "\n" help))
          (push help out)))
      (setq pos (or (next-single-property-change pos 'help-echo text) (length text))))
    out))

(ert-deftest harness-ui-tasks-header-shows-the-plan-and-its-quota ()
  "Tasks a subscription pays for show the plan and its quota in the header.
As in a chat's header: the plan's name with its quota windows, and in
the tooltip, on one line, what the tasks used at API prices.  A click
opens the usage dashboard."
  (harness-ui-tasks-test-with
    (clrhash harness-ui--quotas)
    (harness-ui--store-quota "demo" '(:billing "subscription" :plan "max" :plan-label "Claude Max"
                                      :windows ((:name "5h" :label "Current session (5 hours)" :used 0.23)
                                                (:name "7d" :label "This week, all models" :used 0.41))))
    ;; Before any task the board says who pays for new ones: their
    ;; model's provider, once the board knows the model.
    (harness-test-wait (lambda () (string-match-p "  Max . 5h 23% . 7d 41%  " (harness-ui-tasks-test--header board)))
                       5 "the plan and its quota")
    (harness-ui-tasks-test--type-and-submit board "Fix the flaky test")
    (harness-ui-tasks-test--wait-text board "Completed  1")
    (let ((sid (car (harness-ui-tasks-test--sessions board))))
      (harness-call 'session/usage-add sid '(:input 100 :output 10 :cost 0.0 :list-cost 2.5
                                             :billing subscription :plan "max"))
      (harness-test-wait (lambda () (equal "subscription" (format "%s" (plist-get (plist-get (harness-ui-session sid) :usage)
                                                                                 :billing))))
                         5 "the session update")
      (with-current-buffer board
        (let* ((header (harness-ui-tasks--header most-positive-fixnum))
               (pos (string-match "Max" header))
               (help (get-text-property pos 'help-echo header))
               (opened nil))
          (should (string-match-p "Covered by Claude Max, not billed per token\\. These tasks at API prices: \\$2\\.50\\." help))
          (should (string-match-p "Current session (5 hours): 23% used" help))
          ;; One line, or showing it in the echo area moves the header.
          (should-not (harness-ui-tasks-test--multi-line-help header))
          ;; Escaped for the header line, which would take "23% " for a %-construct.
          (should (string-match-p "5h 23%% " header))
          (cl-letf (((symbol-function 'harness-ui-show-usage) (lambda () (interactive) (setq opened t))))
            (funcall (lookup-key (get-text-property pos 'local-map header) [header-line mouse-1])))
          (should opened))))))

(ert-deftest harness-ui-tasks-header-shows-cost-and-budgets ()
  "Tasks billed per token show their summed cost, then the project's budgets.
The fullest budget shows as a quota window does, its tooltip describes
each that applies, on one line, and setting a budget reloads them."
  (harness-ui-tasks-test-with
    (clrhash harness-ui--quotas)
    (harness-test-load-module 'usage)
    (harness-ui-tasks-test--type-and-submit board "First task")
    (harness-ui-tasks-test--type-and-submit board "Second task")
    (harness-ui-tasks-test--wait-text board "Completed  2")
    (pcase-let ((`(,first ,second) (harness-ui-tasks-test--sessions board)))
      (harness-call 'session/usage-add first '(:input 100 :output 10 :cost 1.25 :billing api))
      (harness-call 'session/usage-add second '(:input 100 :output 10 :cost 0.5 :billing api)))
    (harness-test-wait (lambda () (string-match-p "  \\$1\\.75  " (harness-ui-tasks-test--header board)))
                       5 "the summed cost")
    (with-current-buffer board
      (let ((header (harness-ui-tasks--header most-positive-fixnum)))
        (should (string-match-p "\\`These tasks cost \\$1\\.75, billed per token\\."
                                (get-text-property (string-match "\\$1\\.75" header) 'help-echo header)))))
    ;; A budget of everything and a tighter one of the project: the fullest shows.
    (harness-call 'usage/set-budget '(:scope period :period month :amount 10 :label "monthly cap"))
    (harness-call 'usage/set-budget (list :scope 'project :target dir :amount 2 :hard t :label "project cap"))
    (harness-call 'usage/set-budget (list :scope 'project :target (harness-test-temp-dir) :amount 1 :label "elsewhere"))
    (harness-test-wait (lambda () (string-match-p "  \\$1\\.75 . budget 88%  " (harness-ui-tasks-test--header board)))
                       5 "the budgets")
    (with-current-buffer board
      (let* ((header (harness-ui-tasks--header most-positive-fixnum))
             (pos (string-match "budget" header))
             (help (get-text-property pos 'help-echo header)))
        (should (eq 'harness-context-urgent-face (get-text-property pos 'face header)))
        (should (string-match-p (concat "\\`project cap: \\$1\\.75 of \\$2\\.00 spent; \\$0\\.250 left (hard)\\. "
                                        "monthly cap: \\$1\\.75 of \\$10\\.00 spent; \\$8\\.25 left, \\$[0-9.]+/day")
                                help))
        (should-not (string-match-p "elsewhere" help))
        (should-not (harness-ui-tasks-test--multi-line-help header))
        (should (get-text-property pos 'local-map header))))))

(ert-deftest harness-ui-tasks-header-keeps-the-quota-when-narrow ()
  "In a narrow window the plan's quota outlasts the buttons and the name.
The budget makes room first; the plan and its quota windows stay longest
but for [Refresh], still opening the usage dashboard."
  (harness-ui-tasks-test-with
    (clrhash harness-ui--quotas)
    (harness-test-load-module 'usage)
    (harness-ui--store-quota "demo" '(:billing "subscription" :plan "max" :plan-label "Claude Max"
                                      :windows ((:name "5h" :used 0.23) (:name "7d" :used 0.41))))
    (harness-call 'usage/set-budget '(:scope period :period month :amount 10 :label "monthly cap"))
    (harness-test-wait (lambda () (string-match-p "  Max . 5h 23% . 7d 41% . budget 0%  "
                                                  (harness-ui-tasks-test--header board)))
                       5 "the plan, its quota and the budget")
    ;; The buttons and the project's name go before the quota, which
    ;; keeps the wide separator after the title (see
    ;; `harness-ui-tasks--header'): the queue's switch, which had it
    ;; before, is on the Pending heading.
    (let ((header (harness-ui-tasks-test--header board 56)))
      (should (string-match-p "\\` Tasks   Max . 5h 23% . 7d 41% . budget 0% \\[Refresh\\]\\'" header)))
    ;; Narrower still, the budget goes and the quota stays.
    (let ((header (harness-ui-tasks-test--header board 50)))
      (should (string-match-p "\\` Tasks   Max . 5h 23% . 7d 41% \\[Refresh\\]\\'" header)))
    (with-current-buffer board
      (let* ((header (harness-ui-tasks--header 50))
             (pos (string-match "Max" header)))
        (should (get-text-property pos 'local-map header))
        (should (string-match-p "Covered by Claude Max" (get-text-property pos 'help-echo header)))))))

;;;; The fullscreen layout

(declare-function harness-fullscreen "harness-ui")
(declare-function harness-ui-quit-view "harness-ui")
(declare-function harness-ui--fullscreen-layout "harness-ui")
(declare-function harness-ui--overview-window-p "harness-ui")

(ert-deftest harness-ui-tasks-fullscreen-layout ()
  "F gives the board the fullscreen layout, a task's session beside it;
q on the board ends it.  C-c C-z does q's job from the compose box."
  (harness-ui-tasks-test-with
    (let* ((sessions nil)
           (harness-ui-open-session-function
            (lambda (id)
              (or (cdr (assoc id sessions))
                  (let ((buf (get-buffer-create (format " *fake session %s*" id))))
                    (push (cons id buf) sessions)
                    buf))))
           (main (get-buffer-window board)))
      (unwind-protect
          (progn
            (with-current-buffer board
              (goto-char (point-min))
              (should (eq 'harness-fullscreen (key-binding (kbd "F"))))
              (should (eq 'harness-ui-quit-view (key-binding (kbd "q"))))
              (goto-char harness-compose-end)
              (should (eq 'self-insert-command (key-binding (kbd "q"))))
              (should (eq 'harness-ui-bury (key-binding (kbd "C-c C-z")))))
            (harness-ui-tasks-test--type-and-submit board "First task")
            (harness-ui-tasks-test--wait-text board "Completed  1")
            (harness-ui-tasks-test--type-and-submit board "Second task")
            (harness-ui-tasks-test--wait-text board "Completed  2")
            (let* ((tasks (buffer-local-value 'harness-ui-tasks--tasks board))
                   (first (plist-get (cl-find "First task" tasks :key (lambda (task) (plist-get task :prompt))
                                              :test #'equal)
                                     :session)))
              ;; Beside the board: the session of the task at point.
              (with-selected-window main
                (goto-char (point-min))
                (search-forward "First task")
                (should (equal first (harness-ui-tasks--overview-session)))
                (harness-fullscreen))
              (let ((overview (get-buffer-window board)))
                (should (harness-ui--overview-window-p overview))
                (should (eq 'left (window-parameter overview 'window-side)))
                (should (eq (cdr (assoc first sessions)) (window-buffer main)))
                ;; q on the board ends the layout and buries the board.
                (with-selected-window overview
                  (goto-char (point-min))
                  (call-interactively (key-binding (kbd "q"))))
                (should-not (harness-ui--fullscreen-layout))
                (should-not (get-buffer-window board))
                (should (eq 'full (buffer-local-value 'harness-ui-position board))))))
        (mapc (lambda (entry) (kill-buffer (cdr entry))) sessions)))))

(declare-function harness-ui-anchor-p "harness-ui")
(declare-function harness-ui--fullscreen-leave "harness-ui")
(declare-function harness-ui-session "harness-ui")

(ert-deftest harness-ui-tasks-fullscreen-opens-sessions-beside-the-board ()
  "In the fullscreen layout a task's session opens beside the board, every time.
A task's session is a main session, which could anchor a layout of its
own, but opened from the board -- RET on a card, or a click on it -- it
takes the slot, and the board keeps the anchor side.  After C-x 4 4,
RET opens it in another window instead, and the layout stays as it was."
  (harness-ui-tasks-test-with
    (let* ((sessions nil)
           (harness-ui-open-session-function
            (lambda (id)
              (or (cdr (assoc id sessions))
                  (let ((buf (get-buffer-create (format "*harness: fake session %s*" id))))
                    ;; What a chat buffer is to the layout: a session's conversation.
                    (with-current-buffer buf
                      (setq-local harness-ui-session-id id)
                      (setq-local major-mode 'harness-chat-mode))
                    (push (cons id buf) sessions)
                    buf))))
           (main (get-buffer-window board)))
      (unwind-protect
          (progn
            (harness-ui-tasks-test--type-and-submit board "First task")
            (harness-ui-tasks-test--wait-text board "Completed  1")
            (harness-ui-tasks-test--type-and-submit board "Second task")
            (harness-ui-tasks-test--wait-text board "Completed  2")
            (let* ((tasks (buffer-local-value 'harness-ui-tasks--tasks board))
                   (session-of (lambda (prompt)
                                 (plist-get (cl-find prompt tasks :key (lambda (task) (plist-get task :prompt))
                                                     :test #'equal)
                                            :session)))
                   (first (funcall session-of "First task"))
                   (second (funcall session-of "Second task"))
                   (first-buf (funcall harness-ui-open-session-function first))
                   (second-buf (funcall harness-ui-open-session-function second)))
              ;; The tasks' sessions are main sessions the UI knows.
              (harness-ui-refresh-sessions)
              (harness-test-wait (lambda () (and (harness-ui-session first) (harness-ui-session second)))
                                 5 "the tasks' sessions to be known")
              (should (harness-ui-anchor-p first-buf))
              ;; F with the first task at point: its session beside the board.
              (with-selected-window main
                (goto-char (point-min))
                (search-forward "First task")
                (harness-fullscreen))
              (let ((anchor (get-buffer-window board)))
                (should (harness-ui--overview-window-p anchor))
                (should (eq first-buf (window-buffer main)))
                ;; RET on the second task: its session takes the slot.
                (select-window anchor)
                (goto-char (point-min))
                (search-forward "Second task")
                (execute-kbd-macro (kbd "RET"))
                (should (eq second-buf (window-buffer main)))
                (should (eq board (window-buffer anchor)))
                (should (harness-ui--overview-window-p anchor))
                ;; A click on the first task's card: the same.
                (select-window anchor)
                (goto-char (point-min))
                (search-forward "First task")
                (harness-test-click (point))
                (should (eq first-buf (window-buffer main)))
                (should (eq board (window-buffer anchor)))
                (should (harness-ui--overview-window-p anchor))
                ;; C-x 4 4 RET: another window, the layout as it was.
                (select-window anchor)
                (goto-char (point-min))
                (search-forward "Second task")
                (execute-kbd-macro (kbd "C-x 4 4 RET"))
                (let ((window (get-buffer-window second-buf)))
                  (should window)
                  (should-not (memq window (list anchor main))))
                (should (eq first-buf (window-buffer main)))
                (should (eq board (window-buffer anchor)))
                (should (harness-ui--overview-window-p anchor))
                ;; The prefix is spent with the command.
                (should-not (car display-buffer-overriding-action)))))
        (ignore-errors (harness-ui--fullscreen-leave))
        (mapc (lambda (entry) (kill-buffer (cdr entry))) sessions)))))

(declare-function harness-toggle-supervisor "harness-ui-supervisor")
(declare-function harness-ui-tasks--supervisor-p "harness-ui-tasks")

(ert-deftest harness-ui-tasks-queue-suspends-from-the-board ()
  "P suspends the board's queue: the Pending heading's switch and the box say so.
The switch is on the heading, right after its count rather than at the
end of the line, and the header line has none.  A click on it resumes,
and the waiting task starts."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 1))
      (harness-ui-tasks-test--type-and-submit board "First task")
      (harness-ui-tasks-test--type-and-submit board "Waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  1  \\[Queue: running\\]\n\\(.\\|\n\\)*Waiting task")
      (with-current-buffer board
        (goto-char (point-min))
        (should (eq 'harness-ui-tasks-toggle-queue (key-binding (kbd "P"))))
        ;; Beside the count: two plain spaces, no stretch of space
        ;; pushing it to the right of the line.
        (search-forward "[Queue: running]")
        (let ((at (match-beginning 0)))
          (should (eq 'pending (get-text-property at 'harness-task-section)))
          (should (button-at at))
          (should (equal "Pending  1  " (buffer-substring-no-properties (- at 12) at)))
          (should-not (text-property-not-all (- at 12) at 'display nil))
          (should (string-match-p "\\`Queue running.*Click or P to suspend"
                                  (harness-ui-tasks--queue-help nil nil at))))
        (should-not (string-match-p "Queue" (harness-ui-tasks--header most-positive-fixnum)))
        (goto-char (point-min))
        (execute-kbd-macro "P"))
      ;; Suspended: the heading's switch says so, and so does the box.
      (harness-ui-tasks-test--wait-text board "Pending  1  \\[Queue: suspended\\]\n")
      (with-current-buffer board
        (should-not (string-match-p "Queue" (harness-ui-tasks--header most-positive-fixnum)))
        (should (string-match-p "\\`Queue suspended.*Click or P to resume"
                                (harness-ui-tasks--queue-help nil nil (point-min))))
        (should (string-match-p "queue suspended" (harness-ui-tasks--new-settings-line))))
      ;; The waiting task stays pending while the queue is suspended, and
      ;; its card says so, the facts coming with the tasks a moment later.
      (let ((id (harness-ui-tasks-test--card-id board "Waiting task")))
        (should (eq 'pending (plist-get (harness-call 'task/get id) :state)))
        (harness-test-wait
         (lambda () (with-current-buffer board
                      (plist-get (cl-find id harness-ui-tasks--tasks
                                          :key (lambda (task) (plist-get task :id)) :test #'equal)
                                 :queue-suspended)))
         5 "the board to hear the queue is suspended")
        (harness-ui-tasks-test--show-subtitle board "Waiting task")
        (should (string-match-p "queue suspended" (harness-ui-tasks-test--card-text board "Waiting task")))
        ;; A click on the switch resumes, which starts it.
        (with-current-buffer board
          (goto-char (point-min))
          (search-forward "[Queue: suspended]")
          (push-button (match-beginning 0)))
        (harness-test-wait (lambda () (eq 'active (plist-get (harness-call 'task/get id) :state)))
                           5 "the waiting task to start")
        (harness-ui-tasks-test--wait-text board "Pending  0  \\[Queue: running\\]\n")))))

(declare-function harness-tasks--schedule "harness-tasks")

(ert-deftest harness-ui-tasks-backlog-is-its-own-section ()
  "A backlog task waits in Backlog; Pending holds only what the queue starts.
The pending heading says the queue is suspended only when it really is,
and a queued task still drains from Pending to In progress while the
backlog task stays where it is."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           '((:type text :delta "Fix the lexer\n\nIt drops the last token.") (:type done :stop-reason end-turn))))
      ;; A queued task (0 at a time, so it waits) and one for the backlog.
      (harness-ui-tasks-test--type-and-submit board "Waits for a slot")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Waits for a slot")
      (with-current-buffer board (harness-ui-tasks-cycle-mode 'refine))
      (harness-ui-tasks-test--type-and-submit board "jot the lexer down")
      (harness-ui-tasks-test--wait-text board "Backlog  1\\(.\\|\n\\)*Fix the lexer")
      (let ((text (harness-ui-tasks-test--board-text board)))
        ;; The queued task is Pending, whose queue runs; the backlog has a
        ;; section of its own, saying only you start one, with no
        ;; suspended-queue notice.
        (should (string-match-p "Pending  1  \\[Queue: running\\]\n\\(.\\|\n\\)*Waits for a slot" text))
        (should (string-match-p "Backlog  1  \\[Manual queue\\]\n\\(.\\|\n\\)*Fix the lexer"
                                text))
        (should-not (string-match-p "suspended" text)))
      ;; Refined: the card says it waits to be started, not for a slot.
      (harness-ui-tasks-test--show-subtitle board "Fix the lexer")
      (should (string-match-p "written up"
                              (harness-ui-tasks-test--card-text board "Fix the lexer")))
      ;; Suspended: Pending says so; the backlog, which never drains on its
      ;; own, waits for you either way.
      (with-current-buffer board (harness-ui-tasks-toggle-queue))
      (harness-ui-tasks-test--wait-text board "Pending  1  \\[Queue: suspended\\]\n")
      (should (string-match-p "Backlog  1  \\[Manual queue\\]\n\\(.\\|\n\\)*Fix the lexer"
                              (harness-ui-tasks-test--board-text board)))
      ;; A free slot does not start either while the queue is suspended.
      (setq harness-tasks-max-running 1)
      (harness-tasks--schedule)
      (should (string-match-p "Pending  1\\(.\\|\n\\)*Waits for a slot"
                              (harness-ui-tasks-test--board-text board)))
      ;; Resuming starts the queued task; the backlog task stays, waiting
      ;; for its start by hand.
      (with-current-buffer board (harness-ui-tasks-toggle-queue))
      (harness-ui-tasks-test--wait-text board "Pending  0")
      (should (string-match-p "Backlog  1\\(.\\|\n\\)*Fix the lexer"
                              (harness-ui-tasks-test--board-text board))))))

(ert-deftest harness-ui-tasks-queue-a-backlog-task ()
  "Queue it on a backlog card moves it to Pending, where the queue starts it."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           '((:type text :delta "Fix the lexer\n\nIt drops the last token.") (:type done :stop-reason end-turn))))
      (with-current-buffer board (harness-ui-tasks-cycle-mode 'refine))
      (harness-ui-tasks-test--type-and-submit board "jot the lexer down")
      (harness-ui-tasks-test--wait-text board "Backlog  1\\(.\\|\n\\)*Fix the lexer")
      ;; The card offers the queue first, and the board key does the same.
      (harness-ui-tasks-test--goto-card board "Fix the lexer")
      (with-current-buffer board
        (should (equal '("Queue it" "Start now")
                       (take 2 (mapcar #'car
                                       (cl-remove 'harness-ui-tasks-open
                                                  (harness-ui-tasks--actions (harness-ui-tasks--task))
                                                  :key #'cadr)))))
        (should (eq 'harness-ui-tasks-queue (key-binding (kbd "Q"))))
        (harness-ui-tasks-queue))
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Fix the lexer")
      (let ((task (car (harness-call 'task/list default-directory))))
        (should (eq 'pending (plist-get task :state)))
        (should (eq 'pending (plist-get task :column)))
        (should-not (plist-get task :backlog)))
      (should (string-match-p "Backlog  0" (harness-ui-tasks-test--board-text board))))))

(declare-function harness-ui-tasks-toggle-backlog-mode "harness-ui-tasks")
(declare-function harness-ui-tasks--backlog-mode-help "harness-ui-tasks")

(ert-deftest harness-ui-tasks-backlog-mode-from-the-board ()
  "The Backlog's heading switches it between a manual and an auto queue.
The switch is right after the heading's count, not at the end of the
line.  W, or a click on [Manual queue], gives the project an auto
queue: a task written up for the backlog then joins the queue by itself,
and waits in Pending for a slot like any queued task.  A click on
\[Auto queue] switches back.  The tooltips say which it is, with the key."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           '((:type wait :seconds 1)
             (:type text :delta "Fix the lexer\n\nIt drops the last token.") (:type done :stop-reason end-turn))))
      ;; A queued task (0 at a time, so it waits) brings the columns out,
      ;; the Backlog's heading saying its tasks are queued by hand.
      (harness-ui-tasks-test--type-and-submit board "Waits for a slot")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Waits for a slot")
      (harness-ui-tasks-test--wait-text board "Backlog  0  \\[Manual queue\\]\n")
      (with-current-buffer board
        (goto-char (point-min))
        (search-forward "[Manual queue]")
        ;; Beside the count: two plain spaces, no stretch of space
        ;; pushing it to the right of the line.
        (should (equal "Backlog  0  " (buffer-substring-no-properties (- (match-beginning 0) 12) (match-beginning 0))))
        (should-not (text-property-not-all (- (match-beginning 0) 12) (match-beginning 0) 'display nil))
        (let ((help (harness-ui-tasks--backlog-mode-help nil nil (match-beginning 0))))
          (should (string-match-p "Manual queue: written-up tasks wait here" help))
          (should (string-match-p "Click or W for auto" help)))
        (should (eq 'harness-ui-tasks-toggle-backlog-mode (key-binding (kbd "W"))))
        (goto-char (point-min))
        (execute-kbd-macro "W"))
      ;; The heading switches at once, and the harness follows.
      (harness-ui-tasks-test--wait-text board "Backlog  0  \\[Auto queue\\]\n")
      (harness-test-wait (lambda () (eq 'auto (plist-get (harness-call 'task/backlog-mode default-directory) :mode)))
                         5 "the project's backlog to queue its tasks itself")
      (with-current-buffer board
        (should (string-match-p "Auto queue: written-up tasks join the queue"
                                (harness-ui-tasks--backlog-mode-help nil nil (point-min)))))
      ;; While its write-up goes on, the task waits in the Backlog.
      (with-current-buffer board (harness-ui-tasks-toggle-refine))
      (harness-ui-tasks-test--type-and-submit board "jot the lexer down")
      (harness-ui-tasks-test--wait-text
       board "Backlog  1  \\[Auto queue\\]\n\\(.\\|\n\\)*jot the lexer down")
      (harness-ui-tasks-test--show-subtitle board "jot the lexer down")
      (should (string-match-p "writing it up…"
                              (harness-ui-tasks-test--card-text board "jot the lexer down")))
      ;; Written up, it moves to Pending by itself, where it waits for a slot.
      (harness-ui-tasks-test--wait-text board "Pending  2\\(.\\|\n\\)*Fix the lexer")
      (should (string-match-p "Backlog  0  \\[Auto queue\\]\n" (harness-ui-tasks-test--board-text board)))
      (let ((task (cl-find-if (lambda (task) (string-prefix-p "Fix the lexer" (plist-get task :prompt)))
                              (harness-call 'task/list default-directory))))
        (should task)
        (should (eq 'pending (plist-get task :column)))
        (should-not (plist-get task :backlog))
        (should (plist-get task :auto-queue)))
      ;; A click on [Auto queue] gives the backlog back to your hand.
      (with-current-buffer board
        (goto-char (point-min))
        (search-forward "[Auto queue]")
        (push-button (match-beginning 0)))
      (harness-ui-tasks-test--wait-text board "Backlog  0  \\[Manual queue\\]\n")
      (harness-test-wait (lambda () (eq 'manual (plist-get (harness-call 'task/backlog-mode default-directory) :mode)))
                         5 "the project's backlog to be queued by hand again")
      ;; The switch moved nothing: the queued task still waits for a slot.
      (should (string-match-p "Pending  2\\(.\\|\n\\)*Fix the lexer"
                              (harness-ui-tasks-test--board-text board))))))

(ert-deftest harness-ui-tasks-return-to-pending-from-the-card ()
  "u returns the task at point to the pending queue, keeping its session.
It waits there, its card saying it carries on where it stopped; s starts
it again."
  (harness-ui-tasks-test-with
    (let ((harness-agent--cancel-grace 0.05)
          (harness-provider-demo-script-override '((:type wait :seconds 30))))
      (harness-ui-tasks-test--type-and-submit board "Long work")
      (harness-ui-tasks-test--wait-text board "In progress  1\\(.\\|\n\\)*Long work")
      (let ((id (harness-ui-tasks-test--card-id board "Long work")))
        (let ((sid (plist-get (harness-call 'task/get id) :session)))
          (with-current-buffer board
            (harness-ui-tasks-test--goto-card board "Long work")
            (should (eq 'harness-ui-tasks-return-to-pending (key-binding (kbd "u"))))
            (execute-kbd-macro "u"))
          ;; The card moves to Pending, stopped, with its session kept.
          (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Long work")
          (let ((task (harness-call 'task/get id)))
            (should (eq 'pending (plist-get task :state)))
            (should (plist-get task :returned))
            (should (equal sid (plist-get task :session))))
          (harness-ui-tasks-test--show-subtitle board "Long work")
          (should (string-match-p "#1 in line · paused"
                                  (harness-ui-tasks-test--card-text board "Long work")))
          ;; The return started nothing, and s starts it again.
          (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 5 "its turn to stop")
          (should (eq 'pending (plist-get (harness-call 'task/get id) :state)))
          (with-current-buffer board
            (harness-ui-tasks-test--goto-card board "Long work")
            (execute-kbd-macro "s"))
          (harness-test-wait (lambda () (eq 'active (plist-get (harness-call 'task/get id) :state)))
                             5 "the task to start again")
          (should (equal sid (plist-get (harness-call 'task/get id) :session))))))))

(declare-function harness-ui-tasks--returned-why "harness-ui-tasks")
(declare-function harness-ui-tasks--sent-back-message "harness-ui-tasks")

(ert-deftest harness-ui-tasks-says-why-a-returned-task-waits ()
  "A returned task's card says why it waits; sending work back says where it went.
A task pre-empted names the task sent back from review that took its
slot, by its title when the board has that task, and one whose borrowed
slot was taken back names the task that lent it; one sent back while no
slot could take it waits with the feedback.  The tasks have the shape
the wire gives them, symbols as strings."
  (harness-ui-tasks-test-with
    (with-temp-buffer
      (setq-local harness-ui-tasks--tasks (list (list :id "t-1" :prompt "Fix the parser\nand the lexer")))
      (should (equal "pre-empted by \"Fix the parser\""
                     (harness-ui-tasks--returned-why '(:returned t :return-reason "preempted" :preempted-by "t-1"))))
      (should (equal "pre-empted by t-2"
                     (harness-ui-tasks--returned-why '(:returned t :return-reason "preempted" :preempted-by "t-2"))))
      (should (equal "slot taken back by \"Fix the parser\""
                     (harness-ui-tasks--returned-why '(:returned t :return-reason "reclaimed" :preempted-by "t-1"))))
      (should (equal "slot taken back by the task that lent it"
                     (harness-ui-tasks--returned-why '(:returned t :return-reason "reclaimed"))))
      (should (equal "sent back from review"
                     (harness-ui-tasks--returned-why '(:returned t :return-reason "sent-back"))))
      (dolist (task '((:returned t :return-reason "returned") (:returned t)))
        (should (equal "paused" (harness-ui-tasks--returned-why task)))))
    (should (equal "Sent back" (harness-ui-tasks--sent-back-message '(:state "active"))))
    (should (equal "Sent back; waiting for a slot"
                   (harness-ui-tasks--sent-back-message '(:state "pending"))))
    (should (equal "Sent back; waiting for a slot (queue suspended)"
                   (harness-ui-tasks--sent-back-message '(:state "pending" :queue-suspended t))))))

(defun harness-ui-tasks-test--supervisor-switch-p (board)
  "Non-nil when the lines above BOARD's compose box have the supervisor switch."
  (with-current-buffer board
    (save-excursion
      (goto-char harness-ui-tasks--list-end)
      (and (text-property-search-forward 'harness-task-button 'harness-toggle-supervisor #'eq) t))))

(defvar harness-tasks-lend-blocked-slot-after)
(declare-function harness-ui-tasks--loan-fact "harness-ui-tasks")

(defun harness-ui-tasks-test--fact-tooltip (board title fact)
  "The tooltip of FACT on BOARD's card whose title shows TITLE."
  (with-current-buffer board
    (save-excursion
      (harness-ui-tasks-test--goto-card board title)
      (search-forward fact (line-end-position))
      (get-text-property (match-beginning 0) 'help-echo))))

(ert-deftest harness-ui-tasks-card-says-a-slot-is-lent ()
  "A task waiting on you lends its slot, and both cards say so.
The task the queue started in the slot says \"borrowed slot\", the one
waiting on you \"slot lent\", each naming the other in its tooltip.
Answered, the lender takes its slot back: the borrower's card goes back
to Pending, saying why it waits, and no card speaks of a loan any more."
  (harness-ui-tasks-test-with
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 1)
          (harness-tasks-lend-blocked-slot-after 0.2)
          (harness-provider-demo-script-override '((:type wait :seconds 30))))
      (harness-ui-tasks-test--type-and-submit board "Ask about the parser")
      (harness-ui-tasks-test--wait-text board "In progress  1\\(.\\|\n\\)*Ask about the parser")
      (let* ((lender (harness-ui-tasks-test--card-id board "Ask about the parser"))
             (lsid (plist-get (harness-call 'task/get lender) :session)))
        (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get lsid) :status)))
                           5 "the first task at work")
        (let ((pid (harness-call 'session/pending-add lsid
                                 (list :kind 'question :payload (list :question "Which parser?")))))
          (harness-ui-tasks-test--type-and-submit board "Write the docs")
          ;; The wait over, the next task starts in the slot it lends.
          (harness-ui-tasks-test--wait-text
           board "Requires your input  1\\(.\\|\n\\)*Ask about the parser\\(.\\|\n\\)*In progress  1\\(.\\|\n\\)*Write the docs")
          (harness-ui-tasks-test--wait-text board "borrowed slot")
          (let ((borrower (harness-ui-tasks-test--card-id board "Write the docs")))
            (should (equal lender (plist-get (harness-call 'task/get borrower) :borrowed-from)))
            (let ((lent (harness-ui-tasks-test--card-text board "Ask about the parser"))
                  (borrowed (harness-ui-tasks-test--card-text board "Write the docs")))
              (should (string-match-p "slot lent" lent))
              (should-not (string-match-p "borrowed slot" lent))
              (should (string-match-p "borrowed slot" borrowed))
              (should-not (string-match-p "slot lent" borrowed)))
            ;; Each names the other in its tooltip.
            (should (equal "Lent to \"Write the docs\" until you answer"
                           (harness-ui-tasks-test--fact-tooltip board "Ask about the parser" "slot lent")))
            (should (equal "Borrowed from \"Ask about the parser\" until you answer it"
                           (harness-ui-tasks-test--fact-tooltip board "Write the docs" "borrowed slot")))
            ;; Only a card at work or waiting on you speaks of a loan.
            (with-current-buffer board
              (let ((task (harness-ui-tasks--find borrower)))
                (should (harness-ui-tasks--loan-fact task 'active))
                (should (harness-ui-tasks--loan-fact task 'needs-input))
                (dolist (column '(pending review merging done))
                  (should-not (harness-ui-tasks--loan-fact task column)))))
            ;; Answered, the lender takes its slot back.
            (harness-call 'session/pending-resolve lsid pid "the new one")
            (harness-ui-tasks-test--wait-text
             board "In progress  1\\(.\\|\n\\)*Ask about the parser\\(.\\|\n\\)*Pending  1\\(.\\|\n\\)*Write the docs")
            ;; Why it waits, as much of it as the card's width shows
            ;; (`harness-ui-tasks--returned-why' says it whole).
            (harness-ui-tasks-test--show-subtitle board "Write the docs")
            (should (string-match-p "#1 in line · slot taken back by \"Ask about"
                                    (harness-ui-tasks-test--card-text board "Write the docs")))
            (should-not (string-match-p "slot lent\\|borrowed slot" (harness-ui-tasks-test--board-text board)))
            (harness-call 'task/cancel borrower)
            (harness-call 'task/cancel lender)))))))

(ert-deftest harness-ui-tasks-supervisor-switch ()
  "The settings line turns supervisor mode for the next task.
The button appears only while the harness has the supervisor module,
and a task submitted with the setting keeps it (the session of one that
starts with it is checked in the supervisor suite).  It is on the
task's settings line in Submit and Refine, never in Plan, whose task
works hands-on; each mode shows its own lines alone."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      ;; Without the supervisor module: no setting, no button.
      (with-current-buffer board
        (harness-test-wait (lambda () harness-ui-tasks--settings) 5 "the board's settings")
        (harness-ui-tasks--render-tail)
        (should-not (plist-member harness-ui-tasks--settings :supervisor))
        (should-not (harness-ui-tasks--supervisor-p))
        (should-not (string-match-p "supervisor" (harness-ui-tasks-test--tail-text board))))
      ;; Loaded, the harness reports the setting and the board shows it,
      ;; defaulting to supervising.
      (harness-test-load-module 'supervisor)
      (harness-test-load-module 'ui-chat)
      (harness-test-load-module 'ui-supervisor)
      (with-current-buffer board (harness-ui-tasks-refresh))
      (harness-test-wait (lambda () (with-current-buffer board
                                      (and (plist-member harness-ui-tasks--settings :supervisor)
                                           (harness-ui-tasks--supervisor-p))))
                         5 "the board to show the supervisor setting")
      (with-current-buffer board
        (harness-ui-tasks--render-tail)
        (should (harness-json-true-p (plist-get harness-ui-tasks--new :supervisor)))
        (should (string-match-p "· supervisor" (harness-ui-tasks-test--tail-text board)))
        ;; A click turns the next task's mode off, and on again.
        (push-button (harness-ui-tasks-test--tail-button board "supervisor"))
        (should-not (harness-json-true-p (plist-get harness-ui-tasks--new :supervisor)))
        (should (string-match-p "· hands-on" (harness-ui-tasks-test--tail-text board)))
        (push-button (harness-ui-tasks-test--tail-button board "hands-on"))
        (should (harness-json-true-p (plist-get harness-ui-tasks--new :supervisor)))
        (should (string-match-p "· supervisor" (harness-ui-tasks-test--tail-text board)))
        ;; Hands-on for the two tasks submitted now.
        (push-button (harness-ui-tasks-test--tail-button board "supervisor")))
      (harness-ui-tasks-test--type-and-submit board "Work hands-on")
      (harness-ui-tasks-test--type-and-submit board "Me too")
      (harness-ui-tasks-test--wait-text board "Pending  2")
      (let ((ids (mapcar (lambda (task) (plist-get task :id))
                         (harness-call 'task/list default-directory))))
        (should (= 2 (length ids)))
        (should (cl-every (lambda (id) (eq :false (plist-get (harness-call 'task/get id) :supervisor)))
                          ids)))
      ;; Each mode shows its own lines alone: Submit the task's, Refine
      ;; and Plan their own step's and the work's above it.  A planned
      ;; task works hands-on, its plan made already (its session is
      ;; checked in the supervisor suite), so Plan has no supervisor switch,
      ;; the switch's command says why rather than change what the task
      ;; would not be sent, and the task goes without the setting.  The
      ;; work of Submit and Refine may supervise, and keeps it.
      (with-current-buffer board
        (harness-ui-tasks--render-tail)
        (push-button (harness-ui-tasks-test--tail-button board "hands-on"))
        (should (harness-json-true-p (plist-get harness-ui-tasks--new :supervisor)))
        (goto-char (point-max))
        (pcase-dolist (`(,mode ,step ,switch) '((submit nil t) (refine "refine" t) (plan "plan" nil)))
          (harness-ui-tasks-cycle-mode mode)
          (let ((step-line (harness-ui-tasks-test--tail-line board 'step))
                (tail (harness-ui-tasks-test--tail-text board)))
            (if step
                (should (string-prefix-p (concat " " step " ") step-line))
              (should-not step-line))
            (dolist (other '("refine" "plan"))
              (unless (equal other step)
                (should-not (string-match-p (format "^ %s " other) tail))))
            (should (eq switch (harness-ui-tasks-test--supervisor-switch-p board)))
            (unless switch
              (should-not (string-match-p "supervisor\\|hands-on" tail)))))
        (let ((err (should-error (harness-toggle-supervisor) :type 'user-error)))
          (should (equal "No supervisor mode for a planned task's work" (cadr err))))
        (should (harness-json-true-p (plist-get harness-ui-tasks--new :supervisor)))
        (should-not (plist-member (harness-ui-tasks--new-opts 'plan) :supervisor))
        (should (eq t (plist-get (harness-ui-tasks--new-opts 'refine) :supervisor)))
        (should (eq t (plist-get (harness-ui-tasks--new-opts 'submit) :supervisor)))
        (harness-ui-tasks-cycle-mode 'submit)
        (should (harness-ui-tasks-test--supervisor-switch-p board))))))

;;;; One-shot and sticky submit modes, and what a card stopped part way offers

(declare-function harness-ui-tasks-retry "harness-ui-tasks")
(declare-function harness-ui-tasks--pausable-p "harness-ui-tasks")
(declare-function harness-ui-tasks--no-merge-p "harness-ui-tasks")

(ert-deftest harness-ui-tasks-main-tree-sticky-and-notice ()
  "The main-tree toggle cycles once, sticky, off, with a notice saying which.
The notice draws above the compose box, and its button keeps the choice
on, or turns it off again."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      ;; A git project, where the switch applies; this test's dir is not one.
      (setq harness-ui-tasks--settings
            (plist-put (copy-sequence harness-ui-tasks--settings) :worktrees t))
      (harness-ui-tasks--render-tail)
      (should-not harness-ui-tasks--main-tree-mode)
      ;; One toggle: the next task only, with a notice and a keep button.
      (harness-ui-tasks-toggle-main-tree)
      (should (eq 'once harness-ui-tasks--main-tree-mode))
      (let ((tail (harness-ui-tasks-test--tail-text board)))
        (should (string-match-p "Main tree for the next task" tail))
        (should (string-match-p "\\[keep on\\]" tail)))
      ;; Another: every task, until it is clicked off.
      (harness-ui-tasks-toggle-main-tree)
      (should (eq 'sticky harness-ui-tasks--main-tree-mode))
      (should (string-match-p "Main tree for every task"
                              (harness-ui-tasks-test--tail-text board)))
      ;; The notice's [off] button turns it off, and the worktree is back.
      (push-button (harness-ui-tasks-test--tail-button board "[off]"))
      (should-not harness-ui-tasks--main-tree-mode)
      (should (eq :false (plist-get harness-ui-tasks--new :main-tree)))
      ;; A prefix argument arms the sticky mode at once.
      (harness-ui-tasks-toggle-main-tree 4)
      (should (eq 'sticky harness-ui-tasks--main-tree-mode))
      (should (harness-json-true-p (plist-get harness-ui-tasks--new :main-tree))))))

(ert-deftest harness-ui-tasks-main-tree-once-resets-after-submit ()
  "A one-shot main-tree choice lasts one task: submitting it resets the box.
The task submitted with it keeps the main tree, and the next task works
in its own worktree again."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (with-current-buffer board
        (setq harness-ui-tasks--settings
              (plist-put (copy-sequence harness-ui-tasks--settings) :worktrees t))
        (harness-ui-tasks--render-tail)
        (harness-ui-tasks-toggle-main-tree)
        (should (eq 'once harness-ui-tasks--main-tree-mode)))
      (harness-ui-tasks-test--type-and-submit board "Clean the checkout")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Clean the checkout")
      ;; Spent: the mode is off and the box works in a worktree again.
      (harness-test-wait
       (lambda () (with-current-buffer board
                    (and (null harness-ui-tasks--main-tree-mode)
                         (not (harness-json-true-p (plist-get harness-ui-tasks--new :main-tree))))))
       5 "the one-shot main-tree choice to reset")
      ;; The task it was armed for kept the main tree.
      (should (harness-json-true-p (plist-get (car (harness-call 'task/list default-directory))
                                              :main-tree))))))

(ert-deftest harness-ui-tasks-priority-once-resets-after-submit ()
  "A one-shot priority lasts one task: the notice shows, and goes with it.
The task submitted gets the high priority, and the button is back to
medium for the next one."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (with-current-buffer board
        (harness-ui-tasks-cycle-new-priority)
        (should (eq 'once harness-ui-tasks--priority-mode))
        (let ((tail (harness-ui-tasks-test--tail-text board)))
          (should (string-match-p "High priority for the next task" tail))
          (should (string-match-p "\\[keep on\\]" tail))))
      (harness-ui-tasks-test--type-and-submit board "Urgent fix")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*↑ +Urgent fix")
      (should (eq 'high (plist-get (car (harness-call 'task/list default-directory)) :priority)))
      ;; Spent: medium again, and the notice is gone.
      (harness-test-wait
       (lambda () (with-current-buffer board
                    (and (null harness-ui-tasks--priority-mode)
                         (string-match-p "Submit +medium priority\n"
                                         (harness-ui-tasks-test--tail-text board)))))
       5 "the one-shot priority to reset")
      (should-not (string-match-p "priority for the next task"
                                  (harness-ui-tasks-test--tail-text board))))))

(ert-deftest harness-ui-tasks-priority-sticky-keeps-across-submits ()
  "Keeping the priority on makes every next task high, until clicked off.
A click on the notice's [keep on] makes it sticky; it survives the tasks
it applies to, and the notice stays until its [off] button is used."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (with-current-buffer board
        (harness-ui-tasks-cycle-new-priority)
        (push-button (harness-ui-tasks-test--tail-button board "[keep on]"))
        (should (eq 'sticky harness-ui-tasks--priority-mode))
        (should (string-match-p "High priority for every task"
                                (harness-ui-tasks-test--tail-text board))))
      (harness-ui-tasks-test--type-and-submit board "First urgent")
      (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*↑ +First urgent")
      (should (string-match-p "High priority for every task"
                              (harness-ui-tasks-test--tail-text board)))
      ;; A second submit goes high too, the notice still showing.
      (harness-ui-tasks-test--type-and-submit board "Second urgent")
      (harness-ui-tasks-test--wait-text board "Pending  2\\(.\\|\n\\)*First urgent\\(.\\|\n\\)*Second urgent")
      (should (cl-every (lambda (task) (eq 'high (plist-get task :priority)))
                        (harness-call 'task/list default-directory)))
      (should (string-match-p "High priority for every task"
                              (harness-ui-tasks-test--tail-text board)))
      ;; Off: medium again, and the notice is gone.
      (with-current-buffer board
        (push-button (harness-ui-tasks-test--tail-button board "[off]")))
      (should-not harness-ui-tasks--priority-mode)
      (with-current-buffer board
        (should (equal "medium" (plist-get harness-ui-tasks--new :priority)))
        (should (string-match-p "Submit +medium priority\n"
                                (harness-ui-tasks-test--tail-text board)))))))

(ert-deftest harness-ui-tasks-needs-input-sorts-by-priority ()
  "Requires your input lists the tasks waiting there by priority, then oldest.
A low task submitted first comes after a high one submitted later."
  (harness-ui-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (harness-call 'task/submit default-directory "Low, broken" (list :priority "low"))
      (harness-call 'task/submit default-directory "High, broken" (list :priority "high"))
      (harness-ui-tasks-test--wait-text
       board "Requires your input  2\\(.\\|\n\\)*High, broken\\(.\\|\n\\)*Low, broken")
      (should (string-match-p "Requires your input  2\\(.\\|\n\\)*High, broken\\(.\\|\n\\)*Low, broken"
                              (harness-ui-tasks-test--board-text board))))))

(ert-deftest harness-ui-tasks-card-actions-retry-and-pause ()
  "A task that stopped part way offers Retry then Pause; a working one Pause.
A task that said it cannot continue asks you to Reply first, and can
still be paused; a card whose session waits on a request keeps the
view's own answer buttons and gains Pause beside them."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (setq harness-ui-tasks--tasks
            (list (list :id "t-error" :state "active" :column "needs-input"
                        :outcome "error" :prompt "Broke part way" :created 0)
                  (list :id "t-working" :state "active" :column "active"
                        :prompt "At work" :created 0)
                  (list :id "t-cannot" :state "active" :column "needs-input"
                        :outcome "cannot-continue" :prompt "Cannot finish" :created 0)))
      (let* ((error-task (harness-ui-tasks--find "t-error"))
             (working (harness-ui-tasks--find "t-working"))
             (cannot (harness-ui-tasks--find "t-cannot")))
        ;; A task stopped part way: Retry, then Pause, as its buttons too.
        (should (equal '("Retry" "Pause")
                       (take 2 (mapcar #'car (harness-ui-tasks--actions error-task)))))
        (should (string-match-p "\\[Retry\\] \\[Pause\\]"
                                (substring-no-properties (harness-ui-tasks--card-buttons error-task))))
        ;; A task at work: Pause after Steer.
        (let ((labels (mapcar #'car (harness-ui-tasks--actions working))))
          (should (member "Pause" labels))
          (should (> (cl-position "Pause" labels :test #'equal)
                     (cl-position "Steer" labels :test #'equal))))
        ;; A task that cannot continue: Reply first, and Pause is there.
        (should (equal "Reply" (caar (harness-ui-tasks--actions cannot))))
        (should (member "Pause" (mapcar #'car (harness-ui-tasks--actions cannot)))))
      ;; A live request keeps its answer buttons and gains Pause.
      (puthash "s-waits"
               (list :id "s-waits" :name "Waiter" :status "blocked"
                     :pending (list (list :id "p1" :kind "permission"
                                          :payload (list :title "Bash: ls -la" :tool "bash"
                                                         :options '("allow-once" "deny-once")))))
               harness-ui--sessions)
      (let* ((waiting (list :id "t-waits" :state "active" :column "needs-input"
                            :session "s-waits" :prompt "Needs a permission" :created 0))
             (buttons (substring-no-properties (harness-ui-tasks--card-buttons waiting))))
        (should (string-match-p "\\[Allow\\]" buttons))
        (should (string-match-p "\\[Deny\\]" buttons))
        (should (string-match-p "\\[Pause\\]" buttons))))))

(ert-deftest harness-ui-tasks-no-merge-card-says-so ()
  "A card whose work needs no merge says so, in review and once done.
In review, verifying accepts it, there being nothing to merge; in done,
it says there was nothing to merge."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (setq harness-ui-tasks--tasks
            (list (list :id "t-nomerge-review" :state "review" :column "review"
                        :no-merge t :prompt "Explain the flag" :created 0)
                  (list :id "t-nomerge-done" :state "done" :column "done"
                        :no-merge t :prompt "Document the flag" :created 0)))
      (harness-ui-tasks--render))
    (harness-ui-tasks-test--show-subtitle board "Explain the flag")
    (should (string-match-p "nothing to merge"
                            (harness-ui-tasks-test--card-text board "Explain the flag")))
    (harness-ui-tasks-test--show-subtitle board "Document the flag")
    (should (string-match-p "nothing to merge"
                            (harness-ui-tasks-test--card-text board "Document the flag")))))

;;;; A button pushed is held down until the harness answers

;; A push sends a request and the board only changes when the event it
;; causes comes back.  The button is drawn held down meanwhile, so the
;; click is seen to have landed.  The requests here are kept, not sent, so
;; the tests answer them when they choose.

(defvar harness-ui-tasks--pressed)
(defvar harness-ui-tasks--pressable)
(defvar harness-ui-tasks--card-id)
(defvar harness-ui-tasks--pressed-min-seconds)
(defvar harness-ui-tasks--pressed-max-seconds)
(declare-function harness-ui-tasks--pressed-keys "harness-ui-tasks")
(declare-function harness-ui-tasks--more-line "harness-ui-tasks")
(declare-function harness-ui-tasks--tick "harness-ui-tasks")
(declare-function harness-ui-tasks-start "harness-ui-tasks")

(defmacro harness-ui-tasks-test-holding (var &rest body)
  "Run BODY with the requests the board makes kept in VAR, not sent.
VAR is the list of them, the newest first, each (METHOD PARAMS CALLBACK
ON-ERROR): the test answers one by calling CALLBACK, or fails it with
ON-ERROR.  The harness is not asked."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (method params callback &optional on-error)
                  (push (list method params callback on-error) ,var))))
       ,@body)))

(defun harness-ui-tasks-test--sent (sent method)
  "The requests of METHOD among SENT, oldest first."
  (reverse (cl-remove-if-not (lambda (request) (equal method (car request))) sent)))

(defun harness-ui-tasks-test--card-button (board card label)
  "Where the button LABEL is, on BOARD's card whose title shows CARD."
  (with-current-buffer board
    (harness-ui-tasks-test--goto-card board card)
    (save-excursion
      (search-forward label (or (next-single-property-change (point) 'harness-task-id) (point-max)))
      (match-beginning 0))))

(defun harness-ui-tasks-test--push (board card label)
  "Push the button LABEL on BOARD's card whose title shows CARD."
  (with-current-buffer board
    (push-button (harness-ui-tasks-test--card-button board card label))))

(defun harness-ui-tasks-test--held-p (board card label)
  "Non-nil when BOARD draws the button LABEL of the card showing CARD held down."
  (with-current-buffer board
    (eq 'harness-task-button-pressed-face
        (get-text-property (harness-ui-tasks-test--card-button board card label) 'face))))

(defun harness-ui-tasks-test--waiting-task (board)
  "Submit a task that waits in Pending, and wait for BOARD to show its card."
  (harness-call 'task/submit default-directory "Waiting task" nil)
  (harness-ui-tasks-test--wait-text board "Pending  1\\(.\\|\n\\)*Waiting task"))

(ert-deftest harness-ui-tasks-pushed-button-is-held-down-until-the-harness-answers ()
  "A button pushed is drawn held down, at once, until its request is answered.
The request is still out when it shows; a second push meanwhile runs
nothing and says why (a task started twice is an error); the answer lets
the button go, and it can be pushed again.  Held down it reads the same,
only its look and its tooltip change."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--pressed-min-seconds 0))
      (harness-ui-tasks-test--waiting-task board)
      (harness-ui-tasks-test-holding sent
        (let ((text (harness-ui-tasks-test--board-text board))
              (start (lambda (n) (nth n (harness-ui-tasks-test--sent sent "_harness/task/start")))))
          (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
          (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
          ;; Held down while the request is out.
          (should (funcall start 0))
          (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
          (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Edit]"))
          (with-current-buffer board
            (let ((pos (harness-ui-tasks-test--card-button board "Waiting task" "[Start now]")))
              (should (button-at pos))
              (should (string-prefix-p "Working on it" (get-text-property pos 'help-echo)))
              (should-not (get-text-property pos 'mouse-face))))
          ;; Same words, same width: nothing but the look changed.
          (should (equal text (harness-ui-tasks-test--board-text board)))
          ;; A second push says so and sends nothing.
          (let ((said nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) said))))
              (harness-ui-tasks-test--push board "Waiting task" "[Start now]"))
            (should (string-match-p "Still working" (car said))))
          (should-not (funcall start 1))
          (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
          ;; The answer lets it go...
          (funcall (nth 2 (funcall start 0)) nil)
          (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
          (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys)))
          (with-current-buffer board
            (should (string-prefix-p "Start now"
                                     (get-text-property
                                      (harness-ui-tasks-test--card-button board "Waiting task" "[Start now]")
                                      'help-echo))))
          ;; ...and it works again.
          (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
          (should (funcall start 1))
          (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]")))))))

(ert-deftest harness-ui-tasks-held-button-stays-down-through-redraws-and-may-leave ()
  "A button held down stays so through the board's redraws.
The key outlives the button: once the task has started, its card has
other buttons, none of them held down, and the answer, arriving after
that, only forgets the key."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--pressed-min-seconds 0))
      (harness-ui-tasks-test--waiting-task board)
      (harness-ui-tasks-test-holding sent
        (let ((id (harness-ui-tasks-test--card-id board "Waiting task")))
          (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
          (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
          ;; Redrawn, by hand, by the tick and for new figures: still down.
          (with-current-buffer board
            (harness-ui-tasks--render t)
            (harness-ui-tasks--tick)
            (harness-ui-tasks--refit-tail))
          (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
          ;; The task starts before the answer is in: its card has other
          ;; buttons now, and none is held down.
          (harness-ui-tasks-test--change board id :state "active" :column "active" :started (float-time))
          (with-current-buffer board (harness-ui-tasks--render t))
          (should-not (string-search "[Start now]" (harness-ui-tasks-test--card-text board "Waiting task")))
          (should (string-search "[Steer]" (harness-ui-tasks-test--card-text board "Waiting task")))
          (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Steer]"))
          (should (with-current-buffer board (harness-ui-tasks--pressed-keys)))
          (funcall (nth 2 (car (harness-ui-tasks-test--sent sent "_harness/task/start"))) nil)
          (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys))))))))

(ert-deftest harness-ui-tasks-pushed-button-goes-up-when-its-request-fails ()
  "A request that fails lets the button go too, and the board says what failed."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--pressed-min-seconds 0))
      (harness-ui-tasks-test--waiting-task board)
      (harness-ui-tasks-test-holding sent
        (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
        (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
        (funcall (nth 3 (car (harness-ui-tasks-test--sent sent "_harness/task/start")))
                 '(acp-error 1 "no slot" nil))
        (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
        (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys)))
        (should (string-match-p "Starting the task failed: no slot"
                                (harness-ui-tasks-test--tail-text board)))))))

(ert-deftest harness-ui-tasks-button-waits-for-every-request-its-command-made ()
  "A button stays down until each request of its command has been answered.
A request made by the callback of another is waited for too; the button
goes up once the last answer is in, and one answer counts once."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--pressed-min-seconds 0))
      (harness-ui-tasks-test--waiting-task board)
      (harness-ui-tasks-test-holding sent
        (cl-letf (((symbol-function 'harness-ui-tasks-start)
                   (lambda ()
                     (interactive)
                     (harness-ui-tasks--request-then
                      "_harness/first" nil "Asking"
                      (lambda (_) (harness-ui-tasks--request-then "_harness/third" nil "Asking again")))
                     (harness-ui-tasks--request-then "_harness/second" nil "Asking"))))
          (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
          (let ((answer (lambda (method)
                          (funcall (nth 2 (car (harness-ui-tasks-test--sent sent method))) nil))))
            (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
            ;; One of two answered: it waits for the other.
            (funcall answer "_harness/second")
            (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
            ;; The answer to the first asks again, and the button waits
            ;; for that too.  A request answered and failed both counts
            ;; down once.
            (funcall answer "_harness/first")
            (should (harness-ui-tasks-test--sent sent "_harness/third"))
            (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
            (funcall (nth 3 (car (harness-ui-tasks-test--sent sent "_harness/first"))) '(acp-error 1 "late" nil))
            (funcall (nth 3 (car (harness-ui-tasks-test--sent sent "_harness/second"))) '(acp-error 1 "late" nil))
            (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
            (funcall answer "_harness/third")
            (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))))))))

(ert-deftest harness-ui-tasks-button-that-asks-for-nothing-is-held-down-for-a-moment ()
  "A command that makes no request still shows its push, for a moment.
[Edit] puts the task's prompt in the compose box and asks the harness
for nothing; its button is held down for at least the least time, and
then goes up without disturbing what the box holds."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--pressed-min-seconds 0.3))
      (harness-ui-tasks-test--waiting-task board)
      (harness-ui-tasks-test-holding sent
        (let ((before (float-time))
              (shown-first 'never)
              (set-compose (symbol-function 'harness-ui-tasks--set-compose)))
          ;; The push is drawn before the command runs, so that it shows
          ;; while the command prompts or works.
          (cl-letf (((symbol-function 'harness-ui-tasks--set-compose)
                     (lambda (&rest args)
                       (setq shown-first (harness-ui-tasks-test--held-p board "Waiting task" "[Edit]"))
                       (apply set-compose args))))
            (harness-ui-tasks-test--push board "Waiting task" "[Edit]"))
          (should (eq t shown-first))
          (should (harness-ui-tasks-test--held-p board "Waiting task" "[Edit]"))
          (should (string-match-p "Waiting task" (with-current-buffer board (harness-compose-text))))
          (harness-test-wait (lambda () (not (harness-ui-tasks-test--held-p board "Waiting task" "[Edit]")))
                             5 "the button to be let go")
          (should (>= (- (float-time) before) 0.3))
          (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys)))
          ;; The box is as the command left it.
          (should (string-match-p "Waiting task" (with-current-buffer board (harness-compose-text))))
          (should (equal '(edit) (list (car (buffer-local-value 'harness-ui-tasks--target board)))))
          (should-not (harness-ui-tasks-test--sent sent "_harness/task/start")))))))

(ert-deftest harness-ui-tasks-command-typed-on-a-card-holds-its-button-down ()
  "A key of the board holds the card's button for its command down, as a click does.
`s' is the command of [Start now]: with point on the card its request
keeps the button down until it is answered.  A command the card has no
button for holds none down, and neither does one typed off a card."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--pressed-min-seconds 0))
      (harness-ui-tasks-test--waiting-task board)
      (harness-ui-tasks-test-holding sent
        (harness-ui-tasks-test--goto-card board "Waiting task")
        (with-current-buffer board
          (let ((this-command 'harness-ui-tasks-start))
            (harness-ui-tasks-start)))
        (should (= 1 (length (harness-ui-tasks-test--sent sent "_harness/task/start"))))
        (should (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
        (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Edit]"))
        (funcall (nth 2 (car (harness-ui-tasks-test--sent sent "_harness/task/start"))) nil)
        (should-not (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))
        ;; No button for it on the card: nothing is held down.
        (harness-ui-tasks-test--goto-card board "Waiting task")
        (with-current-buffer board
          (let ((this-command 'harness-ui-tasks-raise-priority))
            (harness-ui-tasks-raise-priority)))
        (should (= 1 (length (harness-ui-tasks-test--sent sent "_harness/priority/set"))))
        (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys)))
        ;; Typed off a card, there is nothing to hold.
        (with-current-buffer board
          (goto-char (point-max))
          (let ((this-command 'harness-ui-tasks-start))
            (should-error (harness-ui-tasks-start) :type 'user-error)))
        (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys)))))))

(ert-deftest harness-ui-tasks-button-held-down-too-long-is-let-go ()
  "An answer that never comes does not leave a button stuck.
The tick lets it go once it has been down for the longest it may be, and
so does the next push of it; the answer, were it to come after all, does
nothing to a button pushed since."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-ui-tasks--pressed-min-seconds 0)
          (harness-ui-tasks--pressed-max-seconds 0.3))
      (harness-ui-tasks-test--waiting-task board)
      (harness-ui-tasks-test-holding sent
        (let ((starts (lambda () (harness-ui-tasks-test--sent sent "_harness/task/start")))
              (held (lambda () (harness-ui-tasks-test--held-p board "Waiting task" "[Start now]"))))
          (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
          (should (funcall held))
          (sleep-for 0.4)
          ;; The tick lets it go.
          (with-current-buffer board (harness-ui-tasks--tick))
          (should-not (funcall held))
          (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys)))
          ;; Pushed again it waits for its own answer, not the lost one.
          (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
          (should (= 2 (length (funcall starts))))
          (should (funcall held))
          (funcall (nth 2 (nth 0 (funcall starts))) nil)
          (should (funcall held))
          ;; Lost as well: the next push does not say the harness is
          ;; working, it pushes the button.
          (sleep-for 0.4)
          (harness-ui-tasks-test--push board "Waiting task" "[Start now]")
          (should (= 3 (length (funcall starts))))
          (should (funcall held))
          (funcall (nth 2 (nth 1 (funcall starts))) nil)
          (should (funcall held))
          (funcall (nth 2 (nth 2 (funcall starts))) nil)
          (should-not (funcall held)))))))

(ert-deftest harness-ui-tasks-buttons-above-the-box-are-not-held-down ()
  "The buttons above the compose box act at once, as they always did.
Pushed, they are not held down and not turned away when pushed again."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (let ((mode (harness-ui-tasks-test--modes-shown board)))
        (push-button (harness-ui-tasks-test--toggle board))
        (should-not (equal mode (harness-ui-tasks-test--modes-shown board)))
        (should-not (harness-ui-tasks--pressed-keys))
        (should-not harness-ui-tasks--pressed)
        (should-not (eq 'harness-task-button-pressed-face
                        (get-text-property (harness-ui-tasks-test--toggle board) 'face)))
        ;; Submit, Refine and Plan: pushed again, not turned away, and
        ;; it takes three pushes to come back round.
        (push-button (harness-ui-tasks-test--toggle board))
        (should-not (equal mode (harness-ui-tasks-test--modes-shown board)))
        (should-not harness-ui-tasks--pressed)
        (push-button (harness-ui-tasks-test--toggle board))
        (should (equal mode (harness-ui-tasks-test--modes-shown board)))
        (should-not harness-ui-tasks--pressed)))))

(defun harness-ui-tasks-test--chevron (board)
  "Where the first card's recap chevron is, in BOARD."
  (with-current-buffer board
    (save-excursion
      (goto-char (point-min))
      (let (found)
        (while (and (not found) (< (point) (point-max)))
          (let ((id (get-text-property (point) 'harness-task-button)))
            (if (and (stringp id) (string-prefix-p "subtitle:" id))
                (setq found (point))
              (goto-char (or (next-single-property-change (point) 'harness-task-button) (point-max))))))
        found))))

(ert-deftest harness-ui-tasks-recap-chevron-is-not-held-down ()
  "The chevron that folds a card's recap acts at once, and can be pushed again.
It asks the harness for nothing, so holding it down would only turn the
second push of a quick open-and-close away."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (harness-ui-tasks-test--waiting-task board)
      (let ((recap (lambda () (string-search "in line" (harness-ui-tasks-test--board-text board)))))
        (should-not (funcall recap))
        (with-current-buffer board (push-button (harness-ui-tasks-test--chevron board)))
        (should (funcall recap))
        (should-not (with-current-buffer board (harness-ui-tasks--pressed-keys)))
        (should-not (eq 'harness-task-button-pressed-face
                        (get-text-property (harness-ui-tasks-test--chevron board) 'face)))
        (with-current-buffer board (push-button (harness-ui-tasks-test--chevron board)))
        (should-not (funcall recap))
        (should-not (with-current-buffer board harness-ui-tasks--pressed))))))

(ert-deftest harness-ui-tasks-section-lines-are-held-down-one-at-a-time ()
  "The [Show all] of one section is held down without those of the others."
  (with-temp-buffer
    (setq harness-ui-tasks--pressed (make-hash-table :test #'equal))
    (puthash (cons 'done "[Show all]") (list :at (float-time) :requests 0) harness-ui-tasks--pressed)
    (let ((harness-ui-tasks--pressable t)
          (inhibit-read-only t))
      (harness-ui-tasks--more-line 3 'pending)
      (harness-ui-tasks--more-line 3 'done)
      (harness-ui-tasks--more-line 3 'backlog))
    (let ((faces nil))
      (goto-char (point-min))
      (while (re-search-forward "\\[Show all\\]" nil t)
        (push (get-text-property (match-beginning 0) 'face) faces))
      (should (equal '(button harness-task-button-pressed-face button) (nreverse faces))))))

;;;; The cards of a section line up in columns

;; A section's cards are drawn together (`harness-ui-tasks--insert-cards'):
;; the facts have a column for each kind, the cells right-aligned in it,
;; the buttons start at one place and the titles at another.  Each column
;; starts with a space aligned to its place (`harness-ui-tasks--align'),
;; so these tests read the places off those spaces, in columns from the
;; window's left edge, instead of counting the characters that come
;; before: an icon drawn wider than its characters moves none of them.

(defvar harness-ui-tasks--subtitles)
(defvar harness-ui-tasks--fact-kinds)
(defvar harness-ui-tasks--min-title-room)
(defvar harness-ui-tasks--project)
(defvar harness-ui-tasks--dir)
(defvar harness-ui--rates)
(declare-function harness-ui-tasks--insert-cards "harness-ui-tasks")
(declare-function harness-ui-tasks--aligned-p "harness-ui-tasks")
(declare-function harness-ui-tasks--set-subtitle "harness-ui-tasks")
(declare-function harness-ui-tasks--column "harness-ui-tasks")
(declare-function harness-ui-tasks--priority-mark "harness-ui-tasks")

(defmacro harness-ui-tasks-test-in-wide-frame (width &rest body)
  "Run BODY with the frame WIDTH columns wide, and the board's window as `window'.
For use in `harness-ui-tasks-test-with', which names `board': the cards
of a section say more than an 80 column window has room for.  The frame
is put back after."
  (declare (indent 1))
  `(unwind-protect
       (progn
         (set-frame-width nil ,width)
         (let ((window (get-buffer-window board)))
           (should window)
           (select-window window)
           (should (>= (window-body-width window) ,width))
           ,@body))
     (set-frame-width nil 80)))

(defun harness-ui-tasks-test--columns (width)
  "The columns drawn in this buffer for a window WIDTH columns wide.
One entry for each line that has any, in order: a plist with `:id', the
task whose card the line belongs to, `:text', the line, and `:columns',
\(KIND START END TEXT) for each of its columns left to right.  KIND is
`title', `zone' (the buttons) or a kind of fact
\(`harness-ui-tasks--fact-kinds'); START and END count from the window's
left edge.  A column runs from the space aligned to where it starts, to
the next one's or the end of the line, and TEXT is what is in it."
  (let (lines)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((bol (line-beginning-position))
               (eol (line-end-position))
               (marks (cl-loop for pos from bol below eol
                               when (get-text-property pos 'harness-task-column) collect pos))
               (columns (cl-loop for (pos . rest) on marks
                                 for kind = (get-text-property pos 'harness-task-column)
                                 for spec = (plist-get (cdr (get-text-property pos 'display)) :align-to)
                                 for text = (buffer-substring-no-properties (1+ pos) (or (car rest) eol))
                                 for start = (if (integerp spec) spec (- width (nth 2 spec)))
                                 collect (list kind start (+ start (string-width text)) text))))
          (when columns
            (push (list :id (get-text-property bol 'harness-task-id)
                        :text (buffer-substring-no-properties bol eol)
                        :columns columns)
                  lines)))
        (forward-line 1)))
    (nreverse lines)))

(defun harness-ui-tasks-test--line-up (lines width)
  "Check that the columns of LINES, drawn for WIDTH, line up; return their places.
Every title starts in one column, every buttons zone at one place, and
the cells of a kind end together.  Along a line the columns follow in
order, two apart at least, inside the window.  The result is an alist
\(KIND . PLACE): where the titles and the buttons start, and where the
facts end."
  (let ((order (append '(title) harness-ui-tasks--fact-kinds '(zone)))
        places)
    (dolist (line lines)
      (let ((previous nil))
        (pcase-dolist (`(,kind ,start ,end ,_) (plist-get line :columns))
          (when previous
            (should (< (cl-position (nth 0 previous) order) (cl-position kind order)))
            (should (>= start (+ (nth 2 previous) 2))))
          (should (< end width))
          (let ((place (if (memq kind '(title zone)) start end))
                (known (assq kind places)))
            (if known
                (should (equal (cdr known) place))
              (push (cons kind place) places)))
          (setq previous (list kind start end)))))
    places))

(defun harness-ui-tasks-test--cards-of (lines column)
  "The entries of LINES, from `harness-ui-tasks-test--columns', of cards in COLUMN."
  (seq-filter (lambda (line)
                (eq column (harness-ui-tasks--column (harness-ui-tasks--find (plist-get line :id)))))
              lines))

(defun harness-ui-tasks-test--line-of (lines id)
  "The first entry of LINES, from `harness-ui-tasks-test--columns', of card ID."
  (seq-find (lambda (line) (equal id (plist-get line :id))) lines))

(defun harness-ui-tasks-test--column-of (line kind)
  "The column KIND of LINE, an entry of `harness-ui-tasks-test--columns', or nil."
  (assq kind (plist-get line :columns)))

(defun harness-ui-tasks-test--fake-tasks (board &rest tasks)
  "Put TASKS, plists, on BOARD as the harness's own store would."
  (with-current-buffer board
    (setq harness-ui-tasks--tasks
          (append harness-ui-tasks--tasks
                  (mapcar (lambda (task)
                            (append (list :project harness-ui-tasks--project :cwd harness-ui-tasks--dir) task))
                          tasks)))))

(defun harness-ui-tasks-test--waiting-four (board)
  "Put four waiting tasks on BOARD whose cards differ in everything they say.
The first is high priority, in the main tree, and was sent back: [Start
now] and [Reply].  The second is low priority and plain: [Start now] and
\[Edit].  The third handed in no report, so has a third button, [No
report].  The fourth waits in a suspended queue, which its time says at
length."
  ;; The [No report] button is there once the harness has loaded the report popout.
  (require 'harness-ui-report)
  (let ((now (float-time)))
    (harness-ui-tasks-test--fake-tasks
     board
     (list :id "t-col-high" :prompt "Retry the webhooks on a 5xx answer" :state "pending" :column "pending"
           :priority "high" :main-tree t :created (- now 90000) :returned (- now 300))
     (list :id "t-col-low" :prompt "Document the paging parameters" :state "pending" :column "pending"
           :priority "low" :created (- now 10800))
     (list :id "t-col-report" :prompt "Rename the orders table" :state "pending" :column "pending"
           :created (- now 172800) :returned (- now 172000) :report (list :missing t))
     (list :id "t-col-wait" :prompt "Send a receipt email after checkout" :state "pending" :column "pending"
           :created (- now 40) :queue-suspended t))))

(defun harness-ui-tasks-test--buttons-of (lines id)
  "The text of the buttons on card ID in LINES, from `harness-ui-tasks-test--columns'."
  (let ((zone (cl-some (lambda (line)
                         (and (equal id (plist-get line :id))
                              (harness-ui-tasks-test--column-of line 'zone)))
                       lines)))
    (and zone (nth 3 zone))))

(ert-deftest harness-ui-tasks-columns-cards-of-a-section-line-up ()
  "The cards of a section say each thing in the same place.
Four waiting tasks differ in the facts they have, in priority -- an arrow
before the title of two -- and in their buttons.  Their titles start in
one column, whatever the arrow takes; the facts of a kind end together
and the buttons start at one place, each under the first.  An arrow takes
room on every card, or on none."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test-in-wide-frame 140
      (harness-ui-tasks-test--waiting-four board)
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (let* ((width (harness-ui-tasks--width))
               (lines (harness-ui-tasks-test--columns width))
               (places (harness-ui-tasks-test--line-up lines width))
               (wait (harness-ui-tasks--find "t-col-wait")))
          (should (= 4 (length lines)))
          ;; A column for each kind that some card has a fact of, and none
          ;; for the others: these have the main tree and the time.
          (should (equal '(title main-tree time zone)
                         (seq-filter (lambda (kind) (assq kind places))
                                     (append '(title) harness-ui-tasks--fact-kinds '(zone)))))
          (should (equal '("[Start now] [Reply]" "[Start now] [Edit]"
                           "[Start now] [Reply] [No report]" "[Start now] [Edit]")
                         (mapcar (lambda (id) (string-trim-right (harness-ui-tasks-test--buttons-of lines id)))
                                 '("t-col-high" "t-col-low" "t-col-report" "t-col-wait"))))
          ;; The widest buttons make the zone, which ends one column short
          ;; of the window's edge; the facts end two columns before it; the
          ;; widest time -- the suspended queue's -- makes its column.
          (should (= (- width 1 (string-width "[Start now] [Reply] [No report]"))
                     (cdr (assq 'zone places))))
          (should (= (- (cdr (assq 'zone places)) 2) (cdr (assq 'time places))))
          (let ((widest (string-width (cdr (assq 'time (harness-ui-tasks--facts wait 'pending nil))))))
            (should (equal "queued 40s ago · queue suspended"
                           (cdr (assq 'time (harness-ui-tasks--facts wait 'pending nil)))))
            (should (= (- (cdr (assq 'time places)) widest 2) (cdr (assq 'main-tree places)))))
          ;; The cells are right-aligned in their column: they end together
          ;; and start where their length says.
          (let ((starts (mapcar (lambda (line) (nth 1 (harness-ui-tasks-test--column-of line 'time))) lines)))
            (should (= 2 (length (delete-dups (copy-sequence starts)))))
            (should (= (apply #'min starts) (nth 1 (harness-ui-tasks-test--column-of
                                                    (harness-ui-tasks-test--line-of lines "t-col-wait")
                                                    'time)))))
          ;; Only the card that has the main tree has a cell in its column.
          (should (equal '("t-col-high")
                         (mapcar (lambda (line) (plist-get line :id))
                                 (seq-filter (lambda (line) (harness-ui-tasks-test--column-of line 'main-tree))
                                             lines))))
          ;; An arrow takes the same room on every card: without one on any,
          ;; the titles start as far left as the arrow's room is wide.
          (let ((room (string-width (harness-ui-tasks--priority-mark (harness-ui-tasks--find "t-col-high") 'pending)))
                (title (cdr (assq 'title places))))
            (should (= 2 room))
            (should (string-match-p "↑ +Retry" (plist-get (harness-ui-tasks-test--line-of lines "t-col-high") :text)))
            (should (string-match-p "↓ +Document" (plist-get (harness-ui-tasks-test--line-of lines "t-col-low") :text)))
            (harness-ui-tasks-test--change board "t-col-high" :priority "medium")
            (harness-ui-tasks-test--change board "t-col-low" :priority "medium")
            (harness-ui-tasks--render t)
            (let ((plain (harness-ui-tasks-test--line-up (harness-ui-tasks-test--columns width) width)))
              (should (= (- title room) (cdr (assq 'title plain)))))
            (should-not (string-match-p "[↑↓]" (buffer-substring-no-properties (point-min) harness-ui-tasks--list-end)))))))))

(ert-deftest harness-ui-tasks-columns-card-keeps-what-it-always-had ()
  "A card laid out in columns is still one card: its title, its id, its buttons.
The title is the part of the line that opens the session, the card is
one task to everything that asks which one point is on, and the facts
stay dim."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test-in-wide-frame 140
      (harness-ui-tasks-test--waiting-four board)
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (goto-char (point-min))
        (search-forward "Rename the orders table")
        (let* ((bol (line-beginning-position))
               (eol (line-end-position))
               (title (match-beginning 0)))
          (should (eq 'highlight (get-text-property title 'mouse-face)))
          (should (equal "Open the session" (get-text-property title 'help-echo)))
          (should (eq 'harness-task-title-face (get-text-property title 'face)))
          ;; All of the card is its task's, and the line ends it.
          (should (equal "t-col-report" (get-text-property bol 'harness-task-id)))
          (should (equal "t-col-report" (get-text-property (1- eol) 'harness-task-id)))
          (should (equal "t-col-report" (plist-get (harness-ui-tasks--task) :id)))
          ;; The cell is dim, as the facts always were.
          (let ((time (text-property-any bol eol 'harness-task-column 'time)))
            (should time)
            (should (eq 'harness-dim-face (get-text-property (1+ time) 'face))))
          ;; The buttons are buttons.
          (should (harness-ui-tasks--find-button 'harness-ui-tasks-start bol eol))
          (should (harness-ui-tasks--find-button "report" bol eol)))))))

(ert-deftest harness-ui-tasks-columns-two-line-card-keeps-its-columns ()
  "A card that shows its recap keeps its facts in their columns, and its buttons in the zone.
The facts stay on the first line and the buttons go to the second, where
they start at the place the other cards' buttons start.  A section of
cards that all show their recap has no card with its buttons beside its
facts, so the facts take the room that would be left for them and end at
the window's edge."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test-in-wide-frame 140
      (harness-ui-tasks-test--waiting-four board)
      (with-current-buffer board
        (harness-ui-tasks--set-subtitle "t-col-report" t)
        (harness-ui-tasks--render t)
        (let* ((width (harness-ui-tasks--width))
               (lines (harness-ui-tasks-test--columns width))
               (places (harness-ui-tasks-test--line-up lines width))
               (card (seq-filter (lambda (line) (equal "t-col-report" (plist-get line :id))) lines)))
          ;; Five lines with columns: the three one-line cards' and the two
          ;; of the card that shows its recap.
          (should (= 5 (length lines)))
          (should (= 2 (length card)))
          (should (harness-ui-tasks-test--column-of (car card) 'time))
          (should-not (harness-ui-tasks-test--column-of (car card) 'zone))
          (should (equal '(zone) (mapcar #'car (plist-get (cadr card) :columns))))
          (should (equal "[Start now] [Reply] [No report]"
                         (string-trim-right (nth 3 (harness-ui-tasks-test--column-of (cadr card) 'zone)))))
          ;; The buttons of the second line start where the others' do.
          (should (= (cdr (assq 'zone places)) (nth 1 (harness-ui-tasks-test--column-of (cadr card) 'zone))))
          (should (= (- width 1 (string-width "[Start now] [Reply] [No report]")) (cdr (assq 'zone places))))
          (should (= (- (cdr (assq 'zone places)) 2) (cdr (assq 'time places)))))
        ;; Every card shows its recap: the zone is on the second lines
        ;; alone and the facts end at the edge of the window.
        (dolist (id '("t-col-high" "t-col-low" "t-col-wait"))
          (harness-ui-tasks--set-subtitle id t))
        (harness-ui-tasks--render t)
        (let* ((width (harness-ui-tasks--width))
               (lines (harness-ui-tasks-test--columns width))
               (places (harness-ui-tasks-test--line-up lines width)))
          (should (= 8 (length lines)))
          (should (= (- width 1) (cdr (assq 'time places))))
          (should (= (- width 1 (string-width "[Start now] [Reply] [No report]")) (cdr (assq 'zone places))))
          (should (= 4 (length (seq-filter (lambda (line) (harness-ui-tasks-test--column-of line 'zone)) lines))))
          (should (= 4 (length (seq-filter (lambda (line) (harness-ui-tasks-test--column-of line 'title)) lines)))))))))

(ert-deftest harness-ui-tasks-columns-sections-are-laid-out-apart ()
  "Each section of the board lays its cards out by itself.
A card in another section, with facts wider than any of these, changes
nothing of where the waiting cards' columns are, and has columns of its own."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test-in-wide-frame 140
      (harness-ui-tasks-test--waiting-four board)
      (with-current-buffer board
        (harness-ui-tasks--render t)
        (let* ((width (harness-ui-tasks--width))
               (before (harness-ui-tasks-test--line-up
                        (harness-ui-tasks-test--cards-of (harness-ui-tasks-test--columns width) 'pending)
                        width)))
          (harness-ui-tasks-test--fake-tasks
           board
           (list :id "t-col-busy" :prompt "Cache the product catalogue" :state "running" :column "active"
                 :started (- (float-time) 7500) :main-tree t))
          (harness-ui-tasks--render t)
          (let* ((lines (harness-ui-tasks-test--columns width))
                 (pending (harness-ui-tasks-test--line-up (harness-ui-tasks-test--cards-of lines 'pending) width))
                 (active (harness-ui-tasks-test--line-up (harness-ui-tasks-test--cards-of lines 'active) width)))
            (should (equal (sort (copy-sequence before) (lambda (a b) (string< (car a) (car b))))
                           (sort (copy-sequence pending) (lambda (a b) (string< (car a) (car b))))))
            ;; Its own: it has the main tree and the time it has run, and
            ;; its zone is as wide as its own buttons.
            (should (equal '(main-tree time title zone)
                           (sort (mapcar #'car active) #'string<)))
            (should (= (- width 1 (string-width "[Steer] [Pause]")) (cdr (assq 'zone active))))))))))


(defun harness-ui-tasks-test--busy-session ()
  "Put the session of a working task in the session cache; return its id.
It has todos, token figures, a rate and a cost: every fact a card has."
  (puthash "s-col-busy"
           (list :id "s-col-busy" :name "Count the tokens" :status "running" :context-window 200000
                 :usage (list :context 12300 :last-output 100 :output 3400 :cost 0.0123
                              :stream-output 3360 :stream-seconds 70.0)
                 :todos (list (list :status "done" :text "Read it")
                              (list :status "in-progress" :text "Write it")
                              (list :status "pending" :text "Check it")))
           harness-ui--sessions)
  (puthash "s-col-busy" (list :rate 48.0 :output 3400 :seconds 70.0 :calls 1 :at (float-time)
                              :model "demo:scripted")
           harness-ui--rates)
  "s-col-busy")

(defun harness-ui-tasks-test--working-pair ()
  "Two working tasks: one with every kind of fact, one with only the time it ran."
  (let ((now (float-time)))
    (list (list :id "t-col-busy" :session (harness-ui-tasks-test--busy-session) :prompt "Count the tokens"
                :state "running" :column "active" :started (- now 720))
          (list :id "t-col-idle" :prompt "Wait for it" :state "running" :column "active" :started (- now 60)))))

(defun harness-ui-tasks-test--draw-cards (column tasks width)
  "Draw the cards of TASKS in COLUMN for WIDTH columns; return their columns.
That is `harness-ui-tasks-test--columns' of a buffer of its own."
  (cl-letf (((symbol-function 'harness-ui-tasks--width) (lambda () width)))
    (with-temp-buffer
      (harness-ui-tasks--insert-cards column (mapcar (lambda (task) (cons task nil)) tasks))
      (harness-ui-tasks-test--columns width))))

(ert-deftest harness-ui-tasks-columns-short-of-room-a-section-drops-columns-together ()
  "A section short of room lets the token figures go first, then every fact.
It is the section that decides, not each card: the card that has no
tokens to show moves its columns with the one that has them, so what the
section's cards say goes on lining up.  The buttons stay."
  (harness-ui-tasks-test-with
    (let* ((tasks (harness-ui-tasks-test--working-pair))
           (real (symbol-function 'harness-ui-tasks--facts))
           (calls 0)
           (seen nil)
           (widest 200))
      ;; From a wide board down to the narrowest one that keeps two-line
      ;; cards: what facts the section shows, and how often it asked.
      (cl-letf (((symbol-function 'harness-ui-tasks--facts)
                 (lambda (&rest args) (cl-incf calls) (apply real args))))
        (cl-loop for width from widest downto harness-ui-tasks--collapse-min-width
                 do (let* ((lines (harness-ui-tasks-test--draw-cards 'active tasks width))
                           (places (harness-ui-tasks-test--line-up lines width))
                           (kinds (seq-filter (lambda (kind) (assq kind places))
                                              harness-ui-tasks--fact-kinds)))
                      ;; Each card's facts are worked out once, however
                      ;; many layouts are tried for the section.
                      (should (= (* 2 (1+ (- widest width))) calls))
                      (should (assq 'title places))
                      (should (assq 'zone places))
                      (should (= 2 (length lines)))
                      (unless (member kinds seen) (push kinds seen)))))
      ;; From every kind of fact, through all but the tokens, to none, and
      ;; nothing between, such as the tokens without the rest.
      (should (equal '((todos time tokens rate spend) (todos time rate spend) nil)
                     (nreverse seen)))
      ;; The card with no tokens moved when the section let them go: its
      ;; time ends the figures' width and the two columns between them
      ;; nearer the window's edge.
      (let* ((tokens (cdr (assq 'tokens (harness-ui-tasks--facts (car tasks) 'active
                                                                 (harness-ui-tasks--session (car tasks))))))
             (time-at (lambda (width)
                        (- width (cdr (assq 'time (harness-ui-tasks-test--line-up
                                                   (harness-ui-tasks-test--draw-cards 'active tasks width)
                                                   width))))))
             (dropped (cl-loop for width from widest downto harness-ui-tasks--collapse-min-width
                               unless (assq 'tokens (harness-ui-tasks-test--line-up
                                                     (harness-ui-tasks-test--draw-cards 'active tasks width) width))
                               return width)))
        (should (string-match-p " out\\'" tokens))
        (should dropped)
        (should (= (+ 2 (string-width tokens))
                   (- (funcall time-at widest) (funcall time-at dropped))))))))

(ert-deftest harness-ui-tasks-columns-long-title-is-cut-to-leave-the-facts-their-room ()
  "A title longer than its room is cut short of what comes after it.
The room is what is left of the line past the title's column and the
first thing its card has after it: a long title never runs into its
card's facts, and a card with fewer of them lets its title run on until
the ones it has -- the buttons, when it has no fact at all."
  (harness-ui-tasks-test-with
    (let* ((long (make-string 150 ?x))
           (tasks (harness-ui-tasks-test--working-pair))
           (busy (car tasks))
           (idle (plist-put (copy-sequence (cadr tasks)) :name (concat "Idle " long)))
           ;; Not started, so it has no time to say, and nothing else.
           (bare (list :id "t-col-bare" :name (concat "Bare " long) :state "running" :column "active"))
           (width 110))
      (puthash "s-col-busy" (plist-put (copy-sequence (gethash "s-col-busy" harness-ui--sessions))
                                       :name (concat "Busy " long))
               harness-ui--sessions)
      (let* ((lines (harness-ui-tasks-test--draw-cards 'active (list busy idle bare) width))
             (places (harness-ui-tasks-test--line-up lines width))
             (column (lambda (id kind)
                       (harness-ui-tasks-test--column-of (harness-ui-tasks-test--line-of lines id) kind))))
        ;; There is room for every kind of fact at this width, and no more
        ;; than the least a title keeps.
        (should (assq 'tokens places))
        (dolist (id '("t-col-busy" "t-col-idle" "t-col-bare"))
          (should (string-suffix-p "…" (nth 3 (funcall column id 'title)))))
        ;; Each title stops two columns short of its card's first fact:
        ;; the busy card's todos, the idle card's time, further right.
        (should (= (- (nth 1 (funcall column "t-col-busy" 'todos)) 2) (nth 2 (funcall column "t-col-busy" 'title))))
        (should (= (- (nth 1 (funcall column "t-col-idle" 'time)) 2) (nth 2 (funcall column "t-col-idle" 'title))))
        (should (> (nth 2 (funcall column "t-col-idle" 'title)) (nth 2 (funcall column "t-col-busy" 'title))))
        (should-not (funcall column "t-col-bare" 'time))
        (should (= (- (nth 1 (funcall column "t-col-bare" 'zone)) 2) (nth 2 (funcall column "t-col-bare" 'title))))
        (should (> (nth 2 (funcall column "t-col-bare" 'title)) (nth 2 (funcall column "t-col-idle" 'title))))
        (should (>= (- (nth 2 (funcall column "t-col-busy" 'title)) (nth 1 (funcall column "t-col-busy" 'title)))
                    harness-ui-tasks--min-title-room))))))

(ert-deftest harness-ui-tasks-columns-icons-drawn-wide-do-not-move-the-titles ()
  "A mark drawn wider than the characters that stand for it moves no title.
Titles start at a column worked out from how wide the marks before them
are drawn, in pixels, not from how many characters they are: the card
with a wide image for its icon and the one with a plain symbol start
their titles together, and the wide image makes room for both."
  (harness-ui-tasks-test-with
    (let* ((wide (propertize "x" 'display '(image :type svg :file "wide.svg")))
           (tasks (harness-ui-tasks-test--working-pair))
           (title-of (lambda (width)
                       (cdr (assq 'title (harness-ui-tasks-test--line-up
                                          (harness-ui-tasks-test--draw-cards 'active tasks width) width))))))
      (cl-letf (((symbol-function 'frame-char-width) (lambda (&optional _) 10)))
        ;; Plain symbols: two spaces, a chevron, a space, the icon and a
        ;; space take six columns.
        (should (= 6 (funcall title-of 120)))
        ;; One card draws a 30 pixel image: its title would start two
        ;; columns later than the plain one's, and so do both.
        (cl-letf (((symbol-function 'image-size) (lambda (&rest _) (cons 30 10)))
                  ((symbol-function 'harness-ui-tasks--icon)
                   (lambda (task &rest _) (if (equal "t-col-busy" (plist-get task :id)) wide "x"))))
          (should (= 8 (funcall title-of 120))))))))

(ert-deftest harness-ui-tasks-columns-facts-are-cells-of-a-kind ()
  "A card's facts are cells: one for each kind of fact it has, in the order of the kinds.
A working task that was archived and works in the main tree has every
kind a working card can have; one in the merge queue, the queue's;
a completed one, when it was done and what it cost.  The cells are dim
and keep what they carry: the tokens a button that asks for another
limit, the cost its tooltip.  The priority is not a fact: the arrow
says it."
  (harness-ui-tasks-test-with
    (let* ((now (float-time))
           (busy (car (harness-ui-tasks-test--working-pair)))
           (session (harness-ui-tasks--session busy))
           (kinds (lambda (task column session)
                    (mapcar #'car (harness-ui-tasks--facts task column session)))))
      (setq busy (plist-put (plist-put (copy-sequence busy) :main-tree t) :archived t))
      (let ((cells (harness-ui-tasks--facts busy 'active session)))
        (should (equal '(archived main-tree todos time tokens rate spend) (mapcar #'car cells)))
        (should (equal '("archived" "main tree" "1/3" "12m") (mapcar #'cdr (seq-take cells 4))))
        (should (equal "48 tok/s avg" (cdr (assq 'rate cells))))
        (should (equal "$0.012" (cdr (assq 'spend cells))))
        (should (string-prefix-p "12.4k/200k · 3.4k out" (cdr (assq 'tokens cells))))
        ;; Dim, and carrying their own properties.
        (dolist (cell cells)
          (should (eq 'harness-dim-face (get-text-property 0 'face (cdr cell)))))
        (should (get-text-property 0 'harness-context-session (cdr (assq 'tokens cells))))
        (should (keymapp (get-text-property 0 'keymap (cdr (assq 'tokens cells)))))
        (should (stringp (get-text-property 0 'help-echo (cdr (assq 'spend cells)))))
        (should (stringp (get-text-property 0 'help-echo (cdr (assq 'rate cells)))))
        (should-not (cl-some (lambda (cell) (string-match-p "priority" (cdr cell))) cells)))
      ;; The tokens and the todos are for work in progress; in review it
      ;; says when it finished instead.  A task with nothing to say has no
      ;; cell for it.
      (should (equal '(archived main-tree time rate spend)
                     (funcall kinds (plist-put (copy-sequence busy) :finished (- now 3600)) 'review session)))
      (should (equal '(time) (funcall kinds (list :id "t-1" :started (- now 60)) 'active nil)))
      (should (equal nil (funcall kinds (list :id "t-1") 'active nil)))
      ;; The queue's: where the merge stands, then the time it joined.
      (let ((queued (list :id "t-2" :merge-status "conflict" :merge-queued (- now 5) :column "merging")))
        (should (equal '(merge time) (funcall kinds queued 'merging nil)))
        (should (equal '("conflict" "queued 5s ago") (mapcar #'cdr (harness-ui-tasks--facts queued 'merging nil))))
        (should (equal '(time) (funcall kinds (plist-put (copy-sequence queued) :merge-status "queued")
                                        'merging nil)))
        (should (equal "merging now" (cdr (assq 'merge (harness-ui-tasks--facts
                                                        (plist-put (copy-sequence queued) :merge-status "merging")
                                                        'merging nil))))))
      ;; A queue held back says so with the time, in the one cell.
      (should (equal "queued 40s ago · queue suspended"
                     (cdr (assq 'time (harness-ui-tasks--facts
                                       (list :id "t-3" :created (- now 40) :queue-suspended t) 'pending nil)))))
      (should (equal '(time) (funcall kinds (list :id "t-4" :created (- now 40) :priority "high") 'pending nil)))
      ;; A write-up in progress has no time to speak of.
      (should (equal nil (funcall kinds (list :id "t-5" :state "refining" :created (- now 40)) 'backlog nil))))))

(ert-deftest harness-ui-tasks-columns-point-stays-by-column-not-by-count ()
  "A position in the facts or the buttons is kept as far from the line's end.
The title's column is a place on the line from its start, as the text
before it is; everything after a space aligned to the window's right edge is measured from the
line's end (`harness-ui-tasks--aligned-p'), where it stays when what
is on its left changes."
  (harness-ui-tasks-test-with
    (let ((tasks (harness-ui-tasks-test--working-pair)))
      (cl-letf (((symbol-function 'harness-ui-tasks--width) (lambda () 120)))
        (with-temp-buffer
          (harness-ui-tasks--insert-cards 'active (mapcar (lambda (task) (cons task nil)) tasks))
          (goto-char (point-min))
          (let* ((title (text-property-any (point-min) (line-end-position) 'harness-task-column 'title))
                 (time (text-property-any (point-min) (line-end-position) 'harness-task-column 'time))
                 (zone (text-property-any (point-min) (line-end-position) 'harness-task-column 'zone)))
            (should (and title time zone))
            ;; Not the spaces that start the title's text, nor the left of it.
            (should-not (harness-ui-tasks--aligned-p (point-min)))
            (should-not (harness-ui-tasks--aligned-p (1+ title)))
            (should-not (harness-ui-tasks--aligned-p (+ title 4)))
            ;; The cells and the buttons are right of one.
            (should (harness-ui-tasks--aligned-p (1+ time)))
            (should (harness-ui-tasks--aligned-p (1+ zone)))
            (should (harness-ui-tasks--aligned-p (1- (line-end-position))))))))))

;;;; A board key, from the box

(declare-function harness-compose-panel-key "harness-ui-compose")
(declare-function harness-compose-set "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")

(ert-deftest harness-ui-tasks-box-presses-a-board-key ()
  "C-c . in the compose box presses a key of the board, which types there.
The board is a panel of the box (`harness-compose-panel-key'), up to
the lines above the box.  F, the fullscreen layout, acts anywhere on
it; a key for the task at point has none from the box, which is said.
The draft stays in the box and so does point, where it was."
  (harness-ui-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (where nil))
      (harness-ui-tasks-test--type-and-submit board "Waiting task")
      (harness-ui-tasks-test--wait-text board "Pending  1")
      (with-current-buffer board
        ;; Keys reach the buffer of the selected window.
        (should (eq board (window-buffer (selected-window))))
        (should (eq 'harness-compose-panel-key (key-binding (kbd "C-c ."))))
        ;; The board region is the panel, and what is below it is not.
        (should (eq 'board (get-text-property (point-min) 'harness-compose-panel)))
        (should (eq 'board (get-text-property (1- harness-ui-tasks--list-end) 'harness-compose-panel)))
        (should-not (get-text-property harness-ui-tasks--list-end 'harness-compose-panel))
        (should-not (get-text-property (1- harness-compose-start) 'harness-compose-panel))
        (should-not (get-text-property (point-min) 'harness-task-id))
        (harness-compose-set "draft")
        (goto-char (+ harness-compose-start 2))
        (cl-letf (((symbol-function 'harness-fullscreen)
                   (lambda () (interactive) (push (point) where))))
          (execute-kbd-macro (kbd "C-c . F")))
        ;; It ran with point on the board's start, and point is back in the box.
        (should (equal (list (point-min)) where))
        (should (= (point) (+ harness-compose-start 2)))
        (should (equal "draft" (harness-compose-text)))
        (should (equal "draft" (buffer-substring-no-properties harness-compose-start harness-compose-end)))
        ;; Typed in the box, F types.
        (execute-kbd-macro "F")
        (should (equal "drFaft" (harness-compose-text)))
        ;; A key for the task at point has no task from the box; one the
        ;; board does not bind is no board key.
        (dolist (keys '("s" "e" "m" "v" "x"))
          (let ((err (should-error (cl-letf (((symbol-function 'read-key-sequence) (lambda (&rest _) keys)))
                                     (harness-compose-panel-key))
                                   :type 'user-error)))
            (should (string-match-p (format "\\`%s has nothing to act on from the box" keys) (cadr err)))))
        (let ((err (should-error (cl-letf (((symbol-function 'read-key-sequence) (lambda (&rest _) "h")))
                                   (harness-compose-panel-key))
                                 :type 'user-error)))
          (should (equal "No panel above the box has h" (cadr err))))
        (should (equal "drFaft" (harness-compose-text)))
        (should (= (point) (+ harness-compose-start 3)))))))

(ert-deftest harness-ui-tasks-box-says-how-to-press-a-board-key ()
  "The empty box, the box's tooltip and the menu say how to press a board key."
  (harness-ui-tasks-test-with
    (with-current-buffer board
      (let ((hint "C-c \\. F: a board key from the box"))
        ;; The empty box that composes a task shows it, in either mode.
        (should (string-match-p hint (harness-ui-tasks--placeholder)))
        (should (string-match-p hint (overlay-get harness-compose--placeholder 'before-string)))
        (setq harness-ui-tasks--mode (quote refine))
        (should (string-match-p hint (harness-ui-tasks--placeholder)))
        (setq harness-ui-tasks--mode (quote submit))
        ;; A box for a message does not take the room, but its tooltip has it.
        (setq harness-ui-tasks--target '(reply . "t-1"))
        (should-not (string-match-p "board key" (harness-ui-tasks--placeholder)))
        (setq harness-ui-tasks--target nil)
        ;; The tooltip of the prompt, new task or message.
        (should (string-match-p hint (get-text-property (1- harness-compose-start) 'help-echo)))
        (harness-ui-tasks--render-tail)
        (should (string-match-p hint (get-text-property (1- harness-compose-start) 'help-echo))))
      ;; The menu lists the key among the box's.
      (let ((entries (cl-loop for column in (cdr (get 'harness-ui-tasks-mode 'harness-menu-group))
                              append (cl-loop for item across column
                                              when (and (consp item) (stringp (car item))) collect item))))
        (should (member '("C-c ." "A board key, from the box" harness-compose-panel-key) entries))))))

;;;; The backlog banner in a task's session

(defconst harness-ui-tasks-test-write-up
  "Fix nested quotes in the parser\n\n- Handle nested quotes in `parse-args'.\n- Done when the quote tests pass."
  "What the demo provider writes a backlog task up as.")

(defun harness-ui-tasks-test--chat (sid)
  "Open SID's chat buffer in the selected window and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (set-window-buffer (selected-window) buffer)
    (harness-test-wait (lambda () (not (buffer-local-value 'harness-chat--loading buffer)))
                       10 "the session to load")
    buffer))

(defun harness-ui-tasks-test--chat-text (buffer)
  "BUFFER's text, without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-tasks-test--wait-chat-text (buffer regexp)
  "Wait until BUFFER's text matches REGEXP."
  (harness-test-wait (lambda () (string-match-p regexp (harness-ui-tasks-test--chat-text buffer)))
                     10 (format "the session to show %s" regexp)))

(defun harness-ui-tasks-test--push-chat-button (buffer label)
  "Push the button LABEL in BUFFER, as a click on it does."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (pos)
        (while (and (not pos) (search-forward label nil t))
          (when (button-at (match-beginning 0)) (setq pos (match-beginning 0))))
        (unless pos (error "No %s button in %s" label (buffer-name)))
        (push-button pos)))))

(defun harness-ui-tasks-test--refine (&optional script)
  "Submit a task written up for the backlog; return its id.
SCRIPT is the provider's, or nil for a complete write-up."
  (setq harness-provider-demo-script-override
        (or script
            `((:type text :delta ,harness-ui-tasks-test-write-up)
              (:type done :stop-reason end-turn))))
  (plist-get (harness-call 'task/submit default-directory
                           "the parser chokes on nested quotes" (list :refine t))
             :id))

(ert-deftest harness-ui-tasks-backlog-session-banner ()
  "A waiting backlog task's session says so, and its [Start now] starts it.
The compose box says that sending a message there starts the task."
  (harness-ui-tasks-test-with
    (harness-test-load-module 'ui-chat)
    (let* ((id (harness-ui-tasks-test--refine))
           (sid (plist-get (harness-call 'task/get id) :session)))
      (harness-test-wait (lambda () (eq 'pending (plist-get (harness-call 'task/get id) :state)))
                         10 "the write-up to finish")
      (should (plist-get (harness-call 'task/get id) :backlog))
      (let ((chat (harness-ui-tasks-test--chat sid)))
        (harness-ui-tasks-test--wait-chat-text chat "Waiting in the Backlog")
        (let ((text (harness-ui-tasks-test--chat-text chat)))
          (should (string-match-p "\\[Start now\\]" text))
          (should (string-match-p "\\[Queue it\\]" text))
          (should (string-match-p "a message starts the task" text)))
        (with-current-buffer chat
          (should (equal "Message…  sending starts the task" harness-chat-placeholder)))
        (setq harness-provider-demo-script-override
              '((:type text :delta "Working on it.") (:type done :stop-reason end-turn)))
        (harness-ui-tasks-test--push-chat-button chat "[Start now]")
        (harness-test-wait (lambda () (eq 'done (plist-get (harness-call 'task/get id) :state)))
                           10 "the task to be done")
        (harness-ui-tasks-test--wait-chat-text chat "Working on it.")
        (harness-test-wait
         (lambda () (not (string-match-p "Waiting in the Backlog"
                                         (harness-ui-tasks-test--chat-text chat))))
         5 "the banner to go")
        (should-not (plist-get (harness-call 'task/get id) :backlog))))))

(ert-deftest harness-ui-tasks-backlog-session-banner-supersedes-write-up ()
  "A write-up running in its session says so, and [Start now] supersedes it.
The box says a message stops the write-up and starts the task."
  (harness-ui-tasks-test-with
    (harness-test-load-module 'ui-chat)
    (let* ((id (harness-ui-tasks-test--refine '((:type text :delta "Still writing it up"))))
           (sid (plist-get (harness-call 'task/get id) :session)))
      (harness-test-wait (lambda () (harness-call 'agent/running sid))
                         10 "the write-up to run")
      (let ((chat (harness-ui-tasks-test--chat sid)))
        (harness-ui-tasks-test--wait-chat-text chat "An agent is writing it up")
        (let ((text (harness-ui-tasks-test--chat-text chat)))
          (should (string-match-p "\\[Start now\\]" text))
          (should-not (string-match-p "\\[Queue it\\]" text)))
        (with-current-buffer chat
          (should (equal "Message…  sending stops the write-up and starts the task"
                         harness-chat-placeholder)))
        (setq harness-provider-demo-script-override
              '((:type text :delta "Working on it.") (:type done :stop-reason end-turn)))
        (harness-ui-tasks-test--push-chat-button chat "[Start now]")
        (harness-test-wait (lambda () (eq 'done (plist-get (harness-call 'task/get id) :state)))
                           10 "the task to start and be done")
        (should-not (plist-get (harness-call 'task/get id) :backlog))
        ;; The stopped write-up never rewrote the task's prompt.
        (should (equal "the parser chokes on nested quotes"
                       (plist-get (harness-call 'task/get id) :prompt)))))))

(ert-deftest harness-ui-tasks-backlog-session-message-starts-through-a-write-up ()
  "A message typed in a writing-up session stops it and starts the task.
This is the report's case: typing \"start\" where the task is written up
runs the task, not another write-up."
  (harness-ui-tasks-test-with
    (harness-test-load-module 'ui-chat)
    (let* ((id (harness-ui-tasks-test--refine '((:type text :delta "Still writing it up"))))
           (sid (plist-get (harness-call 'task/get id) :session)))
      (harness-test-wait (lambda () (harness-call 'agent/running sid))
                         10 "the write-up to run")
      (let ((chat (harness-ui-tasks-test--chat sid)))
        (harness-ui-tasks-test--wait-chat-text chat "An agent is writing it up")
        (setq harness-provider-demo-script-override
              '((:type text :delta "Working on it.") (:type done :stop-reason end-turn)))
        (with-current-buffer chat
          (goto-char harness-compose-end)
          (insert "start")
          (harness-chat-send))
        (harness-test-wait (lambda () (eq 'done (plist-get (harness-call 'task/get id) :state)))
                           10 "the message to start the task")
        (should-not (plist-get (harness-call 'task/get id) :backlog))
        (should (equal "Working on it."
                       (plist-get (car (last (cl-remove-if-not
                                              (lambda (n) (eq (plist-get n :kind) 'assistant))
                                              (harness-call 'session/nodes sid))))
                                  :content)))
        ;; The message that started it stays in the transcript.
        (should (member "start"
                        (mapcar (lambda (n) (plist-get n :content))
                                (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                                  (harness-call 'session/nodes sid)))))))))

;;;; Ready for review, in the mode line

(defvar harness-ui-tasks--in-review)
(defvar harness-ui-tasks--timer)
(defvar harness-ui-notify-segment-functions)
(defvar harness-ui-notify--string)
(defvar harness-ui-notify--last-blocked)
(defvar harness-notify-mode)
(defvar harness-ui-event-functions)
(defvar harness-ui-connected-hook)
(defvar harness-ui-sessions-changed-hook)
(defvar harness-ui-rate-functions)
(defvar harness-ui-live-functions)
(defvar harness-ui-redraw-hook)
(defvar harness-ui-quota-functions)
(defvar harness-chat-panel-functions)
(defvar harness-ui-map)
(declare-function harness-ui-notify-refresh "harness-ui-notify")
(declare-function harness-ui-tasks--on-review-event "harness-ui-tasks")
(declare-function harness-ui-tasks--notify-segment "harness-ui-tasks")
(declare-function harness-ui-tasks--fetch-review "harness-ui-tasks")
(declare-function harness-ui-tasks--init "harness-ui-tasks")
(declare-function harness-ui-tasks--shutdown "harness-ui-tasks")
(declare-function harness-tasks-review "harness-ui-tasks")

(defmacro harness-ui-tasks-test-with-review-count (&rest body)
  "Run BODY with no task counted in review and the mode line notifier on.
The count is the notifier's only segment, so that nothing else, such as
the version page's nag, shows beside it."
  (declare (indent 0))
  `(progn
     (require 'harness-ui-notify)
     (require 'harness-ui-tasks)
     (let ((harness-ui-tasks--in-review (make-hash-table :test 'equal))
           (harness-ui-notify-segment-functions (list #'harness-ui-tasks--notify-segment))
           (harness-notify-mode t)
           (harness-ui-notify--string "")
           (harness-ui-notify--last-blocked 0))
       ,@body)))

(defun harness-ui-tasks-test--flag (n)
  "The notifier's count of N tasks in review, as it reads in batch."
  (concat (substring-no-properties (harness-ui-icon 'harness-icon-task-review)) (number-to-string n)))

(defun harness-ui-tasks-test--review-event (&rest tasks)
  "Hand the count every task of TASKS, views, as `task/changed' brings them."
  (dolist (task tasks)
    (harness-ui-tasks--on-review-event "task/changed" (list task))))

(ert-deftest harness-ui-tasks-review-count-in-the-mode-line ()
  "The notifier counts the tasks ready for review, of every project.
An archived one is not counted, and nor is one at work.  It shows with
no session at work, as a task in review has an idle one, and goes once
the last task leaves review or is deleted.  The notifier is drawn again
only when the count changes."
  (harness-ui-tasks-test-with-review-count
    (let ((harness-ui--sessions (make-hash-table :test 'equal))
          (drawn 0))
      (cl-letf* ((refresh (symbol-function 'harness-ui-notify-refresh))
                 ((symbol-function 'harness-ui-notify-refresh) (lambda () (cl-incf drawn) (funcall refresh)))
                 ((symbol-function 'force-mode-line-update) #'ignore))
        (harness-ui-notify-refresh)
        (should (equal "" harness-ui-notify--string))
        (setq drawn 0)
        ;; A task reaches review: the notifier shows, though no session works.
        (harness-ui-tasks-test--review-event '(:id "t1" :project "/p/alpha/" :column "review" :finished 10))
        (should (equal (concat " harness " (harness-ui-tasks-test--flag 1) " ")
                       (substring-no-properties harness-ui-notify--string)))
        (should (= 1 drawn))
        ;; The same task again, a task at work and an archived one in review:
        ;; the count stays, and the notifier is not drawn again.
        (harness-ui-tasks-test--review-event '(:id "t1" :project "/p/alpha/" :column "review" :finished 10)
                                             '(:id "t2" :project "/p/alpha/" :column "active")
                                             '(:id "t3" :project "/p/beta/" :column "review" :archived t))
        (should (= 1 drawn))
        (should (= 1 (hash-table-count harness-ui-tasks--in-review)))
        ;; Another project's task: both are counted.
        (harness-ui-tasks-test--review-event '(:id "t4" :project "/p/beta/" :column "review" :finished 20))
        (should (equal (concat " harness " (harness-ui-tasks-test--flag 2) " ")
                       (substring-no-properties harness-ui-notify--string)))
        (let ((segment (harness-ui-tasks--notify-segment))
              (clicked 0))
          (should (eq 'harness-notify-review-face (get-text-property 1 'face segment)))
          (should (eq 'mode-line-highlight (get-text-property 1 'mouse-face segment)))
          ;; Hovering says how many each project has, the last to have one
          ;; come to review first.
          (should (equal "Tasks ready for your review: 1 in beta, 1 in alpha (mouse-1: open the task board on them)"
                         (get-text-property 1 'help-echo segment)))
          ;; A click opens the board on them.
          (cl-letf (((symbol-function 'harness-tasks-review) (lambda () (interactive) (cl-incf clicked))))
            (dolist (key (list [mode-line mouse-1] [mode-line mouse-2] [mouse-1] (kbd "RET")))
              (funcall (lookup-key (get-text-property 1 'local-map segment) key))))
          (should (= 4 clicked)))
        ;; With sessions at work, it comes before their counts.
        (puthash "s1" '(:id "s1" :status "running") harness-ui--sessions)
        (harness-ui-notify-refresh)
        (should (string-match-p (concat "\\` harness " (regexp-quote (harness-ui-tasks-test--flag 2))
                                        " " (regexp-quote (substring-no-properties (harness-ui-icon 'harness-icon-running)))
                                        "1 \\'")
                                (substring-no-properties harness-ui-notify--string)))
        (clrhash harness-ui--sessions)
        ;; One task goes on to merge, the other is deleted: the count goes.
        (setq drawn 0)
        (harness-ui-tasks-test--review-event '(:id "t1" :project "/p/alpha/" :column "merging" :finished 10))
        (should (equal (concat " harness " (harness-ui-tasks-test--flag 1) " ")
                       (substring-no-properties harness-ui-notify--string)))
        (should (equal "Tasks ready for your review: 1 in beta (mouse-1: open the task board on it)"
                       (get-text-property 1 'help-echo (harness-ui-tasks--notify-segment))))
        (harness-ui-tasks--on-review-event "task/deleted" (list "t3"))
        (should (= 1 drawn))
        (harness-ui-tasks--on-review-event "task/deleted" (list "t4"))
        (should (= 2 drawn))
        (should-not (harness-ui-tasks--notify-segment))
        (should (equal "" harness-ui-notify--string))))))

(ert-deftest harness-ui-tasks-review-count-without-the-notifier ()
  "With the notifier off, the count is kept and nothing is drawn."
  (harness-ui-tasks-test-with-review-count
    (let ((harness-notify-mode nil))
      (cl-letf (((symbol-function 'harness-ui-notify-refresh) (lambda () (error "Drawn"))))
        (harness-ui-tasks-test--review-event '(:id "t1" :project "/p/alpha/" :column "review"))
        (should (= 1 (hash-table-count harness-ui-tasks--in-review)))))))

(ert-deftest harness-ui-tasks-review-opens-the-right-board ()
  "A click on the count opens the board of the current project when it has tasks in review.
Otherwise the board of the project whose task came to review last.
Point goes to the card of the project's last task to come to review,
and its session names the project to switch to.  With none, it says so."
  (harness-ui-tasks-test-with-review-count
    (let* ((visited nil)
           (project (lambda (prefix)
                      ;; A git root of its own, wherever the temporary
                      ;; directory is: below it is the same project.
                      (let ((dir (file-name-as-directory (make-temp-file prefix t))))
                        (make-directory (expand-file-name ".git" dir))
                        (make-directory (expand-file-name "sub" dir))
                        dir)))
           (alpha (funcall project "harness-test-alpha-"))
           (beta (funcall project "harness-test-beta-"))
           (elsewhere (file-name-as-directory (make-temp-file "harness-test-elsewhere-" t))))
      (unwind-protect
          (cl-letf (((symbol-function 'harness-ui-tasks-visit-task)
                     (lambda (id project &optional session-id) (push (list id project session-id) visited) nil))
                    ((symbol-function 'harness-ui-notify-refresh) #'ignore))
            (let ((default-directory elsewhere))
              (should-error (harness-tasks-review) :type 'user-error))
            (harness-ui-tasks-test--review-event
             `(:id "a1" :project ,alpha :session "sa1" :column "review" :finished 10)
             `(:id "a2" :project ,alpha :session "sa2" :column "review" :finished 30)
             `(:id "b1" :project ,beta :session "sb1" :column "review" :finished 20))
            (cl-flet ((click-in (dir)
                        (let ((default-directory dir))
                          (setq visited nil)
                          (harness-tasks-review)
                          (car visited))))
              ;; Elsewhere: the project whose task came last, at that task.
              (should (equal (list "a2" alpha "sa2") (click-in elsewhere)))
              ;; In a project with tasks in review, from anywhere in it:
              ;; its own board, at its last task to come.
              (should (equal (list "b1" beta "sb1") (click-in beta)))
              (should (equal (list "b1" beta "sb1") (click-in (expand-file-name "sub/" beta))))
              ;; The last one gone, the project of the one before it.
              (harness-ui-tasks-test--review-event `(:id "a2" :project ,alpha :column "done"))
              (should (equal (list "b1" beta "sb1") (click-in elsewhere)))
              (should (equal (list "a1" alpha "sa1") (click-in alpha)))))
        (dolist (d (list alpha beta elsewhere)) (ignore-errors (delete-directory d t)))))))

(ert-deftest harness-ui-tasks-review-count-wiring ()
  "The module counts the tasks in review as it starts, and stops as it stops.
Started while connected, it asks for every project's tasks at once; it
asks again whenever the UI connects.  A harness without tasks, which
fails the request, has none to count."
  (harness-ui-tasks-test-with-review-count
    (let ((requests nil)
          (answer (lambda () (harness-resolved '((:id "t1" :project "/p/alpha/" :column "review")
                                                  (:id "t2" :project "/p/alpha/" :column "active")
                                                  (:id "t3" :project "/p/beta/" :column "review")))))
          (harness-ui-notify-segment-functions nil)
          (harness-ui--sessions (make-hash-table :test 'equal))
          (harness-ui-event-functions nil)
          (harness-ui-connected-hook nil)
          (harness-ui-sessions-changed-hook nil)
          (harness-ui-rate-functions nil)
          (harness-ui-live-functions nil)
          (harness-ui-redraw-hook nil)
          (harness-ui-quota-functions nil)
          (harness-chat-panel-functions nil)
          (harness-ui-tasks--timer nil)
          (harness-ui-map (make-sparse-keymap)))
      (cl-letf (((symbol-function 'harness-ui-request)
                 (lambda (method params) (push (list method params) requests) (funcall answer)))
                ((symbol-function 'harness-ui-connected-p) (lambda () t))
                ((symbol-function 'force-mode-line-update) #'ignore))
        (unwind-protect
            (progn
              (harness-ui-tasks--init)
              (should (equal '(("_harness/task/list" nil)) requests))
              (should (memq #'harness-ui-tasks--notify-segment harness-ui-notify-segment-functions))
              (should (memq #'harness-ui-tasks--on-review-event harness-ui-event-functions))
              (should (memq #'harness-ui-tasks--fetch-review harness-ui-connected-hook))
              (should (equal (concat " harness " (harness-ui-tasks-test--flag 2) " ")
                             (substring-no-properties harness-ui-notify--string)))
              ;; Initialised again, as a reload does: the hooks once each.
              (harness-ui-tasks--init)
              (should (= 1 (cl-count #'harness-ui-tasks--notify-segment harness-ui-notify-segment-functions)))
              ;; Connecting to a harness without tasks: nothing to count.
              (setq requests nil
                    answer (lambda () (harness-rejected '(harness-error "Unknown method"))))
              (run-hooks 'harness-ui-connected-hook)
              (should (equal '(("_harness/task/list" nil)) requests))
              (should (zerop (hash-table-count harness-ui-tasks--in-review)))
              (should (equal "" harness-ui-notify--string))
              ;; Back to a harness with tasks, then the module stops.
              (setq answer (lambda () (harness-resolved '((:id "t1" :project "/p/alpha/" :column "review")))))
              (run-hooks 'harness-ui-connected-hook)
              (should (= 1 (hash-table-count harness-ui-tasks--in-review)))
              (harness-ui-tasks--shutdown)
              (should-not (memq #'harness-ui-tasks--notify-segment harness-ui-notify-segment-functions))
              (should-not (memq #'harness-ui-tasks--on-review-event harness-ui-event-functions))
              (should-not (memq #'harness-ui-tasks--fetch-review harness-ui-connected-hook))
              (should (zerop (hash-table-count harness-ui-tasks--in-review)))
              (should (equal "" harness-ui-notify--string)))
          (when (timerp harness-ui-tasks--timer) (cancel-timer harness-ui-tasks--timer)))))))

(ert-deftest harness-ui-tasks-review-count-follows-the-harness ()
  "The count follows the harness's tasks, all the way through.
A task submitted on the board finishes and waits for review: the
notifier counts it, as it does after fetching every project's tasks
again; a click from another directory opens the board on its card; and
verifying it takes the count away."
  (harness-ui-tasks-test-with
    (harness-ui-tasks-test-with-review-count
      (let ((harness-tasks-require-verification t)
            (elsewhere (file-name-as-directory (make-temp-file "harness-test-elsewhere-" t))))
        (unwind-protect
            (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
              (with-current-buffer board (harness-ui-tasks-refresh))
              (harness-ui-tasks-test--type-and-submit board "Count me in review")
              (harness-ui-tasks-test--wait-text board "Ready for review  1\\(.\\|\n\\)*Count me in review")
              (harness-test-wait (lambda () (string-search (harness-ui-tasks-test--flag 1) harness-ui-notify--string))
                                 5 "the notifier to count the task")
              ;; Every project's tasks again, as when the UI connects: the same.
              (clrhash harness-ui-tasks--in-review)
              (harness-ui-tasks--fetch-review)
              (harness-test-wait (lambda () (= 1 (hash-table-count harness-ui-tasks--in-review)))
                                 5 "the tasks to be fetched")
              (let ((id (plist-get (car (harness-call 'task/list dir)) :id)))
                ;; A click from elsewhere opens the board, point on the card.
                (with-current-buffer board (goto-char (point-max)))
                (with-temp-buffer
                  (setq default-directory elsewhere)
                  (harness-tasks-review))
                (harness-test-wait (lambda () (with-current-buffer board
                                                (equal id (get-text-property (point) 'harness-task-id))))
                                   5 "point on the card")
                (should (eq board (window-buffer (selected-window)))))
              ;; v accepts the work: the count goes, and the notifier with it.
              (harness-ui-tasks-test--goto-card board "Count me in review")
              (with-current-buffer board (call-interactively (key-binding (kbd "v"))))
              (harness-ui-tasks-test--wait-text board "Completed  1\\(.\\|\n\\)*Count me in review")
              (harness-test-wait (lambda () (zerop (hash-table-count harness-ui-tasks--in-review)))
                                 5 "the count to go")
              (should-not (string-search (harness-ui-tasks-test--flag 1) harness-ui-notify--string)))
          (ignore-errors (delete-directory elsewhere t)))))))

(provide 'harness-ui-tasks-test)
;;; harness-ui-tasks-test.el ends here
