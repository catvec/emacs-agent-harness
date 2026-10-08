;;; harness-ui-tasks-search-test.el --- Tests for the board's search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the board's smart search against the real state layer, the
;; in-process ACP connection and the demo provider: the line read by /
;; goes to the model, the board filters to what it answers, the banner
;; says what is shown and what was done, an order runs at once with
;; [Undo], a proposal waits for an OK, a failure offers [Retry] and C-g
;; shows every task again.

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
(defvar harness-tasks-worktrees)
(defvar harness-tasks-search-model)
(defvar harness-tasks-search--system)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--tasks)
(defvar harness-ui-tasks--list-end)
(defvar harness-ui-tasks-filter)
(defvar harness-ui-tasks-search--state)
(defvar harness-ui-tasks-search--model)
(defvar harness-ui-tasks-search-history)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-tasks--header "harness-ui-tasks")
(declare-function harness-ui-tasks--title "harness-ui-tasks")
(declare-function harness-ui-tasks-compose-quit "harness-ui-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks-search "harness-ui-tasks")
(declare-function harness-ui-tasks-search--banner "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--done-text "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--install "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--read "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--shutdown "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-clear "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-confirm "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-retry "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-undo "harness-ui-tasks-search")
(declare-function harness-tasks-search "harness-ui-tasks-search")
(declare-function harness-acp--drop-client "harness-acp")

(defconst harness-ui-tasks-search-test--work
  '((:type text :delta "Working on it.") (:type done :stop-reason end-turn))
  "What a task's session answers.")

(defvar harness-ui-tasks-search-test--replies nil
  "What the search model answers next: strings, in turn.
The last one answers every request after it.")

(defvar harness-ui-tasks-search-test--requests nil
  "The requests the search model got, newest first.")

(defun harness-ui-tasks-search-test--search-p (request)
  "Non-nil when REQUEST is a search's."
  (equal harness-tasks-search--system (plist-get request :system)))

(defun harness-ui-tasks-search-test--script (request)
  "The demo provider's script: a search answers from the replies, a task works."
  (if (harness-ui-tasks-search-test--search-p request)
      (let ((reply (if (cdr harness-ui-tasks-search-test--replies)
                       (pop harness-ui-tasks-search-test--replies)
                     (car harness-ui-tasks-search-test--replies))))
        (push request harness-ui-tasks-search-test--requests)
        `((:type text :delta ,reply)
          (:type usage :input 1200 :output 40 :cache-read 300 :cost 0.0015)
          (:type done :stop-reason end-turn)))
    harness-ui-tasks-search-test--work))

(defmacro harness-ui-tasks-search-test-with (&rest body)
  "Load the state layer, the board and its search with the demo provider.
Run BODY with `board' open, with review off unless BODY turns it on."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks
                          tasks-search acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (setq harness-tasks--loaded t
           harness-acp--clients nil
           harness-ui-tasks-search-test--replies '("{\"show\":[],\"do\":[]}")
           harness-ui-tasks-search-test--requests nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-ui-tasks-search-test--script)
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification nil)
           (harness-tasks-worktrees nil)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-search-model 'auto)
           ;; Full width: the banner checks below are not about narrow boards.
           (harness-ui-default-position 'full)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ;; The UI modules load once the client list is clear, so their
       ;; connection is the one the harness events reach.
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-tasks)
       (harness-test-load-module 'ui-tasks-search)
       (clrhash harness-ui--sessions)
       (let ((board (harness-tasks dir)))
         (unwind-protect
             (progn
               (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                                  5 "the board to load")
               ,@body)
           (harness-ui-tasks-search--shutdown)
           (kill-buffer board)
           (dolist (c (copy-sequence harness-acp--clients))
             (harness-acp--drop-client c)))))))

;;;; Helpers

(defun harness-ui-tasks-search-test--board-text (board)
  "The board region of BOARD as plain text."
  (with-current-buffer board
    (buffer-substring-no-properties (point-min) harness-ui-tasks--list-end)))

(defun harness-ui-tasks-search-test--wait (board pred message)
  "Wait until PRED holds in BOARD or fail after 5 seconds, saying MESSAGE."
  (harness-test-wait (lambda () (with-current-buffer board (funcall pred))) 5 message))

(defun harness-ui-tasks-search-test--wait-text (board regexp)
  "Wait until BOARD's board region matches REGEXP."
  (harness-ui-tasks-search-test--wait
   board (lambda () (string-match-p regexp (harness-ui-tasks-search-test--board-text board)))
   (format "the board to show %s" regexp)))

(defun harness-ui-tasks-search-test--state (board)
  "The search of BOARD, or nil."
  (buffer-local-value 'harness-ui-tasks-search--state board))

(defun harness-ui-tasks-search-test--wait-status (board status)
  "Wait until BOARD's search has STATUS."
  (harness-ui-tasks-search-test--wait
   board (lambda () (eq status (plist-get (harness-ui-tasks-search-test--state board) :status)))
   (format "the search to be %s" status)))

(defun harness-ui-tasks-search-test--wait-done (board id)
  "Wait until task ID has finished: done, or waiting in review for BOARD.
With review on, a task that finished waits there instead of completing."
  (let ((finished-p (lambda (task)
                      (member (format "%s" (plist-get task :state)) '("done" "review")))))
    (harness-test-wait (lambda () (funcall finished-p (harness-call 'task/get id)))
                       5 (format "task %s to finish" id))
    (harness-test-wait (lambda () (with-current-buffer board
                                    (let ((task (harness-ui-tasks--find id)))
                                      (and task (funcall finished-p task)))))
                       5 (format "task %s to show as done" id))))

(defun harness-ui-tasks-search-test--submit (board text)
  "Submit TEXT from BOARD's compose box; wait for its card and return its id."
  (with-current-buffer board
    (goto-char harness-compose-end)
    (insert text)
    (harness-ui-tasks-submit))
  ;; The card first shows while submitting; wait until the task itself is there.
  (harness-test-wait
   (lambda () (with-current-buffer board
                (cl-find text harness-ui-tasks--tasks
                         :key #'harness-ui-tasks--title :test #'equal)))
   5 (format "the task %S to arrive" text))
  (let ((id (harness-ui-tasks-search-test--id board text)))
    (should id)
    (harness-ui-tasks-search-test--wait-done board id)
    id))

(defun harness-ui-tasks-search-test--id (board title)
  "The id of the task TITLE on BOARD."
  (with-current-buffer board
    (plist-get (cl-find title harness-ui-tasks--tasks
                        :key (lambda (task) (harness-ui-tasks--title task)) :test #'equal)
               :id)))

(defun harness-ui-tasks-search-test--search (board query)
  "Search BOARD for QUERY, as / does, and wait for the answer."
  (with-current-buffer board (harness-tasks-search query)))

(defun harness-ui-tasks-search-test--last-user-text (request)
  "The text of the last user message of REQUEST."
  (let* ((messages (plist-get request :messages))
         (last (car (last messages))))
    (mapconcat (lambda (block) (or (plist-get block :text) ""))
               (plist-get last :content) "")))

;;;; Tests

(ert-deftest harness-ui-tasks-search-filters-the-board ()
  "A question filters the board to the tasks it is about."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (harness-ui-tasks-search-test--submit board "Write the docs")
    (let ((id (harness-ui-tasks-search-test--id board "Fix the flaky test")))
      (setq harness-ui-tasks-search-test--replies
            (list (format "{\"show\":[\"%s\"],\"do\":[]}" id)))
      (harness-ui-tasks-search-test--search board "did I have a task about the flaky test?")
      (harness-ui-tasks-search-test--wait-status board 'done)
      (let ((text (harness-ui-tasks-search-test--board-text board)))
        (should (string-match-p "Fix the flaky test" text))
        (should-not (string-match-p "Write the docs" text))
        (should (string-match-p "1 task" text)))
      (with-current-buffer board
        (should (plist-get harness-ui-tasks-filter :show))
        (should (plist-get harness-ui-tasks-filter :banner))
        (should (plist-get harness-ui-tasks-filter :clear))
        (should (equal (list id) (plist-get harness-ui-tasks-search--state :ids)))
        (should (string-match-p "did I have a task about the flaky test"
                                (harness-ui-tasks-search--banner))))
      ;; The line goes with the board to the model.
      (should (string-match-p
               "did I have a task about the flaky test"
               (harness-ui-tasks-search-test--last-user-text
                (car harness-ui-tasks-search-test--requests))))
      ;; And so does every task on it.
      (should (string-match-p "Write the docs"
                              (harness-ui-tasks-search-test--last-user-text
                               (car harness-ui-tasks-search-test--requests)))))))

(ert-deftest harness-ui-tasks-search-archives-and-undoes ()
  "An order that can be undone runs at once, and [Undo] puts it back."
  (harness-ui-tasks-search-test-with
    (let ((id (harness-ui-tasks-search-test--submit board "Old work to remove")))
      (setq harness-ui-tasks-search-test--replies
            (list (format "{\"show\":[\"%s\"],\"do\":[{\"task\":\"%s\",\"action\":\"archive\"}]}"
                          id id)))
      (harness-ui-tasks-search-test--search board "get rid of the old work task")
      (harness-ui-tasks-search-test--wait-text board "Archived")
      (should (harness-json-true-p (plist-get (harness-call 'task/get id) :archived)))
      ;; The card stays shown, marked archived, so the undo is visible.
      (should (string-match-p "archived" (harness-ui-tasks-search-test--board-text board)))
      (with-current-buffer board
        (should (plist-get harness-ui-tasks-search--state :undo))
        (should (string-match-p "\\[Undo\\]" (harness-ui-tasks-search--banner)))
        (call-interactively #'harness-ui-tasks-search-undo))
      (harness-ui-tasks-search-test--wait-text board "Restored")
      (should-not (harness-json-true-p (plist-get (harness-call 'task/get id) :archived)))
      ;; The undo is undoable too: [Undo] now archives it again.
      (should (equal (list (list :task id :action "archive"))
                     (plist-get (harness-ui-tasks-search-test--state board) :undo))))))

(ert-deftest harness-ui-tasks-search-sets-priorities-and-undoes ()
  "A new priority runs at once and reorders the waiting tasks; the banner
names it, and [Undo] gives each task the priority it had."
  (harness-ui-tasks-search-test-with
    (let* ((harness-tasks-max-running 0)
           (docs (plist-get (harness-call 'task/submit dir "Write the docs") :id))
           (bug (plist-get (harness-call 'task/submit dir "Fix the login bug") :id))
           (results (lambda () (plist-get (harness-ui-tasks-search-test--state board) :results)))
           (said (lambda () (and (funcall results)
                                 (substring-no-properties
                                  (harness-ui-tasks-search--done-text (funcall results)))))))
      (harness-ui-tasks-search-test--wait-text board "Fix the login bug")
      ;; Oldest first, while they are all medium.
      (let ((text (harness-ui-tasks-search-test--board-text board)))
        (should (< (string-search "Write the docs" text) (string-search "Fix the login bug" text))))
      (setq harness-ui-tasks-search-test--replies
            (list (harness-json-encode-text
                   (list :show (list bug docs)
                         :do (list (list :task bug :action "priority" :text "high")
                                   (list :task docs :action "priority" :text "low"))))))
      (harness-ui-tasks-search-test--search board "the login bug first, the docs last")
      (harness-ui-tasks-search-test--wait board results "the priorities to change")
      (should (equal "Made “Fix the login bug” high priority; Made “Write the docs” low priority"
                     (funcall said)))
      (should (eq 'high (plist-get (harness-call 'task/get bug) :priority)))
      (should (eq 'low (plist-get (harness-call 'task/get docs) :priority)))
      ;; The high one waits first now.
      (harness-ui-tasks-search-test--wait
       board (lambda () (let ((text (harness-ui-tasks-search-test--board-text board)))
                          (< (string-search "Fix the login bug" text) (string-search "Write the docs" text))))
       "the login bug to wait first")
      (with-current-buffer board
        (should (string-match-p "\\[Undo\\]" (harness-ui-tasks-search--banner)))
        (call-interactively #'harness-ui-tasks-search-undo))
      ;; Both go back to medium, so the banner says it once.
      (harness-ui-tasks-search-test--wait
       board (lambda () (equal "Made “Fix the login bug” and “Write the docs” medium priority"
                               (funcall said)))
       "the undo")
      (should (eq 'medium (plist-get (harness-call 'task/get bug) :priority)))
      (should (eq 'medium (plist-get (harness-call 'task/get docs) :priority))))))

(ert-deftest harness-ui-tasks-search-proposes-what-needs-an-ok ()
  "Verifying is offered, not done, until you say yes."
  (harness-ui-tasks-search-test-with
    (let ((harness-tasks-require-verification t)
          (id nil))
      (setq id (harness-ui-tasks-search-test--submit board "Fix the flaky test"))
      (harness-ui-tasks-search-test--wait-text board "Ready for review")
      (setq harness-ui-tasks-search-test--replies
            (list (format "{\"show\":[\"%s\"],\"do\":[{\"task\":\"%s\",\"action\":\"verify\"}]}" id id)))
      (harness-ui-tasks-search-test--search board "ship the flaky fix")
      (harness-ui-tasks-search-test--wait-text board "Verify .*Fix the flaky test")
      (with-current-buffer board
        (should (plist-get harness-ui-tasks-search--state :proposed))
        (should (string-match-p "\\[Verify\\]" (harness-ui-tasks-search--banner)))
        (should (string-match-p "\\[Skip\\]" (harness-ui-tasks-search--banner))))
      ;; Nothing happened yet.
      (should-not (plist-get (harness-call 'task/get id) :verified))
      (with-current-buffer board (call-interactively #'harness-ui-tasks-search-confirm))
      (harness-ui-tasks-search-test--wait-text board "Verified")
      (should (plist-get (harness-call 'task/get id) :verified))
      (should-not (plist-get (harness-ui-tasks-search-test--state board) :proposed)))))

(ert-deftest harness-ui-tasks-search-empty-line-does-what-is-proposed ()
  "The prompt names the proposal, and RET on an empty line runs it."
  (harness-ui-tasks-search-test-with
    (let ((id (harness-ui-tasks-search-test--submit board "Old work to remove")))
      (with-current-buffer board
        (setq harness-ui-tasks-search--state
              (list :query "remove the old work" :seq 1 :status 'done :ids (list id)
                    :proposed (list (list :task id :action "archive" :title "Old work to remove"
                                          :confirm t))))
        (harness-ui-tasks-search--install)
        (let ((prompt nil))
          (cl-letf (((symbol-function 'read-string)
                     (lambda (p &rest _) (setq prompt p) "")))
            (should (equal "" (harness-ui-tasks-search--read))))
          (should (string-match-p "RET: stop and archive" prompt)))
        ;; An empty line does the proposal.
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  ")))
          (call-interactively #'harness-tasks-search))
        (harness-test-wait (lambda () (harness-json-true-p (plist-get (harness-call 'task/get id) :archived)))
                           5 "the proposal to run")
        (harness-ui-tasks-search-test--wait-text board "Archived")))))

(ert-deftest harness-ui-tasks-search-c-g-shows-every-task-again ()
  "C-g on the board drops the search and its filter."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (harness-ui-tasks-search-test--submit board "Write the docs")
    (let ((id (harness-ui-tasks-search-test--id board "Fix the flaky test")))
      (setq harness-ui-tasks-search-test--replies
            (list (format "{\"show\":[\"%s\"],\"do\":[]}" id)))
      (harness-ui-tasks-search-test--search board "flaky")
      (harness-ui-tasks-search-test--wait-status board 'done)
      (harness-ui-tasks-search-test--wait-text board "\\[Clear\\]")
      (with-current-buffer board
        (should harness-ui-tasks-filter)
        (harness-ui-tasks-compose-quit)
        (should-not harness-ui-tasks-filter)
        (should-not harness-ui-tasks-search--state)
        (let ((text (harness-ui-tasks-search-test--board-text board)))
          (should-not (string-match-p "\\[Clear\\]" text))
          (should (string-match-p "Fix the flaky test" text))
          (should (string-match-p "Write the docs" text))
          (should (string-match-p "\\[Search\\]" (harness-ui-tasks--header))))))))

(ert-deftest harness-ui-tasks-search-failure-offers-retry ()
  "A model that answers nothing useful says so, and can be asked again."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (setq harness-ui-tasks-search-test--replies
          '("I am afraid I cannot do that." "{\"show\":[],\"do\":[]}"))
    (harness-ui-tasks-search-test--search board "what is up?")
    (harness-ui-tasks-search-test--wait-status board 'failed)
    (with-current-buffer board
      (should (string-match-p "the search failed" (harness-ui-tasks-search--banner)))
      (should (string-match-p "\\[Retry\\]" (harness-ui-tasks-search--banner)))
      (call-interactively #'harness-ui-tasks-search-retry))
    (harness-ui-tasks-search-test--wait-status board 'done)
    (should (string-match-p "no task matches" (harness-ui-tasks-search-test--board-text board)))))

(ert-deftest harness-ui-tasks-search-header-spins-while-asking ()
  "The header's [Search] carries a spinner while the model works."
  (harness-ui-tasks-search-test-with
    (with-current-buffer board
      (setq harness-ui-tasks-search--state
            (list :query "restart the errored tasks" :seq 1 :status 'searching :ids 'all))
      (harness-ui-tasks-search--install)
      (should (string-match-p "asking" (harness-ui-tasks-search--banner)))
      (should (string-match-p "\\[Cancel\\]" (harness-ui-tasks-search--banner)))
      (should (string-match-p "[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] \\[Search\\]"
                              (harness-ui-tasks--header)))
      (harness-ui-tasks-search-clear)
      (should-not harness-ui-tasks-filter)
      (should (string-match-p "\\[Search\\]" (harness-ui-tasks--header))))))

(ert-deftest harness-ui-tasks-search-slash-reads-the-line-and-searches ()
  "/ on the board reads a line in the minibuffer and searches for it."
  (harness-ui-tasks-search-test-with
    (let ((id (harness-ui-tasks-search-test--submit board "Fix the flaky test"))
          (prompt nil))
      (setq harness-ui-tasks-search-test--replies
            (list (format "{\"show\":[\"%s\"],\"do\":[]}" id)))
      (with-current-buffer board
        (goto-char (point-min))
        (search-forward "Fix the flaky test")
        (should (eq (key-binding (kbd "/")) #'harness-ui-tasks-search))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (p &rest _) (setq prompt p) "flaky test")))
          (call-interactively (key-binding (kbd "/")))))
      (should (equal "Find or act on tasks: " prompt))
      (harness-ui-tasks-search-test--wait-status board 'done)
      (should (equal "flaky test" (plist-get (harness-ui-tasks-search-test--state board) :query)))
      (should (string-match-p "1 task" (harness-ui-tasks-search-test--board-text board))))))

(ert-deftest harness-ui-tasks-search-asks-with-the-board-dump ()
  "The model reads every task: its id, where it stands, its words."
  (harness-ui-tasks-search-test-with
    (let ((id (harness-ui-tasks-search-test--submit board "Fix the flaky test")))
      (setq harness-ui-tasks-search-test--replies
            (list (format "{\"show\":[\"%s\"],\"do\":[]}" id)))
      (harness-ui-tasks-search-test--search board "flaky")
      (harness-ui-tasks-search-test--wait-status board 'done)
      (let ((text (harness-ui-tasks-search-test--last-user-text
                   (car harness-ui-tasks-search-test--requests))))
        (should (string-match-p (regexp-quote id) text))
        (should (string-match-p "Fix the flaky test" text))
        (should (string-match-p "Query: flaky" text))))))
