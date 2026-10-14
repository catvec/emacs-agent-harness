;;; harness-ui-tasks-search-test.el --- Tests for the board's search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the board's smart search against the real state layer, the
;; in-process ACP connection and the demo provider: / turns the compose
;; box into a search box, whose line goes to the model favouring tasks,
;; with the harness's commands; the box gets back what it held after; the
;; board filters to what it answers, the banner says what is shown, the
;; sessions and commands found and what was done, an order runs at once
;; with [Undo], a proposal waits for an OK, a failure offers [Retry] and
;; C-g shows every task again.

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
(defvar harness-ui-tasks--target)
(defvar harness-ui-map)
(defvar harness-compose-attachments)
(defvar harness-compose--placeholder)
(defvar harness-quick-search-history)
(defvar harness-quick-search-box-mode)
(defvar harness-quick-search-box-function)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-tasks--header "harness-ui-tasks")
(declare-function harness-ui-tasks--title "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
(declare-function harness-ui-tasks--searching-p "harness-ui-tasks")
(declare-function harness-ui-tasks-compose-quit "harness-ui-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks-search "harness-ui-tasks")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-in-p "harness-ui-compose")
(declare-function harness-compose-add-attachment "harness-ui-compose")
(declare-function harness-ui-level-icon "harness-ui")
(declare-function harness-quick-search "harness-ui-quick-search")
(declare-function harness-quick-search-box-submit "harness-ui-quick-search")
(declare-function harness-quick-search--reset-scan "harness-ui-quick-search")
(declare-function harness-ui-visit-session "harness-ui")
(declare-function harness-ui-chat-goto-node "harness-ui-chat")
(declare-function harness-ui-tasks-search--banner "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--done-text "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--found-text "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--install "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search--shutdown "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-submit "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-show-plan "harness-ui-tasks-search")
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
The priority plugin is in there too: a task's priority is its session's,
so the search's priority action goes through `priority/set'; and the
quick search, whose box keys and lines the board's search takes.  Run
BODY with `board' open, with review off unless BODY turns it on, and
an empty history of searches."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent priority tasks
                          session-search tasks-search acp))
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
           (harness-quick-search-history nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ;; The UI modules load once the client list is clear, so their
       ;; connection is the one the harness events reach.
       (dolist (m '(ui ui-compose ui-popout ui-tasks ui-search ui-quick-search ui-tasks-search))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (let ((board (harness-tasks dir)))
         (unwind-protect
             (progn
               (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                                  5 "the board to load")
               ,@body)
           ;; No scan of the commands, and no idle job to build one, is left
           ;; for the next test.
           (harness-quick-search--reset-scan)
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

(defun harness-ui-tasks-search-test--label (board)
  "What BOARD shows above its compose box, the box's label among it."
  (with-current-buffer board
    (buffer-substring-no-properties harness-ui-tasks--list-end harness-compose-start)))

(defun harness-ui-tasks-search-test--placeholder (board)
  "The placeholder BOARD's empty compose box shows, or nil."
  (with-current-buffer board
    (let ((text (overlay-get harness-compose--placeholder 'before-string)))
      (and text (substring-no-properties text)))))

(defun harness-ui-tasks-search-test--push (board label)
  "Push the button LABEL in BOARD's board region, the first there is."
  (with-current-buffer board
    (goto-char (point-min))
    (should (search-forward label harness-ui-tasks--list-end t))
    (push-button (match-beginning 0))))

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

(ert-deftest harness-ui-tasks-search-empty-box-does-what-is-proposed ()
  "The search box's placeholder names the proposal, and RET on the empty
box runs it; with nothing proposed, the search box stays and says what
it takes."
  (harness-ui-tasks-search-test-with
    (let ((id (harness-ui-tasks-search-test--submit board "Old work to remove")))
      (with-current-buffer board
        ;; Nothing proposed: an empty RET searches nothing.
        (call-interactively #'harness-ui-tasks-search)
        (should-not (string-match-p "RET:" (harness-ui-tasks-search-test--placeholder board)))
        (call-interactively (key-binding (kbd "RET")))
        (should (harness-ui-tasks--searching-p))
        (should-not harness-ui-tasks-search--state)
        (should-not harness-ui-tasks-search-test--requests)
        ;; A proposal arrives while the search box is open: the
        ;; placeholder names it at once.
        (setq harness-ui-tasks-search--state
              (list :query "remove the old work" :seq 1 :status 'done :ids (list id)
                    :proposed (list (list :task id :action "archive" :title "Old work to remove"
                                          :confirm t))))
        (harness-ui-tasks-search--install)
        (should (string-match-p "RET: stop and archive “Old work to remove”"
                                (harness-ui-tasks-search-test--placeholder board)))
        ;; Blanks are an empty box: RET does the proposal, and the box
        ;; is a task's again.
        (insert "  ")
        (call-interactively (key-binding (kbd "RET")))
        (should-not (harness-ui-tasks--searching-p))
        (should-not harness-ui-tasks--target))
      (harness-test-wait (lambda () (harness-json-true-p (plist-get (harness-call 'task/get id) :archived)))
                         5 "the proposal to run")
      (harness-ui-tasks-search-test--wait-text board "Archived")
      ;; It ran without asking the model.
      (should-not harness-ui-tasks-search-test--requests))))

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
  "A model whose answer does not parse says so, and can be asked again."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (setq harness-ui-tasks-search-test--replies
          '("{\"show\":[\"t-" "{\"show\":[],\"do\":[]}"))
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

(ert-deftest harness-ui-tasks-search-slash-opens-the-search-box ()
  "/ on the board turns the compose box into a search box, whose RET
searches; the box gets back what it held, and point goes to the best
match.  / under the harness prefix stays the quick search's."
  (harness-ui-tasks-search-test-with
    (let ((id (harness-ui-tasks-search-test--submit board "Fix the flaky test")))
      (setq harness-ui-tasks-search-test--replies
            (list (format "{\"show\":[\"%s\"],\"do\":[]}" id)))
      (should (eq (lookup-key harness-ui-map (kbd "/")) #'harness-quick-search))
      (with-current-buffer board
        ;; A task half described, point back on a card.
        (goto-char harness-compose-end)
        (insert "Half a task")
        (goto-char (point-min))
        (search-forward "Fix the flaky test")
        (should (eq (key-binding (kbd "/")) #'harness-ui-tasks-search))
        (call-interactively (key-binding (kbd "/")))
        ;; A search box: empty, point in it, its own label and placeholder.
        (should (equal '(search) harness-ui-tasks--target))
        (should harness-quick-search-box-mode)
        (should (eq harness-quick-search-box-function #'harness-ui-tasks-search-submit))
        (should (harness-compose-in-p))
        (should (equal "" (harness-compose-text)))
        (should (string-match-p "Search tasks, sessions and commands" (harness-ui-tasks-search-test--label board)))
        (should (string-match-p "Search, or say what to do"
                                (harness-ui-tasks-search-test--placeholder board)))
        ;; RET in the box searches the line.
        (insert "flaky test")
        (should (eq (key-binding (kbd "RET")) #'harness-quick-search-box-submit))
        (call-interactively (key-binding (kbd "RET")))
        ;; The box is a task's again, and holds what it held.
        (should-not harness-ui-tasks--target)
        (should-not harness-quick-search-box-mode)
        (should (equal "Half a task" (harness-compose-text)))
        (should-not (string-match-p "Search tasks" (harness-ui-tasks-search-test--label board))))
      (harness-ui-tasks-search-test--wait-status board 'done)
      (should (equal "flaky test" (plist-get (harness-ui-tasks-search-test--state board) :query)))
      (should (string-match-p "1 task" (harness-ui-tasks-search-test--board-text board)))
      ;; The line is in the searches' history, the quick search's too.
      (should (equal '("flaky test") harness-quick-search-history))
      (with-current-buffer board
        ;; Point was on the board: it is on the best match.
        (should (equal id (get-text-property (point) 'harness-task-id)))
        ;; M-p in the search box brings the line back.
        (call-interactively #'harness-ui-tasks-search)
        (should (eq (key-binding (kbd "M-p")) #'harness-quick-search-box-previous))
        (call-interactively (key-binding (kbd "M-p")))
        (should (equal "flaky test" (harness-compose-text)))
        (harness-ui-tasks-compose-quit)
        (should (equal "Half a task" (harness-compose-text)))))))

(ert-deftest harness-ui-tasks-search-c-g-closes-the-search-box ()
  "C-g in the search box closes it, searching nothing: the box gets back
its text and attachments, and point the card it was on.  A message
being written stays a message."
  (harness-ui-tasks-search-test-with
    (let ((id (harness-ui-tasks-search-test--submit board "Fix the flaky test"))
          (file (expand-file-name "notes.txt" dir)))
      (with-temp-file file (insert "notes\n"))
      (with-current-buffer board
        (goto-char harness-compose-end)
        (insert "Half a task")
        (harness-compose-add-attachment file)
        (should (= 1 (length harness-compose-attachments)))
        ;; From the box: point stays there.
        (call-interactively #'harness-ui-tasks-search)
        (should (harness-ui-tasks--searching-p))
        (should-not harness-compose-attachments)
        (insert "something to find")
        (let ((said nil))
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (setq said (apply #'format-message fmt args)))))
            (harness-ui-tasks-compose-quit))
          (should (equal "Search closed" said)))
        (should-not (harness-ui-tasks--searching-p))
        (should-not harness-quick-search-box-mode)
        (should-not harness-ui-tasks--target)
        (should (equal "Half a task" (harness-compose-text)))
        (should (= 1 (length harness-compose-attachments)))
        (should (harness-compose-in-p))
        ;; From a card: point goes back to it.
        (goto-char (point-min))
        (search-forward "Fix the flaky test")
        (call-interactively (key-binding (kbd "/")))
        (should (harness-compose-in-p))
        (harness-ui-tasks-compose-quit)
        (should (equal id (get-text-property (point) 'harness-task-id)))
        (should (equal "Half a task" (harness-compose-text)))
        ;; A message to the task's session, half written, stays one.
        (harness-ui-tasks-compose-reset)
        (goto-char (point-min))
        (search-forward "Fix the flaky test")
        (call-interactively (key-binding (kbd "m")))
        (should (equal (cons 'reply id) harness-ui-tasks--target))
        (insert "also check the login test")
        (call-interactively #'harness-ui-tasks-search)
        (should (harness-ui-tasks--searching-p))
        (harness-ui-tasks-compose-quit)
        (should (equal (cons 'reply id) harness-ui-tasks--target))
        (should (equal "also check the login test" (harness-compose-text)))))
    (should-not harness-ui-tasks-search-test--requests)))

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

(ert-deftest harness-ui-tasks-search-asks-favouring-tasks-with-the-commands ()
  "The board's search is the harness's own search favouring tasks: the
model reads that it was typed on the board, and the commands its words
match, from the board's catalogue."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (harness-ui-tasks-search-test--search board "archive the completed tasks")
    (harness-ui-tasks-search-test--wait-status board 'done)
    (let ((text (harness-ui-tasks-search-test--last-user-text (car harness-ui-tasks-search-test--requests))))
      (should (string-match-p "^Context: the task board of project .*\\. Favour tasks; sessions and commands count too\\.$"
                              text))
      (should (string-match-p "^Commands (name | keys | where | what it does):$" text))
      (should (string-match-p "^harness-ui-tasks-archive-done | .*Archive completed" text))
      (should (string-match-p "Query: archive the completed tasks" text)))))

(ert-deftest harness-ui-tasks-search-banner-shows-sessions-and-commands ()
  "What the search found besides tasks shows in the banner, counted on
its first line, under the model's note: each session with [Open], each
command with [Run] where it runs; their buttons open and run them from
the board."
  (harness-ui-tasks-search-test-with
    (let* ((id (harness-ui-tasks-search-test--submit board "Fix the flaky test"))
           (session (plist-get (harness-call 'task/get id) :session))
           (opened nil)
           (ran nil))
      (should session)
      (setq harness-ui-tasks-search-test--replies
            (list (harness-json-encode-text
                   (list :show (list id) :sessions (list session)
                         :commands (list "harness-ui-tasks-archive-done")
                         :note "Its session talks of it too."))))
      (harness-ui-tasks-search-test--search board "the flaky test, and how to clear the done ones")
      (harness-ui-tasks-search-test--wait-status board 'done)
      (let ((state (harness-ui-tasks-search-test--state board))
            (text (harness-ui-tasks-search-test--board-text board)))
        (should (equal (list id) (plist-get state :ids)))
        (should (equal (list session) (mapcar (lambda (s) (plist-get s :id)) (plist-get state :sessions))))
        (should (equal '("harness-ui-tasks-archive-done")
                       (mapcar (lambda (c) (plist-get c :command)) (plist-get state :commands))))
        (should-not (plist-get state :widened))
        (should (string-match-p "1 task · 1 session · 1 command" text))
        (should (string-match-p "Its session talks of it too\\." text))
        (should (string-match-p "\\[Open\\]" text))
        (should (string-match-p "Archive completed.*\\[Run\\] \\[Describe\\]" text)))
      ;; [Open] opens the session, [Run] runs the command on the board.
      (cl-letf (((symbol-function 'harness-ui-visit-session) (lambda (sid &rest _) (setq opened sid)))
                ((symbol-function 'harness-ui-tasks-archive-done)
                 (lambda () (interactive) (setq ran (current-buffer)))))
        (harness-ui-tasks-search-test--push board "[Open]")
        (harness-ui-tasks-search-test--push board "[Run]"))
      (should (equal session opened))
      (should (eq board ran)))))

(ert-deftest harness-ui-tasks-search-banner-open-goes-to-the-match ()
  "[Open] in the banner opens a session where the search found its words:
at that node, the words found to be highlighted there.  A session named
without a match in it opens as it is."
  (harness-ui-tasks-search-test-with
    (let* ((other (plist-get (harness-call 'session/create :cwd default-directory
                                           :name "Debug the merge queue")
                             :id))
           (plain (plist-get (harness-call 'session/create :cwd default-directory
                                           :name "Write the release notes")
                             :id))
           (node (plist-get (harness-call 'session/append other
                                          (list :kind 'user :content "Why did the merge queue drop a commit?"))
                            :id))
           (visited nil)
           (went nil))
      ;; The model searched every session's transcript, and named both.
      (setq harness-ui-tasks-search-test--replies
            (list "{\"sessions\":\"merge queue\"}"
                  (harness-json-encode-text (list :show nil :sessions (list other plain)))))
      (harness-ui-tasks-search-test--search board "the merge queue")
      (harness-ui-tasks-search-test--wait-status board 'done)
      (let ((sessions (plist-get (harness-ui-tasks-search-test--state board) :sessions)))
        (should (equal (list other plain) (mapcar (lambda (s) (plist-get s :id)) sessions)))
        (should (equal node (plist-get (car sessions) :node)))
        (should-not (plist-get (cadr sessions) :node)))
      (cl-letf (((symbol-function 'harness-ui-visit-session)
                 (lambda (sid &rest _) (push sid visited) nil))
                ((symbol-function 'harness-ui-chat-goto-node)
                 (lambda (&rest args) (push args went) nil)))
        (harness-ui-tasks-search-test--push board "[Open]")
        (should (equal (list other) visited))
        (pcase-let ((`((,goto-node ,goto-session ,regexp)) went))
          (should (equal node goto-node))
          (should (equal other goto-session))
          (should (string-match-p regexp "Merge"))
          (should (string-match-p regexp "queue"))
          (should-not (string-match-p regexp "commit")))
        ;; The second session's [Open], which had no match to go to.
        (with-current-buffer board
          (goto-char (point-min))
          (should (search-forward "[Open]" harness-ui-tasks--list-end t))
          (should (search-forward "[Open]" harness-ui-tasks--list-end t))
          (push-button (match-beginning 0)))
        (should (equal (list plain other) visited))
        (should (= 1 (length went)))))))

