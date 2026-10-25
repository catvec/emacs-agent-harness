;;; harness-elisp.el --- Evaluating Lisp out of the UI's way  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The `elisp' tool lets a model run Lisp, and model-written code never
;; runs in the user's Emacs.  Emacs runs Lisp on one thread, so code
;; that blocks -- a `call-process' waiting on a child, a loop that never
;; yields -- freezes typing and redisplay, and nothing can be done about
;; it from Lisp: `with-timeout' needs the event loop, and a signal only
;; breaks loops that call `maybe-quit', not a blocked subprocess read.
;; So the tool, which runs in the harness like every tool, evaluates in
;; a background `emacs --batch' process (`harness-elisp-batch-main'),
;; which it kills, tree and all, when it overruns its timeout.  The
;; child adds the harness to its `load-path', so `(require
;; 'harness-...)` works as it did when the code ran in the harness's own
;; Emacs.  It is a command like a bash call's, and the tool runs it in
;; the sandbox the same way (lisp/modules/harness-tools-shell.el), so it
;; sees no more of the machine than one.
;;
;; With `snapshot' the child starts from a copy of the user's Emacs
;; (lisp/harness-snapshot.el makes the copy, in the user's Emacs, and
;; the tool hands the text to the child in a file).  The child reads it
;; as data before the code runs (`harness-elisp-load-snapshot'): it sets
;; the variables the copy holds and recreates its buffers, and runs
;; nothing of the user's doing so.  What the child needs for itself, and
;; every hook and variable that holds a function, keeps the child's own
;; value and is reached as `(harness-user-value 'VARIABLE)'.  The child
;; runs read-only and offline whatever the session otherwise has, so
;; what the code changes stays in the copy.
;;
;; The elisp tool has no other place to run, and no other tool evaluates
;; model-written Lisp: the user's Emacs is read and driven with the
;; bounded `emacs_*' tools, whose requests
;; (lisp/harness-emacs-endpoint.el) carry no code.  The tool reads code
;; with `harness-elisp-read-forms' and words results with
;; `harness-elisp-format-result'.  `harness-elisp-eval-string' is the
;; background child's evaluator, and `harness-elisp-payload' the shape
;; it reports in.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness)

(defvar harness-elisp--timeout 30
  "Seconds an `elisp' evaluation may take before it is abandoned.
Internal, not an option (see docs/configuration-audit.md): the tool's
`:timeout' input overrides it per call.  In the child process the value
bounds code that yields to the event loop; code that blocks entirely is
stopped by the process timeout.")

(defvar harness-elisp--max-value-chars 10000
  "Printed values longer than this are elided in `elisp' results.
Internal, not an option (see docs/configuration-audit.md).")

(defcustom harness-elisp-emacs (expand-file-name invocation-name invocation-directory)
  "Emacs program the `elisp' tool runs its evaluations in."
  :type 'file :group 'harness)

;;;; Evaluating a string

(defun harness-elisp-read-forms (code)
  "Return the list of forms read from CODE.
Only Lisp's syntax table is set, not `emacs-lisp-mode': a mode would
run its hooks."
  (with-temp-buffer
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (insert code)
    (goto-char (point-min))
    (let (forms)
      ;; Skip whitespace and comments between forms so a clean end of
      ;; input is told apart from an unterminated form.
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (push (condition-case nil
                  (read (current-buffer))
                (end-of-file (error "End of file during parsing: unbalanced form at line %d"
                                    (line-number-at-pos))))
              forms))
      (nreverse forms))))

(defun harness-elisp--messages-end ()
  "Return the current end of *Messages*, or 1 when the buffer is absent."
  (let ((buf (messages-buffer)))
    (with-current-buffer buf (point-max))))

(defun harness-elisp--messages-since (pos)
  "Return the text of *Messages* from POS to the end, trimmed."
  (let ((buf (get-buffer "*Messages*")))
    (if (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (string-trim (buffer-substring-no-properties (min pos (point-max)) (point-max))))
      "")))

(defun harness-elisp-print-value (value)
  "Return VALUE printed for a tool result, within `harness-elisp--max-value-chars'."
  (harness-truncate-end
   (string-trim-right
    (condition-case err
        (pp-to-string value)
      (error (format "%S [pp failed: %s]" value (error-message-string err)))))
   harness-elisp--max-value-chars))

