;;; harness-attachments.el --- @-notation file attachments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://github.com/noahhuppert/emacs-agent-harness

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

;; Typing `@' while composing a message offers the files and directories of
;; the session's working directory, fuzzy matched, and whatever the user picks
;; is attached *by content*: the text of the file, or the listing of a
;; directory, is appended to the message.  The point is that the agent does
;; not have to spend a turn finding the file, and cannot be defeated by a path
;; that moved in the meantime.
;;
;; Two halves, deliberately separable:
;;
;; - Completion: a `completion-at-point-function' registered in the
;;   conversation buffer.  It resolves candidates against the session's
;;   working directory (`harness-session-cwd'), so `@' follows the session
;;   into a git worktree, and it fuzzy matches so a fragment of a name is
;;   enough.
;; - Expansion: `harness-attachments-expand', called from `harness-agent-send',
;;   which turns `@path' into an `<attached ...>' block.  Expansion lives in
;;   the send path rather than the UI, so a plugin or a script that calls
;;   `harness-agent-send' gets attachments too.
;;
;; Budgets are enforced here rather than trusted to the model: a file larger
;; than `harness-attachment-max-bytes' is truncated with a note, and the total
;; is capped so that one careless `@' cannot blow out the context window.
;;
;; See DESIGN.md sections 9.1 and 15.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-session)
(require 'harness-agent)
(require 'harness-ui-conversation)
(require 'harness-faces)

(defcustom harness-attachment-max-bytes 65536
  "Maximum characters attached from one file.
Larger files are truncated and the message says so."
  :type 'integer
  :group 'harness)

(defcustom harness-attachment-max-total-bytes 262144
  "Maximum characters attached to one message, across all attachments."
  :type 'integer
  :group 'harness)

(defcustom harness-attachment-max-directory-entries 200
  "Maximum entries listed for an attached directory."
  :type 'integer
  :group 'harness)

(defcustom harness-attachment-max-candidates 4000
  "Maximum number of files offered by `@' completion in one directory tree."
  :type 'integer
  :group 'harness)

(defcustom harness-attachment-ignored-directories
  '(".git" ".hg" ".svn" "node_modules" ".venv" "venv" "target"
    "dist" "build" "eln-cache" ".cache" "__pycache__")
  "Directories `@' completion does not descend into."
  :type '(repeat string)
  :group 'harness)

(defconst harness-attachment-open-tag "<attached "
  "Start of an attachment block in a message.")

(defconst harness-attachment-ignore-functions nil
  "Abnormal hook of functions deciding whether a file may be attached.
Each is called with the file name and should return non-nil to skip it.
Useful for keeping secrets out of a transcript.")

(defvar harness-attachments--candidate-cache nil
  "Cache of directory listings, keyed by (DIRECTORY . MTIME).")


;;; Candidates

(defun harness-attachments--ignored-p (path)
  "Return non-nil when PATH should not be offered or attached."
  (or (cl-some (lambda (name)
                 (member name (split-string path "/" t)))
               harness-attachment-ignored-directories)
      (cl-some (lambda (function) (funcall function path))
               harness-attachment-ignore-functions)))

(defun harness-attachments-candidates (directory)
  "Return the candidate relative paths under DIRECTORY, depth first.

The listing is cached against the directory's modification time, because
`@' completion runs on every keystroke after the at sign."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (attributes (file-attributes directory))
         (mtime (and attributes (float-time (file-attribute-modification-time attributes))))
         (key (cons directory mtime))
         (cached (car harness-attachments--candidate-cache)))
    (if (and cached (equal (car cached) key))
        (cdr cached)
      (let ((candidates
             (when (file-directory-p directory)
               (let (files)
                 (ignore-errors
                   (dolist (file (directory-files-recursively
                                  directory ""
                                  t
                                  (lambda (subdirectory)
                                    (not (harness-attachments--ignored-p subdirectory)))))
                     (when (and (not (harness-attachments--ignored-p file))
                                (< (length files) harness-attachment-max-candidates))
                       (push (harness-relative-path file directory) files))))
                 (nreverse files)))))
        (setq harness-attachments--candidate-cache (cons key candidates))
        candidates))))

(defun harness-attachments--fuzzy-score (pattern candidate)
  "Return a score when PATTERN is a subsequence of CANDIDATE, else nil.
Higher is better: consecutive matches and matches near a separator win."
  (if (string-empty-p pattern)
      1
    (let ((pattern-index 0)
          (score 0)
          (last-match -2)
          (index 0)
          (target (downcase candidate))
          (length (length (downcase candidate)))
          (wanted (downcase pattern)))
      (while (and (< index length) (< pattern-index (length wanted)))
        (if (eq (aref target index) (aref wanted pattern-index))
            (progn
              (setq score (+ score (if (= index (1+ last-match)) 3 1)))
              (when (memq (aref candidate index) '(?/ ?- ?_ ?.))
                (setq score (+ score 2)))
              (setq last-match index)
              (setq pattern-index (1+ pattern-index)))
          (setq score (1- score)))
        (setq index (1+ index)))
      (when (= pattern-index (length wanted))
        (- score (length candidate) 0)))))

(defun harness-attachments--matches (pattern candidates)
  "Return CANDIDATES that fuzzy match PATTERN, best first."
  (if (string-empty-p pattern)
      (seq-take candidates 200)
    (let (scored)
      (dolist (candidate candidates)
        (when-let* ((score (harness-attachments--fuzzy-score pattern candidate)))
          (push (cons score candidate) scored)))
      (mapcar #'cdr (sort scored (lambda (a b) (> (car a) (car b))))))))


;;; Completion

(defconst harness-attachments--token-regexp
  "[^ \t\n()\"',;]+"
  "What a path written after `@' may contain.")

(defun harness-attachments--token-at-point ()
  "Return (START . END) around the `@' reference before point, or nil.

START is just after the at sign.  A reference is recognised when the at sign
starts a word, so email addresses and `foo@bar' are left alone."
  (let ((end (point)))
    (save-excursion
      (save-match-data
        (when (re-search-backward (concat "@\\(?:\\(?:" harness-attachments--token-regexp "\\)\\|\"\\)")
                                  (line-beginning-position) t)
          (let ((at (match-beginning 0)))
            (when (or (= at (point-min))
                      (memq (char-before at) (list ?\s ?\t ?\n ?\( ?\[ ?\" ?')))
              (cons (1+ at) end))))))))

(defun harness-attachments--session ()
  "Return the session of the current buffer, if it has one."
  (when (fboundp 'harness-conversation-session)
    (harness-conversation-session)))

(defun harness-attachments-completion-at-point ()
  "Complete a file or directory reference after `@'."
  (when-let* ((bounds (harness-attachments--token-at-point)))
    (let* ((session (harness-attachments--session))
           (directory (if session (harness-session-cwd session) default-directory))
           (pattern (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (list (car bounds) (cdr bounds)
            (harness-attachments--matches pattern
                                          (harness-attachments-candidates directory))
            :exclusive 'no
            :annotation-function
            (lambda (candidate)
              (let ((full (expand-file-name candidate directory)))
                (concat (if (file-directory-p full) "  dir" "  file")
                        (when (file-regular-p full)
                          (format " %s" (harness-format-count
                                         (file-attribute-size (file-attributes full))))))))
            :company-kind
            (lambda (candidate)
              (if (file-directory-p (expand-file-name candidate directory))
                  'folder 'file))))))


;;; Attaching

(defun harness-attachments--token-bounds (text)
  "Return a list of (START . END . PATH) references in TEXT."
  (let ((references nil)
        (index 0))
    (while (string-match (concat "\\(?:\\`\\|[ \t\n(\\[\"']\\)@"
                                 "\\(?:\\(\"\\([^\"]+\\)\"\\)\\|\\([^ \t\n()\"',;]+\\)\\)")
                         text index)
      (let ((path (or (match-string 2 text) (match-string 3 text)))
            (start (match-beginning 0)))
        (when path
          (push (list start (match-end 0) path) references)))
      (setq index (match-end 0)))
    (nreverse references)))

(defun harness-attachments--read-file (path budget)
  "Return the attachment text for file PATH, spending at most BUDGET characters."
  (let* ((size (file-attribute-size (file-attributes path)))
         (limit (min budget harness-attachment-max-bytes))
         (content (with-temp-buffer
                    (let ((coding-system-for-read 'utf-8-unix))
                      (insert-file-contents path nil 0 (min size limit)))
                    (buffer-string)))
         (truncated (> size (length content))))
    (list :kind 'file
          :path path
          :bytes size
          :content (concat content
                           (when truncated
                             (format "\n… truncated at %s of %s"
                                     (harness-format-count limit)
                                     (harness-format-count size)))))))

(defun harness-attachments--read-directory (path)
  "Return the attachment text listing DIRECTORY at PATH."
  (let ((entries (ignore-errors
                   (directory-files path nil "\\`[^.]" t))))
    (list :kind 'directory
          :path path
          :entries (length entries)
          :content (string-join
                    (seq-take entries harness-attachment-max-directory-entries)
                    "\n"))))

(defun harness-attachments-resolve (session text)
  "Return the attachments referenced by `@' paths in TEXT.

Only references that resolve to an existing file or directory, relative to
SESSION's working directory, become attachments; anything else is left as
ordinary text, which is what makes an at sign in prose harmless."
  (let* ((directory (if session (harness-session-cwd session) default-directory))
         (budget harness-attachment-max-total-bytes)
         (seen (make-hash-table :test #'equal))
         (attachments nil))
    (dolist (reference (harness-attachments--token-bounds text))
      (let* ((raw (nth 2 reference))
             (path (expand-file-name raw directory)))
        (when (and (not (gethash path seen))
                   (> budget 0)
                   (file-exists-p path)
                   (not (harness-attachments--ignored-p path)))
          (puthash path t seen)
          (let ((attachment (cond
                             ((file-directory-p path)
                              (harness-attachments--read-directory path))
                             ((file-readable-p path)
                              (harness-attachments--read-file path budget))
                             (t nil))))
            (when attachment
              (setq budget (- budget (length (plist-get attachment :content))))
              (push attachment attachments))))))
    (nreverse attachments)))

(defun harness-attachments-format (attachments)
  "Return the `<attached>' block for ATTACHMENTS, or an empty string."
  (if (null attachments)
      ""
    (concat "\n\n"
            (string-join
             (mapcar (lambda (attachment)
                       (let ((path (harness-relative-path (plist-get attachment :path))))
                         (format "<attached path=\"%s\" type=\"%s\"%s>\n%s\n</attached>"
                                 path
                                 (plist-get attachment :kind)
                                 (pcase (plist-get attachment :kind)
                                   ('file (format " bytes=\"%s\""
                                                  (plist-get attachment :bytes)))
                                   ('directory (format " entries=\"%s\""
                                                       (plist-get attachment :entries)))
                                   (_ ""))
                                 (plist-get attachment :content))))
                     attachments)
             "\n"))))

(defun harness-attachments-expand (session text)
  "Return TEXT with the contents of any `@' references appended.
This is what `harness-agent-send' calls, so every caller -- the UI, a plugin,
a test -- attaches the same way."
  (if-let* ((attachments (harness-attachments-resolve session text)))
      (concat text (harness-attachments-format attachments))
    text))

(defun harness-attachments-in-text (text)
  "Return the (START . END) of the attachment block in TEXT, or nil."
  (let ((start (string-match (regexp-quote harness-attachment-open-tag) text)))
    (when start
      (cons start (length text)))))

(defun harness-attachments-render (content)
  "Render CONTENT, styling any attachment block it contains.
Returns non-nil when it handled the content, which is how the conversation
view's `harness-content-render-functions' hook works."
  (let ((bounds (harness-attachments-in-text content)))
    (when bounds
      (let ((body (substring content 0 (car bounds)))
            (attached (substring content (car bounds))))
        (when (not (string-empty-p body))
          (harness-conversation-insert body 'face 'harness-message-body))
        ;; Each attached block is a folded, labelled section: the header stays
        ;; visible so the user can see what the agent actually received.
        (dolist (block (harness-attachments--split-blocks attached))
          (harness-conversation-insert
           (format "%s\n" (propertize (harness-attachments--block-label block)
                                       'face 'harness-role-tool)))
          (harness-conversation-insert-folded
           (harness-attachments--block-body block) 'face 'harness-tool-output))
        t))))

(defun harness-attachments--split-blocks (text)
  "Split TEXT into attachment blocks."
  (let ((blocks nil)
        (index 0))
    (while (string-match "<attached \\([^>]*\\)>\n\\(.*?\\)\n</attached>" text index)
      (push (list :attributes (match-string 1 text)
                  :body (match-string 2 text))
            blocks)
      (setq index (match-end 0)))
    (nreverse blocks)))

(defun harness-attachments--block-label (block)
  "Return the label line for BLOCK."
  (let ((attributes (plist-get block :attributes)))
    (concat "📎 "
            (or (and (string-match "path=\"\\([^\"]*\\)\"" attributes)
                     (match-string 1 attributes))
                "attachment")
            (cond
             ((string-match "bytes=\"\\([^\"]*\\)\"" attributes)
              (format "  %s" (match-string 1 attributes)))
             ((string-match "entries=\"\\([^\"]*\\)\"" attributes)
              (format "  %s entries" (match-string 1 attributes)))
             (t "")))))

(defun harness-attachments--block-body (block)
  "Return the body of BLOCK, with a trailing newline."
  (let ((body (or (plist-get block :body) "")))
    (if (string-suffix-p "\n" body) body (concat body "\n"))))


;;; Wiring

(add-hook 'harness-content-render-functions #'harness-attachments-render)

;; Expansion runs on the way out of `harness-agent-send', through the
;; harness's own hook rather than advice, so every caller gets it: the UI, a
;; plugin, a queued message, a subagent.
(add-hook 'harness-user-message-functions #'harness-attachments-expand)

(provide 'harness-attachments)
;;; harness-attachments.el ends here
