;;; harness-ui-worktree-test.el --- Tests for the worktree list  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-worktree-branch-prefix)
(require 'harness-acp)

(defun harness-ui-worktree-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-ui-worktree-test--make-repo (base)
  "Create BASE/repo with one commit and a worktree; return (ROOT . WORKTREE)."
  (let* ((root (file-name-as-directory (expand-file-name "repo" base)))
         (wt (expand-file-name "wt-feature" base)))
    (make-directory root t)
    (harness-ui-worktree-test--git root "init" "-q" "-b" "main")
    (harness-ui-worktree-test--git root "config" "user.name" "Harness Test")
    (harness-ui-worktree-test--git root "config" "user.email" "test@example.invalid")
    (harness-ui-worktree-test--git root "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "README" root) (insert "hello\n"))
    (harness-ui-worktree-test--git root "add" "README")
    (harness-ui-worktree-test--git root "commit" "-q" "-m" "initial")
    (harness-ui-worktree-test--git root "worktree" "add" "-q" "-b" "feature/x" wt)
    (cons root (file-name-as-directory wt))))

(defmacro harness-ui-worktree-test-with (&rest body)
  "Load the state layer, ACP, the UI and the worktree list with a repo, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage worktree merge acp ui ui-worktree))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (let* ((harness-provider-demo--delay 0.005)
            (harness-acp-token nil)
            (default-directory dir)
            (repo (harness-ui-worktree-test--make-repo dir))
            (root (car repo))
            (wt (cdr repo)))
       (ignore root wt)
       (unwind-protect
           (progn ,@body)
         (when (get-buffer harness-ui-worktree--buffer-name) (kill-buffer harness-ui-worktree--buffer-name))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-worktree-test-same-p (a b)
  "Non-nil when A and B name the same directory."
  (string= (file-name-as-directory (file-truename a)) (file-name-as-directory (file-truename b))))

(defun harness-ui-worktree-test-open (root count)
  "Open the list for ROOT and wait until COUNT rows with status are shown."
  (harness-worktrees root)
  (set-buffer harness-ui-worktree--buffer-name)
  (harness-test-wait (lambda () (and (not harness-ui-worktree--loading)
                                     (= count (length harness-ui-worktree--worktrees))
                                     (= count (hash-table-count harness-ui-worktree--status))))
                     10 "worktree rows"))

(defun harness-ui-worktree-test-wait-rows (count)
  "Wait until the list shows COUNT rows with their status."
  (harness-test-wait (lambda () (and (not harness-ui-worktree--loading)
                                     (= count (length harness-ui-worktree--worktrees))
                                     (= count (hash-table-count harness-ui-worktree--status))))
                     10 "worktree rows"))

(defun harness-ui-worktree-test-goto (path)
  "Move point to the row of worktree PATH."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (and (tabulated-list-get-id) (harness-ui-worktree-test-same-p (tabulated-list-get-id) path))))
    (forward-line 1))
  (should-not (eobp)))

(defun harness-ui-worktree-test-mode-line ()
  "Return the text of `mode-line-process' (batch Emacs cannot format mode lines)."
  (mapconcat (lambda (x) (if (stringp x) (substring-no-properties x) "")) mode-line-process ""))