(defun harness-elisp-format-result (value output messages &optional note)
  "Return the content an `elisp' tool result shows.
VALUE is the printed value, OUTPUT what the code printed and MESSAGES
the `message' calls it made; empty sections are left out.  NOTE, when
there is one, is said last: the copy of the user's Emacs the child
started from was not whole, or could not be read."
  (string-join
   (delq nil
         (list (format "=> %s" value)
               (unless (string-empty-p output)
                 (concat "--- output ---\n" (string-trim-right output)))
               (unless (string-empty-p messages)
                 (concat "--- messages ---\n" messages))
               (and note (not (string-empty-p note))
                    (concat "--- snapshot ---\n" note))))
   "\n"))

(defun harness-elisp-eval-string (code)
  "Evaluate CODE and return (VALUE OUTPUT MESSAGES).
OUTPUT is what the forms printed to `standard-output'; MESSAGES are
`message' calls logged while they ran.  Signals an error when the code
does not parse or a form does not evaluate."
  (let* ((forms (harness-elisp-read-forms code))
         (out (generate-new-buffer " *harness-elisp-out*" t))
         (msg-start (harness-elisp--messages-end))
         (value nil))
    (unwind-protect
        (let ((standard-output out)
              (message-log-max t)
              (inhibit-message t)
              (debug-on-error nil))
          (with-timeout (harness-elisp--timeout
                         (error "Evaluation exceeded %ss" harness-elisp--timeout))
            (dolist (form forms)
              (setq value (eval form t))))
          (list value
                (with-current-buffer out (buffer-string))
                (harness-elisp--messages-since msg-start)))
      (when (buffer-live-p out) (kill-buffer out)))))

;;;; A copy of the user's Emacs

(defconst harness-elisp-snapshot-kept-names
  '(load-path exec-path process-environment initial-environment features load-history
    after-load-alist current-load-list load-file-name load-true-file-name load-in-progress
    load-suffixes load-file-rep-suffixes standard-output standard-input noninteractive
    command-line-args command-line-args-left command-line-functions command-switch-alist
    default-directory user-emacs-directory user-init-file custom-file invocation-name
    invocation-directory max-lisp-eval-depth max-specpdl-size lexical-binding obarray debugger
    signal-hook-function file-name-handler-alist temporary-file-directory
    small-temporary-file-directory shell-file-name shell-command-switch exec-directory
    data-directory doc-directory source-directory installation-directory system-name
    window-system initial-window-system timer-list timer-idle-list create-lockfiles
    locale-coding-system default-process-coding-system buffer-file-coding-system
    buffer-undo-list enable-multibyte-characters unread-command-events
    garbage-collection-messages gc-cons-threshold gc-cons-percentage)
  "Variables whose value in the child is the child's own, whatever the copy holds.
The child needs them to work: where it loads from, what it runs, where
it prints, what it does on an error.  The user's value of each is in the
copy and `harness-user-value' gives it.")

(defconst harness-elisp-snapshot-kept-regexp
  (concat "\\`\\(?:debug-\\|inhibit-\\|print-\\|read-\\|invocation-\\|command-line-args\\|coding-system-for-"
          "\\|gc-\\|native-comp-\\|comp-\\|byte-compile-\\|x-\\|ns-\\|w32-\\|pgtk-\\|haiku-\\|android-"
          "\\|emacs-startup\\|after-init\\|before-init\\|kill-emacs\\|window-system\\)"
          ;; What the child would call by itself: a hook, a variable that holds a
          ;; function, an alist that names the function for a file.
          "\\|-hooks?\\'\\|-functions?\\'\\|-handlers?\\'\\|-advice\\'\\|-mode-alist\\'\\|-coding-system-alist\\'")
  "Variables whose names match this keep the child's own value.
Besides `harness-elisp-snapshot-kept-names': the child's debugger, printer
and reader, its compiler and the windowing system it does not have; and
every hook and variable that holds a function, which the child would
call by itself on an edit, a save or an exit.  Loading a copy never runs
anything of the user's, and this is why it must stay that way afterwards.")

(defvar harness-user-values (make-hash-table :test 'eq)
  "The value each variable of the copy had in the user's Emacs.
`harness-user-value' reads it.  Empty without a snapshot.")

(defvar harness-snapshot-info nil
  "What the copy of the user's Emacs held and what the child did with it.
A plist, `harness-snapshot-info' gives it: `:header' (the time and the
Emacs it was taken in), `:manifest' (what the user's Emacs left out and
why, see lisp/harness-snapshot.el), `:partial' (a reason when the copy
is not whole) and `:loaded' (counts of what was set, kept, skipped and
recreated).  Nil without a snapshot.")

(defun harness-snapshot-info ()
  "Return what the copy of the user's Emacs held, as a plist, or nil without one."
  harness-snapshot-info)

(defun harness-user-value (symbol)
  "Return the value SYMBOL had in the user's Emacs, according to the copy.
This is the way to read the variables the child keeps its own value of,
such as `load-path', `features' or a hook.  Signals an error for a
variable the copy does not hold, because it was withheld (the manifest
names those, `harness-snapshot-info'), too big, or void there."
  (let ((value (gethash symbol harness-user-values harness-user-values)))
    (if (eq value harness-user-values)
        (error "The copy of the user's Emacs holds no value for %s (see `harness-snapshot-info')" symbol)
      value)))

