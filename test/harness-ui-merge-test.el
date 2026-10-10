;;; harness-ui-merge-test.el --- Tests for the merge queue panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session whose sub-agents' branches merge into it shows the queue
;; above the compose box, beside its todo list: which children are
;; queued, merging, in conflict, merged or failed.  The panel is drawn
;; from `merge/view' over ACP, and merge events make the open chat draw
;; it again.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-merge--queues)
(defvar harness-merge--locks)
(defvar harness-merge--holds)
(defvar harness-merge--history)
(defvar harness-merge--timers)
(defvar harness-ui--sessions)
(defvar harness-ui-merge--views)
(defvar harness-ui-merge--asked)
(defvar harness-chat--loading)
(defvar harness-ui-session-id)
(defvar harness-ui-default-position)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-acp--server-enabled)

(defun harness-ui-merge-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-ui-merge-test--write (dir name text)
  "Write TEXT to NAME under DIR."
  (with-temp-file (expand-file-name name dir) (insert text)))

(defun harness-ui-merge-test--make-repo (base)
  "Create BASE/repo with one commit and a worktree; return (ROOT . WT)."
  (let* ((root (file-name-as-directory (expand-file-name "repo" base)))
         (wt (file-name-as-directory (expand-file-name "wt" base))))
    (make-directory root t)
    (harness-ui-merge-test--git root "init" "-q" "-b" "main")
    (harness-ui-merge-test--git root "config" "user.name" "Harness Test")
    (harness-ui-merge-test--git root "config" "user.email" "test@example.invalid")
    (harness-ui-merge-test--git root "config" "commit.gpgsign" "false")
    (harness-ui-merge-test--write root "README" "hello\n")
    (harness-ui-merge-test--git root "add" "README")
    (harness-ui-merge-test--git root "commit" "-q" "-m" "initial")
    (harness-ui-merge-test--git root "worktree" "add" "-q" "-b" "worker" wt)
    (cons root wt)))

(defmacro harness-ui-merge-test-with (&rest body)
  "Load the harness and its UI with a session and a worker in a worktree.
Binds `root' (a git repository), `wt' (a worktree of it), `parent' (a
session at ROOT) and `worker' (a session in WT, of PARENT)."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp merge))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-merge--queues)
     (clrhash harness-merge--locks)
     (clrhash harness-merge--holds)
     (clrhash harness-merge--history)
     (let* ((harness-provider-demo--delay 0.005)
            (harness-provider-demo-script-override
             '((:type text :delta "Nothing to do.") (:type done :stop-reason end-turn)))
            (harness-acp-token nil)
            (harness-ui-default-position 'full)
            (default-directory dir)
            (repo (harness-ui-merge-test--make-repo dir))
            (root (car repo))
            (wt (cdr repo))
            (parent (plist-get (harness-call 'session/create :cwd root :model "demo:scripted" :name "main") :id))
            (worker (plist-get (harness-call 'session/create :cwd wt :worktree wt :parent-id parent
                                             :kind 'fork :model "demo:scripted" :name "worker")
                               :id)))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-compose ui-markdown ui-popout ui-chat ui-merge))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (clrhash harness-ui-merge--views)
       (clrhash harness-ui-merge--asked)
       (ignore root wt parent worker)
       (unwind-protect
           (progn ,@body)
         (dolist (b (buffer-list))
           (when (memq (buffer-local-value 'major-mode b) '(harness-chat-mode))
             (ignore-errors (kill-buffer b))))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-merge-test--open-session (sid)
  "Open SID's chat buffer in the selected window and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (set-window-buffer (selected-window) buffer)
    (harness-test-wait (lambda () (not (buffer-local-value 'harness-chat--loading buffer))) 5 "the session to load")
    buffer))

(defun harness-ui-merge-test--text (buffer)
  "Return BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-merge-test--wait-text (buffer regexp)
  "Wait until BUFFER's text matches REGEXP."
  (harness-test-wait (lambda () (string-match-p regexp (harness-ui-merge-test--text buffer)))
                     5 (format "the buffer to show %s" regexp)))

(defun harness-ui-merge-test--undefined-faces (text)
  "Return the face names in TEXT's properties that name no face."
  (let ((pos 0) (bad nil))
    (while (< pos (length text))
      (let ((face (get-text-property pos 'face text)))
        (dolist (f (ensure-list face))
          (unless (or (null f) (keywordp f) (consp f) (facep f))
            (cl-pushnew f bad))))
      (setq pos (or (next-single-property-change pos 'face text) (length text))))
    bad))

(ert-deftest harness-ui-merge-panel-follows-the-queue ()
  "The chat of a session shows the merges into it, as they happen."
  (harness-ui-merge-test-with
    (let ((chat (harness-ui-merge-test--open-session parent)))
      ;; Nothing merges into the session yet: no panel.
      (should-not (string-match-p "Merge queue" (harness-ui-merge-test--text chat)))
      (harness-ui-merge-test--write wt "worker.txt" "from the worker\n")
      (harness-ui-merge-test--git wt "add" "worker.txt")
      (harness-ui-merge-test--git wt "commit" "-q" "-m" "worker work")
      ;; Held: the worker's merge stays queued, and the panel says so.
      (puthash parent "someone" harness-merge--locks)
      (harness-call 'merge/enqueue worker parent)
      (harness-ui-merge-test--wait-text chat "Merge queue  1 live")
      (should (string-match-p "worker  queued (1 in line)" (harness-ui-merge-test--text chat)))
      ;; Let it merge: the panel follows the event and shows the outcome.
      (remhash parent harness-merge--locks)
      (harness-run-soon #'harness-merge--pump parent)
      (harness-ui-merge-test--wait-text chat "1 finished")
      (should (string-match-p "worker  merged" (harness-ui-merge-test--text chat)))
      (should (file-exists-p (expand-file-name "worker.txt" root))))))

(ert-deftest harness-ui-merge-panel-shows-each-state ()
  "The panel marks a merge queued, merging, in conflict, merged or failed."
  (harness-ui-merge-test-with
    (let* ((harness-ui-session-id parent)
           ;; Statuses come over ACP as strings; the panel takes either.
           (view (list (list :child "c1" :name "queued-worker" :status "queued" :position 1)
                       (list :child "c2" :name "waiting-worker" :status "queued" :position 2 :waiting t)
                       (list :child "c3" :name "merging-worker" :status "merging")
                       (list :child "c4" :name "conflict-worker" :status "conflict" :reason "README")
                       (list :child "c5" :name "merged-worker" :status "merged")
                       (list :child "c6" :name "failed-worker" :status "failed"
                             :reason "commit your changes in the worktree first")
                       (list :child "c7" :name "cancelled-worker" :status "cancelled")
                       (list :child "c8" :name "older-worker" :status "merged"))))
      (puthash parent t harness-ui-merge--asked)
      (puthash parent view harness-ui-merge--views)
      (let ((panel (harness-ui-merge--panel)))
        (should panel)
        (should (string-match-p "Merge queue  4 live, 4 finished" panel))
        (should (string-match-p "queued-worker  queued (1 in line)" panel))
        (should (string-match-p "waiting-worker  queued (after its own merges, position 2)" panel))
        (should (string-match-p "merging-worker  merging now" panel))
        (should (string-match-p "conflict-worker  conflict: README" panel))
        (should (string-match-p "merged-worker  merged" panel))
        (should (string-match-p "failed-worker  failed: commit your changes in the worktree first" panel))
        ;; Only the first `harness-ui-merge--finished-limit' finished ones
        ;; show, oldest counted.
        (should (string-match-p "cancelled-worker  cancelled" panel))
        (should-not (string-match-p "older-worker" panel))
        (should (string-match-p "1 more" panel))
        ;; The panel's own face names are all real.
        (should-not (harness-ui-merge-test--undefined-faces panel)))
      ;; Nothing merging and nothing finished: no panel at all.
      (remhash parent harness-ui-merge--views)
      (puthash parent t harness-ui-merge--asked)
      (should-not (harness-ui-merge--panel)))))

(provide 'harness-ui-merge-test)
;;; harness-ui-merge-test.el ends here
