;;; harness-policy.el --- Settings an administrator fixes  -*- lexical-binding: t; -*-

;;; Commentary:

;; A policy sets harness options to values the user cannot change: the
;; managed settings of a machine whose administrator decides what the
;; harness may do.  It lives in a file the user does not own,
;; `harness-policy-default-file' (/etc/harness/policy.el, on Linux and
;; macOS alike), and holds one alist, as a .dir-locals.el file does:
;;
;;   ((harness-corporate-mode . t)
;;    (harness-permission-mode . ask)
;;    (harness-sandbox-policy . required)
;;    (harness-allowed-models . ("claude:*")))
;;
;; The file is read, never evaluated: values are data, and each must
;; fit its option's customize type.  Every setting is then in one of
;; three states: unset (its default), set (by the user's customizations,
;; or a project's or directory's .dir-locals.el), or set by policy,
;; which wins over every other layer.  docs/policy.md has the design:
;; where the file lives and why, what guards a policy value, and what a
;; policy means for sessions, permissions and models.
;;
;; Each process reads the file itself.  The harness process does not
;; take the policy from the UI that starts it: what the UI forwards is
;; the user's configuration, which the policy overrides there as well.
;; The options the harness process sets for itself, which describe that
;; process rather than the user's choices, it keeps as it set them
;; (`harness-policy-exempt').
;; `harness-start' reads the policy before any module loads, applies it
;; to the options defined by then (harness.el's and the core's: the
;; modules to load are options too) and again once the modules have
;; defined theirs.  `harness-reload' reads the file again.  An option is
;; defined once its `defcustom' has been evaluated: one that only has a
;; value, set before its module loaded (the harness process gets the
;; user's values that way, and the UI does not load the modules at
;; all), is left alone until then.
;;
;; A policy that cannot be trusted stops the harness: a file that is
;; there but cannot be read, holds anything but such an alist, or gives
;; an option a value its type refuses makes `harness-start' signal,
;; naming the file and the fault.  A variable this harness does not
;; define as an option, as in a policy written for a newer harness, is
;; reported once every module has loaded, and skipped.
;;
;; Applying a policy value sets the option's default value, as
;; Customize would, and then keeps it there:
;;
;; - the option's `custom-set' function becomes
;;   `harness-policy--custom-set', so `setopt', Customize,
;;   `customize-set-variable' and the custom file warn and leave the
;;   policy value in place;
;; - a variable watcher refuses `setq' and `set-default' of any other
;;   value with an error, so the value never changes (a let-binding,
;;   which ends, and a buffer-local value pass);
;; - the option joins `ignored-local-variables', so no file-local or
;;   directory-local value is set for it in any buffer;
;; - the code that changes options on the user's behalf -- the config
;;   module's `config/set' and `config/unset', which the settings page
;;   and ACP clients use, `harness-save-user-option', the permission
;;   answers that would remember, the remote control's start and stop
;;   -- asks `harness-policy-refuse', which signals an error that gives
;;   the reason, before it changes anything.
;;
;; The config module reads a policy value over every dir-locals layer
;; and reports it with `:source policy'; modules that copy a setting per
;; session (the model, the permission mode) keep every session's copy
;; at the policy value too.
;;
;; This holds a policy against every way the harness, its settings
;; page, its agents and Emacs's customization change a setting.  It is
;; no sandbox for Lisp: code the user runs in their own Emacs (their
;; init file, the harness's sources) can do anything, as it can for any
;; package; the file system, which keeps the policy file out of the
;; user's reach, is the boundary.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)

(defconst harness-policy-default-file "/etc/harness/policy.el"
  "Where the harness reads its policy, on Linux and macOS alike.
Only an administrator can write there: /etc (/private/etc on macOS)
belongs to root, and deploying a file there is what configuration
management and MDM tools do.  See docs/policy.md.")

(defvar harness-policy-file harness-policy-default-file
  "The policy file this Emacs reads, normally `harness-policy-default-file'.
