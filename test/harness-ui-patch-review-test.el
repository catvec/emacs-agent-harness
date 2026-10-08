;;; harness-ui-patch-review-test.el --- Tests for reviewing a task's changes in its report  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task's branch in a repository of its own: what it changes against
;; its merge base, the changes in the task's report, Ediff file by file
;; from there with the review's keys, the comments quoted from the diff
;; into the report's feedback box, and sending them back to the task in
;; one go.  The repositories are throwaway ones, whose commits are never
;; signed.

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
(defvar harness-compose-start)
(defvar harness-compose-end)
(defvar harness-ui-tasks--tasks)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-report-panel-functions)
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

(defun harness-ui-patch-review-test--put (review text &rest comments)
  "Return TEXT, what a feedback box holds, with COMMENTS put in it.
Each is (PATH WHERE COMMENT), as `harness-ui-patch-review--add-comment'
takes them, for REVIEW's file at PATH."
  (with-temp-buffer
    (insert text)
    (pcase-dolist (`(,path ,where ,comment) comments)
      (harness-ui-patch-review--put-comment
       review (harness-ui-patch-review-test--file review path) where comment))
    (buffer-string)))

(defun harness-ui-patch-review-test--attribution (repo)
  "Return the line before the first quote of task/fix of REPO in the feedback."
  (format "My comments on the diff of your branch task/fix (at %s) against main (merge base %s), each under the lines it is about:"
          (substring (harness-ui-patch-review-test--git repo "rev-parse" "task/fix") 0 7)
          (substring (harness-ui-patch-review-test--git repo "merge-base" "main" "task/fix") 0 7)))

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
        ;; In the diff's order.
        (should (equal '("a.el" "b.el" "d.el" "docs/é.txt" "img.bin" "new.el")
                       (mapcar #'harness-ui-patch-review--f-path files)))
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

;;;; The quote and the comments

(ert-deftest harness-ui-patch-review-parses-the-quote ()
  "The feedback quotes the diff as a mailing list does, and reads back as it:
each line of the quote knows its numbers, across the comments in it."
  (with-temp-buffer
    (insert "General words\n"
            "> diff --git a/x b/x\n> index 1..2 100644\n> --- a/x\n> +++ b/x\n"
            "> @@ -3,3 +3,4 @@ (defun x ()\n>  one\n> -two\n> +deux\n\nA comment\n\n> +trois\n>  three\n"
            "> @@ -10 +11 @@\n> -ten\n> +dix\n> \\ No newline at end of file\n"
            "Another\n")
    (let ((lines (harness-ui-patch-review--parse)))
      (should (equal '(comment quote quote quote quote quote quote quote quote blank comment blank
                               quote quote quote quote quote quote comment)
                     (mapcar (lambda (l) (plist-get l :type)) lines)))
      (should (equal '(nil file header header header hunk context removed added nil nil nil
                           added context hunk removed added other nil)
                     (mapcar (lambda (l) (plist-get l :line)) lines)))
      (should (equal '(nil nil nil nil nil nil 3 4 nil nil nil nil nil 5 nil 10 nil nil nil)
                     (mapcar (lambda (l) (plist-get l :old)) lines)))
      (should (equal '(nil nil nil nil nil nil 3 nil 4 nil nil nil 5 6 nil nil 11 nil nil)
                     (mapcar (lambda (l) (plist-get l :new)) lines)))
      ;; A hunk's header says where it starts, under a name no line has.
      (should (equal '(3 11) (delq nil (mapcar (lambda (l) (plist-get l :new-start)) lines))))
      (should (equal '(nil 0 0 0 0 0 0 0 0 0 0 0 0 0 1 1 1 1 1)
                     (mapcar (lambda (l) (if (plist-get l :file) (or (plist-get l :hunk) 0) nil)) lines)))
      (should (equal '("General words" "A comment" "Another")
                     (mapcar (lambda (l) (plist-get l :text)) (harness-ui-patch-review--comment-blocks lines))))
      (should (equal '(("diff --git a/x b/x" . 2))
                     (harness-ui-patch-review--counts (buffer-string)))))))

(ert-deftest harness-ui-patch-review-comment-text-is-no-quote ()
  "A comment is trimmed and filled, and none of its lines reads as the quote."
  (should (equal " > not a quote" (harness-ui-patch-review--comment-text "  > not a quote\n")))
  (let ((filled (harness-ui-patch-review--comment-text (string-join (make-list 40 "word") " "))))
    (should (> (length (split-string filled "\n")) 1))
    (should (cl-every (lambda (line) (<= (length line) harness-ui-patch-review-fill-column))
                      (split-string filled "\n")))))

(ert-deftest harness-ui-patch-review-reads-the-hunks ()
  "A hunk's lines have their numbers on both sides; a comment's excerpt
is the change it ends, a few lines before it, under a header of its own."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (a (harness-ui-patch-review-test--file review "a.el"))
           (new (harness-ui-patch-review-test--file review "new.el"))
           (hunks (harness-ui-patch-review--hunks a))
           (locate (lambda (side number)
                     (let ((found (harness-ui-patch-review--locate hunks side number)))
                       (list (cl-position (car found) hunks) (nth 1 found) (nth 2 found))))))
      (should (= 2 (length hunks)))
      (should (equal '((?\s "(setq a1 1)" 1 1) (?- "(setq a2 2)" 2 2) (?+ "(setq a2 'two)" 3 2)
                       (?\s "(setq a3 3)" 3 3) (?\s "(setq a4 4)" 4 4) (?\s "(setq a5 5)" 5 5))
                     (plist-get (car hunks) :lines)))
      ;; The line, or the nearest the diff has on that side.
      (should (equal '(1 4 t) (funcall locate :new 18)))
      (should (equal '(1 3 t) (funcall locate :old 18)))
      (should (equal '(1 0 nil) (funcall locate :new 12)))
      (should (equal '(0 5 nil) (funcall locate :new 7)))
      (let ((excerpt (harness-ui-patch-review--excerpt a :new 18 nil)))
        (should (equal (concat "> @@ -15,4 +15,4 @@\n>  (setq a15 15)\n>  (setq a16 16)\n>  (setq a17 17)\n"
                               "> -(setq a18 18)\n> +(setq a18 'eighteen)\n")
                       (plist-get excerpt :text)))
        (should (eql 15 (plist-get excerpt :new-start)))
        (should (plist-get excerpt :exact)))
      ;; Three lines before the line, but not into the middle of a change.
      (let ((excerpt (harness-ui-patch-review--excerpt a :new 7 nil)))
        (should (equal (concat "> @@ -2,4 +2,4 @@\n> -(setq a2 2)\n> +(setq a2 'two)\n"
                               ">  (setq a3 3)\n>  (setq a4 4)\n>  (setq a5 5)\n")
                       (plist-get excerpt :text)))
        (should-not (plist-get excerpt :exact)))
      ;; A side with no line names the line before, as git does.
      (should (equal "> @@ -0,0 +1,2 @@\n> +(setq new1 1)\n> +(setq new2 2)\n"
                     (plist-get (harness-ui-patch-review--excerpt new :new 2 nil) :text)))
      (should-not (harness-ui-patch-review--excerpt (harness-ui-patch-review-test--file review "img.bin") :new 1 nil)))))

(ert-deftest harness-ui-patch-review-comments-go-under-their-lines ()
  "A comment goes into the box under the lines it is about, quoted from the
diff with a few lines before: after the comments there already, on from
a quote that stops short of it, the files and their hunks in the diff's
order.  One on a line the diff does not have goes under the nearest,
saying which; one on a file as a whole under its first line."
  (harness-ui-patch-review-test-with-repo
    (let* ((review (harness-ui-patch-review-test--review repo))
           (text (harness-ui-patch-review-test--put
                  review ""
                  '("a.el" (:new . 18) "Why eighteen?")
                  '("a.el" (:new . 18) "And the tests?")
                  '("a.el" (:new . 12) "Too far")
                  '("b.el" (:old . 3) "Who used b3?")
                  '("new.el" nil "Needs a test")
                  '("a.el" (:new . 2) "Why two?")
                  '("a.el" (:new . 20) "And twenty?")
                  '("d.el" (:new . 6) "Six?")
                  '("a.el" nil "Split this up"))))
      (should (equal (concat (harness-ui-patch-review-test--attribution repo) "\n"
                             "\n"
                             "> diff --git a/a.el b/a.el\n"
                             "\n"
                             "Split this up\n"
                             "\n"
                             "> @@ -1,2 +1,2 @@\n"
                             ">  (setq a1 1)\n"
                             "> -(setq a2 2)\n"
                             "> +(setq a2 'two)\n"
                             "\n"
                             "Why two?\n"
                             "\n"
                             "> @@ -15,4 +15,4 @@\n"
                             ">  (setq a15 15)\n"
                             "\n"
                             "On line 12: Too far\n"
                             "\n"
                             ">  (setq a16 16)\n"
                             ">  (setq a17 17)\n"
                             "> -(setq a18 18)\n"
                             "> +(setq a18 'eighteen)\n"
                             "\n"
                             "Why eighteen?\n"
                             "\n"
                             "And the tests?\n"
                             "\n"
                             ">  (setq a19 19)\n"
                             ">  (setq a20 20)\n"
                             "\n"
                             "And twenty?\n"
                             "\n"
                             "> diff --git a/b.el b/b.el\n"
                             "> @@ -1,3 +0,0 @@\n"
                             "> -(setq b1 1)\n"
                             "> -(setq b2 2)\n"
                             "> -(setq b3 3)\n"
                             "\n"
                             "Who used b3?\n"
                             "\n"
                             "> diff --git a/c.el b/d.el\n"
                             "> @@ -3,4 +3,4 @@\n"
                             ">  (setq c3 3)\n"
                             ">  (setq c4 4)\n"
                             ">  (setq c5 5)\n"
                             "> -(setq c6 6)\n"
                             "> +(setq c6 'six)\n"
                             "\n"
                             "Six?\n"
                             "\n"
                             "> diff --git a/new.el b/new.el\n"
                             "\n"
                             "Needs a test\n")
                     text))
      ;; The quote reads back with its numbers, the comments counted per file.
      (should (equal '(("diff --git a/a.el b/a.el" . 6) ("diff --git a/b.el b/b.el" . 1)
                       ("diff --git a/c.el b/d.el" . 1) ("diff --git a/new.el b/new.el" . 1))
                     (harness-ui-patch-review--counts text)))
      (let ((a20 (cl-find ">  (setq a20 20)" (harness-ui-patch-review--parse-text text)
                          :key (lambda (l) (plist-get l :text)) :test #'equal)))
        (should (equal '(20 20) (list (plist-get a20 :old) (plist-get a20 :new)))))
      ;; Words of one's own first: the quote follows them, said what it is.
      (should (string-prefix-p (concat "Nearly there.\n\n" (harness-ui-patch-review-test--attribution repo)
                                       "\n\n> diff --git a/b.el b/b.el\n> @@ -1,5 +0,0 @@\n")
                               (harness-ui-patch-review-test--put
                                review "Nearly there." '("b.el" (:old . 5) "Who used these?"))))
      ;; Under a line quoted already, a line of the merge base too.
      (should (string-search "> -(setq b3 3)\n\nWho used b3?\n\nAnd b2?\n"
                             (harness-ui-patch-review-test--put review text '("b.el" (:old . 3) "And b2?"))))
      (should (string-search ">  (setq a20 20)\n\nAnd twenty?\n\nOn line 30 of the merge base: Past the end\n\n> diff"
                             (harness-ui-patch-review-test--put review text '("a.el" (:old . 30) "Past the end")))))))

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
  "Pop out the report of task ID as BOARD's [Review] does; return its buffer.
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
        (should (string-match-p (format "^Changes (6)   task/fix against main @ %s   \\+7 −8$" (substring merge-base 0 7))
                                text))
        (should (< (string-match "^Evidence" text) (string-match "^Changes (6)" text)
                   (string-match "Ready for review" text)))
        (should (string-match-p "^    M  a\\.el +\\+2 −2$" text))
        (should (string-match-p "^    D  b\\.el +\\+0 −5$" text))
        (should (string-match-p "^    R  c\\.el → d\\.el +\\+1 −1$" text))
        (should (string-match-p "^    A  docs/é\\.txt +\\+1 −0$" text))
        (should (string-match-p "^    M  img\\.bin +binary$" text))
        (should (string-match-p "^  RET or a click compares a file in Ediff" text))
        (should-not (string-search "keep.el" text)))
      (with-current-buffer popout
        (goto-char (harness-ui-patch-review--row-start id 0))
        (should (eq #'harness-ui-patch-review-ediff (key-binding (kbd "RET"))))
        (should (eq #'harness-ui-patch-review-mouse-ediff
                    (lookup-key (get-text-property (point) 'keymap) [mouse-1])))
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
      (harness-ui-patch-review-test--wait-text popout "^  ✓ M  img\\.bin +binary$")
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

(ert-deftest harness-ui-patch-review-ediff-from-the-report ()
  "RET on a file compares it in Ediff, in the report's frame, with the
review's keys: c comments into the report's box, N goes on to the next
file, q gives the frame back, the report there, its files seen, point
on the next one."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
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
        ;; Ediff has the frame; the report waits, out of sight.
        (should-not (get-buffer-window popout t))
        (should (get-buffer-window control))
        ;; The two versions, named after where they are from, in the file's mode.
        (should (string-prefix-p "a.el (merge base " (buffer-name (nth 1 ediff-buffers))))
        (should (string-prefix-p "a.el (task/fix " (buffer-name (nth 2 ediff-buffers))))
        (should (eq 'emacs-lisp-mode (buffer-local-value 'major-mode (nth 2 ediff-buffers))))
        (should (buffer-local-value 'buffer-read-only (nth 2 ediff-buffers)))
        (with-current-buffer control
          (should (eq #'harness-ui-patch-review-comment (key-binding "c")))
          (should (eq #'harness-ui-patch-review-ediff-next-file (key-binding "N")))
          (should (eq #'harness-ui-patch-review-ediff-previous-file (key-binding "P")))
          (should (eq #'harness-ui-patch-review-ediff-quit (key-binding "q")))
          ;; Ediff's own keys are still there.
          (should (eq 'ediff-next-difference (key-binding "n")))
          (should (eq ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help))
          (should (string-search "[Back to the report] q" (harness-ui-patch-review-test--text control)))
          ;; On the first difference: line 2 on the branch.
          (should (= 0 ediff-current-difference))
          (should (= 2 ediff-number-of-differences))
          (should (equal '(:new . 2) (harness-ui-patch-review--ediff-position)))
          (cl-letf (((symbol-function 'read-string) (lambda (p &rest _) (setq prompt p) "Why two?")))
            (call-interactively #'harness-ui-patch-review-comment))
          (should (equal "Comment on a.el, line 2: " prompt))
          (call-interactively #'harness-ui-patch-review-ediff-next-file)))
      ;; The comment is in the report's box, under its lines.
      (with-current-buffer popout
        (should (equal (concat (harness-ui-patch-review-test--attribution repo) "\n\n"
                               "> diff --git a/a.el b/a.el\n> @@ -1,2 +1,2 @@\n>  (setq a1 1)\n"
                               "> -(setq a2 2)\n> +(setq a2 'two)\n\nWhy two?\n")
                       (harness-compose-text))))
      ;; N: on to b.el, deleted on the branch, without the report between.
      (let ((control (harness-ui-patch-review-test--control review 1)))
        (setq ediff-buffers (append (harness-ui-patch-review--ediff-buffers review) ediff-buffers))
        (should-not (get-buffer-window popout t))
        (with-current-buffer control
          (should (= 1 ediff-number-of-differences))
          (should (equal '(:old . 5) (harness-ui-patch-review--ediff-position)))
          (let ((answers (list "Who used these?" "And where did they go?"))
                said)
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                      ((symbol-function 'message) (lambda (&rest args) (setq said (apply #'format args)))))
              (call-interactively #'harness-ui-patch-review-comment)
              (call-interactively #'harness-ui-patch-review-comment))
            (should (equal "In the report's box: 2 comments on b.el; C-c C-c there sends the feedback" said)))
          (call-interactively #'harness-ui-patch-review-ediff-quit))
        (should-not (buffer-live-p control)))
      ;; q: the frame as it was, the report in its window, selected.
      (should-not (harness-ui-patch-review--r-ediff review))
      (should (equal layout (harness-ui-patch-review-test--layout)))
      (should (eq popout (window-buffer (selected-window))))
      ;; The versions and the control panels went.
      (should (= 6 (length ediff-buffers)))
      (should-not (cl-some #'buffer-live-p ediff-buffers))
      (with-current-buffer popout
        ;; Point on the next file, the files seen, the comments counted.
        (should (eql 2 (cdr (harness-ui-patch-review--at-point))))
        (should (eql (point) (window-point (selected-window))))
        (let ((text (harness-ui-patch-review-test--text popout)))
          (should (string-match-p "^  ✓ M  a\\.el .*   1 comment$" text))
          (should (string-match-p "^  ✓ D  b\\.el .*   2 comments$" text))
          (should (string-match-p "^    R  c\\.el → d\\.el +\\+1 −1$" text))
          (should (string-match-p "^Changes (6) .*   3 comments$" text)))
        (should (string-search "> diff --git a/b.el b/b.el\n> @@ -1,5 +0,0 @@\n" (harness-compose-text)))
        (should (string-suffix-p "> -(setq b5 5)\n\nWho used these?\n\nAnd where did they go?\n"
                                 (harness-compose-text))))
      ;; The review stays, for Ediff again.
      (should (eq review (gethash id harness-ui-patch-review--reviews))))))

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

(ert-deftest harness-ui-patch-review-sends-the-feedback-in-one-go ()
  "The box holds the comments with the words typed around them, counted as
they change; C-c C-c sends it all back to the task as its feedback.  A
comment made with the report closed opens it again, out of sight."
  (harness-ui-patch-review-test-with-task
    (let* ((popout (harness-ui-patch-review-test--changes board id))
           (review (gethash id harness-ui-patch-review--reviews))
           (a (harness-ui-patch-review-test--file review "a.el")))
      (with-current-buffer popout
        (goto-char harness-compose-end)
        (insert "Nearly there."))
      (harness-ui-patch-review--add-comment review a '(:new . 18) "Why eighteen?")
      (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el .*   1 comment$")
      ;; A comment typed in the box counts too, once the typing stops.
      (with-current-buffer popout
        (goto-char harness-compose-end)
        (insert "\nAnd the tests?\n"))
      (harness-ui-patch-review-test--wait-text popout "^    M  a\\.el .*   2 comments$")
      ;; Closed, the report keeps the box as a draft; a comment opens it again.
      (kill-buffer popout)
      (let ((windows (window-list)))
        (harness-ui-patch-review--add-comment review (harness-ui-patch-review-test--file review "new.el")
                                              nil "Needs a test")
        (setq popout (harness-ui-popout-buffer (list 'report id)))
        (should (buffer-live-p popout))
        (should-not (get-buffer-window popout t))
        (should (equal windows (window-list))))
      (setq popout (harness-ui-patch-review-test--report board id))
      (with-current-buffer popout
        (should (string-suffix-p "> diff --git a/new.el b/new.el\n\nNeeds a test\n" (harness-compose-text)))
        (goto-char harness-compose-end)
        (call-interactively (key-binding (kbd "C-c C-c"))))
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :feedback))
                         10 "the feedback to reach the task")
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
        (should (string-prefix-p (concat "Nearly there.\n\n" (harness-ui-patch-review-test--attribution repo)
                                         "\n\n> diff --git a/a.el b/a.el\n> @@ -15,4 +15,4 @@\n")
                                 feedback))
        (should (string-search "> +(setq a18 'eighteen)\n\nWhy eighteen?\n\nAnd the tests?\n\n> diff --git a/new.el" feedback))
        (should (string-suffix-p "> diff --git a/new.el b/new.el\n\nNeeds a test" feedback))
        (should-not (string-search "(setq a2 'two)" feedback))
        (should-not (string-search "b.el" feedback))))))

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
