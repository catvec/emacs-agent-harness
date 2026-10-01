;;; harness-config.el --- Layered configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;; Three layers, most specific wins:
;;   directory  .dir-locals.el in the session's working directory
;;   project    .dir-locals.el at the project root
;;   global     the customize value of the variable
;;
;; Every setting is an ordinary `defcustom' with a `:safe' predicate, so
;; the built-in dir-locals machinery reads and writes them without
;; prompting.  Persisting a setting writes the most specific file that
;; makes sense: the project file when the session is in a project,
;; otherwise the directory file, unless a directory file already exists.

;;; Code:

(require 'cl-lib)
(require 'files-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-model "claude:claude-fable-5-1"
  "Default model as PROVIDER:MODEL."
  :type 'string :safe #'stringp :group 'harness)

(defcustom harness-permission-mode 'ask
  "Default permission mode for new sessions."
  :type '(choice (const ask) (const accept-edits) (const auto) (const yolo))
  :safe (lambda (v) (memq v '(ask accept-edits auto yolo)))
  :group 'harness)

(defcustom harness-thinking nil
  "Default thinking level, or nil for the model default."
  :type '(choice (const nil) (const "low") (const "medium") (const "high") (const "xhigh") (const "max"))
  :safe (lambda (v) (or (null v) (member v '("low" "medium" "high" "xhigh" "max"))))
  :group 'harness)

(defcustom harness-allowed-directories nil
  "Extra directories sessions may touch besides their working directory."
  :type '(repeat directory)
  :safe (lambda (v) (and (listp v) (cl-every #'stringp v)))
  :group 'harness)

(defcustom harness-budget nil
  "Default per-session budget plist (:amount USD :hard BOOL), or nil."
  :type '(choice (const nil) (plist :key-type symbol :value-type sexp))
  :safe (lambda (v) (or (null v) (and (listp v) (numberp (plist-get v :amount)))))
  :group 'harness)

(defcustom harness-sandbox-policy 'preferred
  "Whether tool processes must run in a kernel sandbox.
`required' fails closed when no backend exists, `preferred' uses one
when available, `off' never sandboxes."
  :type '(choice (const required) (const preferred) (const off))
  :safe (lambda (v) (memq v '(required preferred off)))
  :group 'harness)

(defcustom harness-non-interactive nil
  "When non-nil sessions avoid blocking on the user."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-context-reserve 20000
  "Tokens kept free below the context window before compaction."
  :type 'integer :safe #'integerp :group 'harness)

(defcustom harness-tasks-directory "docs/tasks"
  "Folder of a git project's task files, relative to its main checkout.
Every task on the project's board is also a markdown file there: YAML
frontmatter with the fields the harness reads, then the task's prompt,
the request it was written from and its plan.  The harness writes the
files when tasks change and reads back the ones people (or other tools)
edit or add, which then show on the board.  See the tasks module.

nil keeps no task files.  A project's .dir-locals.el can pick another
folder for that project, or nil to keep none there."
  :type '(choice (const :tag "No task files" nil) (string :tag "Folder"))
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'harness)

(defconst harness-config-keys
  '(harness-model harness-permission-mode harness-thinking harness-allowed-directories
    harness-budget harness-sandbox-policy harness-non-interactive harness-context-reserve
    harness-tasks-directory)
  "Settings that take part in layering.")

(defun harness-config--dir-locals-alist (dir)
  "Return the alist of variables set for all modes by DIR's dir-locals file."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (file (expand-file-name dir-locals-file dir)))
    (when (file-readable-p file)
      (condition-case err
          (let ((class (dir-locals-read-from-dir dir)))
            (when class
              (let (out)
                (dolist (entry (dir-locals-get-class-variables class))
                  (when (null (car entry))
                    (dolist (var (cdr entry))
                      (push var out))))
                (nreverse out))))
        (error (harness-log 'warn "config: cannot read %s: %S" file err) nil)))))

(defun harness-config--layer-value (dir key)
  "Return (FOUND . VALUE) for KEY in DIR's dir-locals, or nil."
  (let ((cell (assq key (harness-config--dir-locals-alist dir))))
    (and cell (cons t (cdr cell)))))

(defun harness-config--root (cwd)
  (if (harness-method-exists-p 'project/root)
      (harness-call 'project/root cwd)
    (file-name-as-directory (expand-file-name cwd))))

(harness-defmethod config/layers (cwd)
  "Return ((global . V) (project . V) (directory . V)) for every config key at CWD.
Each V is a plist of KEY VALUE for keys set at that layer; global
always lists every key."
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (root (harness-config--root cwd))
         (global (cl-loop for k in harness-config-keys
                          append (list k (symbol-value k))))
         (project (cl-loop for k in harness-config-keys
                           for v = (harness-config--layer-value root k)
                           when v append (list k (cdr v))))
         (directory (and (not (string= cwd root))
                         (cl-loop for k in harness-config-keys
                                  for v = (harness-config--layer-value cwd k)
                                  when v append (list k (cdr v))))))
    (list (cons 'global global) (cons 'project project) (cons 'directory directory))))

(harness-defmethod config/get (key cwd)
  "Return the effective value of setting KEY for a session at CWD."
  (unless (memq key harness-config-keys)
    (error "Unknown config key %s" key))
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (root (harness-config--root cwd))
         (dir (and (not (string= cwd root)) (harness-config--layer-value cwd key)))
         (proj (or dir (harness-config--layer-value root key))))
    (if proj (cdr proj) (symbol-value key))))

(defun harness-config--write-dir-local (dir key value)
  "Persist KEY VALUE for all modes in DIR's dir-locals file."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (file (expand-file-name dir-locals-file dir))
         (default-directory dir)
         (enable-local-variables :all))
    (let ((buf (find-file-noselect file)))
      (unwind-protect
          (with-current-buffer buf
            (add-dir-local-variable nil key value file)
            (let ((inhibit-message t)) (save-buffer)))
        (when (buffer-live-p buf) (kill-buffer buf))))
    ;; Drop the cached class so the next read sees the new value.
    (dir-locals-read-from-dir dir)
    file))

(harness-defmethod config/set (key value &rest opts)
  "Set KEY to VALUE.  OPTS: `:scope' directory|project|global, `:cwd' DIR.
Without `:scope' the project file is used when CWD is in a project,
unless a directory file already exists at CWD; without a project the
directory file is used.  Return (SCOPE . FILE-OR-NIL)."
  (unless (memq key harness-config-keys) (error "Unknown config key %s" key))
  (let* ((cwd (file-name-as-directory (expand-file-name (or (plist-get opts :cwd) default-directory))))
         (root (harness-config--root cwd))
         (scope (or (plist-get opts :scope)
                    (cond ((file-exists-p (expand-file-name dir-locals-file cwd)) 'directory)
                          ((and (harness-method-exists-p 'project/root)
                                (ignore-errors (project-current nil cwd)))
                           'project)
                          (t 'directory))))
         (result
          (pcase scope
            ('global (harness-save-user-option key value) (cons 'global nil))
            ('project (cons 'project (harness-config--write-dir-local root key value)))
            ('directory (cons 'directory (harness-config--write-dir-local cwd key value)))
            (_ (error "Unknown scope %s" scope)))))
    (harness-emit 'config/changed key value scope cwd)
    result))

(harness-declare-event 'config/changed "(KEY VALUE SCOPE CWD) after `config/set'.")

(harness-define-module 'config
  :doc "Layered settings through customize and dir-locals."
  :requires '(project))

(provide 'harness-config)
;;; harness-config.el ends here