This is no user option: it is never forwarded to the harness process,
which reads the default file itself.  Tests bind it to a file of their
own, or to nil for no policy at all.")

(defvar harness-policy-exempt nil
  "Options the policy leaves as they are in this Emacs.
The harness process sets a few options for itself before it starts
\(`harness-server--own-variables': that it is no UI, which modules it
loads, where it listens), since they describe that process, not the
user's choices; it lists them here.  A policy that sets one sets it in
the user's Emacs only.")

(defvar harness-policy--entries nil
  "The policy in force: an alist (OPTION . VALUE), in the file's order.")

(defvar harness-policy--file nil
  "The file `harness-policy--entries' was read from, or nil when there is none.")

(defvar harness-policy--guarded nil
  "Options whose policy value is guarded (see `harness-policy--guard').")

(defvar harness-policy--setters (make-hash-table :test 'eq)
  "Option -> the `custom-set' function it had before the policy guarded it.")

(defvar harness-policy--applying nil
  "Non-nil while the policy sets an option itself, which its watcher lets pass.")

(defvar harness-policy--reported nil
  "Options of the policy this harness does not define, reported already.")

(defvar harness-started)

;;;; Reading

(defun harness-policy--fail (file format-string &rest args)
  "Signal that the policy in FILE cannot be trusted.
FORMAT-STRING with ARGS says why."
  (error "Policy %s: %s" file (apply #'format-message format-string args)))

(defun harness-policy-read (file)
  "Return the policy FILE holds as an alist (OPTION . VALUE); nil without FILE.
FILE holds one alist of `harness-' options and their values, which is
read and never evaluated; comments and a file that is empty but for
them are fine.  Signal an error when FILE is there but cannot be read
\(a directory that hides it included), holds anything but one such
alist, or sets an option twice."
  (when file
    (let ((attributes (condition-case err
                          (file-attributes file)
                        (error (harness-policy--fail file "cannot be read: %s"
                                                     (error-message-string err))))))
      (when attributes
        (with-temp-buffer
          (condition-case err
              (insert-file-contents file)
            (error (harness-policy--fail file "cannot be read: %s" (error-message-string err))))
          ;; So that `forward-comment' knows a comment when it sees one.
          (set-syntax-table emacs-lisp-mode-syntax-table)
          (goto-char (point-min))
          (forward-comment (buffer-size))
          (unless (eobp)
            (let* ((read-circle nil)
                   (form (condition-case err
                             (read (current-buffer))
                           (end-of-file (harness-policy--fail file "ends inside a list or a string"))
                           (error (harness-policy--fail file "is not readable Lisp data: %s"
                                                        (error-message-string err)))))
                   seen)
              (forward-comment (buffer-size))
              (unless (eobp)
                (harness-policy--fail file "holds more than one form: put every setting in one alist"))
              (unless (proper-list-p form)
                (harness-policy--fail file "holds %S, not an alist of (OPTION . VALUE)" form))
              (dolist (entry form)
                (unless (and (consp entry) (car entry) (symbolp (car entry)))
                  (harness-policy--fail file "%S is not an (OPTION . VALUE) entry" entry))
                (let ((option (car entry)))
                  (unless (string-prefix-p "harness-" (symbol-name option))
                    (harness-policy--fail file "%s is not a harness option" option))
                  (when (memq option seen)
                    (harness-policy--fail file "%s is set twice" option))
                  (push option seen)))
              (mapcar (lambda (entry) (cons (car entry) (cdr entry))) form))))))))

(defun harness-policy--type-match-p (option value)
  "Non-nil when VALUE fits the customize type of OPTION.
A type the widget library cannot check passes: that is a fault of the
harness, not of the policy."
  (let ((type (get option 'custom-type)))
    (or (null type)
        (condition-case nil
            (progn (require 'wid-edit)
                   (widget-apply (widget-convert type) :match value))
          (error t)))))

(defun harness-policy--defined-p (option)
  "Non-nil when OPTION is defined as a user option: its `defcustom' was evaluated.
A variable that only has a value, set before its definition, is not."
  (custom-variable-p option))

(defun harness-policy--check (option value file)
  "Signal an error unless VALUE, which fits OPTION's type, may be its policy value.
OPTION is defined (`harness-policy--defined-p').  FILE is the policy
file, for the message."
  (unless (harness-policy--type-match-p option value)
    (harness-policy--fail file "%S is not a valid value for %s, whose type is %S"
                          value option (get option 'custom-type))))

(defun harness-policy-load ()
  "Read `harness-policy-file' and make it the policy in force; return its entries.
The options defined already are checked at once: a policy that gives
one of them a value its type refuses is not taken.  Signal an error
when the file cannot be trusted (see `harness-policy-read'); the
policy in force then stays as it was.
`harness-policy-apply' puts the policy into effect."
  (let* ((file harness-policy-file)
         (entries (harness-policy-read file)))
    (dolist (entry entries)
      (when (harness-policy--defined-p (car entry))
        (harness-policy--check (car entry) (cdr entry) file)))
    (setq harness-policy--entries entries
          harness-policy--file (and entries file)
          harness-policy--reported nil)
    entries))

;;;; The policy in force

(defun harness-policy-entry (option)
  "Return (OPTION . VALUE) when the policy in force sets OPTION, else nil."
  (assq option harness-policy--entries))

(defun harness-policy-pinned-p (option)
  "Non-nil when the policy in force sets OPTION, so the user cannot change it."
  (and (assq option harness-policy--entries) t))

(defun harness-policy-entries ()
  "Return the policy in force as an alist (OPTION . VALUE), in the file's order."
  (copy-alist harness-policy--entries))

(defun harness-policy-file-name ()
  "Return the file the policy in force comes from, or nil without a policy."
  harness-policy--file)

(defun harness-policy-locked-message (option)
  "Return the reason OPTION cannot be changed: the policy sets it."
  (format "%s is set by policy (%s) and cannot be changed" option
          (or harness-policy--file harness-policy-file)))

(defun harness-policy-refuse (option)
  "Signal an error when the policy in force sets OPTION.
Code that changes an option for the user calls this first, so a policy
value is refused with its reason rather than changed."
  (when (harness-policy-pinned-p option)
    (error "%s" (harness-policy-locked-message option))))

;;;; Guards

(defun harness-policy--setter (option)
  "Return the function that sets OPTION as Customize would, without the guard."
  (or (gethash option harness-policy--setters) #'set-default))

(defun harness-policy--custom-set (option value)
  "Set OPTION to VALUE as Customize does, unless the policy sets OPTION.
This is the `custom-set' function of every option the policy sets, so
`setopt', Customize, `customize-set-variable' and the custom file come
here.  For such an option they get the policy value instead, with a
warning once the harness has started.  Before, an option being defined
takes the policy value quietly, whatever value it had."
  (let ((entry (harness-policy-entry option))
        (setter (harness-policy--setter option)))
    (if (not entry)
        (funcall setter option value)
      (when (and (bound-and-true-p harness-started)
                 (not (equal value (cdr entry))))
        (display-warning 'harness (harness-policy-locked-message option)))
      (let ((harness-policy--applying t))
        (funcall setter option (cdr entry))))))

(defun harness-policy--watch (option value operation where)
  "Refuse to change the global value of OPTION away from its policy value.
The variable watcher (see `add-variable-watcher') of every option the
policy sets: OPERATION `set' to another VALUE, and `makunbound', signal
an error, which leaves the value as it was.  A buffer-local
value (WHERE non-nil) and a let-binding pass."
  (when (and (not harness-policy--applying)
             (null where)
             (memq operation '(set makunbound)))
    (when-let* ((entry (harness-policy-entry option)))
      (unless (and (eq operation 'set) (equal value (cdr entry)))
        (error "%s" (harness-policy-locked-message option))))))

(defun harness-policy--guard (option)
  "Keep OPTION at its policy value: see the Commentary.
Its watcher waits until OPTION is defined, as its definition may set
it to another value first (with a `:set' function of its own, which
replaces the guard's until the policy is applied again)."
  (let ((setter (get option 'custom-set)))
    ;; A definition evaluated again (a reload) puts back a `:set'
    ;; function of its own: that is the one to call from now on.
    (unless (eq setter #'harness-policy--custom-set)
      (puthash option setter harness-policy--setters)
      (put option 'custom-set #'harness-policy--custom-set)))
  (when (harness-policy--defined-p option)
    (add-variable-watcher option #'harness-policy--watch))
  (unless (memq option ignored-local-variables)
    (push option ignored-local-variables))
  (cl-pushnew option harness-policy--guarded))

(defun harness-policy--release (option)
  "Stop guarding OPTION, which the policy no longer sets.
It takes the value the user last customized, else saved, else its
standard value."
  (remove-variable-watcher option #'harness-policy--watch)
  (let ((setter (gethash option harness-policy--setters)))
    (when (eq (get option 'custom-set) #'harness-policy--custom-set)
      (put option 'custom-set setter))
    (remhash option harness-policy--setters)
    (when (harness-policy--defined-p option)
      (let ((own (or (get option 'customized-value) (get option 'saved-value)
                     (get option 'standard-value))))
        (when own
          (condition-case err
              (funcall (or setter #'set-default) option (eval (car own) t))
            (error (harness-log 'warn "policy: could not give %s its own value back: %S"
                                option err)))))))
  (setq ignored-local-variables (delq option ignored-local-variables)
        harness-policy--guarded (delq option harness-policy--guarded)))

;;;; Applying

(defun harness-policy-apply (&optional final)
  "Give every option the policy sets its policy value, and keep it there.
An option defined by now (`harness-policy--defined-p') is checked
first, as by `harness-policy-load': when one has a value its type
refuses, nothing changes and an error is signalled.  Then each defined
option is set, with its own `:set' function once the harness has
started (a running module may need to hear of the change), and guarded
\(see the Commentary); one not defined yet is guarded, and takes its
value as its definition is evaluated.  An option that the policy no
longer sets is released (`harness-policy--release').  An option of
`harness-policy-exempt' is left alone.  FINAL non-nil means every
module that will load has loaded: a variable still not defined as an
option is unknown to this harness, and is reported once and skipped.
Return the entries."
  (dolist (entry harness-policy--entries)
    (when (harness-policy--defined-p (car entry))
      (harness-policy--check (car entry) (cdr entry) harness-policy--file)))
  (let ((harness-policy--applying t)
        (started (bound-and-true-p harness-started)))
    (dolist (option (copy-sequence harness-policy--guarded))
      (unless (and (harness-policy-entry option) (not (memq option harness-policy-exempt)))
        (harness-policy--release option)))
    (dolist (entry harness-policy--entries)
      (let ((option (car entry)) (value (cdr entry)))
        (unless (memq option harness-policy-exempt)
          (when (and (harness-policy--defined-p option)
                     (not (equal (default-value option) value)))
            (if started
                (funcall (harness-policy--setter option) option value)
              (set-default option value)))
          (harness-policy--guard option)))))
  (when final
    (dolist (entry harness-policy--entries)
      (let ((option (car entry)))
        (unless (or (harness-policy--defined-p option) (memq option harness-policy--reported)
                    (memq option harness-policy-exempt))
          (push option harness-policy--reported)
          (let ((text (format "Policy %s sets %s, which is no option this harness defines: ignored"
                              harness-policy--file option)))
            (harness-log 'warn "%s" text)
            (unless noninteractive (display-warning 'harness text)))))))
  harness-policy--entries)

(defun harness-policy-clear ()
  "Release every option and forget the policy in force.
For tests, and for a policy file that is gone when it is read again."
  (setq harness-policy--entries nil harness-policy--file nil harness-policy--reported nil)
  (dolist (option (copy-sequence harness-policy--guarded))
    (harness-policy--release option)))

(provide 'harness-policy)
;;; harness-policy.el ends here
