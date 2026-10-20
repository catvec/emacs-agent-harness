;;; harness-ui-patch-review.el --- A task's changes in its report: Ediff, and comments quoted in the feedback  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task waiting for review is a patch waiting for its reviewer.  This
;; module puts the patch in the review, in the task's report (the popout
;; [Review Changes] opens on the board and in the session), and reviews it the
;; way a mailing list does: file by file in Ediff, with comments under
;; the lines they are about, quoted from the diff, sent back to the task
;; as its feedback in one go.
;;
;; Under the evidence, above the review banner and its box, the report
;; shows what the task's branch changes against its merge base with the
;; branch it was made from -- what merging it brings in, not what that
;; branch did since -- a tree of the directories and their files:
;;
;;   a file      its status, its name, the lines it adds and deletes,
;;               a mark once it was looked at in Ediff and a firmer one
;;               once it was approved, the comments on it in the box,
;;               and whether it changed since the reviewer's last
;;               comment on it.  RET or a click compares it in Ediff;
;;               n and p move between rows; a approves it, A approves
;;               every file, t shows the files flat instead.  An
;;               approved file need not be looked at again unless the
;;               branch changes it.  Under it, the comments the
;;               reviewer made on it in earlier rounds (see below).
;;   directories the files group under the directories that hold them,
;;               with how many files each holds and the lines they add
;;               and delete.
;;   Ediff       the file at the merge base against the file on the
;;               branch, in the report's frame, the report itself small
;;               at the bottom of it with its box (see below).  The
;;               control panel keeps Ediff's keys and has more: c
;;               comments on the current difference, e goes to the
;;               report's box, a approves the file, N and P go on to the
;;               next or previous file, q comes back to the report as it
;;               was, point on the next file.  n is Ediff's next
;;               difference, and at the last one says the next
;;               difference is the next file: n again opens it.
;;   comments    c reads a comment and puts it in the report's box as a
;;               reply on a mailing list has it: the lines it is about
;;               quoted from the diff with "> ", under their file's
;;               `diff --git' line and a hunk header, a few lines of
;;               context first, the comment after them.  In either
;;               version Ediff compares, c comments on the line at point
;;               instead.  The box is the feedback: edit it, write more,
;;               and C-c C-c sends it all back to the task, as it sends
;;               any feedback.
;;
;; The box stays in sight while Ediff compares the files: the report
;; keeps the bottom of the frame, 30% of it at most
;; (`harness-ui-patch-review-ediff-box-height'), and ends in the box.  A
;; comment made with c shows there as it is made, highlighted for a
;; moment.  To edit the comments or to add to them, e in Ediff goes to the
;; box, point at the end of the comment on the difference -- or, in a
;; version, the line at point -- if there is one, else at the end of the
;; last comment on the file, else at the end of the box; the box is a
;; box, so editing is typing.  C-c C-d in the report goes back to Ediff,
;; which was never left: the comparison, and where in it the reviewer
;; was, are as they were.  Sending the feedback from there ends Ediff
;; and gives the frame back.
;;
;; A task sent back keeps its earlier rounds of feedback, and the review
;; shows the comments in them where they are now, so the history is
;; there to see: under the file in the report, and in Ediff under the
;; line, in the newest version of the file (in the merge base's version
;; for a comment on a removed line), with the round, when it was sent,
;; and what became of the line since.  The feedback says the commit it
;; was written at; the line a comment was on is carried through the
;; diff from that commit to the branch as it is, so a line that moved
;; shows at its new number ("line 44 (was 42)"), and one the task
;; edited where the edit is ("line 44 (changed since)").  A round that
;; does not say which commit it was written at is placed by the lines it
;; quotes.  RET on such a comment in the report compares the file with
;; that line in sight.  What has no file row -- words on the change as a
;; whole, comments on files the branch no longer changes -- stays in a
;; block above the files.  When it was sent back the review also kept
;; the blobs of the branch it was reviewed at, so the next review says
;; for each file whether it changed since the reviewer's last comment on
;; it or stayed the same -- an approved file that changed is approved no
;; more.
;;
;; From a task's session history -- or a board card -- C-c C-d opens the
;; review, even after the task left review, when it shows the changes
;; without the review banner (`harness-ui-patch-review-mode').
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
(require 'seq)
(require 'pulse)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-popout)
(require 'harness-ui-report)

(defvar harness-ui-patch-review--row-map)
(defvar harness-ui-popout--max-height)
(defvar harness-ui-popout-window-parameters)
(defvar harness-ui-popout-min-height)
(defvar harness-ui-report-max-height)
(defvar ediff-window-setup-function)
(defvar ediff-brief-help-message-function)
(defvar ediff-mode-map)
(defvar ediff-after-quit-hook-internal)
(defvar ediff-current-difference)
(defvar ediff-number-of-differences)
(defvar ediff-buffer-A)
(defvar ediff-buffer-B)
(defvar ediff-keep-variants)
(defvar ediff-help-message)
(defvar ediff-whitespace)
(defvar evil-local-mode)
(defvar window-restore-killed-buffer-windows)
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function ediff-setup-windows-plain "ediff-wind" (buffer-a buffer-b buffer-c control-buffer))
(declare-function ediff-really-quit "ediff-util" (reverse-default-keep-variants))
(declare-function ediff-get-diff-posn "ediff-util" (buf-type pos &optional n control-buf))
(declare-function ediff-next-difference "ediff-util" (&optional arg))
(declare-function ediff-set-help-message "ediff-help" ())
(declare-function ediff-indent-help-message "ediff-help" ())
(declare-function ediff-set-help-overlays "ediff-help" ())
(declare-function ediff-multiframe-setup-p "ediff-init" ())
(declare-function evil-normalize-keymaps "evil-core" (&optional state))
(declare-function harness-ui-report-task "harness-ui-report" ())
(declare-function harness-ui-review--task "harness-ui-review" (sid))
(declare-function harness-ui-tasks--task "harness-ui-tasks" (&optional noerror))

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

(defcustom harness-ui-patch-review-ediff-box-height 0.3
  "How much of the frame's height the report takes beside an Ediff.
While Ediff compares a file the report stays at the bottom of the frame,
under the two versions and Ediff's control panel, with its feedback box
at the end in sight: the comments made so far can be read there, and
edited, without leaving Ediff
\(\\<harness-ui-patch-review-lines-mode-map>\\[harness-ui-patch-review-edit-feedback] in Ediff goes to the box).  This is a fraction of the
frame's height, at most; nil takes the report off the frame while Ediff
shows, as the whole frame is Ediff's then."
  :type '(choice (const :tag "Out of sight" nil) number))

(defcustom harness-ui-patch-review-file-tree t
  "Whether a report shows the changed files as a tree.
The directories group the files they hold, with the lines the files
under each add and delete; nil shows every file in a flat list, in the
diff's order.  \\<harness-ui-patch-review--row-map>\\[harness-ui-patch-review-toggle-file-tree]
switches it for the review at point."
  :type 'boolean)

(defface harness-ui-patch-review-plus-face '((t :inherit diff-indicator-added))
  "Counts of added lines, and the status of an added file, in a report.")
(defface harness-ui-patch-review-minus-face '((t :inherit diff-indicator-removed))
  "Counts of deleted lines, and the status of a deleted file, in a report.")
(defface harness-ui-patch-review-seen-face '((t :inherit success))
  "The mark of a file seen in Ediff, in a report.")
(defface harness-ui-patch-review-approved-face '((t :inherit success :weight bold))
  "The mark of a file approved for this review, in a report.")
(defface harness-ui-patch-review-comments-face '((t :inherit bold))
  "The count of comments on a file, in a report.")
(defface harness-ui-patch-review-earlier-face '((t :inherit (italic font-lock-comment-face)))
  "What the reviewer said in an earlier round, under its line in Ediff.")

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
files seen in Ediff, APPROVED those the reviewer accepted, both by
`harness-ui-patch-review--seen-key' -- a file the branch changes again
is neither.  SNAPSHOTTED is how many rounds of the task's feedback
`SNAPSHOTS' covers: a hash table of the round's number to its files'
blobs on the branch when the review was sent back, which says what the
branch changed since the reviewer's comments.  PREVIOUS keeps the
comments of the task's earlier rounds of feedback as
`harness-ui-patch-review--previous-comments' reads them, and PLACEMENTS
where each is in the newest version of its file, by (ROUND . N): the
line it is on there and whether the line moved, changed or stayed
(`harness-ui-patch-review--place').  PLACING is the reading of the
files that places them, while it runs.  TREE, non-nil while the
files show as a tree.  SHOW, non-nil when the review is shown for a
task no longer waiting for one, opened from its session's history.
DIRTY is non-nil when the task's worktree has changes not committed.
LOADING is non-nil while the branch is read, ERROR what the last
reading failed with.  POPOUT is the report the changes show in, COUNTS
the comments its box held when it was drawn last.  EDIFF is the
comparison under way: a plist of :index, the buffers :a, :b and
:control, the :windows to give back as it ends, the first line
:start the report's window showed and the :box window of the report
kept beside it.  GONE is non-nil once the task went, done or deleted,
while its Ediff showed."
  id task dir branch base merge-base tip files
  (seen (make-hash-table :test 'equal))
  (approved (make-hash-table :test 'equal))
  (snapshots (make-hash-table :test 'equal))
  (snapshotted 0)
  previous
  (placements (make-hash-table :test 'equal))
  placing
  (tree harness-ui-patch-review-file-tree)
  show dirty loading error popout counts ediff gone)

(defvar harness-ui-patch-review--reviews (make-hash-table :test 'equal)
  "Task id -> the review of its changes.")

(defvar-local harness-ui-patch-review--review nil
  "In an Ediff control panel of a review, the review.")

(defvar-local harness-ui-patch-review--index nil
  "In an Ediff control panel of a review, the index of the file it compares.")

(defvar-local harness-ui-patch-review--next-file-offer nil
  "In an Ediff control panel, non-nil when the next difference would go on.
It says the last difference was reached once, so a second n goes to the
next file instead of staying there.")

(defvar-local harness-ui-patch-review--box-limit nil
  "In a report shown beside an Ediff, the height limit it had before: (LIMIT).
Nil while the report is not limited.")

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
                     (puthash id (harness-ui-patch-review--review-create
                                  :id id :tree harness-ui-patch-review-file-tree)
                              harness-ui-patch-review--reviews))))
    ;; A review made after the task was sent back has no snapshot of the
    ;; branch its comments were made on: those rounds say only what was
    ;; said, not what changed since.
    (unless (harness-ui-patch-review--r-task review)
      (setf (harness-ui-patch-review--r-snapshotted review)
            (length (plist-get task :feedback))))
    (setf (harness-ui-patch-review--r-task review) task)
    review))

(defun harness-ui-patch-review--window-places (popout)
  "Return where the windows showing POPOUT that are not selected have point.
A list of (WINDOW . OFFSET): OFFSET is where in the feedback box point is,
nil when it is above it.  The report drawing again leaves those windows
without a place."
  (with-current-buffer popout
    (cl-loop for window in (get-buffer-window-list popout nil t)
             unless (eq window (selected-window))
             collect (cons window
                           (and (harness-compose-live-p)
                                (harness-compose-in-p (window-point window))
                                (- (window-point window) harness-compose-start))))))

(defun harness-ui-patch-review--restore-places (popout places)
  "Give the windows showing POPOUT the places PLACES say.
PLACES is what `harness-ui-patch-review--window-places' returned.  A
window that had point in the box shows the box again, ending the
window, point where it was in it; any other shows what it did, from where
the report's drawing put its start."
  (when (buffer-live-p popout)
    (with-current-buffer popout
      (pcase-dolist (`(,window . ,offset) places)
        (when (and (window-live-p window) (eq (window-buffer window) popout))
          (if (and offset (harness-compose-live-p))
              (harness-ui-patch-review--scroll-box window (cons offset offset))
            (set-window-point window (window-start window))))))))

(defun harness-ui-patch-review--refresh (review)
  "Draw the report REVIEW shows in again, when it is open.
Not while it draws: what it draws is current then.  A window beside an
Ediff, which shows the feedback box, goes on showing it."
  (unless harness-ui-patch-review--drawing
    (let ((popout (harness-ui-patch-review--r-popout review)))
      (when (buffer-live-p popout)
        (let ((places (harness-ui-patch-review--window-places popout)))
          (harness-ui-popout-refresh (buffer-local-value 'harness-ui-popout-key popout))
          (harness-ui-patch-review--restore-places popout places))))))

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
       (if (not (eq (harness-ui-patch-review--r-loading review) token))
           review
         (setf (harness-ui-patch-review--r-loading review) nil
               (harness-ui-patch-review--r-dir review) dir
               (harness-ui-patch-review--r-branch review) branch
               (harness-ui-patch-review--r-base review) (plist-get result :base)
               (harness-ui-patch-review--r-merge-base review) (plist-get result :merge-base)
               (harness-ui-patch-review--r-tip review) (plist-get result :tip)
               (harness-ui-patch-review--r-files review) (plist-get result :files)
               (harness-ui-patch-review--r-dirty review) (plist-get result :dirty))
         (harness-ui-patch-review--refresh review)
         ;; The report is there; where the earlier comments are now, in the
         ;; files just read, comes a moment later.
         (harness-ui-patch-review--place-previous review)))
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

(defun harness-ui-patch-review--approved-p (review file)
  "Non-nil when FILE of REVIEW was approved by the reviewer.
An approved file the branch changed again is not approved."
  (gethash (harness-ui-patch-review--seen-key file)
           (harness-ui-patch-review--r-approved review)))

(defun harness-ui-patch-review--approve (review file &optional approved)
  "Mark FILE of REVIEW approved, or not when APPROVED is nil.
Approving a file marks it seen too: it is reviewed and accepted."
  (when file
    (let ((key (harness-ui-patch-review--seen-key file)))
      (if approved
          (progn (puthash key t (harness-ui-patch-review--r-approved review))
                 (harness-ui-patch-review--mark-seen review file))
        (remhash key (harness-ui-patch-review--r-approved review))))))

(defun harness-ui-patch-review-approve ()
  "Approve the file of the row at point, or stop approving it.
An approved file need not be reviewed again unless the branch changes
it: the approval follows the file's path and blob, as being seen does."
  (interactive)
  (pcase-let* ((`(,review . ,index) (or (harness-ui-patch-review--at-point)
                                        (user-error "No file on this line")))
               (file (nth index (harness-ui-patch-review--r-files review))))
    (let ((approved (not (harness-ui-patch-review--approved-p review file))))
      (harness-ui-patch-review--approve review file approved)
      (harness-ui-patch-review--refresh review)
      (message "%s %s" (if approved "Approved" "No longer approved")
               (harness-ui-patch-review--f-path file)))))

(defun harness-ui-patch-review-approve-all ()
  "Approve every file of the review at point.
A file the branch changes again loses its approval with the change."
  (interactive)
  (let* ((review (or (harness-ui-patch-review--review-here)
                     (user-error "No changes here to approve")))
         (files (harness-ui-patch-review--r-files review)))
    (dolist (file files) (harness-ui-patch-review--approve review file t))
    (harness-ui-patch-review--refresh review)
    (message "Approved all %s"
             (harness-ui-patch-review--plural (length files) "file"))))

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
  (harness-ui-patch-review--unlimit-box (harness-ui-patch-review--r-popout review))
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

(defun harness-ui-patch-review--header-path (review header)
  "Return the path HEADER names in REVIEW's files, or the path it reads as.
HEADER is a `diff --git' line, as the feedback quotes it.  A file the
diff no longer holds -- deleted, or renamed away -- has only its header
to go by."
  (or (when-let* ((file (cl-find header (harness-ui-patch-review--r-files review)
                                 :key #'harness-ui-patch-review--header :test #'equal)))
        (harness-ui-patch-review--f-path file))
      (when (and (stringp header)
                 (string-match "\\`diff --git a/\\(.+?\\) b/\\(.+\\)\\'" header))
        (match-string 2 header))))

