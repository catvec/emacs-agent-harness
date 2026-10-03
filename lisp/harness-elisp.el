;;; harness-elisp.el --- Evaluating Lisp out of the UI's way  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The `elisp' tool lets a model run Lisp, and model-written code must
;; never run in the user's Emacs.  Emacs runs Lisp on one thread, so
;; code that blocks -- a `call-process' waiting on a child, a loop that
;; never yields -- freezes typing and redisplay, and nothing can be
;; done about it from Lisp: `with-timeout' needs the event loop, and a
;; signal only breaks loops that call `maybe-quit', not a blocked
;; subprocess read.  So the tool evaluates in a child `emacs --batch'
;; process (`harness-elisp-batch-main'), which the tool kills, tree and
;; all, when it overruns its timeout.  The child adds the harness to
;; its `load-path', so `(require 'harness-...)` works as it did when
;; the code ran in the harness's own Emacs.
;;
;; `harness-elisp-eval-string' is the evaluator both that child and the
;; opt-in in-UI path (`harness-elisp-allow-ui-eval') share.

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

(defcustom harness-elisp-allow-ui-eval nil
  "Non-nil lets the `elisp' tool evaluate inside the UI's Emacs.
The default runs it in a separate batch Emacs process, where it cannot
freeze Emacs.  Turning this on restores the older behaviour, and with
it the ability to wedge Emacs beyond recovery: Emacs runs Lisp on one
thread, so a blocking subprocess call or a loop that never yields
stops typing and redisplay, and neither a timer nor a signal can end
it.  Only turn this on to drive the live Emacs in ways the narrow
`emacs_*' tools cannot, and expect that a bad expression can freeze
the UI until the blocking process is killed."
  :type 'boolean :group 'harness)

;;;; Evaluating a string

(defun harness-elisp-read-forms (code)
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

(defun harness-elisp-format-result (value output messages)
  "Return the content an `elisp' tool result shows.
VALUE is the printed value, OUTPUT what the code printed and MESSAGES
the `message' calls it made; empty sections are left out."
  (string-join
   (delq nil
         (list (format "=> %s" value)
               (unless (string-empty-p output)
                 (concat "--- output ---\n" (string-trim-right output)))
               (unless (string-empty-p messages)
                 (concat "--- messages ---\n" messages))))
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

;;;; The child process

(defun harness-elisp--batch-payload (result error)
  "Return the JSON-ready plist for an `elisp' evaluation.
RESULT is (VALUE OUTPUT MESSAGES) or nil; ERROR is the failure's
message or nil."
  (if error
      (list :value "" :output "" :messages "" :error error)
    (pcase-let ((`(,value ,output ,messages) result))
      (list :value (harness-elisp-print-value value)
            :output (string-trim-right output)
            :messages messages
            :error nil))))

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
    (let ((payload (condition-case err
                       (progn
                         (when (or (not code-file) (not (file-readable-p code-file)))
                           (error "Cannot read the code file %s" code-file))
                         (harness-elisp--batch-payload
                          (let ((code (with-temp-buffer
                                        (insert-file-contents code-file)
                                        (buffer-string))))
                            (harness-elisp-eval-string code))
                          nil))
                     (error (harness-elisp--batch-payload nil (error-message-string err))))))
      ;; Anything the code printed to the terminal is noise to the parent,
      ;; which reads the result file.
      (harness-elisp--batch-write result-file payload)
      (kill-emacs 0))))

(provide 'harness-elisp)
;;; harness-elisp.el ends here
