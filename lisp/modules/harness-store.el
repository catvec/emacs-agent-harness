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

(defvar harness-store--sqlite nil "(DIRECTORY . DB) of the open database.")

(harness-defmethod store/sqlite ()
  "Return the open SQLite handle for usage.db, or nil when unsupported."
  (when (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (let ((dir (expand-file-name harness-state-directory)))
      (unless (and harness-store--sqlite
                   (equal (car harness-store--sqlite) dir)
                   (sqlitep (cdr harness-store--sqlite)))
        (harness-ensure-directory dir)
        (setq harness-store--sqlite
              (cons dir (sqlite-open (expand-file-name "usage.db" dir)))))
      (cdr harness-store--sqlite))))

(harness-defmethod store/sqlite-close ()
  "Close the SQLite handle if open."
  (when harness-store--sqlite
    (ignore-errors (sqlite-close (cdr harness-store--sqlite)))
    (setq harness-store--sqlite nil)))

(harness-define-module 'store
  :doc "JSON, JSONL and SQLite persistence under the state directory."
  :shutdown (lambda () (harness-call 'store/sqlite-close)))

(provide 'harness-store)
;;; harness-store.el ends here
