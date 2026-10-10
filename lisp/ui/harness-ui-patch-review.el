;;; harness-ui-patch-review.el --- A task's changes in its report: Ediff, and comments quoted in the feedback  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task waiting for review is a patch waiting for its reviewer.  This
;; module puts the patch in the review, in the task's report (the popout
;; [Review] opens on the board and in the session), and reviews it the
;; way a mailing list does: file by file in Ediff, with comments under
;; the lines they are about, quoted from the diff, sent back to the task
;; as its feedback in one go.
;;
;; Under the evidence, above the review banner and its box, the report
;; shows what the task's branch changes against its merge base with the
;; branch it was made from -- what merging it brings in, not what that
;; branch did since -- a row per file:
;;
;;   a row       the file's status, its path, the lines it adds and
;;               deletes, a check mark once it was looked at in Ediff,
;;               and the comments on it in the box.  RET or a click
;;               compares the file in Ediff; n and p move between rows.
;;   Ediff       the file at the merge base against the file on the
;;               branch, in the report's frame.  The control panel keeps
;;               Ediff's keys and has four more: c comments on the
;;               current difference, N and P go on to the next or
;;               previous file, q comes back to the report as it was,
;;               point on the next file.
;;   comments    c reads a comment and puts it in the report's box as a
;;               reply on a mailing list has it: the lines it is about
;;               quoted from the diff with "> ", under their file's
;;               `diff --git' line and a hunk header, a few lines of
;;               context first, the comment after them.  The box is the
;;               feedback: edit it, write more, and C-c C-c sends it all
;;               back to the task, as it sends any feedback.
;;
;; Git runs here, in the Emacs that shows the UI, in the task's
;; repository: the changes show where that is a directory of this
;; machine, so not for a harness on another one.
;;
;; The module is self-contained: nothing else knows of it.  It draws in
;; the report through the hook the report has for panels
;; (`harness-ui-report-panel-functions'), writes in the box between the
;; box's own markers, and leaves sending to the review's box.  Disabled
;; (`harness-disabled-modules'), it takes its part of the report out.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-popout)
(require 'harness-ui-report)

(defvar ediff-window-setup-function)
(defvar ediff-brief-help-message-function)
(defvar ediff-mode-map)
(defvar ediff-after-quit-hook-internal)
(defvar ediff-current-difference)
(defvar ediff-number-of-differences)
(defvar ediff-buffer-A)
(defvar ediff-buffer-B)
(defvar ediff-keep-variants)
(defvar evil-local-mode)
(defvar window-restore-killed-buffer-windows)
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function ediff-setup-windows-plain "ediff-wind" (buffer-a buffer-b buffer-c control-buffer))
(declare-function ediff-really-quit "ediff-util" (reverse-default-keep-variants))
(declare-function ediff-get-diff-posn "ediff-util" (buf-type pos &optional n control-buf))
(declare-function ediff-next-difference "ediff-util" (&optional arg))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))

(defgroup harness-ui-patch-review nil
  "A task's changes in its report: Ediff file by file, comments quoted in the feedback."
  :group 'harness-ui)

(defcustom harness-ui-patch-review-ediff-window-setup #'ediff-setup-windows-plain
  "How Ediff lays out its windows while it compares a task's change.
The default keeps the control panel in the frame, under the two
versions; nil leaves it to `ediff-window-setup-function', which on a
graphical display gives the panel a frame of its own.  Whether the two
versions are side by side is Ediff's `ediff-split-window-function'."
  :type '(choice (const :tag "Ediff's own setting" nil) function))

(defcustom harness-ui-patch-review-fill-column 72
  "Width the comments made in Ediff are filled to in the feedback."
  :type 'natnum)

(defcustom harness-ui-patch-review-context-lines 3
  "How many lines before a change the quote above a comment on it starts.
A comment made in Ediff goes into the feedback under the lines it is
about, quoted from the diff: the change, up to the line it ends on,
after this many lines at most."
  :type 'natnum)

(defface harness-ui-patch-review-plus-face '((t :inherit diff-indicator-added))
  "Counts of added lines, and the status of an added file, in a report.")
(defface harness-ui-patch-review-minus-face '((t :inherit diff-indicator-removed))
  "Counts of deleted lines, and the status of a deleted file, in a report.")
(defface harness-ui-patch-review-seen-face '((t :inherit success))
  "The mark of a file seen in Ediff, in a report.")
(defface harness-ui-patch-review-comments-face '((t :inherit bold))
  "The count of comments on a file, in a report.")

;;;; Data

(cl-defstruct (harness-ui-patch-review--file
               (:constructor harness-ui-patch-review--file-create)
               (:conc-name harness-ui-patch-review--f-)
               (:copier nil))
  "A file the branch changes, as `git diff --raw' and its patch show it.
STATUS is git's letter (A, D, M, R, T...), PATH where the file is on
the branch, OLD-PATH where it was for a rename or a copy.  The modes are
git's, the blobs nil for a side the file is not on.  PATCH is the
file's part of the diff, from its `diff --git' line on."
  status path old-path old-mode new-mode old-blob new-blob patch binary (added 0) (deleted 0))

(cl-defstruct (harness-ui-patch-review--review
               (:constructor harness-ui-patch-review--review-create)
               (:conc-name harness-ui-patch-review--r-)
               (:copier nil))
  "The review of a task's changes, which the task's report shows.
ID and TASK are the task's, as last heard.  DIR is the repository the
branch is read in, BRANCH and BASE the branches compared, MERGE-BASE and
TIP the commits, FILES what the diff of the two holds.  SEEN holds the
files seen in Ediff, by `harness-ui-patch-review--seen-key'.  DIRTY is
non-nil when the task's worktree has changes not committed.  LOADING
is non-nil while the branch is read, ERROR what the last reading failed
with.  POPOUT is the report the changes show in, COUNTS the comments
its box held when it was drawn last.  EDIFF is the comparison under
way: a plist of :index, the buffers :a, :b and :control, the :windows
to give back as it ends and the first line :start the report's window
showed.  GONE is non-nil once the task went, done or deleted, while
its Ediff showed."
  id task dir branch base merge-base tip files
  (seen (make-hash-table :test 'equal))
  dirty loading error popout counts ediff gone)

(defvar harness-ui-patch-review--reviews (make-hash-table :test 'equal)
  "Task id -> the review of its changes.")

(defvar-local harness-ui-patch-review--review nil
  "In an Ediff control panel of a review, the review.")

(defvar-local harness-ui-patch-review--index nil
  "In an Ediff control panel of a review, the index of the file it compares.")

(defvar harness-ui-patch-review--active nil
  "Non-nil while the module is on: reports show the changes.")

(defvar harness-ui-patch-review--drawing nil
  "Non-nil while a report draws the changes: nothing draws it again then.")

(defconst harness-ui-patch-review--hunk-regexp
  "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)"
  "A hunk's header in a diff, with its line numbers and its heading.
Its groups: where the hunk starts at the merge base and how many lines
it has there, the same on the branch, and the heading git gives it.")

(defun harness-ui-patch-review--short (sha)
  "Return commit or blob SHA shortened, or \"none\" for nil."
  (cond ((not (stringp sha)) "none")
        ((> (length sha) 7) (substring sha 0 7))
        (t sha)))

(defun harness-ui-patch-review--title (review)
  "Return the title of REVIEW's task, as the board shows it."
  (or (harness-ui-task-title (harness-ui-patch-review--r-task review))
      (harness-ui-patch-review--r-id review)))

(defun harness-ui-patch-review--reviewing-p (task)
  "Non-nil when TASK waits for review, not archived."
  (and task
       (equal (plist-get task :state) "review")
       (not (harness-json-true-p (plist-get task :archived)))))

(defun harness-ui-patch-review--current ()
  "Return the review of this Ediff control panel."
  (or harness-ui-patch-review--review
      (user-error "Not an Ediff of a task's changes")))

(defun harness-ui-patch-review--fail (format-string &rest args)
  "Return a promise rejected with the error FORMAT-STRING and ARGS make."
  (harness-rejected (list 'error (apply #'format-message format-string args))))

(defun harness-ui-patch-review--plural (count word)
  "Return COUNT WORD, WORD in the plural unless COUNT is 1."
  (format "%d %s%s" count word (if (= count 1) "" "s")))

;;;; Where the branch is

(defun harness-ui-patch-review--repository (task)
  "Return the local directory TASK's branch can be read in, or nil.
That is its project, else its worktree, when it is a directory of this
machine: not for a harness elsewhere, and not over TRAMP."
  (unless (stringp harness-ui-connection-address)
    (cl-loop for dir in (list (plist-get task :project) (plist-get task :worktree))
             when (and (stringp dir) (not (string-empty-p dir))
                       (not (file-remote-p dir)) (file-directory-p dir))
             return (file-name-as-directory (expand-file-name dir)))))

(defun harness-ui-patch-review--offered-p (task)
  "Non-nil when TASK waits for review on a branch this Emacs can read."
  (and (harness-ui-patch-review--reviewing-p task)
       (not (harness-string-blank-p (plist-get task :branch)))
       (harness-ui-patch-review--repository task)
       t))

(defun harness-ui-patch-review--why-not (task)
  "Return why TASK's changes cannot be reviewed here."
  (let ((title (if task (harness-ui-task-title task) "This task")))
    (cond ((null task) "No task waits for review here")
          ((not (equal (plist-get task :state) "review")) (format "%s does not wait for review" title))
          ((harness-json-true-p (plist-get task :archived)) (format "%s is archived" title))
          ((harness-string-blank-p (plist-get task :branch))
           (format "%s has no branch of its own: it worked in the main checkout" title))
          ((stringp harness-ui-connection-address)
           (format "The harness runs at %s: the repository of %s is not on this machine"
                   harness-ui-connection-address title))
          (t (format "The repository of %s is not a directory of this machine" title)))))

;;;; Git

(defun harness-ui-patch-review--decode (bytes &optional coding)
  "Return BYTES, as git wrote them, decoded with CODING (default UTF-8)."
  (decode-coding-string (if (multibyte-string-p bytes)
                            (condition-case nil (string-to-unibyte bytes)
                              (error (encode-coding-string bytes 'utf-8)))
                          bytes)
                        (or coding 'utf-8)))

(defun harness-ui-patch-review--git (dir &rest args)
  "Return a promise of what git, run in DIR with ARGS, writes: its bytes.
It rejects with git's message when git fails.  Git takes no optional
lock, so a status does not get in the way of the task's own git."
  (let ((coding-system-for-read 'binary))
    (harness-then
     (harness-run-command (append '("git" "--no-pager" "-c" "core.quotePath=false") args)
                          :cwd dir :timeout 60 :name "harness-patch-review"
                          :env '(("GIT_OPTIONAL_LOCKS" . "0")))
     (lambda (result)
       (if (eql (plist-get result :exit) 0)
           (plist-get result :stdout)
         (let ((err (string-trim (harness-ui-patch-review--decode (plist-get result :stderr)))))
           (harness-ui-patch-review--fail
            "git %s: %s" (car args)
            (cond ((not (string-empty-p err)) (harness-first-line err))
                  ((eq (plist-get result :exit) 'timeout) "timed out")
                  (t (format "exit status %s" (plist-get result :exit)))))))))))

(defun harness-ui-patch-review--rev (dir rev missing)
  "Return a promise of the commit REV names in DIR; it rejects with MISSING."
  (harness-then (harness-ui-patch-review--git dir "rev-parse" "--verify" "--quiet" rev)
                (lambda (out) (string-trim (harness-ui-patch-review--decode out)))
                (lambda (_) (harness-ui-patch-review--fail "%s" missing))))

(defun harness-ui-patch-review--merge-base (dir base tip)
  "Return a promise of (NAME . COMMIT), the merge base of TIP with BASE in DIR.
BASE is the branch the task's branch was made from.  When it is not
known, or no longer there, it is what DIR has checked out: NAME HEAD."
  (let ((with (lambda (name)
                (harness-then (harness-ui-patch-review--git dir "merge-base" name tip)
                              (lambda (out) (cons name (string-trim (harness-ui-patch-review--decode out))))))))
    (harness-catch (if (harness-string-blank-p base)
                       (funcall with "HEAD")
                     (harness-catch (funcall with base) (lambda (_) (funcall with "HEAD"))))
                   (lambda (_)
                     (harness-ui-patch-review--fail "The branch has no commit in common with %s"
                                                    (if (harness-string-blank-p base) "HEAD" base))))))

(defun harness-ui-patch-review--parse-raw (raw)
  "Return the files of RAW, what `git diff --raw -z' wrote, in its order."
  (let ((fields (split-string raw "\0" t))
        files)
    (while fields
      (let ((head (pop fields)))
        (when (string-match "\\`:\\([0-7]+\\) \\([0-7]+\\) \\([0-9a-f]+\\) \\([0-9a-f]+\\) \\([A-Z]\\)" head)
          (let* ((status (match-string 5 head))
                 (old-sha (match-string 3 head))
                 (new-sha (match-string 4 head))
                 (old-mode (match-string 1 head))
                 (new-mode (match-string 2 head))
                 (two (member status '("R" "C")))
                 (first (pop fields))
                 (second (and two (pop fields))))
            (push (harness-ui-patch-review--file-create
                   :status status
                   :path (or second first)
                   :old-path (and two first)
                   :old-mode old-mode :new-mode new-mode
                   :old-blob (and (not (string-match-p "\\`0+\\'" old-sha)) old-sha)
                   :new-blob (and (not (string-match-p "\\`0+\\'" new-sha)) new-sha))
                  files)))))
    (nreverse files)))

(defun harness-ui-patch-review--split-patch (patch)
  "Return PATCH, a diff, cut into the parts of its files, in order.
Each part starts with its `diff --git' line; no line of a hunk can."
  (let ((starts nil) (pos 0))
    (while (string-match "^diff --git " patch pos)
      (push (match-beginning 0) starts)
      (setq pos (match-end 0)))
    (cl-loop for (start . rest) on (nreverse starts)
             collect (substring patch start (or (car rest) (length patch))))))

(defun harness-ui-patch-review--count (file)
  "Count FILE's added and deleted lines in its patch, and see if it is binary."
  (let ((added 0) (deleted 0) (in-hunk nil) (binary nil))
    (dolist (line (split-string (or (harness-ui-patch-review--f-patch file) "") "\n"))
      (cond ((string-prefix-p "@@" line) (setq in-hunk t))
            ((not in-hunk)
             (when (or (string-prefix-p "Binary files " line) (string-prefix-p "GIT binary patch" line))
               (setq binary t)))
            ((string-prefix-p "+" line) (cl-incf added))
            ((string-prefix-p "-" line) (cl-incf deleted))))
    (setf (harness-ui-patch-review--f-added file) added
          (harness-ui-patch-review--f-deleted file) deleted
          (harness-ui-patch-review--f-binary file) binary)))

(defun harness-ui-patch-review--pair (files parts)
  "Give each of FILES its part of the patch, from PARTS, and count it.
The two come from diffs of the same commits, in the same order, a part
for each file; when their numbers differ, a file gets the part whose
first line names it, if any."
  (let ((in-order (= (length files) (length parts))))
    (dolist (file files)
      (let ((part (if in-order
                      (pop parts)
                    (let ((want (format "diff --git a/%s b/%s\n"
                                        (or (harness-ui-patch-review--f-old-path file)
                                            (harness-ui-patch-review--f-path file))
                                        (harness-ui-patch-review--f-path file))))
                      (cl-find-if (lambda (p) (string-prefix-p want p)) parts)))))
        (setf (harness-ui-patch-review--f-patch file) part)
        (harness-ui-patch-review--count file)))
    files))

(defun harness-ui-patch-review--read-branch (dir branch base &optional worktree)
  "Return a promise of what BRANCH changes against its merge base with BASE.
DIR is the repository.  The promise resolves to a plist: :base, the
branch the merge base is with (HEAD when BASE is not there), :merge-base
and :tip, the commits compared, :files, the files changed, and :dirty,
non-nil when WORKTREE, the branch's worktree, has changes not committed."
  (harness-then
   (harness-ui-patch-review--rev dir (concat branch "^{commit}")
                                 (format-message "There is no branch `%s' in %s" branch (abbreviate-file-name dir)))
   (lambda (tip)
     (harness-then
      (harness-ui-patch-review--merge-base dir base tip)
      (lambda (found)
        (let ((merge-base (cdr found)))
          (harness-then
           (harness-all
            (list (harness-ui-patch-review--git dir "diff" "--raw" "-z" "-M" "--no-abbrev" merge-base tip)
                  (harness-ui-patch-review--git dir "diff" "-M" "--no-color" "--no-ext-diff" "--no-textconv"
                                                "--src-prefix=a/" "--dst-prefix=b/" merge-base tip)
                  (if worktree
                      (harness-catch (harness-ui-patch-review--git worktree "status" "--porcelain" "-z"
                                                                   "--untracked-files=no")
                                     (lambda (_) ""))
                    "")))
           (lambda (outputs)
             (let ((files (harness-ui-patch-review--parse-raw
                           (harness-ui-patch-review--decode (nth 0 outputs)))))
               (harness-ui-patch-review--pair
                files (harness-ui-patch-review--split-patch (harness-ui-patch-review--decode (nth 1 outputs))))
               (list :base (car found) :merge-base merge-base :tip tip :files files
                     :dirty (not (string-empty-p (nth 2 outputs)))))))))))))

(defun harness-ui-patch-review--blob (review sha)
  "Return a promise of the text of blob SHA in REVIEW's repository, \"\" for nil."
  (if (null sha)
      (harness-resolved "")
    (harness-then (harness-ui-patch-review--git (harness-ui-patch-review--r-dir review) "cat-file" "blob" sha)
                  (lambda (bytes) (harness-ui-patch-review--decode bytes 'undecided)))))

;;;; Reviews

(defun harness-ui-patch-review--review-for (task)
  "Return the review of TASK, made now when it has none."
  (let* ((id (plist-get task :id))
         (review (or (gethash id harness-ui-patch-review--reviews)
                     (puthash id (harness-ui-patch-review--review-create :id id)
                              harness-ui-patch-review--reviews))))
    (setf (harness-ui-patch-review--r-task review) task)
    review))

(defun harness-ui-patch-review--refresh (review)
  "Draw the report REVIEW shows in again, when it is open.
Not while it draws: what it draws is current then."
  (unless harness-ui-patch-review--drawing
    (let ((popout (harness-ui-patch-review--r-popout review)))
      (when (buffer-live-p popout)
        (harness-ui-popout-refresh (buffer-local-value 'harness-ui-popout-key popout))))))

(defun harness-ui-patch-review--load (review)
  "Read REVIEW's branch again, then draw its report.
Return a promise of REVIEW."
  (let* ((task (harness-ui-patch-review--r-task review))
         (dir (harness-ui-patch-review--repository task))
         (branch (plist-get task :branch))
         (worktree (let ((wt (plist-get task :worktree)))
                     (and (stringp wt) (not (file-remote-p wt)) (file-directory-p wt) wt)))
         (token (list 'loading)))
    (setf (harness-ui-patch-review--r-loading review) token
          (harness-ui-patch-review--r-error review) nil)
    (harness-ui-patch-review--refresh review)
    (harness-then
     (if dir
         (harness-ui-patch-review--read-branch dir branch (plist-get task :base) worktree)
       (harness-ui-patch-review--fail "%s" (harness-ui-patch-review--why-not task)))
     (lambda (result)
       ;; A later reading wins over this one.
       (when (eq (harness-ui-patch-review--r-loading review) token)
         (setf (harness-ui-patch-review--r-loading review) nil
               (harness-ui-patch-review--r-dir review) dir
               (harness-ui-patch-review--r-branch review) branch
               (harness-ui-patch-review--r-base review) (plist-get result :base)
               (harness-ui-patch-review--r-merge-base review) (plist-get result :merge-base)
               (harness-ui-patch-review--r-tip review) (plist-get result :tip)
               (harness-ui-patch-review--r-files review) (plist-get result :files)
               (harness-ui-patch-review--r-dirty review) (plist-get result :dirty))
         (harness-ui-patch-review--refresh review))
       review)
     (lambda (err)
       (when (eq (harness-ui-patch-review--r-loading review) token)
         (setf (harness-ui-patch-review--r-loading review) nil
               (harness-ui-patch-review--r-error review) (harness-error-message err))
         (harness-ui-patch-review--refresh review))
       review))))

(defun harness-ui-patch-review--seen-key (file)
  "Return what marks FILE seen: its path and its blob on the branch.
A file the branch changed again since it was seen is not seen."
  (cons (harness-ui-patch-review--f-path file) (harness-ui-patch-review--f-new-blob file)))

(defun harness-ui-patch-review--seen-p (review file)
  "Non-nil when FILE of REVIEW was seen in Ediff."
  (gethash (harness-ui-patch-review--seen-key file) (harness-ui-patch-review--r-seen review)))

(defun harness-ui-patch-review--mark-seen (review file)
  "Mark FILE of REVIEW seen."
  (when file
    (puthash (harness-ui-patch-review--seen-key file) t (harness-ui-patch-review--r-seen review))))

(defun harness-ui-patch-review--ediff-buffers (review)
  "Return the buffers of REVIEW's Ediff: its control panel and its two versions."
  (let ((ediff (harness-ui-patch-review--r-ediff review)))
    (list (plist-get ediff :control) (plist-get ediff :a) (plist-get ediff :b))))

(defun harness-ui-patch-review--ediff-shows-p (review)
  "Non-nil when a window shows REVIEW's Ediff."
  (cl-some (lambda (buffer) (and (buffer-live-p buffer) (get-buffer-window buffer t)))
           (harness-ui-patch-review--ediff-buffers review)))

(defun harness-ui-patch-review--forget (review)
  "Drop REVIEW: end its Ediff, give the windows back if it shows, kill its buffers."
  (remhash (harness-ui-patch-review--r-id review) harness-ui-patch-review--reviews)
  (condition-case err
      (harness-ui-patch-review--end-ediff review (not (harness-ui-patch-review--ediff-shows-p review)))
    (error (harness-log 'warn "patch review: could not end Ediff: %S" err)))
  (dolist (buffer (harness-ui-patch-review--ediff-buffers review))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (setf (harness-ui-patch-review--r-ediff review) nil))

;;;; The quote and the comments

(defun harness-ui-patch-review--header (file)
  "Return the first line of FILE's diff, which names it in the quote."
  (let ((patch (harness-ui-patch-review--f-patch file)))
    (if (and patch (string-match "\\`[^\n]+" patch))
        (match-string 0 patch)
      (format "diff --git a/%s b/%s"
              (or (harness-ui-patch-review--f-old-path file) (harness-ui-patch-review--f-path file))
              (harness-ui-patch-review--f-path file)))))

(defun harness-ui-patch-review--parse ()
  "Return the lines of this buffer's accessible portion, in order, as plists.
:type is `quote', for a line of the quote (one that starts with \">\"),
`comment' or `blank'; :start is where the line starts, :text what it
holds.  Every line has the part of the quote it is in: :file, the first
line of its file's diff (nil before the first), and :hunk, the index of
the hunk in the file (nil in the file's header).  A quote line has
:line -- `file' for that first line, `header' for the rest of the
file's header, `hunk', `context', `added', `removed' or `other' -- and
in a hunk :old and :new, its numbers at the merge base and on the
branch, where it has them.  A hunk's header has :new-start, where it
starts on the branch.  The quote of a hunk may stop for comments and go
on after them: its numbers go on too."
  (save-excursion
    (goto-char (point-min))
    (let (lines file hunk old new)
      (while (not (eobp))
        (let* ((start (point))
               (text (buffer-substring-no-properties start (line-end-position)))
               (props
                (cond
                 ((string-prefix-p ">" text)
                  (let ((diff (substring text (if (string-prefix-p "> " text) 2 1))))
                    (cond
                     ((string-prefix-p "diff --git " diff)
                      (setq file diff hunk nil)
                      (list :type 'quote :line 'file))
                     ((and file (string-match harness-ui-patch-review--hunk-regexp diff))
                      (setq hunk (if hunk (1+ hunk) 0)
                            old (string-to-number (match-string 1 diff))
                            new (string-to-number (match-string 3 diff)))
                      (list :type 'quote :line 'hunk :new-start new))
                     ((null hunk) (list :type 'quote :line 'header))
                     ((string-prefix-p "+" diff)
                      (prog1 (list :type 'quote :line 'added :new new) (cl-incf new)))
                     ((string-prefix-p "-" diff)
                      (prog1 (list :type 'quote :line 'removed :old old) (cl-incf old)))
                     ((string-prefix-p "\\" diff) (list :type 'quote :line 'other))
                     (t (prog1 (list :type 'quote :line 'context :old old :new new)
                          (cl-incf old) (cl-incf new))))))
                 ((string-blank-p text) (list :type 'blank))
                 (t (list :type 'comment)))))
          (push (append (list :start start :text text :file file :hunk hunk) props) lines))
        (forward-line 1))
      (nreverse lines))))

(defun harness-ui-patch-review--parse-text (text)
  "Return the lines of TEXT, as `harness-ui-patch-review--parse' does."
  (with-temp-buffer
    (insert text)
    (harness-ui-patch-review--parse)))

(defun harness-ui-patch-review--comment-blocks (lines)
  "Return the first line of each comment in LINES.
A comment is a paragraph of the lines that do not quote: a blank line
ends it, as a line of the quote does.  Two comments under one line of
the quote, each made with c in Ediff, are two."
  (let (blocks in-block)
    (dolist (line lines)
      (if (not (eq (plist-get line :type) 'comment))
          (setq in-block nil)
        (unless in-block (push line blocks))
        (setq in-block t)))
    (nreverse blocks)))

(defun harness-ui-patch-review--counts (text)
  "Return the comments TEXT has on files, an alist of (HEADER . COUNT).
TEXT is what a feedback box holds; HEADER names a file as
`harness-ui-patch-review--header' does.  What comes before any quote of
a file -- the line that says what the quote is, words on the change as
a whole -- is no comment on a file."
  (let (counts)
    (dolist (block (harness-ui-patch-review--comment-blocks (harness-ui-patch-review--parse-text text)))
      (when-let* ((file (plist-get block :file)))
        (let ((cell (assoc file counts)))
          (if cell (cl-incf (cdr cell)) (push (cons file 1) counts)))))
    (nreverse counts)))

(defun harness-ui-patch-review--comment-text (text)
  "Return TEXT made a comment of the feedback: trimmed and filled.
No line of it starts with \">\", which would be taken for the quote."
  (with-temp-buffer
    (insert (string-trim text))
    (let ((fill-column harness-ui-patch-review-fill-column)
          (adaptive-fill-mode nil))
      (fill-region (point-min) (point-max)))
    (goto-char (point-min))
    (while (re-search-forward "^>" nil t)
      (replace-match " >" t t))
    (string-trim-right (buffer-string))))

(defun harness-ui-patch-review--attribution (review)
  "Return the line before the first quote of REVIEW's diff in the feedback.
It says what the quote is, for the task to read it."
  (format "My comments on the diff of your branch %s (at %s) against %s (merge base %s), each under the lines it is about:"
          (harness-ui-patch-review--r-branch review)
          (harness-ui-patch-review--short (harness-ui-patch-review--r-tip review))
          (harness-ui-patch-review--r-base review)
          (harness-ui-patch-review--short (harness-ui-patch-review--r-merge-base review))))

;;;;; The lines a comment is about

(defun harness-ui-patch-review--hunks (file)
  "Return the hunks of FILE's diff, in order, each a plist.
:heading is what its header has after the line numbers, :lines its
lines, each a list (KIND TEXT OLD NEW): KIND the character the line
starts with, TEXT the rest, OLD and NEW its numbers at the merge base
and on the branch -- on a side the line is not on, the number of the
line that follows it there."
  (let (hunks heading lines old new)
    (cl-flet ((finish () (when heading (push (list :heading heading :lines (nreverse lines)) hunks))))
      (dolist (text (split-string (or (harness-ui-patch-review--f-patch file) "") "\n"))
        (cond
         ((string-match harness-ui-patch-review--hunk-regexp text)
          (finish)
          ;; A side with no line counts from the line before: git's
          ;; "-0,0" for a file that is new.
          (setq old (+ (string-to-number (match-string 1 text))
                       (if (equal (match-string 2 text) "0") 1 0))
                new (+ (string-to-number (match-string 3 text))
                       (if (equal (match-string 4 text) "0") 1 0))
                heading (match-string 5 text)
                lines nil))
         ((or (null heading) (string-empty-p text)))
         (t
          (let ((kind (aref text 0)))
            (push (list kind (substring text 1) old new) lines)
            (pcase kind
              (?\s (cl-incf old) (cl-incf new))
              (?- (cl-incf old))
              (?+ (cl-incf new)))))))
      (finish))
    (nreverse hunks)))

(defun harness-ui-patch-review--own-number (line side)
  "Return the number of LINE, a hunk's, on SIDE, :old or :new; nil when not there."
  (pcase-let ((`(,kind ,_ ,old ,new) line))
    (pcase kind
      (?\s (if (eq side :old) old new))
      (?- (and (eq side :old) old))
      (?+ (and (eq side :new) new)))))

(defun harness-ui-patch-review--locate (hunks side number)
  "Return (HUNK INDEX EXACT) for line NUMBER of SIDE in HUNKS, or nil.
INDEX is that of the line in HUNK's lines: the line NUMBER, EXACT
non-nil, else the nearest the diff has on SIDE."
  (let (best distance)
    (cl-loop for hunk in hunks
             until (and distance (zerop distance))
             do (cl-loop for line in (plist-get hunk :lines) for index from 0
                         for own = (harness-ui-patch-review--own-number line side)
                         when (and own (or (null distance) (< (abs (- own number)) distance)))
                         do (setq best (list hunk index (= own number))
                                  distance (abs (- own number)))))
    best))

(defun harness-ui-patch-review--same-line-p (quoted line)
  "Non-nil when QUOTED, a line of the box, quotes LINE, a hunk's."
  (pcase-let ((`(,kind ,_ ,old ,new) line))
    (pcase kind
      (?\s (and (eq (plist-get quoted :line) 'context)
                (eql (plist-get quoted :old) old) (eql (plist-get quoted :new) new)))
      (?- (and (eq (plist-get quoted :line) 'removed) (eql (plist-get quoted :old) old)))
      (?+ (and (eq (plist-get quoted :line) 'added) (eql (plist-get quoted :new) new))))))

(defun harness-ui-patch-review--excerpt (file side number quoted)
  "Return the part of FILE's diff that a comment on line NUMBER of SIDE quotes.
SIDE is :new for a line of the branch, :old for one of the merge base.
The part ends on that line, or on the nearest one the diff has, and
starts where the change it ends starts, after at most
`harness-ui-patch-review-context-lines' lines before it.  QUOTED are
the lines of the box that quote FILE already: what they quote is not
quoted again, the part going on after the last of them instead.

Return nil when the diff has no hunk, else a plist: :text, the part,
quoted, its hunk's header first unless it goes on; :new-start, where it
starts on the branch; :exact, non-nil when it ends on line NUMBER;
:after, the line of QUOTED it goes on after, if it does."
  (when-let* ((found (harness-ui-patch-review--locate (harness-ui-patch-review--hunks file) side number)))
    (pcase-let* ((`(,hunk ,index ,exact) found)
                 (lines (plist-get hunk :lines))
                 (change-p (lambda (i) (memq (car (nth i lines)) '(?+ ?- ?\\))))
                 (end (if (eq (car (nth (1+ index) lines)) ?\\) (1+ index) index))
                 (back (lambda (i)
                         ;; To the start of the change I is in, if any.
                         (when (funcall change-p i)
                           (while (and (> i 0) (funcall change-p (1- i))) (cl-decf i)))
                         i))
                 ;; The context before the change, not cutting into one.
                 (first (funcall back (max 0 (- (funcall back index) harness-ui-patch-review-context-lines))))
                 (done (cl-loop for i from end downto first
                                for line = (nth i lines)
                                for match = (cl-find-if (lambda (q) (harness-ui-patch-review--same-line-p q line))
                                                        quoted)
                                when match return (cons i match)))
                 (from (if done (1+ (car done)) first))
                 (part (cl-subseq lines from (1+ end))))
      (list :text (concat
                   (unless done
                     (pcase-let ((`(,_ ,_ ,old ,new) (nth from lines))
                                 (old-count (cl-count-if (lambda (l) (memq (car l) '(?\s ?-))) part))
                                 (new-count (cl-count-if (lambda (l) (memq (car l) '(?\s ?+))) part)))
                       ;; A side with no line names the line before, as git does.
                       (format "> @@ -%d,%d +%d,%d @@%s\n"
                               (if (zerop old-count) (1- old) old) old-count
                               (if (zerop new-count) (1- new) new) new-count
                               (plist-get hunk :heading))))
                   (mapconcat (lambda (l) (concat "> " (char-to-string (car l)) (nth 1 l) "\n")) part ""))
            :new-start (nth 3 (nth from lines))
            :exact exact
            :after (cdr done)))))

;;;;; Putting a comment in the box

(defun harness-ui-patch-review--after-comments (pos)
  "Return where the comments under the quote line at POS end.
That is the start of the next quote line, or the end."
  (save-excursion
    (goto-char pos)
    (forward-line 1)
    (while (and (not (eobp)) (not (eq (char-after) ?>)))
      (forward-line 1))
    (point)))

(defun harness-ui-patch-review--insert-comment (anchor text)
  "Insert TEXT, a comment, under the quote line that starts at ANCHOR.
It goes after the comments under that line already, a blank line
before it and after it.  Return where it starts."
  (save-excursion
    (goto-char anchor)
    (end-of-line)
    (when (eobp) (insert "\n"))
    (let ((limit (line-beginning-position 2))
          (next (harness-ui-patch-review--after-comments anchor))
          start)
      (goto-char next)
      ;; Back over the blank lines before the next quote line.
      (while (and (> (point) limit)
                  (save-excursion (forward-line -1) (looking-at-p "[ \t]*$")))
        (forward-line -1))
      (let ((blank-after (< (point) next)))
        (insert "\n")
        (setq start (point))
        (insert text "\n")
        (unless (or blank-after (eobp)) (insert "\n")))
      start)))

(defun harness-ui-patch-review--insert-block (pos block)
  "Insert BLOCK, lines of the quote and a comment under them, at POS.
POS starts a line.  A blank line parts BLOCK from a comment before it
and from whatever follows it.  Return where BLOCK starts."
  (goto-char pos)
  (unless (bobp)
    (let ((before (save-excursion (forward-line -1)
                                  (buffer-substring-no-properties (point) (line-end-position)))))
      (unless (or (string-blank-p before) (string-prefix-p ">" before))
        (insert "\n"))))
  (prog1 (point)
    (insert block)
    (unless (or (eobp) (looking-at-p "[ \t]*$"))
      (insert "\n"))))

(defun harness-ui-patch-review--section-end (lines header)
  "Return where the quote of the file HEADER names ends among LINES.
That is where the next file's quote starts, or the end."
  (let ((in nil))
    (or (cl-loop for line in lines
                 for file-p = (eq (plist-get line :line) 'file)
                 when (and file-p in) return (plist-get line :start)
                 when (and file-p (equal (plist-get line :file) header)) do (setq in t))
        (point-max))))

(defun harness-ui-patch-review--block-position (review file lines quoted excerpt)
  "Return where the quote EXCERPT of REVIEW's FILE goes among LINES, the box's.
QUOTED are the lines quoting FILE already.  The files keep the order
of the diff, the hunks of a file the order of its lines."
  (if quoted
      (let ((next (cl-find-if (lambda (line) (and (eq (plist-get line :line) 'hunk)
                                                  (> (plist-get line :new-start)
                                                     (plist-get excerpt :new-start))))
                              quoted)))
        (if next
            (plist-get next :start)
          (harness-ui-patch-review--section-end lines (harness-ui-patch-review--header file))))
    (let* ((files (harness-ui-patch-review--r-files review))
           (rank (lambda (header) (cl-position header files :key #'harness-ui-patch-review--header
                                               :test #'equal)))
           (mine (funcall rank (harness-ui-patch-review--header file)))
           (next (and mine
                      (cl-find-if (lambda (line)
                                    (and (eq (plist-get line :line) 'file)
                                         (let ((theirs (funcall rank (plist-get line :file))))
                                           (and theirs (> theirs mine)))))
                                  lines))))
      (if next (plist-get next :start) (point-max)))))

(defun harness-ui-patch-review--put-comment (review file where text)
  "Put TEXT, a comment on FILE of REVIEW, in the box, under the lines it is about.
The buffer is narrowed to the box.  WHERE is as for
`harness-ui-patch-review--add-comment'."
  ;; Whole lines: the box ends with a newline.
  (goto-char (point-max))
  (unless (or (bobp) (bolp)) (insert "\n"))
  (let* ((lines (harness-ui-patch-review--parse))
         (header (harness-ui-patch-review--header file))
         (quoted (cl-remove-if-not (lambda (line) (and (eq (plist-get line :type) 'quote)
                                                        (equal (plist-get line :file) header)))
                                   lines))
         (side (car where))
         (number (cdr where))
         (exact (and side (cl-find-if (lambda (line) (eql (plist-get line side) number)) quoted))))
    (if exact
        (harness-ui-patch-review--insert-comment (plist-get exact :start)
                                                 (harness-ui-patch-review--comment-text text))
      (let* ((excerpt (and side (harness-ui-patch-review--excerpt file side number quoted)))
             (comment (harness-ui-patch-review--comment-text
                       (if (or (null side) (plist-get excerpt :exact))
                           text
                         (format "On line %d%s: %s" number (if (eq side :old) " of the merge base" "") text))))
             (after (plist-get excerpt :after)))
        (cond
         ;; Nothing more to quote: under the line quoted last.
         ((and after (string-empty-p (plist-get excerpt :text)))
          (harness-ui-patch-review--insert-comment (plist-get after :start) comment))
         ;; On from where the quote of the hunk stops.
         (after
          (harness-ui-patch-review--insert-block
           (harness-ui-patch-review--after-comments (plist-get after :start))
           (concat (plist-get excerpt :text) "\n" comment "\n")))
         ;; On the file as a whole, or a file the diff has no line of:
         ;; under its first line.
         ((and (null excerpt) quoted)
          (harness-ui-patch-review--insert-comment (plist-get (car quoted) :start) comment))
         (t
          (harness-ui-patch-review--insert-block
           (harness-ui-patch-review--block-position review file lines quoted excerpt)
           (concat (unless quoted
                     (concat (unless (cl-some (lambda (line) (plist-get line :file)) lines)
                               (concat (harness-ui-patch-review--attribution review) "\n\n"))
                             "> " header "\n"))
                   (plist-get excerpt :text)
                   "\n" comment "\n"))))))))

(defun harness-ui-patch-review--feedback-box (review)
  "Return the report of REVIEW's task, whose box takes the feedback; or signal.
A report closed meanwhile opens again, out of sight, for its box."
  (let ((task (harness-ui-patch-review--r-task review)))
    (unless (harness-ui-patch-review--reviewing-p task)
      (user-error "%s no longer waits for review: there is no feedback to comment in"
                  (harness-ui-patch-review--title review)))
    (unless (buffer-live-p (harness-ui-patch-review--r-popout review))
      (save-window-excursion (harness-ui-report-popout task)))
    (let ((popout (harness-ui-patch-review--r-popout review)))
      (unless (and (buffer-live-p popout) (with-current-buffer popout (harness-compose-live-p)))
        (user-error "The report of %s has no box for the feedback" (harness-ui-patch-review--title review)))
      popout)))

(defun harness-ui-patch-review--add-comment (review file where text)
  "Put TEXT in the feedback box of REVIEW's report as a comment on FILE.
WHERE is (SIDE . LINE): the comment is on LINE of the branch's version
for SIDE :new, of the merge base's for :old; nil for the file as a
whole.  It goes under the line, quoted from the diff with the change it
ends and a few lines before, its file's `diff --git' line first, and
after the comments there already.  A line the diff does not have gets
the comment under the nearest one, saying which line it is about.  The
first quote in the box gets a line before it saying what it is."
  (let ((popout (harness-ui-patch-review--feedback-box review)))
    (with-current-buffer popout
      (let ((inhibit-read-only t))
        (save-excursion
          (save-restriction
            (narrow-to-region harness-compose-start harness-compose-end)
            (harness-ui-patch-review--put-comment review file where text))))
      (harness-compose-update-placeholder))
    (harness-ui-patch-review--refresh review)))

;;;; The changes in the report

(defvar harness-ui-patch-review--row-map (make-sparse-keymap)
  "Keys on a row of the changes in a report: RET or a click compares its file.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-patch-review--row-map))
  (define-key map (kbd "RET") #'harness-ui-patch-review-ediff)
  (define-key map [mouse-1] #'harness-ui-patch-review-mouse-ediff)
  (define-key map [mouse-2] #'harness-ui-patch-review-mouse-ediff)
  ;; A double click compares once.
  (define-key map [double-mouse-1] #'ignore)
  (define-key map [triple-mouse-1] #'ignore)
  (define-key map (kbd "n") #'harness-ui-patch-review-next-file)
  (define-key map (kbd "p") #'harness-ui-patch-review-previous-file))

(defun harness-ui-patch-review--path-label (file)
  "Return the path of FILE for its row, \"OLD → NEW\" for a rename."
  (if (harness-ui-patch-review--f-old-path file)
      (format "%s → %s" (harness-ui-patch-review--f-old-path file) (harness-ui-patch-review--f-path file))
    (harness-ui-patch-review--f-path file)))

(defun harness-ui-patch-review--submodule-p (file)
  "Non-nil when FILE is a submodule on either side."
  (or (equal (harness-ui-patch-review--f-old-mode file) "160000")
      (equal (harness-ui-patch-review--f-new-mode file) "160000")))

(defun harness-ui-patch-review--change-label (file)
  "Return what changed in FILE, for its row: the lines added and deleted."
  (let* ((added (harness-ui-patch-review--f-added file))
         (deleted (harness-ui-patch-review--f-deleted file))
         (old-mode (harness-ui-patch-review--f-old-mode file))
         (new-mode (harness-ui-patch-review--f-new-mode file))
         (mode (and (not (member old-mode '("000000" nil))) (not (member new-mode '("000000" nil)))
                    (not (equal old-mode new-mode))
                    (format "mode %s → %s" old-mode new-mode)))
         (lines (and (> (+ added deleted) 0)
                     (concat (propertize (format "+%d" added) 'face 'harness-ui-patch-review-plus-face)
                             " "
                             (propertize (format "−%d" deleted) 'face 'harness-ui-patch-review-minus-face)))))
    (cond ((harness-ui-patch-review--submodule-p file) (propertize "submodule" 'face 'harness-dim-face))
          ((harness-ui-patch-review--f-binary file) (propertize "binary" 'face 'harness-dim-face))
          ((and lines mode) (concat lines "  " (propertize mode 'face 'harness-dim-face)))
          (lines)
          (mode (propertize mode 'face 'harness-dim-face))
          ((harness-ui-patch-review--f-old-path file) (propertize "same content" 'face 'harness-dim-face))
          (t ""))))

(defun harness-ui-patch-review--status-face (file)
  "Return the face of FILE's status letter."
  (pcase (harness-ui-patch-review--f-status file)
    ("A" 'harness-ui-patch-review-plus-face)
    ("D" 'harness-ui-patch-review-minus-face)
    (_ 'bold)))

(defun harness-ui-patch-review--row (review file index width counts)
  "Return the row of FILE of REVIEW, at INDEX of its files.
The path is padded to WIDTH; COUNTS are the box's comments."
  (let* ((comments (or (cdr (assoc (harness-ui-patch-review--header file) counts)) 0))
         (row (concat "  "
                      (if (harness-ui-patch-review--seen-p review file)
                          (propertize "✓" 'face 'harness-ui-patch-review-seen-face)
                        " ")
                      " "
                      (propertize (harness-ui-patch-review--f-status file)
                                  'face (harness-ui-patch-review--status-face file))
                      "  "
                      (string-pad (harness-truncate-middle (harness-ui-patch-review--path-label file) width) width)
                      "  "
                      (harness-ui-patch-review--change-label file)
                      (if (> comments 0)
                          (concat "   " (propertize (harness-ui-patch-review--plural comments "comment")
                                                    'face 'harness-ui-patch-review-comments-face))
                        ""))))
    (add-text-properties 0 (length row)
                         (list 'harness-ui-patch-review-file index
                               'harness-ui-patch-review-task (harness-ui-patch-review--r-id review)
                               'mouse-face 'highlight
                               'help-echo "RET or a click: compare it in Ediff"
                               'keymap harness-ui-patch-review--row-map)
                         row)
    row))

(defun harness-ui-patch-review--heading (review comments)
  "Return the first line of REVIEW's changes: what is compared, how much changed.
COMMENTS is how many comments the box has on them."
  (let ((files (harness-ui-patch-review--r-files review))
        (tip (harness-ui-patch-review--r-tip review)))
    (concat
     (propertize (if tip (format "Changes (%d)" (length files)) "Changes") 'face 'harness-label-face)
     (if (not tip) ""
       (concat
        "   " (propertize (harness-ui-patch-review--r-branch review) 'face 'bold)
        (propertize (format " against %s @ %s"
                            (harness-ui-patch-review--r-base review)
                            (harness-ui-patch-review--short (harness-ui-patch-review--r-merge-base review)))
                    'face 'harness-dim-face
                    'help-echo (format "The branch at %s against its merge base with %s, %s: what merging it brings in"
                                       (harness-ui-patch-review--short tip)
                                       (harness-ui-patch-review--r-base review)
                                       (harness-ui-patch-review--short (harness-ui-patch-review--r-merge-base review))))
        (if (null files) ""
          (concat "   " (propertize (format "+%d" (apply #'+ (mapcar #'harness-ui-patch-review--f-added files)))
                                    'face 'harness-ui-patch-review-plus-face)
                  " " (propertize (format "−%d" (apply #'+ (mapcar #'harness-ui-patch-review--f-deleted files)))
                                  'face 'harness-ui-patch-review-minus-face)))
        (if (> comments 0)
            (concat "   " (propertize (harness-ui-patch-review--plural comments "comment")
                                      'face 'harness-ui-patch-review-comments-face))
          ""))))))

(defun harness-ui-patch-review--notes (review)
  "Return the lines that tell what to know about REVIEW, above its files."
  (let ((tip (harness-ui-patch-review--r-tip review)))
    (delq nil
          (list
           (and (harness-ui-patch-review--r-loading review)
                (propertize (if tip "Reading the branch again…" "Reading the branch…") 'face 'harness-dim-face))
           (and (harness-ui-patch-review--r-error review)
                (concat (propertize (format "Could not read the branch: %s" (harness-ui-patch-review--r-error review))
                                    'face 'error)
                        "  "
                        (propertize (buttonize "[Try again]"
                                               (lambda (_) (harness-ui-patch-review--load review))
                                               nil "Read the branch again")
                                    'mouse-face 'highlight)))
           (and (harness-ui-patch-review--r-dirty review)
                (propertize "Its worktree has changes not committed: they are not on the branch, so not here."
                            'face 'warning))
           (and tip (null (harness-ui-patch-review--r-files review))
                (propertize (format "The branch changes nothing against %s." (harness-ui-patch-review--r-base review))
                            'face 'harness-dim-face))))))

(defconst harness-ui-patch-review--hint
  "RET or a click compares a file in Ediff, n and p move between them.  In Ediff c comments on a difference, quoting it in the box below; N and P go on to the next or previous file, q comes back here."
  "What the report says under the changes.")

(defun harness-ui-patch-review--section (review counts)
  "Return REVIEW's changes as its report shows them; COUNTS are the box's comments."
  (let* ((files (harness-ui-patch-review--r-files review))
         (width (min 60 (apply #'max 0 (mapcar (lambda (file) (string-width (harness-ui-patch-review--path-label file)))
                                               files)))))
    (concat
     (harness-ui-patch-review--heading review (apply #'+ (mapcar #'cdr counts))) "\n"
     (mapconcat (lambda (note) (concat "  " note "\n")) (harness-ui-patch-review--notes review) "")
     (if (null files) ""
       (concat "\n"
               (cl-loop for file in files for index from 0
                        concat (concat (harness-ui-patch-review--row review file index width counts) "\n"))
               (propertize (concat "  " harness-ui-patch-review--hint) 'face 'harness-hint-face 'wrap-prefix "  ")
               "\n")))))

(defun harness-ui-patch-review--panel (task)
  "Return the changes of TASK for its report, while TASK waits for review.
On `harness-ui-report-panel-functions', called in the report popout on
every draw.  Nil for a task with no branch of its own; for one whose
repository is not on this machine, a line saying so.  A report opened
afresh reads the branch afresh."
  (when (and harness-ui-patch-review--active
             (derived-mode-p 'harness-ui-popout-mode)
             (harness-ui-patch-review--reviewing-p task)
             (not (harness-string-blank-p (plist-get task :branch))))
    (if (not (harness-ui-patch-review--repository task))
        (concat (propertize "Changes" 'face 'harness-label-face) "   "
                (propertize (harness-ui-patch-review--why-not task) 'face 'harness-dim-face) "\n")
      (let ((review (harness-ui-patch-review--review-for task))
            (harness-ui-patch-review--drawing t))
        (if (not (eq (harness-ui-patch-review--r-popout review) (current-buffer)))
            (progn
              (setf (harness-ui-patch-review--r-popout review) (current-buffer))
              (add-hook 'after-change-functions #'harness-ui-patch-review--box-changed nil t)
              (harness-ui-patch-review--load review))
          (unless (or (harness-ui-patch-review--r-tip review) (harness-ui-patch-review--r-loading review)
                      (harness-ui-patch-review--r-error review))
            (harness-ui-patch-review--load review)))
        (let ((counts (harness-ui-patch-review--counts (or (harness-compose-text) ""))))
          (setf (harness-ui-patch-review--r-counts review) counts)
          (harness-ui-patch-review--section review counts))))))

(defun harness-ui-patch-review--box-changed (beg end _length)
  "Count the comments in this report's box again, once the typing stops.
On `after-change-functions' of a report showing changes, for a change
from BEG to END."
  (when (and harness-ui-patch-review--active (harness-compose-in-p beg) (harness-compose-in-p end))
    (harness-debounce (list 'harness-ui-patch-review (current-buffer)) 0.4
                      #'harness-ui-patch-review--recount (current-buffer))))

(defun harness-ui-patch-review--recount (buffer)
  "Draw BUFFER, a report, again when the comments in its box changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((task (harness-ui-report-task))
                  (review (gethash (plist-get task :id) harness-ui-patch-review--reviews)))
        (when (and (eq (harness-ui-patch-review--r-popout review) buffer)
                   (not (equal (harness-ui-patch-review--counts (or (harness-compose-text) ""))
                               (harness-ui-patch-review--r-counts review))))
          (harness-ui-patch-review--refresh review))))))

(defun harness-ui-patch-review--row-start (id index)
  "Return where the row of the file at INDEX of task ID starts here, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (when (and (eql (get-text-property (point) 'harness-ui-patch-review-file) index)
                   (equal (get-text-property (point) 'harness-ui-patch-review-task) id))
          (setq found (point)))
        (forward-line 1))
      found)))

(defun harness-ui-patch-review--at-point ()
  "Return (REVIEW . INDEX) for the row of a report at point, or nil."
  (let* ((bol (line-beginning-position))
         (index (get-text-property bol 'harness-ui-patch-review-file))
         (review (gethash (get-text-property bol 'harness-ui-patch-review-task)
                          harness-ui-patch-review--reviews)))
    (and index review (cons review index))))

(defun harness-ui-patch-review--goto-row (review index &optional start)
  "Put point on the row of REVIEW's file at INDEX in its report.
With START, the report's windows show from that line on, as before."
  (let ((popout (harness-ui-patch-review--r-popout review)))
    (when (buffer-live-p popout)
      (with-current-buffer popout
        (when-let* ((pos (harness-ui-patch-review--row-start (harness-ui-patch-review--r-id review) index)))
          (goto-char pos)
          (dolist (window (get-buffer-window-list popout nil t))
            (when start
              (set-window-start window (save-excursion (goto-char (point-min))
                                                       (forward-line (1- start))
                                                       (point))
                                t))
            (set-window-point window pos)))))))

(defun harness-ui-patch-review--step-point (step)
  "Move point STEP rows on among the changes of a report."
  (pcase-let* ((`(,review . ,index) (or (harness-ui-patch-review--at-point) (user-error "No file on this line")))
               (target (+ index step)))
    (if (or (< target 0) (>= target (length (harness-ui-patch-review--r-files review))))
        (message (if (< step 0) "That is the first file" "That is the last file"))
      (harness-ui-patch-review--goto-row review target))))

(defun harness-ui-patch-review-next-file (&optional n)
  "Move to the next file of the changes, or the Nth next."
  (interactive "p")
  (harness-ui-patch-review--step-point (or n 1)))

(defun harness-ui-patch-review-previous-file (&optional n)
  "Move to the previous file of the changes, or the Nth previous."
  (interactive "p")
  (harness-ui-patch-review--step-point (- (or n 1))))

;;;; Ediff

(defun harness-ui-patch-review--incomparable (file)
  "Return why Ediff cannot compare FILE, or nil when it can."
  (let ((path (harness-ui-patch-review--f-path file))
        (old (harness-ui-patch-review--f-old-blob file))
        (new (harness-ui-patch-review--f-new-blob file)))
    (cond ((harness-ui-patch-review--submodule-p file)
           (format "%s is a submodule: its commit went from %s to %s"
                   path (harness-ui-patch-review--short old) (harness-ui-patch-review--short new)))
          ((harness-ui-patch-review--f-binary file) (format "%s is binary: Ediff compares text" path))
          ((and old (equal old new))
           (if (harness-ui-patch-review--f-old-path file)
               (format "%s was renamed from %s, its content the same" path (harness-ui-patch-review--f-old-path file))
             (format "%s only changed its mode, %s → %s" path
                     (harness-ui-patch-review--f-old-mode file) (harness-ui-patch-review--f-new-mode file)))))))

(defun harness-ui-patch-review-ediff (&optional review index)
  "Compare the file of the row at point in Ediff, merge base and branch.
On the changes in a task's report.  In Ediff, c comments on the
current difference, into the report's box, N and P go on to the next
or previous file, and q comes back to the report.  REVIEW and INDEX
name the file instead of the row at point."
  (interactive)
  (pcase-let* ((`(,review . ,index) (if review (cons review index)
                                      (or (harness-ui-patch-review--at-point) (user-error "No file on this line"))))
               (file (or (nth index (harness-ui-patch-review--r-files review)) (user-error "No such file")))
               (why (harness-ui-patch-review--incomparable file)))
    (if (not why)
        (harness-ui-patch-review--compare review index)
      (harness-ui-patch-review--mark-seen review file)
      (harness-ui-patch-review--refresh review)
      (message "%s" why)
      nil)))

(defun harness-ui-patch-review-mouse-ediff (event)
  "Compare the file clicked on in EVENT in Ediff."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-patch-review-ediff))

(defun harness-ui-patch-review--compare (review index)
  "Read the two versions of REVIEW's file at INDEX, then compare them in Ediff.
Return a promise of the review."
  (let ((file (nth index (harness-ui-patch-review--r-files review))))
    (message "Reading %s…" (harness-ui-patch-review--f-path file))
    (harness-then
     (harness-all (list (harness-ui-patch-review--blob review (harness-ui-patch-review--f-old-blob file))
                        (harness-ui-patch-review--blob review (harness-ui-patch-review--f-new-blob file))))
     (lambda (texts)
       (harness-ui-patch-review--start-ediff review index (nth 0 texts) (nth 1 texts))
       review)
     (lambda (err)
       (message "Could not read %s: %s" (harness-ui-patch-review--f-path file) (harness-error-message err))
       nil))))

(defun harness-ui-patch-review--side-buffer (review file side text)
  "Return a buffer of TEXT, FILE's version on SIDE, `old' or `new', for Ediff.
REVIEW names it after the commit it is from.  It is in the major mode
of FILE, without the mode's hooks: a language server, say, has no
business there.  It is read-only."
  (let* ((old (eq side 'old))
         (path (if old (or (harness-ui-patch-review--f-old-path file) (harness-ui-patch-review--f-path file))
                 (harness-ui-patch-review--f-path file)))
         (buffer (generate-new-buffer
                  (format "%s (%s)" path
                          (if old (format "merge base %s" (harness-ui-patch-review--short
                                                          (harness-ui-patch-review--r-merge-base review)))
                            (format "%s %s" (harness-truncate-end (harness-ui-patch-review--r-branch review) 40)
                                    (harness-ui-patch-review--short (harness-ui-patch-review--r-tip review))))))))
    (with-current-buffer buffer
      (insert text)
      (let ((buffer-file-name (expand-file-name path (harness-ui-patch-review--r-dir review))))
        (condition-case err
            (delay-mode-hooks (set-auto-mode))
          (error (harness-log 'warn "patch review: no mode for %s: %S" path err))))
      (ignore-errors (font-lock-mode 1))
      (set-buffer-modified-p nil)
      (setq buffer-read-only t)
      (goto-char (point-min)))
    buffer))

(defun harness-ui-patch-review--help-button (label command key)
  "Return LABEL followed by KEY, a button running COMMAND, for Ediff's panel."
  (concat (propertize label 'face 'button 'mouse-face 'highlight
                      'help-echo (format "%s (%s)" label key)
                      'keymap (harness-ui-mouse-keymap command))
          " " (harness-ui-kbd key)))

(defun harness-ui-patch-review--ediff-help ()
  "Return the brief help of the Ediff control panel of a review."
  (concat (harness-ui-patch-review--help-button "[Comment]" #'harness-ui-patch-review-comment "c")
          "   " (harness-ui-patch-review--help-button "[Next file]" #'harness-ui-patch-review-ediff-next-file "N")
          "   " (harness-ui-patch-review--help-button "[Previous file]" #'harness-ui-patch-review-ediff-previous-file "P")
          "   " (harness-ui-patch-review--help-button "[Back to the report]" #'harness-ui-patch-review-ediff-quit "q")
          "   " (propertize "? Ediff's keys" 'face 'harness-dim-face)))

(defun harness-ui-patch-review--main-window ()
  "Return the window Ediff goes in: the selected one, when it may be.
Not a side window, a dedicated one or the minibuffer's: then the largest
window that is none of those, else the frame's first."
  (let* ((usable (lambda (window)
                   (not (or (window-minibuffer-p window)
                            (window-parameter window 'window-side)
                            (window-dedicated-p window)))))
         (windows (cl-remove-if-not usable (window-list nil 'nomini))))
    (cond ((funcall usable (selected-window)) (selected-window))
          (windows (car (sort windows (lambda (a b) (> (* (window-total-width a) (window-total-height a))
                                                       (* (window-total-width b) (window-total-height b)))))))
          (t (frame-first-window)))))

(defun harness-ui-patch-review--start-ediff (review index old new)
  "Compare OLD and NEW, the texts of REVIEW's file at INDEX, in Ediff.
From the report, Ediff takes its frame, whose windows are kept to give
back when it ends.  From an Ediff of the review -- N and P -- it takes
that one's place, with the same windows to give back."
  (require 'ediff)
  (let* ((file (nth index (harness-ui-patch-review--r-files review)))
         (before (harness-ui-patch-review--r-ediff review))
         (going (buffer-live-p (plist-get before :control)))
         (windows (and going (plist-get before :windows)))
         (start (and going (plist-get before :start))))
    (if going
        (harness-ui-patch-review--end-ediff review t)
      ;; In any frame: this runs once git has answered, when the frame
      ;; selected need not be the report's.
      (let* ((popout (harness-ui-patch-review--r-popout review))
             (window (and (buffer-live-p popout) (get-buffer-window popout t))))
        (when window
          (select-window window)
          (setq start (with-current-buffer popout (line-number-at-pos (window-start window)))))))
    (let ((windows (or windows (current-window-configuration)))
          (main (harness-ui-patch-review--main-window)))
      (select-window main)
      ;; Side windows too, the report's among them: Ediff lays the frame
      ;; out its own way, and q gives it back as it was.
      (let ((ignore-window-parameters t))
        (delete-other-windows main))
      (set-window-dedicated-p main nil)
      (let ((a (harness-ui-patch-review--side-buffer review file 'old old))
            (b (harness-ui-patch-review--side-buffer review file 'new new)))
        (setf (harness-ui-patch-review--r-ediff review)
              (list :index index :a a :b b :windows windows :start start))
        (condition-case err
            (let ((ediff-window-setup-function (or harness-ui-patch-review-ediff-window-setup
                                                   ediff-window-setup-function))
                  (ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help))
              (ediff-buffers a b (list (lambda () (harness-ui-patch-review--ediff-startup review index)))))
          (error
           (harness-ui-patch-review--ediff-ended review index)
           (message "Ediff could not compare %s: %s"
                    (harness-ui-patch-review--f-path file) (error-message-string err))))))))

(defun harness-ui-patch-review--ediff-startup (review index)
  "Make this Ediff control panel compare REVIEW's file at INDEX.
It gets the review's keys and help, and gives the report back as it ends."
  (setq harness-ui-patch-review--review review
        harness-ui-patch-review--index index)
  (setq-local ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ediff-mode-map)
    (define-key map "c" #'harness-ui-patch-review-comment)
    (define-key map "N" #'harness-ui-patch-review-ediff-next-file)
    (define-key map "P" #'harness-ui-patch-review-ediff-previous-file)
    (define-key map "q" #'harness-ui-patch-review-ediff-quit)
    ;; The panel's map, for whatever adds to it after: evil's keys, say.
    (setq-local ediff-mode-map map)
    (use-local-map map)
    ;; Evil put the panel's map before its states' (evil-collection makes
    ;; it overriding); the map that inherits from it takes its place.
    (when (and (bound-and-true-p evil-local-mode) (fboundp 'evil-normalize-keymaps))
      (evil-normalize-keymaps)))
  (setf (harness-ui-patch-review--r-ediff review)
        (plist-put (harness-ui-patch-review--r-ediff review) :control (current-buffer)))
  (add-hook 'ediff-after-quit-hook-internal
            (lambda () (harness-ui-patch-review--ediff-ended review index))
            nil t)
  (when (> ediff-number-of-differences 0)
    (ediff-next-difference)))

(defun harness-ui-patch-review--restore-windows (windows)
  "Give the frame of WINDOWS, a window configuration, its windows back.
A window whose buffer was killed meanwhile -- the report's, when the
task was decided -- is not given back: Emacs 31 lets the restoring say
so (`window-restore-killed-buffer-windows'), an older one shows another
buffer there.  Nothing happens when the frame went."
  (let ((window-restore-killed-buffer-windows
         (lambda (_frame entries _kind)
           (dolist (entry entries)
             (when (window-live-p (car entry))
               ;; A side window too: the report's is one.
               (let ((ignore-window-parameters t))
                 (ignore-errors (delete-window (car entry)))))))))
    (ignore-errors (set-window-configuration windows))))

(defun harness-ui-patch-review--ediff-ended (review index)
  "Tidy up after the Ediff of REVIEW's file at INDEX.
Its two versions go and the file is seen.  Unless another comparison
takes its place, the frame gets its windows back, the report among
them, drawn again, with point on the next file."
  (let* ((state (harness-ui-patch-review--r-ediff review))
         (files (harness-ui-patch-review--r-files review)))
    (setf (harness-ui-patch-review--r-ediff review) nil)
    (dolist (buffer (list (plist-get state :a) (plist-get state :b)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (harness-ui-patch-review--mark-seen review (nth index files))
    (unless (plist-get state :quiet)
      (when-let* ((windows (plist-get state :windows)))
        (harness-ui-patch-review--restore-windows windows))
      (if (harness-ui-patch-review--r-gone review)
          (harness-ui-patch-review--forget review)
        (harness-ui-patch-review--refresh review)
        (harness-ui-patch-review--goto-row review (min (1+ index) (max 0 (1- (length files))))
                                           (plist-get state :start))))))

(defun harness-ui-patch-review--really-quit ()
  "Quit the Ediff of this control panel without a question.
Its two versions are the review's, which kills them itself."
  (let ((this-command 'ediff-quit)
        (ediff-keep-variants t))
    (ediff-really-quit nil)))

(defun harness-ui-patch-review--end-ediff (review &optional quiet)
  "End the Ediff of REVIEW under way, if there is one.
The frame gets back the windows it had before, unless QUIET: then the
windows stay as they are, for another comparison to take, or because
Ediff is out of sight."
  (let ((control (plist-get (harness-ui-patch-review--r-ediff review) :control)))
    (when (buffer-live-p control)
      (setf (harness-ui-patch-review--r-ediff review)
            (plist-put (harness-ui-patch-review--r-ediff review) :quiet quiet))
      (let ((quit (lambda () (with-current-buffer control (harness-ui-patch-review--really-quit)))))
        (if quiet
            ;; Ediff shows its two versions again as it quits.
            (save-window-excursion (funcall quit))
          (funcall quit))))))

(defun harness-ui-patch-review--comparable (review index step)
  "Return the index of the file Ediff compares STEP files on from INDEX.
Among REVIEW's files; nil when there is none that way."
  (let ((files (harness-ui-patch-review--r-files review))
        (next (+ index step))
        found)
    (while (and (not found) (>= next 0) (< next (length files)))
      (if (harness-ui-patch-review--incomparable (nth next files))
          (setq next (+ next step))
        (setq found next)))
    found))

(defun harness-ui-patch-review--ediff-step (step)
  "Compare the file STEP files on in Ediff, in place of this one."
  (let* ((review (harness-ui-patch-review--current))
         (target (harness-ui-patch-review--comparable review harness-ui-patch-review--index step)))
    (if target
        (harness-ui-patch-review--compare review target)
      (message "That is the %s file; q goes back to the report" (if (> step 0) "last" "first")))))

(defun harness-ui-patch-review-ediff-quit ()
  "Back to the task's report, the windows as they were, without asking."
  (interactive)
  (harness-ui-patch-review--current)
  (harness-ui-patch-review--really-quit))

(defun harness-ui-patch-review-ediff-next-file ()
  "On to the next file of the task's changes, in Ediff."
  (interactive)
  (harness-ui-patch-review--ediff-step 1))

(defun harness-ui-patch-review-ediff-previous-file ()
  "On to the previous file of the task's changes, in Ediff."
  (interactive)
  (harness-ui-patch-review--ediff-step -1))

(defun harness-ui-patch-review--ediff-position ()
  "Return (SIDE . LINE) for the current difference of this Ediff, or nil.
LINE is the difference's last line: on the branch, SIDE :new, unless
the difference only deletes, then at the merge base, SIDE :old."
  (let ((n ediff-current-difference))
    (when (and (integerp n) (>= n 0) (< n ediff-number-of-differences))
      (let ((b-start (ediff-get-diff-posn 'B 'beg n))
            (b-end (ediff-get-diff-posn 'B 'end n)))
        (if (< b-start b-end)
            (cons :new (with-current-buffer ediff-buffer-B (line-number-at-pos (1- b-end) t)))
          (let ((a-end (ediff-get-diff-posn 'A 'end n)))
            (cons :old (with-current-buffer ediff-buffer-A
                         (line-number-at-pos (max (point-min) (1- a-end)) t)))))))))

(defun harness-ui-patch-review--comment-prompt ()
  "Return the prompt for a comment on the current difference of this Ediff."
  (let* ((review (harness-ui-patch-review--current))
         (file (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))
         (where (harness-ui-patch-review--ediff-position)))
    (format "Comment on %s%s: " (harness-ui-patch-review--f-path file)
            (pcase where
              ('nil " as a whole")
              (`(:new . ,line) (format ", line %d" line))
              (`(:old . ,line) (format ", line %d of the merge base" line))))))

(defun harness-ui-patch-review-comment (text)
  "Comment on the current difference with TEXT, read in the minibuffer.
In the Ediff of a task's change.  The comment goes in the feedback box
of the task's report, under the difference's lines quoted from the
diff -- the branch's lines, or the merge base's for a difference that
only deletes -- after any comment there already.  Without a current
difference it is a comment on the file as a whole."
  (interactive (list (read-string (harness-ui-patch-review--comment-prompt))))
  (let* ((review (harness-ui-patch-review--current))
         (file (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review))))
    (if (string-blank-p text)
        (message "No comment")
      (harness-ui-patch-review--add-comment review file (harness-ui-patch-review--ediff-position) text)
      (message "In the report's box: %s on %s; C-c C-c there sends the feedback"
               (harness-ui-patch-review--plural
                (or (cdr (assoc (harness-ui-patch-review--header file) (harness-ui-patch-review--r-counts review))) 0)
                "comment")
               (harness-ui-patch-review--f-path file)))))

;;;; Following the tasks

(defun harness-ui-patch-review--ended (review)
  "REVIEW's task is done, or deleted: drop the review.
An Ediff of it on show stays until q gives the windows back."
  (if (harness-ui-patch-review--ediff-shows-p review)
      (setf (harness-ui-patch-review--r-gone review) t)
    (harness-ui-patch-review--forget review)))

(defun harness-ui-patch-review--on-event (event args)
  "Follow the tasks whose changes are reviewed: EVENT about a task, with ARGS."
  (pcase event
    ((or "task/changed" "task/review")
     (when-let* ((task (car args))
                 (review (gethash (plist-get task :id) harness-ui-patch-review--reviews)))
       (setf (harness-ui-patch-review--r-task review) task)
       ;; Back for review, maybe with more commits: the report open on it
       ;; reads the branch again.
       (when (and (equal event "task/review") (buffer-live-p (harness-ui-patch-review--r-popout review)))
         (harness-ui-patch-review--load review))))
    ("task/done"
     (when-let* ((review (gethash (plist-get (car args) :id) harness-ui-patch-review--reviews)))
       (harness-ui-patch-review--ended review)))
    ("task/deleted"
     (when-let* ((review (gethash (car args) harness-ui-patch-review--reviews)))
       (harness-ui-patch-review--ended review)))))

;;;; Module

(defun harness-ui-patch-review--init ()
  "Show the changes of a task in review in its report."
  (setq harness-ui-patch-review--active t)
  ;; Before the review banner: the changes are read, then the work is
  ;; verified or sent back.
  (add-hook 'harness-ui-report-panel-functions #'harness-ui-patch-review--panel -10)
  (add-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event))

(defun harness-ui-patch-review--shutdown ()
  "Take the changes out of the reports again, ending the Ediffs of them."
  (setq harness-ui-patch-review--active nil)
  (remove-hook 'harness-ui-report-panel-functions #'harness-ui-patch-review--panel)
  (remove-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event)
  (let (popouts)
    (maphash (lambda (_id review)
               (push (harness-ui-patch-review--r-popout review) popouts)
               (harness-ui-patch-review--forget review))
             (copy-hash-table harness-ui-patch-review--reviews))
    (dolist (popout popouts)
      (when (buffer-live-p popout)
        (with-current-buffer popout
          (remove-hook 'after-change-functions #'harness-ui-patch-review--box-changed t))
        (harness-ui-popout-refresh (buffer-local-value 'harness-ui-popout-key popout))))))

(harness-define-module 'ui-patch-review
  :doc "A task's changes in its report: file by file in Ediff, comments quoted in the feedback."
  :requires '(ui ui-report ui-review)
  :init #'harness-ui-patch-review--init
  :shutdown #'harness-ui-patch-review--shutdown)

(provide 'harness-ui-patch-review)
;;; harness-ui-patch-review.el ends here