(defun harness-ui-patch-review--comment-location (comment)
  "Return (SIDE . LINE) for COMMENT, a line of the quote's comment.
SIDE is :new for the branch's line, :old for the merge base's; nil when
the comment is on the file as a whole, or on a line the quote does not
number."
  (pcase (plist-get comment :quoted-line)
    ('added (and (plist-get comment :new) (cons :new (plist-get comment :new))))
    ('removed (and (plist-get comment :old) (cons :old (plist-get comment :old))))
    ('context (and (plist-get comment :new) (cons :new (plist-get comment :new))))
    (_ nil)))

(defconst harness-ui-patch-review--on-line-regexp
  "\\`On line \\([0-9]+\\)\\( of the merge base\\)?: ?"
  "What a comment on a line the diff does not hold starts with.
`harness-ui-patch-review--put-comment' writes it: the comment goes under
the nearest line the diff has, and this says which line it is about.")

(defun harness-ui-patch-review--quote-content (text)
  "Return the line the quote line TEXT, one of the box's, quotes.
TEXT starts with \">\", then the diff's own line: its mark (a space, +
or -) and the line."
  (let ((diff (substring text (if (string-prefix-p "> " text) 2 1))))
    (if (string-empty-p diff) "" (substring diff 1))))

(defun harness-ui-patch-review--comments-in-text (review text)
  "Return the comments TEXT, a round of feedback, holds.
Each is a plist: :file, the header it quotes (nil for words on no file
in particular), :path what `harness-ui-patch-review--header-path' makes
of it, :text the comment, and :where (SIDE . LINE), or nil for the file
as a whole.  :quote holds the lines of the diff quoted just above it, a
few at most, as (KIND . LINE) -- KIND `context', `added' or `removed' --
the last being the line it is on; :approx is non-nil when the comment
says itself which line it is on (\"On line 57: \") and that line is not
the quoted one."
  (let ((lines (harness-ui-patch-review--parse-text text))
        (previous nil) (recent nil) (block nil) (blocks nil))
    (cl-flet ((finish ()
                (when block
                  (let ((comment (plist-put block :text
                                            (string-trim
                                             (mapconcat #'identity
                                                        (nreverse (plist-get block :texts)) "\n")))))
                    (setq comment (plist-put comment :where
                                             (harness-ui-patch-review--comment-location comment)))
                    (when (string-match harness-ui-patch-review--on-line-regexp
                                        (plist-get comment :text))
                      (setq comment (plist-put comment :where
                                               (cons (if (match-string 2 (plist-get comment :text)) :old :new)
                                                     (string-to-number (match-string 1 (plist-get comment :text))))))
                      (setq comment (plist-put comment :approx t))
                      (setq comment (plist-put comment :text
                                               (substring (plist-get comment :text) (match-end 0)))))
                    (setq comment (plist-put comment :path
                                             (harness-ui-patch-review--header-path
                                              review (plist-get comment :file))))
                    (when (and (not (string-empty-p (plist-get comment :text)))
                               ;; The line this module puts before the
                               ;; first quote is no comment of the user's.
                               (not (and (null (plist-get comment :file))
                                         (string-match-p
                                          "\\`My comments on the diff of your branch "
                                          (plist-get comment :text)))))
                      (push comment blocks)))
                  (setq block nil))))
      (dolist (line lines)
        (pcase (plist-get line :type)
          ('quote
           (finish)
           (setq previous line)
           (pcase (plist-get line :line)
             ;; A new file or hunk starts a new run of quoted lines.
             ((or 'file 'hunk) (setq recent nil))
             ((or 'context 'added 'removed)
              (push (cons (plist-get line :line)
                          (harness-ui-patch-review--quote-content (plist-get line :text)))
                    recent)
              (when (> (length recent) 8) (setq recent (seq-take recent 8))))))
          ('comment
           (unless block
             (setq block (list :file (plist-get line :file)
                               :new (plist-get previous :new)
                               :old (plist-get previous :old)
                               :quoted-line (plist-get previous :line)
                               :quote (reverse recent)
                               :texts nil)))
           (push (plist-get line :text) (plist-get block :texts)))
          (_ (finish))))
      (finish))
    (nreverse blocks)))

(defun harness-ui-patch-review--previous-comments (review)
  "Return the task's earlier rounds of feedback and the comments in them.
A list, oldest first, of plists :round (0 for the first), :at when it
was sent, and :comments as `harness-ui-patch-review--comments-in-text'
gives them, each with its :round, its :at, its place in its round, :n,
the :tip it says the branch was at (`harness-ui-patch-review--round-tip')
and its :target, the file of the review's it is on, if any.
A round whose words name no file is still there: it is a comment on the
change as a whole.  The answer is kept for as long as the task's
feedback and the files read stay the same."
  (let* ((feedback (plist-get (harness-ui-patch-review--r-task review) :feedback))
         (files (harness-ui-patch-review--r-files review))
         (kept (harness-ui-patch-review--r-previous review)))
    (if (and kept (eq (car (car kept)) feedback) (eq (cdr (car kept)) files))
        (cdr kept)
      (let* ((by-path (make-hash-table :test 'equal))
             (by-old-path (make-hash-table :test 'equal))
             (rounds
              (progn
                (dolist (file files)
                  (puthash (harness-ui-patch-review--f-path file) file by-path)
                  (when-let* ((old (harness-ui-patch-review--f-old-path file)))
                    (unless (gethash old by-old-path) (puthash old file by-old-path))))
                (cl-loop for round in feedback for index from 0
                         for at = (plist-get round :at)
                         for tip = (harness-ui-patch-review--round-tip (or (plist-get round :text) ""))
                         for comments = (cl-loop for comment in (harness-ui-patch-review--comments-in-text
                                                                 review (or (plist-get round :text) ""))
                                                 for n from 0
                                                 for path = (plist-get comment :path)
                                                 collect (append comment
                                                                 (list :round index :at at :n n :tip tip
                                                                       :target (and path (or (gethash path by-path)
                                                                                             (gethash path by-old-path))))))
                         when comments
                         collect (list :round index :at at :tip tip :comments comments)))))
        (setf (harness-ui-patch-review--r-previous review) (cons (cons feedback files) rounds))
        rounds))))

(defun harness-ui-patch-review--comment-file (_review comment)
  "Return the file of the review's changes that COMMENT, an earlier one, is on.
Nil for a comment on no file, and for one on a file the branch no
longer changes -- reverted, say -- or while the branch is not read.
COMMENT is one of `harness-ui-patch-review--previous-comments'."
  (plist-get comment :target))

(defun harness-ui-patch-review--file-comments (review file)
  "Return the earlier comments on FILE of REVIEW, oldest first."
  (cl-loop for round in (harness-ui-patch-review--previous-comments review)
           append (cl-loop for comment in (plist-get round :comments)
                           when (eq file (harness-ui-patch-review--comment-file review comment))
                           collect comment)))

(defun harness-ui-patch-review--comment-key (comment)
  "Return what names the earlier COMMENT among the task's feedback."
  (cons (plist-get comment :round) (plist-get comment :n)))

;;;;; Where an earlier comment is now

(defconst harness-ui-patch-review--place-limit 3000000
  "The longest file, in characters, whose lines earlier comments are looked for in.")

(defun harness-ui-patch-review--lines-of (text)
  "Return the lines of TEXT as a vector, without their newlines."
  (if (string-empty-p text)
      (vector)
    (vconcat (split-string (if (string-suffix-p "\n" text) (substring text 0 -1) text) "\n"))))

(defun harness-ui-patch-review--side-quote (comment side)
  "Return the lines of the file on SIDE that COMMENT's quote shows, or nil.
SIDE is :new for the branch's version, :old for the merge base's.  The
last of the lines is the one the comment is on; nil when the quote does
not end on a line of SIDE."
  (let* ((kinds (if (eq side :old) '(context removed) '(context added)))
         (quote (plist-get comment :quote)))
    (and quote (memq (car (car (last quote))) kinds)
         (cl-remove-if-not (lambda (entry) (memq (car entry) kinds)) quote))))

(defun harness-ui-patch-review--find-line (lines quote hint)
  "Return (LINE . SCORE) for where QUOTE is in LINES, or nil.
LINES is a vector of the lines of a file, QUOTE the lines (KIND . TEXT)
of it that were quoted, the last being the one that matters.  LINE is
the number of the line, from 1, that is that last line; where several
are, the one with most of the quoted lines above it just above it too
\(SCORE of them), then the one nearest the line HINT, where it was.
Blanks at the end of a line count for nothing."
  (let* ((target (string-trim-right (cdr (car (last quote)))))
         (before (mapcar (lambda (entry) (string-trim-right (cdr entry)))
                         (reverse (butlast quote))))
         best best-score best-distance)
    (dotimes (i (length lines))
      (when (equal target (string-trim-right (aref lines i)))
        (let ((score 0))
          (while (and (< score (length before)) (>= (- i score 1) 0)
                      (equal (nth score before)
                             (string-trim-right (aref lines (- i score 1)))))
            (cl-incf score))
          (let ((distance (abs (- (1+ i) hint))))
            (when (or (null best) (> score best-score)
                      (and (= score best-score) (< distance best-distance)))
              (setq best (1+ i) best-score score best-distance distance))))))
    (and best (cons best best-score))))

(defconst harness-ui-patch-review--tip-regexp
  "My comments on the diff of your branch .*? (at \\([0-9a-f]\\{7,40\\}\\)) against "
  "The line `harness-ui-patch-review--attribution' writes, up to the commit.")

(defun harness-ui-patch-review--round-tip (text)
  "Return the commit the branch was at when the feedback TEXT was written, or nil.
The feedback names it, in the line before its first quote
\(`harness-ui-patch-review--attribution')."
  (when (string-match harness-ui-patch-review--tip-regexp text)
    (match-string 1 text)))

(defun harness-ui-patch-review--diff-hunks (diff)
  "Return the hunks of DIFF, as `git diff -U0' writes it, in order.
Each is (OLD-START OLD-COUNT NEW-START NEW-COUNT)."
  (let (hunks)
    (dolist (line (split-string diff "\n"))
      (when (string-match "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@" line)
        (push (list (string-to-number (match-string 1 line))
                    (if (match-string 2 line) (string-to-number (match-string 2 line)) 1)
                    (string-to-number (match-string 3 line))
                    (if (match-string 4 line) (string-to-number (match-string 4 line)) 1))
              hunks)))
    (nreverse hunks)))

(defun harness-ui-patch-review--map-line (hunks line)
  "Return (NEW . STATUS) for old LINE, once HUNKS have changed the file.
HUNKS are as `harness-ui-patch-review--diff-hunks' gives them.  NEW is the
line's number in the new file, STATUS `same' where nothing before it
changed the numbering, `moved' where lines were added or deleted before
it, and `changed' for a line in a hunk, whose NEW is the line in the same
place among the lines that replaced it, the last of them at most."
  (let ((offset 0) inside)
    (cl-loop for (start count new-start new-count) in hunks
             do (let ((first (if (zerop count) (1+ start) start))
                      (last (if (zerop count) start (+ start count -1))))
                  (cond
                   ((< line first) (cl-return))
                   ((and (> count 0) (<= line last))
                    ;; The same place in what replaced the lines, the last
                    ;; of them when there are fewer.
                    (setq inside (if (> new-count 0)
                                     (+ new-start (min (- line start) (1- new-count)))
                                   (max 1 new-start)))
                    (cl-return))
                   ;; Past the hunk: its lines come to the new ones that follow.
                   (t (setq offset (- (if (zerop new-count) (1+ new-start) (+ new-start new-count))
                                      (if (zerop count) (1+ start) (+ start count))))))))
    (cond (inside (cons inside 'changed))
          ((zerop offset) (cons line 'same))
          (t (cons (+ line offset) 'moved)))))

(defun harness-ui-patch-review--read-hunks (review file tip path)
  "Return a promise of how FILE of REVIEW changed since the commit TIP.
PATH is the file's path at TIP.  The promise resolves to `same' when the
file is as it was, else the hunks of the change
\(`harness-ui-patch-review--diff-hunks'), or nil when that cannot be told:
TIP is not in the repository, or not the file there."
  (let ((dir (harness-ui-patch-review--r-dir review))
        (new (harness-ui-patch-review--f-new-blob file)))
    (harness-catch
     (harness-then
      (harness-ui-patch-review--git dir "rev-parse" "--verify" "--quiet" (concat tip ":" path))
      (lambda (out)
        (let ((old (string-trim (harness-ui-patch-review--decode out))))
          (cond
           ;; The branch has no such file any more: no line to follow.
           ((null new) nil)
           ((equal old new) 'same)
           (t (harness-then
               (harness-ui-patch-review--git dir "diff" "-U0" "--no-color" "--no-ext-diff" "--no-textconv" old new)
               (lambda (diff) (harness-ui-patch-review--diff-hunks (harness-ui-patch-review--decode diff)))))))))
     (lambda (_) nil))))

(defun harness-ui-patch-review--place (comment old-lines new-lines unchanged &optional hunks)
  "Return where COMMENT, an earlier comment with a line, is in the newest version.
OLD-LINES and NEW-LINES are vectors of the lines of its file at the
merge base and on the branch, nil for a side that was not read.
UNCHANGED is non-nil when the branch's version is as it was when the
comment was made.  HUNKS says how the branch's version changed since
the commit the comment was made at: `same', or the hunks
\(`harness-ui-patch-review--diff-hunks') of the change.  The answer is a
plist: :side, :line where it is now (nil when the file has no such line
any more) and :was where it was, and :status:
  same     the line is where it was
  moved    the line the comment is on is now at :line
  changed  the line was edited, or is gone: :line is where the lines that
           replaced it start, or where it was, as near as the file allows
  unknown  there is no telling: the file was not read, or the comment
           does not say which line it is on."
  (pcase-let* ((`(,side . ,was) (plist-get comment :where))
               (lines (if (eq side :old) old-lines new-lines))
               ;; What the hunks make of the line, on the branch's side.
               (mapped (and (eq side :new) (consp hunks)
                            (harness-ui-patch-review--map-line hunks was)))
               (clamped (lambda ()
                          (if mapped
                              (car mapped)
                            (and (> (length lines) 0) (max 1 (min was (length lines))))))))
    (cond
     ((and (eq side :new) (or unchanged (eq hunks 'same)))
      (list :side side :line was :was was :status 'same))
     ((and mapped (memq (cdr mapped) '(same moved)))
      (list :side side :line (car mapped) :was was :status (cdr mapped)))
     ((null lines)
      (list :side side :line (if mapped (car mapped) was) :was was :status (if mapped 'changed 'unknown)))
     ((zerop (length lines)) (list :side side :line nil :was was :status 'changed))
     (t
      (let* ((quote (and (not (plist-get comment :approx))
                         (harness-ui-patch-review--side-quote comment side)))
             (found (and quote (harness-ui-patch-review--find-line lines quote (if mapped (car mapped) was)))))
        (cond
         ;; Edited, yet the same line is somewhere: moved there.
         (found (list :side side :line (car found) :was was
                      :status (if (= (car found) was) 'same 'moved)))
         ((or quote mapped)
          (list :side side :line (funcall clamped) :was was :status 'changed))
         (t (list :side side :line (funcall clamped) :was was :status 'unknown))))))))

(defun harness-ui-patch-review--unchanged-since-p (review file comment)
  "Non-nil when FILE of REVIEW is as it was on the branch at COMMENT's round.
That is, the blob kept for the round (`harness-ui-patch-review--snapshot')
is the blob it has now."
  (let ((snapshot (gethash (plist-get comment :round) (harness-ui-patch-review--r-snapshots review))))
    (and snapshot
         (let ((kept (assoc (plist-get comment :path) snapshot)))
           (and kept (equal (cdr kept) (harness-ui-patch-review--f-new-blob file)))))))

(defun harness-ui-patch-review--place-comments (review file old-text new-text &optional hunks)
  "Place the earlier comments on FILE of REVIEW in its newest version.
OLD-TEXT and NEW-TEXT are the file at the merge base and on the branch,
nil for one not read.  HUNKS is an alist of a round's number to how the
file changed since that round, as `harness-ui-patch-review--place' takes
it.  Return an alist of (KEY . PLACEMENT) for the comments on a line,
KEY as `harness-ui-patch-review--comment-key' gives it, PLACEMENT as
`harness-ui-patch-review--place' does."
  (let ((old-lines (and old-text (harness-ui-patch-review--lines-of old-text)))
        (new-lines (and new-text (harness-ui-patch-review--lines-of new-text))))
    (cl-loop for comment in (harness-ui-patch-review--file-comments review file)
             when (plist-get comment :where)
             collect (cons (harness-ui-patch-review--comment-key comment)
                           (harness-ui-patch-review--place
                            comment old-lines new-lines
                            (harness-ui-patch-review--unchanged-since-p review file comment)
                            (cdr (assq (plist-get comment :round) hunks)))))))

(defun harness-ui-patch-review--placement (review comment)
  "Return where REVIEW has COMMENT, an earlier one, in the newest version, or nil."
  (gethash (harness-ui-patch-review--comment-key comment)
           (harness-ui-patch-review--r-placements review)))

(defun harness-ui-patch-review--place-previous (review)
  "Place REVIEW's earlier comments in the newest version of their files.
Reads from the repository the files that have such comments, and how
they changed since the commit each round of comments was made at, those
not known to be as they were already; then draws the report again.
Return a promise of REVIEW; it never rejects."
  (let ((token (list 'placing))
        jobs)
    (setf (harness-ui-patch-review--r-placing review) token)
    (dolist (file (harness-ui-patch-review--r-files review))
      (let* ((comments (cl-remove-if-not (lambda (c) (plist-get c :where))
                                         (harness-ui-patch-review--file-comments review file)))
             (changed (cl-remove-if (lambda (c) (harness-ui-patch-review--unchanged-since-p review file c))
                                    (cl-remove-if-not (lambda (c) (eq (car (plist-get c :where)) :new))
                                                      comments)))
             (old (cl-some (lambda (c) (eq (car (plist-get c :where)) :old)) comments))
             ;; The rounds with a comment on the branch's side whose file may
             ;; have changed: (ROUND TIP PATH) each, once.
             (rounds (let (seen)
                       (dolist (c changed)
                         (when (and (plist-get c :tip) (not (assq (plist-get c :round) seen)))
                           (push (list (plist-get c :round) (plist-get c :tip) (plist-get c :path)) seen)))
                       (nreverse seen))))
        (when (or changed old)
          (push (list file old (and changed t) rounds) jobs))))
    (setq jobs (nreverse jobs))
    (let ((read (lambda (review sha wanted file)
                  ;; Not a binary file, nor one too large to search.  No blob
                  ;; is a file without that side: no lines.
                  (if (and wanted (not (harness-ui-patch-review--f-binary file)))
                      (harness-catch
                       (harness-then (harness-ui-patch-review--blob review sha)
                                     (lambda (text)
                                       (and (<= (length text) harness-ui-patch-review--place-limit) text)))
                       (lambda (_) nil))
                    (harness-resolved nil)))))
      (harness-then
       (harness-all
        (mapcar (lambda (job)
                  (pcase-let ((`(,file ,old ,new ,rounds) job))
                    (harness-all
                     (list (funcall read review (harness-ui-patch-review--f-old-blob file) old file)
                           (funcall read review (harness-ui-patch-review--f-new-blob file) new file)
                           (harness-all
                            (mapcar (lambda (round)
                                      (harness-then
                                       (harness-ui-patch-review--read-hunks
                                        review file (nth 1 round) (nth 2 round))
                                       (lambda (hunks) (cons (nth 0 round) hunks))))
                                    rounds))))))
                jobs))
       (lambda (results)
         (when (eq (harness-ui-patch-review--r-placing review) token)
           (let ((table (make-hash-table :test 'equal)))
             (cl-mapc (lambda (job result)
                        (dolist (entry (harness-ui-patch-review--place-comments
                                        review (car job) (nth 0 result) (nth 1 result) (nth 2 result)))
                          (puthash (car entry) (cdr entry) table)))
                      jobs results)
             (setf (harness-ui-patch-review--r-placements review) table
                   (harness-ui-patch-review--r-placing review) nil)
             (harness-ui-patch-review--refresh review)))
         review)
       (lambda (err)
         (harness-log 'warn "patch review: could not place the earlier comments: %s"
                      (harness-error-message err))
         review)))))

(defun harness-ui-patch-review--snapshot (review &optional task)
  "Keep the branch's files' blobs for each round of feedback not kept yet.
When REVIEW's task is sent back with feedback, its branch's files are
as the reviewer saw them: the next review compares the branch with this
to say which files changed since the comments and which stayed the
same.  TASK is the record that has the new round, when REVIEW's own is
the one before it."
  (let ((feedback (plist-get (or task (harness-ui-patch-review--r-task review)) :feedback))
        (files (harness-ui-patch-review--r-files review)))
    (when (> (length feedback) (harness-ui-patch-review--r-snapshotted review))
      (if (null files)
          ;; Nothing was read: these rounds have no snapshot to be exact
          ;; with, and later rounds must not be taken for them.
          (setf (harness-ui-patch-review--r-snapshotted review) (length feedback))
        (let ((blobs (mapcar (lambda (file)
                               (cons (harness-ui-patch-review--f-path file)
                                     (harness-ui-patch-review--f-new-blob file)))
                             files)))
          (cl-loop for index from (harness-ui-patch-review--r-snapshotted review)
                   below (length feedback)
                   do (puthash index blobs (harness-ui-patch-review--r-snapshots review)))
          (setf (harness-ui-patch-review--r-snapshotted review) (length feedback)))))))

(defun harness-ui-patch-review--latest-comment (review file)
  "Return (ROUND . PATH) for the latest earlier comment on FILE of REVIEW.
PATH is the path the comment named then: a file renamed meanwhile has
its old path there.  Nil when no earlier comment was on it."
  (let ((path (harness-ui-patch-review--f-path file))
        (old (harness-ui-patch-review--f-old-path file))
        found)
    (dolist (round (harness-ui-patch-review--previous-comments review))
      (dolist (comment (plist-get round :comments))
        (when (and (plist-get comment :path)
                   (or (equal (plist-get comment :path) path)
                       (and old (equal (plist-get comment :path) old))))
          (setq found (cons (plist-get round :round) (plist-get comment :path))))))
    found))

(defun harness-ui-patch-review--since-comment (review file)
  "Return `changed', `same', or nil for FILE of REVIEW since its last comment.
Nil when no earlier comment named it, or when the review kept no
snapshot of the branch the comment was made on."
  (when-let* ((found (harness-ui-patch-review--latest-comment review file)))
    (let ((snapshot (gethash (car found) (harness-ui-patch-review--r-snapshots review))))
      (when (and snapshot (assoc (cdr found) snapshot))
        (if (equal (cdr (assoc (cdr found) snapshot))
                   (harness-ui-patch-review--f-new-blob file))
            'same
          'changed)))))

(defun harness-ui-patch-review--since-comment-text (review file)
  "Return what to say of FILE of REVIEW since its last comment, or nil."
  (pcase (harness-ui-patch-review--since-comment review file)
    ('same (propertize "same since your comment" 'face 'harness-dim-face))
    ('changed (propertize "changed since your comment" 'face 'warning))))

(defun harness-ui-patch-review--round-time (comment)
  "Return when the round of the earlier COMMENT was sent, as a string, or nil."
  (when-let* ((at (plist-get comment :at)))
    (format-time-string "%Y-%m-%d %H:%M" at)))

(defun harness-ui-patch-review--where-text (review comment)
  "Return where the earlier COMMENT is, as REVIEW's report says it, or nil.
That is its line in the newest version of its file: \"line 44\", with
\"(was 42)\" when it moved, \"(changed since)\" when the line it was on
is not there as it was.  A comment on a file as a whole has no line.
Until the files are read, the line the comment was made on."
  (when-let* ((where (plist-get comment :where)))
    (let* ((placement (harness-ui-patch-review--placement review comment))
           (side (if placement (plist-get placement :side) (car where)))
           (line (if placement (plist-get placement :line) (cdr where)))
           (was (if placement (plist-get placement :was) (cdr where)))
           (of (if (eq side :old) " of the merge base" "")))
      (pcase (and placement (plist-get placement :status))
        ('moved (format "line %d%s (was %d)" line of was))
        ('changed (if line
                      (format "line %d%s (changed since)" line of)
                    "its line is gone"))
        (_ (format "line %d%s" (or line was) of))))))

(defun harness-ui-patch-review--previous-section (review)
  "Return REVIEW's earlier comments that have no file row, or nil.
The comments on a file the report shows are under its row
\(`harness-ui-patch-review--comment-rows'); what stays here are the
words on the change as a whole and the comments on files the branch no
longer changes, round by round, with a line on how many comments there
are.  Nil when there were no earlier rounds."
  (let* ((rounds (harness-ui-patch-review--previous-comments review))
         (total (apply #'+ (mapcar (lambda (round) (length (plist-get round :comments))) rounds)))
         (loose (mapcar (lambda (round)
                          (cons round (cl-remove-if (lambda (comment)
                                                      (harness-ui-patch-review--comment-file review comment))
                                                    (plist-get round :comments))))
                        rounds))
         (shown (- total (apply #'+ (mapcar (lambda (entry) (length (cdr entry))) loose)))))
    (when rounds
      (concat
       (propertize "Previous comments" 'face 'harness-label-face)
       "   "
       (propertize (format "%s in %s%s"
                           (harness-ui-patch-review--plural total "comment")
                           (harness-ui-patch-review--plural (length rounds) "round")
                           (if (> shown 0) (format ", %d under their files below" shown) ""))
                   'face 'harness-dim-face)
       "\n"
       (mapconcat
        (lambda (entry)
          (let ((round (car entry)))
            (if (null (cdr entry))
                ""
              (concat
               "  " (propertize (format "Round %d%s" (1+ (plist-get round :round))
                                        (if-let* ((at (plist-get round :at)))
                                            (format " · %s" (format-time-string "%Y-%m-%d %H:%M" at))
                                          ""))
                                'face 'bold)
               "\n"
               (mapconcat
                (lambda (comment)
                  (let ((where (harness-ui-patch-review--where-text review comment)))
                    (concat
                     "    "
                     (propertize (or (plist-get comment :path) "the change as a whole")
                                 'face 'bold)
                     (when where (concat ", " where))
                     (when (and (plist-get comment :path)
                                (harness-ui-patch-review--r-files review))
                       (propertize " (not changed any more)" 'face 'harness-dim-face))
                     ": "
                     (harness-truncate-end (string-replace "\n" " " (plist-get comment :text)) 160)
                     "\n")))
                (cdr entry) "")))))
        loose "")
       "\n"))))

(defun harness-ui-patch-review--comment-rows (review file index indent)
  "Return the rows of the earlier comments on FILE of REVIEW.
FILE is at INDEX of the review's files.  Each comment is a line of its
own, INDENT then \"↳\", the round, where the comment is in the newest
version of the file, and what it says; RET on it compares the file in
Ediff with that line in sight.  Empty without earlier comments."
  (mapconcat
   (lambda (comment)
     (let* ((where (harness-ui-patch-review--where-text review comment))
            (placement (harness-ui-patch-review--placement review comment))
            (row (concat indent
                         (propertize "↳ " 'face 'harness-dim-face)
                         (propertize (format "Round %d%s" (1+ (plist-get comment :round))
                                             (if where (concat " · " where) ""))
                                     'face 'harness-dim-face)
                         ": "
                         (harness-truncate-end (string-replace "\n" " " (plist-get comment :text)) 140))))
       (add-text-properties
        0 (length row)
        (list 'harness-ui-patch-review-file index
              'harness-ui-patch-review-task (harness-ui-patch-review--r-id review)
              'harness-ui-patch-review-where
              (and (plist-get comment :where)
                   (cons (if placement (plist-get placement :side) (car (plist-get comment :where)))
                         (or (and placement (plist-get placement :line))
                             (cdr (plist-get comment :where)))))
              'mouse-face 'highlight
              'help-echo (format "Round %d%s\n%s\nRET or a click: compare %s in Ediff%s"
                                 (1+ (plist-get comment :round))
                                 (if-let* ((time (harness-ui-patch-review--round-time comment)))
                                     (concat ", " time)
                                   "")
                                 (plist-get comment :text)
                                 (harness-ui-patch-review--f-path file)
                                 (if (plist-get comment :where) " at this line" ""))
              'wrap-prefix (concat indent "  ")
              'keymap harness-ui-patch-review--row-map)
        row)
       (concat row "\n")))
   (harness-ui-patch-review--file-comments review file) ""))

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
`harness-ui-patch-review--add-comment'.  Return (START . END), what was
put in: the comment, and the lines of the quote it brought, if any."
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
        (let* ((comment (harness-ui-patch-review--comment-text text))
               (start (harness-ui-patch-review--insert-comment (plist-get exact :start) comment)))
          (cons start (+ start (length comment))))
      (let* ((excerpt (and side (harness-ui-patch-review--excerpt file side number quoted)))
             (comment (harness-ui-patch-review--comment-text
                       (if (or (null side) (plist-get excerpt :exact))
                           text
                         (format "On line %d%s: %s" number (if (eq side :old) " of the merge base" "") text))))
             (after (plist-get excerpt :after)))
        (cl-flet ((comment-at (start) (cons start (+ start (length comment))))
                  (block-at (start block) (cons start (+ start (length block)))))
          (cond
           ;; Nothing more to quote: under the line quoted last.
           ((and after (string-empty-p (plist-get excerpt :text)))
            (comment-at (harness-ui-patch-review--insert-comment (plist-get after :start) comment)))
           ;; On from where the quote of the hunk stops.
           (after
            (let ((block (concat (plist-get excerpt :text) "\n" comment "\n")))
              (block-at (harness-ui-patch-review--insert-block
                         (harness-ui-patch-review--after-comments (plist-get after :start)) block)
                        block)))
           ;; On the file as a whole, or a file the diff has no line of:
           ;; under its first line.
           ((and (null excerpt) quoted)
            (comment-at (harness-ui-patch-review--insert-comment (plist-get (car quoted) :start) comment)))
           (t
            (let ((block (concat (unless quoted
                                   (concat (unless (cl-some (lambda (line) (plist-get line :file)) lines)
                                             (concat (harness-ui-patch-review--attribution review) "\n\n"))
                                           "> " header "\n"))
                                 (plist-get excerpt :text)
                                 "\n" comment "\n")))
              (block-at (harness-ui-patch-review--insert-block
                         (harness-ui-patch-review--block-position review file lines quoted excerpt) block)
                        block)))))))))

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
  (let ((popout (harness-ui-patch-review--feedback-box review))
        offset)
    (with-current-buffer popout
      (let ((inhibit-read-only t)
            (start (save-excursion
                     (save-restriction
                       (narrow-to-region harness-compose-start harness-compose-end)
                       (harness-ui-patch-review--put-comment review file where text)))))
        ;; Where in the box: the box moves when the report is drawn again.
        (setq offset (and (consp start)
                          (cons (- (car start) harness-compose-start)
                                (- (cdr start) harness-compose-start)))))
      (harness-compose-update-placeholder))
    (harness-ui-patch-review--refresh review)
    (harness-ui-patch-review--show-comment review offset)))

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
  (define-key map (kbd "p") #'harness-ui-patch-review-previous-file)
  (define-key map (kbd "a") #'harness-ui-patch-review-approve)
  (define-key map (kbd "A") #'harness-ui-patch-review-approve-all)
  (define-key map (kbd "t") #'harness-ui-patch-review-toggle-file-tree))

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

(defun harness-ui-patch-review--row (review file index width counts &optional indent label)
  "Return the row of FILE of REVIEW, at INDEX of its files.
The path is padded to WIDTH; COUNTS are the box's comments.  INDENT is
what the row starts with, \"  \" by default; LABEL names the file, its
path by default."
  (let* ((comments (or (cdr (assoc (harness-ui-patch-review--header file) counts)) 0))
         (indent (or indent "  "))
         (label (or label (harness-ui-patch-review--path-label file)))
         (since (harness-ui-patch-review--since-comment-text review file))
         (row (concat indent
                      (cond ((harness-ui-patch-review--approved-p review file)
                             (propertize "✔" 'face 'harness-ui-patch-review-approved-face))
                            ((harness-ui-patch-review--seen-p review file)
                             (propertize "✓" 'face 'harness-ui-patch-review-seen-face))
                            (t " "))
                      " "
                      (propertize (harness-ui-patch-review--f-status file)
                                  'face (harness-ui-patch-review--status-face file))
                      "  "
                      (string-pad (harness-truncate-middle label width) width)
                      "  "
                      (harness-ui-patch-review--change-label file)
                      (if (> comments 0)
                          (concat "   " (propertize (harness-ui-patch-review--plural comments "comment")
                                                    'face 'harness-ui-patch-review-comments-face))
                        "")
                      (if since (concat "   " since) ""))))
    (add-text-properties 0 (length row)
                         (list 'harness-ui-patch-review-file index
                               'harness-ui-patch-review-task (harness-ui-patch-review--r-id review)
                               'mouse-face 'highlight
                               'help-echo (format "%s\nRET or a click: compare it in Ediff; a approves it"
                                                  (harness-ui-patch-review--path-label file))
                               'keymap harness-ui-patch-review--row-map)
                         row)
    row))

(defun harness-ui-patch-review--file-block (review file index width counts &optional indent label)
  "Return FILE of REVIEW as lines: its row, then its earlier comments.
The arguments are those of `harness-ui-patch-review--row'; each line ends
in a newline."
  (let ((indent (or indent "  ")))
    (concat (harness-ui-patch-review--row review file index width counts indent label) "\n"
            ;; Under the label, past the mark and the status.
            (harness-ui-patch-review--comment-rows review file index (concat indent "     ")))))

(defun harness-ui-patch-review--tree-label (file)
  "Return FILE's name under its directory, \"OLD → NEW\" for a rename."
  (let ((old (harness-ui-patch-review--f-old-path file))
        (path (harness-ui-patch-review--f-path file)))
    (cond
     ((and old (not (equal (file-name-directory old) (file-name-directory path))))
      (format "%s → %s" old path))
     (old (format "%s → %s" (file-name-nondirectory old) (file-name-nondirectory path)))
     (t (file-name-nondirectory path)))))

(defun harness-ui-patch-review--tree-node ()
  "Return an empty node of the file tree."
  (list :name nil :dirs nil :files nil))

(defun harness-ui-patch-review--tree-add (node file &optional parts)
  "Put FILE in tree NODE, by the directories of its path.
PARTS is what is left of the path; nil to start at its first directory."
  (let* ((parts (or parts (split-string (harness-ui-patch-review--f-path file) "/" t)))
         (rest (cdr parts)))
    (if (null rest)
        (setf (plist-get node :files) (cons file (plist-get node :files)))
      (let ((child (assoc (car parts) (plist-get node :dirs))))
        (unless child
          (setq child (cons (car parts)
                            (list :name (car parts) :dirs nil :files nil)))
          (setf (plist-get node :dirs) (cons child (plist-get node :dirs))))
        (harness-ui-patch-review--tree-add (cdr child) file rest)))))

(defun harness-ui-patch-review--tree (files)
  "Return FILES as a tree of directories and the files they hold."
  (let ((root (harness-ui-patch-review--tree-node)))
    (dolist (file files) (harness-ui-patch-review--tree-add root file))
    root))

(defun harness-ui-patch-review--tree-stats (node)
  "Return (COUNT ADDED DELETED) for the files of NODE and its directories."
  (let ((count (length (plist-get node :files)))
        (added 0)
        (deleted 0))
    (dolist (file (plist-get node :files))
      (cl-incf added (harness-ui-patch-review--f-added file))
      (cl-incf deleted (harness-ui-patch-review--f-deleted file)))
    (dolist (child (plist-get node :dirs))
      (pcase-let ((`(,child-count ,child-added ,child-deleted)
                   (harness-ui-patch-review--tree-stats (cdr child))))
        (cl-incf count child-count)
        (cl-incf added child-added)
        (cl-incf deleted child-deleted)))
    (list count added deleted)))

(defun harness-ui-patch-review--tree-indent (depth)
  "Return the indentation of a tree row at DEPTH."
  (concat "  " (make-string (* 2 depth) ?\s)))

(defun harness-ui-patch-review--directory-row (node depth)
  "Return the row of directory NODE at DEPTH in the file tree."
  (pcase-let* ((`(,count ,added ,deleted) (harness-ui-patch-review--tree-stats node))
               (indent (harness-ui-patch-review--tree-indent depth)))
    (concat indent
            (propertize "▾ " 'face 'harness-dim-face)
            (propertize (concat (plist-get node :name) "/") 'face 'bold)
            "  " (propertize (harness-ui-patch-review--plural count "file") 'face 'harness-dim-face)
            (if (> (+ added deleted) 0)
                (concat "  " (propertize (format "+%d" added) 'face 'harness-ui-patch-review-plus-face)
                        " " (propertize (format "−%d" deleted) 'face 'harness-ui-patch-review-minus-face))
              "")
            "\n")))

(defun harness-ui-patch-review--tree-lines (review node depth width counts indices)
  "Return the rows of tree NODE at DEPTH, as REVIEW's report shows them.
WIDTH pads a file's name; COUNTS are the box's comments; INDICES maps
each file to its place among REVIEW's files."
  (let* ((files (sort (copy-sequence (plist-get node :files))
                      (lambda (a b)
                        (string< (harness-ui-patch-review--tree-label a)
                                 (harness-ui-patch-review--tree-label b)))))
         (dirs (sort (copy-sequence (plist-get node :dirs))
                     (lambda (a b) (string< (car a) (car b)))))
         (entries (sort (append
                         (mapcar (lambda (file)
                                   (cons (harness-ui-patch-review--tree-label file) (cons 'file file)))
                                 files)
                         (mapcar (lambda (dir)
                                   (cons (concat (car dir) "/") (cons 'dir (cdr dir))))
                                 dirs))
                        (lambda (a b) (string< (car a) (car b)))))
         (indent (harness-ui-patch-review--tree-indent depth)))
    (mapconcat
     (lambda (entry)
       (pcase (car (cdr entry))
         ('file
          (harness-ui-patch-review--file-block
           review (cdr (cdr entry))
           (gethash (cdr (cdr entry)) indices) width counts indent
           (harness-ui-patch-review--tree-label (cdr (cdr entry)))))
         ('dir
          (concat (harness-ui-patch-review--directory-row (cdr (cdr entry)) depth)
                  (harness-ui-patch-review--tree-lines review (cdr (cdr entry)) (1+ depth)
                                                      width counts indices)))))
     entries "")))

(defun harness-ui-patch-review--review-here ()
  "Return the review of the report at point, or nil."
  (or (car (harness-ui-patch-review--at-point))
      (when (derived-mode-p 'harness-ui-popout-mode)
        (when-let* ((task (and (fboundp 'harness-ui-report-task)
                               (harness-ui-report-task))))
          (gethash (plist-get task :id) harness-ui-patch-review--reviews)))))

(defun harness-ui-patch-review-toggle-file-tree ()
  "Show the changed files flat, in the diff's order, or as a tree.
In a report showing the changes, from a row or anywhere else in it."
  (interactive)
  (let ((review (or (harness-ui-patch-review--review-here)
                    (user-error "No changes here to show as a tree"))))
    (setf (harness-ui-patch-review--r-tree review)
          (not (harness-ui-patch-review--r-tree review)))
    (harness-ui-patch-review--refresh review)
    (message "The files show %s" (if (harness-ui-patch-review--r-tree review)
                                     "as a tree"
                                   "in a flat list"))))

(defun harness-ui-patch-review--viewed-text (review)
  "Return how much of REVIEW is reviewed: \"N of M files viewed, K left\".
N is how many files were compared in Ediff (`harness-ui-patch-review--seen-p')."
  (let* ((files (harness-ui-patch-review--r-files review))
         (seen (cl-count-if (lambda (file) (harness-ui-patch-review--seen-p review file)) files))
         (approved (cl-count-if (lambda (file) (harness-ui-patch-review--approved-p review file)) files)))
    (format "%d of %s viewed, %d left%s"
            seen (harness-ui-patch-review--plural (length files) "file")
            (- (length files) seen)
            (if (> approved 0) (format ", %d approved" approved) ""))))

(defun harness-ui-patch-review--heading (review comments)
  "Return the first line of REVIEW's changes: what is compared, how much changed.
COMMENTS is how many comments the box has on them."
  (let ((files (harness-ui-patch-review--r-files review))
        (tip (harness-ui-patch-review--r-tip review)))
    (concat
     (propertize (if tip (format "Changes (%d)" (length files)) "Changes") 'face 'harness-label-face)
     ;; How far through the files the reviewer is, just after the count.
     (if (null files) ""
       (concat "   " (propertize (harness-ui-patch-review--viewed-text review)
                                 'face 'harness-dim-face
                                 'help-echo "The files you have compared in Ediff, those approved, and those left")))
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
  "RET or a click compares a file in Ediff, n and p move between them, a approves it, A approves all, t shows a tree or a flat list.  In Ediff c comments on a difference -- in either version, on the line at point -- quoting it in the box below, and e goes to the box to edit the comments (C-c C-d comes back to Ediff); n at the last difference offers the next file, N and P go on to the next or previous file, q comes back here."
  "What the report says under the changes.")

(defun harness-ui-patch-review--section (review counts)
  "Return REVIEW's changes as its report shows them; COUNTS are the box's comments."
  (let* ((files (harness-ui-patch-review--r-files review))
         (indices (let ((table (make-hash-table :test 'eq)))
                    (cl-loop for file in files for index from 0
                             do (puthash file index table))
                    table))
         (tree (and (harness-ui-patch-review--r-tree review)
                    (harness-ui-patch-review--tree files)))
         (width (min 60 (max 12 (apply #'max 0
                                       (mapcar (lambda (file)
                                                 (string-width (harness-ui-patch-review--tree-label file)))
                                               files))))))
    (concat
     (harness-ui-patch-review--heading review (apply #'+ (mapcar #'cdr counts))) "\n"
     (mapconcat (lambda (note) (concat "  " note "\n")) (harness-ui-patch-review--notes review) "")
     (when-let* ((previous (harness-ui-patch-review--previous-section review)))
       (concat "\n" previous))
     (if (null files) ""
       (concat "\n"
               (if tree
                   (harness-ui-patch-review--tree-lines review tree 0 width counts indices)
                 (cl-loop for file in files for index from 0
                          concat (harness-ui-patch-review--file-block review file index width counts)))
               (propertize (concat "  " harness-ui-patch-review--hint)
                           'face 'harness-hint-face 'wrap-prefix "  ")
               "\n")))))

(defun harness-ui-patch-review--panel (task)
  "Return the changes of TASK for its report, while TASK waits for review.
On `harness-ui-report-panel-functions', called in the report popout on
every draw.  Nil for a task with no branch of its own; for one whose
repository is not on this machine, a line saying so.  A report opened
afresh reads the branch afresh.  A review opened from a session's
history for a task no longer waiting for one shows too: its review
says so (`harness-ui-patch-review--r-show')."
  (let ((existing (and task (plist-get task :id)
                       (gethash (plist-get task :id) harness-ui-patch-review--reviews))))
    (when (and harness-ui-patch-review--active
               (derived-mode-p 'harness-ui-popout-mode)
               (or (harness-ui-patch-review--reviewing-p task)
                   (and existing (harness-ui-patch-review--r-show existing)))
               (not (harness-string-blank-p (plist-get task :branch))))
      (if (not (harness-ui-patch-review--repository task))
          (concat (propertize "Changes" 'face 'harness-label-face) "   "
                  (propertize (if (harness-ui-patch-review--reviewing-p task)
                                  (harness-ui-patch-review--why-not task)
                                (format "The repository of %s is not on this machine"
                                        (harness-ui-patch-review--title
                                         (or existing (harness-ui-patch-review--review-for task)))))
                              'face 'harness-dim-face) "\n")
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
          ;; C-c C-d in the report: back to its Ediff, else the review.
          (unless (bound-and-true-p harness-ui-patch-review-mode)
            (harness-ui-patch-review-mode 1))
          ;; Beside an Ediff the report keeps to its share of the frame, even
          ;; when it was shown again meanwhile; with none, to no share.
          (if (harness-ui-patch-review--r-ediff review)
              (harness-ui-patch-review--limit-box (current-buffer))
            (when harness-ui-patch-review--box-limit
              (harness-ui-patch-review--unlimit-box (current-buffer))))
          (let ((counts (harness-ui-patch-review--counts (or (harness-compose-text) ""))))
            (setf (harness-ui-patch-review--r-counts review) counts)
            (harness-ui-patch-review--section review counts)))))))

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

;;;; The feedback box beside Ediff

;; The report is a popout, a window at the bottom of the frame, and its
;; box is the feedback.  Ediff takes the rest of the frame; the report
;; stays, smaller, so the box can be seen while the files are compared,
;; and a comment made in Ediff shows in it as it is made.

(defun harness-ui-patch-review--box-fraction ()
  "Return the fraction of its frame's height the report in this buffer may take.
It is the popout's height limit while an Ediff shows beside it."
  harness-ui-patch-review-ediff-box-height)

(defun harness-ui-patch-review--limit-box (popout)
  "Keep the report POPOUT to the height an Ediff leaves it."
  (with-current-buffer popout
    (unless harness-ui-patch-review--box-limit
      (setq harness-ui-patch-review--box-limit (list harness-ui-popout--max-height)))
    (setq-local harness-ui-popout--max-height #'harness-ui-patch-review--box-fraction)))

(defun harness-ui-patch-review--unlimit-box (popout)
  "Give the report POPOUT its height limit and its windows' freedom back."
  (when (buffer-live-p popout)
    (with-current-buffer popout
      (when harness-ui-patch-review--box-limit
        (setq-local harness-ui-popout--max-height (car harness-ui-patch-review--box-limit))
        (setq harness-ui-patch-review--box-limit nil)))
    (dolist (window (get-buffer-window-list popout nil t))
      (set-window-parameter window 'no-delete-other-windows nil))))

(defun harness-ui-patch-review--scroll-box (window &optional place)
  "Scroll WINDOW, showing a report, so the end of its feedback box is in sight.
The box ends on the window's last line.  With PLACE, (START . END) as
offsets in the box, that is what WINDOW shows the end of instead, and
where its point goes: a comment just made is in sight, whatever follows
it."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (harness-compose-live-p)
        (let ((pos (if place
                       (min harness-compose-end (+ harness-compose-start (cdr place)))
                     harness-compose-end)))
          (set-window-point window pos)
          (with-selected-window window
            (save-excursion
              (goto-char pos)
              (recenter -1))))))))

(defun harness-ui-patch-review--fit-box (window)
  "Fit WINDOW, showing a report, to the part of the frame it takes beside Ediff."
  (let ((lines (max harness-ui-popout-min-height
                    (floor (* harness-ui-patch-review-ediff-box-height
                              (frame-height (window-frame window))))))
        (window-resize-pixelwise t))
    (ignore-errors (fit-window-to-buffer window lines harness-ui-popout-min-height))
    (harness-ui-patch-review--scroll-box window)))

(defun harness-ui-patch-review--keep-box (review)
  "Keep REVIEW's report in the selected frame, for Ediff to leave be.
Its window is returned: the report's own at the bottom of the frame, or
one it is shown in now when it was closed; either way it is not one
Ediff takes (`no-delete-other-windows'), is limited to
`harness-ui-patch-review-ediff-box-height' of the frame, and shows the
end of the feedback box.  Nil when there is no report open with a box,
or the option is nil."
  (let ((popout (harness-ui-patch-review--r-popout review)))
    (when (and harness-ui-patch-review-ediff-box-height (buffer-live-p popout)
               (with-current-buffer popout (harness-compose-live-p)))
      (let ((window (or (get-buffer-window popout (selected-frame))
                        (display-buffer-in-side-window popout harness-ui-popout-window-parameters))))
        (when (window-live-p window)
          (harness-ui-patch-review--limit-box popout)
          (set-window-parameter window 'no-delete-other-windows t)
          (harness-ui-patch-review--fit-box window)
          window)))))

(defun harness-ui-patch-review--box-target (file where)
  "Return where in this report's box point goes to edit the comments on FILE.
WHERE is (SIDE . LINE), where the reviewer is in FILE.  That is the end
of the comment under the quoted line it names, if the box has one; else
the end of the last comment on FILE; else the end of the box, to write a
new one."
  (save-excursion
    (save-restriction
      (narrow-to-region harness-compose-start harness-compose-end)
      (let* ((header (harness-ui-patch-review--header file))
             (quoted (cl-remove-if-not (lambda (line) (and (eq (plist-get line :type) 'quote)
                                                           (equal (plist-get line :file) header)))
                                       (harness-ui-patch-review--parse)))
             (side (car where))
             (exact (and side (cl-find-if (lambda (line) (eql (plist-get line side) (cdr where)))
                                          quoted)))
             ;; The end of the comment under a line of the quote, nil when
             ;; it has none.
             (comment-end (lambda (line)
                            (let ((limit (save-excursion (goto-char (plist-get line :start))
                                                         (line-end-position)))
                                  (end (save-excursion
                                         (goto-char (harness-ui-patch-review--after-comments
                                                     (plist-get line :start)))
                                         (skip-chars-backward " \t\n")
                                         (point))))
                              (and (> end limit) end)))))
        (or (and exact (funcall comment-end exact))
            (cl-some comment-end (reverse quoted))
            (point-max))))))

(defun harness-ui-patch-review--ediff-where ()
  "Return (SIDE . LINE) for where the reviewer is in this Ediff.
In the control panel that is the current difference
\(`harness-ui-patch-review--ediff-position'), in a version the line at point."
  (let ((state (harness-ui-patch-review--r-ediff (harness-ui-patch-review--current))))
    (if (eq (current-buffer) (plist-get state :control))
        (harness-ui-patch-review--ediff-position)
      (cons (if (eq (current-buffer) (plist-get state :a)) :old :new)
            (line-number-at-pos)))))

(defun harness-ui-patch-review-edit-feedback ()
  "Go to the report's feedback box, to edit what it holds or add to it.
In an Ediff of a task's change, from the control panel or either
version.  The box is at the bottom of the frame, under Ediff; point goes
to the end of the comment on the difference at point -- the line, in a
version -- if the box has one, so it can be reworded, else to the end of
the last comment on this file, else to the end of the box.  Ediff stays as
it is: \\<harness-ui-patch-review-mode-map>\\[harness-ui-patch-review-open] in the report goes back to it, and
\\<harness-ui-popout-mode-map>\\[harness-ui-popout-submit] there sends the feedback."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (index harness-ui-patch-review--index)
         (file (or (and (integerp index) (nth index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (where (harness-ui-patch-review--ediff-where))
         (popout (harness-ui-patch-review--feedback-box review))
         (window (or (harness-ui-patch-review--keep-box review)
                     (user-error "The box is not shown beside Ediff: see `harness-ui-patch-review-ediff-box-height'")))
         (target (with-current-buffer popout (harness-ui-patch-review--box-target file where))))
    (select-window window)
    (goto-char target)
    (message "The feedback: %s goes back to Ediff, %s sends it"
             (substitute-command-keys "\\<harness-ui-patch-review-mode-map>\\[harness-ui-patch-review-open]")
             (substitute-command-keys "\\<harness-ui-popout-mode-map>\\[harness-ui-popout-submit]"))))

(defun harness-ui-patch-review--show-comment (review place)
  "Show REVIEW's feedback box, with PLACE in sight, beside Ediff.
PLACE is where a comment was put in the box, as offsets (START . END);
the box is brought back if it was closed, and what was put in is
highlighted for a moment.  Nothing happens without an Ediff."
  (when (and place (harness-ui-patch-review--r-ediff review))
    (when-let* ((window (harness-ui-patch-review--keep-box review)))
      (harness-ui-patch-review--scroll-box window place)
      (with-current-buffer (window-buffer window)
        (ignore-errors
          (pulse-momentary-highlight-region
           (min harness-compose-end (+ harness-compose-start (car place)))
           (min harness-compose-end (+ harness-compose-start (cdr place)))))))))

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

(defun harness-ui-patch-review-ediff (&optional review index goto)
  "Compare the file of the row at point in Ediff, merge base and branch.
On the changes in a task's report.  In Ediff, c comments on the
current difference, into the report's box, N and P go on to the next
or previous file, and q comes back to the report.  REVIEW and INDEX
name the file instead of the row at point.  On the row of an earlier
comment the version Ediff shows has that comment's line in sight; GOTO,
\(SIDE . LINE), names a line the same way."
  (interactive)
  (let ((goto (or goto (and (null review)
                            (get-text-property (line-beginning-position) 'harness-ui-patch-review-where)))))
    (pcase-let* ((`(,review . ,index) (if review (cons review index)
                                        (or (harness-ui-patch-review--at-point) (user-error "No file on this line"))))
                 (file (or (nth index (harness-ui-patch-review--r-files review)) (user-error "No such file")))
                 (why (harness-ui-patch-review--incomparable file)))
      (if (not why)
          (harness-ui-patch-review--compare review index goto)
        (harness-ui-patch-review--mark-seen review file)
        (harness-ui-patch-review--refresh review)
        (message "%s" why)
        nil))))

(defun harness-ui-patch-review-mouse-ediff (event)
  "Compare the file clicked on in EVENT in Ediff."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-patch-review-ediff))

(defun harness-ui-patch-review--compare (review index &optional goto)
  "Read the two versions of REVIEW's file at INDEX, then compare them in Ediff.
GOTO, (SIDE . LINE), is a line to have in sight in the version of SIDE.
Return a promise of the review."
  (let ((file (nth index (harness-ui-patch-review--r-files review))))
    (message "Reading %s…" (harness-ui-patch-review--f-path file))
    (harness-then
     (harness-all (list (harness-ui-patch-review--blob review (harness-ui-patch-review--f-old-blob file))
                        (harness-ui-patch-review--blob review (harness-ui-patch-review--f-new-blob file))))
     (lambda (texts)
       (harness-ui-patch-review--start-ediff review index (nth 0 texts) (nth 1 texts) goto)
       review)
     (lambda (err)
       (message "Could not read %s: %s" (harness-ui-patch-review--f-path file) (harness-error-message err))
       nil))))

(defvar harness-ui-patch-review-lines-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'harness-ui-patch-review-comment-line)
    (define-key map (kbd "a") #'harness-ui-patch-review-approve-ediff)
    (define-key map (kbd "e") #'harness-ui-patch-review-edit-feedback)
    map)
  "Keys in the two versions Ediff compares: c comments on the line at point.")

(define-minor-mode harness-ui-patch-review-lines-mode
  "Keys to review one of the two versions Ediff compares.
\\<harness-ui-patch-review-lines-mode-map>\\[harness-ui-patch-review-comment-line] comments on the line at point, quoting it
in the report's feedback box; \\[harness-ui-patch-review-approve-ediff] approves the file; \\[harness-ui-patch-review-edit-feedback] goes to the feedback
box, to edit what it holds."
  :lighter nil :keymap harness-ui-patch-review-lines-mode-map :group 'harness-ui-patch-review)

;;;;; The earlier comments in the versions

(defun harness-ui-patch-review--earlier-text (entries)
  "Return the text that shows ENTRIES, earlier comments, under a line.
Each entry is (COMMENT . PLACEMENT).  A comment is a block of lines
behind a bar: the round, when it was sent and what became of the line
since, then what the comment said.  The text starts with a newline and
does not end in one: it goes at the end of the line it is under."
  (mapconcat
   (lambda (entry)
     (let* ((comment (car entry))
            (status (and (cdr entry) (plist-get (cdr entry) :status)))
            (bar (propertize "▎ " 'face 'warning))
            (head (format "Round %d%s%s" (1+ (plist-get comment :round))
                          (if-let* ((time (harness-ui-patch-review--round-time comment)))
                              (concat " · " time)
                            "")
                          (pcase status
                            ('moved (format " · was line %d" (plist-get (cdr entry) :was)))
                            ('changed " · the line changed since")
                            (_ "")))))
       (concat "\n" bar (propertize head 'face 'harness-dim-face)
               (mapconcat (lambda (line)
                            (concat "\n" bar (propertize line 'face 'harness-ui-patch-review-earlier-face)))
                          (split-string (plist-get comment :text) "\n") ""))))
   entries ""))

(defun harness-ui-patch-review--decorate (review file buffer side placed)
  "Show the earlier comments on FILE of REVIEW that are on SIDE in BUFFER.
SIDE is :old or :new, the version BUFFER holds.  PLACED says where each
comment is now (`harness-ui-patch-review--place-comments'); each shows
under its line, as an overlay, and the comments on the file as a whole
at the top of the branch's version."
  (let ((by-line (make-hash-table)) top)
    (dolist (comment (harness-ui-patch-review--file-comments review file))
      (let ((placement (cdr (assoc (harness-ui-patch-review--comment-key comment) placed))))
        (cond
         ((null (plist-get comment :where))
          (when (eq side :new) (push (cons comment nil) top)))
         ((and placement (eq (plist-get placement :side) side) (plist-get placement :line))
          (push (cons comment placement) (gethash (plist-get placement :line) by-line))))))
    (with-current-buffer buffer
      (save-excursion
        (maphash (lambda (line entries)
                   (goto-char (point-min))
                   (forward-line (1- line))
                   (end-of-line)
                   (let ((overlay (make-overlay (point) (point) nil t)))
                     (overlay-put overlay 'harness-ui-patch-review-earlier t)
                     (overlay-put overlay 'after-string
                                  (harness-ui-patch-review--earlier-text (nreverse entries)))))
                 by-line)
        (when top
          (let ((overlay (make-overlay (point-min) (point-min))))
            (overlay-put overlay 'harness-ui-patch-review-earlier t)
            (overlay-put overlay 'before-string
                         (concat (substring (harness-ui-patch-review--earlier-text (nreverse top)) 1)
                                 "\n"))))))))

(defun harness-ui-patch-review--show-line (review goto)
  "Put the Ediff of REVIEW at GOTO, (SIDE . LINE): that line in sight there."
  (pcase-let* ((state (harness-ui-patch-review--r-ediff review))
               (`(,side . ,line) goto)
               (buffer (plist-get state (if (eq side :old) :a :b)))
               (window (and (buffer-live-p buffer) (get-buffer-window buffer))))
    (when (and window (integerp line) (> line 0))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line (1- line))
        (set-window-point window (point)))
      (with-selected-window window (recenter)))))

(defun harness-ui-patch-review--side-buffer (review file side text &optional placed)
  "Return a buffer of TEXT, FILE's version on SIDE, `old' or `new', for Ediff.
REVIEW names it after the commit it is from.  It is in the major mode
of FILE, without the mode's hooks: a language server, say, has no
business there.  It is read-only, and its own keys comment on a line.
It has REVIEW and its file's index, for the keys, and under the lines
the reviewer commented on in earlier rounds, those comments (PLACED
says where they are now, as `harness-ui-patch-review--place-comments'
gives it)."
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
      (setq-local harness-ui-patch-review--review review
                  harness-ui-patch-review--index
                  (cl-position file (harness-ui-patch-review--r-files review) :test #'eq))
      (harness-ui-patch-review-lines-mode 1)
      (harness-ui-patch-review--decorate review file buffer (if old :old :new) placed)
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

(defun harness-ui-patch-review--ediff-progress ()
  "Return where this comparison is, as a prefix for the brief help.
It is \"File i of M · N viewed · \", or an empty string when the
panel does not know its review yet: Ediff composes the brief help while
setting the panel up, before the review's own keys and file are
installed, so `harness-ui-patch-review--ediff-redraw-help' draws it
again once they are."
  (let* ((review harness-ui-patch-review--review)
         (index harness-ui-patch-review--index)
         (files (and review (harness-ui-patch-review--r-files review))))
    (if (or (null files) (not (integerp index)) (< index 0) (>= index (length files)))
        ""
      (let ((earlier (length (harness-ui-patch-review--file-comments review (nth index files)))))
        (format "File %d of %d · %d viewed · %s"
                (1+ index) (length files)
                (cl-count-if (lambda (file) (harness-ui-patch-review--seen-p review file)) files)
                (if (> earlier 0)
                    (format "%d earlier %s · " earlier (if (= earlier 1) "comment" "comments"))
                  ""))))))

(defun harness-ui-patch-review--ediff-redraw-help ()
  "Draw this Ediff control panel's brief help again, with its place in the files.
Ediff composes it once while setting the panel up, before
`harness-ui-patch-review--ediff-startup' has installed the review and
its file, so on its own the panel would not say where the reviewer is."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ediff-set-help-message)
    (insert ediff-help-message)
    (unless (ediff-multiframe-setup-p) (ediff-indent-help-message))
    (ediff-set-help-overlays)
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (skip-chars-forward ediff-whitespace)))

(defun harness-ui-patch-review--ediff-help ()
  "Return the brief help of the Ediff control panel of a review.
It opens with where the reviewer is: which file of how many, and how
many were compared already (`harness-ui-patch-review--ediff-progress')."
  (let* ((here (concat (harness-ui-patch-review--ediff-progress)
                       (harness-ui-patch-review--help-button "[Comment]" #'harness-ui-patch-review-comment "c")
                       "   " (harness-ui-patch-review--help-button "[Edit feedback]" #'harness-ui-patch-review-edit-feedback "e")
                       "   " (harness-ui-patch-review--help-button "[Approve]" #'harness-ui-patch-review-approve-ediff "a")))
         (elsewhere (concat (harness-ui-patch-review--help-button "[Next file]" #'harness-ui-patch-review-ediff-next-file "N")
                            "   " (harness-ui-patch-review--help-button "[Previous file]" #'harness-ui-patch-review-ediff-previous-file "P")
                            "   " (harness-ui-patch-review--help-button "[Back to the report]" #'harness-ui-patch-review-ediff-quit "q")
                            "   " (propertize "? Ediff's keys" 'face 'harness-dim-face)))
         (window (get-buffer-window (current-buffer)))
         (width (if window (window-width window) (frame-width))))
    ;; In one line when the panel is wide enough, else in two, cut between
    ;; buttons rather than through one.
    (concat here (if (> (+ (string-width here) 3 (string-width elsewhere)) (- width 2)) "\n" "   ")
            elsewhere)))

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

(defun harness-ui-patch-review--start-ediff (review index old new &optional goto)
  "Compare OLD and NEW, the texts of REVIEW's file at INDEX, in Ediff.
From the report, Ediff takes its frame, whose windows are kept to give
back when it ends.  From an Ediff of the review -- N and P -- it takes
that one's place, with the same windows to give back.  The earlier
comments on the file show in its versions, placed by these texts.  With
GOTO, (SIDE . LINE), that line is in sight in the version of SIDE."
  (require 'ediff)
  (let* ((file (nth index (harness-ui-patch-review--r-files review)))
         (placed (harness-ui-patch-review--place-comments review file old new))
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
    (let* ((windows (or windows (current-window-configuration)))
           (main (harness-ui-patch-review--main-window))
           ;; The report's window stays for its feedback box, smaller.
           (box (harness-ui-patch-review--keep-box review)))
      (select-window main)
      ;; The other side windows go too: Ediff lays the frame out its own
      ;; way, and q gives it back as it was.
      (condition-case nil
          (let ((ignore-window-parameters (not box)))
            (delete-other-windows main))
        (error (let ((ignore-window-parameters t))
                 (delete-other-windows main))))
      (set-window-dedicated-p main nil)
      ;; The versions show the places the report does, once it has read how
      ;; the files changed; until then, those the texts at hand tell.
      (setq placed (mapcar (lambda (entry)
                             (cons (car entry)
                                   (or (gethash (car entry) (harness-ui-patch-review--r-placements review))
                                       (cdr entry))))
                           placed))
      (let ((a (harness-ui-patch-review--side-buffer review file 'old old placed))
            (b (harness-ui-patch-review--side-buffer review file 'new new placed)))
        (setf (harness-ui-patch-review--r-ediff review)
              (list :index index :a a :b b :windows windows :start start :box box))
        (condition-case err
            (progn
              (let ((ediff-window-setup-function (or harness-ui-patch-review-ediff-window-setup
                                                     ediff-window-setup-function))
                    (ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help))
                (ediff-buffers a b (list (lambda () (harness-ui-patch-review--ediff-startup review index)))))
              ;; Ediff laid the rest of the frame out: the box ends the report in the window.
              (harness-ui-patch-review--scroll-box box)
              (when goto (harness-ui-patch-review--show-line review goto)))
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
    (define-key map "e" #'harness-ui-patch-review-edit-feedback)
    (define-key map "a" #'harness-ui-patch-review-approve-ediff)
    (define-key map "n" #'harness-ui-patch-review-next-difference)
    (define-key map "]" #'harness-ui-patch-review-next-difference)
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
    (ediff-next-difference))
  ;; Ediff drew the brief help while setting the panel up, before the
  ;; review's own keys and file were installed: draw it again, so it opens
  ;; with where in the files the reviewer is.
  (harness-ui-patch-review--ediff-redraw-help))

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
      ;; The report has the height it had again, and its windows are free.
      (harness-ui-patch-review--unlimit-box (harness-ui-patch-review--r-popout review))
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

(defun harness-ui-patch-review-next-difference (&optional arg)
  "Move to the next difference in this Ediff, ARG times.
At the last difference it first says the next difference is the next
file; pressing n again goes on to it, in Ediff.  So the reviewer need
not know before the last difference that another file follows."
  (interactive "p")
  (let ((last (1- ediff-number-of-differences)))
    (cond
     ((<= ediff-number-of-differences 0)
      (harness-ui-patch-review-ediff-next-file))
     ((and harness-ui-patch-review--next-file-offer
           (eq last-command this-command))
      (setq harness-ui-patch-review--next-file-offer nil)
      (harness-ui-patch-review-ediff-next-file))
     ((>= ediff-current-difference last)
      (setq harness-ui-patch-review--next-file-offer t)
      (message "Last difference; n again goes to the next file"))
     (t
      (setq harness-ui-patch-review--next-file-offer nil)
      (ediff-next-difference arg)))))

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

(defun harness-ui-patch-review-comment (&optional text)
  "Comment on the current difference with TEXT.
In the Ediff of a task's change.  Called from the panel it reads the
comment in a buffer of its own, so it may run to several lines: C-c C-c
comments, C-c C-k gives up (`string-edit').  The comment goes in the
feedback box of the task's report, under the difference's lines quoted
from the diff -- the branch's lines, or the merge base's for a
difference that only deletes -- after any comment there already.
Without a current difference it is a comment on the file as a whole."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (file (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))
         (where (harness-ui-patch-review--ediff-position)))
    (if text
        (harness-ui-patch-review--comment-added review file where text)
      (require 'string-edit)
      (string-edit (concat (harness-ui-patch-review--comment-prompt)
                           "  C-c C-c comments, C-c C-k cancels")
                   ""
                   (lambda (written)
                     (harness-ui-patch-review--comment-added review file where written))
                   :abort-callback #'ignore))))

(defun harness-ui-patch-review--read-comment (prompt callback)
  "Read a comment with PROMPT, then call CALLBACK with what was written.
It is read in a buffer of its own, so it may run to several lines:
C-c C-c comments, C-c C-k gives up (`string-edit')."
  (require 'string-edit)
  (string-edit (concat prompt "  C-c C-c comments, C-c C-k cancels")
               ""
               callback
               :abort-callback #'ignore))

(defun harness-ui-patch-review-comment-line (&optional text)
  "Comment on the line at point in the version Ediff shows.
In either version of a file compared in Ediff: the branch's line gets a
comment under it quoted from the diff, the merge base's too.  With TEXT
it is the comment; called from the buffer it reads the comment in one of
its own, which may run to several lines."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (index harness-ui-patch-review--index)
         (file (or (and (integerp index)
                        (nth index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (state (harness-ui-patch-review--r-ediff review))
         (side (if (eq (current-buffer) (plist-get state :a)) :old :new))
         (line (line-number-at-pos))
         (where (cons side line)))
    (if text
        (harness-ui-patch-review--comment-added review file where text)
      (harness-ui-patch-review--read-comment
       (format "Comment on %s, line %d%s: "
               (harness-ui-patch-review--f-path file) line
               (if (eq side :old) " of the merge base" ""))
       (lambda (written)
         (harness-ui-patch-review--comment-added review file where written))))))

(defun harness-ui-patch-review-approve-ediff ()
  "Approve the file compared in this Ediff, or stop approving it.
It need not be reviewed again unless the branch changes it."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (index harness-ui-patch-review--index)
         (file (or (and (integerp index)
                        (nth index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (approved (not (harness-ui-patch-review--approved-p review file))))
    (harness-ui-patch-review--approve review file approved)
    (harness-ui-patch-review--refresh review)
    (message "%s %s" (if approved "Approved" "No longer approved")
             (harness-ui-patch-review--f-path file))))

(defun harness-ui-patch-review--comment-added (review file where text)
  "Put TEXT, a comment on WHERE of FILE of REVIEW, in the feedback box.
Say in the echo area how many comments FILE now has.  A blank TEXT is
no comment, and says so."
  (if (string-blank-p text)
      (message "No comment")
    (harness-ui-patch-review--add-comment review file where text)
    (message "In the report's box: %s on %s; C-c C-c there sends the feedback"
             (harness-ui-patch-review--plural
              (or (cdr (assoc (harness-ui-patch-review--header file) (harness-ui-patch-review--r-counts review))) 0)
              "comment")
             (harness-ui-patch-review--f-path file))))

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
       (let* ((before (harness-ui-patch-review--r-task review))
              (sent (and before (> (length (plist-get task :feedback))
                                   (length (plist-get before :feedback))))))
         ;; Sent back, or with a round more of feedback: keep what the
         ;; branch was when the reviewer wrote, to say what it changed
         ;; since.  A new round taken while still in review is kept too.
         (when (and before
                    (or sent
                        (and (equal (plist-get before :state) "review")
                             (not (equal (plist-get task :state) "review")))))
           (harness-ui-patch-review--snapshot review task))
         (setf (harness-ui-patch-review--r-task review) task)
         ;; The feedback went -- from the box beside Ediff, say: the review
         ;; is over, and the frame is the reviewer's again.
         (when (and sent (harness-ui-patch-review--r-ediff review))
           (harness-ui-patch-review--end-ediff review)))
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

;;;; Opening the review from a session

(defun harness-ui-patch-review--task-here ()
  "Return the task this buffer shows, or nil.
That is the report popout's task, the session's task, or the task at
point of the board."
  (or (and (fboundp 'harness-ui-report-task)
           (harness-ui-report-task))
      (and (bound-and-true-p harness-ui-session-id)
           (fboundp 'harness-ui-review--task)
           (harness-ui-review--task harness-ui-session-id))
      (and (derived-mode-p 'harness-ui-tasks-mode)
           (fboundp 'harness-ui-tasks--task)
           (harness-ui-tasks--task t))))

(defun harness-ui-patch-review--open-task (task)
  "Show TASK's report, with its changes, in a popout."
  (unless (and task (plist-get task :id))
    (user-error "No task here to review"))
  (let ((review (harness-ui-patch-review--review-for task)))
    ;; A task no longer waiting for review -- done, or sent back and at
    ;; work -- is still the reviewer's to look at from its session's
    ;; history: the changes show, without the review banner.
    (unless (harness-ui-patch-review--reviewing-p task)
      (setf (harness-ui-patch-review--r-show review) t))
    (harness-ui-report-popout task)))

(defun harness-ui-patch-review--ediff-window (task)
  "Return the window of the Ediff of TASK's changes that shows, or nil."
  (when-let* ((review (gethash (plist-get task :id) harness-ui-patch-review--reviews))
              (control (plist-get (harness-ui-patch-review--r-ediff review) :control)))
    (and (buffer-live-p control) (get-buffer-window control t))))

(defun harness-ui-patch-review-open ()
  "Show the changes of the task this buffer shows, in a popout.
From its session's history, from its board card, or from its report:
works after the task left review too, for the task the session is the
task's.  A session's task not looked up yet is asked for, and its review
opens when it arrives.  In the report beside an Ediff of its changes
\(`harness-ui-patch-review-edit-feedback'), it goes back to Ediff."
  (interactive)
  (if-let* ((task (harness-ui-patch-review--task-here)))
      (if-let* ((window (harness-ui-patch-review--ediff-window task)))
          ;; An Ediff of it shows beside the report: back to it.
          (progn (select-window window)
                 (message "Back in Ediff"))
        (harness-ui-patch-review--open-task task))
    (if (and (bound-and-true-p harness-ui-session-id)
             (fboundp 'harness-ui-review--task))
        (progn
          (harness-ui-call "_harness/task/for-session"
                           (list :session-id harness-ui-session-id)
                           (lambda (found)
                             (if (and found (plist-get found :id))
                                 (harness-ui-patch-review--open-task found)
                               (message "This session is no task's, so it has no changes to review"))))
          (message "Looking up this session's task…"))
      (user-error "No task here to review"))))

(defvar harness-ui-patch-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-d") #'harness-ui-patch-review-open)
    map)
  "Keys that show a task's changes from its session or board.")

(define-minor-mode harness-ui-patch-review-mode
  "Keys to open the changes of the task this buffer shows.
\\<harness-ui-patch-review-mode-map>\\[harness-ui-patch-review-open] opens its report with the changes, in a popout, from
a task's session history or a board card, whether it waits for review
or has left it."
  :lighter nil :keymap harness-ui-patch-review-mode-map :group 'harness-ui-patch-review)

(put 'harness-ui-patch-review-mode 'harness-menu-group
     '("Changes"
       ["Review the changes"
        ("C-c C-d" "Review the changes" harness-ui-patch-review-open)]))

(defun harness-ui-patch-review--setup-chat ()
  "Offer the review's key in this chat buffer."
  (harness-ui-patch-review-mode 1))

(defun harness-ui-patch-review--setup-existing-buffers ()
  "Offer the review's key in chats and boards that are open already."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'harness-chat-mode 'harness-ui-tasks-mode)
        (harness-ui-patch-review-mode 1)))))

;;;; Module

(defun harness-ui-patch-review--init ()
  "Show the changes of a task in review in its report."
  (setq harness-ui-patch-review--active t)
  ;; Before the review banner: the changes are read, then the work is
  ;; verified or sent back.
  (add-hook 'harness-ui-report-panel-functions #'harness-ui-patch-review--panel -10)
  (add-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event)
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-patch-review--setup-chat))
  (when (fboundp 'harness-chat-mode)
    (harness-ui-patch-review--setup-existing-buffers)))

(defun harness-ui-patch-review--shutdown ()
  "Take the changes out of the reports again, ending the Ediffs of them."
  (setq harness-ui-patch-review--active nil)
  (remove-hook 'harness-ui-report-panel-functions #'harness-ui-patch-review--panel)
  (remove-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event)
  (remove-hook 'harness-chat-mode-hook #'harness-ui-patch-review--setup-chat)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p harness-ui-patch-review-mode)
                 (derived-mode-p 'harness-chat-mode 'harness-ui-tasks-mode 'harness-ui-popout-mode))
        (harness-ui-patch-review-mode -1))))
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
  :doc "A task's changes in its report: a file tree, Ediff file by file with the earlier comments in place and the feedback box beside it, approvals, comments quoted in the feedback."
  :requires '(ui ui-report ui-review)
  :init #'harness-ui-patch-review--init
  :shutdown #'harness-ui-patch-review--shutdown)

(provide 'harness-ui-patch-review)
;;; harness-ui-patch-review.el ends here
