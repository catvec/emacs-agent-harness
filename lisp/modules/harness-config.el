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
;;
;; Only `harness-config-keys' layer.  The other harness options have a
;; global value alone; `config/describe' lists them too, so a settings
;; page can show every option of the harness in one place, and
;; `config/set' and `config/unset' change their global value.  Values
;; cross the wire printed (see `config/describe'): JSON cannot tell a
;; symbol from a string, nor an unset layer from one set to nil.

;;; Code:

(require 'cl-lib)
(require 'files-x)
(require 'project)
(require 'wid-edit)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-model "claude:claude-fable-5-1"
  "Default model as PROVIDER:MODEL."
  :type 'string :safe #'stringp :group 'harness)

(defcustom harness-permission-mode 'ask
  "Default permission mode for new sessions."
  :type '(choice (const :tag "Ask" ask) (const :tag "Accept edits" accept-edits)
                 (const :tag "Auto" auto) (const :tag "YOLO" yolo))
  :safe (lambda (v) (memq v '(ask accept-edits auto yolo)))
  :group 'harness)

(defcustom harness-thinking nil
  "Default thinking level, or nil for the model default."
  :type '(choice (const :tag "Model default" nil) (const :tag "Low" "low")
                 (const :tag "Medium" "medium") (const :tag "High" "high")
                 (const :tag "Extra high" "xhigh") (const :tag "Max" "max"))
  :safe (lambda (v) (or (null v) (member v '("low" "medium" "high" "xhigh" "max"))))
  :group 'harness)

(defcustom harness-allowed-directories nil
  "Extra directories sessions may touch besides their working directory."
  :type '(repeat directory)
  :safe (lambda (v) (and (listp v) (cl-every #'stringp v)))
  :group 'harness)

(defcustom harness-budget nil
  "Default per-session budget plist (:amount USD :hard BOOL), or nil."
  :type '(choice (const :tag "No budget" nil)
                 (plist :tag "Budget" :key-type symbol :value-type sexp
                        :options ((:amount (number :tag "Amount (USD)"))
                                  (:hard (boolean :tag "Hard (stop the next turn once spent)")))))
  :safe (lambda (v) (or (null v) (and (listp v) (numberp (plist-get v :amount)))))
  :group 'harness)

(defcustom harness-sandbox-policy 'preferred
  "Whether tool processes must run in a kernel sandbox.
`required' fails closed when no backend exists, `preferred' uses one
when available, `off' never sandboxes."
  :type '(choice (const :tag "Required" required) (const :tag "Preferred" preferred)
                 (const :tag "Off" off))
  :safe (lambda (v) (memq v '(required preferred off)))
  :group 'harness)

(defcustom harness-non-interactive nil
  "When non-nil sessions avoid blocking on the user."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-context-reserve 20000
  "Tokens kept free below the context window before compaction."
  :type 'integer :safe #'integerp :group 'harness)

(defconst harness-config-keys
  '(harness-model harness-permission-mode harness-thinking harness-allowed-directories
    harness-budget harness-sandbox-policy harness-non-interactive harness-context-reserve)
  "Settings that take part in layering.")

(defconst harness-config-hidden-options
  '(harness-process harness-module-directories harness-enabled-modules harness-disabled-modules
    harness-state-directory harness-server-emacs harness-server-forward-variables
    harness-server-init-file)
  "Harness options `config/describe' leaves out, besides the `harness-acp-' ones.
They decide how the harness starts and how its process reaches the UI,
which a running harness cannot change under itself; set them in the
init file.")

(defconst harness-config-secret-regexp "-\\(?:api-key\\|token\\|secret\\|password\\)\\'"
  "Options whose names match this hold secrets.
Their values never leave the harness through `config/describe' or
`config/changed', and never go into a .dir-locals.el file.")

;;;; Reading the layers

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
  "Return the project root of CWD, or CWD itself without a project module."
  (if (harness-method-exists-p 'project/root)
      (harness-call 'project/root cwd)
    (file-name-as-directory (expand-file-name cwd))))

(defun harness-config--in-project-p (cwd)
  "Non-nil when CWD lies in a project."
  (and (harness-method-exists-p 'project/root)
       (ignore-errors (project-current nil cwd))
       t))

(defun harness-config--cwd (opts)
  "Return the directory OPTS name with `:cwd', else `default-directory'."
  (file-name-as-directory (expand-file-name (or (plist-get opts :cwd) default-directory))))

;;;; Options

(defun harness-config--listed-p (sym)
  "Non-nil when SYM is a harness option `config/describe' lists."
  (let ((name (symbol-name sym)))
    (and (string-prefix-p "harness-" name)
         (boundp sym)
         (get sym 'standard-value)
         (not (string-match-p "--" name))
         (not (string-prefix-p "harness-acp-" name))
         (not (memq sym harness-config-hidden-options))
         (not (and (fboundp sym) (string-suffix-p "-mode" name))))))

(defun harness-config--global-options ()
  "Return the listed harness options that do not layer, sorted by name.
They are the variables of the `harness' customize group: the options of
the harness modules and core, not those of the UI (its own groups)."
  (let (out)
    (dolist (member (get 'harness 'custom-group))
      (let ((sym (car member)))
        (when (and (eq (cadr member) 'custom-variable)
                   (not (memq sym harness-config-keys))
                   (harness-config--listed-p sym))
          (cl-pushnew sym out))))
    (sort out (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun harness-config--key (key)
  "Return the option KEY names, a symbol or its name; signal for anything else."
  (let ((sym (cond ((symbolp key) key)
                   ((stringp key) (intern-soft key)))))
    (unless (and sym (or (memq sym harness-config-keys) (harness-config--listed-p sym)))
      (error "Unknown config key %s" key))
    sym))

(defun harness-config--secret-p (key)
  "Non-nil when option KEY holds a secret."
  (string-match-p harness-config-secret-regexp (symbol-name key)))

(defun harness-config--standard (key)
  "Return the standard (default) value of option KEY."
  (ignore-errors (eval (car (get key 'standard-value)) t)))

(defun harness-config--module-of (key)
  "Return the name of the module KEY belongs to, or \"core\".
That is the module whose file defines KEY, else (for an option of a
shared file such as harness-client-tools.el) the module whose name
starts KEY's name."
  (let* ((file (symbol-file key 'defvar))
         (base (and file (file-name-base file)))
         (name (and base (string-prefix-p "harness-" base) (substring base (length "harness-"))))
         (rest (string-remove-prefix "harness-" (symbol-name key)))
         (best nil))
    (if (and name (harness-module-get (intern name)))
        name
      (dolist (m (harness-modules))
        (let ((n (symbol-name (harness-module-name m))))
          (when (and (string-prefix-p (concat n "-") rest) (> (length n) (length best)))
            (setq best n))))
      (or best "core"))))

;;;; Printed values

(defun harness-config--print (value)
  "Return VALUE printed so that `read' gives it back."
  (let ((print-length nil) (print-level nil))
    (prin1-to-string value)))

(defun harness-config--readable-p (value)
  "Non-nil when VALUE survives `harness-config--print' and `read'."
  (condition-case nil
      (equal value (car (read-from-string (harness-config--print value))))
    (error nil)))

(defun harness-config--read (printed)
  "Return the value PRINTED, a string from `harness-config--print', stands for."
  (unless (stringp printed)
    (error "A printed value must be a string, not %S" printed))
  (pcase-let ((`(,value . ,end) (read-from-string printed)))
    (unless (string-blank-p (substring printed end))
      (error "Not a single value: %s" printed))
    value))

;;;; Checks

(defun harness-config--type-match-p (key value)
  "Non-nil when VALUE fits the customize type of option KEY."
  (let ((type (get key 'custom-type)))
    (or (null type)
        (condition-case nil
            (widget-apply (widget-convert type) :match value)
          ;; A type the widget library cannot check does not block a save.
          (error t)))))

(defun harness-config--check (key value scope)
  "Signal unless option KEY may be set to VALUE at SCOPE."
  (unless (memq scope '(global project directory))
    (error "Unknown scope %s" scope))
  (when (memq scope '(project directory))
    (unless (memq key harness-config-keys)
      (error "%s has a global value only" key))
    (when (harness-config--secret-p key)
      (error "%s is a secret and never goes in %s" key dir-locals-file)))
  (unless (harness-config--type-match-p key value)
    (error "%S is not a valid value for %s" value key))
  (when (memq scope '(project directory))
    (let ((safe (get key 'safe-local-variable)))
      (when (and safe (not (ignore-errors (funcall safe value))))
        (error "%S is not a safe directory-local value for %s" value key)))))

;;;; Writing dir-locals files

(defun harness-config--dir-locals-prune ()
  "Drop modes without settings from the dir-locals alist in this buffer.
Return the alist that is left."
  (save-excursion
    (goto-char (point-min))
    (forward-comment (buffer-size))
    (let* ((start (point))
           (alist (ignore-errors (let ((read-circle nil)) (read (current-buffer)))))
           (kept (cl-remove-if (lambda (e) (and (consp e) (null (cdr e)))) alist)))
      (when (and kept (not (equal kept alist)))
        (delete-region start (point-max))
        (princ (dir-locals-to-string kept) (current-buffer))
        (insert "\n")
        (goto-char start)
        (indent-sexp))
      kept)))

(defun harness-config--edit-dir-locals (dir key value op)
  "Apply OP to KEY for all modes in DIR's dir-locals file and save it.
OP is `add-or-replace', setting KEY to VALUE, or `delete'.  A file
left without settings is deleted.  Return the file."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (file (expand-file-name dir-locals-file dir))
         (enable-local-variables :all)
         (visited (find-buffer-visiting file))
         (buf nil))
    (save-window-excursion
      (unwind-protect
          (progn
            ;; From a buffer visiting no file, `modify-dir-local-variable'
            ;; edits the file of `default-directory'.  Emacs 29 has no FILE
            ;; argument to name it, and a file buffer would make it look
            ;; for a dominating file instead.
            (with-temp-buffer
              (let ((default-directory dir))
                (modify-dir-local-variable nil key value op)
                (setq buf (current-buffer))))
            (unless (and (buffer-live-p buf) (buffer-file-name buf)
                         ;; `file-equal-p' needs the file to exist already.
                         (or (string= (expand-file-name (buffer-file-name buf)) file)
                             (file-equal-p (buffer-file-name buf) file)))
              (error "Could not edit %s" file))
            (with-current-buffer buf
              (if (harness-config--dir-locals-prune)
                  (let ((inhibit-message t)
                        ;; No backup files next to the user's settings.
                        (make-backup-files nil))
                    (save-buffer))
                (set-buffer-modified-p nil)
                (when (file-exists-p file) (delete-file file)))))
        ;; Close the file unless it was open before.
        (when (and (buffer-live-p buf) (buffer-file-name buf) (not (eq buf visited)))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))
    ;; Drop the cached class so the next read sees the change.
    (dir-locals-read-from-dir dir)
    file))

(defun harness-config--write-dir-local (dir key value)
  "Persist KEY VALUE for all modes in DIR's dir-locals file; return the file."
  (harness-config--edit-dir-locals dir key value 'add-or-replace))

(defun harness-config--delete-dir-local (dir key)
  "Remove KEY from DIR's dir-locals file; return the file, or nil without KEY."
  (when (harness-config--layer-value dir key)
    (harness-config--edit-dir-locals dir key nil 'delete)))

;;;; Methods

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
  "Return the effective value of setting KEY (a symbol or its name) at CWD."
  (let ((key (harness-config--key key)))
    (unless (memq key harness-config-keys)
      (error "Unknown config key %s" key))
    (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
           (root (harness-config--root cwd))
           (dir (and (not (string= cwd root)) (harness-config--layer-value cwd key)))
           (proj (or dir (harness-config--layer-value root key))))
      (if proj (cdr proj) (symbol-value key)))))

(defun harness-config--effective (key cwd)
  "Return the value of option KEY in effect at CWD."
  (if (memq key harness-config-keys)
      (harness-call 'config/get key cwd)
    (symbol-value key)))

(defun harness-config--describe-key (key layered project directory)
  "Describe option KEY for `config/describe'.
LAYERED is non-nil for a layered setting; PROJECT and DIRECTORY are the
alists of the project's and the directory's dir-locals files."
  (let* ((secret (harness-config--secret-p key))
         (global (symbol-value key))
         (pcell (and layered (assq key project)))
         (dcell (and layered (assq key directory)))
         (source (cond (dcell 'directory) (pcell 'project) (t 'global)))
         (value (cond (dcell (cdr dcell)) (pcell (cdr pcell)) (t global)))
         (standard (harness-config--standard key)))
    (append
     (list :key (symbol-name key)
           :module (harness-config--module-of key)
           :doc (or (ignore-errors (documentation-property key 'variable-documentation t)) "")
           :type (harness-config--print (or (get key 'custom-type) 'sexp))
           :layered (if layered t :false)
           :secret (if secret t :false)
           :source (symbol-name source))
     (if secret
         (list :editable t :has-value (if global t :false))
       (list :editable (if (cl-every #'harness-config--readable-p
                                     (list global value standard (cdr pcell) (cdr dcell)))
                           t :false)
             ;; Judged here, where the functions a type names are defined.
             :invalid (cl-loop for (layer . cell) in (list (cons "global" (cons t global))
                                                           (cons "project" pcell)
                                                           (cons "directory" dcell))
                               when (and cell (not (harness-config--type-match-p key (cdr cell))))
                               collect layer)
             :standard (harness-config--print standard)
             :global (harness-config--print global)
             :project (and pcell (harness-config--print (cdr pcell)))
             :directory (and dcell (harness-config--print (cdr dcell)))
             :value (harness-config--print value))))))

(harness-defmethod config/describe (cwd)
  "Describe every harness option as seen at CWD, for a settings page.
Return (:cwd DIR :root DIR :project NAME :in-project BOOL
:files (:project FILE :project-exists BOOL
        :directory FILE :directory-exists BOOL)
:modules ((:name NAME :doc DOC) ...) :settings (SETTING ...)).
The layered settings (`harness-config-keys') come first, then the
options with a global value only.  SETTING is
  (:key NAME :module NAME :doc DOC :type TYPE :layered BOOL :secret BOOL
   :editable BOOL :invalid (LAYER ...) :standard V :global V :project V
   :directory V :value V :source global|project|directory)
where :value is what is in effect at CWD, :source the layer it comes
from and :invalid names the layers whose value does not fit TYPE.
TYPE and every V are printed with `prin1': `read' them back.  An
unset :project or :directory is nil, while one set to nil is \"nil\".
:directory is nil when CWD is the project root.  A secret has no V;
:has-value says whether it is set.  :editable is false when a value
does not survive printing (a function object, say)."
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (root (harness-config--root cwd))
         (sub (not (string= cwd root)))
         (project (harness-config--dir-locals-alist root))
         (directory (and sub (harness-config--dir-locals-alist cwd)))
         (pfile (expand-file-name dir-locals-file root))
         (dfile (and sub (expand-file-name dir-locals-file cwd)))
         (settings (append (mapcar (lambda (k) (harness-config--describe-key k t project directory))
                                   harness-config-keys)
                           (mapcar (lambda (k) (harness-config--describe-key k nil nil nil))
                                   (harness-config--global-options)))))
    (list :cwd cwd :root root
          :project (if (harness-method-exists-p 'project/name)
                       (harness-call 'project/name root)
                     (file-name-nondirectory (directory-file-name root)))
          :in-project (if (harness-config--in-project-p cwd) t :false)
          :files (list :project pfile :project-exists (if (file-exists-p pfile) t :false)
                       :directory dfile :directory-exists (if (and dfile (file-exists-p dfile)) t :false))
          :modules (let (names)
                     (dolist (s settings) (cl-pushnew (plist-get s :module) names :test #'equal))
                     (mapcar (lambda (name)
                               (list :name name
                                     :doc (let ((m (harness-module-get (intern name))))
                                            (or (and m (harness-module-doc m)) ""))))
                             (nreverse names)))
          :settings settings)))

(defun harness-config--announce (key value scope cwd)
  "Emit `config/changed' for KEY with VALUE, SCOPE and CWD.
A secret's VALUE is left out."
  (harness-emit 'config/changed key (unless (harness-config--secret-p key) value) scope cwd))

(harness-defmethod config/set (key value &rest opts)
  "Set KEY to VALUE.  OPTS: `:scope' directory|project|global, `:cwd' DIR,
`:printed' non-nil when VALUE is the printed form of the value (see
`config/describe'), as clients whose wire is JSON send it.
KEY is a symbol or its name: a layered setting (`harness-config-keys')
or another option `config/describe' lists, which has a global value
only.  Without `:scope' an option that does not layer is set globally;
a layered one goes to the project file when CWD is in a project, unless
a directory file already exists at CWD, and without a project to the
directory file.  VALUE must fit the option's customize type, and a
directory-local value its `:safe' predicate, which spares Emacs asking
before using it; secrets never go to a dir-locals file.
Return (SCOPE . FILE-OR-NIL)."
  (let* ((key (harness-config--key key))
         (value (if (plist-get opts :printed) (harness-config--read value) value))
         (cwd (harness-config--cwd opts))
         (root (harness-config--root cwd))
         (scope (or (plist-get opts :scope)
                    (cond ((not (memq key harness-config-keys)) 'global)
                          ((file-exists-p (expand-file-name dir-locals-file cwd)) 'directory)
                          ((harness-config--in-project-p cwd) 'project)
                          (t 'directory)))))
    (harness-config--check key value scope)
    (let ((result
           (pcase scope
             ('global (harness-save-user-option key value) (cons 'global nil))
             ('project (cons 'project (harness-config--write-dir-local root key value)))
             ('directory (cons 'directory (harness-config--write-dir-local cwd key value))))))
      (harness-config--announce key value scope cwd)
      result)))

(harness-defmethod config/unset (key &rest opts)
  "Remove the value of KEY at one layer.  OPTS: `:scope', `:cwd' DIR.
KEY is as for `config/set'.  A `project' or `directory' scope (the
default for a layered setting) deletes KEY from that dir-locals file,
and the file itself once nothing is left in it, so the next layer down
applies again.  The `global' scope (the default for other options)
sets KEY back to its standard value through customize.
`config/changed' then carries the value now in effect at CWD.
Return (SCOPE . FILE-OR-NIL); FILE is nil when the file had no KEY."
  (let* ((key (harness-config--key key))
         (cwd (harness-config--cwd opts))
         (root (harness-config--root cwd))
         (scope (or (plist-get opts :scope)
                    (if (memq key harness-config-keys) 'project 'global)))
         (result
          (pcase scope
            ('global
             (harness-save-user-option key (harness-config--standard key))
             (cons 'global nil))
            ((or 'project 'directory)
             (unless (memq key harness-config-keys)
               (error "%s has a global value only" key))
             (cons scope (harness-config--delete-dir-local (if (eq scope 'project) root cwd) key)))
            (_ (error "Unknown scope %s" scope)))))
    (harness-config--announce key (harness-config--effective key cwd) scope cwd)
    result))

(harness-declare-event 'config/changed
                       "(KEY VALUE SCOPE CWD) after `config/set' or `config/unset'.
VALUE is the value set, or after an unset the value now in effect at
CWD; it is nil for a secret.")

(harness-define-module 'config
  :doc "Layered settings through customize and dir-locals."
  :requires '(project))

(provide 'harness-config)
;;; harness-config.el ends here
