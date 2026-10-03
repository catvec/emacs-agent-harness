;;; harness-tools-emacs.el --- Tools that look inside the user's Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only windows into the user's Emacs so a model can help drive
;; it: the buffer list, a buffer's text, documentation and values of
;; symbols, and the tail of *Messages*.  Changing Emacs goes through
;; the elisp tool (tools-shell), an exec-class tool that asks for
;; permission separately and evaluates in a background Emacs unless the
;; user lets it into theirs.
;;
;; Like every tool these run here, in the harness.  The user's Emacs is
;; a resource they reach, as a TRAMP host is for the file tools: they
;; check their input, ask the Emacs a client lent to the harness for
;; plain data (`harness-tools-ask-emacs'; lisp/harness-emacs-endpoint.el
;; answers in that Emacs) and word the result here.  A client that lends
;; no Emacs, such as a phone, is never asked; with none attached (a
;; headless harness) these tools say so, and every other tool works.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defconst harness-tools-emacs--value-chars 500
  "Variable values longer than this are truncated by emacs_describe.")

(defconst harness-tools-emacs--messages-default 50
  "Number of *Messages* lines emacs_messages returns by default.")

(defconst harness-tools-emacs--no-emacs-hint
  "Read files with read_file, or evaluate Lisp in a background Emacs with the elisp tool."
  "What the model is told to do instead when the user's Emacs cannot be asked.")

(defun harness-tools-emacs--buffer-chars ()
  "Return the most characters of text emacs_buffer reads in one call.
Two thirds of `harness-tools-max-output-chars', which leaves room for the
line numbers, so a long buffer comes in ranges instead of crossing from
the user's Emacs whole."
  (max 1000 (/ (* 2 harness-tools-max-output-chars) 3)))

(defun harness-tools-emacs--ask (method params format-answer)
  "Ask the user's Emacs for METHOD with PARAMS; return a promise of a tool result.
FORMAT-ANSWER turns the answer into the result.  When the Emacs cannot
be asked or does not answer, the result is an error that says why."
  (harness-then
   (harness-tools-ask-emacs method params)
   (lambda (answer)
     (condition-case err
         (funcall format-answer answer)
       (error (harness-tool-error (harness-error-message err)))))
   (lambda (err)
     (harness-tool-error (concat (harness-tools-sentence (harness-tools-reason err))
                                 " " harness-tools-emacs--no-emacs-hint)))))

(defun harness-tools-emacs--int (value default)
  "Return VALUE as an integer, or DEFAULT."
  (cond ((integerp value) value)
        ((numberp value) (truncate value))
        ((and (stringp value) (string-match-p "\\`-?[0-9]+\\'" value)) (string-to-number value))
        (t default)))

;;;; emacs_buffers

(defun harness-tools-emacs--buffer-row (buffer)
  "Return the row of emacs_buffers for BUFFER, a plist the user's Emacs sent."
  (let ((file (plist-get buffer :file)))
    (list (or (plist-get buffer :name) "")
          (or (plist-get buffer :mode) "")
          (if (harness-json-true-p (plist-get buffer :modified)) "*" "")
          (harness-format-bytes (plist-get buffer :size))
          (if (stringp file) (abbreviate-file-name file) ""))))

