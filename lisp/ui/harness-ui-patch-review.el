;;; harness-ui-patch-review.el --- Review a task's changes as a patch: Ediff, then a reply  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task waiting for review is a patch waiting for its reviewer.  This
;; module reviews it the way a mailing list does: the changes of its
;; branch, file by file in Ediff, then a reply that quotes the diff with
;; the comments inline, sent back to the task as its feedback in one go.
;;
;; [Changes] on the review banner (C-c C-d there) and on the card of a
;; task in review opens the list of the files the task's branch changes
;; against its merge base with the branch it was made from: what merging
;; it brings in, not what that branch did since.  The list takes the
;; frame; q gives the windows back as they were.
;;
;;   the list    a row per file: its status, its path, what changed
;;               (+added -deleted), a check mark once it was looked at in
;;               Ediff, and the comments on it.  n and p step through the
;;               files, RET compares the one at point in Ediff, r shows
;;               the reply beside the list, C-c C-c sends it, g reads the
;;               branch again, q goes back to the review.
;;   Ediff       the file at the merge base against the file on the
;;               branch.  The control panel keeps Ediff's keys and has
;;               four more: c comments on the current difference, a line
;;               read in the minibuffer that goes into the reply under the
;;               lines it is about; N and P go on to the next or previous
;;               file; q comes back to the list without asking.
;;   the reply   the whole diff quoted with "> ", as a reply to a patch
;;               on a mailing list, with the comments inline: those made
;;               in Ediff, and whatever is written into it -- under a line
;;               of the quote, or above it all for the change as a whole.
;;               C-c C-c sends it back to the task as its feedback
;;               (`task/reject') with only the hunks that have a comment
;;               quoted, and the task works on it again.
;;
;; Git runs here, in the Emacs that shows the UI, in the task's
;; repository: [Changes] is offered where that is a local directory, so
;; not for a harness on another machine.
;;
;; The module is self-contained: nothing else knows of it.  It plugs into
;; the review banner and the task board through the hooks they have for
;; buttons of their own (`harness-ui-review-button-functions',
;; `harness-ui-tasks-card-button-functions'), and takes itself out again
;; when it is disabled (`harness-disabled-modules').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-ui-review-button-functions)
(defvar harness-ui-review-minor-mode-map)
(defvar harness-ui-tasks-card-button-functions)
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
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function ediff-setup-windows-plain "ediff-wind" (buffer-a buffer-b buffer-c control-buffer))
(declare-function ediff-really-quit "ediff-util" (reverse-default-keep-variants))
(declare-function ediff-get-diff-posn "ediff-util" (buf-type pos &optional n control-buf))
(declare-function ediff-next-difference "ediff-util" (&optional arg))
(declare-function harness-ui-review-current-task "harness-ui-review" ())
(declare-function evil-normalize-keymaps "evil-core" (&optional state))

(defgroup harness-ui-patch-review nil
  "Reviewing a task's changes as a patch: Ediff, then a reply with comments inline."
  :group 'harness-ui)

(defcustom harness-ui-patch-review-ediff-window-setup #'ediff-setup-windows-plain
  "How Ediff lays out its windows while it compares a task's change.
The default keeps the control panel in the frame, under the two
versions; nil leaves it to `ediff-window-setup-function', which on a
graphical display gives the panel a frame of its own.  Whether the two
versions are side by side is Ediff's `ediff-split-window-function'."
  :type '(choice (const :tag "Ediff's own setting" nil) function))

(defcustom harness-ui-patch-review-fill-column 72
  "Width the comments made in Ediff are filled to in the reply."
  :type 'natnum)

(defface harness-ui-patch-review-file-face '((t :inherit diff-file-header))
  "A file's first line in the quote of the reply.")
(defface harness-ui-patch-review-header-face '((t :inherit diff-header))
  "The rest of a file's header in the quote of the reply.")
(defface harness-ui-patch-review-hunk-face '((t :inherit diff-hunk-header))
  "A hunk's header in the quote of the reply.")
(defface harness-ui-patch-review-added-face '((t :inherit diff-added))
  "An added line in the quote of the reply.")
(defface harness-ui-patch-review-removed-face '((t :inherit diff-removed))
  "A removed line in the quote of the reply.")
(defface harness-ui-patch-review-context-face '((t :inherit shadow))
  "Any other line of the quote in the reply.")
(defface harness-ui-patch-review-plus-face '((t :inherit diff-indicator-added))
  "Counts of added lines, and the status of an added file, in the list.")
(defface harness-ui-patch-review-minus-face '((t :inherit diff-indicator-removed))
  "Counts of deleted lines, and the status of a deleted file, in the list.")
(defface harness-ui-patch-review-seen-face '((t :inherit success))
  "The mark of a file seen in Ediff, in the list.")
(defface harness-ui-patch-review-comments-face '((t :inherit bold))
  "The count of comments on a file, in the list.")

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
  "The review of a task's changes.
ID and TASK are the task's, as last heard.  DIR is the repository the
branch is read in, BRANCH and BASE the branches compared, MERGE-BASE and
TIP the commits, FILES what the diff of the two holds.  SEEN holds the
files seen in Ediff, by `harness-ui-patch-review--seen-key'.  DIRTY is
non-nil when the task's worktree has changes not committed.  LOADING
is non-nil while the branch is read, ERROR what the last reading failed
with, GONE why the task went, when it did.  WINDOWS are the frame's
windows before the list took it.  LIST and REPLY are the buffers,
REPLY-TIP and REPLY-MERGE-BASE the commits whose diff the reply quotes.
EDIFF is the comparison under way: a plist of :index, the buffers :a,
:b and :control, the :windows to give back and where to go :then."
  id task dir branch base merge-base tip files
  (seen (make-hash-table :test 'equal))
  dirty loading error gone windows list reply reply-tip reply-merge-base ediff)

(defvar harness-ui-patch-review--reviews (make-hash-table :test 'equal)
  "Task id -> the review of its changes, while it lasts.")

(defvar-local harness-ui-patch-review--review nil
  "The review this buffer belongs to: its list, its reply, or an Ediff of it.")

(defvar-local harness-ui-patch-review--index nil
  "In an Ediff control panel of a review, the index of the file it compares.")

(defvar harness-ui-patch-review--active nil
  "Non-nil while the module is on: [Changes] is offered, its key bound.")

(defvar harness-ui-patch-review--forgetting nil
  "Non-nil while a review's buffers are killed on purpose, without asking.")

(defconst harness-ui-patch-review--hunk-regexp
  "\\`@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)\\(?:,[0-9]+\\)? @@"
  "A hunk's header in a diff: its first line on either side.")

(defconst harness-ui-patch-review--button-help
  "Review its changes file by file in Ediff, and reply to them as to a patch on a mailing list"
  "The tooltip of [Changes].")

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
  "Return the review of this buffer: its list, its reply or an Ediff of it."
  (or harness-ui-patch-review--review
      (user-error "Not a review of a task's changes")))

(defun harness-ui-patch-review--fail (format-string &rest args)
  "Return a promise rejected with the error FORMAT-STRING and ARGS make."
  (harness-rejected (list 'error (apply #'format-message format-string args))))

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
    (setf (harness-ui-patch-review--r-task review) task
          (harness-ui-patch-review--r-gone review) nil)
    review))

