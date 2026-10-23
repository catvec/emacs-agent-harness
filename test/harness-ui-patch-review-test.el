;;; harness-ui-patch-review-test.el --- Tests for reviewing a task's changes in its report  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task's branch in a repository of its own: what it changes against
;; its merge base, the changes in the task's report, Ediff file by file
;; from there with the review's keys, the comments made on it as threads
;; of the library change-review -- kept by the harness, drawn under their
;; lines, placed in the newest version of their files -- and sending
;; them back to the task with its feedback.  The repositories are
;; throwaway ones, whose commits are never signed.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-links)
(require 'harness-ui)
(require 'harness-ui-patch-review)
;; Loaded up front, so the comment command's own `(require ...)' is a no-op
;; and the stubs below are what runs.
(require 'string-edit)

(defvar ediff-current-difference)
(defvar ediff-number-of-differences)
(defvar ediff-brief-help-message-function)
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
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-tasks--tasks)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-report-panel-functions)
(defvar harness-ui-report-max-height)
(defvar harness-ui-popout--max-height)
(defvar harness-ui-popout-min-height)
(defvar harness-patch-review--sets)
(defvar harness-ui-linking-handlers)
(defvar harness-ui-linking-context-functions)
(declare-function harness-ui-linking-follow "harness-ui-linking" (url))
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
(declare-function harness-ui-report-popout "harness-ui-report")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function ediff-toggle-split "ediff-util" ())

;;;; A repository with a task's branch

