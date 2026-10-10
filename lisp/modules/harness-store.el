;;; harness-store.el --- Persistence primitives  -*- lexical-binding: t; -*-

;;; Commentary:

;; JSON documents, JSONL logs and a built-in SQLite database, all under
;; `harness-state-directory'.  Nothing here knows what a session is.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)

(defun harness-store-path (name)
  "Return the absolute path for stored object NAME."
  (expand-file-name name harness-state-directory))

(harness-defmethod store/save (name obj)
  "Write OBJ as JSON to NAME atomically.  Return the path."
  (let ((path (harness-store-path name)))
    (harness-write-file-atomically path (harness-json-encode obj))
    path))

(harness-defmethod store/load (name)
  "Read the JSON document NAME, or nil when it does not exist."
  (let ((path (harness-store-path name)))
    (when (file-readable-p path)
      (condition-case err
          (harness-json-parse (harness-read-file path))
        (error (harness-log 'error "store: cannot parse %s: %S" path err) nil)))))

(harness-defmethod store/append (name obj)
  "Append OBJ as one JSON line to NAME."
  (let ((path (harness-store-path name))
        (coding-system-for-write 'utf-8-unix))
    (harness-ensure-directory (file-name-directory path))
    (let ((inhibit-message t))
      (write-region (concat (harness-json-encode obj) "\n") nil path 'append 'silent))
    path))

(harness-defmethod store/read-all (name)
  "Read every JSON line of NAME as a list, skipping corrupt lines."
  (let ((path (harness-store-path name)) out)
    (when (file-readable-p path)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8)) (insert-file-contents path))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties (point) (line-end-position))))
            (unless (string-blank-p line)
              (condition-case nil
                  (push (harness-json-parse line) out)
                (error (harness-log 'warn "store: skipping corrupt line in %s" name)))))
          (forward-line 1))))
    (nreverse out)))

(harness-defmethod store/delete (name)
  "Delete stored object NAME if it exists."
  (let ((path (harness-store-path name)))
    (when (file-exists-p path) (delete-file path) t)))

(harness-defmethod store/list (prefix &optional regexp)
  "List names under directory PREFIX matching REGEXP, relative to PREFIX."
  (let ((dir (harness-store-path prefix)))
    (when (file-directory-p dir)
      (mapcar (lambda (f) (concat (file-name-as-directory prefix) f))
              (directory-files dir nil (or regexp "\\`[^.]"))))))

(defvar harness-store--sqlite nil
  "Open databases, an alist of ((DIRECTORY . NAME) . DB).")

(harness-defmethod store/sqlite (&optional name)
  "Return the open SQLite handle for NAME.db, or nil when unsupported.
NAME defaults to \"usage\", the database of recorded usage; others
such as \"search\" (the session search index) live beside it in
the state directory.  Handles are opened once and reused."
  (when (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (let* ((dir (expand-file-name harness-state-directory))
           (key (cons dir (or name "usage")))
           (cell (assoc key harness-store--sqlite)))
      (unless (and cell (sqlitep (cdr cell)))
        (harness-ensure-directory dir)
        (let ((db (sqlite-open (expand-file-name (concat (cdr key) ".db") dir))))
          ;; Handles of another state directory are stale: close them.
          (setq harness-store--sqlite
                (cons (cons key db)
                      (cl-remove-if (lambda (c)
                                      (when (or (equal (car c) key)
                                                (not (equal (caar c) dir)))
                                        (ignore-errors (sqlite-close (cdr c)))
                                        t))
                                    harness-store--sqlite)))
          (setq cell (car harness-store--sqlite))))
      (cdr cell))))

(harness-defmethod store/sqlite-close (&optional name)
  "Close the SQLite handle of NAME.db, or every open one when NAME is nil."
  (setq harness-store--sqlite
        (cl-remove-if (lambda (cell)
                        (when (or (null name) (equal (cdar cell) name))
                          (ignore-errors (sqlite-close (cdr cell)))
                          t))
                      harness-store--sqlite)))

(harness-define-module 'store
  :doc "JSON, JSONL and SQLite persistence under the state directory."
  :shutdown (lambda () (harness-call 'store/sqlite-close)))

(provide 'harness-store)
;;; harness-store.el ends here
