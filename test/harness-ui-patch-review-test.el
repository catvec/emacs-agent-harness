;;; harness-ui-patch-review-test.el --- Tests for reviewing a task's changes as a patch  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task's branch in a repository of its own: what it changes against
;; its merge base, the list of its files, Ediff file by file with the
;; review's keys, the reply that quotes the diff with comments inline,
;; and sending the comments back to the task as its feedback.  The
;; repositories are throwaway ones, whose commits are never signed.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui)
(require 'harness-ui-patch-review)

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
(defvar harness-compose-end)
(defvar harness-chat--loading)
(defvar harness-ui-tasks--tasks)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-review-minor-mode-map)
(defvar harness-ui-review-button-functions)
(defvar harness-ui-tasks-card-button-functions)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-ui-tasks-submit "harness-ui-tasks")
(declare-function harness-ui-tasks-refresh "harness-ui-tasks")
(declare-function harness-ui-tasks--render "harness-ui-tasks")
(declare-function harness-ui-tasks--find-button "harness-ui-tasks")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-ui-review--redraw "harness-ui-review")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-acp--normalise "harness-acp")

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
  (let ((review (harness-ui-patch-review--review-create
                 :id "t-patch" :task (harness-ui-patch-review-test--task repo))))
    (harness-test-await (harness-ui-patch-review--load review))
    (should-not (harness-ui-patch-review--r-error review))
    review))

