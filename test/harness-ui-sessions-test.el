;;; harness-ui-sessions-test.el --- Tests for the session list  -*- lexical-binding: t; -*-

;;; Commentary:

;; The session list's project scope.  A task's session runs in a linked
;; git worktree under ROOT/.worktrees/ and has that worktree as its
;; `:project'; the list shows it with ROOT, the main checkout, resolved
;; once per root without running git.  Sessions go straight into the UI
;; cache; no harness or connection is needed.
;;
;; The tasks: a task's session is of kind task and shows its task's
;; title until it has a name.  The harness's answer to `_harness/task/list'
;; is `harness-ui-sessions-test--tasks'; events are run as the UI runs them.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)
(require 'harness-ui-sessions)

(defvar harness-ui--sessions)

(defvar harness-ui-sessions-test--tasks nil
  "What the harness answers `_harness/task/list' with: the tasks, or `fail'.")

(defvar harness-ui-sessions-test--requests nil
  "The requests the list sent the harness, newest first: (METHOD PARAMS).")

(defun harness-ui-sessions-test--request (method &optional params)
  "Answer METHOD as the harness would: `_harness/task/list' with the tasks.
An answer to what a session waits on is taken.  Anything else, or the
tasks when they are `fail', fails.  Each request is recorded in
`harness-ui-sessions-test--requests'."
  (push (list method params) harness-ui-sessions-test--requests)
  (cond ((and (equal method "_harness/task/list") (listp harness-ui-sessions-test--tasks))
         (harness-resolved harness-ui-sessions-test--tasks))
        ((member method '("_harness/permission/answer" "_harness/question/answer"))
         (harness-resolved t))
        ((equal method "_harness/session/move")
         (harness-resolved (harness-plist-merge (harness-ui-session (plist-get params :id))
                                                (list :cwd (plist-get params :dir)
                                                      :project (plist-get params :project)))))
        (t (harness-rejected (list 'harness-error (format "%s: no such method" method))))))

(defun harness-ui-sessions-test--answers ()
  "Return the answers the list sent the harness, oldest first: (METHOD PARAMS)."
  (reverse (cl-remove "_harness/task/list" harness-ui-sessions-test--requests
                      :key #'car :test #'equal)))

(defun harness-ui-sessions-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string))))))

(defmacro harness-ui-sessions-test-with-repo (&rest body)
  "Run BODY with a git repository at `root', a linked worktree of it at
`wt' (under ROOT/.worktrees/, where tasks work), an unrelated directory
`other' and an empty session cache.  The list never asks the harness."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (file-truename (harness-test-temp-dir))))
          (root (file-name-as-directory (expand-file-name "repo" base)))
          (wt (file-name-as-directory (expand-file-name ".worktrees/task-x" root)))
          (other (file-name-as-directory (expand-file-name "other" base))))
     (unwind-protect
         (progn
           (make-directory root t)
           (make-directory other t)
           (harness-ui-sessions-test--git root "init" "-q" "-b" "main")
           (harness-ui-sessions-test--git root "config" "user.name" "Harness Test")
           (harness-ui-sessions-test--git root "config" "user.email" "test@example.invalid")
           (harness-ui-sessions-test--git root "config" "commit.gpgsign" "false")
           (harness-ui-sessions-test--git root "commit" "-q" "--allow-empty" "-m" "initial")
           (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/x" wt)
           (clrhash harness-ui--sessions)
           (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                      (lambda (&optional callback) (when callback (funcall callback nil))))
                     ((symbol-function 'harness-ui-request) #'harness-ui-sessions-test--request)
                     ((symbol-function 'harness-ui-display-view) #'ignore))
             (let ((harness-ui-sessions-test--tasks nil)
                   (harness-ui-sessions-test--requests nil))
               ,@body)))
       (clrhash harness-ui--sessions)
       (harness-ui-pending--forget-all)
       (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name))) (kill-buffer buf))
       (ignore-errors (delete-directory base t)))))

(defun harness-ui-sessions-test--add (id project &rest props)
  "Cache a session ID whose project root is PROJECT, as the wire has it.
It is named ID unless PROPS, which go first, say otherwise."
  (puthash id (append props
                      (list :id id :name id :project project :cwd project :status "idle" :kind "main"
                            :model "demo:scripted" :permission-mode "auto" :usage (list :cost 0 :context 0)
                            :context-window 200000 :created (float-time) :updated (float-time)))
           harness-ui--sessions))

