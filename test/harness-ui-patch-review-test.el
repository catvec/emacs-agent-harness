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
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
(declare-function harness-ui-report-popout "harness-ui-report")
(declare-function harness-acp--drop-client "harness-acp")

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
        ;; n and p move between the files.
        (call-interactively (key-binding "n"))
        (should (eql 1 (cdr (harness-ui-patch-review--at-point))))
        (call-interactively (key-binding "p"))
        (should (eql 0 (cdr (harness-ui-patch-review--at-point))))
        (harness-ui-patch-review-previous-file)
        (should (eql 0 (cdr (harness-ui-patch-review--at-point))))
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
      (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el")
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
      (should-not (string-match-p "approved"
                                  (harness-ui-patch-review--section review nil))))))

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
          ;; The threads are rows under their files.
          (should (string-match-p "^       ↳ ● [^ ]+ · line 2 · Noah[^:]*: “Why two\\? Because the second one reads better\\.” · draft$" text))))
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
        ;; The report says so under the file.
        (let ((text (harness-ui-patch-review--section review (harness-ui-patch-review--counts review))))
          (should (string-match-p "↳ ● [^ ]+ · line 5 (changed since) · Noah[^:]*: “Why two\\?”" text))
          (should (string-match-p "↳ ● [^ ]+ · line 21 (was 18) · Noah[^:]*: “Why eighteen\\?”" text))
          (should (string-match-p "↳ ● [^ ]+ · line 14 (was 11) · Noah[^:]*: “Why eleven\\?”" text))
          (should (string-match-p "↳ ● [^ ]+ · line 3 · Noah[^:]*: “Who used b3\\?”" text)))))))

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
  "RET on a thread's row compares its file in Ediff with that line in sight;
the versions show the threads under their lines, those on removed lines in
the merge base's, drawn as the library draws them: who, when, which
revision, the place in the thread."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (bot (change-review-agent "Claude" :session "sess-9" :tool-call "toolu_7"))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (eighteen (harness-ui-patch-review-test--comment-on
                      review "a.el" '(:new . 18) "Why eighteen? It reads oddly next to seventeen, and the test only ever looks at one of them at a time."))
           (removed (harness-ui-patch-review-test--comment-on review "a.el" '(:old . 2) "Was it better?")))
      (change-review-reply set eighteen "Because the loop needs it." :author bot :sent (float-time))
      (harness-ui-patch-review-test--wait-text popout "↳ ● [^ ]+ · line 18 · Noah")
      (with-current-buffer popout
        (goto-char (point-min))
        (re-search-forward "↳ ● [^\n]*line 18")
        (beginning-of-line)
        ;; The row of a thread is a row of its file.
        (should (eql 0 (cdr (harness-ui-patch-review--at-point))))
        (should (equal '(:new . 18) (get-text-property (point) 'harness-ui-patch-review-where)))
        (should (equal (change-review-thread-id (harness-ui-patch-review-test--thread-of review eighteen))
                       (get-text-property (point) 'change-review-thread)))
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

(ert-deftest harness-ui-patch-review-acts-on-threads-in-ediff ()
  "In a version, r replies to the thread under the line at point and x closes
it or opens it again; in the control panel they act on the thread at the
current difference; e edits your draft there.  The threads draw again."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
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
        ;; Closed, it is a line.
        (should (string-search "closed by" (funcall shown)))
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
          ;; e edits the draft there, not the box.
          (let ((change-review-ui-read-function
                 (lambda (prompt initial callback)
                   (should (string-match-p "\\`Edit your comment in thread" prompt))
                   (should (equal "From the panel" initial))
                   (funcall callback "From the panel, better"))))
            (call-interactively #'harness-ui-patch-review-edit-comment))
          (should (equal "From the panel, better" (change-review-comment-body (change-review-thread-last-comment thread)))))
        ;; The second difference has no thread: r says so, and c starts one.
        (with-current-buffer control
          (ediff-next-difference)
          (should-error (call-interactively #'harness-ui-patch-review-reply) :type 'user-error)
          (call-interactively #'harness-ui-patch-review-ediff-quit))))))

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
      ;; The report hears of it: the row says two comments.
      (harness-ui-patch-review-test--wait-text popout "line 2 · Noah[^:]*: “Why two\\?” · 2 comments")
      ;; An operation the library cannot perform is logged, not raised.
      (harness-ui-patch-review--on-event
       "patch-review/changed" (list id (list :op "set-status" :thread "t-nope" :status "closed")))
      (should (= 2 (length (change-review-thread-comments thread)))))))

(ert-deftest harness-ui-patch-review-lists-the-threads-by-file ()
  "T in the report and in Ediff opens the library's threads view of the
review: by file, with the filter; d there shows a thread in Ediff at its line."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (set (harness-ui-patch-review--r-set review))
           (two (harness-ui-patch-review-test--comment-on review "a.el" '(:new . 2) "Why two?"))
           (b3 (harness-ui-patch-review-test--comment-on review "b.el" '(:old . 3) "Who used b3?")))
      (change-review-close set (harness-ui-patch-review-test--thread-of review b3))
      (harness-ui-patch-review-test--wait-text popout "^Changes (6) .*   1 open, 1 closed \\[Threads\\]")
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 0))
        (should (eq #'harness-ui-patch-review-threads (key-binding "T"))))
      (let (view)
        (with-current-buffer popout
          (goto-char (harness-ui-patch-review--row-start id 0))
          (call-interactively (key-binding "T"))
          (setq view (current-buffer)))
        (should (eq 'change-review-threads-mode (buffer-local-value 'major-mode view)))
        (with-current-buffer view
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-prefix-p "Review of Fix the flaky test" text))
            (should (string-match-p "^▾ a\\.el +1 thread$" text))
            (should (string-search "Why two?" text))
            ;; Open threads at first: the closed one of b.el is behind the filter.
            (should-not (string-search "Who used b3?" text)))
          (change-review-ui-set-filter 'all)
          (should (string-search "Who used b3?" (buffer-substring-no-properties (point-min) (point-max))))
          ;; C-c C-c is sending: the report's box, where the drafts go with the feedback.
          (should (eq #'change-review-ui-send (key-binding (kbd "C-c C-c"))))
          (save-window-excursion
            (call-interactively #'change-review-ui-send)
            (should (eq popout (window-buffer (selected-window))))
            (should (= (point) (buffer-local-value 'harness-compose-end popout))))
          ;; d on a comment: Ediff at the thread's line.
          (goto-char (point-min))
          (search-forward "Why two?")
          (call-interactively #'change-review-ui-show-in-diff))
        (let ((control (harness-ui-patch-review-test--control review 0)))
          (should (get-buffer-window control))
          (with-current-buffer control (call-interactively #'harness-ui-patch-review-ediff-quit))))
      (ignore two))))

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
          (should (string-search "[Feedback box] e" (harness-ui-patch-review-test--text control)))
          ;; No thread at the difference yet: e is the box.
          (call-interactively #'harness-ui-patch-review-edit-comment))
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
          (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 300)))
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

;;;; Self-contained

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