(defun harness-ui-patch-review--load (review)
  "Read REVIEW's branch again, then draw its list; return a promise of the review."
  (let* ((task (harness-ui-patch-review--r-task review))
         (dir (harness-ui-patch-review--repository task))
         (branch (plist-get task :branch))
         (worktree (let ((wt (plist-get task :worktree)))
                     (and (stringp wt) (not (file-remote-p wt)) (file-directory-p wt) wt)))
         (token (list 'loading)))
    (setf (harness-ui-patch-review--r-loading review) token
          (harness-ui-patch-review--r-error review) nil)
    (harness-ui-patch-review--render review)
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
         (harness-ui-patch-review--sync-reply review)
         (harness-ui-patch-review--render review))
       review)
     (lambda (err)
       (when (eq (harness-ui-patch-review--r-loading review) token)
         (setf (harness-ui-patch-review--r-loading review) nil
               (harness-ui-patch-review--r-error review) (harness-error-message err))
         (harness-ui-patch-review--render review))
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

(defun harness-ui-patch-review--forget (review)
  "End REVIEW: end its Ediff, give its windows back, kill its buffers, drop it."
  (remhash (harness-ui-patch-review--r-id review) harness-ui-patch-review--reviews)
  ;; An Ediff on show gives the list its windows back, for the list to
  ;; give the frame its own; one out of sight leaves the windows be.
  (condition-case err
      (harness-ui-patch-review--end-ediff
       review (not (cl-some (lambda (buffer) (and (buffer-live-p buffer) (get-buffer-window buffer t)))
                            (harness-ui-patch-review--ediff-buffers review))))
    (error (harness-log 'warn "patch review: could not end Ediff: %S" err)))
  (harness-ui-patch-review--give-back review)
  (let ((harness-ui-patch-review--forgetting t))
    (dolist (buffer (append (harness-ui-patch-review--ediff-buffers review)
                            (list (harness-ui-patch-review--r-list review)
                                  (harness-ui-patch-review--r-reply review))))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  (setf (harness-ui-patch-review--r-ediff review) nil))

;;;; The reply

(defun harness-ui-patch-review--quote (text)
  "Return TEXT quoted as on a mailing list: each line after \"> \"."
  (if (string-empty-p text) ""
    (mapconcat (lambda (line) (if (string-empty-p line) ">\n" (concat "> " line "\n")))
               (split-string (string-remove-suffix "\n" text) "\n")
               "")))

(defun harness-ui-patch-review--header (file)
  "Return the first line of FILE's diff, which names it in the reply."
  (let ((patch (harness-ui-patch-review--f-patch file)))
    (if (and patch (string-match "\\`[^\n]+" patch))
        (match-string 0 patch)
      (format "diff --git a/%s b/%s"
              (or (harness-ui-patch-review--f-old-path file) (harness-ui-patch-review--f-path file))
              (harness-ui-patch-review--f-path file)))))

(defun harness-ui-patch-review--parse ()
  "Return the lines of this reply, in order, each a plist.
:type is `quote', for a line of the quote (one that starts with \">\"),
`comment' or `blank'; :start is where the line starts, :text what it
holds.  Every line has the part of the quote it is in: :file, the first
line of its file's diff (nil before the first), and :hunk, the index of
the hunk in the file (nil in the file's header).  A quote line has
:line -- `header', `hunk', `context', `added', `removed' or `other' --
and in a hunk :old and :new, its numbers at the merge base and on the
branch, where it has them."
  (save-excursion
    (save-restriction
      (widen)
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
                        (list :type 'quote :line 'header))
                       ((and file (string-match harness-ui-patch-review--hunk-regexp diff))
                        (setq hunk (if hunk (1+ hunk) 0)
                              old (string-to-number (match-string 1 diff))
                              new (string-to-number (match-string 2 diff)))
                        (list :type 'quote :line 'hunk))
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
        (nreverse lines)))))

(defun harness-ui-patch-review--comment-blocks (lines)
  "Return the first line of each comment in LINES, the reply's.
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

(defun harness-ui-patch-review--anchor (lines header &optional side number)
  "Return the quote line of LINES, the reply's, that a comment goes under.
HEADER names the file, as `harness-ui-patch-review--header' does.  With
SIDE, :old or :new, it is the line quoted as NUMBER on that side, else
the one nearest to it; without, the last line of the file's header,
for a comment on the file as a whole.  Return nil when the reply does
not quote the file."
  (let ((section (cl-remove-if-not (lambda (line) (and (eq (plist-get line :type) 'quote)
                                                       (equal (plist-get line :file) header)))
                                   lines)))
    (when section
      (or (and side
               (or (cl-find number section :key (lambda (line) (plist-get line side)))
                   (car (sort (cl-remove-if-not (lambda (line) (plist-get line side)) section)
                              (lambda (a b) (< (abs (- (plist-get a side) number))
                                               (abs (- (plist-get b side) number))))))))
          (car (last (cl-remove-if-not (lambda (line) (eq (plist-get line :line) 'header)) section)))
          (car (last section))))))

(defun harness-ui-patch-review--insert-comment (anchor text)
  "Insert TEXT, a comment, under the quote line that starts at ANCHOR.
It goes after the comments under that line already, a blank line
before it and after it.  Return where it starts."
  (save-excursion
    (goto-char anchor)
    (end-of-line)
    (when (eobp) (insert "\n"))
    (let ((limit (line-beginning-position 2)))
      (goto-char limit)
      (while (and (not (eobp)) (not (eq (char-after) ?>)))
        (forward-line 1))
      (let ((next (point)) start)
        ;; Back over the blank lines before the next quote line.
        (while (and (> (point) limit)
                    (save-excursion (forward-line -1) (looking-at-p "[ \t]*$")))
          (forward-line -1))
        (let ((blank-after (< (point) next)))
          (insert "\n")
          (setq start (point))
          (insert text "\n")
          (unless (or blank-after (eobp)) (insert "\n")))
        start))))

(defun harness-ui-patch-review--comment-text (text)
  "Return TEXT made a comment of the reply: trimmed and filled.
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

(defun harness-ui-patch-review--join (lines)
  "Return the text of LINES, blank lines run together and the ends trimmed."
  (let (out blank)
    (dolist (line lines)
      (if (eq (plist-get line :type) 'blank)
          (setq blank t)
        (when (and blank out) (push "" out))
        (setq blank nil)
        (push (plist-get line :text) out)))
    (string-join (nreverse out) "\n")))

(defun harness-ui-patch-review--outgoing (lines)
  "Return the reply LINES make as it is sent, or nil when it has no comment.
That is the comments, with the parts of the quote they answer: each
hunk with a comment, under the header of its file, and a file's header
alone for a comment on the file as a whole.  The rest of the quote is
left out."
  (when (cl-some (lambda (line) (eq (plist-get line :type) 'comment)) lines)
    (let (parts)
      ;; Cut LINES where the part of the quote they are in changes.
      (dolist (line lines)
        (let ((key (list (plist-get line :file) (plist-get line :hunk))))
          (if (and parts (equal (car (car parts)) key))
              (push line (cdr (car parts)))
            (push (list key line) parts))))
      (setq parts (nreverse (mapcar (lambda (part) (cons (car part) (reverse (cdr part)))) parts)))
      (let* ((commented (lambda (lines) (cl-some (lambda (line) (eq (plist-get line :type) 'comment)) lines)))
             (files (cl-loop for (key . lines) in parts
                             when (and (car key) (funcall commented lines)) collect (car key)))
             (kept (cl-loop for (key . lines) in parts
                            when (cond ((null (car key)) t)
                                       ((null (cadr key)) (member (car key) files))
                                       (t (funcall commented lines)))
                            append lines)))
        (harness-ui-patch-review--join kept)))))

(defun harness-ui-patch-review--preface (review)
  "Return what the reply of REVIEW opens with, as the task reads it."
  (format "My review of your changes follows, as a reply to a patch on a mailing list. Lines that start with \"> \" quote the diff of your branch %s (at %s) against its merge base with %s (%s), only the parts I comment on; my comments are the other lines, each under the lines it is about, or before any quote for the change as a whole."
          (harness-ui-patch-review--r-branch review)
          ;; What the reply quotes, which the branch may have moved on from.
          (harness-ui-patch-review--short (or (harness-ui-patch-review--r-reply-tip review)
                                              (harness-ui-patch-review--r-tip review)))
          (harness-ui-patch-review--r-base review)
          (harness-ui-patch-review--short (or (harness-ui-patch-review--r-reply-merge-base review)
                                              (harness-ui-patch-review--r-merge-base review)))))

(defvar harness-ui-patch-review-reply-mode-map (make-sparse-keymap)
  "Keymap of `harness-ui-patch-review-reply-mode'.")

(let ((map harness-ui-patch-review-reply-mode-map))
  (define-key map (kbd "C-c C-c") #'harness-ui-patch-review-send)
  (define-key map (kbd "C-c C-k") #'harness-ui-patch-review-hide-reply))

(defconst harness-ui-patch-review--reply-keywords
  '(("^> ?diff --git .*" 0 'harness-ui-patch-review-file-face)
    ("^> ?\\(?:index\\|new file\\|deleted file\\|old mode\\|new mode\\|similarity\\|dissimilarity\\|rename\\|copy\\|Binary files\\|GIT binary\\|---\\|\\+\\+\\+\\) .*"
     0 'harness-ui-patch-review-header-face)
    ("^> ?@@ .*" 0 'harness-ui-patch-review-hunk-face)
    ("^> ?\\+.*" 0 'harness-ui-patch-review-added-face)
    ("^> ?-.*" 0 'harness-ui-patch-review-removed-face)
    ("^>.*" 0 'harness-ui-patch-review-context-face))
  "How a reply shows its quote: as a diff, the comments as they are.")

(define-derived-mode harness-ui-patch-review-reply-mode text-mode "Reply"
  "Major mode of a reply to a task's changes, as to a patch on a mailing list.
The diff of the task's branch is quoted, every line after \"> \".  The
comments are the other lines: write one under the lines it is about,
or above the quote for the change as a whole; c in Ediff puts one
there for you.  \\<harness-ui-patch-review-reply-mode-map>\\[harness-ui-patch-review-send] sends the comments back to the task as its
feedback, quoting only the hunks they answer, and \\[harness-ui-patch-review-hide-reply] hides the reply.

\\{harness-ui-patch-review-reply-mode-map}"
  (setq-local font-lock-defaults '(harness-ui-patch-review--reply-keywords t))
  (setq-local fill-column harness-ui-patch-review-fill-column)
  ;; A comment fills on its own, never with the quote around it.
  (setq-local paragraph-start (concat ">\\|" paragraph-start))
  (setq-local paragraph-separate (concat ">\\|" paragraph-separate))
  (add-hook 'after-change-functions #'harness-ui-patch-review--reply-changed nil t)
  (add-hook 'kill-buffer-query-functions #'harness-ui-patch-review--reply-kill-query nil t))

(put 'harness-ui-patch-review-reply-mode 'harness-menu-group
     '("Reply"
       ["Reply to the task's changes"
        ("C-c C-c" "Send the comments back" harness-ui-patch-review-send)
        ("C-c C-k" "Hide it" harness-ui-patch-review-hide-reply)]))

(defun harness-ui-patch-review--fill-reply (review)
  "Make this buffer REVIEW's reply afresh: its whole diff quoted, no comment.
A line above the quote is left for comments on the change as a whole,
and a blank one after it, as a reply has."
  (let ((inhibit-modification-hooks t))
    (buffer-disable-undo)
    (erase-buffer)
    (insert "\n\n" (harness-ui-patch-review--quote
                  (mapconcat (lambda (file) (or (harness-ui-patch-review--f-patch file) ""))
                             (harness-ui-patch-review--r-files review) "")))
    (goto-char (point-min))
    (set-buffer-modified-p nil)
    (buffer-enable-undo))
  (setf (harness-ui-patch-review--r-reply-tip review) (harness-ui-patch-review--r-tip review)
        (harness-ui-patch-review--r-reply-merge-base review) (harness-ui-patch-review--r-merge-base review)))

(defun harness-ui-patch-review--reply-buffer (review)
  "Return REVIEW's reply, made now -- the whole diff quoted -- when it has none."
  (let ((buffer (harness-ui-patch-review--r-reply review)))
    (unless (buffer-live-p buffer)
      (require 'diff-mode)
      (setq buffer (generate-new-buffer
                    (format "*harness reply: %s*" (harness-truncate-end (harness-ui-patch-review--title review) 40))))
      (with-current-buffer buffer
        (harness-ui-patch-review-reply-mode)
        (setq harness-ui-patch-review--review review)
        (harness-ui-patch-review--fill-reply review))
      (setf (harness-ui-patch-review--r-reply review) buffer)
      (harness-ui-patch-review--render review))
    buffer))

(defun harness-ui-patch-review--sync-reply (review)
  "Quote REVIEW's diff afresh in its reply if the branch moved.
Unless the reply has comments: it keeps its quote then, and the list
says it is an older one."
  (let ((reply (harness-ui-patch-review--r-reply review)))
    (when (and (buffer-live-p reply)
               (not (equal (harness-ui-patch-review--r-reply-tip review) (harness-ui-patch-review--r-tip review))))
      (with-current-buffer reply
        (unless (harness-ui-patch-review--comment-blocks (harness-ui-patch-review--parse))
          (harness-ui-patch-review--fill-reply review))))))

(defun harness-ui-patch-review--reply-changed (&rest _)
  "Count the reply's comments again in the list, once the typing stops."
  (when-let* ((review harness-ui-patch-review--review))
    (harness-debounce (list 'harness-ui-patch-review (harness-ui-patch-review--r-id review)) 0.3
                      #'harness-ui-patch-review--render review)))

(defun harness-ui-patch-review--reply-kill-query ()
  "Ask before a reply goes with comments not sent."
  (or harness-ui-patch-review--forgetting
      (let ((count (length (harness-ui-patch-review--comment-blocks (harness-ui-patch-review--parse)))))
        (or (zerop count)
            (yes-or-no-p (format "The reply has %d comment%s not sent; kill it anyway? "
                                 count (if (= count 1) "" "s")))))))

(defun harness-ui-patch-review--add-comment (review file where text)
  "Put TEXT into REVIEW's reply as a comment on FILE, and return where it starts.
WHERE is (SIDE . LINE): under LINE of the branch's version for SIDE
:new, of the merge base's for :old; nil for the file as a whole.  A
line the quote does not show gets the comment under the nearest one,
saying which line it is about."
  (let ((reply (harness-ui-patch-review--reply-buffer review))
        start)
    (with-current-buffer reply
      (let* ((lines (harness-ui-patch-review--parse))
             (side (car where))
             (number (cdr where))
             (anchor (or (harness-ui-patch-review--anchor lines (harness-ui-patch-review--header file) side number)
                         (user-error "The reply does not quote %s" (harness-ui-patch-review--f-path file))))
             (exact (or (null side) (eql (plist-get anchor side) number))))
        (setq start (harness-ui-patch-review--insert-comment
                     (plist-get anchor :start)
                     (harness-ui-patch-review--comment-text
                      (if exact text
                        (format "On line %d%s: %s" number (if (eq side :old) " of the merge base" "") text)))))
        (goto-char start)
        (dolist (window (get-buffer-window-list reply nil t))
          (set-window-point window start))))
    (harness-ui-patch-review--render review)
    start))

;;;; The list

(defvar harness-ui-patch-review-list-mode-map (make-sparse-keymap)
  "Keymap of `harness-ui-patch-review-list-mode'.")

(let ((map harness-ui-patch-review-list-mode-map))
  (define-key map (kbd "RET") #'harness-ui-patch-review-ediff)
  (define-key map (kbd "n") #'harness-ui-patch-review-next-file)
  (define-key map (kbd "p") #'harness-ui-patch-review-previous-file)
  (define-key map (kbd "r") #'harness-ui-patch-review-reply)
  (define-key map (kbd "C-c C-c") #'harness-ui-patch-review-send)
  (define-key map (kbd "g") #'harness-ui-patch-review-refresh)
  (define-key map (kbd "q") #'harness-ui-patch-review-quit)
  (define-key map (kbd "?") #'harness-menu))

(defvar harness-ui-patch-review--row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'harness-ui-patch-review-mouse-ediff)
    (define-key map [mouse-2] #'harness-ui-patch-review-mouse-ediff)
    ;; A double click compares once.
    (define-key map [double-mouse-1] #'ignore)
    (define-key map [triple-mouse-1] #'ignore)
    map)
  "Keymap of a row of the list: a click compares its file in Ediff.")

(define-derived-mode harness-ui-patch-review-list-mode special-mode "Changes"
  "Major mode of the list of a task's changes, a row per file.
\\<harness-ui-patch-review-list-mode-map>\\[harness-ui-patch-review-ediff] compares the file at point in Ediff, its merge base against the
branch, and \\[harness-ui-patch-review-next-file] and \\[harness-ui-patch-review-previous-file] move between the files.  \\[harness-ui-patch-review-reply] shows the reply with
the comments, \\[harness-ui-patch-review-send] sends them back to the task, \\[harness-ui-patch-review-refresh] reads the branch again
and \\[harness-ui-patch-review-quit] goes back to the review.

\\{harness-ui-patch-review-list-mode-map}"
  (setq truncate-lines t)
  (setq-local revert-buffer-function (lambda (&rest _) (harness-ui-patch-review-refresh)))
  (add-hook 'post-command-hook #'harness-ui-patch-review--follow-point nil t))

;; The list's keys in the harness menu, behind `.'.
(put 'harness-ui-patch-review-list-mode 'harness-menu-group
     '("Changes"
       ["File at point"
        (". RET" "Compare in Ediff" harness-ui-patch-review-ediff)
        (". n" "Next file" harness-ui-patch-review-next-file)
        (". p" "Previous file" harness-ui-patch-review-previous-file)]
       ["Review"
        (". r" "Reply, with the comments" harness-ui-patch-review-reply)
        ("C-c C-c" "Send the comments back" harness-ui-patch-review-send)
        (". g" "Read the branch again" harness-ui-patch-review-refresh)
        (". q" "Back to the review" harness-ui-patch-review-quit)]))

(defvar-local harness-ui-patch-review--arrow nil
  "The overlay that marks the row of the file at point.")

(defun harness-ui-patch-review--follow-point ()
  "Put the mark of the file at point on its row."
  (let ((start (line-beginning-position)))
    (when (get-text-property start 'harness-ui-patch-review-file)
      (unless (overlayp harness-ui-patch-review--arrow)
        (setq harness-ui-patch-review--arrow (make-overlay start (1+ start)))
        (overlay-put harness-ui-patch-review--arrow 'display (propertize "▸" 'face 'bold)))
      (move-overlay harness-ui-patch-review--arrow start (1+ start)))))

(defun harness-ui-patch-review--list-buffer (review)
  "Return REVIEW's list buffer, made now when it has none."
  (let ((buffer (harness-ui-patch-review--r-list review)))
    (unless (buffer-live-p buffer)
      (require 'diff-mode)
      (setq buffer (generate-new-buffer
                    (format "*harness changes: %s*" (harness-truncate-end (harness-ui-patch-review--title review) 40))))
      (with-current-buffer buffer
        (harness-ui-patch-review-list-mode)
        (setq harness-ui-patch-review--review review))
      (setf (harness-ui-patch-review--r-list review) buffer))
    buffer))

(defun harness-ui-patch-review--segment (label command help)
  "Return LABEL for a header line, running COMMAND on a click, HELP its tooltip."
  (propertize label 'mouse-face 'mode-line-highlight 'help-echo help
              'local-map (harness-ui-mouse-keymap command)))

(defun harness-ui-patch-review--keyed (label command help key)
  "Return LABEL running COMMAND, with HELP, followed by KEY, for a header line."
  (concat (harness-ui-patch-review--segment label command (format "%s (%s)" help key))
          " " (harness-ui-kbd key)))

(defun harness-ui-patch-review--list-header (review)
  "Return the header line of REVIEW's list."
  (concat " " (propertize (string-replace "%" "%%" (format "Changes: %s" (harness-ui-patch-review--title review)))
                          'face 'bold)
          "   " (harness-ui-patch-review--keyed "[Ediff]" #'harness-ui-patch-review-ediff
                                                "Compare the file at point in Ediff" "RET")
          "  " (harness-ui-patch-review--keyed "[Reply]" #'harness-ui-patch-review-reply
                                               "Show the reply: the diff quoted, with the comments inline" "r")
          "  " (harness-ui-patch-review--keyed "[Send]" #'harness-ui-patch-review-send
                                               "Send the comments back to the task, as its feedback" "C-c C-c")
          "  " (harness-ui-patch-review--keyed "[Back]" #'harness-ui-patch-review-quit
                                               "Back to the review, the windows as they were" "q")))

(defun harness-ui-patch-review--reply-header (review count)
  "Return the header line of REVIEW's reply, which has COUNT comments."
  (concat " " (propertize (string-replace "%" "%%" (format "Reply: %s" (harness-ui-patch-review--title review)))
                          'face 'bold)
          "   " (harness-ui-patch-review--keyed "[Send]" #'harness-ui-patch-review-send
                                                "Send the comments back to the task, as its feedback" "C-c C-c")
          "  " (harness-ui-patch-review--keyed "[Hide]" #'harness-ui-patch-review-hide-reply
                                               "Hide the reply, keeping it" "C-c C-k")
          "   " (propertize (format "%d comment%s; only the hunks with one are sent"
                                    count (if (= count 1) "" "s"))
                            'face 'harness-dim-face)))

(defun harness-ui-patch-review--path-label (file)
  "Return the path of FILE for the list, \"OLD → NEW\" for a rename."
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

(defun harness-ui-patch-review--comment-counts (review)
  "Return the comments in REVIEW's reply: an alist of (HEADER . COUNT).
HEADER names a file as `harness-ui-patch-review--header' does, nil for
the comments on the change as a whole."
  (let ((reply (harness-ui-patch-review--r-reply review))
        counts)
    (when (buffer-live-p reply)
      (dolist (block (with-current-buffer reply
                       (harness-ui-patch-review--comment-blocks (harness-ui-patch-review--parse))))
        (let ((cell (assoc (plist-get block :file) counts)))
          (if cell (cl-incf (cdr cell)) (push (cons (plist-get block :file) 1) counts)))))
    counts))

(defun harness-ui-patch-review--plural (count word)
  "Return COUNT WORD, WORD in the plural unless COUNT is 1."
  (format "%d %s%s" count word (if (= count 1) "" "s")))

(defun harness-ui-patch-review--row (review file index width counts)
  "Return the row of FILE of REVIEW, at INDEX of its files.
The path is padded to WIDTH; COUNTS are the reply's comments."
  (let* ((comments (or (cdr (assoc (harness-ui-patch-review--header file) counts)) 0))
         (path (harness-ui-patch-review--path-label file))
         (row (concat " "
                      (if (harness-ui-patch-review--seen-p review file)
                          (propertize "✓" 'face 'harness-ui-patch-review-seen-face)
                        " ")
                      " "
                      (propertize (harness-ui-patch-review--f-status file)
                                  'face (harness-ui-patch-review--status-face file))
                      "  "
                      (string-pad (harness-truncate-middle path width) width)
                      "  "
                      (harness-ui-patch-review--change-label file)
                      (if (> comments 0)
                          (concat "   " (propertize (harness-ui-patch-review--plural comments "comment")
                                                    'face 'harness-ui-patch-review-comments-face))
                        ""))))
    (add-text-properties 0 (length row)
                         (list 'harness-ui-patch-review-file index
                               'harness-ui-patch-review-path (harness-ui-patch-review--f-path file)
                               'mouse-face 'highlight
                               'help-echo "RET or a click: compare it in Ediff"
                               'keymap harness-ui-patch-review--row-map)
                         row)
    row))

(defun harness-ui-patch-review--summary (review counts)
  "Return the first line of REVIEW's list: what is compared, how much changed.
COUNTS are the reply's comments."
  (let* ((files (harness-ui-patch-review--r-files review))
         (branch (or (harness-ui-patch-review--r-branch review)
                     (plist-get (harness-ui-patch-review--r-task review) :branch)
                     ""))
         (comments (apply #'+ (mapcar #'cdr counts))))
    (concat
     " " (propertize branch 'face 'bold)
     (if (not (harness-ui-patch-review--r-tip review)) ""
       (concat
        (propertize (format " against %s @ %s"
                            (harness-ui-patch-review--r-base review)
                            (harness-ui-patch-review--short (harness-ui-patch-review--r-merge-base review)))
                    'face 'harness-dim-face
                    'help-echo (format "The branch at %s against its merge base with %s, %s: what merging it brings in"
                                       (harness-ui-patch-review--short (harness-ui-patch-review--r-tip review))
                                       (harness-ui-patch-review--r-base review)
                                       (harness-ui-patch-review--short (harness-ui-patch-review--r-merge-base review))))
        "   " (harness-ui-patch-review--plural (length files) "file")
        "  " (propertize (format "+%d" (apply #'+ (mapcar #'harness-ui-patch-review--f-added files)))
                         'face 'harness-ui-patch-review-plus-face)
        " " (propertize (format "−%d" (apply #'+ (mapcar #'harness-ui-patch-review--f-deleted files)))
                        'face 'harness-ui-patch-review-minus-face)
        (if (> comments 0)
            (concat "   " (propertize (harness-ui-patch-review--plural comments "comment")
                                      'face 'harness-ui-patch-review-comments-face))
          ""))))))

(defun harness-ui-patch-review--notes (review)
  "Return the lines that tell what to know about REVIEW, above its files."
  (let ((task (harness-ui-patch-review--r-task review))
        (tip (harness-ui-patch-review--r-tip review))
        (reply (harness-ui-patch-review--r-reply review)))
    (delq nil
          (list
           (and (harness-ui-patch-review--r-loading review)
                (propertize " Reading the branch…" 'face 'harness-dim-face))
           (and (harness-ui-patch-review--r-error review)
                (propertize (format " Could not read the branch: %s (g tries again)"
                                    (harness-ui-patch-review--r-error review))
                            'face 'error))
           (cond ((harness-ui-patch-review--r-gone review)
                  (propertize (format " The task was %s: the reply can no longer be sent."
                                      (harness-ui-patch-review--r-gone review))
                              'face 'warning))
                 ((not (harness-ui-patch-review--reviewing-p task))
                  (propertize (format " The task is %s, not waiting for review: the reply cannot be sent now."
                                      (if (harness-json-true-p (plist-get task :archived)) "archived"
                                        (or (plist-get task :state) "gone")))
                              'face 'warning)))
           (and (harness-ui-patch-review--r-dirty review)
                (propertize " Its worktree has changes not committed: they are not on the branch, so not here."
                            'face 'warning))
           (and tip (buffer-live-p reply)
                (harness-ui-patch-review--r-reply-tip review)
                (not (equal tip (harness-ui-patch-review--r-reply-tip review)))
                (propertize (format " The reply quotes the branch at %s; it is at %s now."
                                    (harness-ui-patch-review--short (harness-ui-patch-review--r-reply-tip review))
                                    (harness-ui-patch-review--short tip))
                            'face 'warning))
           (and tip (null (harness-ui-patch-review--r-files review))
                (propertize (format " The branch changes nothing against %s." (harness-ui-patch-review--r-base review))
                            'face 'harness-dim-face))))))

(defun harness-ui-patch-review--insert-list (review)
  "Insert REVIEW's list: what it compares, what to know, a row per file."
  (let* ((files (harness-ui-patch-review--r-files review))
         (counts (harness-ui-patch-review--comment-counts review))
         (width (min 60 (apply #'max 0 (mapcar (lambda (file) (string-width (harness-ui-patch-review--path-label file)))
                                               files)))))
    (insert (harness-ui-patch-review--summary review counts) "\n")
    (dolist (note (harness-ui-patch-review--notes review))
      (insert note "\n"))
    (insert "\n")
    (cl-loop for file in files for index from 0
             do (insert (harness-ui-patch-review--row review file index width counts) "\n"))
    (when files
      (insert "\n" (propertize " n and p move between the files, g reads the branch again, ? shows every key."
                               'face 'harness-hint-face)
              "\n"))))

(defun harness-ui-patch-review--row-start (index)
  "Return where the row of the file at INDEX starts in this list, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (when (eql (get-text-property (point) 'harness-ui-patch-review-file) index)
          (setq found (point)))
        (forward-line 1))
      found)))

(defun harness-ui-patch-review--index-at-point ()
  "Return the index of the file on this line of the list, or nil."
  (get-text-property (line-beginning-position) 'harness-ui-patch-review-file))

(defun harness-ui-patch-review--render (review)
  "Draw REVIEW's list and its reply's header again.
Point stays on the file it was on, by its path."
  (let ((buffer (harness-ui-patch-review--r-list review)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((window (get-buffer-window buffer t))
               (bol (save-excursion (goto-char (if window (window-point window) (point)))
                                    (line-beginning-position)))
               (path (get-text-property bol 'harness-ui-patch-review-path))
               (index (get-text-property bol 'harness-ui-patch-review-file))
               (files (harness-ui-patch-review--r-files review))
               (inhibit-read-only t))
          (erase-buffer)
          (harness-ui-patch-review--insert-list review)
          (setq header-line-format (harness-ui-patch-review--list-header review))
          (goto-char (or (harness-ui-patch-review--row-start
                          (or (and path (cl-position path files :key #'harness-ui-patch-review--f-path :test #'equal))
                              (and index (min index (1- (length files))))
                              0))
                         (point-min)))
          (dolist (window (get-buffer-window-list buffer nil t))
            (set-window-point window (point)))
          (harness-ui-patch-review--follow-point)))))
  (let ((reply (harness-ui-patch-review--r-reply review)))
    (when (buffer-live-p reply)
      (with-current-buffer reply
        (setq header-line-format
              (harness-ui-patch-review--reply-header
               review (length (harness-ui-patch-review--comment-blocks (harness-ui-patch-review--parse)))))
        (force-mode-line-update)))))

(defun harness-ui-patch-review--goto-file (review index)
  "Put point on the row of REVIEW's file at INDEX, in the list and its windows."
  (let ((buffer (harness-ui-patch-review--r-list review)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when-let* ((pos (harness-ui-patch-review--row-start index)))
          (goto-char pos)
          (dolist (window (get-buffer-window-list buffer nil t))
            (set-window-point window pos))
          (harness-ui-patch-review--follow-point))))))

;;;; Windows

(defun harness-ui-patch-review--main-window ()
  "Return the window the list goes in: the selected one, when it may be.
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

(defun harness-ui-patch-review--show-list (review)
  "Show REVIEW's list, alone in the frame until q gives the windows back.
A list on show already is selected."
  (let* ((buffer (harness-ui-patch-review--list-buffer review))
         (shown (get-buffer-window buffer)))
    (if shown
        (select-window shown)
      (setf (harness-ui-patch-review--r-windows review) (current-window-configuration))
      (let ((window (harness-ui-patch-review--main-window)))
        (select-window window)
        ;; Side windows too: the frame is the review's until q.
        (let ((ignore-window-parameters t))
          (delete-other-windows window))
        (set-window-dedicated-p window nil)
        (set-window-buffer window buffer)
        (harness-ui-patch-review--render review)))))

(defun harness-ui-patch-review--give-back (review)
  "Give the frame back the windows REVIEW's list took, and bury its buffers.
The windows are given back while the list or the reply shows."
  (let* ((config (harness-ui-patch-review--r-windows review))
         (frame (and config (window-configuration-frame config)))
         (buffers (list (harness-ui-patch-review--r-list review) (harness-ui-patch-review--r-reply review))))
    (setf (harness-ui-patch-review--r-windows review) nil)
    ;; The frame the list took, whichever is selected: the reply may
    ;; have been sent from another.
    (when (and (frame-live-p frame)
               (cl-some (lambda (buffer) (and (buffer-live-p buffer) (get-buffer-window buffer frame))) buffers))
      (ignore-errors (set-window-configuration config)))
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (dolist (window (get-buffer-window-list buffer nil t))
          (quit-window nil window))
        (bury-buffer-internal buffer)))))

(defun harness-ui-patch-review--show-reply (review)
  "Show REVIEW's reply beside its list, and select it."
  (let* ((reply (harness-ui-patch-review--reply-buffer review))
         (shown (get-buffer-window reply)))
    (if shown
        (select-window shown)
      (let* ((list (harness-ui-patch-review--r-list review))
             (beside (and (buffer-live-p list) (get-buffer-window list)))
             (window (cond ((null beside) (selected-window))
                           ((>= (window-total-width beside) 100)
                            (split-window beside (- (round (* 0.6 (window-total-width beside)))) 'right))
                           (t (split-window beside nil 'below)))))
        (set-window-buffer window reply)
        (select-window window)))))

;;;; Commands of the list and the reply

(defun harness-ui-patch-review (&optional task)
  "Review the changes of TASK, a task waiting for review, file by file.
Interactively, the task of this buffer: the session or the report of a
task in review, or a review of its changes already.  The list of the
files its branch changes takes the frame: \\<harness-ui-patch-review-list-mode-map>\\[harness-ui-patch-review-ediff] compares one in Ediff,
c there comments on a difference, \\[harness-ui-patch-review-reply] shows the reply with the comments,
\\[harness-ui-patch-review-send] sends them back to the task, and \\[harness-ui-patch-review-quit] gives the windows back."
  (interactive)
  (let ((task (or task
                  (and harness-ui-patch-review--review
                       (harness-ui-patch-review--r-task harness-ui-patch-review--review))
                  (if (fboundp 'harness-ui-review-current-task)
                      (harness-ui-review-current-task)
                    (user-error "No task waits for review here")))))
    (unless (harness-ui-patch-review--offered-p task)
      (user-error "%s" (harness-ui-patch-review--why-not task)))
    (let ((review (harness-ui-patch-review--review-for task)))
      (harness-ui-patch-review--show-list review)
      (harness-ui-patch-review--load review))))

(defun harness-ui-patch-review-refresh ()
  "Read the task's branch again: it may have moved on."
  (interactive)
  (harness-ui-patch-review--load (harness-ui-patch-review--current))
  nil)

(defun harness-ui-patch-review-quit ()
  "Go back to the review: the windows as they were before the list took the frame.
The review stays as it is -- the files seen, the reply and its
comments -- for [Changes] to open again, unless its task is gone."
  (interactive)
  (let ((review (harness-ui-patch-review--current)))
    (if (or (harness-ui-patch-review--r-gone review)
            (not (gethash (harness-ui-patch-review--r-id review) harness-ui-patch-review--reviews)))
        (harness-ui-patch-review--forget review)
      (harness-ui-patch-review--give-back review))))

(defun harness-ui-patch-review--step-point (step)
  "Move point STEP files on in the list."
  (let* ((review (harness-ui-patch-review--current))
         (count (length (harness-ui-patch-review--r-files review)))
         (index (harness-ui-patch-review--index-at-point))
         (target (if index (+ index step) (if (> step 0) 0 (1- count)))))
    (cond ((zerop count) (user-error "No files"))
          ((< target 0) (user-error "No previous file"))
          ((>= target count) (user-error "No next file"))
          (t (harness-ui-patch-review--goto-file review target)))))

(defun harness-ui-patch-review-next-file (&optional n)
  "Move to the next file of the list, or the Nth next."
  (interactive "p")
  (harness-ui-patch-review--step-point (or n 1)))

(defun harness-ui-patch-review-previous-file (&optional n)
  "Move to the previous file of the list, or the Nth previous."
  (interactive "p")
  (harness-ui-patch-review--step-point (- (or n 1))))

(defun harness-ui-patch-review-reply ()
  "Show the reply beside the list: the diff quoted, with the comments inline.
Write a comment under the lines it is about, or above the quote for the
change as a whole; \\<harness-ui-patch-review-reply-mode-map>\\[harness-ui-patch-review-send] sends the comments back to the task."
  (interactive)
  (let ((review (harness-ui-patch-review--current)))
    (unless (harness-ui-patch-review--r-tip review)
      (user-error "The branch is not read yet"))
    (harness-ui-patch-review--show-reply review)))

(defun harness-ui-patch-review-hide-reply ()
  "Hide the reply, keeping it and its comments: the list shows instead."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (list (harness-ui-patch-review--list-buffer review))
         (beside (get-buffer-window list)))
    (if (and beside (not (eq beside (selected-window))) (not (one-window-p)))
        (progn (delete-window (selected-window))
               (select-window beside))
      (set-window-buffer (selected-window) list))))

(defun harness-ui-patch-review-send ()
  "Send the comments of the reply back to the task as its feedback, in one go.
The reply goes as it is, with only the hunks that have a comment
quoted, after a line that tells the task how to read it.  The task
works on it again and comes back for review; the review of its changes
ends, and the windows are given back."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (title (harness-ui-patch-review--title review))
         (reply (harness-ui-patch-review--r-reply review))
         (lines (and (buffer-live-p reply) (with-current-buffer reply (harness-ui-patch-review--parse))))
         (body (harness-ui-patch-review--outgoing lines))
         (count (length (harness-ui-patch-review--comment-blocks lines))))
    (when (or (harness-ui-patch-review--r-gone review)
              (not (harness-ui-patch-review--reviewing-p (harness-ui-patch-review--r-task review))))
      (user-error "%s no longer waits for review" title))
    (unless body
      (user-error "There is no comment to send: c in Ediff makes one, or write in the reply (r)"))
    (message "Sending the review of %s…" title)
    (harness-ui-call "_harness/task/reject"
                     (list :id (harness-ui-patch-review--r-id review)
                           :feedback (concat (harness-ui-patch-review--preface review) "\n\n" body))
                     (lambda (_task)
                       (harness-ui-patch-review--forget review)
                       (message "Sent %s back to %s" (harness-ui-patch-review--plural count "comment") title))
                     (lambda (err)
                       (message "Could not send the review: %s" (harness-error-message err))
                       nil))))

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

(defun harness-ui-patch-review-ediff (&optional index)
  "Compare the file at point in Ediff: at the merge base, and on the branch.
In Ediff, c comments on the current difference, N and P go on to the
next or previous file, and q comes back to the list.  INDEX is that of
the file to compare, by default the one at point."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (index (or index (harness-ui-patch-review--index-at-point) (user-error "No file on this line")))
         (file (or (nth index (harness-ui-patch-review--r-files review)) (user-error "No such file")))
         (why (harness-ui-patch-review--incomparable file)))
    (if why
        (progn (harness-ui-patch-review--mark-seen review file)
               (harness-ui-patch-review--render review)
               (message "%s" why)
               nil)
      (message "Reading %s…" (harness-ui-patch-review--f-path file))
      (harness-then
       (harness-all (list (harness-ui-patch-review--blob review (harness-ui-patch-review--f-old-blob file))
                          (harness-ui-patch-review--blob review (harness-ui-patch-review--f-new-blob file))))
       (lambda (texts)
         (harness-ui-patch-review--start-ediff review index (nth 0 texts) (nth 1 texts))
         review)
       (lambda (err)
         (message "Could not read %s: %s" (harness-ui-patch-review--f-path file) (harness-error-message err))
         nil)))))

(defun harness-ui-patch-review-mouse-ediff (event)
  "Compare the file clicked on in EVENT in Ediff."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-patch-review-ediff))

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
          "   " (harness-ui-patch-review--help-button "[Back to the list]" #'harness-ui-patch-review-ediff-quit "q")
          "   " (propertize "? Ediff's keys" 'face 'harness-dim-face)))

(defun harness-ui-patch-review--start-ediff (review index old new)
  "Compare OLD and NEW, the texts of REVIEW's file at INDEX, in Ediff.
A comparison of the review under way ends first: one at a time.  The
frame's windows are saved, to give back when it ends."
  (require 'ediff)
  (let* ((file (nth index (harness-ui-patch-review--r-files review)))
         (before (harness-ui-patch-review--r-ediff review))
         (windows (and (buffer-live-p (plist-get before :control)) (plist-get before :windows))))
    (when windows (harness-ui-patch-review--end-ediff review t))
    (let* ((list (harness-ui-patch-review--r-list review))
           ;; In any frame: this runs once git has answered, when the
           ;; frame selected need not be the list's.
           (beside (and (buffer-live-p list) (get-buffer-window list t))))
      (when beside (select-window beside))
      (let ((a (harness-ui-patch-review--side-buffer review file 'old old))
            (b (harness-ui-patch-review--side-buffer review file 'new new)))
        (setf (harness-ui-patch-review--r-ediff review)
              (list :index index :a a :b b :windows (or windows (current-window-configuration))))
        (condition-case err
            (let ((ediff-window-setup-function (or harness-ui-patch-review-ediff-window-setup
                                                   ediff-window-setup-function))
                  (ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help))
              (with-current-buffer (if (buffer-live-p list) list (current-buffer))
                (ediff-buffers a b (list (lambda () (harness-ui-patch-review--ediff-startup review index))))))
          (error
           (harness-ui-patch-review--ediff-ended review index)
           (message "Ediff could not compare %s: %s"
                    (harness-ui-patch-review--f-path file) (error-message-string err))))))))

(defun harness-ui-patch-review--ediff-startup (review index)
  "Make this Ediff control panel compare REVIEW's file at INDEX.
It gets the review's keys and help, and gives the list back as it ends."
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

(defun harness-ui-patch-review--ediff-ended (review index)
  "Tidy up after the Ediff of REVIEW's file at INDEX, and go on as it said.
Its two versions go, the frame gets the list back, with point on the
next file, and the file is seen.  N and P go on to the next or previous
file Ediff can compare."
  (let* ((state (harness-ui-patch-review--r-ediff review))
         (then (plist-get state :then))
         (quiet (plist-get state :quiet)))
    (setf (harness-ui-patch-review--r-ediff review) nil)
    (dolist (buffer (list (plist-get state :a) (plist-get state :b)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (harness-ui-patch-review--mark-seen review (nth index (harness-ui-patch-review--r-files review)))
    (unless quiet
      (when-let* ((windows (plist-get state :windows)))
        ;; Not when its frame went meanwhile.
        (ignore-errors (set-window-configuration windows)))
      (harness-ui-patch-review--render review)
      (harness-ui-patch-review--goto-file
       review (min (1+ index) (max 0 (1- (length (harness-ui-patch-review--r-files review))))))
      (when then
        (run-at-time 0 nil #'harness-ui-patch-review--step review index then)))))

(defun harness-ui-patch-review--really-quit ()
  "Quit the Ediff of this control panel without a question.
Its two versions are the review's, which kills them itself."
  (let ((this-command 'ediff-quit)
        (ediff-keep-variants t))
    (ediff-really-quit nil)))

(defun harness-ui-patch-review--end-ediff (review &optional quiet)
  "End the Ediff of REVIEW under way, if there is one.
The list gets back the windows it had, unless QUIET: then the windows
stay as they are, for another comparison to take, or because Ediff is
out of sight."
  (let ((control (plist-get (harness-ui-patch-review--r-ediff review) :control)))
    (when (buffer-live-p control)
      (setf (harness-ui-patch-review--r-ediff review)
            (plist-put (harness-ui-patch-review--r-ediff review) :quiet quiet))
      (let ((quit (lambda () (with-current-buffer control (harness-ui-patch-review--really-quit)))))
        (if quiet
            ;; Ediff shows its two versions again as it quits.
            (save-window-excursion (funcall quit))
          (funcall quit))))))

(defun harness-ui-patch-review--step (review index step)
  "Compare the file STEP files on from INDEX in REVIEW that Ediff can compare."
  (let ((files (harness-ui-patch-review--r-files review))
        (next (+ index step))
        found)
    (while (and (not found) (>= next 0) (< next (length files)))
      (if (harness-ui-patch-review--incomparable (nth next files))
          (setq next (+ next step))
        (setq found next)))
    (if (not found)
        (message (if (> step 0) "That was the last file" "That was the first file"))
      (harness-ui-patch-review--goto-file review found)
      (with-current-buffer (harness-ui-patch-review--list-buffer review)
        (harness-ui-patch-review-ediff found)))))

(defun harness-ui-patch-review--quit-ediff (then)
  "End this Ediff of a task's change, then go THEN files on, or stay on the list."
  (let ((review (harness-ui-patch-review--current)))
    (setf (harness-ui-patch-review--r-ediff review)
          (plist-put (harness-ui-patch-review--r-ediff review) :then then))
    (harness-ui-patch-review--really-quit)))

(defun harness-ui-patch-review-ediff-quit ()
  "Back to the list of the task's changes, without asking."
  (interactive)
  (harness-ui-patch-review--quit-ediff nil))

(defun harness-ui-patch-review-ediff-next-file ()
  "On to the next file of the task's changes, in Ediff."
  (interactive)
  (harness-ui-patch-review--quit-ediff 1))

(defun harness-ui-patch-review-ediff-previous-file ()
  "On to the previous file of the task's changes, in Ediff."
  (interactive)
  (harness-ui-patch-review--quit-ediff -1))

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
In the Ediff of a task's change.  The comment goes into the reply under
the difference's lines in the quote of the diff, after any comment
there already: the branch's lines, or the merge base's for a difference
that only deletes.  Without a current difference it is a comment on
the file as a whole."
  (interactive (list (read-string (harness-ui-patch-review--comment-prompt))))
  (let* ((review (harness-ui-patch-review--current))
         (file (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review))))
    (if (string-blank-p text)
        (message "No comment")
      (harness-ui-patch-review--add-comment review file (harness-ui-patch-review--ediff-position) text)
      (message "Put in the reply: %s"
               (harness-ui-patch-review--plural
                (or (cdr (assoc (harness-ui-patch-review--header file)
                                (harness-ui-patch-review--comment-counts review)))
                    0)
                (format "comment on %s" (harness-ui-patch-review--f-path file)))))))

;;;; Following the tasks

(defun harness-ui-patch-review--ended (review why)
  "REVIEW's task is WHY now -- done, or deleted: the review is over.
Its buffers go when nothing shows them; otherwise the list says so,
and they go on q."
  (setf (harness-ui-patch-review--r-gone review) why)
  (if (cl-some (lambda (buffer) (and (buffer-live-p buffer) (get-buffer-window buffer t)))
               (append (list (harness-ui-patch-review--r-list review) (harness-ui-patch-review--r-reply review))
                       (harness-ui-patch-review--ediff-buffers review)))
      (harness-ui-patch-review--render review)
    (harness-ui-patch-review--forget review)))

(defun harness-ui-patch-review--on-event (event args)
  "Follow the tasks under review: EVENT about a task, with ARGS."
  (pcase event
    ((or "task/changed" "task/review" "task/done")
     (let* ((task (car args))
            (review (gethash (plist-get task :id) harness-ui-patch-review--reviews)))
       (when review
         (setf (harness-ui-patch-review--r-task review) task)
         (pcase event
           ("task/done" (harness-ui-patch-review--ended review "done"))
           ;; Back for review, maybe with more commits.
           ("task/review" (harness-ui-patch-review--load review))
           (_ (harness-ui-patch-review--render review))))))
    ("task/deleted"
     (when-let* ((review (gethash (car args) harness-ui-patch-review--reviews)))
       (harness-ui-patch-review--ended review "deleted")))))

;;;; Where [Changes] shows

(defun harness-ui-patch-review--banner-button (task)
  "Return [Changes] for the review banner of TASK, when it can be offered.
On `harness-ui-review-button-functions'.  The command finds its task in
the buffer the banner is in, so the banner shows its key."
  (and (harness-ui-patch-review--offered-p task)
       (list "[Changes]" #'harness-ui-patch-review harness-ui-patch-review--button-help)))

(defun harness-ui-patch-review--card-button (task)
  "Return [Changes] for the card of TASK, when it can be offered.
On `harness-ui-tasks-card-button-functions'."
  (and (harness-ui-patch-review--offered-p task)
       (list "[Changes]" (lambda () (harness-ui-patch-review task)) harness-ui-patch-review--button-help)))

(defconst harness-ui-patch-review--menu-item
  '("C-c C-d" "Changes, file by file" harness-ui-patch-review)
  "The entry of [Changes] in the menu of the review banner's keys.")

(defun harness-ui-patch-review--hook-into-review ()
  "Give the review banner's keys one for [Changes], and their menu too.
Done again whenever harness-ui-review.el loads, which sets both anew."
  (when (and harness-ui-patch-review--active (boundp 'harness-ui-review-minor-mode-map))
    (define-key harness-ui-review-minor-mode-map (kbd "C-c C-d") #'harness-ui-patch-review)
    (pcase (get 'harness-ui-review-minor-mode 'harness-menu-group)
      (`(,title ,column . ,columns)
       (unless (member harness-ui-patch-review--menu-item (append column nil))
         (put 'harness-ui-review-minor-mode 'harness-menu-group
              (cons title (cons (vconcat column (list harness-ui-patch-review--menu-item)) columns))))))))

(defun harness-ui-patch-review--unhook-from-review ()
  "Take the key of [Changes] and its menu entry out of the review banner's."
  (when (boundp 'harness-ui-review-minor-mode-map)
    (when (eq (lookup-key harness-ui-review-minor-mode-map (kbd "C-c C-d")) #'harness-ui-patch-review)
      (define-key harness-ui-review-minor-mode-map (kbd "C-c C-d") nil t)))
  (pcase (get 'harness-ui-review-minor-mode 'harness-menu-group)
    (`(,title . ,columns)
     (put 'harness-ui-review-minor-mode 'harness-menu-group
          (cons title (mapcar (lambda (column)
                                (vconcat (remove harness-ui-patch-review--menu-item (append column nil))))
                              columns))))))

(with-eval-after-load 'harness-ui-review
  (harness-ui-patch-review--hook-into-review))

;;;; Module

(defun harness-ui-patch-review--init ()
  "Offer [Changes] on the review banner and on the cards of tasks in review."
  (setq harness-ui-patch-review--active t)
  (add-hook 'harness-ui-review-button-functions #'harness-ui-patch-review--banner-button)
  (add-hook 'harness-ui-tasks-card-button-functions #'harness-ui-patch-review--card-button)
  (add-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event)
  (harness-ui-patch-review--hook-into-review))

(defun harness-ui-patch-review--shutdown ()
  "Take [Changes] away again; the reviews under way stay as they are."
  (setq harness-ui-patch-review--active nil)
  (remove-hook 'harness-ui-review-button-functions #'harness-ui-patch-review--banner-button)
  (remove-hook 'harness-ui-tasks-card-button-functions #'harness-ui-patch-review--card-button)
  (remove-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event)
  (harness-ui-patch-review--unhook-from-review))

(harness-define-module 'ui-patch-review
  :doc "Review a task's changes as a patch: file by file in Ediff, then a reply with comments inline."
  :requires '(ui)
  :init #'harness-ui-patch-review--init
  :shutdown #'harness-ui-patch-review--shutdown)

(provide 'harness-ui-patch-review)
;;; harness-ui-patch-review.el ends here