(defun harness-ui-patch-review-test--git (dir &rest args)
  "Run git with ARGS in DIR and return what it writes, trimmed."
  (with-temp-buffer
    (let* ((default-directory dir)
           (status (apply #'call-process "git" nil t nil args)))
      (unless (eql status 0)
        (error "git %s failed: %s" (string-join args " ") (buffer-string)))
      (string-trim (buffer-string)))))

(defun harness-ui-patch-review-test--write (dir name text)
  "Write TEXT, a string of characters or of bytes, to NAME under DIR."
  (let ((file (expand-file-name name dir))
        (coding-system-for-write (if (multibyte-string-p text) 'utf-8-unix 'no-conversion)))
    (make-directory (file-name-directory file) t)
    (write-region text nil file nil 'silent)))

(defun harness-ui-patch-review-test--numbered (name count &optional changes)
  "Return COUNT numbered lines setting NAME's variables.
CHANGES is an alist of LINE -> its text instead."
  (mapconcat (lambda (i) (concat (or (cdr (assq i changes)) (format "(setq %s%d %d)" name i i)) "\n"))
             (number-sequence 1 count) ""))

(defun harness-ui-patch-review-test--repo (&optional dir)
  "Make a repository whose branch task/fix a task made from main; return it.
It is DIR when given, an empty directory, else a new one.
On the branch: a.el changed in two places far apart, b.el deleted, c.el
renamed to d.el and changed, docs/é.txt and new.el added, img.bin, a
binary file, changed.  Main went on after: keep.el changed there."
  (let ((repo (or dir (harness-test-temp-dir)))
        (git #'harness-ui-patch-review-test--git)
        (write #'harness-ui-patch-review-test--write))
    (funcall git repo "init" "-q" "-b" "main")
    (funcall git repo "config" "user.name" "Harness Test")
    (funcall git repo "config" "user.email" "test@example.invalid")
    ;; Throwaway commits are never signed: no prompt for a key.
    (funcall git repo "config" "commit.gpgsign" "false")
    (funcall write repo "a.el" (harness-ui-patch-review-test--numbered "a" 20))
    (funcall write repo "b.el" (harness-ui-patch-review-test--numbered "b" 5))
    (funcall write repo "c.el" (harness-ui-patch-review-test--numbered "c" 12))
    (funcall write repo "img.bin" (unibyte-string 137 80 78 71 0 1 2 3 0 255))
    (funcall write repo "keep.el" (harness-ui-patch-review-test--numbered "keep" 3))
    (funcall git repo "add" "-A")
    (funcall git repo "commit" "-q" "-m" "The start")
    (funcall git repo "checkout" "-q" "-b" "task/fix")
    (funcall write repo "a.el" (harness-ui-patch-review-test--numbered
                                "a" 20 '((2 . "(setq a2 'two)") (18 . "(setq a18 'eighteen)"))))
    (delete-file (expand-file-name "b.el" repo))
    (delete-file (expand-file-name "c.el" repo))
    (funcall write repo "d.el" (harness-ui-patch-review-test--numbered "c" 12 '((6 . "(setq c6 'six)"))))
    (funcall write repo "docs/é.txt" "héllo\n")
    (funcall write repo "new.el" (harness-ui-patch-review-test--numbered "new" 3))
    (funcall write repo "img.bin" (unibyte-string 137 80 78 71 0 1 2 4 0 254))
    (funcall git repo "add" "-A")
    (funcall git repo "commit" "-q" "-m" "Fix it")
    (funcall git repo "checkout" "-q" "main")
    (funcall write repo "keep.el" (harness-ui-patch-review-test--numbered "keep" 3 '((1 . "(setq keep1 'kept)"))))
    (funcall git repo "commit" "-q" "-am" "Main goes on")
    repo))

(defun harness-ui-patch-review-test--task (repo &rest plist)
  "Return a task in review on branch task/fix of REPO, as the UI has it.
PLIST goes first, so it wins."
  (append plist (list :id "t-patch" :name "Fix the flaky test" :state "review"
                      :branch "task/fix" :base "main" :project repo)))

(defun harness-ui-patch-review-test--review (repo)
  "Return a review of task/fix in REPO, its branch read."
  (let ((review (harness-ui-patch-review--review-for (harness-ui-patch-review-test--task repo))))
    (harness-test-await (harness-ui-patch-review--load review))
    (should-not (harness-ui-patch-review--r-error review))
    review))

(defun harness-ui-patch-review-test--file (review path)
  "Return the file of REVIEW at PATH."
  (or (cl-find path (harness-ui-patch-review--r-files review)
               :key #'change-review-file-path :test #'equal)
      (error "No %s in the review" path)))

(defun harness-ui-patch-review-test--comment-on (review path where text &rest keys)
  "Comment on WHERE of the file PATH of REVIEW's set with TEXT; return the comment.
WHERE is (SIDE . LINE) or nil.  KEYS are those of `change-review-comment'."
  (apply #'change-review-comment (harness-ui-patch-review--r-set review) text
         :location (harness-ui-patch-review--location
                    (harness-ui-patch-review-test--file review path) where)
         :author (change-review-user "Noah" "noah@example.org")
         keys))

(defun harness-ui-patch-review-test--thread-of (review comment)
  "Return the thread of REVIEW's set that holds COMMENT."
  (car (change-review-find-comment (harness-ui-patch-review--r-set review)
                                   (change-review-comment-id comment))))

(defun harness-ui-patch-review-test--advance (repo)
  "Commit a change on task/fix of REPO that moves and edits lines of a.el.
Three lines go in at the top and the second one is edited."
  (harness-ui-patch-review-test--git repo "checkout" "-q" "task/fix")
  (harness-ui-patch-review-test--write
   repo "a.el" (concat "(setq top1 1)\n(setq top2 2)\n(setq top3 3)\n"
                       (harness-ui-patch-review-test--numbered
                        "a" 20 '((2 . "(setq a2 'three)") (18 . "(setq a18 'eighteen)")))))
  (harness-ui-patch-review-test--git repo "commit" "-q" "-am" "Again"))

(defun harness-ui-patch-review-test--text (buffer)
  "BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defmacro harness-ui-patch-review-test-with-repo (&rest body)
  "Run BODY with `repo', a repository with a task's branch; clean up after.
The reviews made go, their buffers too, and the frame has one window."
  (declare (indent 0))
  `(let ((repo (harness-ui-patch-review-test--repo))
         (harness-ui-connection-address nil))
     ;; A batch frame takes its menu bar's line off at the first wait for
     ;; output: before BODY saves a window configuration to compare with.
     (accept-process-output nil 0)
     (unwind-protect
         ;; The operations a review sends the harness go nowhere: there is none.
         (cl-letf (((symbol-function 'harness-ui-request)
                    (lambda (&rest _) (harness-make-promise))))
           ,@body)
       (maphash (lambda (_id review) (harness-ui-patch-review--forget review))
                (copy-hash-table harness-ui-patch-review--reviews))
       (clrhash harness-ui-patch-review--reviews)
       (delete-other-windows)
       (ignore-errors (delete-directory repo t)))))

;;;; Reading the branch

(ert-deftest harness-ui-patch-review-reads-the-branch-against-its-merge-base ()
  "The files are those the branch changes since its merge base with main:
main's own commits after it are not the task's."
  (harness-ui-patch-review-test-with-repo
    (let ((result (harness-test-await (harness-ui-patch-review--read-branch repo "task/fix" "main" repo))))
      (should (equal (plist-get result :merge-base)
                     (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix")))
      (should-not (equal (plist-get result :merge-base) (harness-ui-patch-review-test--git repo "rev-parse" "main")))
      (should (equal (plist-get result :tip) (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
      (should (equal "main" (plist-get result :base)))
      (should-not (plist-get result :dirty))
      (let ((files (plist-get result :files)))
        ;; In the diff's order.
        (should (equal '("a.el" "b.el" "d.el" "docs/é.txt" "img.bin" "new.el")
                       (mapcar #'change-review-file-path files)))
        (pcase-dolist (`(,path ,status ,old-path ,added ,deleted ,binary)
                       '(("a.el" "M" nil 2 2 nil) ("b.el" "D" nil 0 5 nil) ("d.el" "R" "c.el" 1 1 nil)
                         ("docs/é.txt" "A" nil 1 0 nil) ("new.el" "A" nil 3 0 nil) ("img.bin" "M" nil 0 0 t)))
          (let ((file (cl-find path files :key #'change-review-file-path :test #'equal)))
            (ert-info ((format "%s" path))
              (should (equal status (change-review-file-status file)))
              (should (equal old-path (change-review-file-old-path file)))
              (should (= added (change-review-file-added file)))
              (should (= deleted (change-review-file-deleted file)))
              (should (eq binary (change-review-file-binary file)))
              ;; Each file has its own part of the diff.
              (should (string-prefix-p (format "diff --git a/%s b/%s\n" (or old-path path) path)
                                       (change-review-file-patch file))))))
        ;; No blob for the side a file is not on.
        (let ((deleted (cl-find "b.el" files :key #'change-review-file-path :test #'equal))
              (added (cl-find "new.el" files :key #'change-review-file-path :test #'equal)))
          (should (change-review-file-old-blob deleted))
          (should-not (change-review-file-new-blob deleted))
          (should-not (change-review-file-old-blob added))
          (should (equal "(setq new1 1)\n(setq new2 2)\n(setq new3 3)\n"
                         (harness-test-await (harness-ui-patch-review--blob
                                              (harness-ui-patch-review--review-create :dir repo)
                                              (change-review-file-new-blob added))))))))
    ;; A change not committed in the worktree is not on the branch: said so.
    (harness-ui-patch-review-test--write repo "keep.el" "(setq keep1 'dirty)\n")
    (should (plist-get (harness-test-await (harness-ui-patch-review--read-branch repo "task/fix" "main" repo))
                       :dirty))))

(ert-deftest harness-ui-patch-review-reads-what-it-can ()
  "A base that is not there is HEAD's; a branch that is not there says so."
  (harness-ui-patch-review-test-with-repo
    (let ((result (harness-test-await (harness-ui-patch-review--read-branch repo "task/fix" "gone"))))
      (should (equal "HEAD" (plist-get result :base)))
      (should (equal (plist-get result :merge-base)
                     (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix"))))
    (let ((err (should-error (harness-test-await (harness-ui-patch-review--read-branch repo "task/nope" "main")))))
      (should (string-match-p "There is no branch .task/nope." (error-message-string err))))
    ;; A review that cannot read its branch says why.
    (let ((review (harness-ui-patch-review--review-create
                   :id "t-patch" :task (harness-ui-patch-review-test--task repo :branch "task/nope"))))
      (harness-test-await (harness-ui-patch-review--load review))
      (should (string-match-p "There is no branch" (harness-ui-patch-review--r-error review)))
      (should-not (harness-ui-patch-review--r-loading review))
      (should (cl-some (lambda (note) (string-match-p "Could not read the branch: There is no branch" note))
                       (harness-ui-patch-review--notes review))))))

(ert-deftest harness-ui-patch-review-is-offered-where-the-branch-can-be-read ()
  "Only for a task in review with a branch, in a repository of this machine."
  (harness-ui-patch-review-test-with-repo
    (let ((task (harness-ui-patch-review-test--task repo)))
      (should (harness-ui-patch-review--offered-p task))
      (should (equal repo (harness-ui-patch-review--repository task)))
      ;; The project gone, its worktree does.
      (should (equal repo (harness-ui-patch-review--repository
                           (harness-ui-patch-review-test--task repo :project "/no/such/dir" :worktree repo))))
      (dolist (other (list (plist-put (copy-sequence task) :state "active")
                           (plist-put (copy-sequence task) :archived t)
                           (plist-put (copy-sequence task) :branch nil)
                           (plist-put (copy-sequence task) :project "/no/such/dir")))
        (should-not (harness-ui-patch-review--offered-p other))
        (should (stringp (harness-ui-patch-review--why-not other))))
      ;; A harness on another machine: its repositories are not here.
      (let ((harness-ui-connection-address "elsewhere:7777"))
        (should-not (harness-ui-patch-review--offered-p task))
        (should (string-match-p "elsewhere:7777" (harness-ui-patch-review--why-not task)))))))

;;;; With the harness: the report

(defmacro harness-ui-patch-review-test-with-task (&rest body)
  "Run BODY with a task in review in `repo', which has its branch task/fix.
As the review tests do, with ui-patch-review on: BODY gets `repo', the
task's directory, `board', `id' and `sid'.  The task worked in the
main checkout, so it has no branch until BODY gives it one."
  (declare (indent 0))
  `(harness-test-with-temp-state
     ;; The repository first, while the directory is empty.
     (harness-ui-patch-review-test--repo dir)
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
     (harness-test-load-module 'tools-handin)
     (harness-test-load-module 'tools-review)
     (harness-test-load-module 'patch-review)
     (clrhash harness-patch-review--sets)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override
            '((:type text :delta "All done.\n")
              (:type tool-call :id "h1" :name "hand_in"
                     :input (:problem "The flaky test fails in a random order." :summary "Done: the flaky test is fixed." :evidence ("a note")))))
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification t)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           (harness-ui-default-position 'full)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-compose ui-markdown ui-popout ui-tasks ui-chat ui-report ui-review ui-patch-review))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (let ((repo dir)
             (harness-ui-connection-address nil))
         (accept-process-output nil 0)
         (delete-other-windows)
         (let* ((board (harness-tasks dir))
                (id (progn (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                                               5 "the board to load")
                           (with-current-buffer board
                             (goto-char harness-compose-end)
                             (insert "Fix the flaky test")
                             (harness-ui-tasks-submit)
                             (harness-test-wait
                              (lambda () (equal "review" (plist-get (car harness-ui-tasks--tasks) :state)))
                              10 "the task to wait for review")
                             (plist-get (car harness-ui-tasks--tasks) :id))))
                (sid (plist-get (harness-call 'task/get id) :session)))
           (ignore sid repo)
           (unwind-protect
               (progn ,@body)
             (maphash (lambda (_id review) (harness-ui-patch-review--forget review))
                      (copy-hash-table harness-ui-patch-review--reviews))
             (clrhash harness-ui-patch-review--reviews)
             (let ((ignore-window-parameters t)) (delete-other-windows))
             (dolist (b (buffer-list))
               (when (memq (buffer-local-value 'major-mode b)
                           '(harness-ui-popout-mode harness-chat-mode harness-ui-tasks-mode))
                 (ignore-errors (kill-buffer b))))
             (dolist (c (copy-sequence harness-acp--clients))
               (harness-acp--drop-client c))))))))

(defun harness-ui-patch-review-test--wait-text (buffer regexp &optional absent)
  "Wait until BUFFER's text matches REGEXP, or with ABSENT no longer does."
  (harness-test-wait (lambda () (let ((found (string-match-p regexp (harness-ui-patch-review-test--text buffer))))
                                  (if absent (not found) found)))
                     5 (format "the buffer %s %s" (if absent "to lose" "to show") regexp)))

(defun harness-ui-patch-review-test--report (board id)
  "Pop out the report of task ID as BOARD's [Review Changes] does; return its buffer.
The board's record is the one the wire gives, as the UI sees it."
  (harness-ui-report-popout (with-current-buffer board (harness-ui-tasks--find id)))
  (let ((popout (harness-ui-popout-buffer (list 'report id))))
    (harness-ui-patch-review-test--wait-text popout "Ready for review")
    popout))

(defun harness-ui-patch-review-test--give-branch (board id)
  "Give task ID its branch, task/fix made from main, and wait for BOARD to hear."
  (harness-tasks--set id :branch "task/fix" :base "main")
  (harness-test-wait (lambda () (with-current-buffer board
                                  (equal "task/fix" (plist-get (harness-ui-tasks--find id) :branch))))
                     5 "the board to hear of the branch"))

(defun harness-ui-patch-review-test--changes (board id)
  "Give task ID its branch, pop out its report from BOARD, wait for the changes.
Return the popout, its window selected."
  (harness-ui-patch-review-test--give-branch board id)
  (let ((popout (harness-ui-patch-review-test--report board id)))
    (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
    popout))

(defun harness-ui-patch-review-test--layout ()
  "Return the windows of the selected frame, in order: (BUFFER . SIDE) each."
  (mapcar (lambda (w) (cons (window-buffer w) (window-parameter w 'window-side)))
          (window-list nil 'nomini (frame-first-window))))

(defun harness-ui-patch-review-test--control (review index)
  "Wait for the Ediff of REVIEW's file at INDEX; return its control buffer."
  (harness-test-wait (lambda ()
                       (let ((state (harness-ui-patch-review--r-ediff review)))
                         (and (eql index (plist-get state :index))
                              (buffer-live-p (plist-get state :control))
                              (plist-get state :control))))
                     10 (format "the Ediff of file %d" index)))

(ert-deftest harness-ui-patch-review-report-shows-the-changes ()
  "The report of a task in review with a branch shows its changes after the
evidence, before the review banner: what is compared, a row per file.
Nothing else does: the board has no button for them."
  (harness-ui-patch-review-test-with-task
    (let ((popout (harness-ui-patch-review-test--report board id)))
      ;; Worked in the main checkout, the task has no branch to look at.
      (should-not (string-search "Changes" (harness-ui-patch-review-test--text popout)))
      (should-not (gethash id harness-ui-patch-review--reviews))
      (harness-ui-patch-review-test--give-branch board id)
      ;; The report hears of it, and reads the branch.
      (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
      (let ((text (harness-ui-patch-review-test--text popout))
            (merge-base (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix")))
        (should (string-match-p (format "^Changes (6)   0 of 6 files viewed, 6 left   task/fix against main @ %s   \\+7 −8$"
                                        (substring merge-base 0 7))
                                text))
        (should (< (string-match "^Evidence" text) (string-match "^Changes (6)" text)
                   (string-match "Ready for review" text)))
        (should (string-match-p "^    M  a\\.el +\\+2 −2$" text))
        (should (string-match-p "^    D  b\\.el +\\+0 −5$" text))
        (should (string-match-p "^    R  c\\.el → d\\.el +\\+1 −1$" text))
        (should (string-match-p "^  ▾ docs/  1 file  \\+1 −0$" text))
        (should (string-match-p "^      A  é\\.txt +\\+1 −0$" text))
        (should (string-match-p "^    M  img\\.bin +binary$" text))
        (should (string-match-p "^  RET or a click compares a file in Ediff" text))
        (should-not (string-search "keep.el" text)))
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 0))
        (should (eq #'harness-ui-patch-review-ediff (key-binding (kbd "RET"))))
        (should (eq #'harness-ui-patch-review-mouse-ediff
                    (lookup-key (get-text-property (point) 'keymap) [mouse-1])))
        ;; a approves the file, A all of them, t shows them flat.
        (should (eq #'harness-ui-patch-review-approve (key-binding "a")))
        (should (eq #'harness-ui-patch-review-approve-all (key-binding "A")))
        (should (eq #'harness-ui-patch-review-toggle-file-tree (key-binding "t")))
        (call-interactively (key-binding "a"))
        (harness-ui-patch-review-test--wait-text popout "^  ✔ M  a\\.el")
        (should (string-match-p "1 approved" (harness-ui-patch-review-test--text popout)))
        (call-interactively (key-binding "A"))
        (harness-ui-patch-review-test--wait-text popout "^  ✔ M  img\\.bin")
        (should (string-match-p "6 approved" (harness-ui-patch-review-test--text popout)))
        (call-interactively (key-binding "t"))
        (harness-ui-patch-review-test--wait-text popout "^  ✔ A  docs/é\\.txt")
        (call-interactively #'harness-ui-patch-review-toggle-file-tree)
        (harness-ui-patch-review-test--wait-text popout "^  ▾ docs/")
        ;; n and p move between the files: here with every file approved, so
        ;; with skipping the approved files off (`harness-ui-patch-review-skips-approved-files').
        (let ((harness-ui-patch-review-skip-approved nil))
          (call-interactively (key-binding "n"))
          (should (eql 1 (cdr (harness-ui-patch-review--at-point))))
          (call-interactively (key-binding "p"))
          (should (eql 0 (cdr (harness-ui-patch-review--at-point))))
          (harness-ui-patch-review-previous-file)
          (should (eql 0 (cdr (harness-ui-patch-review--at-point)))))
        ;; The box is the review's still: it sends the task back.
        (should (harness-compose-live-p))
        ;; A binary file is not for Ediff: RET says so, and it is seen.
        (goto-char (harness-ui-patch-review--row-start id 4))
        (call-interactively (key-binding (kbd "RET")))
        (should-not (harness-ui-patch-review--r-ediff (gethash id harness-ui-patch-review--reviews))))
      (harness-ui-patch-review-test--wait-text popout "^  ✔ M  img\\.bin +binary$")
      ;; No button on the board.
      (should-not (string-search "[Changes]" (harness-ui-patch-review-test--text board)))
      ;; A harness on another machine: the report says why it has no changes.
      (let ((harness-ui-connection-address "elsewhere:7777"))
        (harness-ui-popout-refresh (list 'report id))
        (should (string-match-p "^Changes   The harness runs at elsewhere:7777"
                                (harness-ui-patch-review-test--text popout))))
      ;; Off, the module takes its part of the report out.
      (harness-ui-popout-refresh (list 'report id))
      (should (string-search "Changes (6)" (harness-ui-patch-review-test--text popout)))
      (harness-module-disable 'ui-patch-review)
      (should-not (memq #'harness-ui-patch-review--panel harness-ui-report-panel-functions))
      (should-not (string-search "Changes" (harness-ui-patch-review-test--text popout)))
      (should (string-search "Ready for review" (harness-ui-patch-review-test--text popout)))
      (should (= 0 (hash-table-count harness-ui-patch-review--reviews))))))

(ert-deftest harness-ui-patch-review-ends-in-ediff ()
  "A task decided while its Ediff shows keeps the Ediff until q, which gives
the frame back, without the report that closed; one out of sight ends
without touching the windows."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (task (with-current-buffer board (harness-ui-tasks--find id))))
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (buffers (harness-ui-patch-review--ediff-buffers review)))
        ;; Done while Ediff shows: the report closes, the Ediff stays.
        (with-current-buffer popout (setq-local harness-ui-popout--discard t))
        (kill-buffer popout)
        (harness-ui-patch-review--on-event "task/done" (list (append '(:state "done") task)))
        (should (harness-ui-patch-review--r-gone review))
        (should (cl-every #'buffer-live-p buffers))
        ;; q: the windows as they were, but for the report's.
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))
        (should-not (cl-some #'buffer-live-p buffers))
        (should (one-window-p))
        (should (eq board (window-buffer (selected-window))))
        (should-not (gethash id harness-ui-patch-review--reviews)))
      ;; Out of sight, the Ediff ends without touching the windows.
      (setq popout (harness-ui-patch-review-test--report board id))
      ;; a.el was seen in the first Ediff, and the harness kept it so.
      (harness-ui-patch-review-test--wait-text popout "^  ✓ M  a\\.el")
      (setq review (gethash id harness-ui-patch-review--reviews))
      (harness-ui-patch-review-ediff review 2)
      (harness-ui-patch-review-test--control review 2)
      (let ((buffers (harness-ui-patch-review--ediff-buffers review))
            (other (get-buffer-create "*patch review elsewhere*")))
        (let ((ignore-window-parameters t)) (delete-other-windows))
        (set-window-dedicated-p (selected-window) nil)
        (set-window-buffer (selected-window) other)
        (harness-ui-patch-review--on-event "task/deleted" (list id))
        (should-not (cl-some #'buffer-live-p buffers))
        (should (one-window-p))
        (should (eq other (window-buffer (selected-window))))
        (should-not (gethash id harness-ui-patch-review--reviews))
        (kill-buffer other)))))

;;;; The tree and approvals

(ert-deftest harness-ui-patch-review-shows-a-file-tree ()
  "The changed files group under the directories that hold them, with
the lines each directory adds and deletes; t shows them flat instead."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (text (harness-ui-patch-review--section review nil)))
      (should (string-match-p "^  ▾ docs/  1 file  \\+1 −0$" text))
      (should (string-match-p "^      A  é\\.txt +\\+1 −0$" text))
      (should-not (string-match-p "^    A  docs/é\\.txt" text))
      ;; The entries of a directory sort by name.
      (should (< (string-match "a\\.el" text)
                 (string-match "b\\.el" text)
                 (string-match "c\\.el → d\\.el" text)
                 (string-match "docs/" text))))
    ;; Flat: every file on one line, its path whole again.
    (let ((review (harness-ui-patch-review-test--review repo)))
      (setf (harness-ui-patch-review--r-tree review) nil)
      (let ((text (harness-ui-patch-review--section review nil)))
        (should (string-match-p "^    A  docs/é\\.txt +\\+1 −0$" text))
        (should-not (string-match-p "^  ▾ docs/" text))))))

(ert-deftest harness-ui-patch-review-approves-a-file-until-it-changes ()
  "Approving a file marks it seen; the file's path and blob keep it approved.
A file the branch changes again is not approved, so it is reviewed again."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (a (harness-ui-patch-review-test--file review "a.el")))
      (should-not (harness-ui-patch-review--approved-p review a))
      (harness-ui-patch-review--approve review a t)
      (should (harness-ui-patch-review--approved-p review a))
      (should (harness-ui-patch-review--seen-p review a))
      (let ((text (harness-ui-patch-review--section review nil)))
        (should (string-match-p "^  ✔ M  a\\.el" text))
        (should (string-match-p "1 approved" text)))
      ;; The same path with another blob is another file, not approved.
      (should-not (harness-ui-patch-review--approved-p
                   review (change-review-make-file
                           :status "M" :path "a.el" :new-blob "not-the-same")))
      ;; Un-approving takes the mark and the count away.
      (harness-ui-patch-review--approve review a nil)
      (should-not (harness-ui-patch-review--approved-p review a))
      (should-not (string-match-p "[0-9] approved"
                                  (harness-ui-patch-review--section review nil))))))

(defun harness-ui-patch-review-test--viewed (id)
  "Return the files the harness keeps viewed in task ID's review: (SEEN APPROVED) paths."
  (let ((data (harness-test-await (harness-call-async 'patch-review/viewed id))))
    (list (mapcar (lambda (file) (plist-get file :path)) (plist-get data :seen))
          (mapcar (lambda (file) (plist-get file :path)) (plist-get data :approved)))))

(ert-deftest harness-ui-patch-review-keeps-the-files-viewed-with-the-harness ()
  "A file seen, or approved, is kept by the harness by its path and blob: a
report opened again shows the marks, un-approving takes the mark off there
too, and a file the branch changes meanwhile is not viewed any more."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (a (harness-ui-patch-review-test--file review "a.el"))
           (b (harness-ui-patch-review-test--file review "b.el"))
           (d (harness-ui-patch-review-test--file review "d.el")))
      (should (equal '(nil nil) (harness-ui-patch-review-test--viewed id)))
      (harness-ui-patch-review--mark-seen review a)
      (harness-ui-patch-review--approve review b t)
      (harness-ui-patch-review--mark-seen review d)
      (harness-test-wait (lambda () (equal '(("a.el" "b.el" "d.el") ("b.el")) (harness-ui-patch-review-test--viewed id)))
                         5 "the harness to keep the marks")
      ;; By path and blob: a file the branch deleted has no blob.
      (let ((seen (plist-get (harness-test-await (harness-call-async 'patch-review/viewed id)) :seen)))
        (should (equal (change-review-file-new-blob a) (plist-get (car seen) :blob)))
        (should-not (plist-member (cadr seen) :blob)))
      ;; Marking a file seen again sends nothing: it is, already.
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (&rest _) (ert-fail "a mark that is there was sent again"))))
        (harness-ui-patch-review--mark-seen review a))
      ;; The report opened again, the first forgotten, shows what was kept.
      (with-current-buffer popout (setq-local harness-ui-popout--discard t))
      (kill-buffer popout)
      (harness-ui-patch-review--forget review)
      (setq popout (harness-ui-patch-review-test--report board id))
      (harness-ui-patch-review-test--wait-text popout "^  ✓ M  a\\.el")
      (harness-ui-patch-review-test--wait-text popout "^  ✔ D  b\\.el")
      (harness-ui-patch-review-test--wait-text popout "3 of 6 files viewed, 3 left, 1 approved")
      (setq review (gethash id harness-ui-patch-review--reviews))
      ;; Un-approving is kept too; the file stays viewed.
      (harness-ui-patch-review--approve review (harness-ui-patch-review-test--file review "b.el") nil)
      (harness-test-wait (lambda () (equal '(("a.el" "b.el" "d.el") nil) (harness-ui-patch-review-test--viewed id)))
                         5 "the harness to keep the approval taken off")
      ;; The branch changes a.el: it is another file now, not viewed.
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (should-not (harness-ui-patch-review--seen-p review (harness-ui-patch-review-test--file review "a.el")))
      (should (harness-ui-patch-review--seen-p review (harness-ui-patch-review-test--file review "d.el")))
      (should (string-match-p "2 of 6 files viewed, 4 left" (harness-ui-patch-review-test--text popout))))))

(ert-deftest harness-ui-patch-review-takes-the-files-before-the-newest-commit-as-viewed ()
  "V takes every file as viewed but those the branch's newest commit changed,
asks first, and says in the report that the files were taken as viewed;
the harness keeps them."
  (harness-ui-patch-review-test-with-task
    (harness-ui-patch-review-test--give-branch board id)
    (harness-ui-patch-review-test--advance repo)
    (let* ((popout (harness-ui-patch-review-test--report board id))
           (before-newest (harness-ui-patch-review-test--git repo "rev-parse" "task/fix~1")))
      (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 0))
        (should (eq #'harness-ui-patch-review-assume-viewed (key-binding "V")))
        ;; Declined: nothing happens.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (call-interactively (key-binding "V")))
        (should (equal '(nil nil) (harness-ui-patch-review-test--viewed id)))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (call-interactively (key-binding "V"))))
      (harness-ui-patch-review-test--wait-text popout "5 of 6 files viewed, 1 left")
      (let ((text (harness-ui-patch-review-test--text popout)))
        (should (string-search (format "unchanged since %s taken as viewed" (substring before-newest 0 7)) text))
        ;; a.el, the newest commit's, is left to view; the others are viewed.
        (should (string-match-p "^    M  a\\.el" text))
        (should (string-match-p "^  ✓ D  b\\.el" text))
        (should (string-match-p "^  ✓ R  c\\.el → d\\.el" text)))
      (should (equal '(("b.el" "d.el" "docs/é.txt" "img.bin" "new.el") nil)
                     (harness-ui-patch-review-test--viewed id)))
      ;; Looking at the one left changes the count, and is kept.  The report
      ;; draws again when Ediff ends; here nothing does it but the test.
      (let ((review (gethash id harness-ui-patch-review--reviews)))
        (harness-ui-patch-review--mark-seen review (harness-ui-patch-review-test--file review "a.el"))
        (harness-ui-patch-review--refresh review)
        (harness-ui-patch-review-test--wait-text popout "6 of 6 files viewed, 0 left"))
      (harness-test-wait (lambda () (member "a.el" (car (harness-ui-patch-review-test--viewed id))))
                         5 "the harness to keep the file looked at"))))

(ert-deftest harness-ui-patch-review-imports-the-replies-written-by-hand ()
  "A reply typed in the task's session under a quote of the agent's words
becomes a closed thread of the review, with its quote; the review open on
the task shows it as the harness announces it, and asking again adds none."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (said (lambda ()
                   (cl-find-if (lambda (thread)
                                 (string-search "Why that?" (change-review-comment-body (change-review-thread-root thread))))
                               (change-review-set-threads set)))))
      (harness-call 'session/append sid (list :kind 'user :ts 4000.0 :meta '(:steering t)
                                              :content "> What the agent said.\n\nWhy that?"))
      (should-not (funcall said))
      (with-current-buffer popout
        (call-interactively #'harness-ui-patch-review-import-manual))
      (harness-test-wait (lambda () (funcall said)) 5 "the imported thread to reach the review")
      (let ((thread (funcall said)))
        (should (eq 'closed (change-review-thread-status thread)))
        (should (equal "> What the agent said.\n\nWhy that?"
                       (change-review-comment-body (change-review-thread-root thread))))
        (should (equal 4000.0 (change-review-comment-time (change-review-thread-root thread)))))
      (let ((before (length (change-review-set-threads set))))
        (with-current-buffer popout
          (call-interactively #'harness-ui-patch-review-import-manual))
        (harness-test-wait (lambda () (eq 0 (plist-get (harness-call 'patch-review/import-manual id) :added))) 5 "asking again")
        (should (= before (length (change-review-set-threads set)))))
      ;; Where there is no task, it says so.
      (with-temp-buffer
        (should-error (call-interactively #'harness-ui-patch-review-import-manual) :type 'user-error)))))

(defun harness-ui-patch-review-test--comment (text)
  "Comment on the current difference of the selected Ediff panel with TEXT."
  (cl-letf (((symbol-function 'string-edit)
             (lambda (_p _initial callback &rest _) (funcall callback text))))
    (call-interactively #'harness-ui-patch-review-comment)))

(defun harness-ui-patch-review-test--press (command)
  "Run COMMAND in the buffer of the selected window, as a key would."
  (with-current-buffer (window-buffer (selected-window))
    (call-interactively command)))

(ert-deftest harness-ui-patch-review-next-difference-offers-the-next-file ()
  "n at the last difference says another file follows, and a second n goes
on to it in Ediff."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews)))
      (harness-ui-patch-review-ediff review 0)
      (let ((control (harness-ui-patch-review-test--control review 0)))
        (with-current-buffer control
          (should (= 0 ediff-current-difference))
          (should (= 2 ediff-number-of-differences))
          (harness-ui-patch-review-next-difference)
          (should (= 1 ediff-current-difference))
          (let ((this-command #'harness-ui-patch-review-next-difference)
                (last-command 'ediff-next-difference)
                (said nil))
            (cl-letf (((symbol-function 'message)
                       (lambda (&rest args) (setq said (apply #'format args)))))
              (harness-ui-patch-review-next-difference))
            (should (equal "Last difference; n again goes to the next file" said))
            (should harness-ui-patch-review--next-file-offer)))
        ;; The same key again takes the offer: the next file, in Ediff.
        (with-current-buffer control
          (let ((this-command #'harness-ui-patch-review-next-difference)
                (last-command #'harness-ui-patch-review-next-difference))
            (harness-ui-patch-review-next-difference)))
        (let ((next (harness-ui-patch-review-test--control review 1)))
          (with-current-buffer next
            (should (= 0 ediff-current-difference))
            (harness-ui-patch-review-ediff-quit)))))))

(ert-deftest harness-ui-patch-review-opens-from-a-sessions-history ()
  "C-c C-d in a task's session shows its report with the changes, and the
open report of a task done since still shows them."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (chat (harness-ui-display-session sid)))
      (should chat)
      (harness-test-wait (lambda () (harness-ui-review--task sid)) 5 "the session's task")
      (with-current-buffer chat
        (should (harness-ui-patch-review-mode))
        (should (eq #'harness-ui-patch-review-open (key-binding (kbd "C-c C-d"))))
        (call-interactively #'harness-ui-patch-review-open))
      (setq popout (harness-ui-popout-buffer (list 'report id)))
      (should popout)
      (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
      ;; Decided since, the review can still be opened: no banner, the
      ;; changes still show.
      (let* ((task (with-current-buffer board (harness-ui-tasks--find id)))
             (done (plist-put (copy-sequence task) :state "done")))
        (harness-ui-patch-review--open-task done)
        (let ((review (gethash id harness-ui-patch-review--reviews)))
          (should (harness-ui-patch-review--r-show review)))
        (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
        (should (string-search "Changes (6)" (harness-ui-patch-review-test--text popout)))
        (should-not (string-search "Ready for review"
                                   (harness-ui-patch-review-test--text popout)))))))

;;;; Threads: made in Ediff, kept by the harness, placed, drawn

(defun harness-ui-patch-review-test--harness-threads (id)
  "Return the threads the harness keeps for task ID, as plain data."
  (plist-get (harness-call 'patch-review/get id) :threads))

(defun harness-ui-patch-review-test--wait-harness-threads (id count)
  "Wait until the harness keeps COUNT threads for task ID."
  (harness-test-wait (lambda () (= count (length (harness-ui-patch-review-test--harness-threads id))))
                     5 (format "the harness to keep %d threads" count)))

(ert-deftest harness-ui-patch-review-ediff-from-the-report ()
  "RET on a file compares it in Ediff, in the report's frame, with the
review's keys: c starts a thread with a comment, r replies to it, N goes on
to the next file, q gives the frame back, the report there, its files seen,
point on the next one.  The box stays in sight under Ediff."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (layout (harness-ui-patch-review-test--layout))
           (ediff-buffers nil))
      (should (eq popout (window-buffer (selected-window))))
      (should (equal '(nil bottom) (mapcar #'cdr layout)))
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 0))
        (call-interactively (key-binding (kbd "RET"))))
      (let ((control (harness-ui-patch-review-test--control review 0))
            prompt)
        (setq ediff-buffers (harness-ui-patch-review--ediff-buffers review))
        ;; Ediff has the frame, but for the report: small, under Ediff's
        ;; windows, its box ending the window.
        (should (get-buffer-window control))
        (let ((box (get-buffer-window popout t)))
          (should (window-live-p box))
          (should (eq 'bottom (window-parameter box 'window-side)))
          (should (window-parameter box 'no-delete-other-windows))
          (should (>= (nth 1 (window-edges box)) (nth 3 (window-edges (get-buffer-window control)))))
          (should (<= (window-total-height box)
                      (max harness-ui-popout-min-height
                           (floor (* harness-ui-patch-review-ediff-box-height (frame-height))))))
          (should (= (window-point box) (buffer-local-value 'harness-compose-end popout))))
        (should (eq #'harness-ui-patch-review--box-fraction
                    (buffer-local-value 'harness-ui-popout--max-height popout)))
        ;; The two versions, named after where they are from, in the file's mode.
        (should (string-prefix-p "a.el (merge base " (buffer-name (nth 1 ediff-buffers))))
        (should (string-prefix-p "a.el (task/fix " (buffer-name (nth 2 ediff-buffers))))
        (should (eq 'emacs-lisp-mode (buffer-local-value 'major-mode (nth 2 ediff-buffers))))
        (should (buffer-local-value 'buffer-read-only (nth 2 ediff-buffers)))
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-comment (key-binding "c")))
          (should (eq #'harness-ui-patch-review-reply (key-binding "r")))
          (should (eq #'harness-ui-patch-review-threads (key-binding "T")))
          (should (eq #'harness-ui-patch-review-edit-comment (key-binding "e")))
          (should (eq #'harness-ui-patch-review-ediff-next-file (key-binding "N")))
          (should (eq #'harness-ui-patch-review-ediff-previous-file (key-binding "P")))
          (should (eq #'harness-ui-patch-review-ediff-quit (key-binding "q")))
          ;; Ediff's own keys are still there.
          (should (eq #'harness-ui-patch-review-next-difference (key-binding "n")))
          (should (eq ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help))
          (should (string-search "[Back to the report] q" (harness-ui-patch-review-test--text control)))
          ;; The brief help says which file of the six this is; none seen yet.
          (should (string-search "File 1 of 6 · 0 viewed · [Comment]" (harness-ui-patch-review-test--text control)))
          ;; On the first difference: line 2 on the branch.
          (should (= 0 ediff-current-difference))
          (should (= 2 ediff-number-of-differences))
          (should (equal '(:new . 2) (harness-ui-patch-review--ediff-position)))
          ;; The comment is written in a buffer of its own, so it may be
          ;; several lines.
          (cl-letf (((symbol-function 'string-edit)
                     (lambda (p _initial callback &rest _)
                       (setq prompt p)
                       (funcall callback "Why two?\nBecause the second one reads better."))))
            (call-interactively #'harness-ui-patch-review-comment))
          (should (equal "Comment on a.el, line 2:  C-c C-c saves it as a draft, C-c C-k cancels" prompt))
          (call-interactively #'harness-ui-patch-review-ediff-next-file)))
      ;; It is a thread of the review's set: a draft, with where it was made.
      (should (= 1 (length (change-review-set-threads set))))
      (let* ((thread (car (change-review-set-threads set)))
             (root (change-review-thread-root thread))
             (location (change-review-comment-location root)))
        (should (change-review-thread-open-p thread))
        (should (equal "Why two?\nBecause the second one reads better." (change-review-comment-body root)))
        (should (change-review-comment-draft-p root))
        (should (eq 'user (change-review-author-kind (change-review-comment-author root))))
        (should (equal "a.el" (change-review-location-file location)))
        (should (eql 2 (change-review-location-line location)))
        (should (eq 'new (change-review-location-side location)))
        (should (equal "@@ -1,2 +1,2 @@\n (setq a1 1)\n-(setq a2 2)\n+(setq a2 'two)"
                       (change-review-location-excerpt location)))
        ;; Against the version the branch ends at.
        (should (equal (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")
                       (change-review-comment-revision root))))
      ;; And in the harness's, which keeps it.
      (harness-ui-patch-review-test--wait-harness-threads id 1)
      ;; Not in the box: that holds the words that go with the comments.
      (with-current-buffer popout
        (should (equal "" (harness-compose-text))))
      ;; N: on to b.el, deleted on the branch, without the report between.
      (let ((control (harness-ui-patch-review-test--control review 1)))
        (setq ediff-buffers (append (harness-ui-patch-review--ediff-buffers review) ediff-buffers))
        (should (get-buffer-window popout t))
        (with-current-buffer control
          (should (= 1 ediff-number-of-differences))
          (should (equal '(:old . 5) (harness-ui-patch-review--ediff-position)))
          (let (prompt)
            (cl-letf (((symbol-function 'string-edit)
                       (lambda (p _initial callback &rest _)
                         (setq prompt p)
                         (funcall callback "Who used these?"))))
              (call-interactively #'harness-ui-patch-review-comment))
            (should (string-prefix-p "Comment on b.el, line 5 of the merge base:" prompt)))
          (call-interactively #'harness-ui-patch-review-ediff-quit))
        (should-not (buffer-live-p control)))
      ;; q: the frame as it was, the report in its window, selected,
      ;; with the height it had and free to go again.
      (should-not (harness-ui-patch-review--r-ediff review))
      (should (equal layout (harness-ui-patch-review-test--layout)))
      (should (eq popout (window-buffer (selected-window))))
      (should-not (window-parameter (selected-window) 'no-delete-other-windows))
      (should (= harness-ui-report-max-height (buffer-local-value 'harness-ui-popout--max-height popout)))
      ;; The versions and the control panels went.
      (should (= 6 (length ediff-buffers)))
      (should-not (cl-some #'buffer-live-p ediff-buffers))
      (with-current-buffer popout
        ;; Point on the next file, the files seen, the threads counted.
        (should (eql 2 (cdr (harness-ui-patch-review--at-point))))
        (should (eql (point) (window-point (selected-window))))
        (harness-ui-patch-review-test--wait-text popout "^Changes (6) .*   2 open, 0 closed")
        (let ((text (harness-ui-patch-review-test--text popout)))
          (should (string-match-p "^  ✓ M  a\\.el .*   1 open   1 draft" text))
          (should (string-match-p "^  ✓ D  b\\.el .*   1 open   1 draft" text))
          (should (string-match-p "^    R  c\\.el → d\\.el +\\+1 −1$" text))
          ;; Two of the six files were compared, four to go.
          (should (string-match-p "^Changes (6)   2 of 6 files viewed, 4 left" text))
          (should (string-match-p "^  2 drafts to send: they go with the feedback" text))
          ;; The threads are a section below the files, by file, each drawn as the
          ;; library draws a thread, the draft marked.
          (should (string-match-p "^Threads  \\[open 2\\]" text))
          (should (string-match-p "^  ▾ a\\.el +1 thread$" text))
          ;; In this window there is no room for the button that deletes a
          ;; thread of drafts, which is the first thing a header gives up; the
          ;; draft has the buttons that edit it and delete it.
          (should (string-match-p "^    ● [^ ]+ · line 2 · 1 comment · open +\\[Reply\\] \\[Close\\] \\[Diff\\]$" text))
          (should (string-match-p "^    ┃ 1/1  .* · draft  \\[Edit\\] \\[Delete\\]  ▸ where$" text))
          (should (string-match-p "^    ┃      Why two\\?$" text))))
      ;; The review stays, for Ediff again.
      (should (eq review (gethash id harness-ui-patch-review--reviews))))))

(ert-deftest harness-ui-patch-review-sends-the-drafts-with-the-feedback ()
  "The drafts go with the words in the box when it is sent: quoted from the
diff above each comment, naming its thread; they are marked sent and no
longer drafts.  An empty box sends them alone."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review)))
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?")
      (harness-ui-patch-review-test--comment-on review "new.el" nil "Needs a test")
      (harness-ui-patch-review-test--wait-harness-threads id 2)
      (should (= 2 (length (change-review-drafts set))))
      (with-current-buffer popout
        (goto-char harness-compose-end)
        (insert "Nearly there.")
        (call-interactively (key-binding (kbd "C-c C-c"))))
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :feedback))
                         10 "the feedback to reach the task")
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text))
            (tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
        (should (string-prefix-p "Nearly there.\n\nMy review comments on your branch task/fix (at " feedback))
        (should (string-search (substring tip 0 7) feedback))
        (should (string-search "\n> diff --git a/a.el b/a.el\n> @@ -15,4 +15,4 @@\n" feedback))
        (should (string-search "> +(setq a18 'eighteen)\n\nWhy eighteen?\n[thread t-" feedback))
        (should (string-search "> diff --git a/new.el b/new.el\n\nNeeds a test\n[thread t-" feedback))
        (should-not (string-search "b.el" feedback)))
      ;; Sent in the harness's set, and then in the UI's, which hears of it.
      (let ((backend (harness-patch-review--set-for id)))
        (should-not (change-review-drafts backend))
        (should (eql 0 (plist-get (change-review-comment-meta
                                   (change-review-thread-root (car (change-review-set-threads backend))))
                                  :round))))
      (harness-test-wait (lambda () (null (change-review-drafts set))) 5 "the drafts to be sent"))))

(ert-deftest harness-ui-patch-review-sends-the-drafts-alone ()
  "An empty box sends the task back when drafts wait: they are the feedback."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews)))
      ;; Nothing to send: the box says so.
      (with-current-buffer popout
        (goto-char harness-compose-end)
        (should-error (call-interactively (key-binding (kbd "C-c C-c"))) :type 'user-error))
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")
      (harness-ui-patch-review-test--wait-harness-threads id 1)
      (with-current-buffer popout
        (goto-char harness-compose-end)
        (call-interactively (key-binding (kbd "C-c C-c"))))
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :feedback))
                         10 "the feedback to reach the task")
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
        (should (string-prefix-p "My review comments on your branch task/fix" feedback))
        (should (string-search "Why two?" feedback))))))

(ert-deftest harness-ui-patch-review-places-threads-in-the-newest-version ()
  "A thread is on the line it is on now: moved down by lines added above it,
marked changed when its line was edited, the same where nothing happened.
One on a line the diff does not hold is carried through the diff since the
revision it was written against."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (eighteen (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?"))
           (eleven (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 11) "Why eleven?"))
           (b3 (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?"))
           (whole (harness-ui-patch-review-test--comment-on review "d.el" nil "On the file")))
      (let ((where (lambda (comment)
                     (change-review-placement set (harness-ui-patch-review-test--thread-of review comment)))))
        ;; The branch is as it was: every thread is where it was.
        (harness-test-await (harness-ui-patch-review--place-threads review))
        (should (equal 'same (plist-get (funcall where two) :status)))
        (should (eql 18 (plist-get (funcall where eighteen) :line)))
        ;; Three lines go in at the top of a.el and the second is edited.
        (harness-ui-patch-review-test--advance repo)
        (harness-test-await (harness-ui-patch-review--load review))
        (should (equal '(changed 5) (let ((p (funcall where two))) (list (plist-get p :status) (plist-get p :line)))))
        (should (equal '(moved 21 18) (let ((p (funcall where eighteen))) (list (plist-get p :status) (plist-get p :line) (plist-get p :was)))))
        ;; Not a line of the diff: the diff since the revision carries it down.
        (should (equal '(moved 14 11) (let ((p (funcall where eleven))) (list (plist-get p :status) (plist-get p :line) (plist-get p :was)))))
        ;; The merge base did not change.
        (should (eq 'same (plist-get (funcall where b3) :status)))
        (should (eql 3 (plist-get (funcall where b3) :line)))
        (ignore whole)
        ;; The report says so, in the threads below the files.
        (let ((text (harness-ui-patch-review--section review (harness-ui-patch-review--counts review))))
          (should (string-match-p "● [^ ]+ · line 5 (changed since) · 1 comment · open" text))
          (should (string-match-p "● [^ ]+ · line 21 (was 18) · 1 comment · open" text))
          (should (string-match-p "● [^ ]+ · line 14 (was 11) · 1 comment · open" text))
          (should (string-match-p "● [^ ]+ · line 3 · 1 comment · open" text))
          (should (string-match-p "● [^ ]+ · the file · 1 comment · open" text))
          (should (string-search "Why eighteen?" text)))))))

(ert-deftest harness-ui-patch-review-places-threads-by-what-they-quote ()
  "A thread whose revision is not in the repository is placed by the lines it quotes."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (c18 (harness-ui-patch-review-test--comment-on
                 review "a.el" '(:new . 18) "Why eighteen?" :revision "0123456789abcdef0123456789abcdef01234567")))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (let ((p (change-review-placement set (harness-ui-patch-review-test--thread-of review c18))))
        (should (equal '(moved 21 18) (list (plist-get p :status) (plist-get p :line) (plist-get p :was))))))))

(ert-deftest harness-ui-patch-review-says-when-the-line-went-with-its-file ()
  "A thread on a file the branch deleted since has no line to be on."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (c18 (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?")))
      (harness-ui-patch-review-test--git repo "checkout" "-q" "task/fix")
      (harness-ui-patch-review-test--git repo "rm" "-q" "a.el")
      (harness-ui-patch-review-test--git repo "commit" "-q" "-m" "Gone")
      (harness-test-await (harness-ui-patch-review--load review))
      (should (equal "D" (change-review-file-status (harness-ui-patch-review-test--file review "a.el"))))
      (let ((p (change-review-placement set (harness-ui-patch-review-test--thread-of review c18))))
        (should (null (plist-get p :line))))
      ;; The file is one the branch changes still (deleted): its thread is
      ;; under it, saying the line is gone.
      (should (string-match-p "line 18 (gone)"
                              (harness-ui-patch-review--section
                               review (harness-ui-patch-review--counts review)))))))

(ert-deftest harness-ui-patch-review-says-what-changed-since-your-comment ()
  "Each file with a comment of yours says whether it changed on the branch
since, or stayed the same."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo)))
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")
      (harness-ui-patch-review-test--comment-on review "docs/é.txt" nil "Needs a caption")
      ;; Written against the revision the branch is at: nothing to say.
      (harness-test-await (harness-ui-patch-review--place-threads review))
      (should-not (string-search "since your comment"
                                 (harness-ui-patch-review--section review (harness-ui-patch-review--counts review))))
      ;; a.el changes on the branch, é.txt does not.
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (let ((text (harness-ui-patch-review--section review (harness-ui-patch-review--counts review))))
        (should (string-match-p "a\\.el .*changed since your comment" text))
        (should (string-match-p "é\\.txt .*same since your comment" text))))))

(ert-deftest harness-ui-patch-review-shows-threads-in-ediff ()
  "RET on a thread of the report compares its file in Ediff with that line in
sight; the versions show the threads under their lines, those on removed
lines in the merge base's, drawn as the library draws them: who, when,
which revision, the place in the thread."
  (harness-ui-patch-review-test-with-task
    (let* ((harness-ui-patch-review-ediff-tree nil)
           (popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (bot (change-review-agent "Claude" :session "sess-9" :tool-call "toolu_7"))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (eighteen (harness-ui-patch-review-test--comment-on
                      review "a.el" '(:new . 18) "Why eighteen? It reads oddly next to seventeen, and the test only ever looks at one of them at a time."))
           (removed (harness-ui-patch-review-test--comment-on review "a.el" '(:old . 2) "Was it better?")))
      (change-review-reply set eighteen "Because the loop needs it." :author bot :sent (float-time))
      (harness-ui-patch-review-test--wait-text popout "● [^ ]+ · line 18 · 2 comments · open")
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "● [^ ]+ · line 18 ·")
        (beginning-of-line)
        ;; The header of a thread is the thread's: the library's commands find it.
        (should (equal (change-review-thread-id (harness-ui-patch-review-test--thread-of review eighteen))
                       (get-text-property (point) 'change-review-thread)))
        (should (eq #'harness-ui-patch-review-thread-return (key-binding (kbd "RET"))))
        (call-interactively (key-binding (kbd "RET"))))
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (buffers (harness-ui-patch-review--ediff-buffers review))
             (old (nth 1 buffers))
             (new (nth 2 buffers))
             (overlays (lambda (buffer)
                         (with-current-buffer buffer
                           (cl-loop for ov in (overlays-in (point-min) (point-max))
                                    when (overlay-get ov 'change-review-thread)
                                    collect (cons (line-number-at-pos (overlay-start ov))
                                                  (substring-no-properties (overlay-get ov 'after-string))))))))
        (ignore two removed)
        ;; The branch's version: the two threads on it, each at the end of its line.
        (should (equal '(2 18) (sort (mapcar #'car (funcall overlays new)) #'<)))
        (should (string-match-p "1/1  Noah.* · draft" (cdr (assq 2 (funcall overlays new)))))
        (should (string-search "Why two?" (cdr (assq 2 (funcall overlays new)))))
        ;; The thread of two comments: the place of each, who, and the link to the agent's conversation.
        (let ((text (cdr (assq 18 (funcall overlays new)))))
          (should (string-match-p "1/2  Noah" text))
          (should (string-match-p "2/2  Claude (agent)" text))
          (should (string-search "↗ conversation" text))
          (should (string-search "Because the loop needs it." text)))
        ;; The merge base's: the one on a removed line.
        (should (equal '(2) (mapcar #'car (funcall overlays old))))
        (should (string-search "Was it better?" (cdr (assq 2 (funcall overlays old)))))
        ;; Ediff opened with the line of the thread in sight.
        (let ((window (get-buffer-window new)))
          (should (= 18 (with-current-buffer new
                          (save-excursion (goto-char (window-point window)) (line-number-at-pos))))))
        (with-current-buffer control
          (should (string-search "File 1 of 6 · 0 viewed · 3 threads · [Comment]"
                                 (harness-ui-patch-review-test--text control)))
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

;;;; Comments are Markdown

(defconst harness-ui-patch-review-test--markdown
  "Why **two**, not `three`?\nSee [the docs](https://example.org/docs).\n"
  "A comment in Markdown: emphasis, code, a link, and a line break to keep.")

(defconst harness-ui-patch-review-test--answer
  (concat "Because:\n\n- the loop needs it, and it is long enough to be wrapped at sixty columns\n"
          "- it is `cheap`\n\n```elisp\n(setq a2 'two)\n```\n\n> quoted words")
  "An answer in Markdown: a list, a fenced block, a quote.")

(ert-deftest harness-ui-patch-review-draws-comments-as-markdown ()
  "A comment is drawn as the chat draws a message: its markers gone and its
faces there, a link a link, a list with bullets, a fenced block under a
margin, a quote under its bar, every line within the width; and a
thread named by its first words -- a row of the report, a closed
thread -- has the words without the markers.  A line break typed stays
one.  `harness-ui-patch-review-markdown' nil draws it all as it was typed."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (bot (change-review-agent "Claude" :session "sess-9" :tool-call "toolu_7"))
           (root (harness-ui-patch-review-test--comment-on
                  review "a.el" '(:new . 2) harness-ui-patch-review-test--markdown))
           (thread (harness-ui-patch-review-test--thread-of review root))
           (_answer (change-review-reply set root harness-ui-patch-review-test--answer
                                         :author bot :sent (float-time)))
           (string (lambda (&rest args)
                     (apply #'change-review-ui-thread-string set thread :width 60 args)))
           (lines (lambda (string) (split-string (substring-no-properties string) "\n" t))))
      (let* ((drawn (funcall string))
             (plain (substring-no-properties drawn)))
        ;; The words, no markers; each typed line break is a line.
        (should (member "┃      Why two, not three?" (funcall lines drawn)))
        (should (member "┃      See the docs." (funcall lines drawn)))
        (should-not (string-match-p "\\*\\*\\|`\\|](\\|```\\|^┃      > " plain))
        ;; The faces: bold, code; a link with where it goes.
        (should (memq 'bold (let ((f (get-text-property (string-search "two," drawn) 'face drawn)))
                              (if (listp f) f (list f)))))
        (should (memq 'harness-md-code (let ((f (get-text-property (string-search "three" drawn) 'face drawn)))
                                         (if (listp f) f (list f)))))
        (should (equal "https://example.org/docs"
                       (get-text-property (string-search "the docs" drawn) 'harness-url drawn)))
        ;; The answer: a list with bullets, the long item wrapped under its
        ;; text, the code in its block under the margin, the quote under its bar.
        (should (member "┃      • the loop needs it, and it is long enough to be" (funcall lines drawn)))
        (should (member "┃        wrapped at sixty columns" (funcall lines drawn)))
        (should (member "┃      • it is cheap" (funcall lines drawn)))
        (should (member "┃        elisp" (funcall lines drawn)))
        (should (member "┃        (setq a2 'two)" (funcall lines drawn)))
        (should (member "┃      ┃ quoted words" (funcall lines drawn)))
        (let ((code (get-text-property (string-search "(setq a2" drawn) 'face drawn)))
          (should (memq 'harness-md-code-block (if (listp code) code (list code)))))
        ;; None of the text is wider than the thread's width.
        (dolist (line (funcall lines drawn))
          (when (string-prefix-p "┃      " line)
            (should (<= (string-width line) 60))))
        ;; Every line is its comment's, the margins and the wrapped lines too.
        (should (equal (change-review-comment-id (cadr (change-review-thread-comments thread)))
                       (get-text-property (string-search "wrapped at" drawn) 'change-review-comment drawn))))
      ;; Named by its first words.
      (let ((row (substring-no-properties (change-review-ui-thread-line set thread :width 100)))
            (closed (substring-no-properties
                     (change-review-ui-thread-string set thread :width 100 :collapsed t :view 'diff))))
        (should (string-search "“Why two, not three? See the docs.”" row))
        (should (string-search "“Why two, not three? See the docs.”" closed)))
      ;; The threads below the files draw it rendered too.
      (let ((section (harness-ui-patch-review--section review (harness-ui-patch-review--counts review))))
        (should (string-search "Why two, not three?" (substring-no-properties section)))
        (should-not (string-search "**" (substring-no-properties section))))
      ;; Not as Markdown: as it was typed.
      (let ((harness-ui-patch-review-markdown nil))
        (let ((plain (substring-no-properties (funcall string))))
          (should (string-search "Why **two**, not `three`?" plain))
          (should (string-search "```elisp" plain))
          (should (string-search "> quoted words" plain)))
        (should (string-search "“Why **two**, not `three`? See [the docs]"
                               (substring-no-properties (change-review-ui-thread-line set thread :width 100)))))
      ;; Editing it is editing the Markdown.
      (should (equal harness-ui-patch-review-test--markdown (change-review-comment-body root)))
      ;; A comment the renderer cannot take is drawn as typed: the rest of
      ;; the review still draws.
      (cl-letf (((symbol-function 'harness-ui-markdown-render-lines)
                 (lambda (&rest _) (error "Not renderable")))
                ((symbol-function 'harness-ui-markdown-summary)
                 (lambda (&rest _) (error "Not renderable"))))
        (should (string-search "Why **two**, not `three`?"
                               (substring-no-properties (funcall string))))
        (should (string-search "“Why **two**, not `three`? See"
                               (substring-no-properties (change-review-ui-thread-line set thread :width 100))))))))

(ert-deftest harness-ui-patch-review-links-in-comments-are-the-branchs ()
  "A link to a file in a comment is relative to where the task worked, its
worktree, else the repository: the Ediff versions and the threads view are
in that directory, so that following the link finds the file."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (dir (file-name-as-directory (expand-file-name repo)))
           (tree (file-name-as-directory (harness-test-temp-dir))))
      ;; No worktree: the repository.
      (should (equal dir (harness-ui-patch-review--link-directory review)))
      ;; A worktree: where the agent worked.
      (setf (harness-ui-patch-review--r-task review)
            (plist-put (copy-sequence (harness-ui-patch-review--r-task review)) :worktree tree))
      (should (equal (expand-file-name tree) (harness-ui-patch-review--link-directory review)))
      ;; One that is gone is not.
      (setf (harness-ui-patch-review--r-task review)
            (plist-put (copy-sequence (harness-ui-patch-review--r-task review)) :worktree "/no/such/tree"))
      (should (equal dir (harness-ui-patch-review--link-directory review)))
      ;; The versions Ediff compares have it.
      (let* ((file (harness-ui-patch-review-test--file review "a.el"))
             (buffer (harness-ui-patch-review--side-buffer review file 'new "(setq a1 1)\n")))
        (unwind-protect
            (should (equal dir (buffer-local-value 'default-directory buffer)))
          (kill-buffer buffer))))))

(ert-deftest harness-ui-patch-review-shows-markdown-in-ediff-and-the-threads-view ()
  "The threads under the lines of Ediff, and the library's threads view, draw
a comment's Markdown rendered; the option that turns it off draws them again
as typed."
  (harness-ui-patch-review-test-with-task
    (let* ((harness-ui-patch-review-ediff-tree nil)
           (popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on
                 review "a.el" '(:new . 2) harness-ui-patch-review-test--markdown))
           (bold-at (lambda (string pos)
                      (let ((face (get-text-property pos 'face string)))
                        (memq 'bold (if (listp face) face (list face)))))))
      (ignore popout two)
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (shown (lambda ()
                      (with-current-buffer new
                        (mapconcat (lambda (ov) (or (overlay-get ov 'after-string) ""))
                                   (overlays-in (point-min) (point-max)) "")))))
        ;; Ediff: rendered.
        (let ((drawn (funcall shown)))
          (should (string-search "Why two, not three?" (substring-no-properties drawn)))
          (should (string-search "See the docs." (substring-no-properties drawn)))
          (should-not (string-search "**" drawn))
          (should (funcall bold-at drawn (string-search "two," drawn))))
        ;; The threads view: rendered.
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-threads))
        (let ((view (cl-find-if (lambda (b) (eq 'change-review-threads-mode (buffer-local-value 'major-mode b)))
                                (buffer-list))))
          (should view)
          ;; A link to a file in a comment is the branch's.
          (should (equal (file-name-as-directory (expand-file-name repo))
                         (buffer-local-value 'default-directory view)))
          (should (equal (file-name-as-directory (expand-file-name repo))
                         (buffer-local-value 'default-directory new)))
          (unwind-protect
              (with-current-buffer view
                (let ((drawn (buffer-substring (point-min) (point-max))))
                  (should (string-search "Why two, not three?" (substring-no-properties drawn)))
                  (should-not (string-search "**" drawn))
                  (should-not (string-search "](" drawn))
                  (should (funcall bold-at drawn (string-search "two," drawn)))
                  ;; Its keys still act on the comment under point, whatever it draws.
                  (goto-char (+ (point-min) (string-search "not three" drawn)))
                  (should (equal (change-review-comment-id (change-review-thread-root
                                                            (harness-ui-patch-review-test--thread-of review two)))
                                 (change-review-comment-id (change-review-ui--comment-at-point)))))
                ;; As typed, when Markdown is off.
                (let ((harness-ui-patch-review-markdown nil))
                  (change-review-ui-redraw)
                  (should (string-search "Why **two**, not `three`?"
                                         (buffer-substring-no-properties (point-min) (point-max))))))
            (kill-buffer view)))
        (let ((harness-ui-patch-review-markdown nil))
          (change-review-ui-refresh set)
          (change-review-ui-flush)
          (should (string-search "Why **two**, not `three`?" (substring-no-properties (funcall shown)))))
        (change-review-ui-refresh set)
        (change-review-ui-flush)
        (should-not (string-search "**" (funcall shown)))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-acts-on-threads-in-ediff ()
  "In a version, r replies to the thread under the line at point and x closes
it or opens it again; in the control panel they act on the thread at the
current difference; e edits your draft there.  The threads draw again."
  (harness-ui-patch-review-test-with-task
    (let* ((harness-ui-patch-review-ediff-tree nil)
           (popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (thread (harness-ui-patch-review-test--thread-of review two)))
      (ignore popout)
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (shown (lambda () (with-current-buffer new
                                 (mapconcat (lambda (ov) (substring-no-properties (or (overlay-get ov 'after-string) "")))
                                            (overlays-in (point-min) (point-max)) "")))))
        (should (string-search "Why two?" (funcall shown)))
        ;; From the version: point on line 2.
        (with-current-buffer new
          (goto-char (point-min))
          (forward-line 1)
          (should (eq #'change-review-ui-reply (key-binding "r")))
          (should (eq #'change-review-ui-toggle-status (key-binding "x")))
          (should (eq #'harness-ui-patch-review-comment-line (key-binding "c")))
          (let ((change-review-ui-read-function (lambda (_p _i callback) (funcall callback "A reply"))))
            (call-interactively #'change-review-ui-reply))
          (should (equal "A reply" (change-review-comment-body (change-review-thread-last-comment thread)))))
        (change-review-ui-flush)
        (should (string-search "2/2" (funcall shown)))
        (should (string-search "A reply" (funcall shown)))
        (with-current-buffer new
          (call-interactively #'change-review-ui-toggle-status))
        (should-not (change-review-thread-open-p thread))
        (change-review-ui-flush)
        ;; Closed, it is a line, and its triangle points right.
        (should (string-match-p "▸ ✓ [^ ]+ · 2 comments · closed just now" (funcall shown)))
        (should-not (string-search "2/2" (funcall shown)))
        ;; From the control panel: on the current difference, line 2.
        (with-current-buffer control
          (should (equal '(:new . 2) (harness-ui-patch-review--ediff-position)))
          (call-interactively #'harness-ui-patch-review-toggle-thread))
        (should (change-review-thread-open-p thread))
        (with-current-buffer control
          (let ((change-review-ui-read-function (lambda (_p _i callback) (funcall callback "From the panel"))))
            (call-interactively #'harness-ui-patch-review-reply))
          (should (equal "From the panel" (change-review-comment-body (change-review-thread-last-comment thread))))
          ;; e edits a draft there, not the box: three drafts are in the
          ;; thread by now, and RET takes the newest.
          (let ((change-review-ui-read-function
                 (lambda (prompt initial callback)
                   (should (string-match-p "\\`Edit Noah's comment 3/3 on a\\.el:2:" prompt))
                   (should (equal "From the panel" initial))
                   (funcall callback "From the panel, better"))))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (prompt _table _predicate _require _initial _hist default &rest _)
                         (should (equal (format "Edit which draft (default %s): " default) prompt))
                         default)))
              (call-interactively #'harness-ui-patch-review-edit-comment)))
          (should (equal "From the panel, better" (change-review-comment-body (change-review-thread-last-comment thread)))))
        ;; The second difference has no thread: r says so, and c starts one.
        (with-current-buffer control
          (ediff-next-difference)
          (should-error (call-interactively #'harness-ui-patch-review-reply) :type 'user-error)
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(defun harness-ui-patch-review-test--press-nth (string label n)
  "Press the Nth (from 0) button of STRING that starts with LABEL, as a click does."
  (let ((pos 0) starts)
    (when (and (get-text-property 0 'button string)
               (string-prefix-p label (substring-no-properties string 0)))
      (push 0 starts))
    (while (setq pos (next-single-property-change pos 'button string))
      (when (and (get-text-property pos 'button string)
                 (string-prefix-p label (substring-no-properties string pos)))
        (push pos starts)))
    (setq starts (sort starts #'<))
    (with-temp-buffer
      (insert string)
      (push-button (1+ (or (nth n starts) (error "No button %d %s" n label)))))))

(defun harness-ui-patch-review-test--comments (set)
  "Return every comment of SET's threads, thread by thread."
  (cl-loop for thread in (change-review-set-threads set)
           append (change-review-thread-comments thread)))

(defun harness-ui-patch-review-test--count (needle string)
  "Return how many times NEEDLE is in STRING."
  (let ((count 0) (pos 0) (text (substring-no-properties string)))
    (while (setq pos (string-search needle text pos))
      (cl-incf count)
      (setq pos (1+ pos)))
    count))

(defun harness-ui-patch-review-test--thread-string (buffer thread)
  "Return the text drawn under its line in BUFFER for THREAD, with properties."
  (with-current-buffer buffer
    (overlay-get (or (cl-find-if (lambda (ov) (equal (change-review-thread-id thread)
                                                     (overlay-get ov 'change-review-thread)))
                                 (overlays-in (point-min) (point-max)))
                     (error "No thread %s drawn in %s" (change-review-thread-id thread) buffer))
                 'after-string)))

(ert-deftest harness-ui-patch-review-edits-any-of-several-drafts ()
  "Where drafts pile up under one line -- three in a thread, one in another --
each has an [Edit] button in its drawing in Ediff, which edits that draft; e
asks which to edit, in the control panel and in a version, the newest the
default; and e on a thread's row in the report edits one of its drafts."
  (let ((change-review-ui-max-thread-lines nil))
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (noah (change-review-user "Noah" "noah@example.org"))
           (first (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (thread (harness-ui-patch-review-test--thread-of review first))
           (second (change-review-reply set first "And the second." :author noah))
           (third (change-review-reply set first "And the third." :author noah))
           (other (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Also this line."))
           (other-thread (harness-ui-patch-review-test--thread-of review other))
           (body (lambda (comment) (change-review-comment-body comment)))
           (short (lambda (th) (change-review-ui-thread-short-id set th))))
      (should (= 4 (length (change-review-drafts set))))
      ;; The report's thread of the first thread: e edits one of its three drafts,
      ;; not the other thread's.
      (harness-ui-patch-review-test--wait-text popout "● [^ ]+ · line 2 · 3 comments · open")
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "● [^ ]+ · line 2 · 3 comments")
        (beginning-of-line)
        (should (eq #'change-review-ui-edit-draft (key-binding "e")))
        (let (asked)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt table _predicate _require _initial _hist default &rest _)
                       (setq asked (list prompt (all-completions "" table) default))
                       (car (all-completions "" table)))))
            (let ((change-review-ui-read-function
                   (lambda (_prompt initial callback) (funcall callback (concat initial " (row)")))))
              (call-interactively (key-binding "e"))))
          (should (equal (format "Edit which draft (default %s): " (nth 2 asked)) (nth 0 asked)))
          (should (equal (list (format "%s 1/3  Why two?" (funcall short thread))
                               (format "%s 2/3  And the second." (funcall short thread))
                               (format "%s 3/3  And the third." (funcall short thread)))
                         (nth 1 asked)))
          (should (equal (nth 2 (nth 1 asked)) (nth 2 asked))))
        (should (equal "Why two? (row)" (funcall body first))))
      ;; Ediff, on the first difference: line 2 of the branch.
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (drawing (harness-ui-patch-review-test--thread-string new thread))
             (asked nil)
             (choose-first (lambda (prompt table _predicate _require _initial _hist default &rest _)
                             (push (list prompt (all-completions "" table) default) asked)
                             (car (all-completions "" table))))
             (append-to (lambda (suffix)
                          (lambda (_prompt initial callback) (funcall callback (concat initial suffix))))))
        ;; A button on each draft of the drawing: three in the thread, one in the other.
        (should (= 3 (harness-ui-patch-review-test--count "[Edit]" drawing)))
        (should (= 1 (harness-ui-patch-review-test--count
                      "[Edit]" (harness-ui-patch-review-test--thread-string new other-thread))))
        ;; The second button edits the second draft, whatever point is on.
        (with-current-buffer new (goto-char (point-max)))
        (let ((change-review-ui-read-function
               (lambda (prompt initial callback)
                 (should (string-match-p "\\`Edit Noah's comment 2/3 on a\\.el:2:" prompt))
                 (should (equal "And the second." initial))
                 (funcall callback "And the second, changed."))))
          (harness-ui-patch-review-test--press-nth drawing "[Edit]" 1))
        (should (equal "And the second, changed." (funcall body second)))
        (should (equal "And the third." (funcall body third)))
        (should (equal "Also this line." (funcall body other)))
        ;; The other thread's one button goes to its draft.
        (let ((change-review-ui-read-function (funcall append-to " (button)")))
          (harness-ui-patch-review-test--press-nth
           (harness-ui-patch-review-test--thread-string new other-thread) "[Edit]" 0))
        (should (equal "Also this line. (button)" (funcall body other)))
        ;; In the control panel: four drafts at the difference, asked which, in
        ;; the order the threads draw them; the first is chosen.
        (with-current-buffer control
          (cl-letf (((symbol-function 'completing-read) choose-first))
            (let ((change-review-ui-read-function (funcall append-to " (panel)")))
              (call-interactively #'harness-ui-patch-review-edit-comment))))
        (should (equal (list (format "%s 1/3  Why two? (row)" (funcall short thread))
                             (format "%s 2/3  And the second, changed." (funcall short thread))
                             (format "%s 3/3  And the third." (funcall short thread))
                             (format "%s 1/1  Also this line. (button)" (funcall short other-thread)))
                       (nth 1 (car asked))))
        (should (equal (nth 3 (nth 1 (car asked))) (nth 2 (car asked))))
        (should (equal "Why two? (row) (panel)" (funcall body first)))
        ;; In the version, with point on the line: the same question.
        (with-current-buffer new
          (goto-char (point-min))
          (forward-line 1)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt table predicate require initial hist default &rest _)
                       (funcall choose-first prompt table predicate require initial hist default)
                       ;; The newest: the other thread's draft.
                       default)))
            (let ((change-review-ui-read-function (funcall append-to " (line)")))
              (call-interactively #'harness-ui-patch-review-edit-comment))))
        (should (= 2 (length asked)))
        (should (equal "Also this line. (button) (line)" (funcall body other)))
        ;; What was sent is not edited; of the one draft left, that draft.
        (change-review-apply set (list :op 'mark-sent :time (float-time)
                                       :comments (mapcar #'change-review-comment-id (list first second other))))
        (with-current-buffer control
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (ert-fail "asked which of one draft"))))
            (let ((change-review-ui-read-function (funcall append-to " (only)")))
              (call-interactively #'harness-ui-patch-review-edit-comment))))
        (should (equal "And the third. (only)" (funcall body third)))
        (should (equal "Why two? (row) (panel)" (funcall body first)))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
      ;; The harness has what the user made of the drafts: each edit went to
      ;; it as an operation, and it keeps them.
      (let ((kept (lambda ()
                    (sort (mapcar (lambda (c) (plist-get c :body))
                                  (cl-loop for th in (harness-ui-patch-review-test--harness-threads id)
                                           append (plist-get th :comments)))
                          #'string<))))
        (harness-test-wait (lambda ()
                             (equal (funcall kept)
                                    (sort (mapcar body (harness-ui-patch-review-test--comments set)) #'string<)))
                           5 "the harness to keep the edited drafts")
        (should (member "And the second, changed." (funcall kept)))
        (should (member "Why two? (row) (panel)" (funcall kept))))
      ;; A draft on the change as a whole is in the threads below the files,
      ;; and e on it edits it too.
      (let ((whole (change-review-comment set "Overall: tests?" :author noah)))
        (harness-ui-patch-review-test--wait-text popout "Overall: tests\\?")
        (with-current-buffer popout
          (goto-char (point-min))
          (re-search-forward "Overall: tests\\?")
          (beginning-of-line)
          (should (eq #'change-review-ui-edit-draft (key-binding "e")))
          (let ((change-review-ui-read-function
                 (lambda (prompt initial callback)
                   (should (string-match-p "\\`Edit Noah's comment 1/1:" prompt))
                   (should (equal "Overall: tests?" initial))
                   (funcall callback "Overall: where are the tests?"))))
            (call-interactively #'change-review-ui-edit-draft)))
        (should (equal "Overall: where are the tests?" (funcall body whole))))))))

(ert-deftest harness-ui-patch-review-deletes-drafts-and-threads-of-drafts ()
  "A draft is taken back where it was made: K in the report's threads deletes
a thread of drafts; in Ediff each draft has a [Delete] button, k in the
control panel and in a version asks which draft of those at the difference or
under the line, and K which thread of drafts; the first draft of a thread that
has more takes the thread with it.  What the user deleted is gone from the
harness's copy too, and a thread with a comment that was sent is never deleted."
  (let ((change-review-ui-max-thread-lines nil))
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (noah (change-review-user "Noah" "noah@example.org"))
           (first (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (thread (harness-ui-patch-review-test--thread-of review first))
           (second (change-review-reply set first "And the second." :author noah))
           (third (change-review-reply set first "And the third." :author noah))
           (other (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Also this line."))
           (other-thread (harness-ui-patch-review-test--thread-of review other))
           (far (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 10) "Elsewhere."))
           (far-thread (harness-ui-patch-review-test--thread-of review far))
           (asked nil)
           (short (lambda (th) (change-review-ui-thread-short-id set th)))
           (bodies (lambda (th) (mapcar #'change-review-comment-body (change-review-thread-comments th))))
           (yes (lambda (prompt) (push prompt asked) t))
           (no (lambda (prompt) (push prompt asked) nil)))
      (should (= 5 (length (change-review-drafts set))))
      (harness-ui-patch-review-test--wait-text popout "Elsewhere\\.")
      ;; The report: k and K are the library's, on the thread or the comment at point.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "Elsewhere\\.")
        (should (eq #'change-review-ui-delete-draft (key-binding "k")))
        (should (eq #'change-review-ui-delete-draft-thread (key-binding "K")))
        (cl-letf (((symbol-function 'y-or-n-p) yes)
                  ((symbol-function 'message) #'ignore))
          (call-interactively #'change-review-ui-delete-draft-thread)))
      (should (equal (list (format "Delete thread %s with its draft? " (funcall short far-thread))) asked))
      (should-not (memq far-thread (change-review-set-threads set)))
      (harness-ui-patch-review-test--wait-text popout "Elsewhere\\." t)
      (setq asked nil)
      ;; Ediff, on the first difference: line 2 of the branch.
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (drawing (harness-ui-patch-review-test--thread-string new thread))
             (choose (lambda (which)
                       (lambda (prompt table _predicate _require _initial _hist default &rest _)
                         (push (list prompt (all-completions "" table) default) asked)
                         (pcase which
                           ('first (car (all-completions "" table)))
                           ('default default)
                           ((pred integerp) (nth which (all-completions "" table))))))))
        ;; A [Delete] on each draft of the drawing: three in the thread, one in the other.
        (should (= 3 (harness-ui-patch-review-test--count "[Delete]" drawing)))
        (should (= 1 (harness-ui-patch-review-test--count
                      "[Delete]" (harness-ui-patch-review-test--thread-string new other-thread))))
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-delete-comment (key-binding "k")))
          (should (eq #'harness-ui-patch-review-delete-thread (key-binding "K"))))
        (should (string-search "[Delete draft] k" (harness-ui-patch-review-test--text control)))
        (should (string-search "[Delete thread] K" (harness-ui-patch-review-test--text control)))
        (with-current-buffer new
          (should (eq #'harness-ui-patch-review-delete-comment (key-binding "k")))
          (should (eq #'harness-ui-patch-review-delete-thread (key-binding "K"))))
        ;; The second button deletes the second draft, whatever point is on; the
        ;; first asks about the thread, and no leaves everything as it was.
        (with-current-buffer new (goto-char (point-max)))
        (cl-letf (((symbol-function 'y-or-n-p) yes) ((symbol-function 'message) #'ignore))
          (harness-ui-patch-review-test--press-nth drawing "[Delete]" 1))
        (should (equal '("Why two?" "And the third.") (funcall bodies thread)))
        (should (equal '("Delete this draft? ") asked))
        (setq asked nil)
        (cl-letf (((symbol-function 'y-or-n-p) no) ((symbol-function 'message) #'ignore))
          (harness-ui-patch-review-test--press-nth drawing "[Delete]" 0))
        (should (equal (list (format "This draft starts thread %s: delete the thread, with the draft after it? "
                                     (funcall short thread)))
                       asked))
        (should (equal '("Why two?" "And the third.") (funcall bodies thread)))
        (setq asked nil)
        ;; In the control panel: three drafts at the difference, asked which, in
        ;; the order the threads draw them; the newest, the other thread's, goes
        ;; with its thread.
        (with-current-buffer control
          (cl-letf (((symbol-function 'completing-read) (funcall choose 'default))
                    ((symbol-function 'y-or-n-p) yes)
                    ((symbol-function 'message) #'ignore))
            (call-interactively #'harness-ui-patch-review-delete-comment)))
        (should (equal (list (format "%s 1/2  Why two?" (funcall short thread))
                             (format "%s 2/2  And the third." (funcall short thread))
                             (format "%s 1/1  Also this line." (funcall short other-thread)))
                       (nth 1 (nth 1 asked))))
        (should (equal (format "Delete which draft (default %s): " (nth 2 (nth 1 asked))) (nth 0 (nth 1 asked))))
        (should-not (memq other-thread (change-review-set-threads set)))
        (should (eq thread (car (change-review-set-threads set))))
        (setq asked nil)
        ;; In the version, with point on the line: two drafts of the thread; the
        ;; second, which is no first, goes alone.
        (with-current-buffer new
          (goto-char (point-min))
          (forward-line 1)
          (cl-letf (((symbol-function 'completing-read) (funcall choose 1))
                    ((symbol-function 'y-or-n-p) yes)
                    ((symbol-function 'message) #'ignore))
            (call-interactively #'harness-ui-patch-review-delete-comment)))
        (should (equal '("Why two?") (funcall bodies thread)))
        (setq asked nil)
        ;; K in the panel: the one thread at the difference is a draft thread; no
        ;; question which, only whether.
        (with-current-buffer control
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (ert-fail "asked which of one thread")))
                    ((symbol-function 'y-or-n-p) yes)
                    ((symbol-function 'message) #'ignore))
            (call-interactively #'harness-ui-patch-review-delete-thread)))
        (should (equal (list (format "Delete thread %s with its draft? " (funcall short thread))) asked))
        (should-not (change-review-set-threads set))
        ;; Nothing left to delete at the difference: it says so, and does not
        ;; go to the feedback box, as e does.
        (let ((selected (selected-window)))
          (with-current-buffer control
            (let ((error (should-error (call-interactively #'harness-ui-patch-review-delete-comment)
                                       :type 'user-error)))
              (should (equal "No draft of yours here" (cadr error))))
            (let ((error (should-error (call-interactively #'harness-ui-patch-review-delete-thread)
                                       :type 'user-error)))
              (should (equal "No thread here" (cadr error)))))
          (should (eq selected (selected-window)))
          (should-not (eq (selected-window) (get-buffer-window popout t))))
        ;; A thread with a comment that was sent is never deleted.
        (let* ((sent (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Sent one."))
               (sent-thread (harness-ui-patch-review-test--thread-of review sent)))
          (change-review-apply set (list :op 'mark-sent :time (float-time)
                                         :comments (list (change-review-comment-id sent))))
          (with-current-buffer control
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "asked"))))
              (let ((error (should-error (call-interactively #'harness-ui-patch-review-delete-comment)
                                         :type 'user-error)))
                (should (equal "No draft of yours here" (cadr error))))
              (let ((error (should-error (call-interactively #'harness-ui-patch-review-delete-thread)
                                         :type 'user-error)))
                (should (string-match-p "every one has a comment that was sent" (cadr error))))))
          (should (memq sent-thread (change-review-set-threads set))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
      ;; The button in the header of a thread of drafts, where the window has
      ;; room for it: both drafts go, and the harness hears of each.
      (let* ((mine (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 12) "Mine."))
             (mine-thread (harness-ui-patch-review-test--thread-of review mine))
             (more (change-review-reply set mine "More of mine." :author noah)))
        (ignore more)
        (should (= 2 (length (change-review-thread-comments mine-thread))))
        (cl-letf (((symbol-function 'y-or-n-p) yes) ((symbol-function 'message) #'ignore))
          (setq asked nil)
          (harness-ui-patch-review-test--press-nth
           (change-review-ui-thread-string set mine-thread :width 160) "[Delete thread]" 0))
        (should (equal (list (format "Delete thread %s with its 2 drafts? " (funcall short mine-thread))) asked))
        (should-not (memq mine-thread (change-review-set-threads set))))
      ;; The harness has what the user made of the drafts: each deletion went to
      ;; it as an operation, and it keeps only the thread that was sent.
      (let ((kept (lambda ()
                    (sort (mapcar (lambda (c) (plist-get c :body))
                                  (cl-loop for th in (harness-ui-patch-review-test--harness-threads id)
                                           append (plist-get th :comments)))
                          #'string<))))
        (harness-test-wait (lambda ()
                             (equal (funcall kept)
                                    (sort (mapcar (lambda (c) (change-review-comment-body c))
                                                  (harness-ui-patch-review-test--comments set))
                                          #'string<)))
                           5 "the harness to keep what is left of the drafts")
        (should (equal '("Sent one.") (funcall kept))))
      (ignore second third)))))

(ert-deftest harness-ui-patch-review-hears-the-agents-comments ()
  "A comment the agent made with its tool comes from the harness as an
operation and shows at once in the report and in Ediff, its author an
agent with the session and the tool call; following it goes to the point
of the conversation."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (thread (harness-ui-patch-review-test--thread-of review two)))
      (harness-ui-patch-review-test--wait-harness-threads id 1)
      ;; What the harness announces when the agent answers.
      (harness-ui-patch-review--on-event
       "patch-review/changed"
       (list id (list :op "add-comment" :thread (change-review-thread-id thread)
                      :comment (list :id "c-agent01" :thread (change-review-thread-id thread)
                                     :reply-to (change-review-comment-id two)
                                     :body "Done in the next commit." :time (float-time) :sent (float-time)
                                     :author (list :kind "agent" :name "Claude (sonnet)"
                                                   :session "sess-42" :tool-call "toolu_42")
                                     :revision "abc1234abc1234abc1234abc1234abc1234abc1"))))
      (should (= 2 (length (change-review-thread-comments thread))))
      (let ((answer (cdr (change-review-find-comment set "c-agent01"))))
        (should (eq 'agent (change-review-author-kind (change-review-comment-author answer))))
        (should (equal "toolu_42" (change-review-author-tool-call (change-review-comment-author answer))))
        (should-not (change-review-comment-draft-p answer))
        ;; Following it: the session, at the call.
        (let (shown)
          (cl-letf (((symbol-function 'harness-ui-display-session)
                     (lambda (sid) (setq shown sid) (current-buffer)))
                    ((symbol-function 'harness-ui-report--call-position)
                     (lambda (item) (setq shown (list shown (plist-get item :call-id))) nil)))
            (change-review-follow-author set (change-review-comment-author answer))
            (should (equal '("sess-42" "toolu_42") shown)))))
      ;; Performed twice, once: the echo of the user's own operation changes nothing.
      (let ((count (length (change-review-thread-comments thread))))
        (harness-ui-patch-review--on-event
         "patch-review/changed"
         (list id (list :op "add-comment" :thread (change-review-thread-id thread)
                        :comment (list :id "c-agent01" :thread (change-review-thread-id thread) :body "Done in the next commit."))))
        (should (= count (length (change-review-thread-comments thread)))))
      ;; The report hears of it: the thread says two comments, the agent's drawn.
      (harness-ui-patch-review-test--wait-text popout "line 2 · 2 comments · open")
      (should (string-match-p "^    ┃ 2/2  Claude (sonnet) (agent) .*↗ conversation"
                              (harness-ui-patch-review-test--text popout)))
      (should (string-search "Done in the next commit." (harness-ui-patch-review-test--text popout)))
      ;; An operation the library cannot perform is logged, not raised.
      (harness-ui-patch-review--on-event
       "patch-review/changed" (list id (list :op "set-status" :thread "t-nope" :status "closed")))
      (should (= 2 (length (change-review-thread-comments thread)))))))

(ert-deftest harness-ui-patch-review-shows-the-threads-below-the-files ()
  "The threads are a section of the report below the files, in the same buffer:
by file, with the library's filter buttons, drawn as the library draws them.
T goes there instead of opening a view of its own; the filter, a thread's keys
and RET on it act in the report."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (b3 (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?"))
           (whole (change-review-comment set "Overall: fine."
                                         :author (change-review-user "Noah" "noah@example.org"))))
      (ignore whole)
      (change-review-close set (harness-ui-patch-review-test--thread-of review b3))
      (harness-ui-patch-review-test--wait-text popout "^Changes (6) .*   2 open, 1 closed \\[Threads\\]")
      (let ((text (harness-ui-patch-review-test--text popout)))
        ;; Below the files, under a heading with the filter buttons.
        (should (< (string-match "^  RET or a click compares a file" text)
                   (string-match "^Threads  \\[open 2\\] +to review 0 +closed 1 +all 3" text)
                   (string-match "^  ▾ a\\.el +1 thread$" text)))
        ;; The change as a whole first, then the files in the order of the diff.
        (should (< (string-match "^  ▾ The change as a whole +1 thread$" text)
                   (string-match "^  ▾ a\\.el +1 thread$" text)))
        (should (string-match-p "^    ┃      Why two\\?$" text))
        ;; Open threads at first: the closed one of b.el is behind the filter.
        (should-not (string-search "Who used b3?" text))
        (should-not (string-search "Other threads" text)))
      ;; T goes to the section in the same buffer: no view of its own opens.
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 0))
        (should (eq #'harness-ui-patch-review-threads (key-binding "T")))
        (call-interactively (key-binding "T"))
        (should (eq popout (current-buffer)))
        (should (string-prefix-p "Threads" (buffer-substring-no-properties (point) (point-max)))))
      (should-not (cl-some (lambda (buffer)
                             (eq 'change-review-threads-mode (buffer-local-value 'major-mode buffer)))
                           (buffer-list)))
      ;; The library's filter: all shows the closed one too, drawn closed.
      (with-current-buffer popout
        (should (eq 'open change-review-ui--filter))
        (change-review-ui-set-filter 'all)
        (should (eq 'all change-review-ui--filter)))
      (harness-ui-patch-review-test--wait-text popout "Who used b3\\?")
      (should (string-match-p "^Threads  +open 2 +to review 0 +closed 1 +\\[all 3\\]"
                              (harness-ui-patch-review-test--text popout)))
      (should (string-match-p "^  ▾ b\\.el +1 thread · 0 open$" (harness-ui-patch-review-test--text popout)))
      (with-current-buffer popout (change-review-ui-set-filter 'open))
      (harness-ui-patch-review-test--wait-text popout "Who used b3\\?" t)
      ;; The keys of a thread act in the report: x closes it, and it draws again
      ;; without the thread, point on what took its place.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^    ┃      Why two\\?$")
        (should (eq #'change-review-ui-toggle-status (key-binding "x")))
        (should (eq #'change-review-ui-reply (key-binding "r")))
        (call-interactively (key-binding "x")))
      (should-not (change-review-thread-open-p (harness-ui-patch-review-test--thread-of review two)))
      (harness-ui-patch-review-test--wait-text popout "Why two\\?" t)
      (ignore two))))

(ert-deftest harness-ui-patch-review-compares-from-a-thread ()
  "RET on the header of a thread compares its file in Ediff at the thread's
line; on the name of a file above its threads, that file; d does what RET does
on the header, and on a comment RET shows where it was made."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (eighteen (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?")))
      (ignore eighteen)
      (harness-ui-patch-review-test--wait-text popout "● [^ ]+ · line 18 · 1 comment")
      ;; On a comment: where it was made, under it.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^    ┃      Why eighteen\\?$")
        (should (get-text-property (point) 'change-review-comment))
        (should-not (string-search "made at a.el:18" (buffer-string)))
        (call-interactively (key-binding (kbd "RET"))))
      (harness-ui-patch-review-test--wait-text popout "made at a\\.el:18")
      ;; On the name of the file: that file in Ediff.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^  ▾ a\\.el +1 thread$")
        (beginning-of-line)
        (should (equal "a.el" (get-text-property (point) 'change-review-file)))
        (call-interactively (key-binding (kbd "RET"))))
      (let ((control (harness-ui-patch-review-test--control review 0)))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
      ;; d on the header: the same as RET, the line in sight.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "● [^ ]+ · line 18 ·")
        (beginning-of-line)
        (should (eq #'change-review-ui-show-in-diff (key-binding "d")))
        (call-interactively (key-binding "d")))
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review))))
        (should (= 18 (with-current-buffer new
                        (save-excursion (goto-char (window-point (get-buffer-window new)))
                                        (line-number-at-pos)))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-shows-earlier-rounds-as-closed-threads ()
  "The comments of the rounds of feedback a task was sent back with before
there were threads show as closed threads: they are not to do, but are there
to see, with the revision each was written against."
  (harness-ui-patch-review-test-with-task
    (harness-ui-patch-review-test--give-branch board id)
    (let ((tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
      (harness-tasks--set
       id :feedback
       (list (list :at (- (float-time) 3600)
                   :text (concat "Nearly there.\n\n"
                                 "My comments on the diff of your branch task/fix (at " (substring tip 0 7)
                                 ") against main (merge base 7654321), each under the lines it is about:\n\n"
                                 "> diff --git a/a.el b/a.el\n> @@ -1,2 +1,2 @@\n>  (setq a1 1)\n"
                                 "> -(setq a2 2)\n> +(setq a2 'two)\n\nWhy two?\n"))))
      ;; The board hears of the round before the report opens: a report
      ;; that sees a round arrive meanwhile closes, the review decided.
      (harness-test-wait (lambda () (with-current-buffer board
                                      (plist-get (harness-ui-tasks--find id) :feedback)))
                         5 "the board to hear of the feedback")
      (let* ((popout (harness-ui-patch-review-test--report board id))
             (review (gethash id harness-ui-patch-review--reviews))
             (set (harness-ui-patch-review--r-set review)))
        (harness-ui-patch-review-test--wait-text popout "^Changes (6) .*   0 open, 2 closed")
        ;; Two threads: the words on the change, and the comment on a.el:2.
        (should (= 2 (length (change-review-set-threads set))))
        (should (cl-every (lambda (th) (not (change-review-thread-open-p th))) (change-review-set-threads set)))
        (let* ((thread (cl-find-if #'change-review-thread-file (change-review-set-threads set)))
               (root (change-review-thread-root thread)))
          (should (equal "Why two?" (change-review-comment-body root)))
          (should (equal (substring tip 0 7) (substring (change-review-comment-revision root) 0 7)))
          (should (equal "a.el" (change-review-thread-file thread)))
          (should (eql 2 (change-review-thread-line thread))))
        (should (string-match-p "^  [✓ ] M  a\\.el .*   1 closed" (harness-ui-patch-review-test--text popout)))))))

(ert-deftest harness-ui-patch-review-feedback-sent-ends-the-ediff-of-an-earlier-commit-too ()
  "The feedback sent while the code of an earlier commit shows over the review's
Ediff ends both, and gives the frame back as it was before them."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (task (with-current-buffer board (harness-ui-tasks--find id)))
           (v1 (harness-ui-patch-review--r-tip review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (layout (harness-ui-patch-review-test--layout)))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-ui-patch-review-ediff review 0)
      (let ((control (harness-ui-patch-review-test--control review 0)))
        (harness-test-await (change-review-visit set two v1))
        (let* ((snapshot (harness-ui-patch-review-test--snapshot review v1))
               (older (harness-ui-patch-review-test--control snapshot 0)))
          (should (buffer-live-p control))
          (should (buffer-live-p older))
          (harness-ui-patch-review--on-event
           "task/changed" (list (plist-put (plist-put (copy-sequence task) :state "active")
                                           :feedback (list (list :text "More." :at (float-time))))))
          (should-not (buffer-live-p older))
          (should-not (buffer-live-p control))
          (should-not (harness-ui-patch-review--r-ediff snapshot))
          (should-not (harness-ui-patch-review--r-ediff review))
          (should (equal layout (harness-ui-patch-review-test--layout)))
          (should (buffer-live-p popout)))))))

(ert-deftest harness-ui-patch-review-a-task-that-goes-takes-the-ediff-of-an-earlier-commit-with-it ()
  "A task deleted while only the code of an earlier commit shows in Ediff:
the Ediff ends, the frame is as it was before it."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (v1 (harness-ui-patch-review--r-tip review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (layout (harness-ui-patch-review-test--layout)))
      (ignore popout)
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-test-await (change-review-visit set two v1))
      (let* ((snapshot (harness-ui-patch-review-test--snapshot review v1))
             (control (harness-ui-patch-review-test--control snapshot 0))
             (buffers (harness-ui-patch-review--ediff-buffers snapshot)))
        (should (cl-every #'buffer-live-p buffers))
        (harness-ui-patch-review--on-event "task/deleted" (list id))
        (should-not (cl-some #'buffer-live-p buffers))
        (should-not (buffer-live-p control))
        (should-not (gethash id harness-ui-patch-review--reviews))
        (should (equal (mapcar #'cdr layout) (mapcar #'cdr (harness-ui-patch-review-test--layout))))))))

(ert-deftest harness-ui-patch-review-goes-to-the-box-beside-ediff ()
  "While Ediff compares a file the report's box stays in sight under it; e
goes to it, point at its end, unless a draft of yours is under the difference,
which it edits; C-c C-d in the report goes back to Ediff, which has not
been left."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review)))
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (box (get-buffer-window popout t)))
        (should (window-live-p box))
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-edit-comment (key-binding "e")))
          (should (string-search "[Edit draft/box] e" (harness-ui-patch-review-test--text control)))
          ;; No thread at the difference yet: e is the box, and says why.
          (let (said)
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args) (setq said (apply #'format format-string args)))))
              (call-interactively #'harness-ui-patch-review-edit-comment))
            (should (string-prefix-p "No draft of yours here. The feedback: " said))))
        (should (eq box (selected-window)))
        (should (eq popout (window-buffer box)))
        (with-current-buffer popout
          (should (= (point) harness-compose-end))
          (insert "Both."))
        (should (equal "Both." (with-current-buffer popout (harness-compose-text))))
        ;; C-c C-d is on the report's keys; it goes back to Ediff.
        (should (eq #'harness-ui-patch-review-open (key-binding (kbd "C-c C-d"))))
        (harness-ui-patch-review-test--press #'harness-ui-patch-review-open)
        (should (eq control (window-buffer (selected-window))))
        (should (harness-ui-patch-review--r-ediff review))
        ;; A comment on the first difference, then e edits it.
        (with-current-buffer control
          (harness-ui-patch-review-test--comment "Why two?")
          (let ((change-review-ui-read-function
                 (lambda (_prompt initial callback)
                   (should (equal "Why two?" initial))
                   (funcall callback "Why two, of all numbers?"))))
            (call-interactively #'harness-ui-patch-review-edit-comment)))
        (should (equal "Why two, of all numbers?"
                       (change-review-comment-body
                        (change-review-thread-root (car (change-review-set-threads set))))))
        ;; In a version, by the line at point: line 18 has no thread, so the box.
        (with-current-buffer new
          (goto-char (point-min))
          (forward-line 17)
          (should (eq #'harness-ui-patch-review-edit-comment (key-binding "e")))
          (call-interactively #'harness-ui-patch-review-edit-comment))
        (should (eq box (selected-window)))
        (harness-ui-patch-review-test--press #'harness-ui-patch-review-open)
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-replies-in-a-thread-to-lines-of-a-version ()
  "C-c > with lines selected in a version Ediff compares starts a reply in a thread
in the report's box: a card whose reference is the file, the side, the lines
and the revision, with the lines themselves; point goes to the box, under the
card, where the words go.  Without a region it is still the library's quote
reply."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews)))
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (old (nth 1 (harness-ui-patch-review--ediff-buffers review)))
             (box (get-buffer-window popout t)))
        (should (window-live-p box))
        (with-current-buffer new
          (should (eq #'harness-ui-patch-review-thread-reply (key-binding (kbd "C-c >"))))
          (setq-local transient-mark-mode t)
          (goto-char (point-min))
          (forward-line 17)
          (push-mark (point) t t)
          (forward-line 2)
          (should (use-region-p))
          (let ((lines (buffer-substring-no-properties (mark) (point))))
            (call-interactively #'harness-ui-patch-review-thread-reply)
            (should-not (region-active-p))
            (with-current-buffer popout
              (should (equal "[reply 1]\n" (harness-compose-text)))
              (should (= (point) harness-compose-end))
              (let* ((ref (car (harness-thread-refs (plist-get (car harness-compose-attachments) :thread)))))
                (should (equal "diff" (plist-get ref :kind)))
                (should (equal "a.el" (plist-get ref :file)))
                (should (equal "new" (plist-get ref :side)))
                (should (equal 18 (plist-get ref :line)))
                (should (equal 19 (plist-get ref :end)))
                (should (equal (harness-ui-patch-review--r-tip review) (plist-get ref :revision)))
                (should (equal (string-trim-right lines "\n+") (plist-get ref :text)))
                ;; A click shows the lines in Ediff.
                (should (functionp harness-compose-thread-open-function))))
            (should (eq box (selected-window)))
            (with-current-buffer popout
              (insert "Why a symbol?")
              (pcase-let ((`(,text . ,atts) (harness-compose-take)))
                (should (equal "" text))
                (should (equal "Why a symbol?" (plist-get (car atts) :response)))))))
        ;; The merge base's version is the old side.
        (with-current-buffer popout (harness-compose-clear))
        (with-current-buffer old
          (setq-local transient-mark-mode t)
          (goto-char (point-min))
          (push-mark (point) t t)
          (forward-line 1)
          (call-interactively #'harness-ui-patch-review-thread-reply))
        (with-current-buffer popout
          (should (equal "old" (plist-get (car (harness-thread-refs (plist-get (car harness-compose-attachments) :thread))) :side)))
          (should (equal 1 (plist-get (car (harness-thread-refs (plist-get (car harness-compose-attachments) :thread))) :line))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-box-stays-in-sight-when-the-report-draws ()
  "The report drawn again -- a file approved in Ediff -- leaves the window
beside Ediff on the box: a window that is not selected loses its point when
the text is erased, so the review puts it back.  A limit left when no Ediff is
under way is let go on the next drawing, and the control panel's help is cut
between buttons when it does not fit."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (original (buffer-local-value 'harness-ui-popout--max-height popout)))
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (box (get-buffer-window popout t))
             (range (lambda () (with-current-buffer popout
                                 (cons harness-compose-start harness-compose-end)))))
        (with-current-buffer control
          (harness-ui-patch-review-test--comment "Why two?")
          (call-interactively #'harness-ui-patch-review-approve-ediff)
          ;; The help: in one line where it fits, cut between buttons where not.
          (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 400)))
            (should-not (string-search "\n" (harness-ui-patch-review--ediff-help))))
          (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 60)))
            (let ((help (harness-ui-patch-review--ediff-help)))
              (should (string-match-p "\\[Approve\\] a\n.*\\[Next file\\] N" help)))))
        (harness-ui-patch-review-test--wait-text popout "^  ✔ M  a\\.el")
        (should (<= (car (funcall range)) (window-point box) (cdr (funcall range))))
        (should (eq (selected-window) (get-buffer-window control)))
        ;; A killed Ediff leaves the limit: the next drawing lets go of it.
        (with-current-buffer popout
          (setq-local harness-ui-patch-review--box-limit (list original))
          (setq-local harness-ui-popout--max-height #'harness-ui-patch-review--box-fraction))
        (let ((ediff (harness-ui-patch-review--r-ediff review)))
          (setf (harness-ui-patch-review--r-ediff review) nil)
          (harness-ui-popout-refresh (list 'report id))
          (should-not (buffer-local-value 'harness-ui-patch-review--box-limit popout))
          (should (equal original (buffer-local-value 'harness-ui-popout--max-height popout)))
          (setf (harness-ui-patch-review--r-ediff review) ediff))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-box-comes-back-beside-ediff ()
  "The report closed during an Ediff comes back, in the same place, when e
asks for its box; an Ediff with the box turned off (the option nil) has the
whole frame, and e says why it cannot go to the box."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews)))
      (harness-ui-patch-review-ediff review 0)
      (let ((control (harness-ui-patch-review-test--control review 0)))
        ;; q on the report's content closes it; the box's text is kept.
        (with-current-buffer popout (goto-char harness-compose-end) (insert "Words."))
        (harness-ui-popout-close (list 'report id))
        (should-not (buffer-live-p popout))
        (should (buffer-live-p control))
        (with-current-buffer control
          (call-interactively #'harness-ui-patch-review-edit-feedback))
        (setq popout (harness-ui-popout-buffer (list 'report id)))
        (should popout)
        (let ((box (get-buffer-window popout t)))
          (should (window-live-p box))
          (should (eq 'bottom (window-parameter box 'window-side)))
          (should (window-parameter box 'no-delete-other-windows)))
        (should (equal "Words." (with-current-buffer popout (harness-compose-text))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
      ;; The option nil: Ediff has the frame, as it had before.
      (let ((harness-ui-patch-review-ediff-box-height nil)
            (layout (harness-ui-patch-review-test--layout)))
        (harness-ui-patch-review-ediff review 0)
        (let ((control (harness-ui-patch-review-test--control review 0)))
          (should-not (get-buffer-window (harness-ui-popout-buffer (list 'report id)) t))
          (with-current-buffer control
            (should-error (call-interactively #'harness-ui-patch-review-edit-feedback)
                          :type 'user-error)
            (call-interactively #'harness-ui-patch-review-ediff-quit)))
        (should (equal layout (harness-ui-patch-review-test--layout)))))))

(defun harness-ui-patch-review-test--only-ediff-and-box (review popout)
  "Check that REVIEW's Ediff has the selected frame but for the report POPOUT.
The windows are the control panel and the two versions the Ediff
compares, the tree of the files on the left, and the report's own side
window, once; those two are the windows Ediff leaves be
\(`no-delete-other-windows')."
  (let* ((ediff (harness-ui-patch-review--ediff-buffers review))
         (tree (harness-ui-patch-review--r-tree-buffer review))
         (windows (window-list nil 'nomini))
         (report (cl-remove-if-not (lambda (w) (eq popout (window-buffer w))) windows))
         (tree-window (get-buffer-window tree)))
    (should (= 1 (length report)))
    (should (eq 'bottom (window-parameter (car report) 'window-side)))
    (should (window-parameter (car report) 'no-delete-other-windows))
    (should (window-live-p tree-window))
    (should (eq 'left (window-parameter tree-window 'window-side)))
    (should (window-parameter tree-window 'no-delete-other-windows))
    (should (= 5 (length windows)))
    (dolist (buffer ediff)
      (should (get-buffer-window buffer)))
    (dolist (window (remq tree-window (remq (car report) windows)))
      (should (memq (window-buffer window) ediff))
      (should-not (window-parameter window 'no-delete-other-windows)))))

(ert-deftest harness-ui-patch-review-next-file-opens-no-second-report ()
  "N and P, going on from file to file, show the report in its box alone.
Doom Emacs sets back, at the end of an Ediff (`ediff-quit-hook'), the
window configuration it saved before Ediff began
\(`ediff-before-setup-hook'), which undoes what the end of the Ediff under
way does to the windows.  The configuration `save-window-excursion' sets
back after that has windows again for the buffers that were killed, and
Emacs shows in them the first buffer of its list but the current one: the
report's, used last after the board's.  The first of those windows was taken
for the report's box and kept by Ediff, so every file after it had the
report a second time, in the right split.  q gives the frame back as it
was."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (layout (harness-ui-patch-review-test--layout))
           ;; Every file in turn: none skipped as approved, none approved as left.
           (harness-ui-patch-review-skip-approved nil)
           (harness-ui-patch-review-auto-approve nil)
           (saved nil)
           (save (lambda () (setq saved (current-window-configuration))))
           (restore (lambda () (when (window-configuration-p saved) (set-window-configuration saved))))
           ;; Emacs shows `other-buffer' of the current buffer in a window it re-creates for
           ;; a killed buffer: the first of the buffer list but that one.  Have it the
           ;; report, next to the board in the main window, as the review leaves them.
           (report-first (lambda (start &rest args)
                           (dolist (buffer (buffer-list))
                             (unless (eq buffer popout) (bury-buffer buffer)))
                           (with-current-buffer board
                             (apply start args)))))
      (require 'ediff)
      (add-hook 'ediff-before-setup-hook save)
      (add-hook 'ediff-quit-hook restore t)
      (advice-add 'harness-ui-patch-review--start-ediff :around report-first)
      (unwind-protect
          (progn
            (harness-ui-patch-review-ediff review 0)
            (let ((control (harness-ui-patch-review-test--control review 0)))
              (harness-ui-patch-review-test--only-ediff-and-box review popout)
              ;; N twice, then P: each file in Ediff, the report only in its box.
              (dolist (step '((1 . harness-ui-patch-review-ediff-next-file)
                              (2 . harness-ui-patch-review-ediff-next-file)
                              (1 . harness-ui-patch-review-ediff-previous-file)))
                (with-current-buffer control (call-interactively (cdr step)))
                (setq control (harness-ui-patch-review-test--control review (car step)))
                (harness-ui-patch-review-test--only-ediff-and-box review popout))
              ;; The box is the report's: the same buffer, one window.
              (should (eq popout (harness-ui-popout-buffer (list 'report id))))
              (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
            (should-not (harness-ui-patch-review--r-ediff review))
            (should (equal layout (harness-ui-patch-review-test--layout)))
            (should (= 1 (length (get-buffer-window-list popout nil (selected-frame)))))
            (should (eq popout (window-buffer (selected-window)))))
        (advice-remove 'harness-ui-patch-review--start-ediff report-first)
        (remove-hook 'ediff-before-setup-hook save)
        (remove-hook 'ediff-quit-hook restore)))))

(ert-deftest harness-ui-patch-review-keeps-the-reports-own-window-for-its-box ()
  "The box Ediff leaves be is the report's own side window.  Another window
showing the report, one a window configuration put back has, is not: it is not
kept, and one that carries the mark from earlier loses it, so that Ediff's
layout takes it like any other window."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (box (get-buffer-window popout t))
           ;; Before the box in the order of the frame's windows, as a stray in
           ;; the main window's place is.
           (stray (split-window (frame-first-window) nil 'right)))
      (should (eq 'bottom (window-parameter box 'window-side)))
      (set-window-buffer stray popout)
      (set-window-parameter stray 'no-delete-other-windows t)
      ;; Where the review is made, in the main window: the stray comes first.
      (select-window (frame-first-window))
      (should (eq stray (get-buffer-window popout (selected-frame))))
      (should (eq box (harness-ui-patch-review--keep-box review)))
      (should (window-parameter box 'no-delete-other-windows))
      (should-not (window-parameter stray 'no-delete-other-windows))
      ;; Ediff then takes the frame but for the box: the report shows there alone.
      (harness-ui-patch-review-ediff review 0)
      (harness-ui-patch-review-test--control review 0)
      (harness-ui-patch-review-test--only-ediff-and-box review popout)
      (with-current-buffer (harness-ui-patch-review-test--control review 0)
        (call-interactively #'harness-ui-patch-review-ediff-quit)))))

(ert-deftest harness-ui-patch-review-feedback-sent-ends-the-ediff ()
  "Sending the feedback while Ediff shows -- the box beside it -- ends the
Ediff and gives the frame back; a task changing otherwise leaves it be."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (task (with-current-buffer board (harness-ui-tasks--find id)))
           (layout (harness-ui-patch-review-test--layout)))
      (harness-ui-patch-review-ediff review 0)
      (let ((control (harness-ui-patch-review-test--control review 0)))
        ;; The task changes while in review: nothing ends.
        (harness-ui-patch-review--on-event "task/changed" (list (plist-put (copy-sequence task) :name "Renamed")))
        (should (buffer-live-p control))
        (should (equal "Renamed" (change-review-set-title (harness-ui-patch-review--r-set review))))
        ;; A round of feedback arrives: it was sent.
        (harness-ui-patch-review--on-event
         "task/changed" (list (plist-put (plist-put (copy-sequence task) :state "active")
                                         :feedback (list (list :text "More." :at (float-time))))))
        (should-not (buffer-live-p control))
        (should-not (harness-ui-patch-review--r-ediff review))
        (should (equal layout (harness-ui-patch-review-test--layout)))
        (should (buffer-live-p popout))))))

(ert-deftest harness-ui-patch-review-comments-on-a-line-in-ediff ()
  "In either version Ediff compares, c comments on the line at point: a
thread of its own there, of the branch's line or of the merge base's."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review)))
      (ignore popout)
      (harness-ui-patch-review-ediff review 0)
      (let ((control (harness-ui-patch-review-test--control review 0))
            (buffers (harness-ui-patch-review--ediff-buffers review)))
        (with-current-buffer (nth 2 buffers)
          (goto-char (point-min))
          (forward-line 17)
          (should (= 18 (line-number-at-pos)))
          (should (eq #'harness-ui-patch-review-comment-line (key-binding "c")))
          (harness-ui-patch-review-comment-line "Why eighteen?"))
        (with-current-buffer (nth 1 buffers)
          (goto-char (point-min))
          (forward-line 1)
          (harness-ui-patch-review-comment-line "Was it better?"))
        (should (= 2 (length (change-review-set-threads set))))
        (let ((new (change-review-comment-location (change-review-thread-root (nth 0 (change-review-set-threads set)))))
              (old (change-review-comment-location (change-review-thread-root (nth 1 (change-review-set-threads set))))))
          (should (equal '(new 18) (list (change-review-location-side new) (change-review-location-line new))))
          (should (string-suffix-p "+(setq a18 'eighteen)" (change-review-location-excerpt new)))
          (should (equal '(old 2) (list (change-review-location-side old) (change-review-location-line old))))
          (should (string-suffix-p "-(setq a2 2)" (change-review-location-excerpt old))))
        ;; They show under their lines at once.
        (change-review-ui-flush)
        (with-current-buffer (nth 2 buffers)
          (should (cl-some (lambda (ov) (string-search "Why eighteen?" (or (overlay-get ov 'after-string) "")))
                           (overlays-in (point-min) (point-max)))))
        (with-current-buffer control
          (harness-ui-patch-review-ediff-quit))))))

;;;; Skipping the approved files, and approving those gone through

(defmacro harness-ui-patch-review-test-with-rows (review &rest body)
  "Run BODY in a buffer holding the changes of REVIEW as its report draws them.
The buffer is the report of REVIEW, as far as the rows and the keys go."
  (declare (indent 1))
  `(with-temp-buffer
     (setf (harness-ui-patch-review--r-popout ,review) (current-buffer))
     (insert (harness-ui-patch-review--section ,review (harness-ui-patch-review--counts ,review)))
     ,@body))

(defun harness-ui-patch-review-test--approve-paths (review &rest paths)
  "Approve the files of REVIEW at PATHS, as `A' does, without telling the harness."
  (dolist (path paths)
    (harness-ui-patch-review--approve
     review (harness-ui-patch-review-test--file review path) t t)))

(ert-deftest harness-ui-patch-review-skips-approved-files ()
  "The neighbour of a file, for n and p, for Ediff's N and P and for where
point lands, is the next one in the order the files show that is not
approved; with skipping off, the next one.  Ediff also leaves the files it
cannot compare, a binary one, and the last file has none after it."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (harness-ui-patch-review-skip-approved t))
      ;; a.el b.el d.el (c.el renamed) docs/é.txt img.bin new.el, as the tree shows them.
      (should (equal '(0 1 2 3 4 5) (harness-ui-patch-review--order review)))
      (harness-ui-patch-review-test--approve-paths review "b.el" "d.el")
      (should (eql 3 (harness-ui-patch-review--neighbor review 0 1)))
      (should (eql 0 (harness-ui-patch-review--neighbor review 3 -1)))
      (should (eql 5 (harness-ui-patch-review--neighbor review 4 1)))
      (should-not (harness-ui-patch-review--neighbor review 5 1))
      (should-not (harness-ui-patch-review--neighbor review 0 -1))
      (let ((harness-ui-patch-review-skip-approved nil))
        (should (eql 1 (harness-ui-patch-review--neighbor review 0 1)))
        (should (eql 2 (harness-ui-patch-review--neighbor review 3 -1))))
      ;; img.bin is binary: Ediff goes over it, approved or not.
      (should (eql 5 (harness-ui-patch-review--comparable review 3 1)))
      (should (eql 0 (harness-ui-patch-review--comparable review 3 -1)))
      (let ((harness-ui-patch-review-skip-approved nil))
        (should (eql 2 (harness-ui-patch-review--comparable review 3 -1)))
        (should (eql 5 (harness-ui-patch-review--comparable review 3 1))))
      ;; After Ediff, point goes to the next file to review: the file itself at the end.
      (should (eql 3 (harness-ui-patch-review--landing review 0)))
      (should (eql 5 (harness-ui-patch-review--landing review 5)))
      (let ((harness-ui-patch-review-skip-approved nil))
        (should (eql 1 (harness-ui-patch-review--landing review 0))))
      ;; How many approved files a step went over.
      (should (= 2 (harness-ui-patch-review--between review 0 3)))
      (should (= 2 (harness-ui-patch-review--between review 3 0)))
      (should (= 0 (harness-ui-patch-review--between review 3 5)))
      ;; The order is the tree's: a flat list is the diff's.
      (setf (harness-ui-patch-review--r-tree review) nil)
      (should (equal '(0 1 2 3 4 5) (harness-ui-patch-review--order review))))))

(ert-deftest harness-ui-patch-review-steps-over-approved-rows ()
  "n and p move to the next and previous file that is not approved, and say how
many files they went over; with skipping off they stop at every file.  At the
end they say so, and when only approved files are left that way, that."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (id (harness-ui-patch-review--r-id review))
           (harness-ui-patch-review-skip-approved t)
           (said nil)
           (at (lambda () (cdr (harness-ui-patch-review--at-point)))))
      (harness-ui-patch-review-test--approve-paths review "b.el" "d.el")
      (harness-ui-patch-review-test-with-rows review
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args) (push (apply #'format format-string args) said))))
          (goto-char (harness-ui-patch-review--row-start id 0))
          (harness-ui-patch-review-next-file)
          (should (eql 3 (funcall at)))
          (should (equal "Skipped 2 files already approved; s stops skipping them" (car said)))
          (harness-ui-patch-review-previous-file)
          (should (eql 0 (funcall at)))
          ;; A count: two files on, the second not over an approved one.
          (setq said nil)
          (harness-ui-patch-review-next-file 2)
          (should (eql 4 (funcall at)))
          (should (equal "Skipped 2 files already approved; s stops skipping them" (car said)))
          ;; Off: each file in turn.
          (let ((harness-ui-patch-review-skip-approved nil))
            (harness-ui-patch-review-previous-file 2)
            (should (eql 2 (funcall at))))
          (goto-char (harness-ui-patch-review--row-start id 0))
          (setq said nil)
          (harness-ui-patch-review-previous-file)
          (should (eql 0 (funcall at)))
          (should (equal "That is the first file" (car said)))
          ;; Only approved files that way: it says so, and stays.
          (harness-ui-patch-review-test--approve-paths review "img.bin" "new.el")
          (goto-char (harness-ui-patch-review--row-start id 3))
          (harness-ui-patch-review-next-file)
          (should (eql 3 (funcall at)))
          (should (equal "The 2 files after this one are approved; s stops skipping them" (car said)))
          (goto-char (harness-ui-patch-review--row-start id 5))
          (let ((harness-ui-patch-review-skip-approved nil))
            (harness-ui-patch-review-next-file)
            (should (equal "That is the last file" (car said)))))))))

(ert-deftest harness-ui-patch-review-toggles-skipping-and-approving ()
  "s and u switch skipping the approved files and approving the files gone
through, from a button of the changes as from the key on a row, a thread, the
tree beside Ediff and Ediff's two versions, and the changes show which is on."
  (harness-ui-patch-review-test-with-repo
    (let ((harness-ui-patch-review-skip-approved t)
          (harness-ui-patch-review-auto-approve t)
          (review (harness-ui-patch-review-test--review repo))
          (said nil))
      (should (string-match-p "\\[✓\\] Skip approved s +\\[✓\\] Auto-approve u +\\[✓\\] Tree t"
                              (harness-ui-patch-review--section review nil)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said))))
        (harness-ui-patch-review-toggle-skip-approved)
        (should-not harness-ui-patch-review-skip-approved)
        (should (equal "Files already approved are visited like the others" (car said)))
        (should (string-match-p "\\[ \\] Skip approved s +\\[✓\\] Auto-approve u"
                                (harness-ui-patch-review--section review nil)))
        (harness-ui-patch-review-toggle-skip-approved)
        (should harness-ui-patch-review-skip-approved)
        (should (equal "Files already approved are skipped" (car said)))
        (harness-ui-patch-review-toggle-auto-approve)
        (should-not harness-ui-patch-review-auto-approve)
        (should (equal "Files are approved only when you approve them" (car said)))
        (should (string-match-p "\\[✓\\] Skip approved s +\\[ \\] Auto-approve u"
                                (harness-ui-patch-review--section review nil)))
        ;; A click on a button does it too.
        (with-temp-buffer
          (insert (harness-ui-patch-review--section review nil))
          (goto-char (point-min))
          (search-forward "[ ] Auto-approve")
          (push-button (match-beginning 0))
          (should harness-ui-patch-review-auto-approve)
          (goto-char (point-min))
          (search-forward "[✓] Skip approved")
          (push-button (match-beginning 0))
          (should-not harness-ui-patch-review-skip-approved)))
      ;; The keys, wherever the changes are drawn.
      (dolist (map (list harness-ui-patch-review--row-map harness-ui-patch-review--dir-map
                         harness-ui-patch-review--thread-map harness-ui-patch-review--common-map
                         harness-ui-patch-review-lines-mode-map))
        (should (eq #'harness-ui-patch-review-toggle-skip-approved (lookup-key map "s")))
        (should (eq #'harness-ui-patch-review-toggle-auto-approve (lookup-key map "u"))))
      ;; On unless the user says otherwise.
      (should (eq t (eval (car (get 'harness-ui-patch-review-skip-approved 'standard-value)))))
      (should (eq t (eval (car (get 'harness-ui-patch-review-auto-approve 'standard-value)))))
      (should (eq t (eval (car (get 'harness-ui-patch-review-ediff-tree 'standard-value))))))))

(ert-deftest harness-ui-patch-review-approves-a-file-gone-through-without-a-comment ()
  "A file left once the reviewer was at its last difference is approved when the
user has no draft on it and no open thread they wrote in.  A thread closed, or
one an agent started, is no comment of the user's; with the option off, or not
gone through, it is not approved."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (harness-ui-patch-review-auto-approve t)
           (file (lambda (path) (harness-ui-patch-review-test--file review path)))
           (user (change-review-user "Noah" "noah@example.org"))
           (agent (change-review-agent "Claude" :session "sess-1" :tool-call "toolu_1"))
           (said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said))))
        ;; Not gone through, or the option off: nothing.
        (should-not (harness-ui-patch-review--auto-approve review (funcall file "a.el") nil))
        (let ((harness-ui-patch-review-auto-approve nil))
          (should-not (harness-ui-patch-review--auto-approve review (funcall file "a.el") t)))
        (should-not (harness-ui-patch-review--approved-p review (funcall file "a.el")))
        ;; Gone through, nothing said: approved, and it says so.
        (should (harness-ui-patch-review--auto-approve review (funcall file "a.el") t))
        (should (harness-ui-patch-review--approved-p review (funcall file "a.el")))
        (should (harness-ui-patch-review--seen-p review (funcall file "a.el")))
        (should (string-prefix-p "Approved a.el: you went through it and made no comment on it" (car said)))
        ;; Approved already: nothing more to do.
        (setq said nil)
        (should-not (harness-ui-patch-review--auto-approve review (funcall file "a.el") t))
        (should-not said)
        ;; A draft of the user's, or a thread of theirs not closed yet, sent in an
        ;; earlier round: the file is not settled.
        (harness-ui-patch-review-test--comment-on review "d.el" '(:new . 6) "Why six?")
        (should-not (harness-ui-patch-review--auto-approve review (funcall file "d.el") t))
        (harness-ui-patch-review-test--comment-on review "docs/é.txt" nil "A caption?" :sent (float-time))
        (should-not (harness-ui-patch-review--auto-approve review (funcall file "docs/é.txt") t))
        (should-not (harness-ui-patch-review--approved-p review (funcall file "d.el")))
        ;; The user closed their thread: settled.
        (let ((comment (harness-ui-patch-review-test--comment-on
                        review "new.el" nil "Needs a test" :sent (float-time))))
          (change-review-close set (harness-ui-patch-review-test--thread-of review comment) :author user)
          (should (harness-ui-patch-review--auto-approve review (funcall file "new.el") t)))
        ;; A thread an agent started is the agent's, open or not.
        (change-review-comment set "I did this because the loop needs it." :author agent :sent (float-time)
                               :location (harness-ui-patch-review--location (funcall file "b.el") nil))
        (should (harness-ui-patch-review--auto-approve review (funcall file "b.el") t))
        ;; But the user's draft in the agent's thread is a comment of theirs.
        (let ((comment (change-review-comment
                        set "Why is that?" :author agent :sent (float-time)
                        :location (harness-ui-patch-review--location (funcall file "img.bin") nil))))
          (change-review-reply set comment "Then explain it." :author user)
          (should-not (harness-ui-patch-review--auto-approve review (funcall file "img.bin") t)))))))

(ert-deftest harness-ui-patch-review-approves-what-the-reviewer-goes-through ()
  "Leaving a file in Ediff -- q here, N, P and n past the last difference alike --
approves it when the reviewer was at its last difference and made no comment on
it; quitting at the first of two differences approves nothing, a comment
withholds the approval, and the harness keeps the approval as it keeps one made
with a."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (harness-ui-patch-review-auto-approve t)
           (harness-ui-patch-review-skip-approved t)
           (file (lambda (path) (harness-ui-patch-review-test--file review path)))
           (approved (lambda (path) (harness-ui-patch-review--approved-p review (funcall file path))))
           (seen (lambda (path) (harness-ui-patch-review--seen-p review (funcall file path)))))
      (ignore popout)
      ;; q at the first of a.el's two differences: seen, not gone through.
      (harness-ui-patch-review-ediff review 0)
      (with-current-buffer (harness-ui-patch-review-test--control review 0)
        (should (= 2 ediff-number-of-differences))
        (should-not (plist-get (harness-ui-patch-review--r-ediff review) :reached))
        (call-interactively #'harness-ui-patch-review-ediff-quit))
      (should (funcall seen "a.el"))
      (should-not (funcall approved "a.el"))
      ;; Again, at its last difference: approved.
      (harness-ui-patch-review-ediff review 0)
      (with-current-buffer (harness-ui-patch-review-test--control review 0)
        (harness-ui-patch-review-next-difference)
        (should (= 1 ediff-current-difference))
        (should (plist-get (harness-ui-patch-review--r-ediff review) :reached))
        (call-interactively #'harness-ui-patch-review-ediff-quit))
      (should (funcall approved "a.el"))
      (harness-test-wait (lambda () (member "a.el" (cadr (harness-ui-patch-review-test--viewed id))))
                         5 "the harness to keep the approval")
      ;; d.el has one difference, so it is gone through as it opens; a comment
      ;; on it withholds the approval.
      (harness-ui-patch-review-ediff review 2)
      (with-current-buffer (harness-ui-patch-review-test--control review 2)
        (should (plist-get (harness-ui-patch-review--r-ediff review) :reached))
        (harness-ui-patch-review-test--comment "Why six?")
        (call-interactively #'harness-ui-patch-review-ediff-quit))
      (should (funcall seen "d.el"))
      (should-not (funcall approved "d.el"))
      ;; Off: gone through, not approved.
      (let ((harness-ui-patch-review-auto-approve nil))
        (harness-ui-patch-review-ediff review 3)
        (with-current-buffer (harness-ui-patch-review-test--control review 3)
          (call-interactively #'harness-ui-patch-review-ediff-quit)))
      (should (funcall seen "docs/é.txt"))
      (should-not (funcall approved "docs/é.txt"))
      ;; Going on with N approves the file left too.
      (harness-ui-patch-review-ediff review 3)
      (with-current-buffer (harness-ui-patch-review-test--control review 3)
        (call-interactively #'harness-ui-patch-review-ediff-next-file))
      (harness-ui-patch-review-test--control review 5)
      (should (funcall approved "docs/é.txt"))
      (with-current-buffer (harness-ui-patch-review-test--control review 5)
        (call-interactively #'harness-ui-patch-review-ediff-quit)))))

(ert-deftest harness-ui-patch-review-ediff-goes-on-to-files-not-approved ()
  "N and P go on to the next and previous file that is not approved, q puts point
on the next file to review, and s in the control panel switches skipping off and
on; n at the last difference, and N, say when there is no file left to review."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (harness-ui-patch-review-skip-approved t)
           (harness-ui-patch-review-auto-approve nil)
           (said nil)
           (control nil))
      (harness-ui-patch-review-test--approve-paths review "b.el" "d.el")
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said))))
        ;; q puts point on the next file to review: b.el and d.el are approved.
        (harness-ui-patch-review-ediff review 0)
        (with-current-buffer (harness-ui-patch-review-test--control review 0)
          (call-interactively #'harness-ui-patch-review-ediff-quit))
        (with-current-buffer popout
          (should (eql 3 (cdr (harness-ui-patch-review--at-point))))
          (should (eql (point) (window-point (selected-window)))))
        ;; N goes to é.txt, P comes back.
        (harness-ui-patch-review-ediff review 0)
        (setq control (harness-ui-patch-review-test--control review 0))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-next-file))
        (setq control (harness-ui-patch-review-test--control review 3))
        (should (member "Skipped 2 files already approved; s stops skipping them" said))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-previous-file))
        (setq control (harness-ui-patch-review-test--control review 0))
        ;; s switches skipping off in the panel, the help says so, and N stops at b.el.
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-toggle-skip-approved (key-binding "s")))
          (should (string-search "[✓ Skip approved] s" (harness-ui-patch-review-test--text control)))
          (call-interactively (key-binding "s"))
          (should-not harness-ui-patch-review-skip-approved)
          (should (string-search "[✗ Skip approved] s" (harness-ui-patch-review-test--text control)))
          (call-interactively #'harness-ui-patch-review-ediff-next-file))
        (setq control (harness-ui-patch-review-test--control review 1))
        (with-current-buffer control (call-interactively (key-binding "s")))
        (should harness-ui-patch-review-skip-approved)
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))
        ;; Everything else approved: nothing left to review after a.el.
        (harness-ui-patch-review-test--approve-paths review "docs/é.txt" "img.bin" "new.el")
        (harness-ui-patch-review-ediff review 0)
        (setq control (harness-ui-patch-review-test--control review 0))
        (with-current-buffer control
          (setq said nil)
          (harness-ui-patch-review-next-difference)
          (should (= 1 ediff-current-difference))
          (harness-ui-patch-review-next-difference)
          (should (equal "Last difference of the last file to review; q goes back to the report" (car said)))
          (should-not harness-ui-patch-review--next-file-offer)
          (setq said nil)
          (call-interactively #'harness-ui-patch-review-ediff-next-file)
          (should (equal "No file left to review that way, the ones after this one approved; q goes back to the report"
                         (car said)))
          (call-interactively #'harness-ui-patch-review-ediff-quit))
        ;; The last file of all.
        (harness-ui-patch-review-ediff review 5)
        (with-current-buffer (harness-ui-patch-review-test--control review 5)
          (setq said nil)
          (call-interactively #'harness-ui-patch-review-ediff-next-file)
          (should (equal "That is the last file; q goes back to the report" (car said)))
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

;;;; The directories of the tree

(ert-deftest harness-ui-patch-review-folds-directories ()
  "TAB, RET or a click on a directory folds it, and its files go from the changes;
n and p, or q from Ediff, to a file in a folded directory unfold it; a on a
directory approves its files, and stops approving them when they all are."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (harness-ui-patch-review-skip-approved nil))
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^  ▾ docs/")
        (beginning-of-line)
        (should (equal "docs" (get-text-property (point) 'harness-ui-patch-review-dir)))
        (should (eq #'harness-ui-patch-review-toggle-directory (key-binding (kbd "TAB"))))
        (should (eq #'harness-ui-patch-review-toggle-directory (key-binding (kbd "RET"))))
        (should (eq #'harness-ui-patch-review-mouse-toggle-directory (lookup-key (get-text-property (point) 'keymap) [mouse-1])))
        (call-interactively (key-binding (kbd "TAB"))))
      (harness-ui-patch-review-test--wait-text popout "^  ▸ docs/  1 file  \\+1 −0$")
      (should-not (string-search "é.txt" (harness-ui-patch-review-test--text popout)))
      (should (gethash "docs" (harness-ui-patch-review--r-folded review)))
      ;; The files of other directories stay, and so does the order: n from d.el goes
      ;; to the folded file, and unfolds what hides it.
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 2))
        (call-interactively (key-binding "n")))
      (harness-ui-patch-review-test--wait-text popout "^      A  é\\.txt")
      (should (string-match-p "^  ▾ docs/" (harness-ui-patch-review-test--text popout)))
      (with-current-buffer popout
        (should (eql 3 (cdr (harness-ui-patch-review--at-point)))))
      ;; a on a directory: its files.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^  ▾ docs/")
        (beginning-of-line)
        (call-interactively (key-binding "a")))
      (harness-ui-patch-review-test--wait-text popout "^    ✔ A  é\\.txt")
      (should (harness-ui-patch-review--approved-p
               review (harness-ui-patch-review-test--file review "docs/é.txt")))
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^  ▾ docs/")
        (beginning-of-line)
        (call-interactively (key-binding "a")))
      ;; No longer approved, and still seen.
      (harness-ui-patch-review-test--wait-text popout "^    ✓ A  é\\.txt")
      (should-not (harness-ui-patch-review--approved-p
                   review (harness-ui-patch-review-test--file review "docs/é.txt")))
      ;; Folded, and d.el, the file before it, left in Ediff: point lands on the
      ;; next file, in the folded directory, which unfolds.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^  ▾ docs/")
        (beginning-of-line)
        (call-interactively (key-binding (kbd "TAB"))))
      (harness-ui-patch-review-test--wait-text popout "^  ▸ docs/")
      (harness-ui-patch-review-ediff review 2)
      (with-current-buffer (harness-ui-patch-review-test--control review 2)
        (call-interactively #'harness-ui-patch-review-ediff-quit))
      (harness-ui-patch-review-test--wait-text popout "^  ▾ docs/")
      (with-current-buffer popout
        (should (eql 3 (cdr (harness-ui-patch-review--at-point))))))))

;;;; In the review banner of the task's session

(defun harness-ui-patch-review-test--banner (board id sid)
  "Give task ID its branch and open its session's chat; return the chat buffer.
The chat is in the selected window, with the review banner showing the
changes once the branch is read."
  (harness-ui-patch-review-test--give-branch board id)
  (let ((chat (harness-ui-display-session sid)))
    (set-window-buffer (selected-window) chat)
    (harness-test-wait (lambda () (harness-ui-review--task sid)) 5 "the session's task")
    (harness-ui-patch-review-test--wait-text chat "^Changes (6)")
    (harness-ui-patch-review-test--wait-text chat "^    M  a\\.el")
    chat))

(ert-deftest harness-ui-patch-review-shows-the-changes-in-the-banner ()
  "The review banner of the task's session shows the changes -- the tree and the
threads -- between the report and [Verify], with no click on [Review Changes]:
its rows have the keys of the report's, and it follows what happens to the
review, an approval or a thread."
  (harness-ui-patch-review-test-with-task
    (let* ((chat (harness-ui-patch-review-test--banner board id sid))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (text (harness-ui-patch-review-test--text chat)))
      (should (memq chat (harness-ui-patch-review--r-banners review)))
      (should (< (string-match "^Handed in" text)
                 (string-match "^Changes (6)   0 of 6 files viewed, 6 left" text)
                 (string-match "^    M  a\\.el +\\+2 −2$" text)
                 (string-match "^Threads  \\[open 0\\]" text)
                 (string-match "No open threads\\." text)
                 (string-match "\\[Verify\\]" text)))
      (should (string-match-p "^  ▾ docs/  1 file  \\+1 −0$" text))
      (should (string-match-p "^  \\[✓\\] Skip approved s +\\[✓\\] Auto-approve u +\\[✓\\] Tree t$" text))
      ;; The rows, drawn with the banner's text, keep the keys they have in the report.
      (with-current-buffer chat
        (goto-char (harness-ui-patch-review--row-start id 0))
        (should (eq #'harness-ui-patch-review-ediff (key-binding (kbd "RET"))))
        (should (eq #'harness-ui-patch-review-approve (key-binding "a")))
        (should (eq #'harness-ui-patch-review-next-file (key-binding "n")))
        (should (eq #'harness-ui-patch-review-toggle-skip-approved (key-binding "s")))
        (should (eq set change-review-ui--set))
        ;; The box is the session's: typing in it is no key of a row.
        (goto-char harness-compose-end)
        (should (eq #'self-insert-command (key-binding "a"))))
      ;; T goes to the threads in the same buffer; t shows the files flat and a tree again.
      (select-window (get-buffer-window chat))
      (with-current-buffer chat
        (goto-char (harness-ui-patch-review--row-start id 0))
        (call-interactively (key-binding "T"))
        (should (string-prefix-p "Threads" (buffer-substring-no-properties (point) (point-max))))
        (goto-char (harness-ui-patch-review--row-start id 0))
        (call-interactively (key-binding "t")))
      (harness-ui-patch-review-test--wait-text chat "^    A  docs/é\\.txt")
      (should-not (string-match-p "^  ▾ docs/" (harness-ui-patch-review-test--text chat)))
      (with-current-buffer chat
        (goto-char (harness-ui-patch-review--row-start id 0))
        (call-interactively (key-binding "t")))
      (harness-ui-patch-review-test--wait-text chat "^  ▾ docs/")
      ;; An approval, a thread -- by the user or the agent -- shows in the banner.
      (harness-ui-patch-review--approve review (harness-ui-patch-review-test--file review "a.el") t t)
      (harness-ui-patch-review--refresh review)
      (harness-ui-patch-review-test--wait-text chat "^  ✔ M  a\\.el")
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")
      (harness-ui-patch-review-test--wait-text chat "^    ┃      Why two\\?$")
      (should (string-match-p "^Threads  \\[open 1\\]" (harness-ui-patch-review-test--text chat)))
      (should (string-match-p "^  ✔ M  a\\.el .*   1 open   1 draft" (harness-ui-patch-review-test--text chat)))
      ;; The compose box keeps what was typed in it as the banner draws again.
      (with-current-buffer chat
        (goto-char harness-compose-end)
        (insert "the review so far"))
      (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?")
      (harness-ui-patch-review-test--wait-text chat "Who used b3\\?")
      (should (equal "the review so far" (with-current-buffer chat (harness-compose-text))))
      ;; A task sent back has no banner to draw: its chats are forgotten, and no
      ;; refresh draws their tails again.
      (let ((task (with-current-buffer board (harness-ui-tasks--find id))))
        (setf (harness-ui-patch-review--r-task review) (plist-put (copy-sequence task) :state "active"))
        (harness-ui-patch-review--refresh review)
        (should-not (harness-ui-patch-review--r-banners review))
        (setf (harness-ui-patch-review--r-task review) task)
        (cl-pushnew chat (harness-ui-patch-review--r-banners review)))
      ;; [Review Changes] still pops the report out, with the changes too.
      (let ((popout (progn (harness-ui-report-popout (with-current-buffer board (harness-ui-tasks--find id)))
                           (harness-ui-popout-buffer (list 'report id)))))
        (harness-ui-patch-review-test--wait-text popout "^Changes (6)")
        (should (memq chat (harness-ui-patch-review--r-banners review)))
        (should (eq popout (harness-ui-patch-review--r-popout review)))))))

(ert-deftest harness-ui-patch-review-keeps-the-readers-place-in-the-banner ()
  "A key that changes what the banner shows -- an approval, a thread closed --
draws its tail again; point stays on the file or the thread it was on, or, once
that is gone, on the line where it was, and the window shows it where it did."
  (harness-ui-patch-review-test-with-task
    (let* ((chat (harness-ui-patch-review-test--banner board id sid))
           (review (gethash id harness-ui-patch-review--reviews))
           (harness-ui-patch-review-skip-approved nil))
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")
      (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?")
      (harness-ui-patch-review-test--wait-text chat "Who used b3\\?")
      (select-window (get-buffer-window chat))
      (with-current-buffer chat
        ;; On the row of b.el: a approves it, and point stays on the row.
        (goto-char (harness-ui-patch-review--row-start id 1))
        (let ((line (count-screen-lines (window-start) (point))))
          (call-interactively (key-binding "a"))
          (harness-ui-patch-review-test--wait-text chat "^  ✔ D  b\\.el")
          (should (eql 1 (cdr (harness-ui-patch-review--at-point))))
          (should (= line (count-screen-lines (window-start) (point)))))
        ;; On a comment of a thread: closing the thread takes it from the open ones,
        ;; and point stays among the threads, not in the box.
        (goto-char (point-min))
        (re-search-forward "^    ┃      Why two\\?$")
        (should (< (point) harness-compose-start))
        (call-interactively (key-binding "x")))
      (harness-ui-patch-review-test--wait-text chat "Why two\\?" t)
      (with-current-buffer chat
        (should (< (point) harness-compose-start))
        (should (equal id (get-text-property (line-beginning-position) 'harness-ui-patch-review-task)))
        ;; In the middle of what was a thread, it is at the start of the thread now there.
        (should (get-text-property (point) 'change-review-thread-start))
        (should (string-search "Who used b3?" (buffer-substring-no-properties
                                               (point) (min (point-max) (+ (point) 400)))))))))

(ert-deftest harness-ui-patch-review-reviews-from-the-banner ()
  "RET on a file of the banner compares it in Ediff, the report opening beside it
for its box as it does from the report; q gives the frame back, the session as it
was, with point on the next file to review."
  (harness-ui-patch-review-test-with-task
    (let* ((chat (harness-ui-patch-review-test--banner board id sid))
           (review (gethash id harness-ui-patch-review--reviews))
           (layout (harness-ui-patch-review-test--layout))
           (harness-ui-patch-review-auto-approve nil))
      (should-not (harness-ui-popout-buffer (list 'report id)))
      (select-window (get-buffer-window chat))
      (with-current-buffer chat
        (goto-char (harness-ui-patch-review--row-start id 0))
        (call-interactively (key-binding (kbd "RET"))))
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (popout (harness-ui-popout-buffer (list 'report id))))
        (should (eq chat (harness-ui-patch-review--r-origin review)))
        ;; The box: the report, opened for it, at the bottom of the frame.
        (should popout)
        (let ((box (get-buffer-window popout t)))
          (should (window-live-p box))
          (should (eq 'bottom (window-parameter box 'window-side)))
          (should (window-parameter box 'no-delete-other-windows)))
        (should (get-buffer-window control))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
      ;; The frame as it was: the session alone, the report that opened for the
      ;; box closed with the Ediff, point on the next file.
      (should (equal layout (harness-ui-patch-review-test--layout)))
      (should-not (harness-ui-popout-buffer (list 'report id)))
      (should-not (harness-ui-patch-review--r-ediff review))
      (should (eq chat (window-buffer (selected-window))))
      (with-current-buffer chat
        (should (eql 1 (cdr (harness-ui-patch-review--at-point))))
        (should (eql (point) (window-point (selected-window)))))
      (should-not (harness-ui-patch-review--r-origin review)))))

;;;; The tree beside Ediff

(ert-deftest harness-ui-patch-review-shows-a-tree-beside-ediff ()
  "While Ediff compares a file the changes show in a tree on the left of the
frame: the file compared marked, the marks following, the threads below the
files in the same buffer.  RET on a file compares it in place of the one under
way, TAB folds a directory, t in Ediff shows or hides the tree, T goes to the
threads, and the tree goes when Ediff ends."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (layout (harness-ui-patch-review-test--layout))
           (harness-ui-patch-review-ediff-tree t)
           (harness-ui-patch-review-auto-approve nil))
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")
      (harness-ui-patch-review-ediff review 1)
      (let* ((control (harness-ui-patch-review-test--control review 1))
             (tree (harness-ui-patch-review--r-tree-buffer review))
             (window (get-buffer-window tree))
             (current (lambda (index)
                        (let ((pos (harness-ui-patch-review--row-start id index tree)))
                          (and pos (memq 'harness-ui-patch-review-current-face
                                         (ensure-list (get-text-property (1+ pos) 'face tree))))))))
        (should (window-live-p window))
        (should (eq 'left (window-parameter window 'window-side)))
        (should (window-parameter window 'no-delete-other-windows))
        (should (eq 'harness-ui-patch-review-tree-mode (buffer-local-value 'major-mode tree)))
        (harness-ui-patch-review-test--only-ediff-and-box review popout)
        ;; The files as a tree, the file compared marked, the threads under them.
        (let ((text (harness-ui-patch-review-test--text tree)))
          (should (string-prefix-p "Changes (6)" text))
          (should (string-match-p "^▶ +D  *b\\.el" text))
          (should (string-match-p "^  ▾ docs/ +\\+1 −0$" text))
          (should (string-match-p "^Threads  \\[open 1\\]" text))
          (should (string-match-p "^  ▾ a\\.el +1 thread$" text))
          (should (string-match-p "^    ┃      Why two\\?$" text)))
        (should (funcall current 1))
        (should-not (funcall current 0))
        ;; Its rows have the keys of the changes'.
        (with-current-buffer tree
          (goto-char (harness-ui-patch-review--row-start id 3 tree))
          (should (eq #'harness-ui-patch-review-ediff (key-binding (kbd "RET"))))
          (should (eq #'harness-ui-patch-review-ediff-quit (key-binding "q")))
          (should (eq #'harness-ui-patch-review-next-file (key-binding "n")))
          (should (eq review harness-ui-patch-review--review)))
        ;; RET on a file: it is compared in place of the one under way, the tree
        ;; marking it, the same windows.
        (with-current-buffer tree
          (goto-char (harness-ui-patch-review--row-start id 3 tree))
          (call-interactively (key-binding (kbd "RET"))))
        (setq control (harness-ui-patch-review-test--control review 3))
        (should (eq tree (harness-ui-patch-review--r-tree-buffer review)))
        (should (funcall current 3))
        (should-not (funcall current 1))
        (harness-ui-patch-review-test--only-ediff-and-box review popout)
        ;; The marks follow: the file left is seen.
        (should (string-match-p "^  ✓ D +b\\.el" (harness-ui-patch-review-test--text tree)))
        ;; TAB folds a directory in the tree, and in the report too.
        (with-current-buffer tree
          (goto-char (point-min))
          (re-search-forward "^  ▾ docs/")
          (beginning-of-line)
          (call-interactively (key-binding (kbd "TAB"))))
        (should (string-match-p "^  ▸ docs/" (harness-ui-patch-review-test--text tree)))
        (harness-ui-patch-review-test--wait-text popout "^  ▸ docs/")
        (with-current-buffer tree
          (goto-char (point-min))
          (re-search-forward "^  ▸ docs/")
          (beginning-of-line)
          (call-interactively (key-binding (kbd "TAB"))))
        ;; T, from the control panel: to the threads, in the tree.
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-toggle-ediff-tree (key-binding "t")))
          (call-interactively (key-binding "T")))
        (should (eq (get-buffer-window tree) (selected-window)))
        (with-current-buffer tree
          (should (string-prefix-p "Threads" (buffer-substring-no-properties (point) (point-max)))))
        (should-not (cl-some (lambda (buffer)
                               (eq 'change-review-threads-mode (buffer-local-value 'major-mode buffer)))
                             (buffer-list)))
        ;; t hides the tree and shows it again.
        (select-window (get-buffer-window control))
        (with-current-buffer control (call-interactively (key-binding "t")))
        (should-not harness-ui-patch-review-ediff-tree)
        (should-not (buffer-live-p tree))
        (should (= 4 (length (window-list nil 'nomini))))
        (with-current-buffer control (call-interactively (key-binding "t")))
        (should harness-ui-patch-review-ediff-tree)
        (setq tree (harness-ui-patch-review--r-tree-buffer review))
        (should (window-live-p (get-buffer-window tree)))
        (harness-ui-patch-review-test--only-ediff-and-box review popout)
        ;; q gives the frame back, the tree gone with it.
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))
        (should-not (buffer-live-p tree))
        (should-not (harness-ui-patch-review--r-tree-buffer review))
        (should (equal layout (harness-ui-patch-review-test--layout))))
      ;; Without the tree: Ediff and the box, as before.
      (let ((harness-ui-patch-review-ediff-tree nil))
        (harness-ui-patch-review-ediff review 1)
        (harness-ui-patch-review-test--control review 1)
        (should-not (harness-ui-patch-review--r-tree-buffer review))
        (should (= 4 (length (window-list nil 'nomini))))
        (with-current-buffer (harness-ui-patch-review-test--control review 1)
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-tree-beside-ediff-follows-the-threads ()
  "The tree beside Ediff draws again as the review changes: a comment made in
Ediff shows among its threads, and T goes to them in the tree, not in a view of
their own."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews)))
      (ignore popout)
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (tree (harness-ui-patch-review--r-tree-buffer review)))
        (should (string-match-p "^Threads  \\[open 0\\]" (harness-ui-patch-review-test--text tree)))
        (with-current-buffer control
          (harness-ui-patch-review-test--comment "Why two?"))
        (harness-ui-patch-review-test--wait-text tree "^    ┃      Why two\\?$")
        (should (string-match-p "^Threads  \\[open 1\\]" (harness-ui-patch-review-test--text tree)))
        (should (string-match-p "●1 ✎1" (harness-ui-patch-review-test--text tree)))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(defun harness-ui-patch-review-test--older-review (review)
  "Return a review as a version before slots were added made it.
A record with fewer slots than the struct has now, and one that no
definition of this layout made: the accessors read it wrong, or past its
end -- `args-out-of-range' -- as they did the one a reload left behind.
Its slots are those of REVIEW, as far as it goes."
  (apply #'record 'harness-ui-patch-review--review
         (cl-loop for i from 1 to 23 collect (aref review i))))

(defun harness-ui-patch-review-test--big-record ()
  "Return a record that holds a lot, as the review of a task does."
  (record 'harness-ui-patch-review-test--review
          (make-string 5000 ?x) (list :report (make-string 5000 ?y))))

(ert-deftest harness-ui-patch-review-drops-the-reviews-an-older-layout-made ()
  "A reload keeps the reviews, but a struct that gained a slot reads the instance
of its older definition wrong: one slot for another, or past its end.  A review
remembers the layout of its structs when it was made, and a load drops every
review made under another one -- one made by a version that did not remember
too, which is the first update to a version that does -- and keeps the others.
A stale review that gets in later is dropped when it is asked for."
  (let ((harness-ui-patch-review--reviews (make-hash-table :test 'equal))
        (harness-ui-patch-review--made-with (make-hash-table :test 'eq :weakness 'key))
        (harness-ui-patch-review--dropped nil)
        (change-review-ui-sets nil))
    (let* ((current (harness-ui-patch-review--review-for (list :id "t-1" :state "review")))
           ;; Made before slots were added: shorter than the struct is now.
           (shorter (harness-ui-patch-review-test--older-review current))
           ;; Made by a version that kept no layout: as long as now, unremembered.
           (unremembered (harness-ui-patch-review--review-create :id "t-3"))
           (set (harness-ui-patch-review--make-set :id "t-2")))
      (should-not (harness-ui-patch-review--stale-p current))
      (should (harness-ui-patch-review--stale-p shorter))
      (should (harness-ui-patch-review--stale-p unremembered))
      (should (harness-ui-patch-review--stale-p 'not-a-review))
      ;; The library's views of the old review's set stop pointing at it.
      (setf (harness-ui-patch-review--set-review set) shorter)
      (setq change-review-ui-sets (list set))
      (puthash "t-2" shorter harness-ui-patch-review--reviews)
      (puthash "t-3" unremembered harness-ui-patch-review--reviews)
      (should (equal '("t-2" "t-3") (sort (harness-ui-patch-review--drop-stale-reviews) #'string<)))
      (should (equal '("t-1") (hash-table-keys harness-ui-patch-review--reviews)))
      (should (eq current (gethash "t-1" harness-ui-patch-review--reviews)))
      (should (equal '("t-2" "t-3") (sort (copy-sequence harness-ui-patch-review--dropped) #'string<)))
      (should-not (harness-ui-patch-review--set-review set))
      ;; Nothing is left to drop, and what is kept stays.
      (should-not (harness-ui-patch-review--drop-stale-reviews))
      (should (eq current (harness-ui-patch-review--known "t-1")))
      ;; An Ediff that began before the update has the old review: the
      ;; commands of its control panel say so, and the current one works.
      (with-temp-buffer
        (setq-local harness-ui-patch-review--review shorter)
        (should (string-search "began before the harness was updated"
                               (cadr (should-error (harness-ui-patch-review--current)
                                                   :type 'user-error))))
        (setq-local harness-ui-patch-review--review current)
        (should (eq current (harness-ui-patch-review--current))))
      ;; One that gets in after the load is dropped as it is asked for, and
      ;; the review made again is a current one.
      (puthash "t-4" (harness-ui-patch-review-test--older-review current) harness-ui-patch-review--reviews)
      (should-not (harness-ui-patch-review--known "t-4"))
      (should-not (gethash "t-4" harness-ui-patch-review--reviews))
      (puthash "t-4" (harness-ui-patch-review-test--older-review current) harness-ui-patch-review--reviews)
      (let ((again (harness-ui-patch-review--review-for (list :id "t-4" :state "review"))))
        (should-not (harness-ui-patch-review--stale-p again))
        (should (eq again (gethash "t-4" harness-ui-patch-review--reviews))))
      ;; Under another layout of the structs -- the review's, or the library's
      ;; that it holds -- even a review as long as the struct is, is stale; a
      ;; snapshot of a review is made under the layout of its review.
      (let ((harness-ui-patch-review--layout (cdr harness-ui-patch-review--layout)))
        (should (harness-ui-patch-review--stale-p current)))
      (should-not (harness-ui-patch-review--stale-p current))
      (let ((snapshot (harness-ui-patch-review--make-snapshot current (list :tip "abc"))))
        (should-not (harness-ui-patch-review--stale-p snapshot))
        (should (harness-ui-patch-review--stale-p
                 (harness-ui-patch-review--make-snapshot unremembered (list :tip "abc"))))))))

(ert-deftest harness-ui-patch-review-layout-covers-what-the-set-holds ()
  "The layout a review remembers is that of every struct its set holds: a slot the
library's comment or thread gains makes the reviews of the older layout stale
as one of the review's own does."
  (dolist (struct '(harness-ui-patch-review--review harness-ui-patch-review--set
                    change-review-author change-review-location change-review-comment
                    change-review-thread change-review-file change-review-version
                    change-review-set))
    (should (assq struct harness-ui-patch-review--layout))
    (should (equal (mapcar #'car (cdr (cl-struct-slot-info struct)))
                   (cdr (assq struct harness-ui-patch-review--layout))))))

(ert-deftest harness-ui-patch-review-heals-the-report-and-the-banner-after-an-update ()
  "An update of the harness reloads it with the reviews it holds, and one an older
layout made is read wrong: the report that showed the changes failed with an
`args-out-of-range' that printed the whole review, the task's hand-in with it,
and the review banner with [Verify] and [Send back] went with it.  The new
definitions drop the review, and the report and the banner, drawn again, make a
new one: the changes, the threads and the buttons are there."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (chat (harness-ui-patch-review-test--banner board id sid))
           (review (gethash id harness-ui-patch-review--reviews))
           (older (harness-ui-patch-review-test--older-review review)))
      (ignore popout)
      (should (memq chat (harness-ui-patch-review--r-banners review)))
      ;; The update: what the table holds is an older version's review.
      (puthash id older harness-ui-patch-review--reviews)
      (should (equal (list id) (harness-ui-patch-review--drop-stale-reviews)))
      (should-not (gethash id harness-ui-patch-review--reviews))
      ;; The module starts, and draws what showed the review again.
      (harness-ui-patch-review--redraw-dropped)
      (should-not harness-ui-patch-review--dropped)
      (let ((popout (harness-ui-popout-buffer (list 'report id))))
        (harness-ui-patch-review-test--wait-text popout "^Changes (6)")
        (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
        (let ((text (harness-ui-patch-review-test--text popout)))
          (should-not (string-search "Could not draw" text))
          (should-not (string-search "could not be drawn" text))
          (should (string-search "[Verify]" text))
          (should (string-search "[Send back]" text))))
      (harness-ui-patch-review-test--wait-text chat "^Changes (6)")
      (let ((tail (harness-ui-patch-review-test--text chat)))
        (should-not (string-search "could not be drawn" tail))
        (should (string-search "[Verify]  C-c C-v" tail))
        (should (string-search "[Review Changes]" tail)))
      ;; A new review, of this layout, that the surfaces show.
      (let ((new (gethash id harness-ui-patch-review--reviews)))
        (should new)
        (should-not (eq new older))
        (should-not (harness-ui-patch-review--stale-p new))
        (should (memq chat (harness-ui-patch-review--r-banners new)))))))

(ert-deftest harness-ui-patch-review-draws-over-a-stale-review-that-got-in ()
  "A review of an older layout that is in the table when the report draws -- the
load that should have dropped it did not run, or ran too early -- does not fail
the report: it is dropped as the report asks for it, and the changes are made
anew.  The banner of the session and an event about the task too: a listener
that signalled on it would keep the others from hearing the task's events."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (chat (harness-ui-patch-review-test--banner board id sid))
           (review (gethash id harness-ui-patch-review--reviews))
           (task (with-current-buffer board (harness-ui-tasks--find id))))
      ;; An event about the task finds the review stale and drops it, rather
      ;; than read it wrong.
      (puthash id (harness-ui-patch-review-test--older-review review) harness-ui-patch-review--reviews)
      (harness-ui-patch-review--on-event "task/changed" (list task))
      (should-not (gethash id harness-ui-patch-review--reviews))
      ;; The report draws over a stale one.
      (puthash id (harness-ui-patch-review-test--older-review review) harness-ui-patch-review--reviews)
      (harness-ui-popout-refresh (list 'report id))
      (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
      (let ((text (harness-ui-patch-review-test--text popout)))
        (should-not (string-search "Could not draw" text))
        (should (string-search "[Verify]" text)))
      (should-not (harness-ui-patch-review--stale-p (gethash id harness-ui-patch-review--reviews)))
      ;; And the banner.
      (puthash id (harness-ui-patch-review-test--older-review
                   (gethash id harness-ui-patch-review--reviews))
               harness-ui-patch-review--reviews)
      (with-current-buffer chat (funcall harness-compose-redraw-function))
      (harness-ui-patch-review-test--wait-text chat "^Changes (6)")
      (should-not (string-search "could not be drawn" (harness-ui-patch-review-test--text chat)))
      (should-not (harness-ui-patch-review--stale-p (gethash id harness-ui-patch-review--reviews))))))

(ert-deftest harness-ui-patch-review-says-short-when-the-changes-fail-and-tries-again ()
  "Changes that cannot be drawn say so in one short line with a [Try again] -- the
error may carry the review, the task's whole hand-in with it -- and the report
goes on, [Verify] and [Send back] with it.  [Try again] makes the review again."
  (harness-ui-patch-review-test-with-task
    (harness-ui-patch-review-test--give-branch board id)
    (let ((fail t))
      (cl-letf* ((section (symbol-function 'harness-ui-patch-review--section))
                 ((symbol-function 'harness-ui-patch-review--section)
                  (lambda (&rest args)
                    (if fail
                        (signal 'args-out-of-range (list (harness-ui-patch-review-test--big-record) 33))
                      (apply section args)))))
        (let* ((popout (harness-ui-patch-review-test--report board id))
               (text (harness-ui-patch-review-test--text popout)))
          (should (string-match-p "^Changes   could not be drawn: Args out of range: \"#<harness-ui-patch-review-test--review>\", 33  \\[Try again\\]$"
                                  text))
          (should-not (string-search "xxxxxxxxxx" text))
          (should (string-search "[Verify]" text))
          (should (string-search "[Send back]" text))
          ;; Try again, with what failed fixed: the review is made anew.
          (setq fail nil)
          (let ((before (gethash id harness-ui-patch-review--reviews)))
            (should before)
            (harness-ui-patch-review-test--push popout "[Try again]")
            (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
            (should-not (eq before (gethash id harness-ui-patch-review--reviews)))
            (should-not (string-search "could not be drawn"
                                       (harness-ui-patch-review-test--text popout)))))))))

(ert-deftest harness-ui-patch-review-wraps-thread-headers-under-their-bar ()
  "The header of a thread and of each comment is a long line with buttons, which
wraps in a narrow window: a thread's continues under its mark, a comment's under
its bar, so the tree beside Ediff reads in order."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (comment (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (text (with-temp-buffer (harness-ui-patch-review--threads-section review t)))
           (thread-start (text-property-any 0 (length text) 'change-review-thread-start t text))
           (comment-start (text-property-any 0 (length text) 'change-review-comment-start t text)))
      (ignore comment)
      (should thread-start)
      (should comment-start)
      ;; The thread's header: its line is indented, and so is the rest of it.
      (should (string-match-p "\\` +\\'" (get-text-property thread-start 'wrap-prefix text)))
      (should (> (length (get-text-property thread-start 'wrap-prefix text))
                 (- (string-match "●" text thread-start) thread-start)))
      ;; The comment's: under its bar, which goes on.
      (let ((prefix (get-text-property comment-start 'wrap-prefix text)))
        (should (string-match-p "\\` +┃ +\\'" prefix))
        (should (eq (get-text-property (string-match "┃" prefix) 'face prefix)
                    (get-text-property (string-match "┃" text comment-start) 'face text))))
      ;; A line of the body wraps as the library's own drawing wraps it.
      (should-not (get-text-property (string-match "Why two" text) 'wrap-prefix text)))))
;;;; Where a comment was made

(defun harness-ui-patch-review-test--advance-again (repo)
  "Commit a third change on task/fix of REPO, after `--advance': four lines
at the top of a.el, and the second line edited once more."
  (harness-ui-patch-review-test--git repo "checkout" "-q" "task/fix")
  (harness-ui-patch-review-test--write
   repo "a.el" (concat "(setq top0 0)\n(setq top1 1)\n(setq top2 2)\n(setq top3 3)\n"
                       (harness-ui-patch-review-test--numbered
                        "a" 20 '((2 . "(setq a2 'four)") (18 . "(setq a18 'eighteen)")))))
  (harness-ui-patch-review-test--git repo "commit" "-q" "-am" "Once more"))

(defun harness-ui-patch-review-test--snapshot (review revision)
  "Wait for the snapshot of REVIEW at REVISION to be read; return it."
  (harness-test-wait (lambda ()
                       (let ((promise (gethash revision (harness-ui-patch-review--r-snapshots review))))
                         (and promise (eq 'resolved (harness-promise-state promise)))))
                     10 "the snapshot to be read")
  (harness-promise-value (gethash revision (harness-ui-patch-review--r-snapshots review))))

(defun harness-ui-patch-review-test--where-lines (set thread)
  "Return the lines of THREAD of SET drawn with the details of every comment."
  (split-string (substring-no-properties (change-review-ui-thread-string set thread :width 100 :details t))
                "\n" t))

(ert-deftest harness-ui-patch-review-where-is-the-diff-of-the-commit-a-comment-was-written-on ()
  "The details of a comment show the diff of the commit it was written against,
not the newest: the answer to a comment changes the code it is about, and the
newest diff would make the comment ask for what is there already.  A reply
shows the lines of its own commit, found in git once, whatever commit that is."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (v1 (harness-ui-patch-review--r-tip review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (thread (harness-ui-patch-review-test--thread-of review two))
           (bot (change-review-agent "Claude" :session "sess-1" :tool-call "toolu_1")))
      ;; The commit it was written against is kept with it.
      (should (equal v1 (change-review-comment-revision two)))
      ;; The branch moves on: lines at the top, and a2 edited.
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (let* ((v2 (harness-ui-patch-review--r-tip review))
             (reply (change-review-reply set two "It is 'three now." :author bot)))
        (should-not (equal v1 v2))
        (should (equal v2 (change-review-comment-revision reply)))
        ;; The comment: the diff it was made on, the line it was made on.
        (let ((location (plist-get (change-review-origin set thread two) :location)))
          (should (eql 2 (change-review-location-line location)))
          (should (string-suffix-p "+(setq a2 'two)" (change-review-location-excerpt location))))
        ;; The reply, written against the branch as it is: that diff, the line the thread is on there.
        (let* ((origin (change-review-origin set thread reply))
               (location (plist-get origin :location)))
          (should-not (plist-get origin :note))
          (should (eql 5 (change-review-location-line location)))
          (should (string-suffix-p "+(setq a2 'three)" (change-review-location-excerpt location)))
          (should-not (string-search "'two" (change-review-location-excerpt location))))
        (let ((lines (harness-ui-patch-review-test--where-lines set thread)))
          (should (cl-some (lambda (line) (string-match-p "made at a\\.el:2 · revision v1 ([0-9a-f]\\{7\\})  \\[Source @ v1\\] \\[Source @ v2\\]" line))
                           lines))
          (should (cl-some (lambda (line) (string-match-p "made at a\\.el:5 · revision v2 ([0-9a-f]\\{7\\})  \\[Source\\]" line))
                           lines))
          (should (cl-some (lambda (line) (string-search "│ +(setq a2 'three)" line)) lines))
          (should (cl-some (lambda (line) (string-search "│ +(setq a2 'two)" line)) lines)))
        ;; The branch moves on once more: the reply is about a commit that is not the branch's end.
        (harness-ui-patch-review-test--advance-again repo)
        (harness-test-await (harness-ui-patch-review--load review))
        (should-not (equal v2 (harness-ui-patch-review--r-tip review)))
        ;; Reading the commit takes a moment, and says so rather than show other lines.
        (let ((origin (change-review-origin set thread reply)))
          (should (string-match-p "\\`reading the diff at [0-9a-f]\\{7\\}…\\'" (plist-get origin :note)))
          (should-not (change-review-location-excerpt (plist-get origin :location))))
        (harness-ui-patch-review-test--snapshot review v2)
        (let* ((origin (change-review-origin set thread reply))
               (location (plist-get origin :location)))
          (should-not (plist-get origin :note))
          (should (eql 5 (change-review-location-line location)))
          (should (string-suffix-p "+(setq a2 'three)" (change-review-location-excerpt location)))
          (should-not (string-search "'four" (change-review-location-excerpt location))))
        ;; The comment of the first commit is where it was; the thread has moved since.
        (let ((lines (harness-ui-patch-review-test--where-lines set thread)))
          (should (cl-some (lambda (line) (string-search "now: line 6" line)) lines)))))))

(ert-deftest harness-ui-patch-review-lists-a-files-threads-without-reordering-the-set ()
  "The threads of a file are listed by line; the set keeps them in the order they were started."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (file (harness-ui-patch-review-test--file review "a.el")))
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?")
      (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")
      (should (equal '(2 18) (mapcar #'change-review-thread-line
                                     (harness-ui-patch-review--file-threads review file))))
      (should (equal '(18 2) (mapcar #'change-review-thread-line (change-review-set-threads set)))))))

(ert-deftest harness-ui-patch-review-where-has-the-diff-of-an-agents-thread ()
  "A thread the agent started on a line has no excerpt of its own, only the
commit it was at: the diff of that commit gives the lines."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (tip (harness-ui-patch-review--r-tip review))
           (comment (change-review-comment
                     set "This one is odd." :author (change-review-agent "Claude" :session "sess-1")
                     :revision tip
                     :location (change-review-make-location :file "a.el" :line 18 :side 'new)))
           (thread (harness-ui-patch-review-test--thread-of review comment))
           (location (plist-get (change-review-origin set thread comment) :location)))
      (should (eql 18 (change-review-location-line location)))
      (should (string-suffix-p "+(setq a18 'eighteen)" (change-review-location-excerpt location)))
      (should (cl-some (lambda (line) (string-search "│ -(setq a18 18)" line))
                       (harness-ui-patch-review-test--where-lines set thread))))))

(ert-deftest harness-ui-patch-review-where-says-when-the-commit-is-gone ()
  "A comment written against a commit the repository does not have shows what the
thread kept, and says whose lines they are and why."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (thread (harness-ui-patch-review-test--thread-of review two))
           (gone "0123456789abcdef0123456789abcdef01234567")
           (reply (change-review-reply set two "Long ago." :revision gone
                                       :author (change-review-agent "Claude"))))
      (should (string-match-p "reading the diff at 0123456…"
                              (plist-get (change-review-origin set thread reply) :note)))
      (should-error (harness-test-await (harness-ui-patch-review--snapshot review gone)))
      (let* ((origin (change-review-origin set thread reply))
             (location (plist-get origin :location)))
        (should (equal "The commit 0123456 is not in the repository: showing the lines the thread started on"
                       (plist-get origin :note)))
        (should (string-suffix-p "+(setq a2 'two)" (change-review-location-excerpt location)))))))

(ert-deftest harness-ui-patch-review-comments-are-written-against-the-commit-their-diff-was-read-at ()
  "A comment made in Ediff keeps the commit the branch was read at -- the one
its excerpt is from -- not whichever version the review knows last."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (tip (harness-ui-patch-review--r-tip review)))
      ;; A hand-in the UI has not read yet is the newest version of the set.
      (change-review-add-version
       set (change-review-make-version :id "ffffffffffffffffffffffffffffffffffffffff" :base "abc"))
      (harness-ui-patch-review--comment-added
       review (harness-ui-patch-review-test--file review "a.el") '(:new . 18) "Why eighteen?")
      (let ((root (change-review-thread-root (car (last (change-review-set-threads set))))))
        (should (equal tip (change-review-comment-revision root)))
        (should (string-suffix-p "+(setq a18 'eighteen)"
                                 (change-review-location-excerpt (change-review-comment-location root))))))))

(ert-deftest harness-ui-patch-review-shows-the-source-as-the-comment-was-written-on-it ()
  "The code a comment was written against, in Ediff, at the commit it was
written on and with its line in sight, while the branch has gone on: the
merge base against the file of that commit.  It is looked at, not reviewed: no
mark of the file, no approval; a comment made there is written against that
commit.  From the details of the comment, D, and a line of its diff."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (v1 (harness-ui-patch-review--r-tip review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (thread (harness-ui-patch-review-test--thread-of review two)))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (should-not (equal v1 (harness-ui-patch-review--r-tip review)))
      (harness-test-await (change-review-visit set two v1))
      (let* ((snapshot (harness-ui-patch-review-test--snapshot review v1))
             (control (harness-ui-patch-review-test--control snapshot 0))
             (old (plist-get (harness-ui-patch-review--r-ediff snapshot) :a))
             (new (plist-get (harness-ui-patch-review--r-ediff snapshot) :b)))
        ;; The review itself has no Ediff: this is the code as it was.
        (should-not (harness-ui-patch-review--r-ediff review))
        (should (equal v1 (harness-ui-patch-review--r-tip snapshot)))
        (should (string-search (harness-ui-patch-review--short v1) (buffer-name new)))
        (with-current-buffer new
          (goto-char (point-min))
          (should (equal "(setq a1 1)" (buffer-substring (line-beginning-position) (line-end-position))))
          (should (search-forward "(setq a2 'two)")))
        (should (= 2 (with-current-buffer new
                       (save-excursion (goto-char (window-point (get-buffer-window new)))
                                       (line-number-at-pos)))))
        ;; The thread is under its line there, as it was.
        (with-current-buffer new
          (should (cl-some (lambda (ov) (string-search "Why two?" (or (overlay-get ov 'after-string) "")))
                           (overlays-in (point-min) (point-max)))))
        (with-current-buffer control
          (should (string-search (format "as it was at %s" (harness-ui-patch-review--short v1))
                                 (harness-ui-patch-review-test--text control)))
          ;; Looked at, not reviewed.
          (should-error (harness-ui-patch-review-approve-ediff) :type 'user-error)
          ;; A reply here, to the thread at the first difference, is written against this commit.
          (cl-letf (((symbol-function 'string-edit)
                     (lambda (_prompt _initial callback &rest _) (funcall callback "Still odd."))))
            (call-interactively #'harness-ui-patch-review-reply))
          (should (equal v1 (change-review-comment-revision (change-review-thread-last-comment thread))))
          (call-interactively #'harness-ui-patch-review-toggle-thread)
          (should (equal v1 (plist-get (car (last (change-review-thread-history thread))) :revision)))
          ;; A comment made here is written against this commit, on its lines.
          (with-current-buffer new
            (goto-char (point-min))
            (forward-line 17)
            (harness-ui-patch-review-comment-line "Why eighteen?"))
          (let ((root (change-review-thread-root (car (last (change-review-set-threads set))))))
            (should (equal v1 (change-review-comment-revision root)))
            (should (string-suffix-p "+(setq a18 'eighteen)"
                                     (change-review-location-excerpt (change-review-comment-location root)))))
          (call-interactively #'harness-ui-patch-review-ediff-quit))
        (should-not (buffer-live-p new))
        (should-not (buffer-live-p old))
        (should (zerop (hash-table-count (harness-ui-patch-review--r-seen review)))))
      ;; From the threads view: D shows it, and so does RET on a line of its diff.
      (let ((view (save-window-excursion (change-review-open-threads set 'all))))
        (unwind-protect
            (with-current-buffer view
              (goto-char (point-min))
              (search-forward "Why two?")
              (change-review-ui-show-origin)
              (re-search-forward "│ \\+(setq a2 'two)")
              (should (eq #'change-review-ui-follow-source (key-binding (kbd "RET"))))
              (call-interactively #'change-review-ui-follow-source)
              (let* ((snapshot (harness-ui-patch-review-test--snapshot review v1))
                     (control (harness-ui-patch-review-test--control snapshot 0))
                     (new (plist-get (harness-ui-patch-review--r-ediff snapshot) :b)))
                (should (= 2 (with-current-buffer new
                               (save-excursion (goto-char (window-point (get-buffer-window new)))
                                               (line-number-at-pos)))))
                (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
              (goto-char (point-min))
              (search-forward "Why two?")
              (call-interactively #'change-review-ui-show-source)
              (let ((snapshot (harness-ui-patch-review-test--snapshot review v1)))
                (with-current-buffer (harness-ui-patch-review-test--control snapshot 0)
                  (call-interactively #'harness-ui-patch-review-ediff-quit))))
          (kill-buffer view)))
      ;; A review that goes takes the Ediffs of earlier commits with it.
      (harness-test-await (change-review-visit set two v1))
      (let* ((snapshot (harness-ui-patch-review-test--snapshot review v1))
             (control (harness-ui-patch-review-test--control snapshot 0)))
        (should (buffer-live-p control))
        (harness-ui-patch-review--forget review)
        (should-not (buffer-live-p control))
        (should (zerop (hash-table-count (harness-ui-patch-review--r-snapshots review)))))
      (ignore thread))))

(ert-deftest harness-ui-patch-review-the-source-of-an-earlier-commit-has-the-reports-box ()
  "The code of an earlier commit in Ediff has the report's box under it, as any
Ediff of the review does, and the way to it; q gives the frame back and the
report stays as it was, no file of it marked."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (v1 (harness-ui-patch-review--r-tip review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-test-await (change-review-visit set two v1))
      (let* ((snapshot (harness-ui-patch-review-test--snapshot review v1))
             (control (harness-ui-patch-review-test--control snapshot 0))
             (box (get-buffer-window popout t)))
        (should-not (harness-ui-patch-review--r-ediff review))
        (should (window-live-p box))
        (should (eq popout (window-buffer box)))
        ;; The box of the report: where the feedback is written.
        (with-current-buffer control
          (call-interactively #'harness-ui-patch-review-edit-feedback))
        (should (eq box (selected-window)))
        (should (eq popout (window-buffer box)))
        (should (= (buffer-local-value 'harness-compose-end popout)
                   (with-current-buffer popout (point))))
        ;; C-c C-d in the report goes back to that Ediff.
        (harness-ui-patch-review-test--press #'harness-ui-patch-review-open)
        (should (eq control (window-buffer (selected-window))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))
        (should-not (buffer-live-p control))
        (should (window-live-p (get-buffer-window popout t)))
        (should (zerop (hash-table-count (harness-ui-patch-review--r-seen review))))
        ;; Still the report's own review: not in Ediff, and its files not marked.
        (should-not (harness-ui-patch-review--r-ediff review))
        (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")))))

(ert-deftest harness-ui-patch-review-shows-the-source-of-the-newest-commit-in-the-review ()
  "The newest commit is the review's own Ediff, not a snapshot: a comment
written against it, or a location of it, is shown there."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (tip (harness-ui-patch-review--r-tip review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?")))
      (change-review-visit set two tip)
      (let ((control (harness-ui-patch-review-test--control review 0)))
        (should-not (harness-ui-patch-review--r-snapshot review))
        (should (zerop (hash-table-count (harness-ui-patch-review--r-snapshots review))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit)))
      ;; A location: a line of a file of the diff.
      (change-review-visit set (change-review-make-location :file "a.el" :side 'new :line 18))
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (plist-get (harness-ui-patch-review--r-ediff review) :b)))
        (should (= 18 (with-current-buffer new
                        (save-excursion (goto-char (window-point (get-buffer-window new)))
                                        (line-number-at-pos)))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

;;;; Choosing the diff

(ert-deftest harness-ui-patch-review-parses-the-diffs-typed ()
  "A diff is typed as `git diff' takes it: A..B, A...B, A B or A.  What is
left out is the branch's tip, or the branch it was made from."
  (let ((parse #'harness-ui-patch-review--parse-spec))
    (should (equal '("main" "task/fix" nil) (funcall parse "main..task/fix")))
    (should (equal '("main" "task/fix" t) (funcall parse "main...task/fix")))
    (should (equal '("HEAD~2" "HEAD" nil) (funcall parse "HEAD~2..HEAD")))
    (should (equal '("a" "b" nil) (funcall parse "a b")))
    (should (equal '("a" "b" nil) (funcall parse "  a    b  ")))
    (should (equal '("1c9e4a0" nil nil) (funcall parse "1c9e4a0")))
    (should (equal '("1c9e4a0" nil nil) (funcall parse "1c9e4a0..")))
    (should (equal '("1c9e4a0" nil t) (funcall parse "1c9e4a0...")))
    (should (equal '(nil "1c9e4a0" nil) (funcall parse "..1c9e4a0")))
    (should (equal '("a" "b" t) (funcall parse " a ... b ")))
    ;; Nothing to compare, too many revisions, an option for a revision.
    (dolist (bad '("" "   " ".." "..." "a b c" "-p" "--stat" "a..-b" "-x..b"))
      (ert-info ((format "%S" bad))
        (should-error (funcall parse bad) :type 'user-error)))
    (should (string-match-p "names 3" (cadr (should-error (funcall parse "a b c") :type 'user-error))))
    (should (string-match-p "dash" (cadr (should-error (funcall parse "a..-b") :type 'user-error))))))

(defun harness-ui-patch-review-test--read (repo selector &optional last-review)
  "Read task/fix of REPO for SELECTOR, with LAST-REVIEW to say its last review."
  (harness-test-await (harness-ui-patch-review--read-branch repo "task/fix" "main" repo selector last-review)))

(defun harness-ui-patch-review-test--paths (result)
  "Return the paths of the files RESULT, what a reading gives, holds."
  (mapcar #'change-review-file-path (plist-get result :files)))

(ert-deftest harness-ui-patch-review-reads-the-diff-since-the-last-review ()
  "Since the last review the branch is read against the commit the last
review was at: only what the work added since.  The whole change is read
all the same, for the version."
  (harness-ui-patch-review-test-with-repo
    (let ((first (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
          (start (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix"))
          asked)
      (harness-ui-patch-review-test--advance repo)
      (let* ((tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
             (result (harness-ui-patch-review-test--read
                      repo 'since-review (lambda (given) (setq asked given) (cons first "v1")))))
        ;; The function is asked where the branch is now.
        (should (equal tip asked))
        (should (eq 'since-review (plist-get result :kind)))
        (should (equal first (plist-get result :merge-base)))
        (should (equal tip (plist-get result :tip)))
        (should (equal "v1" (plist-get result :old-name)))
        (should (equal "task/fix" (plist-get result :new-name)))
        (should (equal "main" (plist-get result :base)))
        (should (equal '("a.el") (harness-ui-patch-review-test--paths result)))
        ;; Only what the newest commit changed: three lines in, one edited.
        (let ((file (car (plist-get result :files))))
          (should (equal '(4 1) (list (change-review-file-added file) (change-review-file-deleted file)))))
        ;; The branch's whole change is the version's.
        (should (equal start (plist-get result :branch-base)))
        (should (equal tip (plist-get result :branch-tip)))
        (should (equal '("a.el" "b.el" "d.el" "docs/é.txt" "img.bin" "new.el")
                       (mapcar #'change-review-file-path (plist-get result :branch-files)))))
      ;; The default diff is its own whole change.
      (let ((result (harness-ui-patch-review-test--read repo nil)))
        (should (eq 'base (plist-get result :kind)))
        (should (equal "main" (plist-get result :old-name)))
        (should (equal "task/fix" (plist-get result :new-name)))
        (should (eq (plist-get result :files) (plist-get result :branch-files)))
        (should (equal start (plist-get result :branch-base)))
        (should (equal start (plist-get result :merge-base))))
      ;; Nothing is known of a review before: it says so.
      (let ((err (should-error (harness-ui-patch-review-test--read
                                repo 'since-review (lambda (_) nil)))))
        (should (string-match-p "No earlier review of this task is known" (error-message-string err))))
      (let ((err (should-error (harness-ui-patch-review-test--read repo 'since-review))))
        (should (string-match-p "No earlier review of this task is known" (error-message-string err))))
      ;; A review at a commit the repository lost.
      (let ((err (should-error (harness-ui-patch-review-test--read
                                repo 'since-review
                                (lambda (_) (cons "0123456789abcdef0123456789abcdef01234567" "v1"))))))
        (should (string-match-p "The commit of the last review, 0123456, is no longer in the repository"
                                (error-message-string err)))))))

(ert-deftest harness-ui-patch-review-reads-the-revisions-typed ()
  "Revisions typed are compared as `git diff' compares them: A..B directly,
A...B from the merge base; a revision left out is the branch's tip."
  (harness-ui-patch-review-test-with-repo
    (let ((first (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
          (main (harness-ui-patch-review-test--git repo "rev-parse" "main"))
          (start (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix")))
      (harness-ui-patch-review-test--advance repo)
      (let ((tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
            (read (lambda (spec) (harness-ui-patch-review-test--read repo spec))))
        ;; Main went on: against its tip, what main changed shows as well.
        (let ((result (funcall read "main..task/fix")))
          (should (eq 'custom (plist-get result :kind)))
          (should (equal main (plist-get result :merge-base)))
          (should (equal tip (plist-get result :tip)))
          (should (equal "main" (plist-get result :old-name)))
          (should (equal "task/fix" (plist-get result :new-name)))
          (should (member "keep.el" (harness-ui-patch-review-test--paths result)))
          (should (= 7 (length (plist-get result :files))))
          ;; The branch's own change is read all the same.
          (should (= 6 (length (plist-get result :branch-files)))))
        ;; Two revisions, and a branch alone, are as `git diff' takes them.
        (should (equal (harness-ui-patch-review-test--paths (funcall read "main..task/fix"))
                       (harness-ui-patch-review-test--paths (funcall read "main task/fix"))))
        (should (equal (harness-ui-patch-review-test--paths (funcall read "main..task/fix"))
                       (harness-ui-patch-review-test--paths (funcall read "main"))))
        ;; From the merge base: what merging brings in.
        (let ((result (funcall read "main...task/fix")))
          (should (equal start (plist-get result :merge-base)))
          (should-not (member "keep.el" (harness-ui-patch-review-test--paths result)))
          (should (equal '("a.el" "b.el" "d.el" "docs/é.txt" "img.bin" "new.el")
                         (harness-ui-patch-review-test--paths result))))
        ;; A commit alone is compared with the tip, the end left out too.
        (dolist (spec (list "task/fix~1" "task/fix~1.." "task/fix~1 task/fix" "task/fix~1..task/fix"
                            "HEAD~1" first))
          (let ((result (funcall read spec)))
            (ert-info ((format "%s" spec))
              (should (equal first (plist-get result :merge-base)))
              (should (equal tip (plist-get result :tip)))
              (should (equal '("a.el") (harness-ui-patch-review-test--paths result))))))
        ;; An empty start is the branch it was made from.
        (let ((result (funcall read "...task/fix")))
          (should (equal start (plist-get result :merge-base)))
          (should (equal "main" (plist-get result :old-name))))
        ;; Not a diff at all: what git says, in words.
        (let ((err (should-error (funcall read "nope"))))
          (should (string-match-p "There is no commit .nope. in" (error-message-string err))))
        (let ((err (should-error (funcall read "main..task/nope"))))
          (should (string-match-p "There is no commit .task/nope. in" (error-message-string err))))
        (let ((err (should-error (funcall read "-p"))))
          (should (string-match-p "starts with a dash" (error-message-string err))))
        (let ((err (should-error (funcall read ""))))
          (should (string-match-p "Name the revisions" (error-message-string err))))))))

(ert-deftest harness-ui-patch-review-says-when-revisions-share-no-commit ()
  "A... B with nothing in common has no merge base: said, not an empty diff."
  (harness-ui-patch-review-test-with-repo
    (harness-ui-patch-review-test--git repo "checkout" "-q" "--orphan" "lone")
    (harness-ui-patch-review-test--git repo "rm" "-rfq" ".")
    (harness-ui-patch-review-test--write repo "lone.txt" "alone\n")
    (harness-ui-patch-review-test--git repo "add" "-A")
    (harness-ui-patch-review-test--git repo "commit" "-q" "-m" "Alone")
    (let ((err (should-error (harness-ui-patch-review-test--read repo "lone...task/fix"))))
      (should (string-match-p "lone and task/fix have no commit in common" (error-message-string err))))
    ;; Compared directly they differ all the same.
    (should (harness-ui-patch-review-test--paths (harness-ui-patch-review-test--read repo "lone..task/fix")))))

(ert-deftest harness-ui-patch-review-finds-the-last-review-in-the-versions ()
  "The last review is the newest version that is not the branch's own: the
commit the work was handed in at before.  None before the first one."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (first (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
      ;; One version, the branch at it: no earlier review.
      (should-not (harness-ui-patch-review--last-review review first))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (let ((second (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
        (should (equal (cons first "v1") (harness-ui-patch-review--last-review review second)))
        ;; At the first version there was none before it.
        (should-not (harness-ui-patch-review--last-review review first))
        ;; A branch not at a version: the newest one is the last review.
        (should (equal (cons second "v2")
                       (harness-ui-patch-review--last-review
                        review "0123456789abcdef0123456789abcdef01234567")))
        ;; No versions, no last review.
        (should-not (harness-ui-patch-review--last-review
                     (harness-ui-patch-review--review-create :id "none") second))))))

(ert-deftest harness-ui-patch-review-finds-the-last-review-of-work-handed-in-again ()
  "A task sent back whose branch did not move was handed in again at the
same commit: that is its last review, and nothing changed since.  The
harness records the round each version was handed in at, which says so; a
version this Emacs made, with no round, says nothing."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
           (version (change-review-find-version set tip))
           (sent-back (lambda (rounds)
                        (setf (harness-ui-patch-review--r-task review)
                              (plist-put (copy-sequence (harness-ui-patch-review--r-task review))
                                         :feedback (make-list rounds (list :text "back")))))))
      (should (= 1 (length (change-review-set-versions set))))
      (should-not (harness-ui-patch-review--last-review review tip))
      ;; Recorded at round 0, the task never sent back: the first hand-in.
      (setf (change-review-version-meta version) (list :round 0))
      (funcall sent-back 0)
      (should-not (harness-ui-patch-review--handed-in-again-p review version))
      (should-not (harness-ui-patch-review--last-review review tip))
      ;; Sent back once since: handed in again, at the commit it is at.
      (funcall sent-back 1)
      (should (harness-ui-patch-review--handed-in-again-p review version))
      (should (equal (cons tip "v1") (harness-ui-patch-review--last-review review tip)))
      ;; Recorded at round 1, the round it is at: that is this hand-in.
      (setf (change-review-version-meta version) (list :round 1))
      (should-not (harness-ui-patch-review--last-review review tip))
      ;; A version this Emacs made has no round to go by.
      (setf (change-review-version-meta version) nil)
      (should-not (harness-ui-patch-review--last-review review tip)))))

(defun harness-ui-patch-review-test--section (review)
  "Return the changes of REVIEW as its report draws them, without properties."
  (substring-no-properties
   (harness-ui-patch-review--section review (harness-ui-patch-review--counts review))))

(defun harness-ui-patch-review-test--choose (review selector)
  "Choose the diff SELECTOR for REVIEW and wait for it to be read."
  (harness-test-await (harness-ui-patch-review-select-diff selector review)))

(ert-deftest harness-ui-patch-review-says-which-diff-it-shows ()
  "The heading says what is compared and a line under it offers the three
diffs, the chosen one marked: the branch against its base, since the last
review, and any revisions typed."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (first (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
           (main (harness-ui-patch-review-test--git repo "rev-parse" "main"))
           (start (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix"))
           (short (lambda (sha) (substring sha 0 7))))
      ;; At first: the branch against main, no earlier review to offer.
      (let ((text (harness-ui-patch-review-test--section review)))
        (should (string-match-p (format "^Changes (6)   0 of 6 files viewed, 6 left   task/fix against main @ %s   \\+7 −8$"
                                        (funcall short start))
                                text))
        (should (string-match-p "^  Diff   \\[● Task branch against main\\]  \\[Since last review\\]  \\[Other…\\]$" text)))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      ;; The versions are known now: the last review is named.
      (should (string-match-p "^  Diff   \\[● Task branch against main\\]  \\[Since last review (v1)\\]  \\[Other…\\]$"
                              (harness-ui-patch-review-test--section review)))
      ;; Since the last review: the files the work changed since.
      (harness-ui-patch-review-test--choose review 'since-review)
      (should (eq 'since-review (harness-ui-patch-review--kind review)))
      (let ((text (harness-ui-patch-review-test--section review)))
        (should (string-match-p (format "^Changes (1)   0 of 1 file viewed, 1 left   task/fix since v1 @ %s   \\+4 −1$"
                                        (funcall short first))
                                text))
        (should (string-match-p "^  Diff   \\[Task branch against main\\]  \\[● Since last review (v1)\\]  \\[Other…\\]$" text))
        (should (string-match-p "^    M  a\\.el +\\+4 −1$" text))
        (should-not (string-search "b.el" text)))
      ;; Revisions typed: the diff as git has it, main's own change too.
      (harness-ui-patch-review-test--choose review "main..task/fix")
      (should (eq 'custom (harness-ui-patch-review--kind review)))
      (let ((text (harness-ui-patch-review-test--section review)))
        (should (string-match-p (format "^Changes (7) .*   task/fix against main @ %s   " (funcall short main)) text))
        (should (string-match-p "^  Diff   \\[Task branch against main\\]  \\[Since last review (v1)\\]  \\[● Other: main\\.\\.task/fix\\]$" text))
        (should (string-match-p "^    M  keep\\.el " text)))
      ;; A diff whose ends are commits: the ends are told as typed, not repeated.
      (harness-ui-patch-review-test--choose review (format "%s..HEAD" (funcall short first)))
      (let ((text (harness-ui-patch-review-test--section review)))
        (should (string-match-p (format "^Changes (1) .*   HEAD against %s   " (funcall short first)) text)))
      ;; And back to the branch against its base.
      (harness-ui-patch-review-test--choose review 'base)
      (should (eq 'base (harness-ui-patch-review--kind review)))
      (should-not (harness-ui-patch-review--r-selector review))
      (should (string-match-p "^Changes (6) .*   task/fix against main @ "
                              (harness-ui-patch-review-test--section review))))))

(ert-deftest harness-ui-patch-review-refuses-a-diff-that-cannot-be-right ()
  "A diff typed that names no revisions, and one since a review there was
none of, are refused before the report changes."
  (harness-ui-patch-review-test-with-repo
    (let ((review (harness-ui-patch-review-test--review repo)))
      (dolist (spec '("" "a b c" "-p"))
        (should-error (harness-ui-patch-review-select-diff spec review) :type 'user-error)
        (should-not (harness-ui-patch-review--r-selector review)))
      (should-error (harness-ui-patch-review-select-diff 'since-review review) :type 'user-error)
      (should-not (harness-ui-patch-review--r-selector review))
      (should (eq 'base (harness-ui-patch-review--kind review)))
      (should-not (harness-ui-patch-review--r-selection-error review)))))

(ert-deftest harness-ui-patch-review-keeps-the-diff-shown-when-another-cannot-be-read ()
  "A diff chosen that git cannot read leaves the one shown as it is, and the
report says why; the choice is not the report's."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (files (harness-ui-patch-review--r-files review)))
      (harness-ui-patch-review-test--choose review "nope..task/fix")
      (should-not (harness-ui-patch-review--r-selector review))
      (should (eq files (harness-ui-patch-review--r-files review)))
      (should-not (harness-ui-patch-review--r-loading review))
      (should-not (harness-ui-patch-review--r-error review))
      (should (string-match-p "\\`Could not show the diff .nope\\.\\.task/fix.: There is no commit .nope. in"
                              (harness-ui-patch-review--r-selection-error review)))
      (let ((text (harness-ui-patch-review-test--section review)))
        (should (string-match-p "^  Could not show the diff .nope\\.\\.task/fix.: There is no commit" text))
        (should (string-match-p "^  Diff   \\[● Task branch against main\\]" text))
        (should (string-match-p "^Changes (6) " text)))
      ;; It stays until the next reading.
      (harness-test-await (harness-ui-patch-review--load review))
      (should-not (harness-ui-patch-review--r-selection-error review))
      ;; Another diff shown first: that is the one that comes back.
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-ui-patch-review-test--choose review 'since-review)
      (let ((shown (harness-ui-patch-review--r-files review)))
        (should (= 1 (length shown)))
        (harness-ui-patch-review-test--choose review "main..nothing")
        (should (eq 'since-review (harness-ui-patch-review--r-selector review)))
        (should (eq shown (harness-ui-patch-review--r-files review)))
        (should (string-match-p "\\`Could not show the diff .main\\.\\.nothing.: There is no commit .nothing."
                                (harness-ui-patch-review--r-selection-error review)))))))

(ert-deftest harness-ui-patch-review-shows-the-default-when-the-chosen-diff-was-never-read ()
  "A report that opens on a diff it cannot read -- since a review there is
no version of now -- shows the branch against its base, and says why."
  (harness-ui-patch-review-test-with-repo
    (let ((review (harness-ui-patch-review--review-for (harness-ui-patch-review-test--task repo))))
      (setf (harness-ui-patch-review--r-selector review) 'since-review)
      (harness-test-await (harness-ui-patch-review--load review))
      (should-not (harness-ui-patch-review--r-selector review))
      (should (harness-ui-patch-review--r-tip review))
      (should (eq 'base (harness-ui-patch-review--kind review)))
      (should (= 6 (length (harness-ui-patch-review--r-files review))))
      (should (string-match-p "\\`Could not show the changes since the last review: No earlier review"
                              (harness-ui-patch-review--r-selection-error review)))
      (should (string-match-p "^  Could not show the changes since the last review: No earlier review"
                              (harness-ui-patch-review-test--section review))))))

(ert-deftest harness-ui-patch-review-says-nothing-changed-since-the-last-review ()
  "Work handed in again with no new commit changed nothing since the last
review: the report says so, naming the version."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
      ;; The harness recorded the version at round 0; the task was sent back since.
      (setf (change-review-version-meta (change-review-find-version set tip)) (list :round 0))
      (setf (harness-ui-patch-review--r-task review)
            (plist-put (copy-sequence (harness-ui-patch-review--r-task review))
                       :feedback (list (list :text "back"))))
      (harness-ui-patch-review-test--choose review 'since-review)
      (should (eq 'since-review (harness-ui-patch-review--kind review)))
      (should-not (harness-ui-patch-review--r-files review))
      (let ((text (harness-ui-patch-review-test--section review)))
        (should (string-match-p (format "^Changes (0) +task/fix since v1 @ %s$" (substring tip 0 7)) text))
        (should (string-match-p
                 (format "^  Nothing changed since v1 (%s): the branch is where it was at the last review\\.$"
                         (substring tip 0 7))
                 text)))
      ;; Typed revisions with no difference say so too.
      (harness-ui-patch-review-test--choose review "task/fix task/fix")
      (should (string-match-p "^  Nothing differs between task/fix and task/fix\\.$"
                              (harness-ui-patch-review-test--section review))))))

(ert-deftest harness-ui-patch-review-places-threads-on-files-the-diff-does-not-change ()
  "A thread on a file the diff shown leaves out is among the threads, under
its file, where it is now in the branch's whole change; one on a file the
diff changes is placed in that diff."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (b3 (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?"))
           (eighteen (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?"))
           (whole (harness-ui-patch-review-test--comment-on review "d.el" nil "On the file")))
      (ignore whole)
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-ui-patch-review-test--choose review 'since-review)
      (should (equal '("a.el") (harness-ui-patch-review-test--paths
                                (list :files (harness-ui-patch-review--r-files review)))))
      (let ((where (lambda (comment)
                     (change-review-placement set (harness-ui-patch-review-test--thread-of review comment))))
            (text (harness-ui-patch-review-test--section review)))
        ;; The thread on b.el, which the branch deleted and the last review
        ;; saw so, is where it was: placed against the whole change.
        (should (equal '(same 3) (let ((p (funcall where b3))) (list (plist-get p :status) (plist-get p :line)))))
        (should (string-match-p "^  ▾ b\\.el   1 thread$" text))
        (should (string-match-p "^    ● [^ ]+ · line 3 · 1 comment · open " text))
        (should (string-match-p "^  ▾ d\\.el   1 thread$" text))
        (should (string-match-p "^    ● [^ ]+ · the file · 1 comment · open " text))
        ;; The line of the thread on a.el, in the file the diff shows, moved.
        (should (equal '(moved 21 18)
                       (let ((p (funcall where eighteen)))
                         (list (plist-get p :status) (plist-get p :line) (plist-get p :was)))))
        (should (string-match-p "^    ● [^ ]+ · line 21 (was 18) · 1 comment · open " text)))
      ;; With the whole change shown again the threads are all there still,
      ;; each under its file.
      (harness-ui-patch-review-test--choose review 'base)
      (let ((text (harness-ui-patch-review-test--section review)))
        (should (string-match-p "^  ▾ b\\.el   1 thread$" text))
        (should (string-match-p "^  ▾ d\\.el   1 thread$" text))))))

(ert-deftest harness-ui-patch-review-names-the-versions-ediff-compares ()
  "Ediff's two versions are named after what they are in the diff shown: the
merge base and the branch, the version of the last review, the revisions
typed.  A comment on the old one says which."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (first (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
           (start (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix"))
           (short (lambda (sha) (substring sha 0 7))))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (let ((tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
        (should (equal (format "merge base %s" (funcall short start))
                       (harness-ui-patch-review--side-name review 'old)))
        (should (equal (format "task/fix %s" (funcall short tip))
                       (harness-ui-patch-review--side-name review 'new)))
        (should (equal "the merge base" (harness-ui-patch-review--old-phrase review)))
        (harness-ui-patch-review-test--choose review 'since-review)
        (should (equal (format "v1 %s" (funcall short first)) (harness-ui-patch-review--side-name review 'old)))
        (should (equal (format "task/fix %s" (funcall short tip)) (harness-ui-patch-review--side-name review 'new)))
        (should (equal "v1" (harness-ui-patch-review--old-phrase review)))
        (harness-ui-patch-review-test--choose review "task/fix~1")
        (should (equal (format "task/fix~1 %s" (funcall short first))
                       (harness-ui-patch-review--side-name review 'old)))
        (harness-ui-patch-review-test--choose review (format "%s..task/fix~1" (funcall short start)))
        ;; A commit asked for by its own name is not said twice.
        (should (equal (funcall short start) (harness-ui-patch-review--side-name review 'old)))
        (should (equal (format "task/fix~1 %s" (funcall short first))
                       (harness-ui-patch-review--side-name review 'new)))))))

(ert-deftest harness-ui-patch-review-records-the-revision-a-comment-was-written-against ()
  "A comment is against the version the branch ends at, as ever; one made
in a diff that ends elsewhere is against the commit it ends at."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (set (harness-ui-patch-review--r-set review))
           (first (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (let ((tip (harness-ui-patch-review-test--git repo "rev-parse" "task/fix"))
            (revision-of (lambda ()
                           (change-review-comment-revision
                            (change-review-thread-root (car (last (change-review-set-threads set))))))))
        (harness-ui-patch-review--comment-added
         review (harness-ui-patch-review-test--file review "a.el") '(:new . 2) "In the whole change")
        (should (equal tip (funcall revision-of)))
        (harness-ui-patch-review-test--choose review 'since-review)
        (harness-ui-patch-review--comment-added
         review (harness-ui-patch-review-test--file review "a.el") '(:new . 5) "Since the last review")
        (should (equal tip (funcall revision-of)))
        ;; A diff that stops at the earlier commit: the line is that version's.
        (harness-ui-patch-review-test--choose review "main...task/fix~1")
        (harness-ui-patch-review--comment-added
         review (harness-ui-patch-review-test--file review "a.el") '(:new . 2) "In the earlier version")
        (should (equal first (funcall revision-of)))))))

(defun harness-ui-patch-review-test--push (buffer label)
  "Push the button LABEL in BUFFER, as a click on it does."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (pos)
        (while (and (not pos) (search-forward label nil t))
          (when (button-at (match-beginning 0)) (setq pos (match-beginning 0))))
        (unless pos (error "No %s button in %s" label (buffer-name)))
        (push-button pos)))))

(ert-deftest harness-ui-patch-review-report-chooses-the-diff ()
  "The report has a line under its heading to choose the diff by: a click on
a button shows it, d asks in the minibuffer, a diff typed is asked for.
With no review before this one the choice since it is refused."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (text (lambda () (harness-ui-patch-review-test--text popout))))
      (harness-ui-patch-review-test--wait-text
       popout "^  Diff   \\[● Task branch against main\\]  \\[Since last review\\]  \\[Other…\\]$")
      ;; d chooses from the heading, from the line, and from a file's row.
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "^Changes (")
        (should (eq #'harness-ui-patch-review-select-diff (key-binding "d")))
        (should (eq #'harness-ui-patch-review-toggle-file-tree (key-binding "t")))
        (should (eq #'harness-ui-patch-review-threads (key-binding "T")))
        (re-search-forward "^  Diff")
        (should (eq #'harness-ui-patch-review-select-diff (key-binding "d")))
        (goto-char (harness-ui-patch-review--row-start id 0))
        (should (eq #'harness-ui-patch-review-select-diff (key-binding "d"))))
      ;; Nothing was reviewed before this: the click says so, and nothing moves.
      (should-error (harness-ui-patch-review-test--push popout "[Since last review]") :type 'user-error)
      (should-not (harness-ui-patch-review--r-selector review))
      ;; The branch moves and is read again: the first version is the last review.
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-ui-patch-review-test--wait-text popout "\\[Since last review (v1)\\]")
      (harness-ui-patch-review-test--push popout "[Since last review (v1)]")
      (harness-ui-patch-review-test--wait-text
       popout "^Changes (1)   0 of 1 file viewed, 1 left   task/fix since v1 @ ")
      (harness-ui-patch-review-test--wait-text
       popout "^  Diff   \\[Task branch against main\\]  \\[● Since last review (v1)\\]  \\[Other…\\]$")
      (should (string-match-p "^    M  a\\.el +\\+4 −1$" (funcall text)))
      (should-not (string-search "b.el" (funcall text)))
      ;; Other…: asks for the revisions, and a click on it again asks again,
      ;; with what was typed to start from.
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "main..task/fix")))
        (harness-ui-patch-review-test--push popout "[Other…]"))
      (harness-ui-patch-review-test--wait-text popout "^Changes (7) ")
      (harness-ui-patch-review-test--wait-text popout "\\[● Other: main\\.\\.task/fix\\]$")
      (should (string-match-p "^    M  keep\\.el " (funcall text)))
      (let (default)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt &optional _initial _history def &rest _) (setq default def) "task/fix~1")))
          (harness-ui-patch-review-test--push popout "[● Other: main..task/fix]"))
        (should (equal "main..task/fix" default)))
      (harness-ui-patch-review-test--wait-text popout "\\[● Other: task/fix~1\\]$")
      (harness-ui-patch-review-test--wait-text popout "^Changes (1) ")
      ;; d in the minibuffer: the three, the one shown now the default.
      (let (asked)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &optional _pred _require _initial _history default &rest _)
                     (setq asked (list prompt (all-completions "" collection) default))
                     "Task branch against main")))
          (with-current-buffer popout
            (goto-char (harness-ui-patch-review--row-start id 0))
            (call-interactively (key-binding "d"))))
        (should (equal '("Show the diff: "
                         ("Task branch against main" "Since last review (v1)" "Other: task/fix~1")
                         "Other: task/fix~1")
                       asked)))
      (harness-ui-patch-review-test--wait-text popout "^Changes (6) ")
      (harness-ui-patch-review-test--wait-text popout "^  Diff   \\[● Task branch against main\\]")
      ;; Choosing Other… from the minibuffer asks what to compare.
      (let (prompts)
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Other…"))
                  ((symbol-function 'read-string)
                   (lambda (prompt &rest _) (push prompt prompts) "main...task/fix")))
          (with-current-buffer popout
            (goto-char (point-min))
            (re-search-forward "^Changes (")
            (call-interactively (key-binding "d"))))
        (should (string-match-p "Diff of revisions (A\\.\\.B, A\\.\\.\\.B, A B, or A against the branch)"
                                (car prompts))))
      (harness-ui-patch-review-test--wait-text popout "\\[● Other: main\\.\\.\\.task/fix\\]$")
      (harness-test-wait (lambda () (and (not (harness-ui-patch-review--r-loading review))
                                         (equal "main...task/fix" (harness-ui-patch-review--r-shown-selector review))))
                         5 "the diff to be read")
      ;; A diff that cannot be read is said so; the one shown stays.
      (harness-test-await (harness-ui-patch-review-select-diff "nope..task/fix" review))
      (harness-ui-patch-review-test--wait-text popout "^  Could not show the diff .nope\\.\\.task/fix.: There is no commit")
      (should (string-match-p "\\[● Other: main\\.\\.\\.task/fix\\]$" (funcall text)))
      (should (equal "main...task/fix" (harness-ui-patch-review--r-selector review))))))

(ert-deftest harness-ui-patch-review-chooses-the-diff-before-opening ()
  "C-u C-c C-d in a task's session asks which diff to open the changes at,
and the report keeps the choice; without the prefix nothing is asked.  Asked
again with the report open, the report reads the diff chosen."
  (harness-ui-patch-review-test-with-task
    (harness-ui-patch-review-test--give-branch board id)
    (let ((chat (harness-ui-display-session sid))
          (asked nil))
      (should chat)
      (harness-test-wait (lambda () (harness-ui-review--task sid)) 5 "the session's task")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (setq asked t) "Other…"))
                ((symbol-function 'read-string) (lambda (&rest _) "main..task/fix")))
        ;; Without the prefix: the report opens at the branch against main.
        (with-current-buffer chat
          (call-interactively #'harness-ui-patch-review-open))
        (should-not asked)
        (let ((popout (harness-ui-popout-buffer (list 'report id))))
          (harness-ui-patch-review-test--wait-text popout "^Changes (6) ")
          (harness-ui-patch-review-test--wait-text popout "\\[● Task branch against main\\]")
          ;; A diff asked for with the prefix is read, the report being open.
          (with-current-buffer chat
            (let ((current-prefix-arg '(4)))
              (call-interactively #'harness-ui-patch-review-open)))
          (should asked)
          (harness-ui-patch-review-test--wait-text popout "^Changes (7) ")
          (harness-ui-patch-review-test--wait-text popout "\\[● Other: main\\.\\.task/fix\\]$")))
      ;; Closed, it opens at the diff chosen.
      (kill-buffer (harness-ui-popout-buffer (list 'report id)))
      (with-current-buffer chat
        (call-interactively #'harness-ui-patch-review-open))
      (let ((popout (harness-ui-popout-buffer (list 'report id))))
        (harness-ui-patch-review-test--wait-text popout "^Changes (7) ")
        (should (equal "main..task/fix"
                       (harness-ui-patch-review--r-selector (gethash id harness-ui-patch-review--reviews)))))
      ;; Typed revisions that cannot be right are refused: nothing changes.
      ;; (The choice of typing some is labelled with what was typed.)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (car (cl-remove-if-not (lambda (label) (string-prefix-p "Other" label))
                                          (all-completions "" collection)))))
                ((symbol-function 'read-string) (lambda (&rest _) "a b c")))
        (with-current-buffer chat
          (let ((current-prefix-arg '(4)))
            (should-error (call-interactively #'harness-ui-patch-review-open) :type 'user-error))))
      (should (equal "main..task/fix"
                     (harness-ui-patch-review--r-selector (gethash id harness-ui-patch-review--reviews))))
      ;; An answer that is none of the three is refused too.
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Something else")))
        (with-current-buffer chat
          (let ((current-prefix-arg '(4)))
            (should-error (call-interactively #'harness-ui-patch-review-open) :type 'user-error)))))))

(ert-deftest harness-ui-patch-review-keeps-the-diff-chosen-when-the-report-opens-again ()
  "The diff chosen is the review's, not the popout's: closed and opened again,
the report shows it.  A diff since the last review waits for the versions,
which the harness keeps, to say which commit that was."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review)))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-test-await (harness-ui-patch-review-select-diff 'since-review review))
      (harness-ui-patch-review-test--wait-text popout "^Changes (1) .*task/fix since v1 @ ")
      ;; The harness has both versions, which is all a reopened report has to go by.
      (harness-test-wait (lambda () (= 2 (length (plist-get (harness-call 'patch-review/get id) :versions))))
                         5 "the harness to keep the two versions")
      (kill-buffer popout)
      (setf (change-review-set-versions set) nil)
      (should-not (harness-ui-patch-review--last-review review (harness-ui-patch-review--r-branch-tip review)))
      (let ((again (harness-ui-patch-review-test--report board id)))
        (should-not (eq popout again))
        (harness-ui-patch-review-test--wait-text again "^Changes (1) .*task/fix since v1 @ ")
        (harness-ui-patch-review-test--wait-text
         again "^  Diff   \\[Task branch against main\\]  \\[● Since last review (v1)\\]  \\[Other…\\]$")
        (should (eq 'since-review (harness-ui-patch-review--r-selector review)))
        (should-not (harness-ui-patch-review--r-selection-error review))
        (should (equal '("a.el") (mapcar #'change-review-file-path (harness-ui-patch-review--r-files review))))))))

(ert-deftest harness-ui-patch-review-compares-what-the-diff-chosen-compares ()
  "Ediff compares the two versions the diff shows, named after them, and the
comments on the old one say which it is.  Choosing another diff ends Ediff,
the frame as it was."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (layout (harness-ui-patch-review-test--layout))
           (first (harness-ui-patch-review-test--git repo "rev-parse" "task/fix")))
      (harness-ui-patch-review-test--advance repo)
      (harness-test-await (harness-ui-patch-review--load review))
      (harness-test-await (harness-ui-patch-review-select-diff 'since-review review))
      (harness-ui-patch-review-test--wait-text popout "^Changes (1) .*task/fix since v1 @ ")
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 0))
        (call-interactively (key-binding (kbd "RET"))))
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (buffers (harness-ui-patch-review--ediff-buffers review))
             prompt)
        (should (string-prefix-p (format "a.el (v1 %s)" (substring first 0 7)) (buffer-name (nth 1 buffers))))
        (should (string-prefix-p "a.el (task/fix " (buffer-name (nth 2 buffers))))
        ;; The old version is the last review's: a.el as it was.
        (should (string-search "(setq a2 'two)" (harness-ui-patch-review-test--text (nth 1 buffers))))
        (should-not (string-search "(setq top1 1)" (harness-ui-patch-review-test--text (nth 1 buffers))))
        (should (string-search "(setq top1 1)" (harness-ui-patch-review-test--text (nth 2 buffers))))
        ;; The first difference is the three lines in at the top.
        (with-current-buffer control
          (should (equal '(:new . 3) (harness-ui-patch-review--ediff-position))))
        (with-current-buffer (nth 1 buffers)
          (goto-char (point-min))
          (forward-line 1)
          (cl-letf (((symbol-function 'string-edit)
                     (lambda (p _initial callback &rest _)
                       (setq prompt p)
                       (funcall callback "As it was?"))))
            (call-interactively #'harness-ui-patch-review-comment-line)))
        (should (string-prefix-p "Comment on a.el, line 2 of v1:" prompt))
        ;; The comment is in the diff's own lines, against the version shown.
        (let ((root (change-review-thread-root
                     (car (last (change-review-set-threads (harness-ui-patch-review--r-set review)))))))
          (should (eq 'old (change-review-location-side (change-review-comment-location root))))
          (should (string-search "(setq a2 'two)" (change-review-location-excerpt (change-review-comment-location root)))))
        (should (get-buffer-window control))
        ;; Another diff: Ediff goes, the frame is back, the report shows it.
        (harness-test-await (harness-ui-patch-review-select-diff 'base review))
        (should-not (harness-ui-patch-review--r-ediff review))
        (should-not (buffer-live-p control))
        (should (equal layout (harness-ui-patch-review-test--layout)))
        (harness-ui-patch-review-test--wait-text popout "^Changes (6) .*task/fix against main @ ")
        (should (equal "the merge base" (harness-ui-patch-review--old-phrase review)))))))

;;;; The threads in Ediff: folded, and to the room the windows have

(defun harness-ui-patch-review-test--drawn (buffer)
  "Return the threads drawn in the version BUFFER: an alist of (LINE . TEXT).
The text has no properties and starts with the newline that puts it under
its line."
  (with-current-buffer buffer
    (sort (cl-loop for ov in (overlays-in (point-min) (point-max))
                   for text = (or (overlay-get ov 'after-string) (overlay-get ov 'before-string))
                   when (and text (overlay-get ov 'change-review-thread))
                   collect (cons (line-number-at-pos (overlay-start ov)) (substring-no-properties text)))
          (lambda (a b) (< (car a) (car b))))))

(defun harness-ui-patch-review-test--widest (text)
  "Return the width of the widest line of TEXT."
  (apply #'max 0 (mapcar #'string-width (split-string text "\n"))))

(ert-deftest harness-ui-patch-review-folds-threads-in-ediff ()
  "A closed thread is one line in the version Ediff shows, its triangle pointing
right, and TAB under it opens it to its conversation and folds it again: from the
version, on the line at point, and from the control panel, for the threads of
the current difference.  What was folded stays when the next file comes and the
first comes back."
  (harness-ui-patch-review-test-with-task
    (let* ((harness-ui-patch-review-ediff-tree nil)
           (popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (_eighteen (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?"))
           (thread (harness-ui-patch-review-test--thread-of review two))
           (inhibit-message t))
      (ignore popout)
      (change-review-reply set two "Because two reads better." :author (change-review-user "Noah" "noah@example.org")
                           :time (float-time))
      (change-review-close set thread)
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (text (lambda (line) (cdr (assq line (harness-ui-patch-review-test--drawn new))))))
        ;; The closed thread is a line; the open one is in its conversation.
        (should (string-match-p "\n▸ ✓ [^ ]+ · 2 comments · closed.*“Why two\\?”\\'" (funcall text 2)))
        (should (= 2 (length (split-string (funcall text 2) "\n"))))
        (should (string-match-p "\n▾ ● [^ ]+ · 1 comment · open " (funcall text 18)))
        (should (string-search "1/1  Noah" (funcall text 18)))
        ;; In the version, TAB on the line of the thread.
        (with-current-buffer new
          (goto-char (point-min))
          (forward-line 1)
          (should (eq #'change-review-ui-cycle-fold (key-binding (kbd "TAB"))))
          (call-interactively #'change-review-ui-cycle-fold))
        (change-review-ui-flush)
        (should (eq 'expanded (change-review-ui-thread-fold set thread)))
        (should (string-match-p "\n▾ ✓ [^ ]+ · 2 comments · closed .*\n  ┃ 1/2  Noah.*\n  ┃      Why two\\?\n  ┃ 2/2  Noah.*\n  ┃      Because two reads better\\."
                                (funcall text 2)))
        (with-current-buffer new
          (call-interactively #'change-review-ui-cycle-fold))
        (change-review-ui-flush)
        (should (eq 'collapsed (change-review-ui-thread-fold set thread)))
        (should (string-prefix-p "\n▸ ✓ " (funcall text 2)))
        ;; From the control panel: the current difference is line 2, where the thread is.
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-cycle-fold (key-binding (kbd "TAB"))))
          (should (string-search "[Fold thread] TAB" (harness-ui-patch-review-test--text control)))
          (should (= 0 ediff-current-difference))
          (call-interactively #'harness-ui-patch-review-cycle-fold))
        (change-review-ui-flush)
        (should (eq 'expanded (change-review-ui-thread-fold set thread)))
        (should (string-prefix-p "\n▾ ✓ " (funcall text 2)))
        ;; The second difference has the open thread: it goes to one line, and back.
        (with-current-buffer control
          (ediff-next-difference)
          (call-interactively #'harness-ui-patch-review-cycle-fold))
        (change-review-ui-flush)
        (should (string-prefix-p "\n▸ ● " (funcall text 18)))
        (should (string-prefix-p "\n▾ ✓ " (funcall text 2)))
        (with-current-buffer control
          (call-interactively #'harness-ui-patch-review-cycle-fold))
        (change-review-ui-flush)
        (should (string-prefix-p "\n▾ ● " (funcall text 18)))
        ;; Folded on the next file, and still so when the first comes back.
        (with-current-buffer control
          (call-interactively #'harness-ui-patch-review-ediff-next-file))
        (let ((control-2 (harness-ui-patch-review-test--control review 1)))
          (with-current-buffer control-2
            ;; b.el has no thread: there is none to fold.
            (should-error (call-interactively #'harness-ui-patch-review-cycle-fold) :type 'user-error)
            (call-interactively #'harness-ui-patch-review-ediff-previous-file)))
        (harness-ui-patch-review-test--control review 0)
        (let ((again (nth 2 (harness-ui-patch-review--ediff-buffers review))))
          (should-not (eq again new))
          (should (string-prefix-p "\n▾ ✓ " (cdr (assq 2 (harness-ui-patch-review-test--drawn again))))))
        (with-current-buffer (harness-ui-patch-review-test--control review 0)
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-folds-the-threads-of-a-deletion ()
  "The control panel's TAB folds the threads of the merge base's lines a
difference removes, those of the branch's it adds: a thread is in the
difference if it is placed on a line the difference spans, on its side."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (b3 (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?"))
           (thread (harness-ui-patch-review-test--thread-of review b3))
           (inhibit-message t))
      (ignore popout)
      (change-review-close set thread)
      (harness-ui-patch-review-ediff review 1)
      (let* ((control (harness-ui-patch-review-test--control review 1))
             (old (nth 1 (harness-ui-patch-review--ediff-buffers review))))
        (with-current-buffer control
          ;; b.el is deleted: the one difference spans all five lines of the old, none of the new.
          (should (equal '(:old (1 . 5) :new nil) (harness-ui-patch-review--difference-ranges)))
          (should (equal (list thread) (harness-ui-patch-review--difference-threads
                                        review (harness-ui-patch-review-test--file review "b.el")))))
        (should (string-prefix-p "\n▸ ✓ " (cdr (assq 3 (harness-ui-patch-review-test--drawn old)))))
        (with-current-buffer control
          (call-interactively #'harness-ui-patch-review-cycle-fold))
        (change-review-ui-flush)
        (should (string-prefix-p "\n▾ ✓ " (cdr (assq 3 (harness-ui-patch-review-test--drawn old)))))
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-draws-threads-to-the-windows-of-ediff ()
  "The threads in the versions fit the windows that show them: no line is
wider, whether Ediff lays them out one over the other or side by side; and
they are drawn again when a window changes its size."
  (harness-ui-patch-review-test-with-task
    (let* ((harness-ui-patch-review-ediff-tree nil)
           (popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (comment (harness-ui-patch-review-test--comment-on
                     review "a.el" '(:new . 2)
                     (string-join (make-list 12 "A question that goes on and on and on") " ")))
           (thread (harness-ui-patch-review-test--thread-of review comment))
           (fits (lambda (buffer)
                   ;; Every thread drawn in BUFFER is narrower than its window.
                   (let ((columns (window-max-chars-per-line (get-buffer-window buffer)))
                         (drawn (harness-ui-patch-review-test--drawn buffer)))
                     (should drawn)
                     (dolist (entry drawn)
                       (should (<= (harness-ui-patch-review-test--widest (cdr entry)) columns)))
                     columns)))
           (inhibit-message t))
      (ignore popout set)
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (stacked (funcall fits new)))
        ;; Drawn to the window, not to the 80 columns a buffer no window shows gets.
        (should (equal (change-review-ui-current-size)
                       (with-current-buffer new (change-review-ui-current-size))))
        (should (equal (with-current-buffer new (change-review-ui-current-size))
                       (buffer-local-value 'harness-ui-patch-review--drawn-size new)))
        ;; Side by side: the windows are half as wide, and the thread is drawn again.
        (with-current-buffer control
          (ediff-toggle-split))
        (should (< (window-max-chars-per-line (get-buffer-window new)) stacked))
        (should-not (equal (buffer-local-value 'harness-ui-patch-review--drawn-size new)
                           (with-current-buffer new (change-review-ui-current-size))))
        (with-current-buffer new (harness-ui-patch-review--side-resized (get-buffer-window new)))
        (harness-test-wait (lambda ()
                             (equal (buffer-local-value 'harness-ui-patch-review--drawn-size new)
                                    (with-current-buffer new (change-review-ui-current-size))))
                           5 "the thread to be drawn again for the narrower window")
        (should (< (funcall fits new) stacked))
        ;; Nothing to draw again once it is as wide as the window.
        (with-current-buffer new
          (let (drawn)
            (setq-local change-review-ui--redraw-function (lambda () (setq drawn t)))
            (harness-ui-patch-review--redraw-side new)
            (should-not drawn)
            (setq-local change-review-ui--redraw-function
                        (lambda () (harness-ui-patch-review--decorate
                                    review (harness-ui-patch-review-test--file review "a.el") new 'new nil)))))
        ;; The thread is cut where it is taller than the window.
        (with-current-buffer new
          (let ((change-review-ui-max-thread-lines 4))
            (funcall change-review-ui--redraw-function)
            (should (string-match-p "┃      … [0-9]+ more lines\\'"
                                    (cdr (assq 2 (harness-ui-patch-review-test--drawn new)))))
            (should (<= (length (split-string (cdr (assq 2 (harness-ui-patch-review-test--drawn new))) "\n")) 5))))
        (ignore thread)
        (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(defun harness-ui-patch-review-test--drag (overlay text from to)
  "Drag the mouse over TEXT of what OVERLAY shows, from the character FROM to TO.
Both count from where TEXT starts.  The press, the move and the release are
those the command loop would give `change-review-ui-mouse-select', over the
window that shows the overlay's buffer; there is no display to point a mouse at
here, so the positions are made by hand."
  (let* ((window (get-buffer-window (overlay-buffer overlay) t))
         (string (overlay-get overlay 'after-string))
         (base (or (string-search text string) (error "No %S under the line" text)))
         (posn (lambda (after)
                 (list window (overlay-start overlay) (cons after 5) 0
                       (cons string (+ base after)) (overlay-start overlay)
                       (cons after 0) nil (cons 0 0) (cons 1 10)))))
    (should (window-live-p window))
    (setq unread-command-events
          (list (list 'mouse-movement (funcall posn to))
                (list 'drag-mouse-1 (funcall posn from) (funcall posn to))))
    (let ((this-command 'change-review-ui-mouse-select))
      (change-review-ui-mouse-select (list 'down-mouse-1 (funcall posn from))))))

(ert-deftest harness-ui-patch-review-quote-replies-to-a-comment-in-ediff ()
  "A comment under a line of either version Ediff compares is no text of the
buffer, so the mouse selects it: a drag over its text selects a part, which
C-c > quotes in a reply to the comment, a draft in its thread, point under
the quote.  From the control panel C-c > quotes the last comment of the
thread at the current difference."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (bot (change-review-agent "Claude" :session "sess-9" :tool-call "toolu_7"))
           (two (harness-ui-patch-review-test--comment-on
                 review "a.el" '(:new . 2) "Why two? The loop only ever uses one."))
           (answer (change-review-reply
                    set two "Because the first pass needs a placeholder."
                    :author bot :sent (float-time)))
           (thread (harness-ui-patch-review-test--thread-of review two))
           (calls nil)
           (reader (lambda (prompt initial callback &optional point)
                     (push (list prompt initial point) calls)
                     (funcall callback (concat initial "I see."))))
           (transient-mark-mode t))
      (ignore popout)
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (overlay (with-current-buffer new
                        (cl-find-if (lambda (ov) (equal (overlay-get ov 'change-review-thread)
                                                        (change-review-thread-id thread)))
                                    (overlays-in (point-min) (point-max))))))
        (should overlay)
        ;; The text of the comments is the mouse's.
        (should (eq change-review-ui-text-map
                    (get-text-property (string-search "only ever" (overlay-get overlay 'after-string))
                                       'keymap (overlay-get overlay 'after-string))))
        (with-current-buffer new
          ;; The version's own C-c > starts a thread on lines selected in it
          ;; (`harness-ui-patch-review-thread-reply'); text of a comment
          ;; selected with the mouse, or nothing selected, is the library's.
          (should (eq #'harness-ui-patch-review-thread-reply (key-binding (kbd "C-c >"))))
          (harness-ui-patch-review-test--drag overlay "only ever uses one" 0 18)
          (should (equal '("c" "only ever uses one")
                         (let ((selection (overlay-get overlay 'change-review-selection)))
                           (list (substring (car selection) 0 1)
                                 (substring (change-review-comment-body two) (nth 1 selection) (nth 2 selection))))))
          (goto-char (point-min))
          (let ((change-review-ui-read-function reader))
            (call-interactively #'harness-ui-patch-review-thread-reply)))
        (should (equal "> only ever uses one\n\nI see."
                       (change-review-comment-body (change-review-thread-last-comment thread))))
        (should (equal (change-review-comment-id two)
                       (change-review-comment-reply-to (change-review-thread-last-comment thread))))
        (should (change-review-comment-draft-p (change-review-thread-last-comment thread)))
        (pcase-let ((`(,prompt ,initial ,point) (car calls)))
          (should (string-match-p "\\`Reply to Noah's comment 1/2 on a\\.el:2" prompt))
          (should (equal "> only ever uses one\n\n" initial))
          (should (eq 'end point)))
        ;; With nothing selected: the last comment of the thread, whole.
        (change-review-ui-flush)
        (with-current-buffer new
          (goto-char (point-min))
          (forward-line 1)
          (let ((change-review-ui-read-function (lambda (_p initial _callback &optional _point)
                                                  (push initial calls))))
            (call-interactively #'harness-ui-patch-review-thread-reply)))
        (should (equal "> > only ever uses one\n>\n> I see.\n\n" (car calls)))
        ;; The control panel quotes the last comment of the thread at the current
        ;; difference, which is on line 2.
        (with-current-buffer control
          (should (equal '(:new . 2) (harness-ui-patch-review--ediff-position)))
          (should (eq #'harness-ui-patch-review-quote-reply (key-binding (kbd "C-c >"))))
          (let ((change-review-ui-read-function reader))
            (call-interactively #'harness-ui-patch-review-quote-reply)))
        (pcase-let ((`(,prompt ,initial ,point) (car calls)))
          (should (string-match-p "\\`Reply to Noah's comment 3/3" prompt))
          (should (equal "> > only ever uses one\n>\n> I see.\n\n" initial))
          (should (eq 'end point)))
        (ignore answer)
        ;; What is selected in a version is what the control panel quotes, as what
        ;; is marked there is what C-c > quotes.
        (change-review-ui-flush)
        (let ((overlay (with-current-buffer new
                         (cl-find-if (lambda (ov) (equal (overlay-get ov 'change-review-thread)
                                                         (change-review-thread-id thread)))
                                     (overlays-in (point-min) (point-max))))))
          (harness-ui-patch-review-test--drag overlay "Because the first pass" 0 7)
          (with-current-buffer control
            (let ((change-review-ui-read-function reader))
              (call-interactively #'harness-ui-patch-review-quote-reply)))
          (pcase-let ((`(,prompt ,initial ,point) (car calls)))
            (should (string-match-p "\\`Reply to Claude's comment 2/" prompt))
            (should (equal "> Because\n\n" initial))
            (should (eq 'end point)))
          (should-not (with-current-buffer new (change-review-ui--overlay-selection))))
        ;; The second difference has no thread: nothing to quote.
        (with-current-buffer control
          (ediff-next-difference)
          (should-error (call-interactively #'harness-ui-patch-review-quote-reply) :type 'user-error)
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

;;;; Self-contained

(defun harness-ui-patch-review-test--agent-closes (review id sid comment text)
  "Have the agent of task ID, session SID, answer the thread of COMMENT with TEXT and close it.
It goes through the harness, as the agent's tool does; the UI hears of it.
Wait until REVIEW's set has the close; return the thread."
  (let* ((thread (harness-ui-patch-review-test--thread-of review comment))
         (before (length (change-review-thread-history thread))))
    (harness-call 'patch-review/comment id text
                  :thread (change-review-thread-id thread) :status "closed"
                  :session sid :call-id "toolu_close")
    (harness-test-wait (lambda () (> (length (change-review-thread-history thread)) before))
                       5 "the UI to hear that the agent closed the thread")
    thread))

(ert-deftest harness-ui-patch-review-lists-what-the-agent-closed-to-review ()
  "A thread the agent closed waits for the reviewer: the heading counts it, as
a button that lists it, the file's row says so, and the report lists it under
its file with the open threads, where one the reviewer closed is only counted.
m on its row marks it reviewed, which the harness keeps, and it leaves the
rows; the agent closing it again brings it back."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"
                                                          :sent (float-time)))
           (_eighteen (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?"))
           (b3 (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?")))
      (harness-ui-patch-review-test--wait-harness-threads id 3)
      ;; The reviewer closes b3 themselves: nothing of theirs to review.
      (change-review-close set (harness-ui-patch-review-test--thread-of review b3))
      (let ((thread (harness-ui-patch-review-test--agent-closes review id sid two "Because two reads better.")))
        (should (change-review-thread-unreviewed-p set thread))
        (harness-ui-patch-review-test--wait-text
         popout "^Changes (6) .*   1 open, 2 closed \\[1 to review\\] \\[Threads\\]$")
        (let ((text (harness-ui-patch-review-test--text popout)))
          ;; The file's row: its threads and how many of the closed ones wait.
          (should (string-match-p "^    M  a\\.el +\\+2 −2   1 open   1 closed (1 to review)   1 draft$" text))
          (should (string-match-p "^    D  b\\.el +\\+0 −5   1 closed   1 draft$" text))
          ;; The section shows the open threads: the one to review is behind its filter.
          (should (string-search "Why eighteen?" text))
          (should-not (string-search "Because two reads better." text))
          ;; The one the reviewer closed is only counted.
          (should-not (string-search "Who used b3?" text)))
        ;; The heading's button shows them in the section, filtered.
        (with-current-buffer popout
          (goto-char (point-min))
          (re-search-forward "\\[1 to review\\]")
          (backward-char 3)
          (push-button)
          (should (eq 'unreviewed change-review-ui--filter)))
        (harness-ui-patch-review-test--wait-text popout "Because two reads better\\.")
        (let ((text (harness-ui-patch-review-test--text popout)))
          (should-not (string-search "Why eighteen?" text))
          (should-not (string-search "Who used b3?" text)))
        ;; m on the thread: reviewed, kept by the harness, off the section.
        (with-current-buffer popout
          (goto-char (point-min))
          (re-search-forward "Because two reads better\\.")
          (should (eq #'change-review-ui-toggle-reviewed (key-binding "m")))
          (should (eq #'change-review-ui-mark-all-reviewed (key-binding "M")))
          (call-interactively (key-binding "m")))
        (should-not (change-review-thread-unreviewed-p set thread))
        (harness-ui-patch-review-test--wait-text popout "1 to review" t)
        (let ((text (harness-ui-patch-review-test--text popout)))
          (should (string-match-p "^    M  a\\.el +\\+2 −2   1 open   1 closed   1 draft$" text))
          (should-not (string-search "Why two?" text)))
        (harness-test-wait
         (lambda ()
           (let ((history (plist-get (cl-find (change-review-thread-id thread)
                                              (harness-ui-patch-review-test--harness-threads id)
                                              :key (lambda (th) (plist-get th :id)) :test #'equal)
                                     :history)))
             (numberp (plist-get (car (last history)) :reviewed))))
         5 "the harness to keep that the thread was reviewed")
        ;; Opened and closed again by the agent, it waits once more.
        (change-review-reopen set thread)
        (harness-test-wait (lambda () (equal "open" (plist-get (cl-find (change-review-thread-id thread)
                                                                        (harness-ui-patch-review-test--harness-threads id)
                                                                        :key (lambda (th) (plist-get th :id))
                                                                        :test #'equal)
                                                               :status)))
                           5 "the harness to open the thread")
        (harness-ui-patch-review-test--agent-closes review id sid two "Now it is two for good.")
        (should (change-review-thread-unreviewed-p set thread))
        (harness-ui-patch-review-test--wait-text
         popout "^    M  a\\.el +\\+2 −2   1 open   1 closed (1 to review)   1 draft$")))))

(ert-deftest harness-ui-patch-review-draws-what-the-agent-closed-whole-in-ediff ()
  "In Ediff a thread the agent closed that waits for the reviewer is drawn
whole, its answer in sight, where other closed threads are a line.  m, in a
version or in the control panel, marks it reviewed -- and makes it wait again
-- and the thread follows."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"
                                                          :sent (float-time)))
           (thread (harness-ui-patch-review-test--agent-closes review id sid two "Because two reads better.")))
      (ignore popout)
      (harness-ui-patch-review-ediff review 0)
      (let* ((control (harness-ui-patch-review-test--control review 0))
             (new (nth 2 (harness-ui-patch-review--ediff-buffers review)))
             (shown (lambda () (with-current-buffer new
                                 (mapconcat (lambda (ov) (substring-no-properties (or (overlay-get ov 'after-string) "")))
                                            (overlays-in (point-min) (point-max)) "")))))
        ;; Whole: both comments, and what it waits for.
        (should (string-match-p "2/2  .* (agent)" (funcall shown)))
        (should (string-search "Because two reads better." (funcall shown)))
        (should (string-search "· to review" (funcall shown)))
        ;; m in the version, on the line of the thread.
        (with-current-buffer new
          (goto-char (point-min))
          (forward-line 1)
          (should (eq #'change-review-ui-toggle-reviewed (key-binding "m")))
          (call-interactively #'change-review-ui-toggle-reviewed))
        (should-not (change-review-thread-unreviewed-p set thread))
        (change-review-ui-flush)
        ;; Reviewed, it is a line like any closed thread.
        (should (string-match-p "closed\\(?: by .*, .*\\)? · reviewed" (funcall shown)))
        (should-not (string-search "2/2" (funcall shown)))
        ;; m in the control panel acts on the thread at the current difference.
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-toggle-reviewed (key-binding "m")))
          (should (equal '(:new . 2) (harness-ui-patch-review--ediff-position)))
          (call-interactively #'harness-ui-patch-review-toggle-reviewed))
        (should (change-review-thread-unreviewed-p set thread))
        (change-review-ui-flush)
        (should (string-match-p "2/2  .* (agent)" (funcall shown)))
        ;; The second difference has no thread: m says so.
        (with-current-buffer control
          (ediff-next-difference)
          (should-error (call-interactively #'harness-ui-patch-review-toggle-reviewed) :type 'user-error)
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

(ert-deftest harness-ui-patch-review-lists-the-other-threads-to-review ()
  "A thread on the change as a whole is shown by the section's \"to review\"
filter when the agent closed it and the reviewer has not looked, and m on it
marks it reviewed."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (whole (change-review-comment set "Is this the whole of it?" :sent (float-time)
                                         :author (change-review-user "Noah" "noah@example.org")))
           (done (change-review-comment set "Fine as it is." :sent (float-time)
                                        :author (change-review-user "Noah" "noah@example.org"))))
      (harness-ui-patch-review-test--wait-harness-threads id 2)
      ;; The reviewer closed one themselves; the agent closes the other.
      (change-review-close set (harness-ui-patch-review-test--thread-of review done))
      (let ((thread (harness-ui-patch-review-test--agent-closes review id sid whole "Yes: nothing else is needed.")))
        (harness-ui-patch-review-test--wait-text popout "0 open, 2 closed \\[1 to review\\] \\[Threads\\]")
        (with-current-buffer popout (change-review-ui-set-filter 'unreviewed))
        (harness-ui-patch-review-test--wait-text popout "Yes: nothing else is needed\\.")
        (let ((text (harness-ui-patch-review-test--text popout)))
          (should (string-match-p "^  ▾ The change as a whole +1 thread$" text))
          (should-not (string-search "Fine as it is." text)))
        (with-current-buffer popout
          (goto-char (point-min))
          (re-search-forward "Yes: nothing else is needed\\.")
          (should (eq #'change-review-ui-toggle-reviewed (key-binding "m")))
          (call-interactively (key-binding "m")))
        (should-not (change-review-thread-unreviewed-p set thread))
        (harness-ui-patch-review-test--wait-text popout "Yes: nothing else is needed\\." t)
        (should (string-match-p "0 open, 2 closed \\[Threads\\]" (harness-ui-patch-review-test--text popout)))))))

;;;; A link to a thread

(defun harness-ui-patch-review-test--at-thread-p (buffer id)
  "Non-nil when point in BUFFER is on the thread ID, at its header."
  (with-current-buffer buffer
    (and (equal id (get-text-property (point) 'change-review-thread))
         (get-text-property (point) 'change-review-thread-start))))

(ert-deftest harness-ui-patch-review-shows-a-thread-from-a-link ()
  "A link to a thread opens the task's report with point on the thread, whether
the report was open or not, and the thread may be named by the start of its id."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (eighteen (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?"))
           (thread-id (change-review-thread-id (harness-ui-patch-review-test--thread-of review eighteen))))
      (ignore two)
      (harness-ui-patch-review-test--wait-harness-threads id 2)
      (harness-ui-patch-review-test--wait-text popout "Why eighteen\?")
      ;; The report open, with point at its top.
      (with-current-buffer popout (goto-char (point-min)))
      (harness-ui-patch-review-show-thread id thread-id)
      (harness-test-wait (lambda () (harness-ui-patch-review-test--at-thread-p popout thread-id))
                         15 "point on the thread")
      ;; The report gone, the link opens it again, at the thread: by the start of its id.
      (harness-ui-popout-close (list 'report id))
      (should-not (harness-ui-popout-buffer (list 'report id)))
      (harness-ui-patch-review-show-thread id (substring thread-id 0 4))
      (let ((opened (harness-test-wait (lambda () (harness-ui-popout-buffer (list 'report id)))
                                       5 "the report to open")))
        (harness-test-wait (lambda () (harness-ui-patch-review-test--at-thread-p opened thread-id))
                           15 "point on the thread in the report that opened")
        (should (eq opened (window-buffer (get-buffer-window opened t))))
        (with-current-buffer opened
          (should (string-match-p "line 18" (buffer-substring-no-properties
                                             (point) (line-end-position)))))))))

(ert-deftest harness-ui-patch-review-shows-a-closed-thread-the-filter-hides ()
  "The report starts on the open threads; a link to a closed one shows it."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (b3 (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?"))
           (thread (harness-ui-patch-review-test--thread-of review b3)))
      (ignore (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
      (change-review-close set thread)
      (harness-ui-patch-review-test--wait-harness-threads id 2)
      (harness-ui-patch-review-test--wait-text popout "Who used b3\?" t)
      (with-current-buffer popout (should (eq 'open change-review-ui--filter)))
      (harness-ui-patch-review-show-thread id (change-review-thread-id thread))
      (harness-test-wait (lambda () (harness-ui-patch-review-test--at-thread-p popout (change-review-thread-id thread)))
                         15 "point on the closed thread")
      (with-current-buffer popout
        (should (eq 'all change-review-ui--filter)))
      (should (string-search "Who used b3?" (harness-ui-patch-review-test--text popout))))))

(ert-deftest harness-ui-patch-review-says-when-a-link-names-no-thread ()
  "A thread the review does not have is said so in the echo area, and the
report opens all the same: it is what the link was about."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews)))
      (ignore (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
      (harness-ui-patch-review-test--wait-harness-threads id 1)
      (harness-ui-popout-close (list 'report id))
      (harness-ui-patch-review-show-thread id "t-nothing")
      (harness-test-wait (lambda () (harness-ui-popout-buffer (list 'report id))) 5 "the report to open")
      (should (string-match-p "has no thread t-nothing"
                              (with-current-buffer "*Messages*" (buffer-string))))
      ;; A task that is not there either.
      (harness-ui-patch-review-show-thread "t-nobody" "t-nothing")
      (harness-test-wait (lambda () (string-match-p "Could not read the task t-nobody"
                                                    (with-current-buffer "*Messages*" (buffer-string))))
                         5 "the echo area to say the task is not there")
      (ignore popout))))

(ert-deftest harness-ui-patch-review-shows-a-thread-in-the-threads-view-without-the-changes ()
  "Where the report draws no changes -- the task has no branch -- the library's
threads view shows the thread, all of them, point on it; the comments link to
files as the task's directory has them."
  (harness-ui-patch-review-test-with-task
    (let* ((task (harness-call 'task/get id))
           (review (harness-ui-patch-review--review-for task))
           (set (harness-ui-patch-review--r-set review)))
      (should-not (harness-ui-patch-review--report-shows-p review))
      (change-review-comment set "Overall: fine." :author (change-review-user "Noah" "noah@example.org"))
      (let ((whole (change-review-comment set "A second point."
                                          :author (change-review-user "Noah" "noah@example.org"))))
        (harness-ui-patch-review-test--wait-harness-threads id 2)
        (harness-ui-patch-review-show-thread
         id (change-review-thread-id (harness-ui-patch-review-test--thread-of review whole)))
        (let ((view (harness-test-wait
                     (lambda () (cl-find-if (lambda (b) (eq 'change-review-threads-mode
                                                            (buffer-local-value 'major-mode b)))
                                            (buffer-list)))
                     10 "the threads view")))
          (harness-test-wait
           (lambda () (harness-ui-patch-review-test--at-thread-p
                       view (change-review-thread-id (harness-ui-patch-review-test--thread-of review whole))))
           10 "point on the thread in the threads view")
          ;; The links in its comments are written in the task's session.
          (with-current-buffer view
            (should (equal (plist-get task :session) (harness-ui-patch-review--link-context)))
            (kill-buffer view)))
        (should-not (harness-ui-popout-buffer (list 'report id)))))))

(ert-deftest harness-ui-patch-review-opens-a-linked-thread ()
  "ui-linking opens a link to a thread with the handler this module registers,
whichever of the two loads first, and the registration goes with the module."
  (harness-ui-patch-review-test-with-task
    (let ((popout (harness-ui-patch-review-test--changes board id))
          (harness-ui-linking-handlers nil)
          (harness-ui-linking-context-functions nil))
      (ignore popout)
      (harness-test-load-module 'ui-linking)
      (should (eq #'harness-ui-patch-review--follow-thread
                  (cdr (assoc "thread" harness-ui-linking-handlers))))
      (should (memq #'harness-ui-patch-review--link-context harness-ui-linking-context-functions))
      (let* ((review (gethash id harness-ui-patch-review--reviews))
             (eighteen (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 18) "Why eighteen?"))
             (thread-id (change-review-thread-id (harness-ui-patch-review-test--thread-of review eighteen)))
             (resolve (lambda (method params callback &optional on-error)
                        (ignore method params on-error)
                        (funcall callback (list :kind "thread" :task id :thread thread-id)))))
        (harness-ui-patch-review-test--wait-harness-threads id 1)
        (harness-ui-popout-close (list 'report id))
        ;; Only the harness's resolving is faked; the report is real.
        (let ((call (symbol-function 'harness-ui-call)))
          (cl-letf (((symbol-function 'harness-ui-call)
                     (lambda (method params callback &optional on-error)
                       (if (equal method "_harness/link/resolve")
                           (funcall resolve method params callback on-error)
                         (funcall call method params callback on-error)))))
            (harness-ui-linking-follow (harness-links-thread-url id thread-id))))
        (let ((opened (harness-test-wait (lambda () (harness-ui-popout-buffer (list 'report id)))
                                         5 "the report to open")))
          (harness-test-wait (lambda () (harness-ui-patch-review-test--at-thread-p opened thread-id))
                             15 "point on the thread"))
        ;; Off, the module takes its handler away and leaves the others.
        (setf (alist-get "session" harness-ui-linking-handlers nil nil #'equal) #'ignore)
        (harness-module-disable 'ui-patch-review)
        (should-not (assoc "thread" harness-ui-linking-handlers))
        (should (assoc "session" harness-ui-linking-handlers))
        (should-not (memq #'harness-ui-patch-review--link-context harness-ui-linking-context-functions))))))

(ert-deftest harness-ui-patch-review-links-a-session-id-in-a-comment ()
  "The id of a session the UI knows, in a comment's Markdown, is a link to it,
as in the chat; the one in code is not."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews)))
      (ignore (harness-ui-patch-review-test--comment-on
               review "a.el" '(:new . 2) (format "See %s for details, not `%s`." sid sid)))
      (harness-ui-patch-review-test--wait-text popout "for details")
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward (format "See %s" (regexp-quote sid)))
        (let ((at (- (point) 4)))
          (should (memq 'harness-ui-session-link-face (ensure-list (get-text-property at 'face))))
          (should (keymapp (get-text-property at 'keymap)))
          (should (equal (format "mouse-1, RET: open the session %s"
                                 (harness-ui-session-name sid))
                         (get-text-property at 'help-echo))))
        ;; The comment wraps at its width, so the id may start a line of its own.
        (re-search-forward (format "not[ \n┃]+%s" (regexp-quote sid)))
        (should (memq 'harness-md-code (ensure-list (get-text-property (- (point) 4) 'face))))
        (should-not (memq 'harness-ui-session-link-face
                          (ensure-list (get-text-property (- (point) 4) 'face))))))))

(ert-deftest harness-ui-patch-review-is-known-only-to-its-halves ()
  "No other file of the harness names the review of a task's changes but its
two halves, the review tools and the ACP lists of what a UI may call and
hear: what knows no harness is the library, whose own test checks that."
  (let ((default-directory harness-test-root)
        (known '("harness-ui-patch-review.el" "harness-patch-review.el"
                 "harness-tools-review.el" "harness-acp.el")))
    (dolist (file (append (list "harness.el")
                          (directory-files "lisp" t "\\.el\\'")
                          (directory-files "lisp/modules" t "\\.el\\'")
                          (directory-files "lisp/ui" t "\\.el\\'")))
      (unless (member (file-name-nondirectory file) known)
        (with-temp-buffer
          (insert-file-contents file)
          (ert-info ((format "%s" file))
            (should-not (search-forward "patch-review" nil t))))))))

(provide 'harness-ui-patch-review-test)
;;; harness-ui-patch-review-test.el ends here