(defun harness-ui-sessions-test--shown ()
  "Return the sorted ids the list buffer shows."
  (with-current-buffer harness-ui-sessions--buffer-name
    (sort (mapcar #'car tabulated-list-entries) #'string<)))

(defun harness-ui-sessions-test--row (id)
  "Return (NAME KIND) as the list buffer shows session ID, as plain text."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let ((columns (cadr (assoc id tabulated-list-entries))))
      (list (substring-no-properties (aref columns 1))
            (substring-no-properties (aref columns 3))))))

(defun harness-ui-sessions-test--blocked (id project kind &rest props)
  "Cache a session ID in PROJECT blocked on a request of KIND, as the wire has it.
KIND is \"permission\", for a shell command, or \"question\"; the
request's id is ID-p or ID-q.  PROPS go first."
  (apply #'harness-ui-sessions-test--add id project
         (append props
                 (list :status "blocked"
                       :pending (list (if (equal kind "question")
                                          (list :id (concat id "-q") :kind "question"
                                                :payload (list :question "Which colour?\nThe second line"
                                                               :options '("red" "green")))
                                        (list :id (concat id "-p") :kind "permission"
                                              :payload (list :title "Bash: rm -rf build/" :tool "bash"
                                                             :options '("allow-once" "allow-session"
                                                                        "deny-once")))))))))

(defun harness-ui-sessions-test--text ()
  "Return the text of the list buffer, without properties."
  (with-current-buffer harness-ui-sessions--buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-sessions-test--goto (id)
  "Put point on the row of session ID in the current buffer, the list."
  (goto-char (harness-ui-sessions--position id))
  (should (equal id (tabulated-list-get-id))))

(defun harness-ui-sessions-test--line (id)
  "Return the line under the row of session ID, as plain text, or nil.
Only a line of the session's own: the one saying what it waits on."
  (with-current-buffer harness-ui-sessions--buffer-name
    (save-excursion
      (harness-ui-sessions-test--goto id)
      (forward-line 1)
      (when (and (not (eobp)) (equal id (tabulated-list-get-id)))
        (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

(defmacro harness-ui-sessions-test--with-init (&rest body)
  "Run BODY with the list's module started, its hooks kept to BODY."
  (declare (indent 0))
  `(let ((harness-ui-event-functions nil)
         (harness-ui-redraw-hook nil)
         (harness-ui-sessions-changed-hook nil)
         (harness-ui-pending-changed-hook nil)
         (harness-ui-rate-functions nil)
         (harness-ui-live-functions nil))
     (harness-ui-sessions--init)
     (unwind-protect
         (progn ,@body)
       (when (timerp harness-ui-sessions--live-timer)
         (cancel-timer harness-ui-sessions--live-timer))
       (setq harness-ui-sessions--live-timer nil))))

(ert-deftest harness-ui-sessions-show-token-figures ()
  "The Context and Output columns show each session's token figures.
They sort by the figures.  A running session's grow as its model
streams: the list redraws for them at most every half second, all the
sessions that grew at once, and not at all while they read the same.
They do not drop when the count ends before the session's new totals
arrive."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--live (make-hash-table :test 'equal))
            (redraws 0))
        (harness-ui-sessions-test--add "busy" root :status "running"
                                       :usage (list :cost 0 :context 1000 :last-output 200 :output 300))
        (harness-ui-sessions-test--add "quiet" root :usage (list :cost 0 :context 50000 :output 9000))
        (harness-ui-sessions-test--add "fresh" root)
        (let ((default-directory root)) (harness-sessions))
        (advice-add 'harness-ui-sessions--redraw :before (lambda () (cl-incf redraws))
                    '((name . harness-ui-sessions-test-count)))
        (unwind-protect
            (with-current-buffer harness-ui-sessions--buffer-name
              (let* ((column (lambda (name) (cl-position name tabulated-list-format :key #'car :test #'equal)))
                     (cell (lambda (id name)
                             (substring-no-properties
                              (aref (cadr (assoc id tabulated-list-entries)) (funcall column name)))))
                     (sorted (lambda (name)
                               (mapcar #'car (sort (copy-sequence tabulated-list-entries)
                                                   (nth 2 (aref tabulated-list-format (funcall column name))))))))
                (should (equal "1.2k/200k" (funcall cell "busy" "Context")))
                (should (equal "300" (funcall cell "busy" "Output")))
                (should (equal "50.0k/200k" (funcall cell "quiet" "Context")))
                (should (equal "9.0k" (funcall cell "quiet" "Output")))
                (should (equal "0/200k" (funcall cell "fresh" "Context")))
                (should (equal "" (funcall cell "fresh" "Output")))
                (should (equal '("fresh" "busy" "quiet") (funcall sorted "Context")))
                (should (equal '("fresh" "busy" "quiet") (funcall sorted "Output")))
                ;; The count grows: one redraw, half a second later.
                (harness-ui--store-live "busy" '(:context 1700 :output 800 :estimated 500))
                (let ((timer harness-ui-sessions--live-timer))
                  (should (timerp timer))
                  (harness-ui--store-live "busy" '(:context 1900 :output 1000 :estimated 700))
                  (should (eq timer harness-ui-sessions--live-timer)))
                (should (equal "1.2k/200k" (funcall cell "busy" "Context")))
                (should (= 0 redraws))
                (harness-test-wait (lambda () (equal "~1.0k" (funcall cell "busy" "Output")))
                                   5 "the list to show the live count")
                (should (= 1 redraws))
                (should (equal "~1.9k/200k" (funcall cell "busy" "Context")))
                (should-not harness-ui-sessions--live-timer)
                ;; It sorts by the live figures.
                (harness-ui--store-live "busy" '(:context 60000 :output 10000 :estimated 0))
                (harness-test-wait (lambda () (equal "10.0k" (funcall cell "busy" "Output")))
                                   5 "the list to show the reported count")
                (should (equal '("fresh" "quiet" "busy") (funcall sorted "Context")))
                (should (equal '("fresh" "quiet" "busy") (funcall sorted "Output")))
                ;; Figures that read the same redraw nothing.
                (setq redraws 0)
                (harness-ui--store-live "busy" '(:context 60010 :output 10010 :estimated 0))
                (should-not harness-ui-sessions--live-timer)
                ;; The count ends before the totals come: the figures stay.
                (harness-ui--store-live "busy" nil)
                (should-not harness-ui-sessions--live-timer)
                (should (equal "10.0k" (funcall cell "busy" "Output")))
                (should (equal '(:context 60010 :output 10010 :estimated 0)
                               (harness-ui-session-tokens (harness-ui-session "busy"))))
                (should (= 0 redraws))
                ;; The totals come with the session idle, and count from then on.
                (harness-ui-cache-session (append (list :status "idle"
                                                        :usage (list :cost 0 :context 61000 :last-output 1200
                                                                     :output 10200))
                                                  (harness-ui-session "busy")))
                (should-not (gethash "busy" harness-ui--live))
                (harness-test-wait (lambda () (equal "62.2k/200k" (funcall cell "busy" "Context")))
                                   5 "the list to show the totals")
                (should (equal "10.2k" (funcall cell "busy" "Output")))))
          (advice-remove 'harness-ui-sessions--redraw 'harness-ui-sessions-test-count))))))

(ert-deftest harness-ui-sessions-show-output-rates ()
  "The Tok/s column shows each measured session's output rate and sorts by it.
An idle session's figure is its last, dimmed; a new one redraws the list."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--rates (make-hash-table :test 'equal)))
        (harness-ui-sessions-test--add "fast" root :status "running")
        (harness-ui-sessions-test--add "slow" root)
        (harness-ui-sessions-test--add "never" root)
        (puthash "fast" '(:rate 61.4 :output 600 :seconds 9.8 :calls 2 :at 1000.0 :model "demo:scripted")
                 harness-ui--rates)
        (puthash "slow" '(:rate 4.3 :output 17 :seconds 4.0 :calls 1 :at 900.0 :model "demo:scripted")
                 harness-ui--rates)
        (let ((default-directory root)) (harness-sessions))
        (with-current-buffer harness-ui-sessions--buffer-name
          (let* ((column (cl-position "Tok/s" tabulated-list-format :key #'car :test #'equal))
                 (cell (lambda (id) (aref (cadr (assoc id tabulated-list-entries)) column))))
            (should (equal "61" (substring-no-properties (funcall cell "fast"))))
            (should (equal "4.3" (substring-no-properties (funcall cell "slow"))))
            (should (equal "" (funcall cell "never")))
            (should-not (get-text-property 0 'face (funcall cell "fast")))
            (should (eq 'harness-dim-face (get-text-property 0 'face (funcall cell "slow"))))
            (should (string-prefix-p "Last output rate: 4.3 tokens per second"
                                     (get-text-property 0 'help-echo (funcall cell "slow"))))
            ;; Sorting by the column puts the unmeasured first, the fastest last.
            (let ((sorter (nth 2 (aref tabulated-list-format column))))
              (should (equal '("never" "slow" "fast")
                             (mapcar #'car (sort (copy-sequence tabulated-list-entries) sorter)))))
            ;; A rate from the harness redraws the list.
            (harness-ui--store-rate "never" '(:rate 120.0 :output 1200 :seconds 10.0 :calls 1
                                              :at 1100.0 :model "demo:scripted"))
            (harness-test-wait (lambda () (equal "120" (substring-no-properties (funcall cell "never"))))
                               5 "the list to show the new rate")))))))

(ert-deftest harness-ui-sessions-project-includes-its-worktrees ()
  "A task's session in a worktree is listed with its project, not another's."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("main" "task") (harness-ui-sessions-test--shown)))
    ;; `a' toggles every project, and back.
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-toggle-scope)
      (should (equal '("elsewhere" "main" "task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-toggle-scope)
      (should (equal '("main" "task") (harness-ui-sessions-test--shown))))
    ;; The other project's list has only its own session.
    (let ((default-directory other)) (harness-sessions))
    (should (equal '("elsewhere") (harness-ui-sessions-test--shown)))
    ;; A task created while the list is open shows on the next redraw.
    (let ((default-directory root)) (harness-sessions))
    (let ((wt2 (file-name-as-directory (expand-file-name ".worktrees/task-y" root))))
      (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/y" wt2)
      (harness-ui-sessions-test--add "task-2" wt2))
    (harness-ui-sessions--redraw)
    (should (equal '("main" "task" "task-2") (harness-ui-sessions-test--shown)))))

(ert-deftest harness-ui-sessions-from-a-worktree-shows-the-whole-project ()
  "Opened from a task's worktree, the list is scoped to the main checkout."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory (expand-file-name "sub/" wt)))
      (make-directory default-directory t)
      (harness-sessions))
    (should (equal root (buffer-local-value 'harness-ui-sessions--project
                                            (get-buffer harness-ui-sessions--buffer-name))))
    (should (equal '("main" "task") (harness-ui-sessions-test--shown)))))

(ert-deftest harness-ui-sessions-removed-worktree-stays-with-its-project ()
  "An archived task's worktree is gone from disk; its session still lists."
  (harness-ui-sessions-test-with-repo
    (let ((gone (file-name-as-directory (expand-file-name ".worktrees/task-gone" root))))
      (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/gone" gone)
      (harness-ui-sessions-test--git root "worktree" "remove" gone)
      (should-not (file-exists-p gone))
      (harness-ui-sessions-test--add "main" root)
      (harness-ui-sessions-test--add "archived" gone)
      (let ((default-directory root)) (harness-sessions))
      (should (equal '("archived" "main") (harness-ui-sessions-test--shown))))))

(ert-deftest harness-ui-sessions-remote-roots-are-not-looked-at ()
  "A remote session's root is compared as it is, with no file access."
  (harness-ui-sessions-test-with-repo
    (let ((remote "/ssh:nobody@example.invalid:/srv/project/"))
      (harness-ui-sessions-test--add "main" root)
      (harness-ui-sessions-test--add "remote" remote)
      (let ((default-directory root)) (harness-sessions))
      (should (equal '("main") (harness-ui-sessions-test--shown)))
      (with-current-buffer harness-ui-sessions--buffer-name
        (cl-letf (((symbol-function 'harness-files-main-checkout) (lambda (&rest _) (error "Looked at")))
                  ((symbol-function 'harness-files-main-root) (lambda (&rest _) (error "Looked at")))
                  ((symbol-function 'file-directory-p) (lambda (&rest _) (error "Looked at"))))
          (setq harness-ui-sessions--main-roots nil)
          (should (equal remote (harness-ui-sessions--main-root remote))))
        (harness-ui-sessions-toggle-scope)
        (should (equal '("main" "remote") (harness-ui-sessions-test--shown)))))))

(ert-deftest harness-ui-sessions-resolve-each-root-once ()
  "Redraws reuse resolved roots; `g' resolves them again."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "task-again" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let* ((calls 0)
           (resolve (symbol-function 'harness-files-main-checkout)))
      (cl-letf (((symbol-function 'harness-files-main-checkout)
                 (lambda (r) (cl-incf calls) (funcall resolve r))))
        (let ((default-directory root)) (harness-sessions))
        (should (equal '("main" "task" "task-again") (harness-ui-sessions-test--shown)))
        ;; One for the scope, one for each distinct session root.
        (should (= 4 calls))
        (dotimes (_ 3) (harness-ui-sessions--redraw))
        (should (= 4 calls))
        (with-current-buffer harness-ui-sessions--buffer-name (harness-ui-sessions-reload))
        (should (= 7 calls))
        (should (equal '("main" "task" "task-again") (harness-ui-sessions-test--shown)))))))

;;;; Tasks

(ert-deftest harness-ui-sessions-task-sessions-show-their-task ()
  "A task's session is of kind task.  Until it is named it shows its
task's title, as on the board: the task's own name, which it gets as
soon as it is submitted, else its prompt's first line."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "plain" root)
    (harness-ui-sessions-test--add "working" wt :name nil :status "running")
    (harness-ui-sessions-test--add "named" wt :name "Fix login redirect loop")
    (harness-ui-sessions-test--add "titled" wt :name nil :status "running")
    (setq harness-ui-sessions-test--tasks
          (list (list :id "t-1" :session "working" :state "active" :column "active"
                      :prompt "make btw open up with a lower effort level\n\nunless the config says otherwise")
                (list :id "t-2" :session "named" :state "review" :column "review"
                      :prompt "the login page loops")
                (list :id "t-3" :state "pending" :column "pending" :prompt "not started, so no session")
                (list :id "t-4" :session "titled" :state "active" :column "active"
                      :name "Export orders as CSV" :prompt "finance wants the orders as a CSV file")))
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("named" "plain" "titled" "working") (harness-ui-sessions-test--shown)))
    (should (equal '("make btw open up with a lower effort level" "task")
                   (harness-ui-sessions-test--row "working")))
    (should (equal '("Fix login redirect loop" "task") (harness-ui-sessions-test--row "named")))
    (should (equal '("Export orders as CSV" "task") (harness-ui-sessions-test--row "titled")))
    (should (equal '("plain" "") (harness-ui-sessions-test--row "plain")))
    ;; Named by the model after its turn: the name wins over the title.
    (harness-ui-sessions-test--add "working" wt :name "Lower BTW effort level" :status "idle")
    (harness-ui-sessions--redraw)
    (should (equal '("Lower BTW effort level" "task") (harness-ui-sessions-test--row "working")))))

(ert-deftest harness-ui-sessions-follow-task-events ()
  "`task/changed' and `task/deleted' update the list between fetches."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "s-1" wt :name nil :status "running")
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("unnamed" "") (harness-ui-sessions-test--row "s-1")))
    (harness-ui-sessions-test--with-init
      (cl-flet ((event (name &rest args) (run-hook-with-args 'harness-ui-event-functions name args))
                (shows (row) (harness-test-wait (lambda () (equal row (harness-ui-sessions-test--row "s-1")))
                                                5 (format "the list to show %S" row))))
        ;; Submitted: no session yet.
        (event "task/changed" (list :id "t-1" :prompt "Paginate GET /orders" :state "pending"))
        ;; Started: its session works on it.
        (event "task/changed" (list :id "t-1" :session "s-1" :prompt "Paginate GET /orders" :state "active"))
        (shows '("Paginate GET /orders" "task"))
        ;; Its prompt edited: the same task, shown anew.
        (event "task/changed" (list :id "t-1" :session "s-1" :prompt "Paginate GET /orders and /products"
                                    :state "active"))
        (shows '("Paginate GET /orders and /products" "task"))
        ;; Deleted, its session kept: a plain session again.
        (event "task/deleted" "t-1")
        (shows '("unnamed" ""))
        ;; Other events leave the list alone.
        (event "agent/turn-ended" "s-1" "end-turn")
        (should (equal '("unnamed" "") (harness-ui-sessions-test--row "s-1")))))))

(ert-deftest harness-ui-sessions-tasks-come-again-on-reload ()
  "`g' and a reload or reconnect ask for the tasks again.  When the
harness cannot say, as one without tasks, the list names no task."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "s-1" wt :name nil)
    (setq harness-ui-sessions-test--tasks (list (list :id "t-1" :session "s-1" :prompt "Log slow requests")))
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("Log slow requests" "task") (harness-ui-sessions-test--row "s-1")))
    (setq harness-ui-sessions-test--tasks
          (list (list :id "t-1" :session "s-1" :prompt "Log requests slower than 500 ms")))
    (with-current-buffer harness-ui-sessions--buffer-name (harness-ui-sessions-reload))
    (should (equal '("Log requests slower than 500 ms" "task") (harness-ui-sessions-test--row "s-1")))
    ;; Connected to a harness without tasks.
    (setq harness-ui-sessions-test--tasks 'fail)
    (harness-ui-sessions-test--with-init (run-hooks 'harness-ui-redraw-hook))
    (should (equal '("unnamed" "") (harness-ui-sessions-test--row "s-1")))))

(ert-deftest harness-ui-sessions-filter-finds-tasks ()
  "The filter matches what a row shows: a task's title and the kind task."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "s-task" wt :name nil)
    (harness-ui-sessions-test--add "s-guide" root :name "Write the API guide")
    (setq harness-ui-sessions-test--tasks (list (list :id "t-1" :session "s-task" :prompt "Paginate GET /orders")))
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-filter "paginate")
      (should (equal '("s-task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-filter "task")
      (should (equal '("s-task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-filter "")
      (should (equal '("s-guide" "s-task") (harness-ui-sessions-test--shown))))))

;;;; Those waiting for you

(ert-deftest harness-ui-sessions-show-those-waiting-for-you ()
  "b shows only the blocked sessions, under a banner counting them.
The banner's [Show all] shows every session again, as b does.  With
none waiting the banner says so, rows or no rows.  The mode line's
notifier opens the list so for every project, whatever its filter."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "busy" root :status "running")
    (harness-ui-sessions-test--blocked "asks" root "permission")
    (harness-ui-sessions-test--blocked "elsewhere" other "question")
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (equal '("asks" "busy") (harness-ui-sessions-test--shown)))
      (should-not (string-match-p "waits? for you" (harness-ui-sessions-test--text)))
      (should (eq 'harness-ui-sessions-toggle-blocked (key-binding (kbd "b"))))
      (call-interactively #'harness-ui-sessions-toggle-blocked)
      (should (equal '("asks") (harness-ui-sessions-test--shown)))
      (should (equal " [project blocked]" mode-line-process))
      ;; The banner first, which is no session's, then the rows.
      (should (string-match-p "\\` .+ 1 session waits for you in this project  \\[Show all\\] b\n"
                              (harness-ui-sessions-test--text)))
      (should (equal "asks" (tabulated-list-get-id)))
      (should-not (tabulated-list-get-id (point-min)))
      ;; Its [Show all] shows every session again.
      (goto-char (point-min))
      (search-forward "[Show all")
      (harness-ui-action-push)
      (should (equal '("asks" "busy") (harness-ui-sessions-test--shown)))
      (should (equal " [project]" mode-line-process))
      (should-not (string-match-p "waits? for you" (harness-ui-sessions-test--text)))
      ;; None waiting, or none the filter lets through: the banner says so.
      (harness-ui-sessions-toggle-blocked)
      (harness-ui-sessions-filter "busy")
      (should-not (harness-ui-sessions-test--shown))
      (should (string-match-p
               "\\` .+ No session waits for you in this project matching /busy  \\[Show all\\] b\n\\'"
               (harness-ui-sessions-test--text))))
    ;; The notifier's: every project, whatever the filter was.
    (harness-sessions-waiting)
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (equal '("asks" "elsewhere") (harness-ui-sessions-test--shown)))
      (should (equal " [all projects blocked]" mode-line-process))
      (should (string-match-p "\\` .+ 2 sessions wait for you in any project  \\[Show all\\] b\n"
                              (harness-ui-sessions-test--text))))
    ;; The list opened as ever shows them all again.
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("asks" "busy") (harness-ui-sessions-test--shown)))
    (should-not (string-match-p "waits? for you" (harness-ui-sessions-test--text)))))

(ert-deftest harness-ui-sessions-answer-what-a-session-waits-on ()
  "A blocked session's row has a line under it saying what it waits on.
It has the task board's buttons: [Allow] and [Deny] for a permission
request, which y and n push from either line too, and [Answer…] for a
question, which pops it out.  An answer takes the line away at once,
before the session says it waits no more."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((popped nil))
        (harness-ui-sessions-test--add "busy" root :status "running" :updated 400)
        (harness-ui-sessions-test--blocked "asks" root "permission" :updated 300)
        (harness-ui-sessions-test--blocked "risky" root "permission" :updated 200)
        (harness-ui-sessions-test--blocked "child" root "question" :parent-id "busy")
        (let ((default-directory root)) (harness-sessions))
        (with-current-buffer harness-ui-sessions--buffer-name
          ;; Under the name, the buttons, then what it waits on.
          (should (equal "    [Allow] [Deny]  needs your permission · Bash: rm -rf build/"
                         (harness-ui-sessions-test--line "asks")))
          (should (equal "        [Answer…]  has a question for you · Which colour?"
                         (harness-ui-sessions-test--line "child")))
          (should-not (harness-ui-sessions-test--line "busy"))
          (should (string-match-p "y allows it, n denies it"
                                  (harness-ui-sessions--waiting-help (harness-ui-session "asks"))))
          ;; [Allow] answers over the bus, and the line goes at once.
          (harness-ui-sessions-test--goto "asks")
          (forward-line 1)
          (search-forward "[Allow")
          (harness-ui-action-push)
          (should (equal '(("_harness/permission/answer"
                            (:session-id "asks" :pending-id "asks-p" :answer "allow-once")))
                         (harness-ui-sessions-test--answers)))
          (harness-test-wait (lambda () (not (harness-ui-sessions-test--line "asks")))
                             5 "the answered request to leave the list")
          (should (equal "asks" (tabulated-list-get-id)))
          ;; Still blocked until the session says otherwise, it offers nothing.
          (should (equal "blocked" (plist-get (harness-ui-session "asks") :status)))
          (should-error (harness-ui-sessions-allow) :type 'user-error)
          ;; n on the row itself denies.
          (harness-ui-sessions-test--goto "risky")
          (should (eq 'harness-ui-sessions-allow (key-binding (kbd "y"))))
          (should (eq 'harness-ui-sessions-deny (key-binding (kbd "n"))))
          (call-interactively (key-binding (kbd "n")))
          (should (equal '("_harness/permission/answer"
                           (:session-id "risky" :pending-id "risky-p" :answer "deny-once"))
                         (car (last (harness-ui-sessions-test--answers)))))
          ;; A question is not allowed: [Answer…] pops it out to be answered.
          (harness-ui-sessions-test--goto "child")
          (should-not (eq 'harness-ui-sessions-allow (key-binding (kbd "y"))))
          (should-error (harness-ui-sessions-allow) :type 'user-error)
          (forward-line 1)
          (search-forward "[Answer")
          (cl-letf (((symbol-function 'harness-ui-pending-popout) (lambda (sid) (push sid popped) t)))
            (harness-ui-action-push))
          (should (equal '("child") popped))
          (should (= 2 (length (harness-ui-sessions-test--answers)))))))))

(ert-deftest harness-ui-sessions-move-the-session-at-point ()
  "m moves the session at point to another directory, read from the
directory that holds its own, and the list follows it to the project
there."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((asked nil))
        (harness-ui-sessions-test--add "lost" other)
        (harness-ui-sessions-test--add "home" root)
        (let ((default-directory other)) (harness-sessions))
        (with-current-buffer harness-ui-sessions--buffer-name
          (should (equal '("lost") (harness-ui-sessions-test--shown)))
          (harness-ui-sessions-test--goto "lost")
          (should (eq 'harness-ui-sessions-move (key-binding (kbd "m"))))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (prompt dir &rest _) (push (list prompt dir) asked) root)))
            (call-interactively (key-binding (kbd "m"))))
          (should (= 1 (length asked)))
          (should (string-match-p "\\`Move .*lost to directory: \\'" (car (car asked))))
          (should (equal base (cadr (car asked))))
          (should (equal (list (list "_harness/session/move" (list :id "lost" :dir root :keep-old-dir :false :project root)))
                         (harness-ui-sessions-test--answers)))
          (should (equal root (plist-get (harness-ui-session "lost") :project)))
          (harness-test-wait (lambda () (null (harness-ui-sessions-test--shown))) 5 "the list to follow the move"))))))

(ert-deftest harness-ui-sessions-open-in-its-project ()
  "RET opens the session at point in its project, from either of its lines.
The project switched to is the main checkout, a task's worktree's too,
and the session then opens where sessions open -- in the one window of
a workspace showing nothing yet -- and without a switch it replaces the
list, as ever.  A session shown already gets its window selected.  A
remote project, or one gone from disk, is not switched to."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--blocked "task" wt "permission")
    (harness-ui-sessions-test--add "remote" "/ssh:nobody@example.invalid:/srv/project/")
    (harness-ui-sessions-test--add "gone" (expand-file-name "gone/" other))
    (let* ((switched nil) (opened nil) (shown nil) (switch t)
           (chat (get-buffer-create " *harness-ui-sessions-test chat*"))
           (window-buffer (window-buffer))
           (harness-ui-switch-project-function (lambda (dir) (push dir switched) switch))
           (harness-ui-open-session-function (lambda (id) (push id opened) chat)))
      (unwind-protect
          (cl-letf (((symbol-function 'harness-ui-display-buffer)
                     (lambda (buffer &optional position) (push (list buffer position) shown) buffer)))
            (let ((default-directory root)) (harness-sessions))
            (with-current-buffer harness-ui-sessions--buffer-name
              (setq-local harness-ui-position 'full)
              ;; The line of what it waits on is the session's too.
              (harness-ui-sessions-test--goto "task")
              (forward-line 1)
              (should (eq 'harness-ui-sessions-open (key-binding (kbd "RET"))))
              (call-interactively (key-binding (kbd "RET"))))
            (should (equal (list root) switched))
            (should (equal '("task") opened))
            (should (equal (list (list chat nil)) shown))
            ;; In its project already: the session replaces the list.
            (setq switched nil shown nil switch nil)
            (with-current-buffer harness-ui-sessions--buffer-name
              (harness-ui-sessions-test--goto "task")
              (harness-ui-sessions-open))
            (should (equal (list root) switched))
            (should (equal (list (list chat 'full)) shown))
            ;; Shown already: its window is selected, it opens no more.
            (setq switched nil shown nil)
            (set-window-buffer (selected-window) chat)
            (with-current-buffer harness-ui-sessions--buffer-name
              (should (eq chat (harness-ui-visit-session "task"))))
            (should-not shown)
            (should (eq chat (window-buffer (selected-window))))
            ;; Switched to a workspace showing nothing yet: the session
            ;; takes its window, unless a position is asked for.
            (set-window-buffer (selected-window) window-buffer)
            (setq switched nil shown nil switch 'blank)
            (with-current-buffer harness-ui-sessions--buffer-name
              (setq-local harness-ui-position 'left)
              (harness-ui-sessions-test--goto "task")
              (harness-ui-sessions-open)
              (harness-ui-sessions-open 'bottom))
            (should (equal (list root root) switched))
            (should (equal (list (list chat 'bottom) (list chat 'full)) shown))
            (setq switch t)
            ;; Nowhere to switch to.
            (setq switched nil)
            (cl-letf (((symbol-function 'harness-files-owning-checkout) (lambda (&rest _) (error "Looked at"))))
              (should-not (harness-ui-session-project (harness-ui-session "remote"))))
            (should-not (harness-ui-session-project (harness-ui-session "gone")))
            (harness-ui-visit-session "remote")
            (harness-ui-visit-session "gone")
            (should-not switched)
            ;; Nor with switching turned off.
            (let ((harness-ui-switch-project-function nil))
              (harness-ui-visit-session "task"))
            (should-not switched))
        (set-window-buffer (selected-window) window-buffer)
        (kill-buffer chat)))))

(defvar persp-mode)
(defvar +workspaces-switch-project-function)
(defvar doom-fallback-buffer-name)

(defun harness-ui-sessions-test--project (base dir &rest files)
  "Make a project at DIR under BASE, a directory with .git, holding FILES.
Return its root."
  (let ((root (file-name-as-directory (expand-file-name dir base))))
    (make-directory (expand-file-name ".git" root) t)
    (dolist (file files)
      (write-region "" nil (expand-file-name file root)))
    root))

(defmacro harness-ui-sessions-test-with-workspaces (&rest body)
  "Run BODY with Doom Emacs's workspaces faked, in a frame of one window.
In BODY, `workspaces' lists the workspaces in order, each as
\(NAME PROJECT . OPEN): PROJECT is the directory it notes as its
`+workspace-project', as a fork of Doom keeps it (nil for none), OPEN
the files (or buffers) it has open.  `current' names the current one.
`switched' lists the workspaces switched to and `made' Doom's project
switches, as (DIR FUNCTION), FUNCTION the `+workspaces-switch-project-function'
it ran with, newest first.  `base' is a directory for projects
\(`harness-ui-sessions-test--project').  A workspace shows its first
open file in the window, else Doom's fallback buffer; Doom's project
switch makes a workspace named after the project, noting it, as the
fork's does -- \"parent/name\" when the name is taken -- that shows
the fallback buffer."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (file-truename (harness-test-temp-dir))))
          (workspaces nil) (current nil) (switched nil) (made nil)
          (doom-fallback-buffer-name " *harness-ui-sessions-test doom*")
          (persp-mode t)
          (buffers (lambda (open)
                     (mapcar (lambda (f) (if (bufferp f) f (find-file-noselect f))) open)))
          (show (lambda (name)
                  (setq current name)
                  (set-window-buffer
                   nil (or (car (funcall buffers (cddr (assoc name workspaces))))
                           (get-buffer-create doom-fallback-buffer-name))))))
     (save-window-excursion
       (delete-other-windows)
       (unwind-protect
           (cl-letf (((symbol-function '+workspace-list-names) (lambda () (mapcar #'car workspaces)))
                     ((symbol-function '+workspace-get)
                      (lambda (name &optional _noerror) (assoc name workspaces)))
                     ((symbol-function '+workspace-buffer-list)
                      (lambda (&optional persp) (funcall buffers (cddr persp))))
                     ((symbol-function 'persp-parameter)
                      (lambda (param &optional persp)
                        (and (eq param '+workspace-project) (cadr persp))))
                     ((symbol-function '+workspace-current-name) (lambda () current))
                     ((symbol-function '+workspace-switch)
                      (lambda (name &optional _auto-create)
                        (push name switched)
                        (funcall show name)
                        t))
                     ((symbol-function '+workspace-message) #'ignore)
                     ((symbol-function '+workspaces-switch-to-project-h)
                      (lambda (&optional dir)
                        (push (list dir (symbol-value '+workspaces-switch-project-function)) made)
                        (let* ((name (file-name-nondirectory (directory-file-name dir)))
                               (name (if (assoc name workspaces)
                                         (concat (file-name-nondirectory
                                                  (directory-file-name (file-name-directory
                                                                        (directory-file-name dir))))
                                                 "/" name)
                                       name)))
                          (setq workspaces (append workspaces (list (list name dir))))
                          (funcall show name))))
                     ((symbol-function 'doom-project-name)
                      (lambda (&optional dir) (file-name-nondirectory (directory-file-name dir))))
                     ((symbol-function 'doom-project-p)
                      (lambda (&optional dir) (file-directory-p (expand-file-name ".git" dir)))))
             ,@body)
         (dolist (buffer (buffer-list))
           (when (or (equal (buffer-name buffer) doom-fallback-buffer-name)
                     (string-prefix-p base (or (buffer-file-name buffer) "")))
             (kill-buffer buffer)))
         (delete-directory base t)))))

(ert-deftest harness-ui-sessions-switch-doom-workspaces ()
  "With Doom Emacs's workspaces, a session's project is switched to.
Its workspace, when it has one, comes back as it was left; else Doom
makes one, as switching project does but without asking for a file to
open, which shows nothing yet.  A project whose workspace is current
already is not switched to, nor a directory that is no project, and
without workspaces nothing is."
  (harness-ui-sessions-test-with-workspaces
    (let ((shop (harness-ui-sessions-test--project base "srv/shop/" "README.md"))
          (blog (harness-ui-sessions-test--project base "srv/blog/" "post.md"))
          (lab (harness-ui-sessions-test--project base "srv/lab/"))
          (scratch (file-name-as-directory (expand-file-name "scratch" base))))
      (make-directory scratch)
      (setq workspaces (list (list "blog" nil (expand-file-name "post.md" blog))
                             (list "shop" nil (expand-file-name "README.md" shop)))
            current "blog")
      (should (eq t (harness-ui-switch-project-workspace shop)))
      (should (equal '("shop") switched))
      (should-not made)
      (should (equal (expand-file-name "README.md" shop) (buffer-file-name (window-buffer))))
      ;; Its workspace is current already.
      (should-not (harness-ui-switch-project-workspace shop))
      (should (equal '("shop") switched))
      ;; None yet: Doom makes it, with no file to open, and it is blank.
      (should (eq 'blank (harness-ui-switch-project-workspace lab)))
      (should (equal (list (list lab 'ignore)) made))
      (should (equal "lab" current))
      (should-not (harness-ui-switch-project-workspace lab))
      ;; No project.
      (should-not (harness-ui-switch-project-workspace scratch))
      (let ((persp-mode nil))
        (should-not (harness-ui-switch-project-workspace blog)))
      (should (equal '("shop") switched))
      (should (= 1 (length made)))))
  ;; No Doom at all.
  (let ((persp-mode t))
    (should-not (fboundp '+workspaces-switch-to-project-h))
    (should-not (harness-ui-switch-project-workspace "/srv/blog/"))))

(ert-deftest harness-ui-sessions-switch-to-the-workspace-a-fork-notes ()
  "A fork of Doom notes the project a workspace is for, `+workspace-project'.
A workspace noting the project is the project's whatever its name, and
so is the one named after it noting none: the empty workspace the
project was first opened in, which the fork renames without noting
anything, and whose project the fork's own switch passes over for a
new, empty workspace.  One named after the project noting another is
the other's, unless that is gone, moved say.  A workspace noting a
directory on another host is not looked at, which would connect to it."
  (harness-ui-sessions-test-with-workspaces
    (let ((shop (harness-ui-sessions-test--project base "srv/shop/" "README.md"))
          (old-shop (harness-ui-sessions-test--project base "old/shop/" "main.c"))
          (blog (harness-ui-sessions-test--project base "srv/blog/" "post.md"))
          (lab (harness-ui-sessions-test--project base "srv/lab/"))
          (other-lab (harness-ui-sessions-test--project base "elsewhere/lab/"))
          (wiki (harness-ui-sessions-test--project base "srv/wiki/" "index.org"))
          (looked nil))
      (setq workspaces (list (list "blog" blog (expand-file-name "post.md" blog))
                             (list "shop" nil (expand-file-name "README.md" shop))
                             (list "old/shop" old-shop (expand-file-name "main.c" old-shop))
                             (list "lab" other-lab)
                             (list "wiki" (expand-file-name "gone/wiki/" base)
                                   (expand-file-name "index.org" wiki))
                             (list "far/shop" "/ssh:nobody@example.invalid:/srv/shop/"))
            current "blog")
      (cl-letf* ((directory-p (symbol-function 'file-directory-p))
                 ((symbol-function 'file-directory-p)
                  (lambda (file)
                    (if (file-remote-p file)
                        (ignore (push file looked))
                      (funcall directory-p file))))
                 (equal-p (symbol-function 'file-equal-p))
                 ((symbol-function 'file-equal-p)
                  (lambda (file other)
                    (if (or (file-remote-p file) (file-remote-p other))
                        (ignore (push file looked))
                      (funcall equal-p file other)))))
        ;; Noting the project, from inside: current already.
        (should-not (harness-ui-switch-project-workspace blog))
        ;; Named after it, noting none.
        (should (eq t (harness-ui-switch-project-workspace shop)))
        (should (equal "shop" current))
        ;; Noting it under another name, past "shop", which has none of its files.
        (should (eq t (harness-ui-switch-project-workspace old-shop)))
        (should (equal "old/shop" current))
        (should (eq t (harness-ui-switch-project-workspace blog)))
        (should (equal "blog" current))
        ;; Named after it, noting a directory gone since.
        (should (eq t (harness-ui-switch-project-workspace wiki)))
        (should (equal "wiki" current))
        (should (equal (expand-file-name "index.org" wiki) (buffer-file-name (window-buffer))))
        ;; Named after it, noting another project: Doom makes its own.
        (should (eq 'blank (harness-ui-switch-project-workspace lab)))
        (should (equal (list (list lab 'ignore)) made))
        (should (equal "srv/lab" current))
        (should (equal '("wiki" "blog" "old/shop" "shop") switched))
        (should-not looked)))))

(ert-deftest harness-ui-sessions-switch-past-an-empty-duplicate ()
  "Of two workspaces of a project, the one with its files open is taken.
That is the one named after the project, noting none, rather than the
empty one a fork of Doom made beside it, noting the project -- from
another workspace or from that empty one.  The one with the most of
the project's files open wins; on a tie the one named after the
project.  Remote files are not looked at."
  (harness-ui-sessions-test-with-workspaces
    (let* ((harness (harness-ui-sessions-test--project base "ai/emacs-agent-harness/"
                                                       "README.md" "harness.el" "DESIGN.md"))
           (site (harness-ui-sessions-test--project base "web/site/" "index.html"))
           (file (lambda (name) (expand-file-name name harness)))
           (remote (generate-new-buffer " *harness-ui-sessions-test remote*")))
      (with-current-buffer remote
        (setq buffer-file-name "/ssh:nobody@example.invalid:/srv/x.el"))
      (unwind-protect
          (cl-letf* ((in-directory (symbol-function 'file-in-directory-p))
                     ((symbol-function 'file-in-directory-p)
                      (lambda (file dir)
                        (when (file-remote-p file) (error "Looked at %s" file))
                        (funcall in-directory file dir))))
            (setq workspaces (list (list "emacs-agent-harness" nil
                                         (funcall file "README.md") (funcall file "harness.el"))
                                   (list "site" site (expand-file-name "index.html" site))
                                   (list "ai/emacs-agent-harness" harness remote))
                  current "site")
            (should (eq t (harness-ui-switch-project-workspace harness)))
            (should (equal "emacs-agent-harness" current))
            (should (equal (funcall file "README.md") (buffer-file-name (window-buffer))))
            ;; From the empty one too.
            (setq current "ai/emacs-agent-harness")
            (should (eq t (harness-ui-switch-project-workspace harness)))
            (should (equal "emacs-agent-harness" current))
            ;; More of its files open wins.
            (setcdr (cdr (assoc "ai/emacs-agent-harness" workspaces))
                    (list (funcall file "DESIGN.md") (funcall file "README.md") (funcall file "harness.el")))
            (should (eq t (harness-ui-switch-project-workspace harness)))
            (should (equal "ai/emacs-agent-harness" current))
            ;; A tie: the one named after the project.
            (setcdr (cdr (assoc "emacs-agent-harness" workspaces)) nil)
            (setcdr (cdr (assoc "ai/emacs-agent-harness" workspaces)) nil)
            (should (eq 'blank (harness-ui-switch-project-workspace harness)))
            (should (equal "emacs-agent-harness" current))
            (should-not made))
        (kill-buffer remote)))))

(ert-deftest harness-ui-sessions-notifier-shows-those-waiting ()
  "A click on the mode line's notifier lists the sessions waiting for you.
From every project, as `harness-sessions-waiting'.  With none waiting
it opens the list as ever."
  (require 'harness-ui-notify)
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "busy" root :status "running")
    (harness-ui-sessions-test--blocked "elsewhere" other "question")
    (let* ((segment (harness-ui-notify--segment 1 'harness-icon-blocked 'harness-notify-blocked-face "Waiting"))
           (click (lookup-key (get-text-property 1 'local-map segment) [mode-line mouse-1]))
           (default-directory root))
      (call-interactively click)
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal '("elsewhere") (harness-ui-sessions-test--shown)))
        (should (equal " [all projects blocked]" mode-line-process)))
      ;; Answered: with none waiting, the list as ever.
      (harness-ui-sessions-test--add "elsewhere" other :status "idle")
      (call-interactively click)
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal '("busy") (harness-ui-sessions-test--shown)))
        (should (equal " [project]" mode-line-process))))))

;;;; The fullscreen layout

(ert-deftest harness-ui-sessions-is-an-overview ()
  "The list can take the fullscreen layout: F starts it, q on it ends it.
Beside it shows the session at point, else the newest it lists, a BTW
aside."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "old" root :updated 100)
    (harness-ui-sessions-test--add "new" root :updated 300)
    (harness-ui-sessions-test--add "btw" root :updated 400 :kind "btw")
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (harness-ui-overview-p (current-buffer)))
      (should (eq 'harness-fullscreen (key-binding (kbd "F"))))
      (should (eq 'harness-ui-quit-view (key-binding (kbd "q"))))
      (should (eq 'harness-ui-bury (key-binding (kbd "C-c C-z"))))
      (goto-char (point-min))
      (while (not (equal (tabulated-list-get-id) "old")) (forward-line 1))
      (should (equal "old" (harness-ui-sessions--overview-session)))
      (goto-char (point-max))
      (should-not (tabulated-list-get-id))
      (should (equal "new" (harness-ui-sessions--overview-session))))))

(provide 'harness-ui-sessions-test)
;;; harness-ui-sessions-test.el ends here
