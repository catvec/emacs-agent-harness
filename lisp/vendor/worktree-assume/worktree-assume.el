;;; worktree-assume.el --- Assume a git worktree as the project  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; Author: catvec
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: vc, convenience

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A repository often has more than one working tree: `git worktree add'
;; makes another one, on another branch, in another directory.  To look
;; at the files of such a worktree you used to find out where it is and
;; open it in Dired.  This library lets you *assume* it instead, as you
;; assume a role with AWS STS: from then on the project you are in is
;; that worktree, and it stays so until you reset.
;;
;;   M-x worktree-assume        pick one of the project's other worktrees
;;   M-x worktree-assume-reset  go back to the project's own worktree
;;
;; While a worktree is assumed, everything that asks which project a
;; directory is in -- `project-current', and so `project-find-file',
;; `project-dired', `project-find-regexp', `project-switch-project' and
;; the rest, and projectile's `projectile-project-root' too -- is
;; answered with the worktree, for every directory of the project
;; assumed *for*.  The worktree is a full project: its files, its
;; buffers, its root.  Directories of the worktree itself, of any other
;; worktree and of other projects are unchanged.
;;
;; The project assumed for keeps being known.  `worktree-assume-parent'
;; says, for a directory in the assumed worktree, which project that is;
;; `worktree-assume-assumed' says, for a directory in the project, which
;; worktree stands in for it; and code that must see the project as it
;; really is, because it keys its own data by it, wraps itself in
;; `worktree-assume-with-parent'.  `worktree-assume-change-functions'
;; runs when an assumption comes or goes.
;;
;; `worktree-assume-mode' is what makes the assumptions count.
;; `worktree-assume' turns it on, and turning it off forgets them all.
;; While one stands, the mode line shows it.
;;
;; The project assumed for is whichever project finder says: normally the
;; repository's main worktree, but a linked one works as well, and so does
;; a project that is only a directory of its repository, which assumes
;; the same directory of the other worktree.  Only local git worktrees
;; are handled.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)

(defgroup worktree-assume nil
  "Assume a git worktree as the project."
  :group 'project
  :prefix "worktree-assume-")

