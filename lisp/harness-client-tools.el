;;; harness-client-tools.el --- Tools that run in the user's Emacs  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The harness runs in its own Emacs process (see harness-server.el),
;; but some tools are about the user's Emacs: its buffers, its symbols,
;; its *Messages*, and evaluating Lisp in it.  Their implementations
;; live here and run in the Emacs that shows the UI.  The tool modules
;; (tools-emacs, tools-shell) define the tools for the model and forward
;; each call to the UI as a `_harness/client/tool' request, which
;; `harness-client-tools-run' answers.  With the harness in-process the
;; request travels the local connection, so both setups share one path.
;;
;; Results are plists (:content STRING :is-error BOOL), the shape of a
;; tool result.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'help-fns)
(require 'pp)
(require 'harness-core)
(require 'harness-util)

(defun harness-client-tools--ok (content)
  "Return a successful tool result with CONTENT."
  (list :content (if (stringp content) content (format "%S" content)) :is-error nil))

(defun harness-client-tools--error (message)
  "Return a failed tool result with MESSAGE."
  (list :content message :is-error t))

(defcustom harness-tools-emacs-value-chars 500
  "Variable values longer than this are truncated by emacs_describe."
  :type 'integer :group 'harness)

(defcustom harness-tools-emacs-messages-default 50
  "Number of *Messages* lines emacs_messages returns by default."
  :type 'integer :group 'harness)

(defun harness-client-tools--int (v default)
  "Return V as an integer, or DEFAULT."
  (cond ((integerp v) v)
        ((numberp v) (truncate v))
        ((and (stringp v) (string-match-p "\\`-?[0-9]+\\'" v)) (string-to-number v))
        (t default)))

;;;; emacs_buffers

(defun harness-client-tools--buffers (input _ctx)
  "Handler for emacs_buffers with INPUT."
  (let* ((all (harness-json-true-p (plist-get input :all)))
         (filter (plist-get input :filter))
         (rows nil))
    (dolist (b (buffer-list))
      (let ((name (buffer-name b)))
        (when (and (or all (not (string-prefix-p " " name)))
                   (or (not (stringp filter)) (string-empty-p filter)
                       (string-match-p filter name)
                       (and (buffer-file-name b) (string-match-p filter (buffer-file-name b)))))
          (with-current-buffer b
            (push (list name (symbol-name major-mode)
                        (if (buffer-modified-p) "*" "")
                        (harness-format-bytes (buffer-size))
                        (or (and buffer-file-name (abbreviate-file-name buffer-file-name))
                            (and (derived-mode-p 'dired-mode) (abbreviate-file-name default-directory))
                            ""))
                  rows)))))
    (setq rows (nreverse rows))
    (if (null rows)
        (harness-client-tools--ok "No buffers match")
      (let ((w1 (min 40 (apply #'max (mapcar (lambda (r) (length (car r))) rows))))
            (w2 (min 28 (apply #'max (mapcar (lambda (r) (length (cadr r))) rows)))))
        (harness-client-tools--ok
         (concat (format (format "%%-%ds  %%-%ds  M  %%8s  %%s\n" w1 w2) "NAME" "MODE" "SIZE" "FILE")
                 (mapconcat (lambda (r)
                              (format (format "%%-%ds  %%-%ds  %%1s  %%8s  %%s" w1 w2)
                                      (harness-truncate-end (nth 0 r) w1) (harness-truncate-end (nth 1 r) w2)
                                      (nth 2 r) (nth 3 r) (nth 4 r)))
                            rows "\n")
                 (format "\n(%d buffer%s)" (length rows) (if (= 1 (length rows)) "" "s"))))))))


;;;; emacs_buffer

(defun harness-client-tools--buffer (input _ctx)
  "Handler for emacs_buffer with INPUT."
  (let* ((name (plist-get input :name))
         (buf (and (stringp name) (get-buffer name)))
         (offset (max 1 (harness-client-tools--int (plist-get input :offset) 1)))
         (limit (harness-client-tools--int (plist-get input :limit) nil)))
    (cond
     ((not (stringp name)) (harness-client-tools--error "Missing name"))
     ((null buf) (harness-client-tools--error (format "No buffer named %S; use emacs_buffers to list them" name)))
     (t
      (with-current-buffer buf
        (save-excursion
          (save-restriction
            (widen)
            (let* ((total (count-lines (point-min) (point-max)))
                   (last (if limit (min total (+ offset limit -1)) total))
                   (lines nil) (n offset))
              (goto-char (point-min))
              (forward-line (1- offset))
              (while (and (<= n last) (not (eobp)))
                (push (format "%6d\t%s" n (buffer-substring-no-properties (line-beginning-position) (line-end-position))) lines)
                (cl-incf n)
                (forward-line 1))
              (cond
               ((zerop total) (harness-client-tools--ok (format "Buffer %s is empty" name)))
               ((> offset total) (harness-client-tools--error (format "offset %d is past the end of %s (%d lines)" offset name total)))
               (t (harness-client-tools--ok
                   (format "%s\n\n[%s (%s): lines %d-%d of %d%s%s]"
                           (string-join (nreverse lines) "\n") name major-mode offset (1- n) total
                           (if buffer-file-name (format ", file %s" (abbreviate-file-name buffer-file-name)) "")
                           (if (buffer-modified-p) ", modified" "")))))))))))))


;;;; emacs_describe

(defun harness-client-tools--describe-function (sym)
  "Return a description of SYM as a function, or nil."
  (when (fboundp sym)
    (let ((args (condition-case nil (help-function-arglist sym t) (error 'unknown)))
          (doc (condition-case nil (documentation sym t) (error nil)))
          (kind (cond ((macrop sym) "macro")
                      ((special-form-p sym) "special form")
                      ((commandp sym) "command")
                      ((subrp (symbol-function sym)) "primitive")
                      (t "function"))))
      (format "%s: %S\n%s" kind
              (cons sym (if (eq args 'unknown) '(\?) args))
              (if (and doc (not (string-empty-p doc))) doc "(no documentation)")))))

(defun harness-client-tools--describe-variable (sym)
  "Return a description of SYM as a variable, or nil."
  (when (or (boundp sym) (get sym 'variable-documentation))
    (let ((doc (documentation-property sym 'variable-documentation t))
          (value (if (boundp sym)
                     (condition-case nil (prin1-to-string (symbol-value sym))
                       (error "#<unprintable>"))
                   "void")))
      (format "%s: %s\nvalue: %s\n%s"
              (cond ((custom-variable-p sym) "user option")
                    ((local-variable-if-set-p sym) "buffer-local variable")
                    (t "variable"))
              sym
              (harness-truncate-end value harness-tools-emacs-value-chars)
              (if (and doc (not (string-empty-p doc))) doc "(no documentation)")))))

(defun harness-client-tools--describe (input _ctx)
  "Handler for emacs_describe with INPUT."
  (let* ((name (plist-get input :symbol))
         (sym (and (stringp name) (intern-soft (string-trim name)))))
    (cond
     ((not (stringp name)) (harness-client-tools--error "Missing symbol"))
     ((null sym) (harness-client-tools--error (format "No symbol named %s is known to this Emacs" name)))
     (t
      (let ((parts (delq nil (list (harness-client-tools--describe-function sym)
                                   (harness-client-tools--describe-variable sym)
                                   (when (facep sym) (format "face: %s\n%s" sym (or (face-documentation sym) "")))))))
        (if parts
            (harness-client-tools--ok (string-join parts "\n\n"))
          (harness-client-tools--error (format "%s is neither a function nor a variable" sym))))))))


;;;; emacs_messages

(defun harness-client-tools--messages (input _ctx)
  "Handler for emacs_messages with INPUT."
  (let* ((count (max 1 (harness-client-tools--int (plist-get input :count) harness-tools-emacs-messages-default)))
         (buf (messages-buffer)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (forward-line (- count))
        (let ((text (string-trim-right (buffer-substring-no-properties (point) (point-max)))))
          (harness-client-tools--ok (if (string-empty-p text) "*Messages* is empty" text)))))))



(defcustom harness-elisp-timeout 30
  "Seconds an elisp evaluation may take before it is abandoned."
  :type 'number :group 'harness)

(defcustom harness-elisp-max-value-chars 10000
  "Printed values longer than this are elided in elisp results."
  :type 'integer :group 'harness)

(defun harness-client-tools--read-forms (code)
  "Return the list of forms read from CODE."
  (with-temp-buffer
    (insert code)
    (emacs-lisp-mode)
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

(defun harness-client-tools--messages-since (pos)
  "Return the text of *Messages* from POS to the end, trimmed."
  (let ((buf (get-buffer "*Messages*")))
    (if (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (string-trim (buffer-substring-no-properties (min pos (point-max)) (point-max))))
      "")))

(defun harness-client-tools--messages-end ()
  "Return the current end of *Messages*, or 1 when the buffer is absent."
  (let ((buf (messages-buffer)))
    (with-current-buffer buf (point-max))))

(defun harness-client-tools--eval (code)
  "Evaluate CODE and return (VALUE OUTPUT MESSAGES).
OUTPUT is what the forms printed to `standard-output'; MESSAGES are
`message' calls logged while they ran."
  (let* ((forms (harness-client-tools--read-forms code))
         (out (generate-new-buffer " *harness-elisp-out*" t))
         (msg-start (harness-client-tools--messages-end))
         (value nil))
    (unwind-protect
        (let ((standard-output out)
              (message-log-max t)
              (inhibit-message t)
              (debug-on-error nil))
          (with-timeout (harness-elisp-timeout
                         (error "Evaluation exceeded %ss" harness-elisp-timeout))
            (dolist (form forms)
              (setq value (eval form t))))
          (list value
                (with-current-buffer out (buffer-string))
                (harness-client-tools--messages-since msg-start)))
      (when (buffer-live-p out) (kill-buffer out)))))

(defun harness-client-tools--elisp (input _ctx)
  "Handler for the elisp tool with INPUT."
  (let ((code (plist-get input :code)))
    (if (or (not (stringp code)) (string-blank-p code))
        (harness-client-tools--error "Missing code")
      (condition-case err
          (pcase-let ((`(,value ,output ,messages) (harness-client-tools--eval code)))
            (let ((printed (string-trim-right
                            (condition-case perr
                                (pp-to-string value)
                              (error (format "%S [pp failed: %s]" value (error-message-string perr)))))))
              (harness-client-tools--ok
               (string-join
                (delq nil
                      (list (format "=> %s" (harness-truncate-end printed harness-elisp-max-value-chars))
                            (unless (string-empty-p output)
                              (concat "--- output ---\n" (string-trim-right output)))
                            (unless (string-empty-p messages)
                              (concat "--- messages ---\n" messages))))
                "\n"))))
        (error (harness-client-tools--error (format "Error: %s" (error-message-string err))))))))

;;;; Dispatch

(defconst harness-client-tools
  '(("emacs_buffers" . harness-client-tools--buffers)
    ("emacs_buffer" . harness-client-tools--buffer)
    ("emacs_describe" . harness-client-tools--describe)
    ("emacs_messages" . harness-client-tools--messages)
    ("elisp" . harness-client-tools--elisp))
  "Tool name -> function (INPUT CTX) run in the user's Emacs.")

(defun harness-client-tools-run (name input)
  "Run the client tool NAME with INPUT here; return a tool result plist."
  (let ((fn (cdr (assoc name harness-client-tools))))
    (if (not fn)
        (harness-client-tools--error (format "Unknown client tool %s" name))
      (condition-case err
          (funcall fn input nil)
        (error (harness-client-tools--error (format "Error: %s" (error-message-string err))))))))

(defun harness-client-tools-customize-save (name printed)
  "Save the user option NAME with the value read from PRINTED in `custom-file'.
Only `harness-' options: the request comes from the harness process."
  (unless (and (stringp name) (string-prefix-p "harness-" name))
    (error "Refusing to save %s: not a harness option" name))
  ;; Module options are not defined in the UI's Emacs, so intern the name.
  (let ((sym (intern name)))
    (customize-save-variable sym (car (read-from-string printed)))
    t))

(defun harness-client-tools-revert-visiting (path)
  "Revert an unmodified live buffer visiting PATH so it shows the new content."
  (let ((buf (and (stringp path) (find-buffer-visiting path))))
    (when (and buf (buffer-live-p buf) (not (buffer-modified-p buf)))
      (with-current-buffer buf
        (harness-ignore-errors-logged "revert after tool write"
          (revert-buffer :ignore-auto :noconfirm :preserve-modes))))))

(provide 'harness-client-tools)
;;; harness-client-tools.el ends here
