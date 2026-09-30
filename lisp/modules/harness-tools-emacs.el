;;; harness-tools-emacs.el --- Tools that look inside the running Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only windows into the user's Emacs session so a model can help
;; drive it: the buffer list, a buffer's text, documentation and values
;; of symbols, and the tail of *Messages*.  Changing Emacs goes through
;; the elisp tool (tools-shell), which is an exec-class tool and so
;; asks for permission separately.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'help-fns)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defcustom harness-tools-emacs-value-chars 500
  "Variable values longer than this are truncated by emacs_describe."
  :type 'integer :group 'harness)

(defcustom harness-tools-emacs-messages-default 50
  "Number of *Messages* lines emacs_messages returns by default."
  :type 'integer :group 'harness)

(defun harness-tools-emacs--int (v default)
  "Return V as an integer, or DEFAULT."
  (cond ((integerp v) v)
        ((numberp v) (truncate v))
        ((and (stringp v) (string-match-p "\\`-?[0-9]+\\'" v)) (string-to-number v))
        (t default)))

;;;; emacs_buffers

(defun harness-tools-emacs--buffers (input _ctx)
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
        (harness-tool-ok "No buffers match")
      (let ((w1 (min 40 (apply #'max (mapcar (lambda (r) (length (car r))) rows))))
            (w2 (min 28 (apply #'max (mapcar (lambda (r) (length (cadr r))) rows)))))
        (harness-tool-ok
         (concat (format (format "%%-%ds  %%-%ds  M  %%8s  %%s\n" w1 w2) "NAME" "MODE" "SIZE" "FILE")
                 (mapconcat (lambda (r)
                              (format (format "%%-%ds  %%-%ds  %%1s  %%8s  %%s" w1 w2)
                                      (harness-truncate-end (nth 0 r) w1) (harness-truncate-end (nth 1 r) w2)
                                      (nth 2 r) (nth 3 r) (nth 4 r)))
                            rows "\n")
                 (format "\n(%d buffer%s)" (length rows) (if (= 1 (length rows)) "" "s"))))))))

(harness-define-tool "emacs_buffers"
  :description "List the live buffers in the user's Emacs: name, major mode, modified flag (M), size and visited file."
  :schema '(:type "object"
            :properties (:filter (:type "string" :description "Only buffers whose name or file matches this regexp")
                         :all (:type "boolean" :description "Include hidden buffers (names starting with a space). Default false")))
  :kind 'read
  :coalescable t
  :title (lambda (input) (if (plist-get input :filter) (format "emacs_buffers /%s/" (plist-get input :filter)) "emacs_buffers"))
  :handler #'harness-tools-emacs--buffers)

;;;; emacs_buffer

(defun harness-tools-emacs--buffer (input _ctx)
  "Handler for emacs_buffer with INPUT."
  (let* ((name (plist-get input :name))
         (buf (and (stringp name) (get-buffer name)))
         (offset (max 1 (harness-tools-emacs--int (plist-get input :offset) 1)))
         (limit (harness-tools-emacs--int (plist-get input :limit) nil)))
    (cond
     ((not (stringp name)) (harness-tool-error "Missing name"))
     ((null buf) (harness-tool-error (format "No buffer named %S; use emacs_buffers to list them" name)))
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
               ((zerop total) (harness-tool-ok (format "Buffer %s is empty" name)))
               ((> offset total) (harness-tool-error (format "offset %d is past the end of %s (%d lines)" offset name total)))
               (t (harness-tool-ok
                   (format "%s\n\n[%s (%s): lines %d-%d of %d%s%s]"
                           (string-join (nreverse lines) "\n") name major-mode offset (1- n) total
                           (if buffer-file-name (format ", file %s" (abbreviate-file-name buffer-file-name)) "")
                           (if (buffer-modified-p) ", modified" "")))))))))))))

(harness-define-tool "emacs_buffer"
  :description "Read the text of a live buffer with line numbers, optionally a range (offset is the 1-based first line, limit the number of lines)."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "Buffer name, exactly as emacs_buffers lists it")
                         :offset (:type "integer" :description "First line to return (1-based). Default 1")
                         :limit (:type "integer" :description "Maximum number of lines. Default: all"))
            :required ("name"))
  :kind 'read
  :coalescable t
  :title (lambda (input)
           (let ((o (plist-get input :offset)) (l (plist-get input :limit)))
             (format "emacs_buffer %s%s" (plist-get input :name)
                     (cond ((and o l) (format ":%s-%s" o (+ o l -1))) (o (format ":%s-" o)) (t "")))))
  :handler #'harness-tools-emacs--buffer)

;;;; emacs_describe

(defun harness-tools-emacs--describe-function (sym)
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

(defun harness-tools-emacs--describe-variable (sym)
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

(defun harness-tools-emacs--describe (input _ctx)
  "Handler for emacs_describe with INPUT."
  (let* ((name (plist-get input :symbol))
         (sym (and (stringp name) (intern-soft (string-trim name)))))
    (cond
     ((not (stringp name)) (harness-tool-error "Missing symbol"))
     ((null sym) (harness-tool-error (format "No symbol named %s is known to this Emacs" name)))
     (t
      (let ((parts (delq nil (list (harness-tools-emacs--describe-function sym)
                                   (harness-tools-emacs--describe-variable sym)
                                   (when (facep sym) (format "face: %s\n%s" sym (or (face-documentation sym) "")))))))
        (if parts
            (harness-tool-ok (string-join parts "\n\n"))
          (harness-tool-error (format "%s is neither a function nor a variable" sym))))))))

(harness-define-tool "emacs_describe"
  :description "Describe an Emacs symbol: function signature and docstring, variable docstring and current value (truncated)."
  :schema '(:type "object"
            :properties (:symbol (:type "string" :description "The symbol name, e.g. find-file or fill-column"))
            :required ("symbol"))
  :kind 'read
  :coalescable t
  :title (lambda (input) (format "emacs_describe %s" (plist-get input :symbol)))
  :handler #'harness-tools-emacs--describe)

;;;; emacs_messages

(defun harness-tools-emacs--messages (input _ctx)
  "Handler for emacs_messages with INPUT."
  (let* ((count (max 1 (harness-tools-emacs--int (plist-get input :count) harness-tools-emacs-messages-default)))
         (buf (messages-buffer)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (forward-line (- count))
        (let ((text (string-trim-right (buffer-substring-no-properties (point) (point-max)))))
          (harness-tool-ok (if (string-empty-p text) "*Messages* is empty" text)))))))

(harness-define-tool "emacs_messages"
  :description "Return the last lines of the *Messages* buffer (errors, warnings and messages Emacs showed the user)."
  :schema '(:type "object"
            :properties (:count (:type "integer" :description "Number of lines. Default 50")))
  :kind 'read
  :coalescable t
  :title (lambda (input) (format "emacs_messages %s" (or (plist-get input :count) harness-tools-emacs-messages-default)))
  :handler #'harness-tools-emacs--messages)

(harness-define-module 'tools-emacs
  :doc "Read-only tools into the running Emacs: buffers, describe, messages."
  :requires '(tools))

(provide 'harness-tools-emacs)
;;; harness-tools-emacs.el ends here