(ert-deftest harness-ui-tasks-search-widened-answer-says-so ()
  "A search that matches nothing, even looking wider, says so in the
banner, with the caution icon, and that no task matches; the board then
shows no task."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (setq harness-ui-tasks-search-test--replies '("{\"show\":[],\"sessions\":[],\"commands\":[],\"do\":[]}"))
    (harness-ui-tasks-search-test--search board "zxqv blorp")
    (harness-ui-tasks-search-test--wait-status board 'done)
    (let ((state (harness-ui-tasks-search-test--state board))
          (text (harness-ui-tasks-search-test--board-text board)))
      (should (eq t (plist-get state :widened)))
      (should (equal "Nothing matched: no task, session or command." (plist-get state :note)))
      (should (string-match-p "“zxqv blorp”  ·  no task matches" text))
      (should (string-match-p "Nothing matched: no task, session or command\\." text))
      (should-not (string-match-p "Fix the flaky test" text))
      ;; The note says it looked wider: the caution icon leads it.
      (should (string-match-p (regexp-quote (concat (substring-no-properties (harness-ui-level-icon 'caution))
                                                    " Nothing matched"))
                              text)))))

(ert-deftest harness-ui-tasks-search-show-plan-shows-what-was-found ()
  "A plan from elsewhere -- the quick search's [Board] -- shows on the
board as its search would: its tasks under a banner, nothing proposed."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (harness-ui-tasks-search-test--submit board "Write the docs")
    (let ((id (harness-ui-tasks-search-test--id board "Write the docs")))
      (with-current-buffer board
        (harness-ui-tasks-search-show-plan (list :ids (list id) :query "the docs"))
        (let ((state harness-ui-tasks-search--state)
              (text (harness-ui-tasks-search-test--board-text board)))
          (should (eq 'done (plist-get state :status)))
          (should (equal (list id) (plist-get state :ids)))
          (should-not (plist-get state :proposed))
          (should (string-match-p "“the docs”  ·  1 task" text))
          (should (string-match-p "Write the docs" text))
          (should-not (string-match-p "Fix the flaky test" text))
          (should (equal id (get-text-property (point) 'harness-task-id))))))
    (should-not harness-ui-tasks-search-test--requests)))

(ert-deftest harness-ui-tasks-search-banner-shows-the-answer-whole ()
  "A search that answers in words has the answer in the banner, under the
line it answers: whole however long, every line of it indented, and
rendered as Markdown.  That line, and the echo area, say it answered
rather than that no task matches.  A plan from the quick search's
[Board] that answers shows its answer too."
  (harness-ui-tasks-search-test-with
    (harness-ui-tasks-search-test--submit board "Fix the flaky test")
    (let* ((steps (mapcar (lambda (n)
                            (format "Step %d of the answer, which says more than fits on one line of the board, so that it has to wrap at least once." n))
                          (number-sequence 1 10)))
           (answer (concat "A task that failed shows in the **Failed** column; press `r` on its card to retry it.\n\n"
                           (mapconcat (lambda (step) (format "%d. %s" (1+ (cl-position step steps)) step))
                                      steps "\n")
                           "\n\nThe last line of the answer.")))
      (setq harness-ui-tasks-search-test--replies (list (harness-json-encode-text (list :show nil :answer answer))))
      (harness-ui-tasks-search-test--search board "how do I retry a failed task?")
      (harness-ui-tasks-search-test--wait-status board 'done)
      (let ((state (harness-ui-tasks-search-test--state board))
            (text (harness-ui-tasks-search-test--board-text board)))
        (should (equal answer (plist-get state :answer)))
        ;; An answer in words is something found: the search did not look wider.
        (should-not (plist-get state :widened))
        (should (string-match-p "“how do I retry a failed task\\?”  ·  answered" text))
        (should-not (string-match-p "no task matches" text))
        ;; Every line of it, whole, as Markdown: no ** nor backquotes.
        (should (string-search "A task that failed shows in the Failed column; press r on its card to retry it." text))
        (dolist (step steps)
          (should (string-search step text)))
        (should (string-search "The last line of the answer." text))
        (should-not (string-search "…" text))
        (should (< (string-search "answered" text) (string-search "A task that failed" text)
                   (string-search "The last line of the answer." text))))
      (with-current-buffer board
        (goto-char (point-min))
        (should (search-forward "The last line of the answer." harness-ui-tasks--list-end t))
        (should (get-text-property (match-beginning 0) 'harness-quick-search-answer))
        (should (equal "    " (get-text-property (match-beginning 0) 'line-prefix)))
        ;; A step wraps under its own text, past its number.
        (should (search-backward "Step 10 of the answer" nil t))
        (should (equal "    " (get-text-property (point) 'line-prefix)))
        (should (equal "        " (get-text-property (point) 'wrap-prefix)))
        (should (eq 'bold (progn (goto-char (point-min))
                                 (search-forward "Failed column" harness-ui-tasks--list-end)
                                 (get-text-property (match-beginning 0) 'face))))))
    ;; What the echo area says of an answer.
    (should (equal "Answered" (harness-ui-tasks-search--found-text (list :query "q" :answer "Press `r`."))))
    (should (equal "Answered · 1 task matches"
                   (harness-ui-tasks-search--found-text (list :query "q" :ids '("a") :answer "Press `r`."))))
    (should (equal "No task matches “q”" (harness-ui-tasks-search--found-text (list :query "q" :answer " \n"))))
    ;; A plan from the quick search shows its answer too.
    (with-current-buffer board
      (harness-ui-tasks-search-show-plan (list :ids nil :query "how?" :answer "Press `r` on its card."))
      (should (equal "Press `r` on its card." (plist-get harness-ui-tasks-search--state :answer))))
    (let ((text (harness-ui-tasks-search-test--board-text board)))
      (should (string-match-p "“how\\?”  ·  answered" text))
      (should (string-search "Press r on its card." text)))))