(defun harness-ui-patch-review-test--file (review path)
  "Return the file of REVIEW at PATH."
  (or (cl-find path (harness-ui-patch-review--r-files review)
               :key #'harness-ui-patch-review--f-path :test #'equal)
      (error "No %s in the review" path)))

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
         (progn ,@body)
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
        (should (equal '("a.el" "b.el" "d.el" "docs/é.txt" "img.bin" "new.el")
                       (sort (mapcar #'harness-ui-patch-review--f-path files) #'string<)))
        (pcase-dolist (`(,path ,status ,old-path ,added ,deleted ,binary)
                       '(("a.el" "M" nil 2 2 nil) ("b.el" "D" nil 0 5 nil) ("d.el" "R" "c.el" 1 1 nil)
                         ("docs/é.txt" "A" nil 1 0 nil) ("new.el" "A" nil 3 0 nil) ("img.bin" "M" nil 0 0 t)))
          (let ((file (cl-find path files :key #'harness-ui-patch-review--f-path :test #'equal)))
            (ert-info ((format "%s" path))
              (should (equal status (harness-ui-patch-review--f-status file)))
              (should (equal old-path (harness-ui-patch-review--f-old-path file)))
              (should (= added (harness-ui-patch-review--f-added file)))
              (should (= deleted (harness-ui-patch-review--f-deleted file)))
              (should (eq binary (harness-ui-patch-review--f-binary file)))
              ;; Each file has its own part of the diff.
              (should (string-prefix-p (format "diff --git a/%s b/%s\n" (or old-path path) path)
                                       (harness-ui-patch-review--f-patch file))))))
        ;; No blob for the side a file is not on.
        (let ((deleted (cl-find "b.el" files :key #'harness-ui-patch-review--f-path :test #'equal))
              (added (cl-find "new.el" files :key #'harness-ui-patch-review--f-path :test #'equal)))
          (should (harness-ui-patch-review--f-old-blob deleted))
          (should-not (harness-ui-patch-review--f-new-blob deleted))
          (should-not (harness-ui-patch-review--f-old-blob added))
          (should (equal "(setq new1 1)\n(setq new2 2)\n(setq new3 3)\n"
                         (harness-test-await (harness-ui-patch-review--blob
                                              (harness-ui-patch-review--review-create :dir repo)
                                              (harness-ui-patch-review--f-new-blob added))))))))
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
    ;; A review that cannot read its branch shows why, and g tries again.
    (let ((review (harness-ui-patch-review--review-create
                   :id "t-patch" :task (harness-ui-patch-review-test--task repo :branch "task/nope"))))
      (harness-test-await (harness-ui-patch-review--load review))
      (should (string-match-p "There is no branch" (harness-ui-patch-review--r-error review)))
      (should-not (harness-ui-patch-review--r-loading review)))))

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
        (should (stringp (harness-ui-patch-review--why-not other)))
        (should-not (harness-ui-patch-review--banner-button other))
        (should-not (harness-ui-patch-review--card-button other)))
      ;; A harness on another machine: its repositories are not here.
      (let ((harness-ui-connection-address "elsewhere:7777"))
        (should-not (harness-ui-patch-review--offered-p task))
        (should (string-match-p "elsewhere:7777" (harness-ui-patch-review--why-not task)))
        (should-error (harness-ui-patch-review task) :type 'user-error))
      (should (equal (list "[Changes]" #'harness-ui-patch-review harness-ui-patch-review--button-help)
                     (harness-ui-patch-review--banner-button task))))))

;;;; The reply

(ert-deftest harness-ui-patch-review-quotes-and-parses-the-diff ()
  "The reply quotes the diff as a mailing list does, and reads back as it."
  (should (equal "> a\n>\n> b\n" (harness-ui-patch-review--quote "a\n\nb\n")))
  (should (equal "" (harness-ui-patch-review--quote "")))
  (with-temp-buffer
    (insert "General words\n"
            (harness-ui-patch-review--quote
             (concat "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n"
                     "@@ -3,3 +3,4 @@ (defun x ()\n one\n-two\n+deux\n+trois\n three\n"
                     "@@ -10 +11 @@\n-ten\n+dix\n\\ No newline at end of file\n"))
            "A comment\n")
    (let ((lines (harness-ui-patch-review--parse)))
      (should (equal '(comment quote quote quote quote quote quote quote quote quote quote quote quote quote quote comment)
                     (mapcar (lambda (l) (plist-get l :type)) lines)))
      (should (equal '(nil header header header header hunk context removed added added context hunk removed added other nil)
                     (mapcar (lambda (l) (plist-get l :line)) lines)))
      (should (equal '(nil nil nil nil nil nil 3 4 nil nil 5 nil 10 nil nil nil)
                     (mapcar (lambda (l) (plist-get l :old)) lines)))
      (should (equal '(nil nil nil nil nil nil 3 nil 4 5 6 nil nil 11 nil nil)
                     (mapcar (lambda (l) (plist-get l :new)) lines)))
      (should (equal '(nil 0 0 0 0 0 0 0 0 0 0 1 1 1 1 1)
                     (mapcar (lambda (l) (if (plist-get l :file) (or (plist-get l :hunk) 0) nil)) lines)))
      (should (equal '("General words" "A comment")
                     (mapcar (lambda (l) (plist-get l :text)) (harness-ui-patch-review--comment-blocks lines)))))))

(ert-deftest harness-ui-patch-review-comment-text-is-no-quote ()
  "A comment is trimmed and filled, and none of its lines reads as the quote."
  (should (equal " > not a quote" (harness-ui-patch-review--comment-text "  > not a quote\n")))
  (let ((filled (harness-ui-patch-review--comment-text (string-join (make-list 40 "word") " "))))
    (should (> (length (split-string filled "\n")) 1))
    (should (cl-every (lambda (line) (<= (length line) harness-ui-patch-review-fill-column))
                      (split-string filled "\n")))))

(ert-deftest harness-ui-patch-review-comments-go-under-their-lines ()
  "A comment goes under the line it is about, after those there before;
one on a line the quote does not show goes under the nearest, saying which."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (a (harness-ui-patch-review-test--file review "a.el"))
           (b (harness-ui-patch-review-test--file review "b.el"))
           (new (harness-ui-patch-review-test--file review "new.el")))
      (harness-ui-patch-review--add-comment review a '(:new . 18) "Why eighteen?")
      (harness-ui-patch-review--add-comment review a '(:new . 18) "And the tests?")
      (harness-ui-patch-review--add-comment review a '(:new . 12) "Too far")
      (harness-ui-patch-review--add-comment review b '(:old . 3) "Who used b3?")
      (harness-ui-patch-review--add-comment review new nil "Needs a test")
      (let ((reply (harness-ui-patch-review--r-reply review)))
        (should (buffer-live-p reply))
        (with-current-buffer reply
          (should (eq major-mode 'harness-ui-patch-review-reply-mode))
          (let ((text (harness-ui-patch-review-test--text reply)))
            (should (string-search "> +(setq a18 'eighteen)\n\nWhy eighteen?\n\nAnd the tests?\n\n>  (setq a19 19)\n" text))
            (should (string-search ">  (setq a15 15)\n\nOn line 12: Too far\n\n>  (setq a16 16)\n" text))
            (should (string-search "> -(setq b3 3)\n\nWho used b3?\n\n> -(setq b4 4)\n" text))
            (should (string-search "> +++ b/new.el\n\nNeeds a test\n\n> @@ " text)))
          ;; The comment on the change as a whole, above the quote: the
          ;; reply starts with a line for it.
          (should (string-prefix-p "\n\n> diff --git " (harness-ui-patch-review-test--text reply)))
          (goto-char (point-min))
          (insert "Nearly there."))
        (should (equal '(("diff --git a/a.el b/a.el" . 3) ("diff --git a/b.el b/b.el" . 1)
                         ("diff --git a/new.el b/new.el" . 1) (nil . 1))
                       (sort (harness-ui-patch-review--comment-counts review)
                             (lambda (x y) (string< (or (car x) "~") (or (car y) "~"))))))
        ;; What goes: the comments, with only the hunks they answer.
        (let ((out (harness-ui-patch-review--outgoing (with-current-buffer reply (harness-ui-patch-review--parse)))))
          (should (string-prefix-p "Nearly there.\n\n> diff --git a/a.el b/a.el\n" out))
          (should (string-search "> +(setq a18 'eighteen)\n\nWhy eighteen?" out))
          (should-not (string-search "(setq a2 'two)" out))
          (should (string-search "> diff --git a/b.el b/b.el" out))
          ;; new.el's header, for the comment on it, but not its lines.
          (should (string-search "> +++ b/new.el\n\nNeeds a test" out))
          (should-not (string-search "(setq new1 1)" out))
          (should-not (string-search "d.el" out))
          (should-not (string-search "img.bin" out))
          (should-not (string-match-p "\n\n\n" out))
          (should (string-search "Who used b3?\n\n> -(setq b4 4)\n> -(setq b5 5)\n> diff --git a/new.el" out))
          (should (string-suffix-p "> +++ b/new.el\n\nNeeds a test" out)))
        ;; Without a comment there is nothing to send.
        (with-temp-buffer
          (insert (harness-ui-patch-review--quote (harness-ui-patch-review--f-patch a)))
          (should-not (harness-ui-patch-review--outgoing (harness-ui-patch-review--parse))))))))

(ert-deftest harness-ui-patch-review-reply-follows-the-branch-until-commented ()
  "A reply with no comment quotes the branch as it is now; one with comments keeps its quote."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (reply (harness-ui-patch-review--reply-buffer review)))
      (should (equal (harness-ui-patch-review--r-tip review) (harness-ui-patch-review--r-reply-tip review)))
      (harness-ui-patch-review-test--git repo "checkout" "-q" "task/fix")
      (harness-ui-patch-review-test--write repo "new.el" "(setq new1 'one)\n")
      (harness-ui-patch-review-test--git repo "commit" "-q" "-am" "More")
      (harness-test-await (harness-ui-patch-review--load review))
      (should (string-search "> +(setq new1 'one)" (harness-ui-patch-review-test--text reply)))
      (should (equal (harness-ui-patch-review--r-tip review) (harness-ui-patch-review--r-reply-tip review)))
      (harness-ui-patch-review--add-comment review (harness-ui-patch-review-test--file review "new.el")
                                            '(:new . 1) "One what?")
      (let ((quoted (harness-ui-patch-review--r-tip review)))
        (harness-ui-patch-review-test--write repo "new.el" "(setq new1 'uno)\n")
        (harness-ui-patch-review-test--git repo "commit" "-q" "-am" "Again")
        (harness-test-await (harness-ui-patch-review--load review))
        (should (string-search "One what?" (harness-ui-patch-review-test--text reply)))
        (should-not (string-search "'uno" (harness-ui-patch-review-test--text reply)))
        (should-not (equal (harness-ui-patch-review--r-tip review) (harness-ui-patch-review--r-reply-tip review)))
        ;; The list says the reply quotes an older branch.
        (should (cl-some (lambda (note) (string-match-p "The reply quotes the branch at" note))
                         (harness-ui-patch-review--notes review)))
        ;; What is sent names the commit it quotes, not the branch's tip.
        (let ((preface (harness-ui-patch-review--preface review)))
          (should (string-search (format "task/fix (at %s)" (substring quoted 0 7)) preface))
          (should-not (string-search (substring (harness-ui-patch-review--r-tip review) 0 7) preface)))))))

;;;; The list and Ediff

(defun harness-ui-patch-review-test--open (task)
  "Open the review of TASK's changes; return the review once its branch is read."
  (harness-ui-patch-review task)
  (let ((review (gethash (plist-get task :id) harness-ui-patch-review--reviews)))
    (harness-test-wait (lambda () (and (harness-ui-patch-review--r-tip review)
                                       (not (harness-ui-patch-review--r-loading review))))
                       10 "the branch to be read")
    review))

(defun harness-ui-patch-review-test--control (review index)
  "Wait for the Ediff of REVIEW's file at INDEX; return its control buffer."
  (harness-test-wait (lambda ()
                       (let ((state (harness-ui-patch-review--r-ediff review)))
                         (and (eql index (plist-get state :index))
                              (buffer-live-p (plist-get state :control))
                              (plist-get state :control))))
                     10 (format "the Ediff of file %d" index)))

(ert-deftest harness-ui-patch-review-list-shows-the-files ()
  "The list says what is compared and has a row per file, what changed in it."
  (harness-ui-patch-review-test-with-repo
    (delete-other-windows)
    (let* ((review (harness-ui-patch-review-test--open (harness-ui-patch-review-test--task repo)))
           (list (harness-ui-patch-review--r-list review))
           (text (harness-ui-patch-review-test--text list))
           (merge-base (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix")))
      (should (eq list (window-buffer (selected-window))))
      (should (one-window-p))
      (with-current-buffer list
        (should (eq major-mode 'harness-ui-patch-review-list-mode))
        (should (string-match-p "Changes: Fix the flaky test" (format "%s" header-line-format)))
        (should (eq #'harness-ui-patch-review-ediff (key-binding (kbd "RET"))))
        (should (eq #'harness-ui-patch-review-send (key-binding (kbd "C-c C-c"))))
        ;; Point is on the first file.
        (should (eql 0 (harness-ui-patch-review--index-at-point))))
      (should (string-search (format "task/fix against main @ %s   6 files  +7 −8" (substring merge-base 0 7)) text))
      (should (string-match-p "^   M  a\\.el +\\+2 −2$" text))
      (should (string-match-p "^   D  b\\.el +\\+0 −5$" text))
      (should (string-match-p "^   R  c\\.el → d\\.el +\\+1 −1$" text))
      (should (string-match-p "^   M  img\\.bin +binary$" text))
      (should (string-match-p "^   A  docs/é\\.txt +\\+1 −0$" text))
      (should-not (string-search "keep.el" text))
      ;; n and p move between the files.
      (with-current-buffer list
        (harness-ui-patch-review-next-file)
        (should (eql 1 (harness-ui-patch-review--index-at-point)))
        (harness-ui-patch-review-previous-file)
        (should-error (harness-ui-patch-review-previous-file) :type 'user-error)
        ;; A binary file is not for Ediff: RET says so, and it is seen.
        (goto-char (harness-ui-patch-review--row-start
                    (cl-position "img.bin" (harness-ui-patch-review--r-files review)
                                 :key #'harness-ui-patch-review--f-path :test #'equal)))
        (harness-ui-patch-review-ediff)
        (should-not (harness-ui-patch-review--r-ediff review))
        (should (string-match-p "^ ✓ M  img\\.bin" (harness-ui-patch-review-test--text list)))))))

(ert-deftest harness-ui-patch-review-ediff-steps-through-the-files ()
  "RET compares a file in Ediff with the review's keys: c comments, N goes
on to the next file, q comes back to the list as it was."
  (harness-ui-patch-review-test-with-repo
    (delete-other-windows)
    (let* ((start (get-buffer-create "*patch review start*"))
           (_ (switch-to-buffer start))
           (before (current-window-configuration))
           (review (harness-ui-patch-review-test--open (harness-ui-patch-review-test--task repo)))
           (list (harness-ui-patch-review--r-list review))
           (files (harness-ui-patch-review--r-files review))
           (ediff-buffers nil))
      (should (equal "a.el" (harness-ui-patch-review--f-path (nth 0 files))))
      (should (equal "b.el" (harness-ui-patch-review--f-path (nth 1 files))))
      (with-current-buffer list
        (goto-char (harness-ui-patch-review--row-start 0))
        (harness-ui-patch-review-ediff))
      (let ((control (harness-ui-patch-review-test--control review 0))
            prompt)
        (setq ediff-buffers (append (cl-loop for key in '(:a :b :control)
                                             collect (plist-get (harness-ui-patch-review--r-ediff review) key))
                                    ediff-buffers))
        ;; The two versions, named after where they are from, in the file's mode.
        (should (string-prefix-p "a.el (merge base " (buffer-name (nth 0 ediff-buffers))))
        (should (string-prefix-p "a.el (task/fix " (buffer-name (nth 1 ediff-buffers))))
        (should (eq 'emacs-lisp-mode (buffer-local-value 'major-mode (nth 1 ediff-buffers))))
        (should (buffer-local-value 'buffer-read-only (nth 1 ediff-buffers)))
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-comment (key-binding "c")))
          (should (eq #'harness-ui-patch-review-ediff-next-file (key-binding "N")))
          (should (eq #'harness-ui-patch-review-ediff-previous-file (key-binding "P")))
          (should (eq #'harness-ui-patch-review-ediff-quit (key-binding "q")))
          ;; Ediff's own keys are still there.
          (should (eq 'ediff-next-difference (key-binding "n")))
          (should (eq ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help))
          (should (string-search "[Comment] c" (harness-ui-patch-review-test--text control)))
          ;; On the first difference: line 2 on the branch.
          (should (= 0 ediff-current-difference))
          (should (= 2 ediff-number-of-differences))
          (should (equal '(:new . 2) (harness-ui-patch-review--ediff-position)))
          (cl-letf (((symbol-function 'read-string) (lambda (p &rest _) (setq prompt p) "Why two?")))
            (call-interactively #'harness-ui-patch-review-comment))
          (should (equal "Comment on a.el, line 2: " prompt))
          (call-interactively #'harness-ui-patch-review-ediff-next-file)))
      (should (string-search "> +(setq a2 'two)\n\nWhy two?\n\n"
                             (harness-ui-patch-review-test--text (harness-ui-patch-review--r-reply review))))
      ;; N: on to b.el, deleted on the branch.
      (let ((control (harness-ui-patch-review-test--control review 1)))
        (setq ediff-buffers (append (cl-loop for key in '(:a :b :control)
                                             collect (plist-get (harness-ui-patch-review--r-ediff review) key))
                                    ediff-buffers))
        (with-current-buffer control
          (should (= 1 ediff-number-of-differences))
          (should (equal '(:old . 5) (harness-ui-patch-review--ediff-position)))
          (call-interactively #'harness-ui-patch-review-ediff-quit))
        (should-not (buffer-live-p control)))
      ;; q: back to the list as it was, the two files seen, point on the next.
      (should-not (harness-ui-patch-review--r-ediff review))
      (should (eq list (window-buffer (selected-window))))
      (should (one-window-p))
      ;; The versions and the control panels went with them.
      (should (= 6 (length ediff-buffers)))
      (should-not (cl-some #'buffer-live-p ediff-buffers))
      (with-current-buffer list
        (should (eql 2 (harness-ui-patch-review--index-at-point)))
        (let ((text (harness-ui-patch-review-test--text list)))
          (should (string-match-p "^ ✓ M  a\\.el .*   1 comment$" text))
          (should (string-match-p "^ ✓ D  b\\.el" text))
          (should (string-match-p "^   R  c\\.el → d\\.el" text))
          (should (string-match-p "1 comment$" (car (split-string text "\n"))))))
      ;; q in the list gives the windows back as they were.
      (with-current-buffer list (harness-ui-patch-review-quit))
      (should (eq start (window-buffer (selected-window))))
      (should (window-configuration-equal-p before (current-window-configuration)))
      ;; The review stays, comments and all, for [Changes] again.
      (should (eq review (gethash "t-patch" harness-ui-patch-review--reviews)))
      (should (buffer-live-p (harness-ui-patch-review--r-reply review)))
      (kill-buffer start))))

(ert-deftest harness-ui-patch-review-ends-in-ediff ()
  "A review that ends during Ediff ends the Ediff too: the frame gets its
windows back when Ediff shows, and keeps them when it is out of sight."
  (harness-ui-patch-review-test-with-repo
    (delete-other-windows)
    (let* ((start (get-buffer-create "*patch review start*"))
           (_ (switch-to-buffer start))
           (before (current-window-configuration))
           (task (harness-ui-patch-review-test--task repo))
           (review (harness-ui-patch-review-test--open task)))
      (with-current-buffer (harness-ui-patch-review--r-list review)
        (harness-ui-patch-review-ediff 0))
      (harness-ui-patch-review-test--control review 0)
      (let ((buffers (cons (harness-ui-patch-review--r-list review)
                           (harness-ui-patch-review--ediff-buffers review))))
        ;; Deleted while Ediff shows: the review stays, and says so.
        (harness-ui-patch-review--on-event "task/deleted" (list "t-patch"))
        (should (equal "deleted" (harness-ui-patch-review--r-gone review)))
        (should (cl-every #'buffer-live-p buffers))
        ;; Ending it ends the Ediff, and the frame is as it was.
        (harness-ui-patch-review--forget review)
        (should-not (cl-some #'buffer-live-p buffers))
        (should (eq start (window-buffer (selected-window))))
        (should (window-configuration-equal-p before (current-window-configuration)))
        (should-not (gethash "t-patch" harness-ui-patch-review--reviews)))
      ;; Out of sight, the Ediff ends without touching the windows.
      (setq review (harness-ui-patch-review-test--open task))
      (with-current-buffer (harness-ui-patch-review--r-list review)
        (harness-ui-patch-review-ediff 2))
      (harness-ui-patch-review-test--control review 2)
      (let ((buffers (cons (harness-ui-patch-review--r-list review)
                           (harness-ui-patch-review--ediff-buffers review)))
            (other (get-buffer-create "*patch review elsewhere*")))
        (let ((ignore-window-parameters t)) (delete-other-windows))
        (set-window-dedicated-p (selected-window) nil)
        (set-window-buffer (selected-window) other)
        (let ((elsewhere (current-window-configuration)))
          (harness-ui-patch-review--on-event "task/done" (list (append '(:state "done") task)))
          (should-not (cl-some #'buffer-live-p buffers))
          (should (eq other (window-buffer (selected-window))))
          (should (window-configuration-equal-p elsewhere (current-window-configuration))))
        (should-not (gethash "t-patch" harness-ui-patch-review--reviews))
        (kill-buffer other))
      (kill-buffer start))))

(ert-deftest harness-ui-patch-review-reply-shows-beside-the-list ()
  "r shows the reply beside the list, C-c C-k hides it again."
  (harness-ui-patch-review-test-with-repo
    (delete-other-windows)
    (let* ((review (harness-ui-patch-review-test--open (harness-ui-patch-review-test--task repo)))
           (list (harness-ui-patch-review--r-list review)))
      (with-current-buffer list (harness-ui-patch-review-reply))
      (let ((reply (harness-ui-patch-review--r-reply review)))
        (should (eq reply (window-buffer (selected-window))))
        (should (get-buffer-window list))
        (should (= 2 (length (window-list))))
        (with-current-buffer reply
          (should (eq #'harness-ui-patch-review-send (key-binding (kbd "C-c C-c"))))
          (should (string-match-p "Reply: Fix the flaky test" (format "%s" header-line-format)))
          (should (string-match-p "0 comments" (format "%s" header-line-format)))
          ;; Nothing to send yet.
          (should-error (harness-ui-patch-review-send) :type 'user-error)
          (harness-ui-patch-review-hide-reply))
        (should (eq list (window-buffer (selected-window))))
        (should (one-window-p))
        (should (buffer-live-p reply))))))

;;;; With the harness: the banner, the board, and sending

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
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override
            '((:type text :delta "All done.\n")
              (:type tool-call :id "h1" :name "hand_in"
                     :input (:summary "Done: the flaky test is fixed." :evidence ("a note")))))
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
             (delete-other-windows)
             (dolist (b (buffer-list))
               (when (memq (buffer-local-value 'major-mode b)
                           '(harness-ui-popout-mode harness-chat-mode harness-ui-tasks-mode))
                 (ignore-errors (kill-buffer b))))
             (dolist (c (copy-sequence harness-acp--clients))
               (harness-acp--drop-client c))))))))

(defun harness-ui-patch-review-test--open-session (sid)
  "Open SID's chat buffer in the selected window and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (delete-other-windows)
    (set-window-buffer (selected-window) buffer)
    (harness-test-wait (lambda () (not (buffer-local-value 'harness-chat--loading buffer))) 5 "the session to load")
    buffer))

(defun harness-ui-patch-review-test--wait-text (buffer regexp &optional absent)
  "Wait until BUFFER's text matches REGEXP, or with ABSENT no longer does."
  (harness-test-wait (lambda () (let ((found (string-match-p regexp (harness-ui-patch-review-test--text buffer))))
                                  (if absent (not found) found)))
                     5 (format "the buffer %s %s" (if absent "to lose" "to show") regexp)))

(ert-deftest harness-ui-patch-review-banner-and-card-offer-the-changes ()
  "[Changes] shows on the banner of a task in review with a branch, C-c C-d
its key, and on its card; neither once the module is off."
  (harness-ui-patch-review-test-with-task
    (let ((chat (harness-ui-patch-review-test--open-session sid)))
      (harness-ui-patch-review-test--wait-text chat "Ready for review")
      ;; Worked in the main checkout, the task has no branch to look at.
      (should-not (string-search "[Changes]" (harness-ui-patch-review-test--text chat)))
      (harness-tasks--set id :branch "task/fix" :base "main")
      (harness-ui-patch-review-test--wait-text chat "\\[Changes\\]  C-c C-d")
      (with-current-buffer chat
        (should (eq #'harness-ui-patch-review (key-binding (kbd "C-c C-d"))))
        (should (member '("C-c C-d" "Changes, file by file" harness-ui-patch-review)
                        (append (nth 1 (get 'harness-ui-review-minor-mode 'harness-menu-group)) nil)))
        ;; The key opens the list in the session's window; q comes back.
        (call-interactively (key-binding (kbd "C-c C-d"))))
      (let ((review (gethash id harness-ui-patch-review--reviews)))
        (should review)
        (should (eq (harness-ui-patch-review--r-list review) (window-buffer (selected-window))))
        (harness-test-wait (lambda () (harness-ui-patch-review--r-files review)) 10 "the branch to be read")
        (with-current-buffer (harness-ui-patch-review--r-list review) (harness-ui-patch-review-quit))
        (should (eq chat (window-buffer (selected-window)))))
      ;; The card has it too.
      (with-current-buffer board (harness-ui-tasks-refresh))
      (harness-ui-patch-review-test--wait-text board "\\[Changes\\]")
      (with-current-buffer board
        (let ((button (harness-ui-tasks--find-button "[Changes]" (point-min) (point-max))))
          (should button)
          (should (equal harness-ui-patch-review--button-help
                         (get-text-property (nth 1 button) 'help-echo)))))
      ;; Off, the module takes all of it back.
      (harness-module-disable 'ui-patch-review)
      (should-not (memq #'harness-ui-patch-review--banner-button harness-ui-review-button-functions))
      (should-not (memq #'harness-ui-patch-review--card-button harness-ui-tasks-card-button-functions))
      (should-not (lookup-key harness-ui-review-minor-mode-map (kbd "C-c C-d")))
      (should-not (member '("C-c C-d" "Changes, file by file" harness-ui-patch-review)
                          (append (nth 1 (get 'harness-ui-review-minor-mode 'harness-menu-group)) nil)))
      (harness-ui-review--redraw sid)
      (harness-ui-patch-review-test--wait-text chat "\\[Changes\\]" t)
      (with-current-buffer board (harness-ui-tasks--render t))
      (harness-ui-patch-review-test--wait-text board "\\[Changes\\]" t))))

(ert-deftest harness-ui-patch-review-sends-the-comments-back ()
  "C-c C-c sends the comments back to the task as its feedback, in one go:
the commented hunks quoted, a line first that says how to read them."
  (harness-ui-patch-review-test-with-task
    (harness-tasks--set id :branch "task/fix" :base "main")
    (let* ((task (harness-acp--normalise (harness-call 'task/get id)))
           (review (progn (delete-other-windows)
                          (harness-ui-patch-review-test--open task)))
           (a (harness-ui-patch-review-test--file review "a.el")))
      (harness-ui-patch-review--add-comment review a '(:new . 18) "Why eighteen?")
      (with-current-buffer (harness-ui-patch-review--r-reply review)
        (goto-char (point-min))
        (insert "Nearly there.")
        (harness-ui-patch-review-send))
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :feedback))
                         10 "the feedback to reach the task")
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
        (should (string-prefix-p "My review of your changes follows, as a reply to a patch on a mailing list." feedback))
        (should (string-search "your branch task/fix" feedback))
        (should (string-search "\n\nNearly there.\n\n> diff --git a/a.el b/a.el\n" feedback))
        (should (string-search "> +(setq a18 'eighteen)\n\nWhy eighteen?" feedback))
        (should-not (string-search "(setq a2 'two)" feedback))
        (should-not (string-search "b.el" feedback)))
      ;; The review is over: its buffers gone, the windows given back.
      (harness-test-wait (lambda () (not (gethash id harness-ui-patch-review--reviews))) 5 "the review to end")
      (should-not (buffer-live-p (harness-ui-patch-review--r-list review)))
      (should-not (buffer-live-p (harness-ui-patch-review--r-reply review))))))

;;;; Self-contained

(ert-deftest harness-ui-patch-review-is-unknown-to-the-rest ()
  "No other file of the harness names the module: it could leave as a package."
  (let ((default-directory harness-test-root))
    (dolist (file (append (list "harness.el")
                          (directory-files "lisp" t "\\.el\\'")
                          (directory-files "lisp/modules" t "\\.el\\'")
                          (directory-files "lisp/ui" t "\\.el\\'")))
      (unless (string-match-p "harness-ui-patch-review\\.el\\'" file)
        (with-temp-buffer
          (insert-file-contents file)
          (ert-info ((format "%s" file))
            (should-not (search-forward "patch-review" nil t))))))))

(provide 'harness-ui-patch-review-test)
;;; harness-ui-patch-review-test.el ends here