(defun harness-tools-emacs--format-buffers (buffers filter all)
  "Return the emacs_buffers result for BUFFERS, matched against FILTER.
Hidden buffers, whose names start with a space, are left out unless ALL."
  (let* ((filter (and (stringp filter) (not (string-empty-p filter)) filter))
         (rows (mapcar #'harness-tools-emacs--buffer-row
                       (cl-remove-if-not
                        (lambda (b)
                          (let ((name (or (plist-get b :name) ""))
                                (file (plist-get b :file)))
                            (and (or all (not (string-prefix-p " " name)))
                                 (or (not filter)
                                     (string-match-p filter name)
                                     (and (stringp file) (string-match-p filter file))))))
                        buffers))))
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

(defun harness-tools-emacs--buffers (input _ctx)
  "Handler for emacs_buffers with INPUT."
  (let ((filter (plist-get input :filter))
        (all (harness-json-true-p (plist-get input :all))))
    (harness-tools-emacs--ask
     "buffers" :empty
     (lambda (answer) (harness-tools-emacs--format-buffers (plist-get answer :buffers) filter all)))))

(harness-define-tool "emacs_buffers"
  :label "List buffers"
  :description "List the live buffers in the user's Emacs: name, major mode, modified flag (M), size and visited file."
  :schema '(:type "object"
            :properties (:filter (:type "string" :description "Only buffers whose name or file matches this regexp")
                         :all (:type "boolean" :description "Include hidden buffers (names starting with a space). Default false")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (when-let* ((filter (plist-get input :filter))) (format "/%s/" filter)))
  :handler #'harness-tools-emacs--buffers)

;;;; emacs_buffer

(defun harness-tools-emacs--format-buffer (name answer)
  "Return the emacs_buffer result for buffer NAME from ANSWER.
ANSWER is what the user's Emacs sent: the lines, and where they are."
  (let* ((total (or (plist-get answer :total) 0))
         (first (or (plist-get answer :first) 1))
         (lines (plist-get answer :lines))
         (last (+ first (length lines) -1))
         (mode (plist-get answer :mode))
         (file (plist-get answer :file)))
    (cond
     ((not (harness-json-true-p (plist-get answer :exists)))
      (harness-tool-error (format "No buffer named %S; use emacs_buffers to list them" name)))
     ((zerop total) (harness-tool-ok (format "Buffer %s is empty" name)))
     ((> first total)
      (harness-tool-error (format "offset %d is past the end of %s (%d lines)" first name total)))
     (t
      (harness-tool-ok
       (format "%s\n\n[%s (%s): lines %d-%d of %d%s%s%s]"
               (string-join (cl-loop for line in lines for n from first
                                     collect (format "%6d\t%s" n line))
                            "\n")
               name mode first last total
               (if (stringp file) (format ", file %s" (abbreviate-file-name file)) "")
               (if (harness-json-true-p (plist-get answer :modified)) ", modified" "")
               (if (harness-json-true-p (plist-get answer :truncated))
                   (format "; stopped at %d characters, read on with offset %d"
                           (harness-tools-emacs--buffer-chars) (1+ last))
                 "")))))))

(defun harness-tools-emacs--buffer (input _ctx)
  "Handler for emacs_buffer with INPUT."
  (let ((name (plist-get input :name))
        (offset (max 1 (harness-tools-emacs--int (plist-get input :offset) 1)))
        (limit (harness-tools-emacs--int (plist-get input :limit) nil)))
    (if (not (stringp name))
        (harness-tool-error "Missing name")
      (harness-tools-emacs--ask
       "buffer" (list :name name :offset offset :limit (and limit (max 0 limit))
                      :maxChars (harness-tools-emacs--buffer-chars))
       (lambda (answer) (harness-tools-emacs--format-buffer name answer))))))

(harness-define-tool "emacs_buffer"
  :label "Read buffer"
  :description "Read the text of a live buffer with line numbers, optionally a range (offset is the 1-based first line, limit the number of lines)."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "Buffer name, exactly as emacs_buffers lists it")
                         :offset (:type "integer" :description "First line to return (1-based). Default 1")
                         :limit (:type "integer" :description "Maximum number of lines. Default: all"))
            :required ("name"))
  :kind 'read
  :coalescable t
  :subject (lambda (input)
             (when-let* ((name (plist-get input :name)))
               (let ((o (plist-get input :offset)) (l (plist-get input :limit)))
                 (format "%s%s" name
                         (cond ((and o l) (format ":%s-%s" o (+ o l -1))) (o (format ":%s-" o)) (t ""))))))
  :handler #'harness-tools-emacs--buffer)

;;;; emacs_describe

(defun harness-tools-emacs--format-describe (name answer)
  "Return the emacs_describe result for the symbol NAME from ANSWER."
  (if (not (harness-json-true-p (plist-get answer :known)))
      (harness-tool-error (format "No symbol named %s is known to the user's Emacs" name))
    (let* ((doc (lambda (part)
                  (let ((d (plist-get part :doc)))
                    (if (and (stringp d) (not (string-empty-p d))) d "(no documentation)"))))
           (fn (plist-get answer :function))
           (var (plist-get answer :variable))
           (face (plist-get answer :face))
           (parts (delq nil
                        (list (and fn (format "%s: %s\n%s" (plist-get fn :kind) (plist-get fn :signature)
                                              (funcall doc fn)))
                              (and var (format "%s: %s\nvalue: %s\n%s" (plist-get var :kind) (string-trim name)
                                               (plist-get var :value) (funcall doc var)))
                              (and face (format "face: %s\n%s" (string-trim name)
                                                (or (plist-get face :doc) "")))))))
      (if parts
          (harness-tool-ok (string-join parts "\n\n"))
        (harness-tool-error (format "%s is neither a function nor a variable" (string-trim name)))))))

(defun harness-tools-emacs--describe (input _ctx)
  "Handler for emacs_describe with INPUT."
  (let ((name (plist-get input :symbol)))
    (if (not (stringp name))
        (harness-tool-error "Missing symbol")
      (harness-tools-emacs--ask
       "describe" (list :symbol name :maxValueChars harness-tools-emacs--value-chars)
       (lambda (answer) (harness-tools-emacs--format-describe name answer))))))

(harness-define-tool "emacs_describe"
  :label "Describe symbol"
  :description "Describe an Emacs symbol: function signature and docstring, variable docstring and current value (truncated)."
  :schema '(:type "object"
            :properties (:symbol (:type "string" :description "The symbol name, e.g. find-file or fill-column"))
            :required ("symbol"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :symbol))
  :handler #'harness-tools-emacs--describe)

;;;; emacs_messages

(defun harness-tools-emacs--messages (input _ctx)
  "Handler for emacs_messages with INPUT."
  (let ((count (max 1 (harness-tools-emacs--int (plist-get input :count)
                                                harness-tools-emacs--messages-default))))
    (harness-tools-emacs--ask
     "messages" (list :count count)
     (lambda (answer)
       (let ((text (plist-get answer :text)))
         (harness-tool-ok (if (or (not (stringp text)) (string-empty-p text)) "*Messages* is empty" text)))))))

(harness-define-tool "emacs_messages"
  :label "Emacs messages"
  :description "Return the last lines of the *Messages* buffer (errors, warnings and messages Emacs showed the user)."
  :schema '(:type "object"
            :properties (:count (:type "integer" :description "Number of lines. Default 50")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (format "last %s lines" (or (plist-get input :count) harness-tools-emacs--messages-default)))
  :handler #'harness-tools-emacs--messages)

(harness-define-module 'tools-emacs
  :doc "List buffers, Read buffer, Describe symbol and Emacs messages: read-only tools into the user's Emacs."
  :requires '(tools))

(provide 'harness-tools-emacs)
;;; harness-tools-emacs.el ends here