(defcustom worktree-assume-lighter " ⇒%s"
  "Format of the mode line text while a worktree is assumed.
%s stands for the assumed worktree's name, or for how many are
assumed when there are several.  See `worktree-assume-mode'."
  :type 'string
  :group 'worktree-assume)

(defcustom worktree-assume-lighter-width 16
  "Most characters of a worktree's name that the mode line shows."
  :type 'natnum
  :group 'worktree-assume)

(defface worktree-assume-lighter '((t :inherit warning))
  "Face of the mode line text while a worktree is assumed."
  :group 'worktree-assume)

(defvar worktree-assume-change-functions nil
  "Abnormal hook run after an assumption comes, changes or goes.
Each function is called with two arguments: PARENT, the root of the
project the worktree stands in for, and ASSUMED, the root of the
worktree now assumed for it, or nil once PARENT is its own worktree
again.  Both are absolute directory names.")

(defvar worktree-assume-mode)

(defvar worktree-assume-inhibit nil
  "Non-nil makes every lookup of a project ignore the assumptions.
Bind it with `worktree-assume-with-parent' to see the project as it
really is.")

(defmacro worktree-assume-with-parent (&rest body)
  "Evaluate BODY as if no worktree were assumed.
Project lookups in BODY (`project-current', `projectile-project-root')
find the project itself, the parent the assumed worktree stands in
for, not the worktree.  For code that must go on with the real project
while the rest of Emacs works in the worktree."
  (declare (indent 0) (debug t))
  `(let ((worktree-assume-inhibit t)) ,@body))

;;;; Names

(defun worktree-assume--dir (dir)
  "Return DIR as an absolute directory name, with a trailing slash."
  (file-name-as-directory (expand-file-name dir)))

(defvar worktree-assume--true-names (make-hash-table :test #'equal)
  "Memo of `worktree-assume--true': directory name -> its true name.
Emptied whenever an assumption changes.")

(defun worktree-assume--true (dir)
  "Return the true name of DIR, as a directory name.
Symbolic links are resolved, so that two spellings of a place match.
A remote name is returned as it is: it is no business of this library,
and looking at it would reach a remote host."
  (let ((dir (worktree-assume--dir dir)))
    (if (file-remote-p dir)
        dir
      (or (gethash dir worktree-assume--true-names)
          (progn
            (when (> (hash-table-count worktree-assume--true-names) 256)
              (clrhash worktree-assume--true-names))
            (puthash dir (file-name-as-directory (file-truename dir))
                     worktree-assume--true-names))))))

(defun worktree-assume--linked-worktree-p (dir)
  "Non-nil when DIR is the top directory of a linked worktree.
That is a directory with a .git file naming a directory below a
\"worktrees\" one of its repository's, which has a commondir file, as
`git worktree add' writes.  A submodule's .git file names one below
\"modules\", and a repository with a git directory of its own, named
worktrees or not, has no commondir: neither is a worktree."
  (let ((dotgit (expand-file-name ".git" dir)))
    (and (file-regular-p dotgit)
         (let ((gitdir (with-temp-buffer
                         (insert-file-contents dotgit nil 0 1024)
                         (and (looking-at "gitdir: \\(.*/worktrees/[^/\n]+\\)[ \t]*$")
                              (match-string 1)))))
           (and gitdir
                (file-exists-p (expand-file-name "commondir"
                                                 (expand-file-name gitdir dir))))))))

(defun worktree-assume--below-p (dir top)
  "Non-nil when the true name DIR is below the true name TOP, in no other worktree.
DIR is in the worktree TOP is the top directory of unless another one,
linked, lies between them: the main worktree holds the linked worktrees
made below it, which are no part of it."
  (and (string-prefix-p top dir)
       (let ((d (directory-file-name dir))
             (stop (directory-file-name top))
             (nested nil))
         (while (and (not nested) (> (length d) (length stop)))
           (if (worktree-assume--linked-worktree-p d)
               (setq nested t)
             (setq d (directory-file-name (file-name-directory d)))))
         (not nested))))

(defun worktree-assume--inside-p (dir top)
  "Non-nil when DIR is in the worktree whose top directory is TOP.
DIR is TOP, or below it and in no other worktree below TOP, whichever way
each is spelled.  Remote names are never inside."
  (unless (or (file-remote-p dir) (file-remote-p top))
    (let ((dir (worktree-assume--dir dir))
          (top (worktree-assume--dir top)))
      (or (worktree-assume--below-p dir top)
          (worktree-assume--below-p (worktree-assume--true dir) (worktree-assume--true top))))))

;;;; The assumptions

(cl-defstruct (worktree-assume--entry
               (:constructor worktree-assume--make-entry (parent parent-true top root))
               (:copier nil))
  "An assumption: a worktree standing in for a project."
  ;; The project's root, as its finder gave it.
  parent
  ;; Its true name, to match the project however it is spelled.
  parent-true
  ;; The top directory of the assumed worktree.
  top
  ;; The root of the project assumed: TOP, or a directory of the
  ;; worktree, when the project is only that directory of its repository.
  root)

(defvar worktree-assume--entries nil
  "The assumptions that stand, a list of `worktree-assume--entry'.")

(defun worktree-assume--name (entry)
  "Return the name of the worktree ENTRY assumes: its directory's."
  (file-name-nondirectory (directory-file-name (worktree-assume--entry-top entry))))

(defun worktree-assume--entry-for-root (root)
  "Return the assumption standing in for the project with root ROOT, or nil."
  (when worktree-assume--entries
    (let ((root (worktree-assume--dir root)))
      (or (cl-find root worktree-assume--entries
                   :key #'worktree-assume--entry-parent :test #'equal)
          (cl-find (worktree-assume--true root) worktree-assume--entries
                   :key #'worktree-assume--entry-parent-true :test #'equal)))))

(defun worktree-assume--forget (entry)
  "Drop ENTRY from the assumptions, and tell about it soon.
The change hook and the message wait for idle time: this runs deep in
a lookup of a project, where a hook function should not."
  (setq worktree-assume--entries (delq entry worktree-assume--entries))
  (worktree-assume--changed (worktree-assume--entry-parent entry) nil 'defer)
  (let ((top (worktree-assume--entry-top entry))
        (root (worktree-assume--entry-root entry)))
    (run-at-time 0 nil #'message "%s: %s is its own worktree again"
                 (if (file-directory-p top)
                     (format "Worktree %s has no %s" (worktree-assume--name entry)
                             (directory-file-name (file-relative-name root top)))
                   (format "Worktree %s is gone" (worktree-assume--name entry)))
                 (abbreviate-file-name (worktree-assume--entry-parent entry)))))

(defun worktree-assume--live-root (entry)
  "Return the root ENTRY assumes, or nil, forgetting ENTRY, when it is gone."
  (let ((root (worktree-assume--entry-root entry)))
    (if (file-directory-p root)
        root
      (worktree-assume--forget entry)
      nil)))

(defun worktree-assume--run-change-functions (parent assumed)
  "Run `worktree-assume-change-functions' with PARENT and ASSUMED.
A function that signals is reported, and the others run all the same:
an assumption is made and the hook told, never the other way round."
  (run-hook-wrapped
   'worktree-assume-change-functions
   (lambda (function &rest args)
     (condition-case err
         (apply function args)
       (error (message "worktree-assume-change-functions: %s: %s"
                       (if (symbolp function) function "a function")
                       (error-message-string err))))
     nil)
   parent assumed))

(defun worktree-assume--changed (parent assumed &optional defer)
  "Note that the worktree assumed for PARENT is now ASSUMED, or none if nil.
Run `worktree-assume-change-functions', now, or at idle time with DEFER."
  (clrhash worktree-assume--true-names)
  (force-mode-line-update t)
  (if defer
      (run-at-time 0 nil #'worktree-assume--run-change-functions parent assumed)
    (worktree-assume--run-change-functions parent assumed)))

;;;; Finding the project

(defun worktree-assume-project-find (dir)
  "Return the project of the worktree assumed for DIR's project, or nil.
An entry of `project-find-functions', ahead of the others: DIR's project
is found as the others find it, and when a worktree stands in for it,
the project in that worktree is returned instead.  A project is
returned only for a directory of the project assumed for; the worktree's
own directories are found by the others, as are those of other projects.
Never signals: an error here would break every lookup of a project."
  (when (and worktree-assume--entries
             (not worktree-assume-inhibit)
             (not (file-remote-p dir)))
    (ignore-errors
      (let ((native (let ((worktree-assume-inhibit t))
                      (run-hook-with-args-until-success 'project-find-functions dir))))
        (when-let* ((native)
                    (entry (worktree-assume--entry-for-root (project-root native)))
                    (root (worktree-assume--live-root entry)))
          (worktree-assume--project root))))))

(defun worktree-assume--project (root)
  "Return the project instance whose root is the directory ROOT."
  (let* ((root (worktree-assume--dir root))
         (native (let ((worktree-assume-inhibit t))
                   (run-hook-with-args-until-success 'project-find-functions root))))
    ;; Where the finders see no project there, or a bigger one around it,
    ;; the directory is a project all the same.
    (if (and native (equal (worktree-assume--dir (project-root native)) root))
        native
      (cons 'transient root))))

(defun worktree-assume--projectile-root (root)
  "Return the root of the worktree assumed for ROOT, or ROOT itself.
Filters the value of `projectile-project-root' while the mode is on."
  (or (and root
           worktree-assume--entries
           (not worktree-assume-inhibit)
           (not (file-remote-p root))
           (ignore-errors
             (when-let* ((entry (worktree-assume--entry-for-root root)))
               (worktree-assume--live-root entry))))
      root))

(defun worktree-assume--project-root (&optional dir)
  "Return the root of the project DIR is in, as the finders see it.
DIR defaults to `default-directory'.  Signal a `user-error' where there
is no project, or only a remote one."
  (let ((dir (worktree-assume--dir (or dir default-directory))))
    ;; Before the finders look: they would reach the remote host.
    (when (file-remote-p dir)
      (user-error "%s is remote: only local worktrees can be assumed"
                  (abbreviate-file-name dir)))
    (let ((project (worktree-assume-with-parent (project-current nil dir))))
      (unless project
        (user-error "%s is not in a project" (abbreviate-file-name dir)))
      (let ((root (worktree-assume--dir (project-root project))))
        (when (file-remote-p root)
          (user-error "%s is remote: only local worktrees can be assumed"
                      (abbreviate-file-name root)))
        root))))

(defun worktree-assume--stand-in (&optional dir)
  "Return the root of the project a worktree is to stand in for, for DIR.
That is DIR's project, `default-directory''s by default, as the finders
see it; or, where DIR is in a worktree that is assumed already, the
project it stands in for, so that a worktree assumed there replaces it."
  (or (worktree-assume-parent dir)
      (worktree-assume--project-root dir)))

;;;; The worktrees of a repository

(defun worktree-assume--unquote (text)
  "Return TEXT as git wrote it, with the quotes and escapes of a C string undone.
Git quotes a file name that has a quote, a backslash or a control
character in it, and bytes outside ASCII unless `core.quotePath' says
not to.  A TEXT that does not start with a quote is returned as it is."
  (if (not (string-prefix-p "\"" text))
      text
    (let* ((inner (string-remove-suffix "\"" (substring text 1)))
           (size (length inner))
           (bytes nil)
           (i 0))
      (while (< i size)
        (let ((c (aref inner i)))
          (cond
           ((and (eq c ?\\) (< (1+ i) size))
            (let ((next (aref inner (1+ i))))
              (if (and (<= ?0 next ?3) (<= (+ i 4) size)
                       (string-match-p "\\`[0-7]\\{3\\}\\'" (substring inner (1+ i) (+ i 4))))
                  (progn (push (string-to-number (substring inner (1+ i) (+ i 4)) 8) bytes)
                         (setq i (+ i 4)))
                (push (pcase next (?n ?\n) (?t ?\t) (?a 7) (?b 8) (?f 12) (?r ?\r) (?v 11) (_ next))
                      bytes)
                (setq i (+ i 2)))))
           (t (dolist (byte (append (encode-coding-string (string c) 'utf-8) nil))
                (push byte bytes))
              (setq i (1+ i))))))
      (decode-coding-string (apply #'unibyte-string (nreverse bytes)) 'utf-8))))

(defun worktree-assume--parse-worktrees (output)
  "Return the worktrees `git worktree list --porcelain' printed as OUTPUT.
Each is a plist: :path (a directory name), :head, :branch (without
\"refs/heads/\"), :main (the first of them, the main worktree),
:detached, :bare, and :locked and :prunable, each t or the reason.
OUTPUT is as `-z' makes it, a NUL ending each line and one more each
record, or else lines, a blank one between the records, with the names
git finds unusual quoted."
  (let* ((null-separated (string-search "\0" output))
         (records (if null-separated
                      (split-string output "\0\0" t)
                    (split-string output "\n\n" t "[ \t\n]+")))
         (first t)
         (worktrees nil))
    (dolist (record records)
      (let ((worktree nil))
        (dolist (line (split-string record (if null-separated "\0" "\n") t))
          (let* ((space (string-search " " line))
                 (key (if space (substring line 0 space) line))
                 (value (and space (if null-separated
                                       (substring line (1+ space))
                                     (worktree-assume--unquote (substring line (1+ space)))))))
            (pcase key
              ("worktree" (setq worktree (plist-put worktree :path (file-name-as-directory value))))
              ("HEAD" (setq worktree (plist-put worktree :head value)))
              ("branch" (setq worktree (plist-put worktree :branch
                                                  (string-remove-prefix "refs/heads/" value))))
              ("detached" (setq worktree (plist-put worktree :detached t)))
              ("bare" (setq worktree (plist-put worktree :bare t)))
              ("locked" (setq worktree (plist-put worktree :locked (or value t))))
              ("prunable" (setq worktree (plist-put worktree :prunable (or value t)))))))
        (when (plist-get worktree :path)
          (when first (setq worktree (plist-put worktree :main t)))
          (setq first nil)
          (push worktree worktrees))))
    (nreverse worktrees)))

(defvar worktree-assume--null-separated 'unknown
  "Whether this git lists worktrees with `-z': t, `no', or `unknown' until tried.
Git knows `-z' of `worktree list' from 2.36 on; an older one is asked once.")

(defun worktree-assume--git-list (null-separated)
  "List the worktrees with git, in `default-directory', -z if NULL-SEPARATED.
Run `git worktree list --porcelain'.  Return (STATUS . OUTPUT), STATUS
nil where git cannot be run at all."
  (with-temp-buffer
    (let* ((coding-system-for-read 'utf-8-unix)
           (status (condition-case nil
                       (apply #'process-file "git" nil (list (current-buffer) nil) nil
                              "-c" "core.quotePath=false"
                              "worktree" "list" "--porcelain"
                              (and null-separated '("-z")))
                     (file-error nil))))
      (cons status (buffer-string)))))

(defun worktree-assume-worktrees (&optional dir)
  "Return the worktrees of the git repository DIR is in, a list of plists.
DIR defaults to `default-directory'.  The first is the main worktree.
Each has :path, the worktree's directory name, and, as git knows them,
:head, :branch, :detached, :bare, :locked and :prunable; see
`git worktree list'.  Signal a `user-error' when git cannot say."
  (let* ((default-directory (worktree-assume--dir (or dir default-directory)))
         (nul (and (not (eq worktree-assume--null-separated 'no))
                   (worktree-assume--git-list t)))
         (result (if (eql (car nul) 0)
                     (progn (setq worktree-assume--null-separated t) nul)
                   (let ((lines (worktree-assume--git-list nil)))
                     ;; Without -z it works: git is too old for it, which it
                     ;; need not be asked again.
                     (when (and nul (eql (car lines) 0))
                       (setq worktree-assume--null-separated 'no))
                     lines))))
    (unless (eql (car result) 0)
      (if (car result)
          (user-error "Cannot list the worktrees of %s: is it a git repository?"
                      (abbreviate-file-name default-directory))
        (user-error "Cannot list the worktrees of %s: git cannot be run"
                    (abbreviate-file-name default-directory))))
    (worktree-assume--parse-worktrees (cdr result))))

(defun worktree-assume--find-worktree (dir worktrees)
  "Return the one of WORKTREES that DIR is the top directory of, or nil."
  (let ((true (worktree-assume--true dir)))
    (cl-find-if (lambda (worktree)
                  (equal true (worktree-assume--true (plist-get worktree :path))))
                worktrees)))

(defun worktree-assume--home (root worktrees)
  "Return the one of WORKTREES that the directory ROOT is in, or nil.
When worktrees nest, the innermost."
  (let ((true (worktree-assume--true root))
        (best nil)
        (best-length -1))
    (dolist (worktree worktrees best)
      (let ((top (worktree-assume--true (plist-get worktree :path))))
        (when (and (string-prefix-p top true) (> (length top) best-length))
          (setq best worktree best-length (length top)))))))

;;;; Assuming

;;;###autoload
(defun worktree-assume (worktree &optional project)
  "Assume WORKTREE as the project, in place of PROJECT.
WORKTREE is the top directory of another worktree of PROJECT's git
repository.  PROJECT is a directory in the project the worktree
stands in for, `default-directory' by default.  From now on the
project of every directory of PROJECT is WORKTREE, until
`worktree-assume-reset': commands such as `project-find-file' work on
the worktree, as if it were the project itself.

When PROJECT is only a directory of its repository, the same
directory of WORKTREE is assumed.  Assuming a worktree where another
is assumed already replaces it, and so does assuming one for a
directory of the assumed worktree itself: that is the project it stands
in for.  This turns `worktree-assume-mode' on.

Interactively, read WORKTREE among the other worktrees of the current
project's repository.  Return (PARENT . ASSUMED): the root of the
project and the root of the project now standing in for it."
  (interactive (worktree-assume--read-arguments))
  (let* ((root (worktree-assume--stand-in project))
         (worktrees (worktree-assume-worktrees root))
         (home (or (worktree-assume--home root worktrees)
                   (user-error "%s is in no worktree of its repository"
                               (abbreviate-file-name root))))
         (target (or (worktree-assume--find-worktree worktree worktrees)
                     (user-error "%s is not a worktree of %s"
                                 (abbreviate-file-name (worktree-assume--dir worktree))
                                 (abbreviate-file-name root))))
         (top (plist-get target :path))
         (relative (substring (worktree-assume--true root)
                              (length (worktree-assume--true (plist-get home :path)))))
         (assumed (worktree-assume--dir (expand-file-name relative top))))
    (when (eq target home)
      (user-error "%s is the project's own worktree" (abbreviate-file-name top)))
    (when (plist-get target :bare)
      (user-error "%s is a bare repository, not a worktree" (abbreviate-file-name top)))
    (unless (file-directory-p top)
      (user-error "The directory of worktree %s is missing" (abbreviate-file-name top)))
    (unless (file-directory-p assumed)
      (user-error "Worktree %s has no %s, which the project is"
                  (abbreviate-file-name top) (directory-file-name relative)))
    (setq worktree-assume--entries
          (cons (worktree-assume--make-entry root (worktree-assume--true root) top assumed)
                (cl-remove (worktree-assume--true root) worktree-assume--entries
                           :key #'worktree-assume--entry-parent-true :test #'equal)))
    (unless worktree-assume-mode (worktree-assume-mode 1))
    (worktree-assume--changed root assumed)
    (message "Assumed worktree %s for %s: %s finds its files, %s resets"
             (file-name-nondirectory (directory-file-name top))
             (abbreviate-file-name root)
             (substitute-command-keys "\\[project-find-file]")
             (substitute-command-keys "\\[worktree-assume-reset]"))
    (cons root assumed)))

(defun worktree-assume--label (worktree main)
  "Return how to name WORKTREE, a plist, to choose it: below MAIN, relatively."
  (let ((path (plist-get worktree :path)))
    (if (and (string-prefix-p main path) (not (equal main path)))
        (directory-file-name (substring path (length main)))
      (abbreviate-file-name (directory-file-name path)))))

(defun worktree-assume--annotation (worktree)
  "Return what to say beside the name of WORKTREE, a plist, when choosing."
  (concat "  "
          (cond ((plist-get worktree :branch))
                ((plist-get worktree :detached)
                 (let ((head (or (plist-get worktree :head) "")))
                   (concat "detached " (substring head 0 (min 7 (length head))))))
                (t ""))
          (and (plist-get worktree :main) "  main")
          (and (plist-get worktree :locked) "  locked")
          (and (plist-get worktree :prunable) "  missing")))

(defun worktree-assume--read-worktree (candidates main prompt)
  "Read one of the worktrees CANDIDATES, plists, naming those below MAIN.
Return its directory name.  PROMPT is for the minibuffer."
  (let* ((names (mapcar (lambda (worktree)
                          (cons (worktree-assume--label worktree main) worktree))
                        candidates))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . worktree)
                        (display-sort-function . identity)
                        (annotation-function
                         . ,(lambda (name)
                              (when-let* ((worktree (cdr (assoc name names))))
                                (worktree-assume--annotation worktree)))))
                    (complete-with-action action names string predicate))))
         (name (completing-read prompt table nil t)))
    (plist-get (cdr (assoc name names)) :path)))

(defun worktree-assume--read-arguments ()
  "Read the arguments of `worktree-assume' as it is called interactively.
The project is this buffer's, or when the buffer is in an assumed
worktree, the project that worktree stands in for: another worktree
chosen there replaces it."
  (let* ((root (worktree-assume--stand-in))
         (worktrees (worktree-assume-worktrees root))
         (home (worktree-assume--home root worktrees))
         (candidates (cl-remove-if (lambda (worktree)
                                     (or (eq worktree home) (plist-get worktree :bare)))
                                   worktrees)))
    (unless candidates
      (user-error "%s has no other worktree; git worktree add makes one"
                  (abbreviate-file-name root)))
    (list (worktree-assume--read-worktree
           candidates (plist-get (car worktrees) :path)
           (format "Assume worktree for %s: " (file-name-nondirectory (directory-file-name root))))
          root)))

;;;; Resetting

(defun worktree-assume--entries-for (dir)
  "Return the assumptions DIR is concerned in.
Those standing in for the project DIR is in, and those whose assumed
worktree DIR is in."
  (let* ((dir (worktree-assume--dir dir))
         (project (and (not (file-remote-p dir))
                       (worktree-assume-with-parent (project-current nil dir))))
         (root (and project (worktree-assume--dir (project-root project)))))
    (cl-remove-if-not
     (lambda (entry)
       (or (equal dir (worktree-assume--entry-parent entry))
           (and root (equal root (worktree-assume--entry-parent entry)))
           (and root (equal (worktree-assume--true root) (worktree-assume--entry-parent-true entry)))
           (worktree-assume--inside-p dir (worktree-assume--entry-top entry))))
     worktree-assume--entries)))

(defun worktree-assume--read-reset ()
  "Read what `worktree-assume-reset' should reset, interactively.
That is the assumption of the buffer's project; when the buffer has
none, the only one, or else one to choose."
  (cond ((null worktree-assume--entries) (user-error "No worktree is assumed"))
        (current-prefix-arg 'all)
        ((worktree-assume--entries-for default-directory) default-directory)
        ((null (cdr worktree-assume--entries))
         (worktree-assume--entry-parent (car worktree-assume--entries)))
        (t (let* ((names (mapcar (lambda (entry)
                                   (cons (format "%s  %s" (worktree-assume--name entry)
                                                 (abbreviate-file-name (worktree-assume--entry-parent entry)))
                                         (worktree-assume--entry-parent entry)))
                                 worktree-assume--entries)))
             (cdr (assoc (completing-read "Reset the worktree assumed for: " names nil t)
                         names))))))

;;;###autoload
(defun worktree-assume-reset (&optional project)
  "Stop assuming a worktree: PROJECT is its own worktree again.
PROJECT is a directory of the project, or of the assumed worktree,
`default-directory' by default; the symbol `all' means every
assumption.  Interactively, reset the one of this buffer's project,
the only one there is, or one to choose; with a prefix argument,
every one.  Return the (PARENT . ASSUMED) pairs reset."
  (interactive (list (worktree-assume--read-reset)))
  (let ((entries (if (eq project 'all)
                     worktree-assume--entries
                   (worktree-assume--entries-for (or project default-directory)))))
    (dolist (entry entries)
      (setq worktree-assume--entries (delq entry worktree-assume--entries))
      (worktree-assume--changed (worktree-assume--entry-parent entry) nil))
    (when (and entries (called-interactively-p 'any))
      (message "%s is its own worktree again"
               (mapconcat (lambda (entry)
                            (abbreviate-file-name (worktree-assume--entry-parent entry)))
                          entries ", ")))
    (mapcar (lambda (entry)
              (cons (worktree-assume--entry-parent entry) (worktree-assume--entry-root entry)))
            entries)))

;;;; Asking

(defun worktree-assume-assumptions ()
  "Return the assumptions that stand, an alist of (PARENT . ASSUMED).
PARENT is the root of a project, ASSUMED the root of the worktree
standing in for it, both absolute directory names.  An assumed
worktree whose directory is gone is forgotten here, and left out."
  (mapcar (lambda (entry)
            (cons (worktree-assume--entry-parent entry) (worktree-assume--entry-root entry)))
          (cl-remove-if-not #'worktree-assume--live-root (copy-sequence worktree-assume--entries))))

(defun worktree-assume-assumed (&optional dir)
  "Return the root of the worktree assumed for DIR's project, or nil.
DIR defaults to `default-directory'."
  (when-let* ((entry (and worktree-assume--entries
                          (not (file-remote-p (or dir default-directory)))
                          (ignore-errors
                            (let ((project (worktree-assume-with-parent
                                             (project-current nil (or dir default-directory)))))
                              (and project
                                   (worktree-assume--entry-for-root (project-root project))))))))
    (worktree-assume--live-root entry)))

(defun worktree-assume-parent (&optional dir)
  "Return the root of the project DIR's worktree is assumed for, or nil.
That is the parent: the project a worktree stands in for, when DIR is
in the assumed worktree.  DIR defaults to `default-directory'."
  (when worktree-assume--entries
    (let ((dir (or dir default-directory)))
      (unless (file-remote-p dir)
        (when-let* ((entry (cl-find-if
                            (lambda (entry)
                              (worktree-assume--inside-p
                               dir (worktree-assume--entry-top entry)))
                            worktree-assume--entries)))
          (worktree-assume--entry-parent entry))))))

(defun worktree-assume--descriptions ()
  "Return a line for each assumption that stands."
  (mapcar (lambda (entry)
            (format "%s ⇒ %s"
                    (abbreviate-file-name (worktree-assume--entry-parent entry))
                    (abbreviate-file-name (worktree-assume--entry-root entry))))
          worktree-assume--entries))

;;;###autoload
(defun worktree-assume-status ()
  "Say which worktrees are assumed."
  (interactive)
  (message "%s" (if worktree-assume--entries
                    (concat "Assumed: " (string-join (worktree-assume--descriptions) "; "))
                  "No worktree is assumed")))

;;;; The mode

(defun worktree-assume--lighter ()
  "Return the mode line text for the assumptions that stand, or nil."
  (when worktree-assume--entries
    (let ((text (if (cdr worktree-assume--entries)
                    (number-to-string (length worktree-assume--entries))
                  (truncate-string-to-width (worktree-assume--name (car worktree-assume--entries))
                                            worktree-assume-lighter-width nil nil "…"))))
      (propertize (format worktree-assume-lighter text)
                  'face 'worktree-assume-lighter
                  'help-echo (lambda (&rest _)
                               (string-join (cons "Worktrees assumed for their projects:"
                                                  (worktree-assume--descriptions))
                                            "\n"))))))

;;;###autoload
(define-minor-mode worktree-assume-mode
  "Make the worktrees assumed with `worktree-assume' count.
While the mode is on, a worktree assumed for a project is the project
of its directories for `project-current' and projectile alike.
`worktree-assume' turns the mode on itself.  Turning it off resets
every assumption.  The mode line shows the worktree assumed, if any."
  :global t
  :group 'worktree-assume
  :lighter (:eval (worktree-assume--lighter))
  (cond
   (worktree-assume-mode
    ;; Ahead of the finders already there: they are asked for the
    ;; project, which is then swapped for the worktree's.
    (add-hook 'project-find-functions #'worktree-assume-project-find -90)
    (advice-add 'projectile-project-root :filter-return #'worktree-assume--projectile-root))
   (t
    ;; The finder and the advice first: nothing that fails while the
    ;; assumptions are reset leaves them in place.
    (remove-hook 'project-find-functions #'worktree-assume-project-find)
    (advice-remove 'projectile-project-root #'worktree-assume--projectile-root)
    (worktree-assume-reset 'all))))

(provide 'worktree-assume)

;;; worktree-assume.el ends here