(defun harness-elisp--user-object-p (value)
  "Non-nil when VALUE is a placeholder of the copy for an object data cannot hold."
  (and (recordp value) (memq (aref value 0) '(harness-user-object harness-user-truncated))))

(defun harness-elisp--snapshot-kept-p (name)
  "Non-nil when the variable NAME, a symbol, keeps the child's own value."
  (or (memq name harness-elisp-snapshot-kept-names)
      (string-match-p harness-elisp-snapshot-kept-regexp (symbol-name name))))

(defun harness-elisp--snapshot-set (name value counts)
  "Make the user's VALUE the value of the variable NAME in the child.
COUNTS, a vector, tallies what happens: [set kept skipped errors].  The
user's value is in `harness-user-values' either way."
  (puthash name value harness-user-values)
  (cond
   ((harness-elisp--snapshot-kept-p name) (cl-incf (aref counts 1)))
   ;; The child's variable holds an object of its own where the user's
   ;; held one of theirs: the placeholder means nothing to the child.
   ((and (harness-elisp--user-object-p value) (boundp name)) (cl-incf (aref counts 2)))
   (t
    (condition-case nil
        (progn
          (if (or (boundp name) (special-variable-p name))
              (set-default name value)
            (defvar-1 name value))
          (cl-incf (aref counts 0)))
      (error (cl-incf (aref counts 3)))))))

(defun harness-elisp--snapshot-buffer (entry deadline counts)
  "Recreate the buffer ENTRY describes, the plist of a `b' form of the copy.
It gets its text, its major mode if the child has that function and it
runs within DEADLINE (else Fundamental mode), then its file name and
directory, its point, its flag and its local variables.  No mode hook
runs, and none of the user's functions.  COUNTS, a vector, tallies the
modes that did not run in its fifth slot."
  (let* ((name (plist-get entry :name))
         (mode (plist-get entry :mode))
         (from (or (plist-get entry :text-from) 1)))
    (when (and (stringp name) (not (string-empty-p name)))
      (with-current-buffer (get-buffer-create name)
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t)
              (buffer-undo-list t))
          (erase-buffer)
          (insert (or (plist-get entry :text) ""))
          (if (and (symbolp mode) mode (not (eq mode 'fundamental-mode)) (fboundp mode)
                   (< (float-time) deadline))
              (condition-case nil
                  ;; The mode runs; its hooks are delayed and never run.
                  (delay-mode-hooks (funcall mode))
                (error (cl-incf (aref counts 4))
                       (fundamental-mode)))
            (fundamental-mode))
          (setq-local buffer-file-name (plist-get entry :file))
          (when (stringp (plist-get entry :directory))
            (setq-local default-directory (plist-get entry :directory)))
          (dolist (local (plist-get entry :locals))
            (when (and (consp local) (symbolp (car local)) (not (keywordp (car local)))
                       (not (harness-elisp--snapshot-kept-p (car local)))
                       (not (memq (car local) '(buffer-file-name default-directory major-mode mode-name))))
              (condition-case nil
                  (set (make-local-variable (car local)) (cdr local))
                (error nil))))
          (goto-char (max (point-min)
                          (min (point-max) (1+ (- (or (plist-get entry :point) from) from)))))
          (set-buffer-modified-p (and (plist-get entry :modified) t)))))))

(defun harness-elisp-load-snapshot (file)
  "Read the copy of the user's Emacs in FILE into this child, and return its info.
FILE holds forms (see lisp/harness-snapshot.el), read as data, never
evaluated: a header, buffers, variables and a manifest.  Each variable
becomes the value it had in the user's Emacs, but for those the child
keeps its own (`harness-elisp-snapshot-kept-regexp'); each buffer is
recreated; nothing of the user's runs.  The result, also in
`harness-snapshot-info', is a plist of the header, the manifest, the
reason the copy is partial if it is, and what was done."
  (clrhash harness-user-values)
  (let ((read-eval nil)
        (counts (make-vector 5 0))
        (buffers 0)
        (deadline (+ (float-time) 10))
        (header nil) (manifest nil) (partial nil) (failed nil))
    ;; The child works on a copy: it never locks, nor offers to save, a file.
    (setq create-lockfiles nil)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (goto-char (point-min))
      (condition-case err
          (while (progn (skip-chars-forward " \t\r\n") (not (eobp)))
            (let ((form (read (current-buffer))))
              (pcase (car-safe form)
                ('v (when (symbolp (cadr form))
                      (harness-elisp--snapshot-set (cadr form) (nth 2 form) counts)))
                ('b (harness-elisp--snapshot-buffer (cdr form) deadline counts)
                    (cl-incf buffers))
                ('snapshot (setq header (cdr form)))
                ('manifest (setq manifest (cdr form)))
                ('partial (setq partial (cadr form))))))
        (error (setq failed (error-message-string err)))))
    (setq harness-snapshot-info
          (list :header header :manifest manifest :partial partial :error failed
                :loaded (list :variables (aref counts 0) :kept (aref counts 1) :skipped (aref counts 2)
                              :errors (aref counts 3) :buffers buffers :modes-failed (aref counts 4))))))

(defun harness-elisp--snapshot-summary (info)
  "Return the part of INFO, from `harness-elisp-load-snapshot', the tool reports.
A plist of what was loaded, the time of the copy and, if it is not
whole or could not be read, why."
  (let ((header (plist-get info :header))
        (loaded (plist-get info :loaded)))
    (list :variables (plist-get loaded :variables)
          :kept (plist-get loaded :kept)
          :buffers (plist-get loaded :buffers)
          :time (plist-get header :time)
          :partial (plist-get info :partial)
          :error (plist-get info :error))))

;;;; The child process

(defun harness-elisp-payload (result error &optional snapshot)
  "Return the JSON-ready plist that reports an `elisp' evaluation.
RESULT is (VALUE OUTPUT MESSAGES) from `harness-elisp-eval-string', or
nil; ERROR is the failure's message, or nil; SNAPSHOT, when the child
started from a copy of the user's Emacs, is what
`harness-elisp--snapshot-summary' gives, and goes in `:snapshot'.  The
background Emacs writes it as JSON, and the `elisp' tool reads it back."
  (if error
      (list :value "" :output "" :messages "" :error error :snapshot snapshot)
    (pcase-let ((`(,value ,output ,messages) result))
      (list :value (harness-elisp-print-value value)
            :output (string-trim-right output)
            :messages messages
            :error nil
            :snapshot snapshot))))

(defun harness-elisp--batch-write (path payload)
  "Write PAYLOAD as JSON to PATH, quietly."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (harness-json-encode payload) nil path nil 'silent)))

(defun harness-elisp--batch-number (variable)
  "Return the positive number in environment VARIABLE, or nil."
  (let ((value (getenv variable)))
    (when (and value (string-match-p "\\`[0-9.]*[0-9]\\'" value))
      (let ((n (string-to-number value)))
        (and (> n 0) n)))))

(defun harness-elisp-batch-main ()
  "Evaluate the code named by $HARNESS_ELISP_CODE.
Entry point of the child Emacs the `elisp' tool starts: the result is
a JSON file named by $HARNESS_ELISP_RESULT, so the child's own output
cannot be confused with it.  The value is truncated to
$HARNESS_ELISP_MAX_VALUE_CHARS and evaluation stops after
$HARNESS_ELISP_TIMEOUT seconds."
  ;; The harness is loaded so `(require 'harness-...)' works, as it did
  ;; when this code ran in the harness's own Emacs.
  (harness--setup-load-path)
  (when-let* ((n (harness-elisp--batch-number "HARNESS_ELISP_MAX_VALUE_CHARS")))
    (setq harness-elisp--max-value-chars n))
  (when-let* ((n (harness-elisp--batch-number "HARNESS_ELISP_TIMEOUT")))
    (setq harness-elisp--timeout n))
  (let* ((code-file (getenv "HARNESS_ELISP_CODE"))
         (result-file (getenv "HARNESS_ELISP_RESULT")))
    (unless result-file
      (princ "harness-elisp: HARNESS_ELISP_RESULT is not set\n" #'external-debugging-output)
      (kill-emacs 1))
    (let* ((snapshot-file (getenv "HARNESS_ELISP_SNAPSHOT"))
           (snapshot (and snapshot-file
                          (condition-case err
                              (harness-elisp--snapshot-summary (harness-elisp-load-snapshot snapshot-file))
                            (error (list :error (format "the copy could not be loaded: %s"
                                                        (error-message-string err)))))))
           (payload (condition-case err
                        (progn
                          (when (or (not code-file) (not (file-readable-p code-file)))
                            (error "Cannot read the code file %s" code-file))
                          (harness-elisp-payload
                           (let ((code (with-temp-buffer
                                         (insert-file-contents code-file)
                                         (buffer-string))))
                             (harness-elisp-eval-string code))
                           nil snapshot))
                      (error (harness-elisp-payload nil (error-message-string err) snapshot)))))
      ;; Anything the code printed to the terminal is noise to the parent,
      ;; which reads the result file.
      (harness-elisp--batch-write result-file payload)
      (kill-emacs 0))))

(provide 'harness-elisp)
;;; harness-elisp.el ends here