(defun harness-ui-worktree-test-column (name)
  "Return the text of column NAME on the current line."
  (let ((i (cl-position name tabulated-list-format :key #'car :test #'equal)))
    (substring-no-properties (aref (tabulated-list-get-entry) i))))

(ert-deftest harness-ui-worktree-rows-flags-and-status ()
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (should (derived-mode-p 'harness-ui-worktree-mode))
    ;; q buries the list rather than quitting its window.
    (should (eq #'harness-ui-quit-view (key-binding (kbd "q"))))
    (should (harness-ui-worktree-test-same-p root harness-ui-worktree--root))
    (harness-ui-worktree-test-goto root)
    (should (equal "main" (harness-ui-worktree-test-column "Branch")))
    (should (string-match-p "main" (harness-ui-worktree-test-column "Flags")))
    (should (string-match-p "clean" (harness-ui-worktree-test-column "Status")))
    (harness-ui-worktree-test-goto wt)
    (should (equal "feature/x" (harness-ui-worktree-test-column "Branch")))
    (should-not (string-match-p "main" (harness-ui-worktree-test-column "Flags")))
    (should (= 8 (length (harness-ui-worktree-test-column "Head"))))
    ;; Dirty shows after a refresh.
    (with-temp-file (expand-file-name "scratch" wt) (insert "x\n"))
    (harness-ui-worktree-refresh)
    (harness-ui-worktree-test-wait-rows 2)
    (harness-ui-worktree-test-goto wt)
    (should (string-match-p "dirty" (harness-ui-worktree-test-column "Status")))
    ;; Opening from inside a worktree resolves to the main root.
    (kill-buffer harness-ui-worktree--buffer-name)
    (harness-ui-worktree-test-open wt 2)
    (should (harness-ui-worktree-test-same-p root harness-ui-worktree--root))
    ;; The mode line carries a mouse target for every command.
    (let ((ml (harness-ui-worktree-test-mode-line)))
      (dolist (label '("new" "remove" "prune" "lock" "session" "fork" "merge"))
        (should (string-match-p label ml)))
      (dolist (seg mode-line-process)
        (when (and (stringp seg) (string-match-p "\\[" seg))
          (should (keymapp (get-text-property 0 'local-map seg)))
          (should (get-text-property 0 'help-echo seg)))))))

(ert-deftest harness-ui-worktree-status-fanout-bounded-and-coalesced ()
  "Hundreds of rows fetch their status a few at a time and redraw once."
  (harness-ui-worktree-test-with
    ;; The reload/reconnect hooks would fire a second load mid-test; isolate
    ;; this test to the status fan-out and redraw behaviour it measures.
    (unwind-protect
        (progn
          (remove-hook 'harness-ui-redraw-hook #'harness-ui-worktree--redraw-all)
          (remove-hook 'harness-ui-event-functions #'harness-ui-worktree--on-event)
          (let* ((n 200)
                 (main-path (harness-ui-worktree--dir root))
                 (paths (cons main-path
                              (cl-loop for i from 1 below n
                                       collect (file-name-as-directory (expand-file-name (format "wt-%d" i) dir)))))
                 (wts (mapcar (lambda (p) (list :path p :branch "wt" :head "deadbeef" :main (equal p main-path)))
                              paths))
                 (in-flight 0) (max-inflight 0) (arrived 0) (prints 0)
                 (orig-print (symbol-function 'tabulated-list-print)))
            (cl-letf (((symbol-function 'tabulated-list-print)
                       (lambda (&rest args) (cl-incf prints) (apply orig-print args)))
                      ((symbol-function 'harness-ui-call)
                       (lambda (method params callback &optional _on-error)
                         (pcase method
                           ("_harness/worktree/root-of" (funcall callback main-path))
                           ("_harness/worktree/list" (funcall callback wts))
                           ("_harness/worktree/status"
                            (cl-incf in-flight)
                            (setq max-inflight (max max-inflight in-flight))
                            (run-at-time 0 nil
                                         (lambda ()
                                           (cl-decf in-flight)
                                           (cl-incf arrived)
                                           (funcall callback (list :dirty nil :ahead 0 :behind 0 :branch "wt")))))
                           (_ (funcall callback nil))))))
              (harness-worktrees root)
              (set-buffer harness-ui-worktree--buffer-name)
              (harness-test-wait (lambda () (= n (length harness-ui-worktree--worktrees))) 10 "rows")
              (harness-test-wait
               (lambda () (and (= n arrived)
                               (= n (hash-table-count harness-ui-worktree--status))))
               10 "statuses")
              (should (= harness-ui-worktree--status-concurrency max-inflight))
              (should (< prints 10))
              ;; A stale generation is ignored: a reload's answer must not overwrite.
              (cl-incf harness-ui-worktree--status-generation)
              (harness-ui-worktree--status-arrived
               (current-buffer) 0 main-path (list :dirty t :ahead 1 :behind 0 :branch "wt"))
              (should-not (plist-get (gethash main-path harness-ui-worktree--status) :dirty)))))
      (add-hook 'harness-ui-redraw-hook #'harness-ui-worktree--redraw-all)
      (add-hook 'harness-ui-event-functions #'harness-ui-worktree--on-event))))

(ert-deftest harness-ui-worktree-sessions-create-remove-prune ()
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    ;; A new session in the worktree at point gets it as cwd and worktree.
    (harness-ui-worktree-test-goto wt)
    (harness-ui-worktree-new-session)
    (let ((s (harness-test-wait (lambda () (cl-find-if (lambda (s) (and (plist-get s :worktree)
                                                                          (harness-ui-worktree-test-same-p wt (plist-get s :worktree))))
                                                        (harness-call 'session/list)))
                                5 "session in worktree")))
      (should (harness-ui-worktree-test-same-p wt (plist-get s :cwd)))
      (harness-test-wait (lambda () (progn (harness-ui-worktree-test-goto wt)
                                           (string-match-p "unnamed" (harness-ui-worktree-test-column "Sessions"))))
                         5 "sessions column"))
    ;; Create through the command with the prompt stubbed.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "feature/y")))
      (call-interactively #'harness-ui-worktree-create))
    (harness-ui-worktree-test-wait-rows 3)
    (let ((new (cl-find "feature/y" harness-ui-worktree--worktrees :key (lambda (w) (plist-get w :branch)) :test #'equal)))
      (should new)
      (should (file-directory-p (plist-get new :path)))
      ;; Removing a dirty worktree fails, then succeeds when forcing is accepted.
      (with-temp-file (expand-file-name "dirty" (plist-get new :path)) (insert "x\n"))
      (harness-ui-worktree-test-goto (plist-get new :path))
      (let ((asked-force nil))
        ;; The force question is asked from the request's error callback, so the
        ;; stubs must stay in place while waiting.
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked-force (string-match-p "force" prompt)) t)))
          (harness-ui-worktree-remove)
          (harness-ui-worktree-test-wait-rows 2))
        (should asked-force)
        (should-not (file-exists-p (plist-get new :path)))))
    ;; An empty answer has the harness name the branch, with its prefix.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (call-interactively #'harness-ui-worktree-create))
    (harness-ui-worktree-test-wait-rows 3)
    (let ((named (cl-find-if (lambda (w) (string-prefix-p harness-worktree-branch-prefix
                                                          (or (plist-get w :branch) "")))
                             harness-ui-worktree--worktrees)))
      (should named)
      (harness-ui-worktree-test-goto (plist-get named :path))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (harness-ui-worktree-remove)
        (harness-ui-worktree-test-wait-rows 2)))
    ;; The main worktree refuses to be removed.
    (harness-ui-worktree-test-goto root)
    (should-error (harness-ui-worktree-remove) :type 'user-error)
    ;; Prune drops a worktree deleted behind git's back.
    (let ((gone (expand-file-name "wt-gone" dir)))
      (harness-ui-worktree-test--git root "worktree" "add" "-q" "-b" "gone" gone)
      (harness-ui-worktree-refresh)
      (harness-ui-worktree-test-wait-rows 3)
      (delete-directory gone t)
      (harness-ui-worktree-prune)
      (harness-ui-worktree-test-wait-rows 2))))

(ert-deftest harness-ui-worktree-locked-rows ()
  "A locked worktree says so; prune keeps it, saying why; d removes it all the same."
  (harness-ui-worktree-test-with
    (let ((locked (plist-get (harness-test-await (harness-call 'worktree/create root :branch "task/locked")) :path))
          (shown nil))
      (harness-ui-worktree-test-open root 3)
      (harness-ui-worktree-test-goto locked)
      (should (string-match-p "locked" (harness-ui-worktree-test-column "Flags")))
      (let* ((flags (aref (tabulated-list-get-entry)
                          (cl-position "Flags" tabulated-list-format :key #'car :test #'equal)))
             (help (get-text-property (string-match "locked" flags) 'help-echo flags)))
        (should (string-match-p "harness: task/locked" help))
        (should (string-match-p "prune" help)))
      ;; Its directory gone, the prune keeps it and says so.
      (delete-directory locked t)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) shown))))
        (harness-ui-worktree-prune)
        (harness-test-wait (lambda () (cl-some (lambda (m) (string-match-p "\\`Kept .*task-locked" m)) shown))
                           10 "the prune message"))
      (harness-ui-worktree-test-wait-rows 3)
      (harness-ui-worktree-test-goto locked)
      (should (string-match-p "locked missing" (harness-ui-worktree-test-column "Flags")))
      ;; d asks, mentioning the lock, and removes it without forcing.
      (let ((asked nil) (asked-force nil))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) t))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked-force t) t)))
          (harness-ui-worktree-remove)
          (harness-ui-worktree-test-wait-rows 2))
        (should (string-match-p "locked: harness: task/locked" asked))
        (should-not asked-force)))))

(ert-deftest harness-ui-worktree-lock-keys ()
  "l locks or unlocks the worktree at point; L locks the harness's worktrees that have none."
  (harness-ui-worktree-test-with
    (let ((old (expand-file-name ".worktrees/old" root)))
      ;; Made as before locks, in the harness's worktree directory.
      (harness-ui-worktree-test--git root "worktree" "add" "-q" "-b" "task/old" old)
      (harness-ui-worktree-test-open root 3)
      (cl-flet ((flags (path) (harness-ui-worktree-test-goto path) (harness-ui-worktree-test-column "Flags")))
        (should-not (string-match-p "locked" (flags old)))
        ;; L locks it, but not the foreign worktree outside that directory.
        (harness-ui-worktree-lock-existing)
        (harness-test-wait (lambda () (and (harness-ui-worktree-test-wait-rows 3) (string-match-p "locked" (flags old))))
                           10 "the lock")
        (should-not (string-match-p "locked" (flags wt)))
        ;; l unlocks it after asking, and locks it again.
        (harness-ui-worktree-test-goto old)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (should (string-match-p "harness: task/old" prompt)) t)))
          (harness-ui-worktree-toggle-lock))
        (harness-test-wait (lambda () (and (harness-ui-worktree-test-wait-rows 3) (not (string-match-p "locked" (flags old)))))
                           10 "the unlock")
        (harness-ui-worktree-test-goto wt)
        (harness-ui-worktree-toggle-lock)
        (harness-test-wait (lambda () (and (harness-ui-worktree-test-wait-rows 3) (string-match-p "locked" (flags wt))))
                           10 "the lock at point")
        (should (equal "locked harness: feature/x"
                       (seq-find (lambda (l) (string-prefix-p "locked" l))
                                 (split-string (harness-ui-worktree-test--git root "worktree" "list" "--porcelain") "\n"))))
        (harness-ui-worktree-test-goto root)
        (should-error (harness-ui-worktree-toggle-lock) :type 'user-error)))))

(ert-deftest harness-ui-worktree-prune-merged-key ()
  "P removes the worktrees whose work merged, after asking; a no keeps them."
  (harness-ui-worktree-test-with
    (let* ((merged (plist-get (harness-test-await (harness-call 'worktree/create root :branch "task/merged")) :path))
           (asked nil) (messages nil))
      ;; Unlocked, as the merge queue leaves a merged worktree, and at the
      ;; repository's HEAD: git ancestry says it merged.
      (harness-test-await (harness-call 'worktree/unlock root merged))
      ;; The other worktree (at the repository's HEAD as well) has local
      ;; changes, so it is no candidate and the working copy is left alone.
      (with-temp-file (expand-file-name "scratch" wt) (insert "x\n"))
      (harness-ui-worktree-test-open root 3)
      (should (string-match-p "\\[P merged\\]" (harness-ui-worktree-test-mode-line)))
      (should (eq (lookup-key harness-ui-worktree-mode-map (kbd "P"))
                  #'harness-ui-worktree-prune-merged))
      ;; A no leaves the worktree alone.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) nil)))
        (harness-ui-worktree-prune-merged)
        (harness-test-wait (lambda () asked) 5 "the question"))
      (should (string-match-p "Remove 1 worktree" asked))
      (should (string-match-p "task-merged" asked))
      (should (file-directory-p merged))
      ;; A yes removes it and reloads the list.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (harness-ui-worktree-prune-merged)
        (harness-ui-worktree-test-wait-rows 2))
      (should-not (file-exists-p merged))
      (should (file-directory-p wt))
      (should (cl-some (lambda (m) (string-match-p "Removed 1 merged worktree" m)) messages))
      ;; Nothing merged left to remove: it says so and asks nothing.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "should not ask")))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (harness-ui-worktree-prune-merged)
        (harness-test-wait (lambda () (cl-some (lambda (m) (string-match-p "No merged worktrees" m)) messages))
                           5 "the empty message")))))

(defvar worktree-assume-mode)
(declare-function worktree-assume "worktree-assume" (worktree &optional project))
(declare-function worktree-assume-assumed "worktree-assume" (&optional dir))
(declare-function worktree-assume-reset "worktree-assume" (&optional project))
(declare-function worktree-assume-mode "worktree-assume" (&optional arg))

(ert-deftest harness-ui-worktree-assume-keys ()
  "a assumes the worktree at point as the project, r resets it to the main worktree.
The row says it is assumed while it is, and the mode line offers the
reset then; the main worktree is the project already, so there is
nothing to assume there."
  (harness-ui-worktree-test-with
    (unwind-protect
        (progn
          (harness-ui-worktree-test-open root 2)
          (should (eq (lookup-key harness-ui-worktree-mode-map (kbd "a")) #'harness-ui-worktree-assume))
          (should (eq (lookup-key harness-ui-worktree-mode-map (kbd "r")) #'harness-ui-worktree-assume-reset))
          (should (string-match-p "\\[a assume\\]" (harness-ui-worktree-test-mode-line)))
          (should-not (string-match-p "reset" (harness-ui-worktree-test-mode-line)))
          ;; The main worktree: nothing to assume, nothing assumed to reset.
          (harness-ui-worktree-test-goto root)
          (should-error (harness-ui-worktree-assume) :type 'user-error)
          (should-error (harness-ui-worktree-assume-reset) :type 'user-error)
          ;; a on the other one.
          (harness-ui-worktree-test-goto wt)
          (should-not (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
          (call-interactively (key-binding (kbd "a")))
          (should worktree-assume-mode)
          (should (harness-ui-worktree-test-same-p wt (worktree-assume-assumed root)))
          (should (harness-ui-worktree-test-same-p wt (project-root (project-current nil root))))
          (harness-ui-worktree-test-goto wt)
          (should (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
          (should (string-match-p "\\[r reset\\]" (harness-ui-worktree-test-mode-line)))
          (harness-ui-worktree-test-goto root)
          (should-not (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
          ;; The harness still has the project.
          (should (harness-ui-worktree-test-same-p root (harness-files-project-root root)))
          (should (harness-ui-worktree-test-same-p root (harness-files-main-root root)))
          ;; r resets, wherever point is.
          (call-interactively (key-binding (kbd "r")))
          (should-not (worktree-assume-assumed root))
          (should (harness-ui-worktree-test-same-p root (project-root (project-current nil root))))
          (harness-ui-worktree-test-goto wt)
          (should-not (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
          (should-not (string-match-p "reset" (harness-ui-worktree-test-mode-line)))
          (should-error (harness-ui-worktree-assume-reset) :type 'user-error)
          ;; A worktree whose directory is gone cannot be assumed.
          (delete-directory wt t)
          (should-error (harness-ui-worktree-assume) :type 'user-error)
          (should-not (worktree-assume-assumed root)))
      (worktree-assume-mode -1))))

(ert-deftest harness-ui-worktree-redraws-when-a-worktree-is-assumed-from-elsewhere ()
  "The list shows an assumption made or reset by anything else, the card menu say."
  (harness-ui-worktree-test-with
    (unwind-protect
        (progn
          (harness-ui-worktree-test-open root 2)
          (worktree-assume wt root)
          (harness-ui-worktree-test-goto wt)
          (should (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
          (should (string-match-p "reset" (harness-ui-worktree-test-mode-line)))
          (worktree-assume-reset root)
          (harness-ui-worktree-test-goto wt)
          (should-not (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
          (should-not (string-match-p "reset" (harness-ui-worktree-test-mode-line)))
          ;; Nothing breaks without a list to redraw.
          (kill-buffer harness-ui-worktree--buffer-name)
          (worktree-assume wt root)
          (worktree-assume-reset root))
      (worktree-assume-mode -1))))

(ert-deftest harness-ui-worktree-reset-resets-what-the-rows-show ()
  "r resets an assumption between two linked worktrees, which a row shows as assumed.
`worktree-assume' made it elsewhere, from a buffer of the one worktree for
the other: the list is of the repository, so it resets it as well."
  (harness-ui-worktree-test-with
    (let ((other (expand-file-name ".worktrees/other" root)))
      (harness-ui-worktree-test--git root "worktree" "add" "-q" "-b" "task/other" other)
      (unwind-protect
          (progn
            (harness-ui-worktree-test-open root 3)
            (should-not (harness-ui-worktree--assumptions))
            (worktree-assume other wt)
            (harness-ui-worktree-test-goto other)
            (should (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
            (should (string-match-p "\\[r reset\\]" (harness-ui-worktree-test-mode-line)))
            (should (equal 1 (length (harness-ui-worktree--assumptions))))
            ;; The main worktree is the project still, with nothing of its own to reset.
            (harness-ui-worktree-test-goto root)
            (should-error (harness-ui-worktree-assume) :type 'user-error)
            (call-interactively (key-binding (kbd "r")))
            (should-not (worktree-assume-assumptions))
            (harness-ui-worktree-test-goto other)
            (should-not (string-match-p "assumed" (harness-ui-worktree-test-column "Flags")))
            (should-not (string-match-p "reset" (harness-ui-worktree-test-mode-line)))
            (should-error (harness-ui-worktree-assume-reset) :type 'user-error))
        (worktree-assume-mode -1)))))

(ert-deftest harness-ui-worktree-reset-leaves-another-repositorys-assumption-alone ()
  "A repository below the main checkout has its own assumptions, which r does not reset."
  (harness-ui-worktree-test-with
    (let* ((inner (file-name-as-directory (expand-file-name "vendor/inner" root)))
           (inner-wt (file-name-as-directory (expand-file-name "../inner-wt" inner))))
      (make-directory inner t)
      (harness-ui-worktree-test--git inner "init" "-q" "-b" "main")
      (harness-ui-worktree-test--git inner "config" "user.name" "Harness Test")
      (harness-ui-worktree-test--git inner "config" "user.email" "test@example.invalid")
      (harness-ui-worktree-test--git inner "config" "commit.gpgsign" "false")
      (with-temp-file (expand-file-name "README" inner) (insert "inner\n"))
      (harness-ui-worktree-test--git inner "add" "README")
      (harness-ui-worktree-test--git inner "commit" "-q" "-m" "initial")
      (harness-ui-worktree-test--git inner "worktree" "add" "-q" "-b" "inner-wt" inner-wt)
      (unwind-protect
          (progn
            (harness-ui-worktree-test-open root 2)
            (worktree-assume inner-wt inner)
            (should (worktree-assume-assumed inner))
            ;; Not this repository's: nothing to reset, no [r reset], and r says so.
            (should-not (harness-ui-worktree--assumptions))
            (should-not (string-match-p "reset" (harness-ui-worktree-test-mode-line)))
            (should-error (harness-ui-worktree-assume-reset) :type 'user-error)
            (should (worktree-assume-assumed inner))
            ;; This repository's own is reset, the other stays.
            (worktree-assume wt root)
            (should (equal 1 (length (harness-ui-worktree--assumptions))))
            (harness-ui-worktree-assume-reset)
            (should-not (worktree-assume-assumed root))
            (should (worktree-assume-assumed inner)))
        (worktree-assume-mode -1)))))

(ert-deftest harness-ui-worktree-fork-and-merge-queue ()
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (let* ((parent (harness-call 'session/create :cwd root :model "demo:scripted" :name "Parent"))
           (pid (plist-get parent :id)))
      ;; f: fork the current session into a new worktree.
      (cl-letf (((symbol-function 'harness-ui-display-session) #'ignore))
        (harness-ui-worktree-fork-session pid "feature/fork"))
      (harness-ui-worktree-test-wait-rows 3)
      (let* ((wt2 (cl-find "feature/fork" harness-ui-worktree--worktrees :key (lambda (w) (plist-get w :branch)) :test #'equal))
             (path (plist-get wt2 :path))
             (child (cl-find-if (lambda (s) (equal (plist-get s :parent-id) pid)) (harness-call 'session/list))))
        (should child)
        (should (harness-ui-worktree-test-same-p path (plist-get child :worktree)))
        (should (harness-ui-worktree-test-same-p path (plist-get child :cwd)))
        (harness-test-wait (lambda () (harness-ui-session (plist-get child :id))) 5 "session cached")
        ;; m: queue the child for merging into the parent; the queue shows in the mode line.
        (harness-ui-worktree-test-goto path)
        (harness-ui-worktree-merge)
        (harness-test-wait (lambda () harness-ui-worktree--queue) 5 "merge queue")
        (should (equal pid (car harness-ui-worktree--queue)))
        (should (string-match-p "merge queue" (harness-ui-worktree-test-mode-line)))))))

(ert-deftest harness-ui-worktree-sessions-leave-out-internal-ones ()
  "The sessions of a worktree are the user's: an internal session working there is none.
The harness records each model call it makes on its own as an internal
session, made for a session, living where it does and having it as its
parent.  The sessions column does not name one, and the merge key does
not take it for a forked session of the worktree: with the one fork it
queues that, without asking which."
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (let* ((parent (harness-call 'session/create :cwd root :model "demo:scripted" :name "Parent"))
           (pid (plist-get parent :id))
           (child (harness-call 'session/create :cwd wt :model "demo:scripted" :name "Feature worker"
                                :parent-id pid))
           (cid (plist-get child :id))
           (jid (harness-call 'session/internal-start :job "Permission judge" :model "demo:scripted"
                              :parent-id cid :prompt "May it run ls?"))
           (enqueued nil)
           (real (symbol-function 'harness-ui-call)))
      (let (done)
        (harness-ui-refresh-sessions (lambda (_) (setq done t)))
        (harness-test-wait (lambda () done) 5 "the sessions"))
      (should (equal "internal" (format "%s" (plist-get (harness-ui-session jid) :kind))))
      ;; The judge lives in the worktree, with the fork as its parent.
      (should (harness-ui-worktree-test-same-p wt (plist-get (harness-ui-session jid) :cwd)))
      (should (equal (list cid) (mapcar (lambda (s) (plist-get s :id)) (harness-ui-worktree--sessions-in wt))))
      (should (string-match-p "Feature worker" (harness-ui-worktree--sessions-label wt)))
      (should-not (string-match-p "Permission judge" (harness-ui-worktree--sessions-label wt)))
      ;; The merge key: one fork there, so no question.
      (harness-ui-worktree-test-goto wt)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "The merge key asked which session")))
                ((symbol-function 'harness-ui-call)
                 (lambda (method params &rest rest)
                   (if (equal method "_harness/merge/enqueue")
                       (push params enqueued)
                     (apply real method params rest)))))
        (harness-ui-worktree-merge))
      (should (equal (list (list :child-id cid :target pid)) enqueued)))))

;;;; The cost of a redraw, and who pays it

;; The sessions column once asked `file-truename' twice per session for
;; every row, on every redraw, and redrew the list (shown or not) for every
;; change of the session cache: with 1,300 sessions and a list of 4 rows
;; that was 1.5 s of the UI thread, over and over, for a buffer no window
;; showed.  Nothing here measures time, which a loaded machine would
;; turn into a flaky test: the calls and the redraws are counted.

(defvar harness-ui-worktree-test--in-truename nil
  "Non-nil inside the `file-truename' call `harness-ui-worktree-test--truenames' counts.")

(defun harness-ui-worktree-test--truenames (fn)
  "Call FN; return the names it asked `file-truename' about, oldest first.
`file-truename' calls itself for the parts of a name: those are not counted."
  (let ((names nil))
    (advice-add 'file-truename :around
                (lambda (orig &rest args)
                  (if harness-ui-worktree-test--in-truename
                      (apply orig args)
                    (push (car args) names)
                    (let ((harness-ui-worktree-test--in-truename t))
                      (apply orig args))))
                '((name . harness-ui-worktree-test-truenames)))
    (unwind-protect (funcall fn)
      (advice-remove 'file-truename 'harness-ui-worktree-test-truenames))
    (nreverse names)))

(defun harness-ui-worktree-test--session (n cwd &rest props)
  "Cache session number N working in CWD, with PROPS; return it.
The higher N, the older the session."
  (let ((session (append props (list :id (format "wt-test-%04d" n) :name (format "Session %d" n)
                                     :kind "main" :status "idle" :cwd cwd :updated (- 100000 n)))))
    (puthash (plist-get session :id) session harness-ui--sessions)
    session))

(defun harness-ui-worktree-test--pending-for (buffer)
  "Return the keys of the debounced calls still waiting to do something to BUFFER.
Other tests' leftovers, which the same keys may hold, are not BUFFER's."
  (let (keys)
    (maphash (lambda (key timer)
               (when (and (timerp timer) (memq buffer (timer--args timer)))
                 (push key keys)))
             harness--debounce-timers)
    keys))

(defun harness-ui-worktree-test--settle (buffer)
  "Fire the debounced redraws scheduled for BUFFER."
  (let ((count 0) keys)
    (while (setq keys (harness-ui-worktree-test--pending-for buffer))
      (should (< (cl-incf count) 100))
      (dolist (key keys) (harness-test-fire-debounce key)))))

(defun harness-ui-worktree-test--sync-sessions ()
  "Wait for the harness's sessions to reach the cache, which they replace.
Sessions cached by hand go when they do, so a test caches its own after."
  (let (done)
    (harness-ui-refresh-sessions (lambda (_) (setq done t)))
    (harness-test-wait (lambda () done) 10 "the sessions")))

(defun harness-ui-worktree-test--ids-in (path)
  "Return the numbers of the sessions that live in PATH, as the list shows them."
  (mapcar (lambda (s) (string-to-number (substring (plist-get s :id) -4)))
          (harness-ui-worktree--sessions-in path)))

(ert-deftest harness-ui-worktree-redraw-finds-a-true-name-per-directory ()
  "A redraw costs a true name per directory, not two per session for every row.
Hundreds of sessions in a few places and a few rows: the names are found
once, and not again on the redraws that follow."
  (harness-ui-worktree-test-with
    (let* ((places (cl-loop for i below 12
                            collect (let ((d (file-name-as-directory
                                              (expand-file-name (format "place-%d" i) dir))))
                                      (make-directory d t)
                                      d)))
           (n 0))
      (dotimes (i 600) (harness-ui-worktree-test--session (cl-incf n) (nth (mod i 12) places)))
      ;; The harness's own records are left out, and cost nothing.
      (dotimes (i 60) (harness-ui-worktree-test--session (cl-incf n) (nth (mod i 12) places)
                                                         :kind "internal"))
      (with-temp-buffer
        (harness-ui-worktree-mode)
        (setq harness-ui-worktree--root root
              harness-ui-worktree--worktrees
              (mapcar (lambda (d) (list :path d :branch "task/x" :head "0123456789abcdef"))
                      (cons root (seq-take places 4))))
        (clrhash harness-ui-worktree--true-names)
        (let ((first (harness-ui-worktree-test--truenames #'harness-ui-worktree--refresh-entries)))
          ;; The 12 places and the repository: with two per session per row it was 6,000.
          (should (<= (length first) 13))
          ;; Each row names its place's sessions, 50 in each.
          (let ((entry (cl-find (car places) tabulated-list-entries
                                :key #'car :test #'harness-ui-worktree--same-p)))
            (should (string-match-p "Session 1  .*Session 13  .*Session 25  .*\\+47 more"
                                    (substring-no-properties (aref (cadr entry) 5))))))
        ;; Redrawn as sessions change, it looks at no file at all.
        (should-not (harness-ui-worktree-test--truenames #'harness-ui-worktree--refresh-entries))))))

(ert-deftest harness-ui-worktree-sessions-live-in-their-worktree-else-their-cwd ()
  "A session lives in its worktree, else its working directory, by any spelling of the place.
A link to a directory is that directory, and so is the name with or
without its slash; the internal sessions are nobody's; a remote name is
only itself, and is never looked at: it would reach its host from the UI
thread."
  (harness-ui-worktree-test-with
    (let* ((a (file-name-as-directory (expand-file-name "a" dir)))
           (b (file-name-as-directory (expand-file-name "b" dir)))
           (link (expand-file-name "link-to-a" dir))
           (remote "/ssh:nowhere.invalid:/srv/a/"))
      (make-directory a)
      (make-directory b)
      (make-symbolic-link (directory-file-name a) link)
      (harness-ui-worktree-test--session 1 a)
      (harness-ui-worktree-test--session 2 link)
      (harness-ui-worktree-test--session 3 (directory-file-name a))
      ;; The worktree says where it lives, whatever its cwd says.
      (harness-ui-worktree-test--session 4 b :worktree a)
      (harness-ui-worktree-test--session 5 a :worktree b)
      (harness-ui-worktree-test--session 6 a :kind "internal")
      (harness-ui-worktree-test--session 7 remote)
      (harness-ui-worktree-test--session 8 nil)
      (let ((names (harness-ui-worktree-test--truenames
                    (lambda ()
                      ;; Newest first.
                      (should (equal '(1 2 3 4) (harness-ui-worktree-test--ids-in a)))
                      (should (equal '(5) (harness-ui-worktree-test--ids-in b)))
                      ;; The link is the place it points to.
                      (should (equal '(1 2 3 4) (harness-ui-worktree-test--ids-in link)))
                      (should (equal '(7) (harness-ui-worktree-test--ids-in remote)))
                      (should (equal '(7) (harness-ui-worktree-test--ids-in
                                           (directory-file-name remote))))))))
        (should names)
        (should-not (cl-some #'file-remote-p names))))))

(ert-deftest harness-ui-worktree-refresh-looks-at-links-again ()
  "Where a link points is remembered, until the list is refreshed by hand."
  (harness-ui-worktree-test-with
    (let* ((a (file-name-as-directory (expand-file-name "a" dir)))
           (b (file-name-as-directory (expand-file-name "b" dir)))
           (link (expand-file-name "link" dir)))
      (make-directory a)
      (make-directory b)
      (make-symbolic-link (directory-file-name a) link)
      (harness-ui-worktree-test-open root 2)
      (harness-ui-worktree-test--settle (get-buffer harness-ui-worktree--buffer-name))
      ;; After the harness's sessions have come, which replace these.
      (harness-ui-worktree-test--sync-sessions)
      (harness-ui-worktree-test--session 1 link)
      (should (equal '(1) (harness-ui-worktree-test--ids-in a)))
      (delete-file link)
      (make-symbolic-link (directory-file-name b) link)
      (should (equal '(1) (harness-ui-worktree-test--ids-in a)))
      (harness-ui-worktree-refresh)
      (harness-ui-worktree-test-wait-rows 2)
      (should-not (harness-ui-worktree-test--ids-in a))
      (should (equal '(1) (harness-ui-worktree-test--ids-in b))))))

(ert-deftest harness-ui-worktree-reload-gives-an-existing-list-the-show-hook ()
  "A list that was made before the harness reloaded catches up when shown too.
The mode function installs the hook on `window-buffer-change-functions',
and an old list never ran this version's; the module's init gives it."
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (let ((buf (get-buffer harness-ui-worktree--buffer-name)))
      (with-current-buffer buf
        (remove-hook 'window-buffer-change-functions #'harness-ui-worktree--shown t))
      (should-not (memq #'harness-ui-worktree--shown
                        (buffer-local-value 'window-buffer-change-functions buf)))
      (harness-ui-worktree--init)
      (should (memq #'harness-ui-worktree--shown
                    (buffer-local-value 'window-buffer-change-functions buf)))
      ;; Once, however often the harness reloads.
      (harness-ui-worktree--init)
      (should (= 1 (cl-count #'harness-ui-worktree--shown
                             (buffer-local-value 'window-buffer-change-functions buf)))))))

(ert-deftest harness-ui-worktree-redraws-only-for-the-sessions-it-shows ()
  "A change of the session cache that alters no row's sessions cell redraws nothing.
Tokens, costs and the harness's own records change by the second, and
drawing the rows of a repository with a worktree for each task takes a
tenth of a second or more.  A hidden list that missed such changes does
not redraw when shown either; one that missed a rename does."
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (let* ((buf (get-buffer harness-ui-worktree--buffer-name))
           (redraws 0)
           (redraw (symbol-function 'harness-ui-worktree--redraw)))
      (cl-flet ((cell () (harness-ui-worktree-test-goto wt)
                  (harness-ui-worktree-test-column "Sessions"))
                (changed (&optional (n 1))
                  (dotimes (_ n) (run-hooks 'harness-ui-sessions-changed-hook))
                  (harness-ui-worktree-test--settle buf)))
        (harness-ui-worktree-test--settle buf)
        (harness-ui-worktree-test--sync-sessions)
        (should (equal "" (cell)))
        (cl-letf (((symbol-function 'harness-ui-worktree--redraw)
                   (lambda (&rest args) (cl-incf redraws) (apply redraw args))))
          ;; A session appears in the worktree: its cell changes, so the list is drawn.
          (harness-ui-worktree-test--session 1 wt :name "Feature worker")
          (changed)
          (should (= 1 redraws))
          (should (string-match-p "Feature worker" (cell)))
          ;; Its tokens grow, the harness makes a model call of its own there, a
          ;; session elsewhere is born: no cell reads otherwise, so nothing is drawn.
          (setq redraws 0)
          (harness-ui-worktree-test--session 1 wt :name "Feature worker" :updated 123456789
                                             :usage (list :output-tokens 99))
          (harness-ui-worktree-test--session 2 wt :kind "internal")
          (harness-ui-worktree-test--session 3 root :kind "internal")
          (harness-ui-worktree-test--session 4 "/nowhere/else/")
          (changed 3)
          (should (= 0 redraws))
          ;; Hidden while a session in it is renamed: the list draws once, when it is
          ;; shown again.
          (switch-to-buffer (get-buffer-create "*elsewhere*"))
          (should-not (get-buffer-window buf t))
          (harness-ui-worktree-test--session 1 wt :name "Renamed worker")
          (changed 2)
          (should (= 0 redraws))
          (should (eq 'sessions (buffer-local-value 'harness-ui-worktree--stale buf)))
          (switch-to-buffer buf)
          (with-current-buffer buf (harness-ui-worktree--shown))
          (harness-ui-worktree-test--settle buf)
          (should (= 1 redraws))
          (should (string-match-p "Renamed worker" (cell)))
          ;; Hidden for changes that alter nothing: shown, it draws nothing.
          (setq redraws 0)
          (switch-to-buffer (get-buffer-create "*elsewhere*"))
          (harness-ui-worktree-test--session 4 "/nowhere/else/" :updated 987654321)
          (changed 2)
          (switch-to-buffer buf)
          (with-current-buffer buf (harness-ui-worktree--shown))
          (harness-ui-worktree-test--settle buf)
          (should (= 0 redraws))
          (should-not (buffer-local-value 'harness-ui-worktree--stale buf)))
        (ignore-errors (kill-buffer "*elsewhere*"))))))

(ert-deftest harness-ui-worktree-leaves-a-list-nobody-looks-at-alone ()
  "A list no window shows is neither redrawn nor reloaded; it catches up when shown.
The session cache changes many times a second while agents work, and
each change redrew the list, a timer on the UI thread, whether anyone saw
it or not.  What a hidden list missed is noted, and done once a window
shows it again: a redraw for sessions that changed, a reload for
worktrees that did."
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (let* ((buf (get-buffer harness-ui-worktree--buffer-name))
           (redraws 0)
           (loads 0)
           (redraw (symbol-function 'harness-ui-worktree--redraw))
           (load (symbol-function 'harness-ui-worktree--load)))
      (cl-flet ((hide () (switch-to-buffer (get-buffer-create "*elsewhere*"))
                  (should-not (get-buffer-window buf t)))
                (show () (switch-to-buffer buf)
                  ;; Redisplay runs this on `window-buffer-change-functions'.
                  (with-current-buffer buf (harness-ui-worktree--shown)))
                (stale () (buffer-local-value 'harness-ui-worktree--stale buf))
                (pending () (harness-ui-worktree-test--pending-for buf)))
        (should (memq #'harness-ui-worktree--shown
                      (buffer-local-value 'window-buffer-change-functions buf)))
        (should-not (stale))
        ;; The statuses and the session cache redraw the list a little after
        ;; it opens: let that be done before anything is counted.
        (harness-ui-worktree-test--settle buf)
        (harness-ui-worktree-test--sync-sessions)
        (unwind-protect
            (cl-letf (((symbol-function 'harness-ui-worktree--redraw)
                       (lambda (&rest args) (cl-incf redraws) (apply redraw args)))
                      ((symbol-function 'harness-ui-worktree--load)
                       (lambda (&rest args) (cl-incf loads) (apply load args))))
              ;; A list that is shown follows the sessions: one lives in a worktree now.
              (harness-ui-worktree-test--session 1 wt :name "Feature worker")
              (run-hooks 'harness-ui-sessions-changed-hook)
              (should (pending))
              (harness-ui-worktree-test--settle buf)
              (should (>= redraws 1))
              (should-not (stale))
              (harness-ui-worktree-test--settle buf)
              ;; Hidden, it is left alone: nothing is redrawn, and no timer is even started.
              (hide)
              (setq redraws 0)
              (harness-ui-worktree-test--session 1 wt :name "Renamed worker")
              (dotimes (_ 5) (run-hooks 'harness-ui-sessions-changed-hook))
              (should-not (pending))
              (should (eq 'sessions (stale)))
              ;; It says it is suspended, as every such view does, until it is shown.
              (should (equal "[Suspended: resume]"
                             (substring-no-properties (with-current-buffer buf (harness-ui-view-indicator)))))
              (harness-ui-worktree--on-assumed)
              (should-not (pending))
              (should (eq 'redraw (stale)))
              (should (= 0 redraws))
              (should (= 0 loads))
              ;; Shown again, it redraws: the sessions are all it missed.
              (show)
              (harness-ui-worktree-test--settle buf)
              (should (>= redraws 1))
              (should-not (stale))
              (should (equal "" (with-current-buffer buf (harness-ui-view-indicator))))
              (harness-ui-worktree-test--settle buf)
              (should (= 0 loads))
              ;; A worktree event, a merge, a reconnect while hidden: a reload is owed,
              ;; and nothing is started.
              (hide)
              (setq redraws 0)
              (harness-ui--run-event-functions "worktree/created" nil)
              (harness-ui--run-event-functions "merge/finished" nil)
              (run-hooks 'harness-ui-redraw-hook)
              (run-hooks 'harness-ui-sessions-changed-hook)
              (should-not (pending))
              (should (eq 'reload (stale)))
              (should (= 0 loads))
              (should (= 0 redraws))
              ;; Shown again, the list is fetched anew, once.
              (show)
              (harness-ui-worktree-test--settle buf)
              (should (= 1 loads))
              (should-not (stale))
              (harness-ui-worktree-test-wait-rows 2)
              (harness-ui-worktree-test--settle buf)
              (should (= 1 loads)))
          (ignore-errors (kill-buffer "*elsewhere*")))))))

(provide 'harness-ui-worktree-test)
;;; harness-ui-worktree-test.el ends here
