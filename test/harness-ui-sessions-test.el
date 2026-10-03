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

(defun harness-ui-sessions-test--request (method &optional _params)
  "Answer METHOD as the harness would: `_harness/task/list' with the tasks.
Anything else, or the tasks when they are `fail', fails."
  (if (and (equal method "_harness/task/list") (listp harness-ui-sessions-test--tasks))
      (harness-resolved harness-ui-sessions-test--tasks)
    (harness-rejected (list 'harness-error (format "%s: no such method" method)))))

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
             (let ((harness-ui-sessions-test--tasks nil))
               ,@body)))
       (clrhash harness-ui--sessions)
       (when-let* ((buf (get-buffer harness-ui-sessions-buffer-name))) (kill-buffer buf))
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
  (with-current-buffer harness-ui-sessions-buffer-name
    (sort (mapcar #'car tabulated-list-entries) #'string<)))

(defun harness-ui-sessions-test--row (id)
  "Return (NAME KIND) as the list buffer shows session ID, as plain text."
  (with-current-buffer harness-ui-sessions-buffer-name
    (let ((columns (cadr (assoc id tabulated-list-entries))))
      (list (substring-no-properties (aref columns 1))
            (substring-no-properties (aref columns 3))))))

(defmacro harness-ui-sessions-test--with-init (&rest body)
  "Run BODY with the list's module started, its hooks kept to BODY."
  (declare (indent 0))
  `(let ((harness-ui-event-functions nil)
         (harness-ui-redraw-hook nil)
         (harness-ui-sessions-changed-hook nil))
     (harness-ui-sessions--init)
     ,@body))

(ert-deftest harness-ui-sessions-project-includes-its-worktrees ()
  "A task's session in a worktree is listed with its project, not another's."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("main" "task") (harness-ui-sessions-test--shown)))
    ;; `a' toggles every project, and back.
    (with-current-buffer harness-ui-sessions-buffer-name
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
                                            (get-buffer harness-ui-sessions-buffer-name))))
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
      (with-current-buffer harness-ui-sessions-buffer-name
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
        (with-current-buffer harness-ui-sessions-buffer-name (harness-ui-sessions-reload))
        (should (= 7 calls))
        (should (equal '("main" "task" "task-again") (harness-ui-sessions-test--shown)))))))

;;;; Tasks

(ert-deftest harness-ui-sessions-task-sessions-show-their-task ()
  "A task's session is of kind task.  Until it is named, which happens
after its first turn, where the task does its work, it shows its
task's title, the prompt's first line, as on the board."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "plain" root)
    (harness-ui-sessions-test--add "working" wt :name nil :status "running")
    (harness-ui-sessions-test--add "named" wt :name "Fix login redirect loop")
    (setq harness-ui-sessions-test--tasks
          (list (list :id "t-1" :session "working" :state "active" :column "active"
                      :prompt "make btw open up with a lower effort level\n\nunless the config says otherwise")
                (list :id "t-2" :session "named" :state "review" :column "review"
                      :prompt "the login page loops")
                (list :id "t-3" :state "pending" :column "pending" :prompt "not started, so no session")))
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("named" "plain" "working") (harness-ui-sessions-test--shown)))
    (should (equal '("make btw open up with a lower effort level" "task")
                   (harness-ui-sessions-test--row "working")))
    (should (equal '("Fix login redirect loop" "task") (harness-ui-sessions-test--row "named")))
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
    (with-current-buffer harness-ui-sessions-buffer-name (harness-ui-sessions-reload))
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
    (with-current-buffer harness-ui-sessions-buffer-name
      (harness-ui-sessions-filter "paginate")
      (should (equal '("s-task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-filter "task")
      (should (equal '("s-task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-filter "")
      (should (equal '("s-guide" "s-task") (harness-ui-sessions-test--shown))))))

(provide 'harness-ui-sessions-test)
;;; harness-ui-sessions-test.el ends here
